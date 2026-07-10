#!/usr/bin/env python3
"""Validate the lean EngineOS role index, role docs, and role skills."""

from __future__ import annotations

import argparse
import json
import os
import sys
import tomllib
from pathlib import Path


REQUIRED_ROLE_HEADINGS = (
    "Responsibilities:", "Boundaries:", "Forbidden actions:",
    "Escalation:", "Proof commands:",
)
LEGACY_PATHS = (
    "tools/scripts/agent_dispatcher.sh",
    "tools/scripts/agent_metadata.sh",
    "tools/scripts/agent_profile.sh",
    "packages/engineos-tools/files/usr/lib/systemd/system/engineos-agent-dispatcher@.service",
    ".codex/hooks.example.json",
)


def check(root: Path) -> list[dict[str, str]]:
    issues: list[dict[str, str]] = []

    def issue(code: str, message: str) -> None:
        issues.append({"code": code, "message": message})

    index_path = root / ".agents/index.toml"
    try:
        with index_path.open("rb") as handle:
            data = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        issue("invalid-index", str(exc))
        return issues
    if data.get("schema") != "engineos-agent-index-v1":
        issue("index-schema", "expected engineos-agent-index-v1")
    roles = data.get("roles", [])
    ids = [role.get("id") for role in roles if isinstance(role, dict)]
    if len(ids) != len(set(ids)):
        issue("duplicate-role", "role ids must be unique")
    if "oracle" not in ids or "cleaner" not in ids:
        issue("required-role", "oracle and cleaner roles are required")
    for role in roles:
        if not isinstance(role, dict):
            issue("invalid-role", "role records must be TOML tables")
            continue
        role_id = str(role.get("id", ""))
        for field in ("display_name", "role_doc", "skill", "proof", "route_triggers"):
            if not role.get(field):
                issue("missing-field", f"{role_id}: missing {field}")
        for removed in ("profile", "opencode_wrapper"):
            if removed in role:
                issue("legacy-field", f"{role_id}: remove {removed}")
        role_doc = root / str(role.get("role_doc", ""))
        skill = root / str(role.get("skill", ""))
        if not role_doc.is_file():
            issue("missing-role-doc", f"{role_id}: {role_doc.relative_to(root)}")
        else:
            text = role_doc.read_text(encoding="utf-8")
            for heading in REQUIRED_ROLE_HEADINGS:
                if heading not in text:
                    issue("role-heading", f"{role_id}: missing {heading}")
        if not skill.is_file():
            issue("missing-skill", f"{role_id}: {skill.relative_to(root)}")
        else:
            text = skill.read_text(encoding="utf-8")
            if not text.startswith("---\n") or f"name: {role_id}\n" not in text:
                issue("skill-frontmatter", f"{role_id}: invalid skill frontmatter")
    indexed = set(ids)
    for role_doc in (root / ".agents/roles").glob("*/AGENTS.md"):
        if role_doc.parent.name not in indexed:
            issue("unindexed-role", role_doc.parent.name)
    for path in LEGACY_PATHS:
        if (root / path).exists():
            issue("legacy-harness", f"remove {path}")
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(prog="eos-agent hygiene")
    parser.add_argument("command", nargs="?", default="check", choices=("check",))
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--fix-plan", action="store_true")
    args = parser.parse_args()
    root = Path(os.environ.get("ENGINEOS_AGENT_HYGIENE_ROOT", os.environ.get("ENGINEOS_ROOT", Path(__file__).resolve().parents[2]))).resolve()
    issues = check(root)
    if args.json:
        print(json.dumps({"schema": "engineos-agent-hygiene-v1", "status": "fail" if issues else "pass", "issues": issues}, separators=(",", ":")))
    elif issues:
        print(f"Agent hygiene check failed: {len(issues)} issue(s)")
        for item in issues:
            print(f"FAIL {item['code']}: {item['message']}")
        if args.fix_plan:
            print("\nFix the indexed path or remove the legacy harness file, then rerun eos-agent hygiene check.")
    else:
        print("Agent hygiene check passed")
    return 1 if issues else 0


if __name__ == "__main__":
    raise SystemExit(main())
