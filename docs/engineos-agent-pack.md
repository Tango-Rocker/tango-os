# EngineOS Agent Pack

The Codex agent pack is now embedded in the repo instead of kept as a generated
sidecar. It gives agents three layers:

```text
AGENTS.md                         always-loaded repository rules
.agents/skills/*/SKILL.md         task routers and area workflows
tools/mcp/engineos_mcp_server.py  read-only status/docs discovery
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

## Interface Policy

Use direct `engineos` CLI commands for local builds, tests, proofs, logs, and
runtime actions. Use skills to capture repeatable workflows and safety rules.
The MCP server is limited to read-only orientation:

- `project_status`
- `read_status`
- status and agent-document resources
- prompts that point back to direct CLI proof commands

Do not add MCP tools just to mirror local commands that are already scriptable,
documented, and safe through the CLI.

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
