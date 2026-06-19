---
name: admin-shell
description: Manage the EngineOS graphical shell, Wayland session, app slots, tiling/window state, input routing, recovery shortcuts, and user-space/system glue. Use for shell-owned app launch, window state, focus, and runtime desktop behavior.
---

# Admin Shell

Read `docs/agent-roles.md` and the `wlroots-compositor` or `input-routing`
skill when the task touches compositor state or input behavior.

## Workflow

1. Inspect shell/app state before changing launch behavior.
2. Use `eos-app` and `eos-runtime shell` wrappers for proofs.
3. Preserve recovery TTY and emergency release paths.
4. Escalate build failures to `compiler` and Quake internals to
   `pergame-quake`.

## Commands

```bash
eos-app status --json
eos-app manifest validate
eos-proof launchpad --runtime --dry-run
eos-test shell-actions
```
