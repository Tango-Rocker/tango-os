---
name: engineos
description: Use for general Tang-OS / EngineOS work involving eos-* CLI tools, agent workflow, packages, runtime proofs, shell launchpad, Quake path, logs, crash bundles, observability, or role routing.
---

# EngineOS Orchestrator Skill

EngineOS is a bare-metal/source-checkout hobby OS lab. Keep the next proof
small and use `./tools/engineos/eos-*` tools as the control surface. ISO, VM,
QEMU, Hyper-V builder, and generated-image work is legacy/reference-only unless
the user explicitly re-enables it.

## First Read

Read only the context the task needs:

- `CURRENT_STATUS.md` for what is proven, broken, and next.
- `ROADMAP.md` for the current phase.
- `docs/agent-harness.md` for command policy.
- Area skills such as `wlroots-compositor`, `quake-port`, `render-gl`,
  `input-routing`, and `crash-forensics` when the task enters those areas.

## Default Loop

1. Place the task against the current PoC/sprint.
2. Pick the smallest command that proves or falsifies the claim.
3. Make the narrowest repo-owned change.
4. Run the narrowest relevant check.
5. If validation cannot run, classify the blocker as repo-owned or
   environmental and record the exact rerun command.

## Local Check Ladder

Prefer these on the live checkout. Dry-runs are previews only, not proof.

```bash
./tools/engineos/eos-doctor
./tools/engineos/eos-source-test agent
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-agent dispatch status
./tools/engineos/eos-observe metrics
./tools/engineos/eos-observe tui --once
./tools/engineos/eos-preflight all
./tools/engineos/eos-ci local --no-validate-repo --clean-generated
./tools/engineos/eos-source-test shell
```

Do not use ISO, VM, or builder-handoff paths for routine work.
Use `eos-source-test <scope>` for checkout-local tests from live sessions that
may have installed `/usr` EngineOS variables. Use `eos-ci local` for the normal
post-change package/test/install loop; direct build, lint, and preflight
commands are lower-level checks.

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

## Finish And Deploy

When finished work is ready to publish from a checkout that should deploy on
push, install the repo-owned hook once:

```bash
tools/hooks/install_git_push_deploy_hook.sh
```

The hook writes `.git/hooks/pre-push` and runs the configured local deploy
command for pushed branch refs. The default command is the local `eos-ci`
package rebuild/reinstall loop. It must not call `eos-builder`, `eos-vm`, or
`eos-build iso` unless the user explicitly re-enables the legacy image lab.

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
- Do not route work through generated ISO/VM artifacts unless explicitly asked.
- Do not run real USB writes, dev installs, or TTY/KMS takeover commands without
  explicit user direction.
- Put persistent OS behavior in packages, profile files, or repo-owned scripts.
- Keep useful tangents in `BACKLOG.md` and return to the current proof.
