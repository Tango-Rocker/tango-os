#!/usr/bin/env python3
"""Read-only EngineOS MCP orientation server.

The local EngineOS CLI is the execution surface for builds, tests, proofs, and
runtime commands. This MCP server intentionally stays small: it exposes bounded
project status, documents, resources, and prompts for clients that benefit from
a typed discovery surface.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

SERVER_NAME = "engineos"
SERVER_VERSION = "0.3.0"

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

RESOURCES = {
    "engineos://status/current": ("text/markdown", "CURRENT_STATUS.md"),
    "engineos://status/roadmap": ("text/markdown", "ROADMAP.md"),
    "engineos://agent/harness": ("text/markdown", "docs/agent-harness.md"),
    "engineos://agent/workflow": ("text/markdown", "docs/agent-workflow.md"),
    "engineos://agent/lsp": ("text/markdown", "docs/agent-lsp.md"),
    "engineos://agent/pack": ("text/markdown", "docs/engineos-agent-pack.md"),
}

PROMPTS = {
    "next-proof": "Read CURRENT_STATUS.md and ROADMAP.md, then run the smallest relevant direct engineos CLI proof command.",
    "runtime-failure": "Use direct engineos CLI log/proof commands and preserve crash-bundle evidence before proposing a runtime fix.",
    "agent-harness-check": "Read the agent pack docs, run engineos test agent directly, and summarize Codex/MCP readiness.",
}


def repo_root() -> Path:
    env_root = os.environ.get("ENGINEOS_REPO") or os.environ.get("ENGINEOS_PROJECT_ROOT")
    if env_root:
        return Path(env_root).expanduser().resolve()
    return Path(__file__).resolve().parents[2]


def json_text(obj: Any) -> str:
    return json.dumps(obj, indent=2, ensure_ascii=False)


def text_result(text: str, is_error: bool = False) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def schema(properties: dict[str, Any], required: list[str] | None = None) -> dict[str, Any]:
    return {"type": "object", "properties": properties, "required": required or []}


def arg_str(args: dict[str, Any], name: str, default: str = "") -> str:
    value = args.get(name, default)
    if value is None:
        return default
    return str(value)


def arg_int(args: dict[str, Any], name: str, default: int, minimum: int = 1, maximum: int = 40000) -> int:
    try:
        value = int(args.get(name, default))
    except (TypeError, ValueError):
        value = default
    return max(minimum, min(maximum, value))


def git_output(root: Path, *args: str) -> str:
    try:
        proc = subprocess.run(
            ["git", *args],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
    except Exception as exc:
        return f"unavailable: {type(exc).__name__}: {exc}"
    return (proc.stdout or proc.stderr or "").strip()


def read_file(rel: str, max_chars: int = 40000) -> str:
    path = repo_root() / rel
    if not path.exists():
        raise FileNotFoundError(rel)
    return path.read_text(encoding="utf-8", errors="replace")[:max_chars]


def tool_project_status(args: dict[str, Any]) -> dict[str, Any]:
    root = repo_root()
    skills_dir = root / ".agents" / "skills"
    skills = []
    if skills_dir.exists():
        skills = sorted(str(path.relative_to(root)) for path in skills_dir.glob("*/SKILL.md"))
    payload = {
        "server": {"name": SERVER_NAME, "version": SERVER_VERSION},
        "repo_root": str(root),
        "git_head": git_output(root, "rev-parse", "--short", "HEAD"),
        "git_status_short": git_output(root, "status", "--short"),
        "engineos_cli_path": str(root / "tools" / "engineos" / "engineos"),
        "execution_policy": "Use direct engineos CLI commands for builds, tests, proofs, logs, and runtime actions.",
        "has_codex_config": (root / ".codex" / "config.toml").exists(),
        "has_hooks": (root / "tools" / "hooks").exists(),
        "skills": skills,
        "docs": {name: (root / rel).exists() for name, rel in SAFE_DOCS.items()},
    }
    return text_result(json_text(payload))


def tool_read_status(args: dict[str, Any]) -> dict[str, Any]:
    name = arg_str(args, "name", "current_status")
    max_chars = arg_int(args, "max_chars", 12000, minimum=1000)
    if name not in SAFE_DOCS:
        return text_result(f"unknown status document: {name}", True)
    try:
        return text_result(read_file(SAFE_DOCS[name], max_chars=max_chars))
    except FileNotFoundError:
        return text_result(f"missing document: {SAFE_DOCS[name]}", True)


TOOLS = {
    "project_status": (
        "Read repo root, git status, known docs, skills, Codex config, and direct CLI guidance.",
        schema({}),
        tool_project_status,
    ),
    "read_status": (
        "Read a bounded project status/planning document.",
        schema({"name": {"type": "string", "default": "current_status"}, "max_chars": {"type": "integer", "default": 12000}}),
        tool_read_status,
    ),
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
        return text_result(f"unknown tool: {name}", True)
    try:
        return TOOLS[name][2](arguments)
    except Exception as exc:
        return text_result(f"tool {name} failed: {type(exc).__name__}: {exc}", True)


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
    try:
        text = read_file(rel)
    except FileNotFoundError:
        text = f"missing resource file: {rel}"
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
        "policy": "read-only MCP; direct CLI for local execution",
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
