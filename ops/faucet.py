"""Fund and verify the alphanet faucet account over a node's admin RPC.

The faucet seed is read from the xrpld-lab ansible YAML (services[].faucet.seed) and is passed
only to the node's wallet_propose; it is never printed or logged.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass

import requests
import yaml

from ops.nodes import Inventory, Node, load_inventory

# The genesis account of every xrpld chain; its key is derived from this passphrase by the node.
GENESIS_PASSPHRASE = "masterpassphrase"
GENESIS_ACCOUNT = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
# Drops left in the genesis account after funding the faucet.
GENESIS_RESERVE_DROPS = 200_000_000
# A faucet holding more than this is treated as already funded.
FUNDED_THRESHOLD_DROPS = 10_000_000_000


@dataclass
class FundFaucetResult:
    faucet_address: str = ""
    amount_xrp: str = ""
    tx_hash: str = ""
    engine_result: str = ""
    error: str = ""

    @property
    def passed(self) -> bool:
        return self.engine_result == "tesSUCCESS" and not self.error


@dataclass
class VerifyFaucetResult:
    faucet_address: str = ""
    balance_drops: int = 0
    balance_xrp: str = ""
    error: str = ""

    @property
    def passed(self) -> bool:
        return self.balance_drops > 0 and not self.error


def rpc(admin_url: str, method: str, params: dict | None = None, timeout: float = 10) -> dict:
    body = {"method": method, "params": [params]} if params is not None else {"method": method}
    resp = requests.post(admin_url, json=body, timeout=timeout)
    return resp.json()["result"]


def load_faucet_seed(ansible_config: str) -> str:
    """Return services[].faucet.seed from the xrpld-lab ansible YAML, or '' when absent."""
    with open(ansible_config) as fh:
        data = yaml.safe_load(fh) or {}
    for svc in data.get("services", []):
        faucet = svc.get("faucet")
        if faucet and faucet.get("seed"):
            return str(faucet["seed"])
    return ""


def pick_admin_url(inventory: Inventory, timeout: float = 5) -> str | None:
    """Return the first admin URL that answers server_info, peers before validators."""
    for node in inventory.peers + inventory.validators:
        try:
            requests.post(node.admin_url, json={"method": "server_info"}, timeout=timeout)
            return node.admin_url
        except Exception:
            continue
    return None


def derive_address(admin_url: str, seed: str) -> str:
    return rpc(admin_url, "wallet_propose", {"seed": seed})["account_id"]


def get_network_id(admin_url: str) -> int:
    return int(rpc(admin_url, "server_info")["info"].get("network_id", 0))


def get_balance(admin_url: str, account: str) -> int:
    return int(rpc(admin_url, "account_info", {"account": account})["account_data"]["Balance"])


def fund_faucet(inventory: Inventory, faucet_seed: str) -> FundFaucetResult:
    """Pay the genesis balance minus GENESIS_RESERVE_DROPS to the faucet account."""
    result = FundFaucetResult()
    if not faucet_seed:
        result.error = "no faucet seed in the ansible config (services[].faucet.seed)"
        return result
    admin_url = pick_admin_url(inventory)
    if not admin_url:
        result.error = "no admin RPC endpoint answered"
        return result
    try:
        network_id = get_network_id(admin_url)
        result.faucet_address = derive_address(admin_url, faucet_seed)
        try:
            existing = get_balance(admin_url, result.faucet_address)
        except Exception:
            existing = 0
        if existing > FUNDED_THRESHOLD_DROPS:
            result.amount_xrp = f"{existing / 1_000_000:.6f}"
            result.engine_result = "tesSUCCESS"
            return result

        send_amount = get_balance(admin_url, GENESIS_ACCOUNT) - GENESIS_RESERVE_DROPS
        if send_amount <= 0:
            result.error = f"genesis balance too low: {send_amount + GENESIS_RESERVE_DROPS} drops"
            return result
        result.amount_xrp = f"{send_amount / 1_000_000:.6f}"
        tx_json = {
            "TransactionType": "Payment",
            "Account": GENESIS_ACCOUNT,
            "Destination": result.faucet_address,
            "Amount": str(send_amount),
            "Fee": "12",
            "NetworkID": network_id,
        }
        submit = rpc(admin_url, "submit", {"secret": GENESIS_PASSPHRASE, "tx_json": tx_json}, timeout=30)
        result.engine_result = submit.get("engine_result", "unknown")
        result.tx_hash = submit.get("tx_json", {}).get("hash", "")
        if result.engine_result != "tesSUCCESS":
            result.error = f"{result.engine_result}: {submit.get('engine_result_message', '')}"
    except Exception as exc:
        result.error = str(exc)
    return result


def verify_faucet(inventory: Inventory, faucet_seed: str, min_balance_xrp: float = 1000.0) -> VerifyFaucetResult:
    """Check the faucet account balance is at least min_balance_xrp."""
    result = VerifyFaucetResult()
    if not faucet_seed:
        result.error = "no faucet seed in the ansible config (services[].faucet.seed)"
        return result
    admin_url = pick_admin_url(inventory)
    if not admin_url:
        result.error = "no admin RPC endpoint answered"
        return result
    try:
        result.faucet_address = derive_address(admin_url, faucet_seed)
        result.balance_drops = get_balance(admin_url, result.faucet_address)
        result.balance_xrp = f"{result.balance_drops / 1_000_000:.6f}"
        if result.balance_drops < int(min_balance_xrp * 1_000_000):
            result.error = f"faucet balance {result.balance_xrp} XRP below minimum {min_balance_xrp} XRP"
    except Exception as exc:
        result.error = str(exc)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["fund", "verify"])
    parser.add_argument("--inventory", default=None, help="path to network/inventory")
    parser.add_argument("--ansible-config", required=True, help="xrpld-lab ansible YAML holding services[].faucet.seed")
    parser.add_argument("--min-balance-xrp", type=float, default=1000.0)
    args = parser.parse_args(argv)

    inventory = load_inventory(args.inventory)
    seed = load_faucet_seed(args.ansible_config)
    if args.command == "fund":
        fund = fund_faucet(inventory, seed)
        print(f"faucet_address={fund.faucet_address} amount_xrp={fund.amount_xrp} "
              f"engine_result={fund.engine_result} tx_hash={fund.tx_hash}")
        if fund.error:
            print(fund.error, file=sys.stderr)
        return 0 if fund.passed else 1
    verify = verify_faucet(inventory, seed, args.min_balance_xrp)
    print(f"faucet_address={verify.faucet_address} balance_xrp={verify.balance_xrp}")
    if verify.error:
        print(verify.error, file=sys.stderr)
    return 0 if verify.passed else 1


if __name__ == "__main__":
    sys.exit(main())
