# EngineOS Agent Pack

The EngineOS agent pack is embedded in the repo instead of kept as a generated
sidecar. It has these canonical source layers:

```text
AGENTS.md                         always-loaded repository rules
agentd.md                         progressive-disclosure directives
docs/agent-roles.md               role boundaries and handoff rules
.agents/index.toml                machine-readable role/path index
.agents/roles/*/AGENTS.md         role-local ownership instructions
.agents/skills/*/SKILL.md         task routers and area workflows
tools/scripts/agent_router.py     structured TOML role router
tools/scripts/agent_hygiene.py    role/path drift validator
```

## Installed Files

```text
.codex/config.toml
agentd.md
docs/agent-roles.md
.agents/index.toml
.agents/roles/*/AGENTS.md
.agents/skills/*/SKILL.md
```

The `engineos-tools` package installs the same guidance under
`/usr/share/engineos`. Role metadata remains canonical in one TOML file; the
package does not generate profiles, wrappers, queues, or inactive hooks.

## Interface Policy

Use direct `eos-*` CLI commands for local builds, tests, proofs, logs, package
work, admin work, observability, and runtime actions. Use skills to capture
repeatable workflows and safety rules.

Project-status/docs MCP has been removed. Do not add MCP tools just to mirror
local commands that are already scriptable, documented, and safe through the
CLI. Future EngineOS MCP work is reserved for read-only live runtime state, such
as shell state, app slots, service status, recent log summaries, and crash
bundle indexes. Runtime MCP v0 must not execute CLI commands, sudo, package
operations, or window control.

Observability v1 is local, opt-in, metadata-only JSONL. It may record shell
command hashes, `engineos` command metadata, and agent route/handoff events. It
must not store raw shell commands, raw prompts, raw AI responses, secrets, or
commercial game assets.

## Observability

`eos-observe metrics` derives Prometheus text metrics from metadata-only
observability events. It reports event counters by kind, source, role, and
risk, and must not expose raw shell commands, raw prompts, or AI I/O.

Inspect or export it directly:

```bash
eos-observe metrics
eos-observe tail --last 20
```

## Checks

```bash
./tools/engineos/eos-source-test agent
./tools/engineos/eos-agent list
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-test agent-hygiene
./tools/engineos/eos-test observability
./tools/engineos/eos-test agent-route
./tools/engineos/eos-preflight repo --package engineos-tools
./tools/engineos/eos-lint packages --package engineos-tools
```
