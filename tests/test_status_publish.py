import json

import pytest

from ops import status_publish
from ops.nodes import parse_inventory

INVENTORY = """
VALIDATOR 10.0.0.1 vnode1
PEER      10.0.0.10 pnode1
VL_SITE http://vl.example/vl.json
"""

CONF = """
base XRPLF/rippled develop
target Transia-RnD/rippled alphanet
XRPLF/rippled dangell7/subscriptions rebase
XRPLF/rippled xrplf/smart-contracts
"""

RPC_RESPONSES = {
    "server_info": {"info": {"validator_list": {"expiration": "2026-10-01T00:00:00Z"}}},
    "wallet_propose": {"account_id": "rFaucet"},
    "account_info": {"account_data": {"Balance": "2500000000"}},
    "feature": {"features": {
        "A": {"name": "Subscription", "enabled": True},
        "B": {"name": "SmartContract", "enabled": False},
    }},
}


@pytest.fixture
def files(tmp_path):
    conf = tmp_path / "alphanet.conf"
    conf.write_text(CONF)
    deploys = tmp_path / "deploys.json"
    deploys.write_text(json.dumps([{"sha": "abc", "image": "img", "genesis": False, "date": "d", "operator": "op"}]))
    return conf, deploys


def test_branches_from_conf_skips_base_and_target(files):
    conf, _ = files
    branches = status_publish.branches_from_conf(conf)
    assert [b["branch"] for b in branches] == ["dangell7/subscriptions", "xrplf/smart-contracts"]
    assert branches[0]["pr_url"] == "https://github.com/XRPLF/rippled/tree/dangell7/subscriptions"


def test_render_offline_leaves_node_fields_empty(files):
    conf, _ = files
    inventory = parse_inventory(INVENTORY)
    network = status_publish.render_network(
        [{"sha": "abc"}], status_publish.branches_from_conf(conf), inventory, admin_url=None)
    assert network["last_deploy"] == {"sha": "abc"}
    assert network["vl"] == {"site": "http://vl.example/vl.json", "expiration": ""}
    assert network["faucet"] is None and network["amendments"] is None


def test_render_with_node_fills_vl_faucet_and_amendments(files, monkeypatch):
    conf, _ = files
    fake_rpc = lambda url, method, params=None, timeout=10: RPC_RESPONSES[method]
    monkeypatch.setattr(status_publish, "rpc", fake_rpc)
    monkeypatch.setattr("ops.faucet.rpc", fake_rpc)
    inventory = parse_inventory(INVENTORY)
    network = status_publish.render_network(
        [], status_publish.branches_from_conf(conf), inventory, admin_url="http://10.0.0.10:5015", faucet_seed="s")
    assert network["last_deploy"] is None
    assert network["vl"]["expiration"] == "2026-10-01T00:00:00Z"
    assert network["faucet"] == {"address": "rFaucet", "balance_xrp": 2500.0}
    assert network["amendments"] == {"enabled": ["Subscription"]}


def test_cli_offline_writes_file(files, tmp_path):
    conf, deploys = files
    inventory = tmp_path / "inventory"
    inventory.write_text(INVENTORY)
    out = tmp_path / "ws" / "network.json"
    assert status_publish.main([
        "--inventory", str(inventory), "--conf", str(conf), "--deploys", str(deploys),
        "--offline", "--out", str(out),
    ]) == 0
    network = json.loads(out.read_text())
    assert network["last_deploy"]["sha"] == "abc"
    assert len(network["branches"]) == 2
