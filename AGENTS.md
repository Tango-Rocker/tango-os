# Agent Index

EngineOS is a hobby OS lab: build an Arch-based EngineDev OS first, then a smaller game-runtime appliance. Keep work practical. Advance the next proof, avoid process for its own sake, and put useful tangents in [BACKLOG.md](BACKLOG.md).

Current target: prove the live bare-metal EngineOS shell/app stack with
hardware GL acceleration, shell-owned Wayland clients, recovery logs, and
Quake launch through the EngineOS app stack. ISO, VM, QEMU, Hyper-V builder,
and generated-image work is legacy/reference-only unless the user explicitly
re-enables the image lab.

## First Pass

Read only what the task needs:

1. [CURRENT_STATUS.md](CURRENT_STATUS.md) for what works, what is broken, and the next command.
2. [ROADMAP.md](ROADMAP.md) for the PoC/sprint/MVP map.
3. [docs/mvp-plan.md](docs/mvp-plan.md) only when scope or acceptance details matter.
4. [docs/agent-harness.md](docs/agent-harness.md) for command policy and tangent handling.
5. [docs/agent-lsp.md](docs/agent-lsp.md) when semantic navigation matters.

## Work Loop

1. Place the task against the current PoC and sprint.
2. Pick the smallest command that proves or falsifies the next claim.
3. Make the narrowest change that moves that proof forward.
4. Run the narrowest relevant check.
5. If validation cannot run, determine whether the blocker is environmental or repo-owned. Fix repo-owned blockers before handoff; for environmental blockers, record the exact failure and the exact command to rerun on the target host.
6. Update [CURRENT_STATUS.md](CURRENT_STATUS.md) if an acceptance condition changes.
7. Put useful off-track ideas in [BACKLOG.md](BACKLOG.md), then return to the current proof.
8. When the work is finished, leave a Git disposition: commit the scoped
   changes, push the branch, and merge or open the merge path when policy and
   repository state allow. If publishing cannot happen, record the exact
   blocker and next command.

## Project Map

```text
archiso/              legacy generated-image profiles; not routine work
packages/             local Arch package definitions
shell/                wlroots shell work
engines/              QuakeSpasm and future engine ports
tools/engineos/       eos-* command wrappers and command entrypoints
tools/scripts/        implementation helpers for the CLI
tools/post-install-payload/ first-deploy guest setup scripts and assets
docs/                 architecture, plans, and workflow docs
.agents/index.toml    canonical agent role/path index
.agents/roles/        role-specific AGENTS.md boundaries
.agents/skills/       local task skills
tests/                smoke checks
```

## Task Router

Use this before opening broad docs.

| Task | Read first | Then read if needed |
| --- | --- | --- |
| Find the next useful move | [CURRENT_STATUS.md](CURRENT_STATUS.md) | [ROADMAP.md](ROADMAP.md) |
| Understand sprint scope | [ROADMAP.md](ROADMAP.md) | [docs/mvp-plan.md](docs/mvp-plan.md) |
| Run agent workflow safely | [docs/agent-harness.md](docs/agent-harness.md) | [docs/agent-workflow.md](docs/agent-workflow.md) |
| Route broad agent work | [docs/agent-roles.md](docs/agent-roles.md) | `.agents/roles/*/AGENTS.md` |
| Inspect agent roles | [docs/agent-roles.md](docs/agent-roles.md) | `eos-agent list` |
| Clean agent-pack drift | [.agents/skills/cleaner/SKILL.md](.agents/skills/cleaner/SKILL.md) | `eos-agent hygiene check` |
| Write a session record | [agentd.md](agentd.md) | [docs/session-archive/](docs/session-archive/) |
| First-deploy EngineDev setup | [docs/dev-instance.md](docs/dev-instance.md) | [CURRENT_STATUS.md](CURRENT_STATUS.md) |
| Navigate code or check LSP | [.agents/skills/code-navigation/SKILL.md](.agents/skills/code-navigation/SKILL.md) | [docs/agent-lsp.md](docs/agent-lsp.md) |
| Build packages or repo | [docs/agent-harness.md](docs/agent-harness.md) | `packages/*/PKGBUILD` |
| Legacy ISO profiles | [.agents/skills/archiso-build/SKILL.md](.agents/skills/archiso-build/SKILL.md) | only when explicitly re-enabled |
| Work on wlroots shell | [.agents/skills/wlroots-compositor/SKILL.md](.agents/skills/wlroots-compositor/SKILL.md) | [shell/README.md](shell/README.md) |
| Work on QuakeSpasm | [.agents/skills/quake-port/SKILL.md](.agents/skills/quake-port/SKILL.md) | [docs/asset-policy.md](docs/asset-policy.md) |
| Work on input routing | [.agents/skills/input-routing/SKILL.md](.agents/skills/input-routing/SKILL.md) | [docs/mvp-plan.md](docs/mvp-plan.md) |
| Work on rendering checks | [.agents/skills/render-gl/SKILL.md](.agents/skills/render-gl/SKILL.md) | [docs/architecture.md](docs/architecture.md) |
| Investigate logs/crashes | [.agents/skills/crash-forensics/SKILL.md](.agents/skills/crash-forensics/SKILL.md) | `tools/scripts/crash_bundle.sh` |
| Capture a tangent | [BACKLOG.md](BACKLOG.md) | return to the current proof |

## Command Ladder

Use real local checks for non-destructive proof. ISO, VM, QEMU, Hyper-V
builder, and generated-image paths are legacy/reference-only:

```bash
./tools/engineos/eos --help
./tools/engineos/eos-doctor
./tools/engineos/eos-source-test agent
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-ci local --package engineos-tools --test agent --install --clean-generated --no-validate-repo
./tools/engineos/eos-preflight all
./tools/engineos/eos-lint packages
./tools/engineos/eos-build fetch engine quake --status
./tools/engineos/eos-build shell --dry-run
./tools/engineos/eos-build repo --dry-run
./tools/engineos/eos-test
./tools/engineos/eos-test all
```

Use `eos-source-test <scope>` for source-checkout-safe validation when an
installed EngineOS session may have exported `/usr` paths. Direct
`eos-build`, `eos-lint`, and `eos-preflight` commands are lower-level package
checks; prefer `eos-ci local` for routine post-change package loops.

On the live bare-metal EngineDev install, verify:

```bash
tmux -V
docker info
codex --version
cat /var/log/engineos/post-first-deploy.log
```

## LSP MCP

Semantic navigation MCP: `mcp__sdl_scaffoliding_lsp`.

Use `tool_search` if tools are not visible yet. In this harness the MCP is discoverable, but live LSP calls currently fail with `Transport closed`, so do not block PoC work on it. When LSP responds for a supported source file, prefer it for symbols, definitions, references, diagnostics, completions, type hierarchy, and call flow.

Project-status/docs MCP was removed. Use skills and direct `eos-*` CLI
commands for build, config, admin, package, proof, and log workflows. Future
EngineOS MCP work is reserved for read-only live runtime state only.

Currently exposed LSP tools include:

```text
lsp_server_status
lsp_start_server
lsp_stop_server
lsp_document_symbols
lsp_file_imports
lsp_file_exports
lsp_diagnostics
lsp_workspace_diagnostics
lsp_completions
lsp_hover
lsp_signature_help
lsp_goto_definition
lsp_goto_type_definition
lsp_find_references
lsp_find_implementations
lsp_type_hierarchy
lsp_call_hierarchy
lsp_workspace_symbols
lsp_find_symbol
lsp_related_files
```

Bash, PKGBUILD, Markdown, legacy archiso profiles, and package lists are not LSP-backed here. Use `rg`, `bash -n`, `shellcheck` when available, `eos-preflight all`, and `eos-lint packages`. Real C/wlroots proof belongs on the target host with compiler output.

## Stay Focused

- Finish the current PoC before expanding later polish.
- Prefer one working command over broad refactors.
- Use `eos-*` commands and skills as the control surface.
- Put off-track ideas in [BACKLOG.md](BACKLOG.md) with why they matter and the likely phase.
- Do not start GPU passthrough, Steam/Proton, NVIDIA, HDR, VRR, or rich 3D cockpit work before the MVP path asks for it.
- Update [CURRENT_STATUS.md](CURRENT_STATUS.md) whenever an acceptance condition changes.

## Handoff Check

Run the narrowest relevant check before handing off. For broad scaffold changes:

```bash
bash -n tools/engineos/engineos tools/scripts/*.sh tools/eos/*/*.sh engines/quakespasm/engineos/*.sh tests/smoke.sh archiso/enginedev/profiledef.sh archiso/engineruntime/profiledef.sh
./tools/engineos/eos-test agent-hygiene
./tools/engineos/eos-source-test agent
./tools/engineos/eos-preflight all
./tools/engineos/eos-test
```

If a check cannot run here, do not treat that as success. Decide whether it is caused by the local environment or by the repo change. Fix repo-owned failures before handoff. For environment-only blockers, say why, preserve the failing output, and name the exact command to run on the target host.
