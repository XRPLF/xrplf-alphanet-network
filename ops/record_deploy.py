"""Append one deploy record to data/deploys.json, or print the last one."""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_DEPLOYS = Path(__file__).resolve().parent.parent / "data" / "deploys.json"


def load_deploys(path: Path) -> list[dict]:
    if not path.exists() or not path.read_text().strip():
        return []
    data = json.loads(path.read_text())
    if not isinstance(data, list):
        raise ValueError(f"{path} must hold a JSON list")
    return data


def record_deploy(path: Path, sha: str, image: str, genesis: bool, operator: str, date: str | None = None) -> dict:
    """Append {sha, image, genesis, date, operator} to the JSON list at path and return the record."""
    record = {
        "sha": sha,
        "image": image,
        "genesis": bool(genesis),
        "date": date or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "operator": operator,
    }
    deploys = load_deploys(path)
    deploys.append(record)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(deploys, indent=2) + "\n")
    return record


def format_record(record: dict | None) -> str:
    if record is None:
        return "last deploy: none recorded"
    kind = "genesis" if record["genesis"] else "rolling"
    return f"last deploy: {record['date']} {kind} sha={record['sha']} image={record['image']} by {record['operator']}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", default=str(DEFAULT_DEPLOYS))
    parser.add_argument("--show-last", action="store_true", help="print the last record and exit")
    parser.add_argument("--sha", default="")
    parser.add_argument("--image", default="")
    parser.add_argument("--genesis", type=int, choices=[0, 1], default=0)
    parser.add_argument("--operator", default=os.environ.get("USER", ""))
    args = parser.parse_args(argv)

    path = Path(args.file)
    if args.show_last:
        deploys = load_deploys(path)
        print(format_record(deploys[-1] if deploys else None))
        return 0
    if not args.sha or not args.image:
        print("--sha and --image are required to record a deploy", file=sys.stderr)
        return 2
    record = record_deploy(path, args.sha, args.image, bool(args.genesis), args.operator)
    print(f"recorded: {json.dumps(record)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
