#!/usr/bin/env python3
"""Codex stop helper for EngineOS handoff hygiene."""
from __future__ import annotations

from pathlib import Path


def main() -> int:
    root = Path.cwd().resolve()
    print("EngineOS stop check")
    if not (root / "AGENTS.md").exists():
        print("warning: AGENTS.md is not present in the current directory")
    print("If behavior changed, update CURRENT_STATUS.md with the proof command and outcome.")
    print("If a useful tangent appeared, capture it in BACKLOG.md and return to the current proof.")
    print("Narrow local check: ./tools/engineos/eos-test agent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
