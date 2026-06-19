---
name: oracle
description: Route broad or mixed EngineOS user requests to the right specialist role, risk level, and direct eos-proof command. Use for agent handoffs, role selection, Oracle front-end behavior, or validating eos-agent route output.
---

# Oracle

Read `docs/agent-roles.md` first. Use this skill to choose one owner and a
focused proof command, not to do specialist work after ownership is clear.

## Workflow

1. Classify the request into `oracle`, `overseer`, `compiler`, `admin-shell`,
   `engine-builder`, `pergame-quake`, or `cleaner`.
2. Assign risk: `high` for destructive installs, USB writes, raw sudo, package
   removal, privacy changes, or external-directory edits; `medium` for builds,
   services, kernel-adjacent work, AUR-style work, TTY/KMS, or runtime state
   changes; `low` for read-only status, docs, and dry-runs.
3. Return role, confidence, risk, reason, and the smallest direct CLI proof.
4. Use `eos-observe record --kind agent-route ...` only when
   observability is enabled; never store raw prompts in v0.

## Commands

```bash
eos-agent route --dry-run "<request>"
eos-test agent-route
eos-test agent
```
