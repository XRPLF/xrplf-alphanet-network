"""Parse network/inventory into the node list with admin RPC ports."""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

DEFAULT_INVENTORY = Path(__file__).resolve().parent.parent / "network" / "inventory"

# xrpld-lab PortSet: admin RPC port is 5005 + 1-based index * step, per role.
RPC_ADMIN_BASE = 5005
VALIDATOR_PORT_STEP = 100
PEER_PORT_STEP = 10

ROLE_KEYWORDS = {"VALIDATOR": "validator", "PEER": "peer"}


@dataclass(frozen=True)
class Node:
    name: str
    ip: str
    role: str
    admin_port: int
    ssh_user: str = "root"
    ssh_port: int = 22
    ssh_key: str = ""


@dataclass(frozen=True)
class Inventory:
    nodes: tuple[Node, ...]
    settings: dict[str, str]

    @property
    def validators(self) -> list[Node]:
        return [n for n in self.nodes if n.role == "validator"]

    @property
    def peers(self) -> list[Node]:
        return [n for n in self.nodes if n.role == "peer"]

    def by_name(self, name: str) -> Node:
        for node in self.nodes:
            if node.name == name:
                return node
        raise KeyError(f"unknown node '{name}' (have: {' '.join(n.name for n in self.nodes)})")


def parse_inventory(text: str) -> Inventory:
    """Parse inventory text: `VALIDATOR|PEER <ip> <name>` rows and `KEY value` settings."""
    rows: list[tuple[str, str, str]] = []
    settings: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        key = fields[0]
        if key in ROLE_KEYWORDS:
            if len(fields) != 3:
                raise ValueError(f"inventory row needs 'ROLE ip name': {raw!r}")
            rows.append((ROLE_KEYWORDS[key], fields[1], fields[2]))
        elif len(fields) >= 2:
            settings[key] = " ".join(fields[1:])
        else:
            raise ValueError(f"inventory line has no value: {raw!r}")
    counts = {"validator": 0, "peer": 0}
    nodes: list[Node] = []
    for role, ip, name in rows:
        counts[role] += 1
        step = VALIDATOR_PORT_STEP if role == "validator" else PEER_PORT_STEP
        nodes.append(Node(
            name=name,
            ip=ip,
            role=role,
            admin_port=RPC_ADMIN_BASE + counts[role] * step,
            ssh_user=settings.get("SSH_USER", "root"),
            ssh_port=int(settings.get("SSH_PORT", "22")),
            ssh_key=os.path.expanduser(settings.get("SSH_KEY", "")),
        ))
    return Inventory(nodes=tuple(nodes), settings=settings)


def admin_rpc(node: Node, method: str, params: dict | None = None, timeout: float = 10) -> dict:
    """Call the node's admin RPC, which listens on its loopback only, through ssh; the request body
    travels on stdin so secrets never appear in a command line."""
    body = {"method": method, "params": [params]} if params is not None else {"method": method}
    # One ssh session per node, reused across calls: the hosts rate-limit new ssh connections.
    ssh = ["ssh", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes",
           "-o", "ConnectTimeout=10", "-o", "ControlMaster=auto", "-o", "ControlPersist=120",
           "-o", "ControlPath=~/.ssh/xrpld-ops-%C", "-p", str(node.ssh_port)]
    if node.ssh_key:
        ssh += ["-i", node.ssh_key]
    curl = ["curl", "-sS", "-m", str(int(timeout)), "-X", "POST", f"http://127.0.0.1:{node.admin_port}",
            "--data-binary", "@-"]
    proc = subprocess.run(ssh + [f"{node.ssh_user}@{node.ip}", "--"] + curl, input=json.dumps(body),
                          capture_output=True, text=True, timeout=timeout + 15)
    if proc.returncode != 0:
        raise RuntimeError(f"{node.name} admin RPC {method}: {proc.stderr.strip() or f'exit {proc.returncode}'}")
    return json.loads(proc.stdout)["result"]


def load_inventory(path: str | os.PathLike | None = None) -> Inventory:
    return parse_inventory(Path(path or DEFAULT_INVENTORY).read_text())
