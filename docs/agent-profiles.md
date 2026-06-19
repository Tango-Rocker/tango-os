# EngineOS Agent Profiles

Agent profiles are the structured harness layer for Codex, OpenCode, and future
local agents. Role prose stays in `docs/agent-roles.md` and
`.agents/roles/<role>/AGENTS.md`; `.agents/index.toml` is the machine-readable
role/path index. Profiles make the same boundaries easy to validate and load
without scraping prose.

Profiles are generated from:

```text
.agents/index.toml
tools/scripts/agent_metadata.sh
```

Installed packages write generated profile files under
`.agents/profiles/<role>.profile.toml`; source checkouts keep only the index and
generator.

Each profile uses `schema = "engineos-agent-profile-v0"` and includes:

- `role`, `display_name`, `mode`, `risk_default`, and `primary_skill`
- pointers to the role AGENTS file, role skill, and OpenCode wrapper
- route triggers and handoff targets
- allowed read/edit/bash policy for portable harnesses
- observability metadata kinds and redaction policy
- proof commands that should be suggested before broader work

Use:

```bash
eos-agent profile list
eos-agent profile show oracle
eos-agent hygiene check
eos-test agent
```

The profile is declarative. It must not contain raw secrets, user prompts,
private tokens, commercial game assets, or runtime state snapshots. MCP is not a
profile execution path; future MCP remains read-only live runtime state only.
