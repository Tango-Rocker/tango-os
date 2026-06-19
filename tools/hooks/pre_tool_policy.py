#!/usr/bin/env python3
"""Conservative Codex PreToolUse policy helper for EngineOS.

The hook emits warnings for commands that commonly break the lab workflow. It
blocks only when CODEX_ENGINEOS_STRICT_HOOKS=1 is set.
"""
from __future__ import annotations

import os
import re
import sys


STRICT = os.environ.get("CODEX_ENGINEOS_STRICT_HOOKS") == "1"

WARN_PATTERNS = [
    (re.compile(r"\brm\s+-rf\s+/(?:\s|$)"), "recursive delete against /"),
    (re.compile(r"\bgit\s+reset\s+--hard\b"), "hard git reset"),
    (re.compile(r"\bgit\s+checkout\s+--\s+"), "destructive git checkout"),
    (re.compile(r"\bmkarchiso\b"), "direct mkarchiso; prefer eos-build iso"),
    (re.compile(r"\bpacman\s+-R"), "package removal"),
    (re.compile(r"\bchmod\s+-R\s+777\b"), "world-writable recursive chmod"),
    (re.compile(r"\bengineos\s+run\s+shell\s+--tty\b"), "TTY/KMS takeover"),
    (re.compile(r"\bengineos\s+usb\s+write\b(?!.*--dry-run)"), "USB write without --dry-run"),
    (re.compile(r"\bengineos\s+install\s+dev\b(?!.*--dry-run)"), "destructive dev install"),
]


def main() -> int:
    payload = sys.stdin.read()
    blocked = False
    for pattern, label in WARN_PATTERNS:
        if pattern.search(payload):
            print(f"EngineOS policy warning: {label}. Use the documented proof command or explicit user approval.")
            blocked = True
    if blocked and STRICT:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
