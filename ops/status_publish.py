"""Render network.json for the status page: last deploy, pinned branches, faucet, VL, amendments."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from multibranch_builder.conf import parse_config

from ops.faucet import derive_address, get_balance, load_faucet_seed, pick_admin_url, rpc
from ops.nodes import Inventory, load_inventory
from ops.record_deploy import load_deploys

DROPS_PER_XRP = 1_000_000


def branches_from_conf(conf_path: str | Path) -> list[dict]:
    config = parse_config(conf_path)
    return [
        {
            "repo": f"{b.owner}/{b.repo}",
            "branch": b.branch,
            "pr_url": f"https://github.com/{b.owner}/{b.repo}/tree/{b.branch}",
        }
        for b in config.branches
    ]


def vl_from_node(admin_url: str, site: str) -> dict:
    """VL site from the inventory plus the publisher list expiration the node reports."""
    info = rpc(admin_url, "server_info")["info"]
    expiration = (info.get("validator_list") or {}).get("expiration", "")
    return {"site": site, "expiration": expiration}


def faucet_from_node(admin_url: str, seed: str) -> dict:
    address = derive_address(admin_url, seed)
    try:
        balance_xrp = get_balance(admin_url, address) / DROPS_PER_XRP
    except (KeyError, ValueError):
        balance_xrp = None
    return {"address": address, "balance_xrp": balance_xrp}


def enabled_amendments(admin_url: str) -> list[str]:
    features = rpc(admin_url, "feature").get("features", {})
    return sorted(f["name"] for f in features.values() if f.get("enabled"))


def render_network(
    deploys: list[dict],
    branches: list[dict],
    inventory: Inventory,
    admin_url: str | None,
    faucet_seed: str = "",
) -> dict:
    network: dict = {
        "last_deploy": deploys[-1] if deploys else None,
        "branches": branches,
        "vl": {"site": inventory.settings.get("VL_SITE", ""), "expiration": ""},
        "faucet": None,
        "amendments": None,
    }
    if admin_url is None:
        return network
    network["vl"] = vl_from_node(admin_url, network["vl"]["site"])
    network["amendments"] = {"enabled": enabled_amendments(admin_url)}
    if faucet_seed:
        network["faucet"] = faucet_from_node(admin_url, faucet_seed)
    return network


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--conf", required=True)
    parser.add_argument("--deploys", required=True)
    parser.add_argument("--ansible-config", default="", help="xrpld-lab YAML holding the faucet seed; omit to leave the faucet panel empty")
    parser.add_argument("--offline", action="store_true", help="skip every node RPC; VL expiration, faucet and amendments stay empty")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)

    inventory = load_inventory(args.inventory)
    admin_url = None if args.offline else pick_admin_url(inventory)
    if not args.offline and admin_url is None:
        print("no node answered server_info on its admin port", file=sys.stderr)
        return 1
    seed = load_faucet_seed(args.ansible_config) if args.ansible_config else ""
    network = render_network(load_deploys(Path(args.deploys)), branches_from_conf(args.conf), inventory, admin_url, seed)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(network, indent=2) + "\n")
    print(f"wrote {out}: {len(network['branches'])} branches, last deploy {(network['last_deploy'] or {}).get('sha', 'none')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
