---
name: engineos
description: Use for general Tang-OS / EngineOS work involving the engineos CLI, agent workflow, builder VM, archiso profiles, packages, runtime proofs, shell launchpad, Quake path, logs, crash bundles, or MCP tools.
---

# EngineOS Orchestrator Skill

EngineOS is a hobby OS lab. Build the Arch-based EngineDev lab first, then the
smaller EngineRuntime appliance. Keep the next proof small and use
`./tools/engineos/engineos` as the control surface.

## First Read

Read only the context the task needs:

- `CURRENT_STATUS.md` for what is proven, broken, and next.
- `ROADMAP.md` for the current phase.
- `docs/agent-harness.md` for command policy.
- Area skills such as `archiso-build`, `wlroots-compositor`, `quake-port`,
  `render-gl`, `input-routing`, and `crash-forensics` when the task enters
  those areas.

## Default Loop

1. Place the task against the current PoC/sprint.
2. Pick the smallest command that proves or falsifies the claim.
3. Make the narrowest repo-owned change.
4. Run the narrowest relevant check.
5. If validation cannot run, classify the blocker as repo-owned or
   environmental and record the exact rerun command.

## Local Proof Ladder

Prefer these outside the Arch builder VM:

```bash
./tools/engineos/engineos doctor --mock
./tools/engineos/engineos test agent
./tools/engineos/engineos preflight all
./tools/engineos/engineos build repo --dry-run
./tools/engineos/engineos build iso --dry-run
./tools/engineos/engineos proof launchpad --runtime --dry-run
```

Use real package/ISO builds only from `/srv/engineos` on the Arch builder VM.

## Agent Harness

Codex-specific files are part of the product:

```text
AGENTS.md
.codex/config.toml
.codex/hooks.example.json
.agents/skills/*/SKILL.md
tools/hooks/*.py
tools/mcp/engineos_mcp_server.py
docs/agent-harness.md
docs/agent-workflow.md
docs/agent-lsp.md
```

The MCP server is read-only orientation glue. Use direct `engineos` CLI commands
for local builds, tests, proofs, logs, and runtime actions. Do not add MCP tools
just to mirror local commands, and never expose arbitrary shell, raw sudo,
package removal, recursive deletion, secret reads, or direct editing of
generated `work/` or `out/` artifacts.

## Hard Boundaries

- Do not commit commercial Quake assets or secrets.
- Do not hand-edit generated ISO output as source of truth.
- Do not run real USB writes, dev installs, or TTY/KMS takeover commands without
  explicit user direction.
- Put persistent OS behavior in packages, profile files, or repo-owned scripts.
- Keep useful tangents in `BACKLOG.md` and return to the current proof.
