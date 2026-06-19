# EngineOS Agent Pack

The EngineOS agent pack is embedded in the repo instead of kept as a generated
sidecar. It has these canonical source layers:

```text
AGENTS.md                         always-loaded repository rules
docs/agent-roles.md               role boundaries and handoff rules
.agents/index.toml                machine-readable role/path index
.agents/roles/*/AGENTS.md         role-local ownership instructions
.agents/skills/*/SKILL.md         task routers and area workflows
tools/scripts/agent_metadata.sh   profile and wrapper generator
```

## Installed Files

```text
.codex/config.toml
.codex/hooks.example.json
docs/agent-roles.md
docs/agent-profiles.md
.agents/index.toml
.agents/roles/*/AGENTS.md
.agents/skills/*/SKILL.md
tools/hooks/session_start.py
tools/hooks/pre_tool_policy.py
tools/hooks/stop_check.py
```

The `engineos-tools` package installs the same guidance under
`/usr/share/engineos`, writes generated profiles to
`.agents/profiles/*.profile.toml`, writes generated OpenCode wrappers to
`.opencode/agents/*.md`, and installs executable hook helpers under
`/usr/share/engineos/tools`.

## Interface Policy

Use direct `engineos` CLI commands for local builds, tests, proofs, logs,
package work, admin work, observability, and runtime actions. Use skills to
capture repeatable workflows and safety rules.

Project-status/docs MCP has been removed. Do not add MCP tools just to mirror
local commands that are already scriptable, documented, and safe through the
CLI. Future EngineOS MCP work is reserved for read-only live runtime state, such
as shell state, app slots, service status, recent log summaries, and crash
bundle indexes. Runtime MCP v0 must not execute CLI commands, sudo, package
operations, or window control.

Observability v0 is local, opt-in, metadata-only JSONL. It may record shell
command hashes, `engineos` command metadata, and agent route/handoff events. It
must not store raw shell commands, raw prompts, raw AI responses, secrets, or
commercial game assets.

Agent operations v0 adds a repo-local queue and ledger under
`artifacts/agent-ledger/`. The ledger is operational state, not opt-in
telemetry. Dispatcher work is manual-drain, one task at a time, repo-scoped,
and must block sudo, package operations, USB/disk operations, service changes,
external directories, and raw prompt/AI I/O storage.

## Observability

`eos-observe metrics` derives Prometheus text metrics from
metadata-only observability events plus the local agent queue/ledger. It reports
event counters, current task states by role, ledger event counters, oldest task
age by role/state, dispatcher lock state, and queue/ledger record totals. It
must not expose raw shell commands, raw prompts, AI I/O, or task summaries.

Use:

```bash
eos-observe exporter start --host 0.0.0.0 --port 9109
eos-observe tui
```

External collectors can scrape the exporter when needed. EngineOS does not ship
repo-owned Docker orchestration for Prometheus or OpenTelemetry.

## Checks

```bash
./tools/engineos/eos-test agent
./tools/engineos/eos-agent profile list
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-test agent-hygiene
./tools/engineos/eos-test agent-dispatcher
./tools/engineos/eos-test observability
./tools/engineos/eos-test agent-route
./tools/engineos/eos-preflight repo --package engineos-tools
./tools/engineos/eos-lint packages --package engineos-tools
```
