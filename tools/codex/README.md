# Codex Helpers

This directory points to the repo-owned Codex harness. The active helper code is
kept in first-class project paths so it can be packaged and validated.

Use:

```text
AGENTS.md
.codex/config.toml
.codex/hooks.example.json
.agents/skills/*/SKILL.md
tools/hooks/*.py
tools/mcp/engineos_mcp_server.py
docs/engineos-agent-pack.md
docs/agent-harness.md
docs/agent-workflow.md
docs/agent-lsp.md
```

Validation:

```bash
./tools/engineos/engineos test agent
python tools/mcp/engineos_mcp_server.py --self-test
```
