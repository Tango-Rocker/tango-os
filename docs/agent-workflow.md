# Agent Workflow

The `engineos` CLI is the execution surface for humans and agents. Skills carry
repeatable workflow judgment. The project MCP server is intentionally read-only:
it exposes bounded status/docs discovery, not build, test, proof, or runtime
command wrappers.

## Default Loop

```bash
./tools/engineos/engineos doctor --mock
./tools/engineos/engineos test agent
./tools/engineos/engineos bootstrap builder --dry-run
./tools/engineos/engineos validate builder --mock
./tools/engineos/engineos validate repo --dry-run
./tools/engineos/engineos proof build-lab --dry-run
./tools/engineos/engineos build repo --dry-run
./tools/engineos/engineos build iso --dry-run
./tools/engineos/engineos test
```

On the Arch builder VM, replace dry-runs with real builds only after the local
proof path is clean:

```bash
cd /srv/engineos
./tools/engineos/engineos bootstrap builder
./tools/engineos/engineos validate builder
./tools/engineos/engineos proof build-lab
./tools/engineos/engineos vm boot enginedev --display none --background --ssh-port 2222
```

## Codex Harness

Project-local Codex integration lives in:

```text
.codex/config.toml
.codex/hooks.example.json
.agents/skills/*/SKILL.md
tools/hooks/*.py
tools/mcp/engineos_mcp_server.py
```

Validate it with:

```bash
python tools/mcp/engineos_mcp_server.py --self-test
./tools/engineos/engineos test agent
```

Run local work through direct CLI commands such as `engineos test agent` or
`engineos proof launchpad --runtime --dry-run`; do not add MCP tools just to
mirror local commands.

## Status Discipline

When work changes build, boot, runtime, or agent behavior, update
`CURRENT_STATUS.md` with:

- what now works
- what was tested
- what is still blocked
- the next command to run

Put useful off-track ideas in `BACKLOG.md` and return to the current proof.
