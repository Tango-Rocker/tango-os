# Management Project

This is the lightweight improvement loop for the EngineOS repository, not a
second product or planning system.

## Repo Link

- Goal and phases: [../ROADMAP.md](../ROADMAP.md)
- Directives: [../AGENTS.md](../AGENTS.md)
- Current handoff: [../CURRENT_STATUS.md](../CURRENT_STATUS.md)
- Project harness: [../docs/agent-harness.md](../docs/agent-harness.md)

## Project Overseer

- Agent contract: [project-overseer-harness-agent.md](agents/project-overseer-harness-agent.md)
- Bounded runtime config: [../.agents/supervisor.toml](../.agents/supervisor.toml)
- Status: `eos-agent supervisor status --root /home/dev/Tang-OS --json`
- Run once: `eos-agent supervisor run --root /home/dev/Tang-OS`

## Records

- Historic patterns: [issues-history.md](issues-history.md)
- Overseer archive: [archive/](archive/)
- Session archive: [../docs/session-archive/](../docs/session-archive/)

Generated reports and token ledgers remain under
`.agent-insights/out/supervisor/`; private extracted evidence remains under
`.agent-insights/archive/`. Neither path is committed.
