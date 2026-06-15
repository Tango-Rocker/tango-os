# EngineOS Agent Pack

The Codex agent pack is now embedded in the repo instead of kept as a generated
sidecar. It gives agents three layers:

```text
AGENTS.md                         always-loaded repository rules
.agents/skills/*/SKILL.md         task routers and area workflows
tools/mcp/engineos_mcp_server.py  bounded wrappers around engineos commands
```

## Installed Files

```text
.codex/config.toml
.codex/hooks.example.json
.agents/skills/engineos/SKILL.md
.agents/skills/archiso-build/SKILL.md
.agents/skills/wlroots-compositor/SKILL.md
.agents/skills/quake-port/SKILL.md
.agents/skills/input-routing/SKILL.md
.agents/skills/render-gl/SKILL.md
.agents/skills/crash-forensics/SKILL.md
.agents/skills/code-navigation/SKILL.md
tools/hooks/session_start.py
tools/hooks/pre_tool_policy.py
tools/hooks/stop_check.py
tools/mcp/engineos_mcp_server.py
```

The `engineos-agent-tools` package installs the same guidance under
`/usr/share/engineos` and executable helpers under `/usr/share/engineos/tools`.

## MCP Tool Surface

The MCP server exposes typed operations for status, docs, doctor, logs, app
state, app manifest validation, assets, preflight, validation, focused tests,
repo/ISO/shell dry-runs, packages, proofs, shell/Quake smoke runs, engine
runner control, frame capture, and crash bundles.

The server must never expose:

- arbitrary shell
- raw sudo
- package removal
- recursive deletion
- secret reads
- direct edits to generated `work/` or `out/` artifacts

## Checks

```bash
python tools/mcp/engineos_mcp_server.py --self-test
./tools/engineos/engineos test agent
./tools/engineos/engineos preflight repo --package engineos-agent-tools
./tools/engineos/engineos lint packages --package engineos-agent-tools
```
