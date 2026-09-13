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

SDK_CONF = """
base XRPLF/xrpl.js main
target Transia-RnD/xrpl.js alphanet
definitions https://alphanet.xrpl.org
XRPLF/xrpl.js smart-contracts
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


def test_render_offline_leaves_node_fields_empty(files, tmp_path):
    conf, _ = files
    inventory = parse_inventory(INVENTORY)
    network = status_publish.render_network(
        [{"sha": "abc"}], status_publish.integrations_from_confs([conf], tmp_path), inventory, node=None)
    assert network["last_deploy"] == {"sha": "abc"}
    assert network["vl"] == {"site": "http://vl.example/vl.json", "expiration": ""}
    assert network["faucet"] is None and network["amendments"] is None


def test_render_with_node_fills_vl_faucet_and_amendments(files, monkeypatch, tmp_path):
    conf, _ = files
    fake_rpc = lambda url, method, params=None, timeout=10: RPC_RESPONSES[method]
    monkeypatch.setattr(status_publish, "rpc", fake_rpc)
    monkeypatch.setattr("ops.faucet.rpc", fake_rpc)
    inventory = parse_inventory(INVENTORY)
    network = status_publish.render_network(
        [], status_publish.integrations_from_confs([conf], tmp_path), inventory, node=inventory.nodes[0], faucet_seed="s")
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
    assert len(network["integrations"]) == 1 and len(network["integrations"][0]["branches"]) == 2


def test_integrations_carry_kind_base_target_and_manifest_outcomes(tmp_path):
    xrpld = tmp_path / "alphanet.conf"
    xrpld.write_text(CONF)
    sdk = tmp_path / "xrpljs.conf"
    sdk.write_text(SDK_CONF)
    (tmp_path / "alphanet").mkdir()
    (tmp_path / "alphanet" / "manifest.json").write_text(json.dumps({
        "composed_sha": "c0ffee", "branches": [
            {"repo": "XRPLF/rippled", "branch": "dangell7/subscriptions", "sha": "aaa111", "outcome": "merged"},
            {"repo": "XRPLF/rippled", "branch": "xrplf/smart-contracts", "sha": "bbb222", "outcome": "ai-resolved"},
        ]}))
    ints = status_publish.integrations_from_confs([xrpld, sdk], tmp_path)
    assert [(i["kind"], i["conf"], i["base"], i["target"]) for i in ints] == [
        ("xrpld", "alphanet", "XRPLF/rippled@develop", "Transia-RnD/rippled@alphanet"),
        ("xrpl_js", "xrpljs", "XRPLF/xrpl.js@main", "Transia-RnD/xrpl.js@alphanet"),
    ]
    assert ints[0]["composed_sha"] == "c0ffee"
    assert [(b["branch"], b["sha"], b["outcome"]) for b in ints[0]["branches"]] == [
        ("dangell7/subscriptions", "aaa111", "merged"), ("xrplf/smart-contracts", "bbb222", "ai-resolved")]
    assert ints[1]["composed_sha"] is None and ints[1]["branches"][0]["outcome"] is None
    assert ints[1]["branches"][0]["pr_url"] == "https://github.com/XRPLF/xrpl.js/tree/smart-contracts"


def test_endpoints_from_public_domain():
    inv = parse_inventory(INVENTORY + "PUBLIC_DOMAIN example.test\n")
    assert status_publish.endpoints_from_inventory(inv) == {
        "websocket": "wss://example.test", "json_rpc": "https://example.test",
        "faucet_url": "https://faucet.example.test", "vl_site": "http://vl.example/vl.json"}
    assert status_publish.endpoints_from_inventory(parse_inventory(INVENTORY)) == {"vl_site": "http://vl.example/vl.json"}
