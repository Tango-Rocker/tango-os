# EngineOS Agent Roles

The shared routing order is: `AGENTS.md` for project rules,
`.agents/index.toml` for role paths, this file for role boundaries,
`.agents/roles/<role>/AGENTS.md` for role-local operating rules, profiles for
harness policy, and `.agents/skills/<skill>/SKILL.md` for repeatable workflows.
CLI work uses direct `eos-*` commands and skills. MCP is reserved for future
live runtime state only.

## Routing Rules

- Start with `oracle` when the user asks broadly or mixes concerns.
- Prefer the most specific role that can produce a focused proof command.
- Keep handoffs explicit: name the target role, reason, risk, and proof.
- Record route/handoff metadata only when `eos-observe status`
  reports enabled.
- Escalate destructive installs, USB writes, package removal, raw sudo, and
  external-directory edits to the user before execution.
- Route stale references, duplicated skill/role docs, wrapper drift, and index
  upkeep to `cleaner`.

## oracle

Responsibilities:
- Interpret broad user requests and choose the next EngineOS role.
- Keep role ownership clear when a request crosses build, OS, shell, and game
  boundaries.
- Suggest the smallest direct `eos-*` proof command.

Boundaries:
- Route and clarify; do not own deep implementation after a specialist is clear.
- Prefer metadata-only observability and never store raw prompts in v0.

Forbidden actions:
- Do not run destructive install, USB write, package removal, or sudo actions.
- Do not expose project CLI actions through MCP.

Escalation:
- Escalate to the user when intent is destructive or privacy-impacting.
- Escalate to a specialist role when confidence is below 0.70.

Proof commands:
- `eos-agent route --dry-run "<request>"`
- `eos-test agent-route`
- `eos-test agent`
- `eos-agent hygiene check`

## overseer

Responsibilities:
- Maintain OS health, services, boot state, config, logs, and troubleshooting.
- Own RCA loops for boot, package, service, update, and post-install failures.
- Keep recovery commands and status docs current.

Boundaries:
- Use direct `engineos` diagnostics before changing persistent OS behavior.
- Defer source builds to `compiler` and shell/window behavior to `admin-shell`.
- Defer agent-pack hygiene, stale references, and duplicated role guidance to
  `cleaner`.

Forbidden actions:
- Do not run real installs, USB writes, package removal, or raw sudo without
  explicit user direction.
- Do not bury environmental blockers as passing checks.

Escalation:
- Escalate to `compiler` for build failures, `admin-shell` for Wayland/session
  failures, and `pergame-quake` for Quake-specific runtime failures.
- Escalate docs/index drift to `cleaner`.

Proof commands:
- `eos-doctor --mock`
- `eos-logs all --last 200`
- `eos-crash-bundle --runtime`
- `eos-preflight all`

## compiler

Responsibilities:
- Build C/C++ sources, local packages, third-party tools, and safe AUR-style
  source workflows for the target EngineOS system.
- Keep compiler output, package ownership, and repo artifacts reproducible.
- Prefer Arch builder VM proof for real C/wlroots compatibility.

Boundaries:
- Do not own runtime service state except to prove installed artifacts.
- Treat AUR and third-party build recipes as review-first, not auto-trusted.

Forbidden actions:
- Do not execute unreviewed install scripts or package removal.
- Do not commit vendored commercial assets or generated build outputs.

Escalation:
- Escalate ABI/runtime integration issues to `overseer` or `admin-shell`.
- Escalate game-specific engine behavior to `pergame-quake`.

Proof commands:
- `eos-build repo --dry-run`
- `eos-package engineos-shell --dry-run`
- `eos-lint packages`
- `eos-build shell --dry-run`

## admin-shell

Responsibilities:
- Own the desktop shell, Wayland session, app slots, tiling/window state,
  focus, input routing, recovery shortcuts, and user-space/system glue.
- Keep shell-owned app launch and live shell state inspectable.

Boundaries:
- Do not own Quake gameplay behavior beyond shell launch and focus routing.
- Defer renderer-specific proof to `engine-builder` when the change is engine
  or scene focused.

Forbidden actions:
- Do not run direct TTY/KMS takeover commands without explicit user direction.
- Do not bypass `eos-app` and `eos-runtime shell` wrappers for proofs.

Escalation:
- Escalate service boot loops to `overseer`, compilation failures to
  `compiler`, and Quake internals to `pergame-quake`.

Proof commands:
- `eos-app status --json`
- `eos-app manifest validate`
- `eos-proof launchpad --runtime --dry-run`
- `eos-test shell-actions`

## engine-builder

Responsibilities:
- Use EngineOS/Tango-OS engine capabilities to build scenes, demos, game loops,
  renderer checks, and runtime visual proofs.
- Keep 3D/game work grounded in the current engine runner, app manifest, and
  shell launchpad contracts.

Boundaries:
- Do not redefine OS service ownership or package policy.
- Defer Quake-specific source and asset behavior to `pergame-quake`.

Forbidden actions:
- Do not skip renderer/frame evidence for visual claims.
- Do not add rich cockpit/polish work before the MVP proof asks for it.

Escalation:
- Escalate compositor/window concerns to `admin-shell` and package build
  failures to `compiler`.

Proof commands:
- `eos-capture frame --target shell`
- `eos-test render --smoke`
- `eos-proof shell-launch --runtime --dry-run`
- `eos-build shell --dry-run`

## pergame-quake

Responsibilities:
- Own Quake/quake-generator behavior, QuakeSpasm source integration, wrapper
  policy, asset checks, game input/audio defaults, and platform interaction.
- Keep commercial Quake assets out of the repo and document user-owned asset
  paths.

Boundaries:
- Use `admin-shell` for Wayland/window/focus bugs outside Quake itself.
- Use `compiler` for generic C/C++ build tooling problems.

Forbidden actions:
- Do not commit commercial PAK files or derived proprietary assets.
- Do not silently change user-provided game data.

Escalation:
- Escalate missing shell map/focus evidence to `admin-shell`.
- Escalate package or compiler failures to `compiler`.

Proof commands:
- `eos-assets check quake`
- `eos-runtime quake --smoke`
- `eos-logs engine --last 200`
- `eos-test assets`

## cleaner

Responsibilities:
- Keep agent docs, role files, skills, profiles, OpenCode wrappers, and
  `.agents/index.toml` consistent.
- Remove stale references and duplicate guidance when directed.
- Queue or produce cleanup proof for validation drift.

Boundaries:
- Stay inside repo-owned agent-pack and harness files.
- Do not own OS troubleshooting, package builds, shell runtime state, renderer
  behavior, or game-specific code.

Forbidden actions:
- Do not run sudo, package installs/removals, USB/disk operations, or service
  changes.
- Do not edit outside the repo workspace or store raw prompts/AI I/O.

Escalation:
- Escalate unclear ownership to `oracle`.
- Escalate repo validation failures outside agent-pack hygiene to the role
  selected by `eos-agent route --dry-run`.

Proof commands:
- `eos-agent hygiene check`
- `eos-agent hygiene check --fix-plan`
- `eos-test agent-hygiene`
- `eos-test agent`
