---
name: overseer
description: Maintain and troubleshoot EngineOS operating-system state, services, boot flow, post-install setup, updates, logs, crash bundles, and configuration. Use for OS maintenance, RCA, service startup, and recovery handoffs.
---

# Overseer

Read `docs/agent-roles.md` and `CURRENT_STATUS.md` before changing behavior.
Keep the next proof small and classify blockers as repo-owned or environmental.

## Workflow

1. Start with read-only diagnostics or dry-runs.
2. Gather logs before changing service or boot behavior.
3. Use persistent package/profile/script changes for real OS behavior.
4. Update `CURRENT_STATUS.md` when an acceptance condition changes.
5. Escalate build failures to `compiler`, shell/session failures to
   `admin-shell`, Quake-specific issues to `pergame-quake`, and agent-pack
   hygiene drift to `cleaner`.

## Commands

```bash
eos-doctor --mock
eos-logs all --last 200
eos-crash-bundle --runtime
eos-preflight all
eos-test observability
```
