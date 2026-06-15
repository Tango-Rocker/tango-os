# EngineOS MCP

`engineos_mcp_server.py` exposes bounded EngineOS operations to Codex through
stdio MCP. It wraps the existing `engineos` CLI and does not expose arbitrary
shell execution.

## Self-Test

```bash
python tools/mcp/engineos_mcp_server.py --self-test
```

## Codex Config

Project-local config lives in `.codex/config.toml`:

```toml
[mcp_servers.engineos]
command = "python"
args = ["tools/mcp/engineos_mcp_server.py"]
```

## Tool Policy

Auto-approvable read-only tools:

- `project_status`
- `read_status`
- `doctor`
- `logs`
- `app_status`
- `app_manifest`
- `assets`

Prompt-gate tools that can run tests, write artifacts, consume disk/time, start
processes, or mutate build output:

- `preflight`
- `validate`
- `test`
- `build_repo`
- `build_iso`
- `build_shell`
- `package`
- `proof`
- `run_shell_smoke`
- `run_quake_smoke`
- `engine`
- `capture_frame`
- `crash_bundle`

Never add tools for raw sudo, recursive deletion, package removal, secret reads,
or direct edits to generated `work/` and `out/` artifacts.
