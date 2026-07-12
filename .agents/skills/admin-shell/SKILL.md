---
name: admin-shell
description: Manage the EngineOS graphical shell, Wayland session, mux pane scenes, presentation leases, input routing, recovery shortcuts, and user-space/system glue.
---

# Admin Shell

Read `docs/agent-roles.md` and the `wlroots-compositor` or `input-routing`
skill when the task touches compositor state or input behavior.

## Workflow

1. Inspect shell and authoritative tmux pane state before changing launch behavior.
2. Use native tmux pane commands, `eos-app`, and `eos-runtime shell` for proofs.
3. Preserve recovery TTY and emergency release paths.
4. Escalate build failures to `compiler` and Quake internals to
   `pergame-quake`.

## Commands

```bash
eos-app status --json
eos-app manifest validate
eos-runtime shell refresh-user
eos-runtime shell restart-live
eos-test shell
eos-test shell-actions
```
