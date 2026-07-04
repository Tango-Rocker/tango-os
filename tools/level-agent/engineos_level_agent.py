#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import queue
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SCHEMA = "engineos-level-agent/v1"
DEFAULT_DGEN_ROOT = Path("/home/dev/quake-generator")
DEFAULT_WAD = Path("/usr/share/engineos/quake/engineos-dgen.wad")
DEFAULT_SOCKET_NAME = "level-agent.sock"


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def runtime_dir() -> Path:
    override = os.environ.get("ENGINEOS_LEVEL_AGENT_RUNTIME_DIR")
    if override:
        return Path(override)
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return Path(base) / "engineos"


def default_socket_path() -> Path:
    override = os.environ.get("ENGINEOS_LEVEL_AGENT_SOCKET")
    if override:
        return Path(override)
    return runtime_dir() / DEFAULT_SOCKET_NAME


def default_state_dir() -> Path:
    override = os.environ.get("ENGINEOS_LEVEL_AGENT_STATE_DIR")
    if override:
        return Path(override)
    if "ENGINEOS_ROOT" in os.environ:
        return Path(os.environ["ENGINEOS_ROOT"]) / "artifacts" / "level-agent"
    return Path.home() / ".local" / "state" / "engineos" / "level-agent"


def default_log_dir() -> Path:
    override = os.environ.get("ENGINEOS_LEVEL_AGENT_LOG_DIR")
    if override:
        return Path(override)
    if "ENGINEOS_ROOT" in os.environ:
        return Path(os.environ["ENGINEOS_ROOT"]) / "artifacts" / "logs"
    return Path.home() / ".local" / "state" / "engineos" / "logs"


def atomic_write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def tail_text(text: str, limit: int = 4000) -> str:
    if len(text) <= limit:
        return text
    return text[-limit:]


def safe_job_name(prompt: str) -> str:
    words = []
    for chunk in prompt.lower().replace("_", " ").split():
        clean = "".join(ch for ch in chunk if ch.isalnum())
        if clean:
            words.append(clean)
        if len(words) >= 5:
            break
    if not words:
        words = ["generated", "dungeon"]
    return "_".join(words)[:48]


@dataclass
class Settings:
    socket_path: Path
    state_dir: Path
    log_dir: Path
    dgen_root: Path
    wad_path: Path

    @classmethod
    def from_env(cls) -> "Settings":
        dgen_root = Path(
            os.environ.get("ENGINEOS_DGEN_ROOT")
            or os.environ.get("ENGINEOS_LEVEL_AGENT_DGEN_ROOT")
            or DEFAULT_DGEN_ROOT
        )
        wad_path = Path(os.environ.get("ENGINEOS_LEVEL_AGENT_WAD", str(DEFAULT_WAD)))
        return cls(
            socket_path=default_socket_path(),
            state_dir=default_state_dir(),
            log_dir=default_log_dir(),
            dgen_root=dgen_root,
            wad_path=wad_path,
        )


class CodexMCPError(RuntimeError):
    pass


class CodexMCPClient:
    def __init__(self, workspace: Path):
        command = os.environ.get("ENGINEOS_CODEX_MCP_COMMAND") or os.environ.get(
            "ENGINEOS_LEVEL_AGENT_CODEX_CMD", "codex mcp-server"
        )
        self.argv = shlex.split(command)
        self.workspace = workspace
        self.sandbox = os.environ.get("ENGINEOS_LEVEL_AGENT_CODEX_SANDBOX", "workspace-write")
        self.proc: subprocess.Popen[str] | None = None
        self.stderr_log: Any | None = None
        self.next_id = 1
        self.thread_id: str | None = None
        self.lock = threading.Lock()

    def close(self) -> None:
        proc = self.proc
        self.proc = None
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=3)
        if self.stderr_log:
            self.stderr_log.close()
            self.stderr_log = None

    def ensure_started(self) -> None:
        if self.proc and self.proc.poll() is None:
            return
        if not self.argv:
            raise CodexMCPError("empty Codex MCP command")
        if shutil.which(self.argv[0]) is None and "/" not in self.argv[0]:
            raise CodexMCPError(f"Codex MCP command not found on PATH: {self.argv[0]}")
        self.workspace.mkdir(parents=True, exist_ok=True)
        if self.stderr_log:
            self.stderr_log.close()
        self.stderr_log = (self.workspace / "codex-mcp.stderr.log").open("a", encoding="utf-8")
        self.proc = subprocess.Popen(
            self.argv,
            cwd=str(self.workspace),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr_log,
            text=True,
            bufsize=1,
        )
        self._request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "engineos-level-agent", "version": "0.1.0"},
            },
            timeout=30,
        )
        self._notify("notifications/initialized", {})

    def _send(self, payload: dict[str, Any]) -> None:
        if not self.proc or not self.proc.stdin:
            raise CodexMCPError("Codex MCP process is not running")
        self.proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
        self.proc.stdin.flush()

    def _read_json_line(self, timeout: int) -> dict[str, Any]:
        if not self.proc or not self.proc.stdout:
            raise CodexMCPError("Codex MCP process is not running")
        out: queue.Queue[str | None] = queue.Queue()

        def reader() -> None:
            try:
                out.put(self.proc.stdout.readline())
            except Exception:
                out.put(None)

        thread = threading.Thread(target=reader, daemon=True)
        thread.start()
        try:
            line = out.get(timeout=timeout)
        except queue.Empty as exc:
            raise CodexMCPError(f"Codex MCP request timed out after {timeout}s") from exc
        if line is None or line == "":
            raise CodexMCPError(f"Codex MCP process exited without a response; see {self.workspace / 'codex-mcp.stderr.log'}")
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            raise CodexMCPError(f"Codex MCP returned non-JSON output: {line.strip()}") from exc

    def _request(self, method: str, params: dict[str, Any], timeout: int = 600) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            remaining = max(1, int(deadline - time.monotonic()))
            if remaining <= 0:
                raise CodexMCPError(f"Codex MCP request timed out after {timeout}s")
            message = self._read_json_line(timeout=remaining)
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise CodexMCPError(f"Codex MCP {method} failed: {message['error']}")
            result = message.get("result")
            if not isinstance(result, dict):
                raise CodexMCPError(f"Codex MCP {method} returned an invalid result")
            return result

    def _notify(self, method: str, params: dict[str, Any]) -> None:
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def write_dungeon_spec(self, job: dict[str, Any], prompt: str) -> str:
        with self.lock:
            self.ensure_started()
            relative = f"jobs/{job['id']}/job.dungeon"
            author_prompt = build_codex_prompt(prompt, relative)
            if self.thread_id:
                result = self._request(
                    "tools/call",
                    {
                        "name": "codex-reply",
                        "arguments": {
                            "threadId": self.thread_id,
                            "prompt": author_prompt,
                        },
                    },
                    timeout=900,
                )
            else:
                result = self._request(
                    "tools/call",
                    {
                        "name": "codex",
                        "arguments": {
                            "prompt": author_prompt,
                            "cwd": str(self.workspace),
                            "approval-policy": "never",
                            "sandbox": self.sandbox,
                            "base-instructions": codex_base_instructions(),
                        },
                    },
                    timeout=900,
                )
            structured = result.get("structuredContent")
            if isinstance(structured, dict):
                thread_id = structured.get("threadId")
                if isinstance(thread_id, str) and thread_id:
                    self.thread_id = thread_id
                content = structured.get("content")
                if isinstance(content, str):
                    return content
            return json.dumps(result)


def codex_base_instructions() -> str:
    return (
        "You are the EngineOS Quake dungeon intent author. You must only create "
        "dungeon-spec/v2 files for the deterministic dgen generator. Do not edit "
        "Python source, EngineOS source, prefab manifests, recipes, package files, "
        "or generated BSP/MAP files. Do not invoke compilers. If the request is "
        "ambiguous, choose a small playable four-to-six beat dungeon using reviewed "
        "catalog tags."
    )


def build_codex_prompt(user_prompt: str, relative_output: str) -> str:
    return f"""Write one dungeon-spec/v2 intent file for dgen.

User request:
{user_prompt}

Output path, relative to the Codex workspace:
{relative_output}

Rules:
- Write only that .dungeon file.
- Use this syntax:
  dungeon <snake_case_id>
  version dungeon-spec/v2
  seed <integer>
  layout linear
  tag dynamic
  tag meaning
  beat <id> role <role> count 1 require [tag tag] meaning [beat beat]
- Keep the dungeon short enough for pr_smoke compile.
- Prefer reviewed tags such as entry, water, vertical, hub, combat, hazard, return.
- Do not write raw brush geometry or map text.
"""


class LevelAgent:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.settings.state_dir.mkdir(parents=True, exist_ok=True)
        self.settings.log_dir.mkdir(parents=True, exist_ok=True)
        self.codex_workspace = self.settings.state_dir / "codex-workspace"
        self.codex_workspace.mkdir(parents=True, exist_ok=True)
        self.codex = CodexMCPClient(self.codex_workspace)
        self.jobs_lock = threading.Lock()

    def job_path(self, job_id: str) -> Path:
        return self.settings.state_dir / "jobs" / job_id / "job.json"

    def load_job(self, job_id: str) -> dict[str, Any]:
        path = self.job_path(job_id)
        if not path.exists():
            raise FileNotFoundError(f"unknown level-agent job: {job_id}")
        return read_json(path)

    def save_job(self, job: dict[str, Any]) -> None:
        job["updated_at"] = now()
        atomic_write_json(self.job_path(job["id"]), job)

    def latest_job_id(self) -> str | None:
        jobs_dir = self.settings.state_dir / "jobs"
        if not jobs_dir.exists():
            return None
        candidates: list[tuple[float, str]] = []
        for path in jobs_dir.glob("*/job.json"):
            try:
                data = read_json(path)
            except (OSError, json.JSONDecodeError):
                continue
            candidates.append((path.stat().st_mtime, str(data.get("id", path.parent.name))))
        if not candidates:
            return None
        return sorted(candidates)[-1][1]

    def create_job(self, prompt: str) -> dict[str, Any]:
        job_id = f"lvl-{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}-{uuid.uuid4().hex[:8]}"
        map_name = safe_job_name(prompt)
        workspace = self.codex_workspace / "jobs" / job_id
        workspace.mkdir(parents=True, exist_ok=True)
        job = {
            "schema": SCHEMA,
            "id": job_id,
            "prompt": prompt,
            "state": "queued",
            "map_name": map_name,
            "workspace": str(workspace),
            "dungeon_path": str(workspace / "job.dungeon"),
            "map_path": str(workspace / f"{map_name}.map"),
            "bsp_path": str(workspace / f"{map_name}.bsp"),
            "log": "",
            "error": "",
            "created_at": now(),
            "updated_at": now(),
        }
        self.save_job(job)
        return job

    def build(self, prompt: str, *, wait: bool = False) -> dict[str, Any]:
        job = self.create_job(prompt)
        thread = threading.Thread(target=self._run_job, args=(job["id"],), daemon=True)
        thread.start()
        if wait:
            thread.join()
            return self.load_job(job["id"])
        return job

    def _set_state(self, job: dict[str, Any], state: str, *, log: str = "", error: str = "") -> None:
        job["state"] = state
        if log:
            job["log"] = tail_text((job.get("log") or "") + log)
        if error:
            job["error"] = error
        self.save_job(job)

    def _run_job(self, job_id: str) -> None:
        job = self.load_job(job_id)
        try:
            self._set_state(job, "planning")
            codex_output = self.codex.write_dungeon_spec(job, job["prompt"])
            job = self.load_job(job_id)
            job["codex_output"] = tail_text(codex_output)
            self.save_job(job)

            dungeon_path = Path(job["dungeon_path"])
            if not dungeon_path.exists():
                raise RuntimeError(f"Codex did not create dungeon spec: {dungeon_path}")
            text = dungeon_path.read_text(encoding="utf-8")
            if "version dungeon-spec/v2" not in text:
                raise RuntimeError("Codex output is not a dungeon-spec/v2 file")

            self._set_state(job, "building")
            completed = self.run_dgen(job)
            job = self.load_job(job_id)
            job["log"] = tail_text((job.get("log") or "") + completed.stdout + completed.stderr)
            if completed.returncode != 0:
                job["state"] = "failed"
                job["error"] = f"dgen build failed with exit {completed.returncode}"
                self.save_job(job)
                return
            bsp_path = Path(job["bsp_path"])
            if not bsp_path.exists():
                raise RuntimeError(f"dgen completed but BSP is missing: {bsp_path}")
            job["state"] = "accepted"
            job["error"] = ""
            self.save_job(job)
        except Exception as exc:
            job = self.load_job(job_id)
            job["state"] = "failed"
            job["error"] = str(exc)
            self.save_job(job)

    def dgen_argv(self) -> list[str]:
        override = os.environ.get("ENGINEOS_LEVEL_AGENT_DGEN_CMD")
        if override:
            return shlex.split(override)
        dgen = shutil.which("dgen")
        if dgen:
            return [dgen]
        return [sys.executable, "-m", "dgen.cli"]

    def run_dgen(self, job: dict[str, Any]) -> subprocess.CompletedProcess[str]:
        dgen_root = self.settings.dgen_root
        if not dgen_root.exists():
            raise RuntimeError(f"dgen root is missing: {dgen_root}")
        env = os.environ.copy()
        src = str(dgen_root / "src")
        env["PYTHONPATH"] = src + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
        argv = [
            *self.dgen_argv(),
            "build-dungeon",
            str(Path(job["dungeon_path"])),
            "--out",
            str(Path(job["map_path"])),
            "--compile-profile",
            "pr_smoke",
        ]
        if self.settings.wad_path.exists():
            argv.extend(["--wad", str(self.settings.wad_path)])
        return subprocess.run(
            argv,
            cwd=str(dgen_root),
            env=env,
            text=True,
            capture_output=True,
            check=False,
            timeout=int(os.environ.get("ENGINEOS_LEVEL_AGENT_DGEN_TIMEOUT", "600")),
        )

    def status_text(self, job_id: str | None = None) -> str:
        job_id = job_id or self.latest_job_id()
        if not job_id:
            return "level-agent: no jobs"
        job = self.load_job(job_id)
        parts = [
            f"job={job['id']}",
            f"state={job['state']}",
            f"map={job.get('map_name', '')}",
        ]
        if job.get("error"):
            parts.append(f"error={job['error']}")
        log = (job.get("log") or "").strip()
        if log:
            parts.append("log_tail=" + tail_text(log, 800).replace("\n", " | "))
        return " ".join(parts)

    def load(self, job_id: str | None = None) -> str:
        job_id = job_id or self.latest_job_id()
        if not job_id:
            return "level-agent: no jobs"
        job = self.load_job(job_id)
        if job.get("state") != "accepted":
            return f"level-agent: job {job_id} is not ready: state={job.get('state')} error={job.get('error', '')}"
        bsp_path = Path(job["bsp_path"])
        if not bsp_path.exists():
            return f"level-agent: accepted BSP is missing: {bsp_path}"
        id1 = resolve_quake_id1()
        if id1 is None:
            return "level-agent: Quake id1 path is not configured; run eos-assets prepare/check quake or set ENGINEOS_QUAKE_ID1"
        maps_dir = id1 / "maps"
        maps_dir.mkdir(parents=True, exist_ok=True)
        target = maps_dir / bsp_path.name
        shutil.copy2(bsp_path, target)
        launcher = shlex.split(os.environ.get("ENGINEOS_LEVEL_AGENT_EOS_APP", "eos-app"))
        launch = subprocess.run(
            [*launcher, "launch", "quake", "--map", job["map_name"]],
            text=True,
            capture_output=True,
            check=False,
            timeout=30,
        )
        job["state"] = "loaded" if launch.returncode == 0 else "load-failed"
        job["load_log"] = tail_text(launch.stdout + launch.stderr)
        if launch.returncode != 0:
            job["error"] = f"eos-app launch failed with exit {launch.returncode}: {job['load_log']}"
        self.save_job(job)
        if launch.returncode != 0:
            return f"level-agent: copied {target}, but launch failed: {job['load_log'].strip()}"
        return f"level-agent: loaded {job['map_name']} from {target}"


def resolve_quake_id1() -> Path | None:
    override = os.environ.get("ENGINEOS_QUAKE_ID1")
    if override:
        return Path(override)
    assets_cmd = os.environ.get("ENGINEOS_LEVEL_AGENT_ASSETS_CMD", "eos-assets")
    assets = shlex.split(assets_cmd)
    if assets:
        try:
            result = subprocess.run(
                [*assets, "path", "quake"],
                text=True,
                capture_output=True,
                check=False,
                timeout=10,
            )
            if result.returncode == 0:
                value = result.stdout.strip().splitlines()[-1]
                if value:
                    return Path(value)
        except (OSError, subprocess.TimeoutExpired):
            pass
    default = Path.home() / ".local" / "share" / "engineos" / "quake" / "id1"
    return default if default.exists() else None


def parse_request(line: str) -> dict[str, Any]:
    line = line.strip()
    if not line:
        return {"command": "status"}
    if line.startswith("{"):
        data = json.loads(line)
        if not isinstance(data, dict):
            raise ValueError("JSON request must be an object")
        return data
    parts = line.split("\t")
    command = parts[0]
    if command == "build":
        wait = len(parts) > 1 and parts[1] == "1"
        prompt = parts[2] if len(parts) > 2 else ""
        return {"command": "build", "prompt": prompt, "wait": wait}
    if command in {"status", "load"}:
        return {"command": command, "job_id": parts[1] if len(parts) > 1 and parts[1] else None}
    raise ValueError(f"unknown request command: {command}")


def handle_request(agent: LevelAgent, request: dict[str, Any]) -> str:
    command = request.get("command")
    if command == "build":
        prompt = str(request.get("prompt") or "").strip()
        if not prompt:
            return "level-agent: build requires a prompt"
        job = agent.build(prompt, wait=bool(request.get("wait")))
        if request.get("wait"):
            return agent.status_text(str(job["id"]))
        return f"level-agent: queued job={job['id']}"
    if command == "status":
        return agent.status_text(request.get("job_id"))
    if command == "load":
        return agent.load(request.get("job_id"))
    if command == "ping":
        return "level-agent: pong"
    return f"level-agent: unknown command {command}"


def serve(args: argparse.Namespace) -> int:
    settings = Settings.from_env()
    if args.socket:
        settings.socket_path = Path(args.socket)
    agent = LevelAgent(settings)
    settings.socket_path.parent.mkdir(parents=True, exist_ok=True)
    if settings.socket_path.exists():
        settings.socket_path.unlink()
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(settings.socket_path))
    server.listen(16)
    os.chmod(settings.socket_path, 0o660)
    print(f"engineos-level-agent listening on {settings.socket_path}", flush=True)

    def client_thread(conn: socket.socket) -> None:
        with conn:
            try:
                data = conn.recv(65536).decode("utf-8", errors="replace")
                response = handle_request(agent, parse_request(data))
            except Exception as exc:
                response = f"level-agent: error: {exc}"
            conn.sendall((response.rstrip() + "\n").encode("utf-8"))

    try:
        while True:
            conn, _ = server.accept()
            threading.Thread(target=client_thread, args=(conn,), daemon=True).start()
    finally:
        agent.codex.close()
        server.close()
        try:
            settings.socket_path.unlink()
        except FileNotFoundError:
            pass


def request_socket(request: dict[str, Any], socket_path: Path | None = None) -> str:
    path = socket_path or default_socket_path()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(float(os.environ.get("ENGINEOS_LEVEL_AGENT_CLIENT_TIMEOUT", "900")))
        client.connect(str(path))
        client.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8"))
        chunks: list[bytes] = []
        while True:
            chunk = client.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    return b"".join(chunks).decode("utf-8", errors="replace")


def run_inline_build(prompt: str) -> int:
    agent = LevelAgent(Settings.from_env())
    try:
        job = agent.build(prompt, wait=True)
        print(agent.status_text(str(job["id"])))
        return 0 if job.get("state") == "accepted" else 1
    finally:
        agent.codex.close()


def trenchbroom_setup(_: argparse.Namespace) -> int:
    home = Path.home()
    tb_root = Path(os.environ.get("ENGINEOS_TRENCHBROOM_USER_DIR", str(home / ".TrenchBroom")))
    game_dir = tb_root / "games" / "EngineOSQuake"
    game_dir.mkdir(parents=True, exist_ok=True)
    quake_root = Path(os.environ.get("ENGINEOS_QUAKE_ROOT", str(home / ".local" / "share" / "engineos" / "quake")))
    id1 = Path(os.environ["ENGINEOS_QUAKE_ID1"]) if os.environ.get("ENGINEOS_QUAKE_ID1") else resolve_quake_id1()
    if id1 is None:
        id1 = quake_root / "id1"
    wad = Path(os.environ.get("ENGINEOS_LEVEL_AGENT_WAD", str(DEFAULT_WAD)))

    (game_dir / "GameConfig.cfg").write_text(engineos_game_config(), encoding="utf-8")
    (game_dir / "CompilationProfiles.cfg").write_text(engineos_compile_profiles(str(id1), str(wad)), encoding="utf-8")
    (game_dir / "Engines.cfg").write_text(engineos_engines_profile(), encoding="utf-8")
    print(f"wrote TrenchBroom EngineOS Quake setup under {game_dir}")
    return 0


def engineos_game_config() -> str:
    return """{
  "version": 9,
  "name": "EngineOS Quake",
  "fileformats": [
    { "format": "Valve" },
    { "format": "Standard" }
  ],
  "filesystem": {
    "searchpath": "id1",
    "packageformat": { "extension": ".pak", "format": "idpak" }
  },
  "materials": {
    "root": ".",
    "extensions": [ ".wad" ],
    "property": "wad"
  },
  "entities": {
    "definitions": [ "Quake/Quake.fgd" ],
    "defaultcolor": "0.6 0.6 0.6 1.0",
    "scale": 1,
    "setDefaultProperties": true
  },
  "softMapBounds": "-4096 -4096 -4096 4096 4096 4096",
  "compilationTools": [
    { "name": "qbsp", "description": "ericw-tools qbsp" },
    { "name": "vis", "description": "ericw-tools vis" },
    { "name": "light", "description": "ericw-tools light" },
    { "name": "bsputil", "description": "ericw-tools bsputil" },
    { "name": "bspinfo", "description": "ericw-tools bspinfo" }
  ]
}
"""


def engineos_compile_profiles(id1: str, wad: str) -> str:
    return f"""{{
  "profiles": [
    {{
      "name": "EngineOS pr_smoke",
      "workdir": "${{MAP_DIR_PATH}}",
      "tasks": [
        {{ "type": "export", "target": "${{WORK_DIR_PATH}}/${{MAP_BASE_NAME}}-compile.map" }},
        {{ "type": "tool", "tool": "${{qbsp}}", "parameters": "-leaktest -bsp2 ${{MAP_BASE_NAME}}-compile.map", "treatNonZeroResultCodeAsError": true }},
        {{ "type": "tool", "tool": "${{vis}}", "parameters": "-fast ${{MAP_BASE_NAME}}-compile.bsp", "treatNonZeroResultCodeAsError": true }},
        {{ "type": "tool", "tool": "${{light}}", "parameters": "${{MAP_BASE_NAME}}-compile.bsp", "treatNonZeroResultCodeAsError": true }},
        {{ "type": "tool", "tool": "${{bsputil}}", "parameters": "--check ${{MAP_BASE_NAME}}-compile.bsp", "treatNonZeroResultCodeAsError": true }},
        {{ "type": "tool", "tool": "${{bspinfo}}", "parameters": "${{MAP_BASE_NAME}}-compile.bsp", "treatNonZeroResultCodeAsError": true }},
        {{ "type": "copy", "source": "${{WORK_DIR_PATH}}/${{MAP_BASE_NAME}}-compile.bsp", "target": "{id1}/maps" }}
      ]
    }}
  ],
  "materialCollections": [ "{wad}" ],
  "tools": {{
    "qbsp": "/usr/bin/qbsp",
    "vis": "/usr/bin/vis",
    "light": "/usr/bin/light",
    "bsputil": "/usr/bin/bsputil",
    "bspinfo": "/usr/bin/bspinfo"
  }}
}}
"""


def engineos_engines_profile() -> str:
    return """{
  "profiles": [
    {
      "name": "EngineOS QuakeSpasm",
      "path": "/usr/bin/eos-app",
      "parameters": "launch quake --map ${MAP_BASE_NAME}"
    }
  ]
}
"""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="engineos-level-agent")
    sub = parser.add_subparsers(dest="command", required=True)
    serve_parser = sub.add_parser("serve")
    serve_parser.add_argument("--socket")
    build_parser = sub.add_parser("build")
    build_parser.add_argument("prompt")
    build_parser.add_argument("--wait", action="store_true")
    build_parser.add_argument("--socket")
    status_parser = sub.add_parser("status")
    status_parser.add_argument("job_id", nargs="?")
    status_parser.add_argument("--socket")
    load_parser = sub.add_parser("load")
    load_parser.add_argument("job_id", nargs="?")
    load_parser.add_argument("--socket")
    sub.add_parser("trenchbroom-setup")

    args = parser.parse_args(argv)
    if args.command == "serve":
        return serve(args)
    if args.command == "build":
        request = {"command": "build", "prompt": args.prompt, "wait": args.wait}
        try:
            response = request_socket(request, Path(args.socket) if args.socket else None)
            print(response, end="")
            if args.wait and "state=accepted" not in response:
                return 1
            return 0
        except (FileNotFoundError, ConnectionRefusedError, socket.timeout, OSError):
            if args.wait:
                print("level-agent: sidecar not running; running one-shot build inline", file=sys.stderr)
                return run_inline_build(args.prompt)
            print("level-agent: sidecar is not running; start engineos-level-agent serve", file=sys.stderr)
            return 1
    if args.command == "status":
        try:
            print(request_socket({"command": "status", "job_id": args.job_id}, Path(args.socket) if args.socket else None), end="")
            return 0
        except (FileNotFoundError, ConnectionRefusedError, socket.timeout, OSError):
            agent = LevelAgent(Settings.from_env())
            print(agent.status_text(args.job_id))
            return 0
    if args.command == "load":
        try:
            response = request_socket({"command": "load", "job_id": args.job_id}, Path(args.socket) if args.socket else None)
            print(response, end="")
            return 0 if response.startswith("level-agent: loaded ") else 1
        except (FileNotFoundError, ConnectionRefusedError, socket.timeout, OSError):
            agent = LevelAgent(Settings.from_env())
            response = agent.load(args.job_id)
            print(response)
            return 0 if response.startswith("level-agent: loaded ") else 1
    if args.command == "trenchbroom-setup":
        return trenchbroom_setup(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
