# Agent Workflow

The `engineos` CLI is the execution surface for humans and agents. Skills carry
repeatable workflow judgment. Project-status/docs MCP has been removed; do not
mirror build, test, proof, package, admin, or runtime commands through MCP.
Future EngineOS MCP work is reserved for read-only live runtime state.

## Default Loop

```bash
./tools/engineos/eos-doctor --mock
./tools/engineos/eos-test agent
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-agent dispatch status
./tools/engineos/eos-builder bootstrap --dry-run
./tools/engineos/eos-validate builder --mock
./tools/engineos/eos-validate repo --dry-run
./tools/engineos/eos-proof build-lab --dry-run
./tools/engineos/eos-build repo --dry-run
./tools/engineos/eos-build iso --dry-run
./tools/engineos/eos-test
```

On the Arch builder VM, replace dry-runs with real builds only after the local
proof path is clean:

```bash
cd /srv/engineos
./tools/engineos/eos-builder bootstrap
./tools/engineos/eos-validate builder
./tools/engineos/eos-proof build-lab
./tools/engineos/eos-vm boot enginedev --display none --background --ssh-port 2222
```

## Codex Harness

Project-local Codex integration lives in:

```text
.codex/config.toml
.codex/hooks.example.json
.agents/index.toml
.agents/roles/*/AGENTS.md
.agents/skills/*/SKILL.md
tools/scripts/agent_metadata.sh
tools/hooks/*.py
docs/agent-roles.md
docs/agent-profiles.md
```

Validate it with:

```bash
./tools/engineos/eos-test agent
./tools/engineos/eos-test agent-hygiene
./tools/engineos/eos-test agent-dispatcher
```

Run local work through direct CLI commands such as `eos-test agent` or
`eos-proof launchpad --runtime --dry-run`; do not add MCP tools just to
mirror local commands.

Queued agent work is local and manual-drain in v0:

```bash
./tools/engineos/eos-agent queue list
./tools/engineos/eos-agent dispatch drain --dry-run
```

Inspect the queue and agent health locally with:

```bash
./tools/engineos/eos-observe tui --once
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
