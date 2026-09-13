from pathlib import Path

import pytest

from ops import health
from ops.nodes import load_inventory

INVENTORY = Path(__file__).resolve().parent.parent / "network" / "inventory"


def server_info(state, seq=100, peers=7):
    return {"info": {"server_state": state, "peers": peers, "validated_ledger": {"seq": seq}, "uptime": 5}}


def fake_rpc_factory(states_by_port):
    def fake_rpc(node, method, params=None, timeout=None):
        state = states_by_port[node.admin_port]
        if state == "down":
            raise ConnectionError(f"refused {node.name}")
        return server_info(state)
    return fake_rpc


def test_all_nodes_healthy(monkeypatch):
    inv = load_inventory(INVENTORY)
    states = {n.admin_port: ("proposing" if n.role == "validator" else "full") for n in inv.nodes}
    monkeypatch.setattr(health, "admin_rpc", fake_rpc_factory(states))
    result = health.health_check(inv, timeout=0, poll_interval=0, sleep=lambda s: None)
    assert result.passed
    assert result.nodes_checked == 8 and result.nodes_healthy == 8


def test_peer_in_proposing_is_not_healthy(monkeypatch):
    inv = load_inventory(INVENTORY)
    states = {n.admin_port: "proposing" for n in inv.nodes}
    monkeypatch.setattr(health, "admin_rpc", fake_rpc_factory(states))
    result = health.health_check(inv, timeout=0, sleep=lambda s: None)
    assert not result.passed
    assert result.nodes_healthy == 6
    assert "pnode1(proposing)" in result.error and "pnode2(proposing)" in result.error


def test_unreachable_node_fails_and_cli_exits_one(monkeypatch):
    inv = load_inventory(INVENTORY)
    states = {n.admin_port: ("proposing" if n.role == "validator" else "full") for n in inv.nodes}
    states[inv.by_name("vnode3").admin_port] = "down"
    monkeypatch.setattr(health, "admin_rpc", fake_rpc_factory(states))
    result = health.health_check(inv, timeout=0, sleep=lambda s: None)
    assert not result.passed
    assert [d["state"] for d in result.node_details if d["name"] == "vnode3"] == ["unreachable"]
    assert health.main(["--inventory", str(INVENTORY), "--timeout", "0"]) == 1


def test_polls_until_healthy(monkeypatch):
    inv = load_inventory(INVENTORY)
    calls = {"n": 0}
    healthy = {n.admin_port: ("proposing" if n.role == "validator" else "full") for n in inv.nodes}

    def fake_rpc(node, method, params=None, timeout=None):
        calls["n"] += 1
        state = healthy[node.admin_port] if calls["n"] > 8 else "connected"
        return server_info(state)

    monkeypatch.setattr(health, "admin_rpc", fake_rpc)
    ticks = iter([0, 0, 1, 1, 2, 2])
    result = health.health_check(inv, timeout=100, poll_interval=1, sleep=lambda s: None, clock=lambda: next(ticks))
    assert result.passed
    assert calls["n"] == 16


def test_cli_exits_zero_when_healthy(monkeypatch):
    inv = load_inventory(INVENTORY)
    states = {n.admin_port: ("proposing" if n.role == "validator" else "full") for n in inv.nodes}
    monkeypatch.setattr(health, "admin_rpc", fake_rpc_factory(states))
    assert health.main(["--inventory", str(INVENTORY), "--timeout", "0"]) == 0
