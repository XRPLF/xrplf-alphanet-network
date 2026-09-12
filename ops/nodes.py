"""Parse network/inventory into the node list with admin RPC ports."""

from __future__ import annotations

import os
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

    @property
    def admin_url(self) -> str:
        return f"http://{self.ip}:{self.admin_port}"


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
    nodes: list[Node] = []
    settings: dict[str, str] = {}
    counts = {"validator": 0, "peer": 0}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        key = fields[0]
        if key in ROLE_KEYWORDS:
            if len(fields) != 3:
                raise ValueError(f"inventory row needs 'ROLE ip name': {raw!r}")
            role = ROLE_KEYWORDS[key]
            counts[role] += 1
            step = VALIDATOR_PORT_STEP if role == "validator" else PEER_PORT_STEP
            nodes.append(Node(
                name=fields[2],
                ip=fields[1],
                role=role,
                admin_port=RPC_ADMIN_BASE + counts[role] * step,
            ))
        elif len(fields) >= 2:
            settings[key] = " ".join(fields[1:])
        else:
            raise ValueError(f"inventory line has no value: {raw!r}")
    return Inventory(nodes=tuple(nodes), settings=settings)


def load_inventory(path: str | os.PathLike | None = None) -> Inventory:
    return parse_inventory(Path(path or DEFAULT_INVENTORY).read_text())
