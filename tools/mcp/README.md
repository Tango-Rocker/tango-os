# EngineOS MCP

`engineos_mcp_server.py` exposes bounded EngineOS orientation to Codex through
stdio MCP. It is intentionally read-only: local builds, tests, proofs, logs, and
runtime actions stay on the direct `engineos` CLI and are guided by skills.

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

Do not add MCP tools for local `engineos` execution surfaces such as:

- `build_repo`
- `build_iso`
- `preflight`
- `test`
- `proof`
- `logs`
- `run_quake_smoke`
- `crash_bundle`

Those remain direct CLI commands so the same interface works for humans,
scripts, CI, and agents.

Never add tools for raw sudo, recursive deletion, package removal, secret reads,
or direct edits to generated `work/` and `out/` artifacts.
