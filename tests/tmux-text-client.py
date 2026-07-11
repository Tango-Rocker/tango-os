#!/usr/bin/env python3
"""Drive an ordinary tmux tty client for the native mux acceptance test."""

from __future__ import annotations

import argparse
import errno
import fcntl
import json
import os
import pathlib
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mux", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--ready", required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--initial-marker", required=True)
    parser.add_argument("--toggled-marker", required=True)
    parser.add_argument("--columns", type=int, default=50)
    parser.add_argument("--rows", type=int, default=20)
    parser.add_argument("--timeout", type=float, default=20.0)
    return parser.parse_args()


def write_capture(path: pathlib.Path, capture: bytearray) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(capture)
    temporary.replace(path)


def main() -> int:
    args = parse_args()
    output_path = pathlib.Path(args.output)
    ready_path = pathlib.Path(args.ready)
    release_path = pathlib.Path(args.release)
    capture = bytearray()
    deadline = time.monotonic() + args.timeout

    pid, master = pty.fork()
    if pid == 0:
        environment = os.environ.copy()
        environment.update(
            {
                "TERM": "xterm-256color",
                "XDG_RUNTIME_DIR": args.runtime,
                "TMUX_TMPDIR": args.runtime,
            }
        )
        os.execve(
            args.mux,
            [args.mux, "attach-session", "-t", args.target],
            environment,
        )

    fcntl.ioctl(
        master,
        termios.TIOCSWINSZ,
        struct.pack("HHHH", args.rows, args.columns, 0, 0),
    )
    os.set_blocking(master, False)

    def drain() -> bool:
        readable, _, _ = select.select([master], [], [], 0.05)
        if not readable:
            return True
        try:
            data = os.read(master, 65536)
        except OSError as error:
            if error.errno == errno.EIO:
                return False
            raise
        if not data:
            return False
        capture.extend(data)
        return True

    try:
        initial = args.initial_marker.encode()
        while initial not in capture:
            if time.monotonic() >= deadline:
                raise TimeoutError(f"initial status marker not rendered: {args.initial_marker}")
            if not drain():
                raise RuntimeError("tmux client exited before its initial status rendered")

        prompt_offset = len(capture)
        os.write(master, b"\x02:")
        prompt_marker = f"\x1b[{args.rows};1H:".encode()
        while prompt_marker not in capture[prompt_offset:]:
            if time.monotonic() >= deadline:
                raise TimeoutError("tmux command prompt did not render through the tty")
            if not drain():
                raise RuntimeError("tmux client exited before its command prompt rendered")
        os.write(master, b"set-option -g @engineos-text-client accepted\r")
        command_environment = os.environ.copy()
        command_environment.update(
            {"XDG_RUNTIME_DIR": args.runtime, "TMUX_TMPDIR": args.runtime}
        )
        while True:
            result = subprocess.run(
                [args.mux, "show-option", "-gv", "@engineos-text-client"],
                env=command_environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
                text=True,
            )
            if result.returncode == 0 and result.stdout.strip() == "accepted":
                break
            if time.monotonic() >= deadline:
                raise TimeoutError("tmux command prompt did not execute through the tty")
            if not drain():
                raise RuntimeError("tmux client exited while its command prompt ran")
        os.write(master, b"\x02")
        drain()
        os.write(master, b"v")
        toggled = args.toggled_marker.encode()
        while toggled not in capture:
            if time.monotonic() >= deadline:
                raise TimeoutError(f"toggled status marker not rendered: {args.toggled_marker}")
            if not drain():
                raise RuntimeError("tmux client exited before prefix+v completed")

        write_capture(output_path, capture)
        ready_payload = {
            "schema": "engineos/tmux-text-client-proof-v1",
            "pid": pid,
            "columns": args.columns,
            "rows": args.rows,
            "initial_marker": args.initial_marker,
            "toggled_marker": args.toggled_marker,
        }
        temporary_ready = ready_path.with_suffix(ready_path.suffix + ".tmp")
        temporary_ready.write_text(json.dumps(ready_payload) + "\n", encoding="utf-8")
        temporary_ready.replace(ready_path)

        while not release_path.exists():
            if time.monotonic() >= deadline:
                raise TimeoutError("release marker was not created")
            if not drain():
                raise RuntimeError("tmux client exited before the release marker")

        os.write(master, b"\x02d")
        while drain():
            if time.monotonic() >= deadline:
                break
        write_capture(output_path, capture)
    except Exception as error:  # noqa: BLE001 - command-line proof reports context
        write_capture(output_path, capture)
        print(f"tmux text-client proof failed: {error}", file=sys.stderr)
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
        return 1

    _, status = os.waitpid(pid, 0)
    if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        print(f"tmux text client exited abnormally: {status}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
