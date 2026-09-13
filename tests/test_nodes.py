from pathlib import Path

import pytest

from ops.nodes import load_inventory, parse_inventory

INVENTORY = Path(__file__).resolve().parent.parent / "network" / "inventory"


def test_repo_inventory_has_six_validators_and_two_peers():
    inv = load_inventory(INVENTORY)
    assert [n.name for n in inv.validators] == ["vnode1", "vnode2", "vnode3", "vnode4", "vnode5", "vnode6"]
    assert [n.name for n in inv.peers] == ["pnode1", "pnode2"]
    assert inv.validators[0].ip == "79.110.60.99"
    assert inv.peers[1].ip == "79.110.60.106"


def test_admin_ports_follow_xrpld_lab_portset():
    inv = load_inventory(INVENTORY)
    assert [n.admin_port for n in inv.validators] == [5105, 5205, 5305, 5405, 5505, 5605]
    assert [n.admin_port for n in inv.peers] == [5015, 5025]
    pnode1 = inv.by_name("pnode1")
    assert (pnode1.ssh_user, pnode1.ssh_port) == ("root", 1988)
    assert pnode1.ssh_key.endswith("/.ssh/xrpl-labs")


def test_settings_and_comments():
    inv = load_inventory(INVENTORY)
    assert inv.settings["SSH_PORT"] == "1988"
    assert inv.settings["SSH_USER"] == "root"
    assert inv.settings["SSH_KEY_DIR"] == "~/.ssh/alphanet"
    assert inv.settings["VL_SITE"] == "https://vl.alphanet.xrpl.org/vl.json"
    assert "LIFECYCLE" not in inv.settings


def test_parse_rejects_malformed_row():
    with pytest.raises(ValueError):
        parse_inventory("VALIDATOR 10.0.0.1\n")
    with pytest.raises(KeyError):
        parse_inventory("PEER 10.0.0.1 p1\n").by_name("vnode9")
