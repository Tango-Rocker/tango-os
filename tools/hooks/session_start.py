#!/usr/bin/env python3
"""Codex session-start helper for EngineOS worktrees.

The hook prints a bounded orientation snapshot. It never reads secrets and it
does not execute project build commands.
"""
from __future__ import annotations

import subprocess
from pathlib import Path


def find_root() -> Path:
    path = Path.cwd().resolve()
    for candidate in (path, *path.parents):
        if (candidate / "AGENTS.md").exists() and (candidate / "tools" / "engineos" / "engineos").exists():
            return candidate
    return path


def git_status(root: Path) -> str:
    try:
        proc = subprocess.run(
            ["git", "status", "--short"],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
    except Exception as exc:
        return f"unavailable: {type(exc).__name__}: {exc}"
    return (proc.stdout or proc.stderr or "clean").strip()


def excerpt(path: Path, max_chars: int = 2500) -> str:
    if not path.exists():
        return f"missing: {path.name}"
    text = path.read_text(encoding="utf-8", errors="replace")
    return text[:max_chars].rstrip()


def main() -> int:
    root = find_root()
    print("EngineOS session context")
    print(f"root: {root}")
    print(f"git: {git_status(root)}")
    print()
    print("CURRENT_STATUS.md excerpt:")
    print(excerpt(root / "CURRENT_STATUS.md"))
    print()
    print("Next local proof starts with:")
    print("  ./tools/engineos/eos-doctor --vm")
    print("  ./tools/engineos/eos-test agent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
