"""Poll server_info on every node's admin port until each reaches its expected server_state."""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass, field

from ops.nodes import Inventory, Node, admin_rpc, load_inventory

# Validators must be proposing; peers (no validation key) are full when synced.
EXPECTED_STATE = {"validator": "proposing", "peer": "full"}


@dataclass
class HealthCheckResult:
    nodes_checked: int = 0
    nodes_healthy: int = 0
    node_details: list[dict] = field(default_factory=list)
    error: str = ""

    @property
    def passed(self) -> bool:
        return self.nodes_checked > 0 and self.nodes_healthy == self.nodes_checked and not self.error


def check_node(node: Node, timeout: float = 10) -> dict:
    """Query one node's server_info and return the fields the health check reads."""
    info = {"name": node.name, "ip": node.ip, "port": node.admin_port, "role": node.role}
    try:
        data = admin_rpc(node, "server_info", timeout=timeout).get("info", {})
        info["state"] = data.get("server_state", "unknown")
        info["peers"] = data.get("peers", 0)
        info["validated_ledger"] = data.get("validated_ledger", {}).get("seq", 0)
        info["uptime"] = data.get("uptime", 0)
    except Exception as exc:  # network errors and malformed responses both count as unreachable
        info["error"] = str(exc)
        info["state"] = "unreachable"
    info["expected_state"] = EXPECTED_STATE[node.role]
    info["healthy"] = info["state"] == info["expected_state"]
    return info


def health_check(
    inventory: Inventory,
    timeout: float = 120,
    poll_interval: float = 15,
    sleep=time.sleep,
    clock=time.monotonic,
) -> HealthCheckResult:
    """Check every node, retrying every poll_interval seconds until all are healthy or timeout passes."""
    result = HealthCheckResult()
    nodes = list(inventory.nodes)
    if not nodes:
        result.error = "no nodes in inventory"
        return result

    deadline = clock() + timeout
    while True:
        details = [check_node(node) for node in nodes]
        healthy = sum(1 for d in details if d["healthy"])
        result.nodes_checked = len(nodes)
        result.nodes_healthy = healthy
        result.node_details = details
        if healthy == len(nodes):
            return result
        if clock() >= deadline:
            break
        sleep(poll_interval)

    unhealthy = [f"{d['name']}({d['state']})" for d in result.node_details if not d["healthy"]]
    result.error = f"timeout after {timeout}s; unhealthy: {', '.join(unhealthy)}"
    return result


def format_table(result: HealthCheckResult) -> str:
    rows = [f"{'NODE':<8} {'IP':<15} {'PORT':<5} {'ROLE':<9} {'STATE':<11} {'LEDGER':<9} PEERS"]
    for d in result.node_details:
        rows.append(
            f"{d['name']:<8} {d['ip']:<15} {d['port']:<5} {d['role']:<9} "
            f"{d['state']:<11} {d.get('validated_ledger', '-')!s:<9} {d.get('peers', '-')}"
        )
    rows.append(f"{result.nodes_healthy}/{result.nodes_checked} healthy")
    return "\n".join(rows)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", default=None, help="path to network/inventory")
    parser.add_argument("--timeout", type=float, default=120, help="seconds to keep polling; 0 checks once")
    parser.add_argument("--poll-interval", type=float, default=15)
    parser.add_argument("--json", action="store_true", help="print the node details as JSON")
    args = parser.parse_args(argv)

    result = health_check(load_inventory(args.inventory), timeout=args.timeout, poll_interval=args.poll_interval)
    if args.json:
        print(json.dumps({"passed": result.passed, "error": result.error, "nodes": result.node_details}, indent=2))
    else:
        print(format_table(result))
        if result.error:
            print(result.error, file=sys.stderr)
    return 0 if result.passed else 1


if __name__ == "__main__":
    sys.exit(main())
