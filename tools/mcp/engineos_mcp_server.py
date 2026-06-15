#!/usr/bin/env python3
"""Dependency-light EngineOS MCP server.

The server speaks line-delimited JSON-RPC over stdio and exposes a bounded tool
surface around ./tools/engineos/engineos. It intentionally does not provide an
arbitrary shell.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

SERVER_NAME = "engineos"
SERVER_VERSION = "0.2.0"

SAFE_PACKAGE_RE = re.compile(r"^[a-zA-Z0-9@._+:-]+$")
SAFE_DOCS = {
    "current_status": "CURRENT_STATUS.md",
    "roadmap": "ROADMAP.md",
    "backlog": "BACKLOG.md",
    "agents": "AGENTS.md",
    "agent_harness": "docs/agent-harness.md",
    "agent_workflow": "docs/agent-workflow.md",
    "agent_lsp": "docs/agent-lsp.md",
    "agent_pack": "docs/engineos-agent-pack.md",
    "dev_instance": "docs/dev-instance.md",
}


@dataclass
class CommandResult:
    command: list[str]
    exit_code: int | None
    stdout: str
    stderr: str
    timed_out: bool = False

    @property
    def ok(self) -> bool:
        return self.exit_code == 0 and not self.timed_out

    def payload(self, max_chars: int = 20000) -> dict[str, Any]:
        return {
            "command": self.command,
            "exit_code": self.exit_code,
            "timed_out": self.timed_out,
            "stdout": self.stdout[-max_chars:],
            "stderr": self.stderr[-max_chars:],
        }


def repo_root() -> Path:
    env_root = os.environ.get("ENGINEOS_REPO") or os.environ.get("ENGINEOS_PROJECT_ROOT")
    if env_root:
        return Path(env_root).expanduser().resolve()
    return Path(__file__).resolve().parents[2]


def engineos_argv(extra_args: list[str] | None = None) -> list[str]:
    extra_args = extra_args or []
    env_bin = os.environ.get("ENGINEOS_BIN")
    if env_bin:
        return [*shlex.split(env_bin), *extra_args]

    path_bin = shutil.which("engineos")
    if path_bin:
        return [path_bin, *extra_args]

    root = repo_root()
    script = root / "tools" / "engineos" / "engineos"
    if os.name == "nt":
        bash = shutil.which("bash") or shutil.which("bash.exe")
        if bash and script.exists():
            command = "exec ./tools/engineos/engineos"
            if extra_args:
                command = f"{command} {' '.join(shlex.quote(arg) for arg in extra_args)}"
            return [bash, "-lc", command]
    return [str(script), *extra_args]


def run_cmd(
    cmd: list[str],
    timeout_sec: int = 45,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> CommandResult:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd or repo_root()),
            env=merged_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=max(1, int(timeout_sec)),
            check=False,
        )
        return CommandResult(cmd, proc.returncode, proc.stdout or "", proc.stderr or "")
    except subprocess.TimeoutExpired as exc:
        return CommandResult(
            cmd,
            124,
            exc.stdout if isinstance(exc.stdout, str) else "",
            exc.stderr if isinstance(exc.stderr, str) else "",
            timed_out=True,
        )
    except OSError as exc:
        return CommandResult(cmd, 127, "", f"{type(exc).__name__}: {exc}")


def ecmd(*args: str, timeout_sec: int = 45, env: dict[str, str] | None = None) -> CommandResult:
    return run_cmd(engineos_argv(list(args)), timeout_sec=timeout_sec, env=env)


def text_result(text: str, is_error: bool = False) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def json_text(obj: Any) -> str:
    return json.dumps(obj, indent=2, ensure_ascii=False)


def command_result(res: CommandResult) -> dict[str, Any]:
    return text_result(json_text(res.payload()), is_error=not res.ok)


def arg_str(args: dict[str, Any], name: str, default: str = "") -> str:
    value = args.get(name, default)
    if value is None:
        return default
    return str(value)


def arg_bool(args: dict[str, Any], name: str, default: bool = False) -> bool:
    value = args.get(name, default)
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() in {"1", "true", "yes", "on"}
    return bool(value)


def arg_int(args: dict[str, Any], name: str, default: int, minimum: int = 1, maximum: int = 3600) -> int:
    try:
        value = int(args.get(name, default))
    except (TypeError, ValueError):
        value = default
    return max(minimum, min(maximum, value))


def schema(properties: dict[str, Any], required: list[str] | None = None) -> dict[str, Any]:
    return {"type": "object", "properties": properties, "required": required or []}


def invalid(message: str) -> dict[str, Any]:
    return text_result(message, True)


def safe_package(name: str) -> bool:
    return bool(SAFE_PACKAGE_RE.match(name))


def tool_project_status(args: dict[str, Any]) -> dict[str, Any]:
    root = repo_root()
    skills_dir = root / ".agents" / "skills"
    git_status = run_cmd(["git", "status", "--short"], timeout_sec=10, cwd=root)
    git_head = run_cmd(["git", "rev-parse", "--short", "HEAD"], timeout_sec=10, cwd=root)
    skills = []
    if skills_dir.exists():
        skills = sorted(str(path.relative_to(root)) for path in skills_dir.glob("*/SKILL.md"))
    payload = {
        "server": {"name": SERVER_NAME, "version": SERVER_VERSION},
        "repo_root": str(root),
        "engineos_argv": engineos_argv(),
        "engineos_cli_exists": (root / "tools" / "engineos" / "engineos").exists() or shutil.which("engineos") is not None,
        "git_head": git_head.stdout.strip(),
        "git_status_short": git_status.stdout,
        "has_codex_config": (root / ".codex" / "config.toml").exists(),
        "has_hooks": (root / "tools" / "hooks").exists(),
        "skills": skills,
        "docs": {name: (root / rel).exists() for name, rel in SAFE_DOCS.items()},
    }
    return text_result(json_text(payload), is_error=not git_status.ok)


def tool_read_status(args: dict[str, Any]) -> dict[str, Any]:
    name = arg_str(args, "name", "current_status")
    max_chars = arg_int(args, "max_chars", 12000, minimum=1000, maximum=40000)
    if name not in SAFE_DOCS:
        return invalid(f"unknown status document: {name}")
    path = repo_root() / SAFE_DOCS[name]
    if not path.exists():
        return invalid(f"missing document: {SAFE_DOCS[name]}")
    return text_result(path.read_text(encoding="utf-8", errors="replace")[:max_chars])


def tool_doctor(args: dict[str, Any]) -> dict[str, Any]:
    mode = arg_str(args, "mode", "mock")
    timeout = arg_int(args, "timeout_sec", 45, maximum=300)
    cmd = ["doctor"]
    if mode == "mock":
        cmd.append("--mock")
    elif mode == "vm":
        cmd.append("--vm")
    elif mode == "bare-metal":
        cmd.append("--bare-metal")
    elif mode == "host":
        pass
    else:
        return invalid("mode must be mock, vm, bare-metal, or host")
    return command_result(ecmd(*cmd, timeout_sec=timeout))


def tool_logs(args: dict[str, Any]) -> dict[str, Any]:
    target = arg_str(args, "target", "all")
    source = arg_str(args, "source", "auto")
    lines = arg_int(args, "lines", 200, maximum=2000)
    if target not in {"shell", "app", "engine", "runtime", "live-setup", "doctor", "boot", "all"}:
        return invalid("target must be shell, app, engine, runtime, live-setup, doctor, boot, or all")
    if source not in {"auto", "files", "journal"}:
        return invalid("source must be auto, files, or journal")
    cmd = ["logs", target, "--last", str(lines)]
    if source != "auto":
        cmd.append(f"--{source}")
    return command_result(ecmd(*cmd, timeout_sec=30))


def tool_app_status(args: dict[str, Any]) -> dict[str, Any]:
    want_json = arg_bool(args, "json", True)
    cmd = ["app", "status"]
    if want_json:
        cmd.append("--json")
    return command_result(ecmd(*cmd, timeout_sec=20))


def tool_app_manifest(args: dict[str, Any]) -> dict[str, Any]:
    action = arg_str(args, "action", "validate")
    if action not in {"path", "show", "validate"}:
        return invalid("action must be path, show, or validate")
    return command_result(ecmd("app", "manifest", action, timeout_sec=30))


def tool_assets(args: dict[str, Any]) -> dict[str, Any]:
    action = arg_str(args, "action", "check")
    target = arg_str(args, "target", "quake")
    if action not in {"check", "explain", "path"}:
        return invalid("action must be check, explain, or path")
    if target != "quake":
        return invalid("target must be quake")
    return command_result(ecmd("assets", action, target, timeout_sec=30))


def tool_preflight(args: dict[str, Any]) -> dict[str, Any]:
    scope = arg_str(args, "scope", "all")
    if scope not in {"all", "repo", "iso", "scripts"}:
        return invalid("scope must be all, repo, iso, or scripts")
    cmd = ["preflight", scope]
    package = arg_str(args, "package", "")
    profile = arg_str(args, "profile", "")
    if package:
        if not safe_package(package):
            return invalid("invalid package name")
        cmd.extend(["--package", package])
    if profile:
        if profile not in {"enginedev", "engineruntime"}:
            return invalid("profile must be enginedev or engineruntime")
        cmd.extend(["--profile", profile])
    return command_result(ecmd(*cmd, timeout_sec=arg_int(args, "timeout_sec", 120, maximum=600)))


def tool_validate(args: dict[str, Any]) -> dict[str, Any]:
    target = arg_str(args, "target", "repo")
    cmd = ["validate"]
    if target == "builder":
        cmd.append("builder")
        if arg_bool(args, "mock", True):
            cmd.append("--mock")
    elif target == "repo":
        cmd.append("repo")
        if arg_bool(args, "dry_run", True):
            cmd.append("--dry-run")
        elif arg_bool(args, "mock", False):
            cmd.append("--mock")
    elif target == "engine":
        engine = arg_str(args, "engine", "quake")
        if engine != "quake":
            return invalid("engine must be quake")
        cmd.extend(["engine", engine])
        if arg_bool(args, "mock", False):
            cmd.append("--mock")
    elif target == "shell":
        cmd.append("shell")
        if arg_bool(args, "mock", False):
            cmd.append("--mock")
    elif target == "boot":
        mode = arg_str(args, "mode", "vm")
        if mode not in {"vm", "runtime", "bare-metal"}:
            return invalid("mode must be vm, runtime, or bare-metal")
        cmd.extend(["boot", f"--{mode}"])
    else:
        return invalid("target must be builder, repo, engine, shell, or boot")
    return command_result(ecmd(*cmd, timeout_sec=arg_int(args, "timeout_sec", 120, maximum=900)))


def tool_test(args: dict[str, Any]) -> dict[str, Any]:
    scope = arg_str(args, "scope", "smoke")
    allowed = {
        "smoke", "all", "agent", "mcp", "compositor", "shell-actions", "engine-runner-env",
        "app", "assets", "reliability", "logs", "artifacts", "release", "terminal", "vm",
        "usb", "install", "proof", "installed-preflight", "builder-handoff", "builder-doctor",
        "post-first-deploy", "builder", "bootstrap", "repo", "boot", "engine", "shell", "input",
        "outputs", "render",
    }
    if scope not in allowed:
        return invalid("unknown test scope")
    cmd = ["test", scope]
    if scope == "compositor":
        mode = arg_str(args, "mode", "headless")
        if mode not in {"headless", "nested"}:
            return invalid("compositor mode must be headless or nested")
        cmd.append(f"--{mode}")
    elif scope == "render":
        cmd.append("--smoke")
    elif scope == "outputs":
        mode = arg_str(args, "mode", "single")
        if mode not in {"single", "dual-static"}:
            return invalid("outputs mode must be single or dual-static")
        cmd.append(f"--{mode}")
    return command_result(ecmd(*cmd, timeout_sec=arg_int(args, "timeout_sec", 120, maximum=1800)))


def tool_build_repo(args: dict[str, Any]) -> dict[str, Any]:
    cmd = ["build", "repo"]
    package = arg_str(args, "package", "")
    if arg_bool(args, "dry_run", True):
        cmd.append("--dry-run")
    if package:
        if not safe_package(package):
            return invalid("invalid package name")
        cmd.extend(["--package", package])
    return command_result(ecmd(*cmd, timeout_sec=arg_int(args, "timeout_sec", 180, maximum=3600)))


def tool_build_iso(args: dict[str, Any]) -> dict[str, Any]:
    profile = arg_str(args, "profile", "enginedev")
    if profile not in {"enginedev", "engineruntime"}:
        return invalid("profile must be enginedev or engineruntime")
    cmd = ["build", "iso", profile]
    if arg_bool(args, "fast", False):
        cmd.append("--fast")
    if arg_bool(args, "dry_run", True):
        cmd.append("--dry-run")
    return command_result(ecmd(*cmd, timeout_sec=arg_int(args, "timeout_sec", 600, maximum=7200)))


def tool_build_shell(args: dict[str, Any]) -> dict[str, Any]:
    cmd = ["build", "shell"]
    if arg_bool(args, "dry_run", True):
        cmd.append("--dry-run")
    return command_result(ecmd(*cmd, timeout_sec=arg_int(args, "timeout_sec", 120, maximum=1800)))


def tool_package(args: dict[str, Any]) -> dict[str, Any]:
    name = arg_str(args, "name", "")
    if not name or not safe_package(name):
        return invalid("valid package name is required")
    cmd = ["package", name]
    if arg_bool(args, "dry_run", True):
        cmd.append("--dry-run")
    return command_result(ecmd(*cmd, timeout_sec=arg_int(args, "timeout_sec", 300, maximum=3600)))


def tool_proof(args: dict[str, Any]) -> dict[str, Any]:
    proof = arg_str(args, "proof", "launchpad")
    if proof not in {"build-lab", "release-candidate", "hardware-ready", "booted-iso", "shell-launch", "launchpad"}:
        return invalid("unknown proof")
    cmd = ["proof", proof]
    mode = arg_str(args, "mode", "")
    if proof in {"booted-iso", "shell-launch", "launchpad"}:
        if not mode:
            mode = "runtime" if proof == "launchpad" else "vm"
        if mode not in {"vm", "runtime", "bare-metal"}:
            return invalid("mode must be vm, runtime, or bare-metal")
        cmd.append(f"--{mode}")
    profile = arg_str(args, "profile", "")
    if proof in {"build-lab", "hardware-ready"} and profile:
        if profile not in {"enginedev", "engineruntime"}:
            return invalid("profile must be enginedev or engineruntime")
        cmd.extend(["--profile", profile])
    device = arg_str(args, "device", "")
    if proof == "hardware-ready" and device:
        cmd.extend(["--device", device])
    if arg_bool(args, "dry_run", True):
        cmd.append("--dry-run")
    return command_result(ecmd(*cmd, timeout_sec=arg_int(args, "timeout_sec", 180, maximum=7200)))


def tool_run_shell_smoke(args: dict[str, Any]) -> dict[str, Any]:
    mode = arg_str(args, "mode", "headless")
    if mode not in {"headless", "nested"}:
        return invalid("mode must be headless or nested")
    return command_result(
        ecmd("run", "shell", f"--{mode}", timeout_sec=arg_int(args, "timeout_sec", 60, maximum=300), env={"ENGINEOS_SHELL_SMOKE": "true"})
    )


def tool_run_quake_smoke(args: dict[str, Any]) -> dict[str, Any]:
    return command_result(ecmd("run", "quake", "--smoke", timeout_sec=arg_int(args, "timeout_sec", 90, maximum=300)))


def tool_engine(args: dict[str, Any]) -> dict[str, Any]:
    action = arg_str(args, "action", "status")
    if action not in {"status", "launch", "quit", "restart"}:
        return invalid("action must be status, launch, quit, or restart")
    cmd = ["engine", action]
    if action in {"launch", "restart"}:
        target = arg_str(args, "target", "quake")
        if target != "quake":
            return invalid("target must be quake")
        cmd.append(target)
        if arg_bool(args, "smoke", True):
            cmd.append("--smoke")
    return command_result(ecmd(*cmd, timeout_sec=arg_int(args, "timeout_sec", 60, maximum=300)))


def tool_capture_frame(args: dict[str, Any]) -> dict[str, Any]:
    tool = arg_str(args, "tool", "auto")
    if tool not in {"auto", "grim", "import", "metadata"}:
        return invalid("tool must be auto, grim, import, or metadata")
    target = arg_str(args, "target", "shell")
    if target != "shell":
        return invalid("target must be shell")
    return command_result(ecmd("capture", "frame", "--target", target, "--tool", tool, timeout_sec=45))


def tool_crash_bundle(args: dict[str, Any]) -> dict[str, Any]:
    mode = arg_str(args, "mode", "host")
    cmd = ["crash-bundle"]
    if mode == "vm":
        cmd.append("--vm")
    elif mode == "runtime":
        cmd.append("--runtime")
    elif mode == "bare-metal":
        cmd.append("--bare-metal")
    elif mode == "host":
        pass
    else:
        return invalid("mode must be host, vm, runtime, or bare-metal")
    return command_result(ecmd(*cmd, timeout_sec=arg_int(args, "timeout_sec", 120, maximum=900)))


TOOLS: dict[str, tuple[str, dict[str, Any], Callable[[dict[str, Any]], dict[str, Any]]]] = {
    "project_status": (
        "Read repo root, git status, known docs, skills, Codex config, and EngineOS CLI path.",
        schema({}),
        tool_project_status,
    ),
    "read_status": (
        "Read a bounded project status/planning document.",
        schema({"name": {"type": "string", "default": "current_status"}, "max_chars": {"type": "integer", "default": 12000}}),
        tool_read_status,
    ),
    "doctor": (
        "Run engineos doctor. Defaults to --mock for local safety.",
        schema({"mode": {"type": "string", "enum": ["mock", "vm", "bare-metal", "host"], "default": "mock"}, "timeout_sec": {"type": "integer", "default": 45}}),
        tool_doctor,
    ),
    "logs": (
        "Fetch bounded EngineOS logs.",
        schema({"target": {"type": "string", "default": "all"}, "lines": {"type": "integer", "default": 200}, "source": {"type": "string", "default": "auto"}}),
        tool_logs,
    ),
    "app_status": ("Read launchpad/app status.", schema({"json": {"type": "boolean", "default": True}}), tool_app_status),
    "app_manifest": ("Show or validate the app manifest.", schema({"action": {"type": "string", "default": "validate"}}), tool_app_manifest),
    "assets": ("Check, explain, or locate Quake assets.", schema({"action": {"type": "string", "default": "check"}, "target": {"type": "string", "default": "quake"}}), tool_assets),
    "preflight": ("Run EngineOS preflight.", schema({"scope": {"type": "string", "default": "all"}, "package": {"type": "string"}, "profile": {"type": "string"}, "timeout_sec": {"type": "integer", "default": 120}}), tool_preflight),
    "validate": ("Run EngineOS validation wrappers.", schema({"target": {"type": "string", "default": "repo"}, "mode": {"type": "string"}, "engine": {"type": "string"}, "mock": {"type": "boolean"}, "dry_run": {"type": "boolean", "default": True}, "timeout_sec": {"type": "integer", "default": 120}}), tool_validate),
    "test": ("Run a focused EngineOS test scope.", schema({"scope": {"type": "string", "default": "smoke"}, "mode": {"type": "string"}, "timeout_sec": {"type": "integer", "default": 120}}), tool_test),
    "build_repo": ("Build or dry-run the local package repo.", schema({"dry_run": {"type": "boolean", "default": True}, "package": {"type": "string"}, "timeout_sec": {"type": "integer", "default": 180}}), tool_build_repo),
    "build_iso": ("Build or dry-run an EngineOS ISO.", schema({"profile": {"type": "string", "default": "enginedev"}, "dry_run": {"type": "boolean", "default": True}, "fast": {"type": "boolean", "default": False}, "timeout_sec": {"type": "integer", "default": 600}}), tool_build_iso),
    "build_shell": ("Build or dry-run the wlroots shell.", schema({"dry_run": {"type": "boolean", "default": True}, "timeout_sec": {"type": "integer", "default": 120}}), tool_build_shell),
    "package": ("Build or dry-run a named EngineOS package.", schema({"name": {"type": "string"}, "dry_run": {"type": "boolean", "default": True}, "timeout_sec": {"type": "integer", "default": 300}}, ["name"]), tool_package),
    "proof": ("Run a focused EngineOS proof command. Defaults to dry-run.", schema({"proof": {"type": "string", "default": "launchpad"}, "mode": {"type": "string"}, "profile": {"type": "string"}, "device": {"type": "string"}, "dry_run": {"type": "boolean", "default": True}, "timeout_sec": {"type": "integer", "default": 180}}), tool_proof),
    "run_shell_smoke": ("Run shell headless/nested smoke.", schema({"mode": {"type": "string", "default": "headless"}, "timeout_sec": {"type": "integer", "default": 60}}), tool_run_shell_smoke),
    "run_quake_smoke": ("Run Quake wrapper smoke.", schema({"timeout_sec": {"type": "integer", "default": 90}}), tool_run_quake_smoke),
    "engine": ("Read or control the engine runner with bounded actions.", schema({"action": {"type": "string", "default": "status"}, "target": {"type": "string", "default": "quake"}, "smoke": {"type": "boolean", "default": True}, "timeout_sec": {"type": "integer", "default": 60}}), tool_engine),
    "capture_frame": ("Capture shell frame or metadata artifact.", schema({"target": {"type": "string", "default": "shell"}, "tool": {"type": "string", "default": "auto"}}), tool_capture_frame),
    "crash_bundle": ("Collect an EngineOS crash bundle.", schema({"mode": {"type": "string", "default": "host"}, "timeout_sec": {"type": "integer", "default": 120}}), tool_crash_bundle),
}

RESOURCES = {
    "engineos://status/current": ("text/markdown", "CURRENT_STATUS.md"),
    "engineos://status/roadmap": ("text/markdown", "ROADMAP.md"),
    "engineos://agent/harness": ("text/markdown", "docs/agent-harness.md"),
    "engineos://agent/workflow": ("text/markdown", "docs/agent-workflow.md"),
    "engineos://agent/lsp": ("text/markdown", "docs/agent-lsp.md"),
    "engineos://agent/pack": ("text/markdown", "docs/engineos-agent-pack.md"),
}

PROMPTS = {
    "next-proof": "Read CURRENT_STATUS.md and ROADMAP.md, then pick the smallest local proof command. Do not widen scope.",
    "runtime-failure": "Use EngineOS logs, app status, proof launchpad, and crash bundle evidence before proposing a runtime fix.",
    "agent-harness-check": "Run project_status and engineos test agent, then summarize Codex/MCP readiness.",
}


def handle_initialize(params: dict[str, Any]) -> dict[str, Any]:
    return {
        "protocolVersion": params.get("protocolVersion", "2025-06-18"),
        "capabilities": {"tools": {}, "resources": {}, "prompts": {}},
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
    }


def handle_tools_list() -> dict[str, Any]:
    return {
        "tools": [
            {"name": name, "description": desc, "inputSchema": input_schema}
            for name, (desc, input_schema, _func) in TOOLS.items()
        ]
    }


def handle_tools_call(params: dict[str, Any]) -> dict[str, Any]:
    name = params.get("name")
    arguments = params.get("arguments") or {}
    if name not in TOOLS:
        return invalid(f"unknown tool: {name}")
    try:
        return TOOLS[name][2](arguments)
    except Exception as exc:
        return invalid(f"tool {name} failed: {type(exc).__name__}: {exc}")


def handle_resources_list() -> dict[str, Any]:
    return {
        "resources": [
            {"uri": uri, "name": uri.replace("engineos://", ""), "description": rel, "mimeType": mime}
            for uri, (mime, rel) in RESOURCES.items()
        ]
    }


def handle_resources_read(params: dict[str, Any]) -> dict[str, Any]:
    uri = params.get("uri", "")
    if uri not in RESOURCES:
        return {"contents": [{"uri": uri, "mimeType": "text/plain", "text": f"unknown resource: {uri}"}]}
    mime, rel = RESOURCES[uri]
    path = repo_root() / rel
    if not path.exists():
        text = f"missing resource file: {rel}"
    else:
        text = path.read_text(encoding="utf-8", errors="replace")
    return {"contents": [{"uri": uri, "mimeType": mime, "text": text}]}


def handle_prompts_list() -> dict[str, Any]:
    return {"prompts": [{"name": name, "description": text} for name, text in PROMPTS.items()]}


def handle_prompts_get(params: dict[str, Any]) -> dict[str, Any]:
    name = params.get("name", "")
    if name not in PROMPTS:
        raise ValueError(f"unknown prompt: {name}")
    return {
        "description": PROMPTS[name],
        "messages": [{"role": "user", "content": {"type": "text", "text": PROMPTS[name]}}],
    }


def dispatch(method: str, params: dict[str, Any]) -> Any:
    if method == "initialize":
        return handle_initialize(params)
    if method == "notifications/initialized":
        return None
    if method == "tools/list":
        return handle_tools_list()
    if method == "tools/call":
        return handle_tools_call(params)
    if method == "resources/list":
        return handle_resources_list()
    if method == "resources/read":
        return handle_resources_read(params)
    if method == "prompts/list":
        return handle_prompts_list()
    if method == "prompts/get":
        return handle_prompts_get(params)
    raise ValueError(f"unsupported method: {method}")


def write_message(msg: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(msg, separators=(",", ":"), ensure_ascii=False) + "\n")
    sys.stdout.flush()


def serve() -> None:
    for line in sys.stdin:
        if not line.strip():
            continue
        msg_id = None
        try:
            req = json.loads(line)
            msg_id = req.get("id")
            result = dispatch(req.get("method", ""), req.get("params") or {})
            if msg_id is not None:
                write_message({"jsonrpc": "2.0", "id": msg_id, "result": result})
        except Exception as exc:
            if msg_id is not None:
                write_message(
                    {
                        "jsonrpc": "2.0",
                        "id": msg_id,
                        "error": {"code": -32603, "message": f"{type(exc).__name__}: {exc}"},
                    }
                )


def self_test() -> int:
    report = {
        "server": SERVER_NAME,
        "version": SERVER_VERSION,
        "repo_root": str(repo_root()),
        "engineos_argv": engineos_argv(),
        "tool_count": len(TOOLS),
        "tools": sorted(TOOLS),
        "resources": sorted(RESOURCES),
        "prompts": sorted(PROMPTS),
    }
    print(json_text(report))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    serve()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
