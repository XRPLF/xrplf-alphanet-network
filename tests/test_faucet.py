from pathlib import Path

from ops import faucet
from ops.nodes import load_inventory

INVENTORY = Path(__file__).resolve().parent.parent / "network" / "inventory"
FAUCET_ADDRESS = "rFAUCETxxxxxxxxxxxxxxxxxxxxxxxxxxx"


class FakeResponse:
    def __init__(self, payload):
        self._payload = payload

    def json(self):
        return self._payload


def make_post(balances, submits):
    def fake_post(url, json=None, timeout=None):
        method = json["method"]
        params = json.get("params", [{}])[0]
        if method == "server_info":
            return FakeResponse({"result": {"info": {"server_state": "full", "network_id": 24100}}})
        if method == "wallet_propose":
            assert params == {"seed": "PLACEHOLDER_SEED"}
            return FakeResponse({"result": {"account_id": FAUCET_ADDRESS}})
        if method == "account_info":
            account = params["account"]
            if account not in balances:
                return FakeResponse({"result": {"error": "actNotFound"}})
            return FakeResponse({"result": {"account_data": {"Balance": str(balances[account])}}})
        if method == "submit":
            submits.append(params)
            return FakeResponse({"result": {"engine_result": "tesSUCCESS", "tx_json": {"hash": "ABC"}}})
        raise AssertionError(method)
    return fake_post


def test_load_faucet_seed_reads_services(tmp_path):
    cfg = tmp_path / "ansible.yml"
    cfg.write_text("services:\n  - ip: 1.2.3.4\n    faucet:\n      seed: PLACEHOLDER_SEED\n")
    assert faucet.load_faucet_seed(str(cfg)) == "PLACEHOLDER_SEED"
    cfg.write_text("services:\n  - ip: 1.2.3.4\n    nginx: {}\n")
    assert faucet.load_faucet_seed(str(cfg)) == ""


def test_fund_signs_with_genesis_passphrase_and_keeps_reserve(monkeypatch):
    inv = load_inventory(INVENTORY)
    submits = []
    monkeypatch.setattr(faucet.requests, "post", make_post({faucet.GENESIS_ACCOUNT: 1_000_000_000}, submits))
    result = faucet.fund_faucet(inv, "PLACEHOLDER_SEED")
    assert result.passed
    assert result.faucet_address == FAUCET_ADDRESS
    assert result.tx_hash == "ABC"
    assert submits == [{
        "passphrase": "masterpassphrase",
        "tx_json": {
            "TransactionType": "Payment",
            "Account": faucet.GENESIS_ACCOUNT,
            "Destination": FAUCET_ADDRESS,
            "Amount": "800000000",
            "Fee": "12",
            "NetworkID": 24100,
        },
    }]


def test_fund_skips_when_already_funded(monkeypatch):
    inv = load_inventory(INVENTORY)
    submits = []
    balances = {faucet.GENESIS_ACCOUNT: 1_000_000_000, FAUCET_ADDRESS: 50_000_000_000}
    monkeypatch.setattr(faucet.requests, "post", make_post(balances, submits))
    result = faucet.fund_faucet(inv, "PLACEHOLDER_SEED")
    assert result.passed and submits == []
    assert result.amount_xrp == "50000.000000"


def test_verify_reports_low_balance(monkeypatch):
    inv = load_inventory(INVENTORY)
    monkeypatch.setattr(faucet.requests, "post", make_post({FAUCET_ADDRESS: 5_000_000}, []))
    result = faucet.verify_faucet(inv, "PLACEHOLDER_SEED", min_balance_xrp=1000)
    assert not result.passed
    assert result.balance_xrp == "5.000000"
    assert "below minimum" in result.error


def test_missing_seed_is_an_error():
    inv = load_inventory(INVENTORY)
    assert "no faucet seed" in faucet.fund_faucet(inv, "").error
    assert "no faucet seed" in faucet.verify_faucet(inv, "").error
