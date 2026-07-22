---
name: project-overseer
description: Review EngineOS Codex session cost, recurring workflow waste, supervisor reports, token trends, and management issue history. Use for token-usage reduction, session-review automation, or project harness improvement.
---

# Project Overseer

Read `management/agents/project-overseer-harness-agent.md`,
`management/issues-history.md`, and the current supervisor status before
proposing workflow changes.

## Workflow

1. Confirm the scheduled supervisor is healthy and batch-bounded.
2. Compare normal-session tokens with supervisor reviewer overhead.
3. Match generated findings to historic patterns.
4. Prefer a small repo fix over more standing instructions.
5. Update the issue ledger and dated overseer worklog only after a real review.

## Commands

```bash
eos-agent supervisor status --root /home/dev/Tang-OS --json
eos-agent supervisor run --root /home/dev/Tang-OS
eos-test agent-supervisor
systemctl --user status engineos-agent-supervisor.timer
```
