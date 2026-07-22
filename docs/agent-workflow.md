# Agent Workflow

The `eos-*` CLI is the execution surface for humans and agents. Skills carry
repeatable workflow judgment. Project-status/docs MCP has been removed; do not
mirror build, test, proof, package, admin, or runtime commands through MCP.
Future EngineOS MCP work is reserved for read-only live runtime state.

## Default Loop

```bash
./tools/engineos/eos-doctor
./tools/engineos/eos-source-test agent
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-preflight repo --package engineos-tools
./tools/engineos/eos-ci local --package engineos-tools --test agent-route --no-validate-repo --clean-generated
./tools/engineos/eos-app manifest validate
./tools/engineos/eos-game quake proof
```

Apply committed live changes with the package-aware development workflow:

```bash
./tools/engineos/eos dev plan --range <base>..<head>
./tools/engineos/eos dev apply --range <base>..<head>
./tools/engineos/eos-runtime shell refresh-user
./tools/engineos/eos-runtime shell restart-live
```

ISO, VM, QEMU, and Hyper-V commands are legacy/reference-only unless the user
explicitly re-enables the image lab.

## Codex Harness

Project-local Codex integration lives in:

```text
.codex/config.toml
.agents/index.toml
.agents/roles/*/AGENTS.md
.agents/skills/*/SKILL.md
tools/scripts/agent_router.py
tools/scripts/agent_hygiene.py
docs/agent-roles.md
```

Validate it with:

```bash
./tools/engineos/eos-source-test agent
./tools/engineos/eos-test agent-hygiene
```

Run source-checkout tests through `eos-source-test <scope>` and package loops
through `eos-ci local --no-validate-repo`; do not add MCP tools just to mirror
local commands. Direct `eos-build`, `eos-lint`, and `eos-preflight` are
lower-level checks.

Inspect metadata-only agent route events locally with:

```bash
./tools/engineos/eos-observe tail --last 20
./tools/engineos/eos-observe metrics
```

## Status Discipline

When work changes build, boot, runtime, or agent behavior, update
`CURRENT_STATUS.md` with:

- what now works
- what was tested
- what is still blocked
- the next command to run

Put useful off-track ideas in `BACKLOG.md` and return to the current proof.
