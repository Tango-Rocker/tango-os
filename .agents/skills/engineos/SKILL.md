---
name: engineos
description: Use for general Tang-OS / EngineOS work involving eos-* CLI tools, agent workflow, builder VM, archiso profiles, packages, runtime proofs, shell launchpad, Quake path, logs, crash bundles, observability, or role routing.
---

# EngineOS Orchestrator Skill

EngineOS is a hobby OS lab. Build the Arch-based EngineDev lab first, then the
smaller EngineRuntime appliance. Keep the next proof small and use
`./tools/engineos/eos-*` tools as the control surface.

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
./tools/engineos/eos-doctor --mock
./tools/engineos/eos-test agent
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-agent dispatch status
./tools/engineos/eos-observe metrics
./tools/engineos/eos-observe tui --once
./tools/engineos/eos-preflight all
./tools/engineos/eos-build repo --dry-run
./tools/engineos/eos-build iso --dry-run
./tools/engineos/eos-proof launchpad --runtime --dry-run
```

Use real package/ISO builds only from `/srv/engineos` on the Arch builder VM.

## Agent Harness

Codex-specific files are part of the product:

```text
AGENTS.md
.codex/config.toml
.codex/hooks.example.json
.agents/index.toml
.agents/roles/*/AGENTS.md
.agents/profiles/*.profile.toml
.agents/skills/*/SKILL.md
tools/hooks/*.py
docs/agent-harness.md
docs/agent-workflow.md
docs/agent-lsp.md
docs/agent-roles.md
docs/agent-profiles.md
```

Use direct `eos-*` CLI commands for local builds, tests, proofs, logs,
runtime actions, observability, and route checks. Use skills for repeatable
workflow judgment. Use `eos-agent hygiene check` for agent-pack drift and
`eos-agent dispatch ...` for manual local queue/ledger work. The old
project-status/docs MCP server is removed; future EngineOS MCP work is reserved
for read-only live runtime state and must not
mirror local commands or expose arbitrary shell, raw sudo, package removal,
recursive deletion, secret reads, or direct editing of generated `work/` or
`out/` artifacts.

## Hard Boundaries

- Do not commit commercial Quake assets or secrets.
- Do not hand-edit generated ISO output as source of truth.
- Do not run real USB writes, dev installs, or TTY/KMS takeover commands without
  explicit user direction.
- Put persistent OS behavior in packages, profile files, or repo-owned scripts.
- Keep useful tangents in `BACKLOG.md` and return to the current proof.
