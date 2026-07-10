# Codex Helpers

This directory points to the repo-owned Codex harness. The active helper code is
kept in first-class project paths so it can be packaged and validated.

Use:

```text
AGENTS.md
.codex/config.toml
.agents/index.toml
.agents/roles/*/AGENTS.md
.agents/skills/*/SKILL.md
tools/scripts/agent_router.py
tools/scripts/agent_hygiene.py
docs/engineos-agent-pack.md
docs/agent-harness.md
docs/agent-workflow.md
docs/agent-lsp.md
docs/agent-roles.md
```

Validation:

```bash
./tools/engineos/eos-test agent
./tools/engineos/eos-agent hygiene check
```

Run local EngineOS work through the direct CLI and use skills for repeatable
workflow guidance. Project-status/docs MCP has been removed; future MCP is
runtime-only and read-only.
