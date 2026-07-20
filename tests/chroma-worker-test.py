#!/usr/bin/env python3
"""Integration proof for the durable Chroma worker queue."""

import base64
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "tools/engineos/chroma-worker"
PROTOCOL = "chroma-worker/v1"
PNG = base64.b64encode(b"\x89PNG\r\n\x1a\nengineos-test").decode()


def call(path: Path, operation: str, **fields: object) -> dict:
    deadline = time.time() + 5
    while True:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.connect(str(path))
                client.sendall(
                    json.dumps(
                        {"protocol": PROTOCOL, "op": operation, **fields}
                    ).encode()
                    + b"\n"
                )
                response = b""
                while b"\n" not in response:
                    response += client.recv(65536)
            result = json.loads(response)
            if not result["ok"]:
                raise RuntimeError(result["error"])
            return result
        except (FileNotFoundError, ConnectionRefusedError):
            if time.time() >= deadline:
                raise
            time.sleep(0.05)


def wait_status(path: Path, job_id: int, expected: str, timeout: float = 10) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        snapshot = call(path, "snapshot")
        record = next(job for job in snapshot["jobs"] if job["id"] == job_id)
        if record["status"] == expected:
            return record
        time.sleep(0.05)
    raise AssertionError(f"job {job_id} did not reach {expected}")


def start_worker(environment: dict[str, str]) -> subprocess.Popen:
    return subprocess.Popen(
        [sys.executable, str(WORKER), "serve"],
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def stop(process: subprocess.Popen) -> None:
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=10)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="engineos-chroma-worker-") as raw:
        fixture = Path(raw)
        server = fixture / "fake-server"
        server.write_text(
            textwrap.dedent(
                f"""\
                #!{sys.executable}
                import argparse, json, time
                from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
                parser = argparse.ArgumentParser()
                parser.add_argument("--listen-ip")
                parser.add_argument("--listen-port", type=int)
                args, _ = parser.parse_known_args()
                class Handler(BaseHTTPRequestHandler):
                    def do_GET(self):
                        self.send_response(200); self.end_headers()
                    def do_POST(self):
                        length = int(self.headers.get("Content-Length", "0"))
                        body = json.loads(self.rfile.read(length))
                        if body.get("prompt") in ("delay", "cancel"):
                            time.sleep(1.5)
                        payload = json.dumps({{"images": ["{PNG}"] * body["batch_size"]}}).encode()
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(payload)))
                        self.end_headers()
                        self.wfile.write(payload)
                    def log_message(self, *_args):
                        pass
                ThreadingHTTPServer((args.listen_ip, args.listen_port), Handler).serve_forever()
                """
            ),
            encoding="utf-8",
        )
        server.chmod(0o755)
        runtime = fixture / "run"
        state = fixture / "state"
        output = fixture / "output"
        runtime.mkdir()
        environment = os.environ.copy()
        environment.update(
            {
                "XDG_RUNTIME_DIR": str(runtime),
                "XDG_STATE_HOME": str(state),
                "CHROMA_WORKER_LEGACY_DB": str(fixture / "missing.sqlite3"),
            }
        )
        socket_path = runtime / "chroma/worker.sock"
        settings = {
            "Server": str(server),
            "ServerPort": free_port(),
            "DiffusionModel": "model",
            "Vae": "vae",
            "T5xxl": "t5",
            "OutDir": str(output),
            "Width": 16,
            "Height": 16,
            "Steps": 1,
            "CfgScale": 1.0,
            "Seed": 1,
            "BatchCount": 1,
            "SamplingMethod": "euler",
            "MainBackend": "CPU",
            "DiffusionBackend": "CPU",
            "ClipBackend": "CPU",
            "VaeBackend": "CPU",
            "OffloadToCpu": False,
            "VaeTiling": False,
            "ChromaDisableDitMask": False,
        }
        worker = start_worker(environment)
        try:
            first = call(
                socket_path,
                "enqueue",
                payload={
                    "settings": settings,
                    "prompt": "first",
                    "negative_prompt": "",
                },
            )
            record = wait_status(socket_path, first["job_id"], "completed")
            assert Path(record["outputs"][0]).read_bytes().startswith(b"\x89PNG")

            call(socket_path, "pause")
            paused = call(
                socket_path,
                "enqueue",
                payload={
                    "settings": settings,
                    "prompt": "paused",
                    "negative_prompt": "",
                },
            )
            time.sleep(0.2)
            wait_status(socket_path, paused["job_id"], "queued")
            call(socket_path, "resume")
            wait_status(socket_path, paused["job_id"], "completed")

            recovering = call(
                socket_path,
                "enqueue",
                payload={
                    "settings": settings,
                    "prompt": "delay",
                    "negative_prompt": "",
                },
            )
            wait_status(socket_path, recovering["job_id"], "running")
            stop(worker)
            worker = start_worker(environment)
            wait_status(socket_path, recovering["job_id"], "completed", timeout=15)

            cancelling = call(
                socket_path,
                "enqueue",
                payload={
                    "settings": settings,
                    "prompt": "cancel",
                    "negative_prompt": "",
                },
            )
            wait_status(socket_path, cancelling["job_id"], "running")
            call(socket_path, "cancel", job_id=cancelling["job_id"])
            wait_status(socket_path, cancelling["job_id"], "cancelled")

            snapshot = call(socket_path, "snapshot")
            statuses = {job["status"] for job in snapshot["jobs"]}
            assert {"completed", "cancelled"} <= statuses
            assert socket_path.stat().st_mode & 0o777 == 0o600

            unknown_port = free_port()
            unknown = subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "http.server",
                    str(unknown_port),
                    "--bind",
                    "127.0.0.1",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                time.sleep(0.2)
                unknown_settings = {**settings, "ServerPort": unknown_port}
                rejected = call(
                    socket_path,
                    "enqueue",
                    payload={
                        "settings": unknown_settings,
                        "prompt": "unknown-port",
                        "negative_prompt": "",
                    },
                )
                failed = wait_status(
                    socket_path, rejected["job_id"], "failed"
                )
                assert failed["attempts"] == 3
                assert "unknown process" in failed["error"]
            finally:
                unknown.terminate()
                unknown.wait(timeout=5)
        finally:
            stop(worker)
            if worker.stderr:
                errors = worker.stderr.read()
                if errors:
                    print(errors, file=sys.stderr)
    print("durable Chroma worker test passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
