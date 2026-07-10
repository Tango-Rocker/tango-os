#!/usr/bin/env python3
"""Structured EngineOS role routing from the canonical TOML index."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tomllib
from pathlib import Path
from typing import Any


HIGH_RISK = (
    "rm -rf", "mkfs", "dd if=", "dd of=", "usb write", "format disk",
    "package removal", "pacman -r", "install dev", "sudo ",
)
MEDIUM_RISK = (
    "build", "compile", "service", "systemd", "install", "package",
    "runtime", "tty", "wayland", "window", "update",
)


def root_path() -> Path:
    override = os.environ.get("ENGINEOS_ROOT")
    if override:
        return Path(override).resolve()
    return Path(__file__).resolve().parents[2]


def load_index(root: Path) -> dict[str, Any]:
    path = Path(os.environ.get("ENGINEOS_AGENT_INDEX", root / ".agents/index.toml"))
    try:
        with path.open("rb") as handle:
            data = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise RuntimeError(f"cannot read agent index {path}: {exc}") from exc
    if data.get("schema") != "engineos-agent-index-v1":
        raise RuntimeError("agent index schema must be engineos-agent-index-v1")
    roles = data.get("roles")
    if not isinstance(roles, list) or not roles:
        raise RuntimeError("agent index has no roles")
    return data


def roles_by_id(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {str(role["id"]): role for role in data["roles"]}


def risk_for(request: str, default: str) -> str:
    lower = request.casefold()
    if any(token in lower for token in HIGH_RISK):
        return "high"
    if default == "medium" or any(token in lower for token in MEDIUM_RISK):
        return "medium"
    return "low"


def route(data: dict[str, Any], request: str) -> dict[str, Any]:
    lower = request.casefold()
    candidates: list[tuple[int, int, int, dict[str, Any], list[str]]] = []
    for role in data["roles"]:
        if role["id"] == "oracle":
            continue
        matches = [
            trigger for trigger in role.get("route_triggers", [])
            if str(trigger).casefold() in lower
        ]
        if not matches:
            continue
        candidates.append((
            int(role.get("priority", 0)),
            max(len(match) for match in matches),
            len(matches),
            role,
            matches,
        ))
    if candidates:
        _priority, _length, _count, selected, matches = max(
            candidates, key=lambda item: item[:3]
        )
        confidence = min(0.98, 0.76 + 0.04 * len(matches))
        reason = f"matched {', '.join(sorted(matches, key=len, reverse=True)[:3])}"
    else:
        selected = roles_by_id(data)["oracle"]
        confidence = 0.60
        reason = "broad or mixed request"
    return {
        "schema": "engineos-agent-route-v1",
        "role": selected["id"],
        "confidence": round(confidence, 2),
        "risk": risk_for(request, str(selected.get("risk_default", "low"))),
        "reason": reason,
        "proof": selected["proof"],
        "role_doc": selected["role_doc"],
        "skill": selected["skill"],
    }


def record_route(root: Path, result: dict[str, Any], request: str) -> None:
    observer = root / "tools/scripts/observability.sh"
    if not observer.is_file():
        return
    subprocess.run(
        [str(observer), "record", "--kind", "agent-route", "--source", "router",
         "--role", result["role"], "--confidence", str(result["confidence"]),
         "--risk", result["risk"], "--reason", "toml-route",
         "--proof", result["proof"], "--request", request],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def print_route(result: dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(result, separators=(",", ":")))
        return
    for key in ("role", "confidence", "risk", "reason", "proof", "role_doc", "skill"):
        print(f"{key}={result[key]}")


def parser() -> argparse.ArgumentParser:
    cli = argparse.ArgumentParser(prog="eos-agent")
    sub = cli.add_subparsers(dest="command", required=True)
    route_parser = sub.add_parser("route")
    route_parser.add_argument("--dry-run", action="store_true", help=argparse.SUPPRESS)
    route_parser.add_argument("--json", action="store_true")
    route_parser.add_argument("request", nargs="+")
    sub.add_parser("list")
    show = sub.add_parser("show")
    show.add_argument("role")
    sub.add_parser("capabilities")
    return cli


def main() -> int:
    args = parser().parse_args()
    root = root_path()
    data = load_index(root)
    indexed = roles_by_id(data)
    if args.command == "route":
        request = " ".join(args.request)
        result = route(data, request)
        print_route(result, args.json)
        record_route(root, result, request)
    elif args.command == "list":
        for role in sorted(indexed):
            print(role)
    elif args.command == "show":
        if args.role not in indexed:
            raise RuntimeError(f"unknown role: {args.role}")
        print(json.dumps(indexed[args.role], indent=2))
    elif args.command == "capabilities":
        print(json.dumps({"schema": data["schema"], "roles": data["roles"]}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"eos-agent: {exc}", file=sys.stderr)
        raise SystemExit(1)
