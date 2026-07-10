#!/usr/bin/env python3
"""Validated ExecStart adapter for the per-user EngineOS Quake unit."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path


NAME = re.compile(r"^[A-Za-z0-9_.-]+$")
ALLOWED_ENV = {
    "DBUS_SESSION_BUS_ADDRESS", "DISPLAY", "HOME", "LANG", "LC_ALL",
    "LC_CTYPE", "LOGNAME", "USER", "WAYLAND_DISPLAY", "XDG_CONFIG_HOME",
    "XDG_DATA_DIRS", "XDG_DATA_HOME", "XDG_RUNTIME_DIR", "XDG_SESSION_TYPE",
    "XDG_STATE_HOME",
}


def fail(message: str) -> None:
    print(f"engineos-quake-service: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "engineos"
    request_path = Path(os.environ.get("ENGINEOS_QUAKE_LAUNCH_REQUEST", runtime / "quake-launch.json"))
    try:
        request = json.loads(request_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read launch request {request_path}: {exc}")
    if request.get("schema") != "engineos-quake-launch/v1":
        fail("unsupported launch request schema")
    allowed = {"schema", "map", "game", "smoke", "window", "fullscreen", "id1"}
    unknown = sorted(set(request) - allowed)
    if unknown:
        fail(f"unknown launch request field: {unknown[0]}")
    for option in ("smoke", "window", "fullscreen"):
        if not isinstance(request.get(option), bool):
            fail(f"{option} must be boolean")
    if request["window"] and request["fullscreen"]:
        fail("window and fullscreen modes are mutually exclusive")

    argv: list[str] = []
    for option in ("map", "game"):
        value = request.get(option)
        if value is None:
            continue
        if not isinstance(value, str) or not NAME.fullmatch(value):
            fail(f"invalid {option} value")
        argv.extend((f"--{option}", value))
    if request.get("smoke") is True:
        argv.append("--smoke")
    if request.get("window") is True:
        argv.append("--window")
    if request.get("fullscreen") is True:
        argv.append("--fullscreen")

    root = Path(os.environ.get("ENGINEOS_ROOT", "/usr"))
    source_runner = root / "engines" / "quakespasm" / "engineos" / "run.sh"
    runner = source_runner if source_runner.is_file() else Path("/usr/share/engineos/quake/run.sh")
    if not runner.is_file():
        fail(f"Quake runner is missing: {runner}")

    env = {key: value for key, value in os.environ.items() if key in ALLOWED_ENV or key.startswith("LC_")}
    env["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/bin"
    env["ENGINEOS_LOG_TEE"] = "false"
    env["ENGINEOS_LOG_DIR"] = str(Path.home() / ".local" / "state" / "engineos" / "logs")
    id1 = request.get("id1")
    if id1:
        if not isinstance(id1, str):
            fail("id1 must be a string path")
        id1_path = Path(str(id1)).expanduser().resolve()
        if not id1_path.is_dir():
            fail(f"Quake id1 directory is missing: {id1_path}")
        env["ENGINEOS_QUAKE_ID1"] = str(id1_path)
    os.execve(str(runner), [str(runner), *argv], env)


if __name__ == "__main__":
    main()
