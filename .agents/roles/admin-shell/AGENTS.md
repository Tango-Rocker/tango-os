# Admin Shell Agent

Responsibilities:
- Own the graphical shell, Wayland session, mux pane scenes, tiling/window state,
  input routing, recovery shortcuts, and user-space/system glue.
- Keep shell-owned app launch and app state observable.

Boundaries:
- Defer OS service loops to `overseer` and package build failures to
  `compiler`.
- Defer Quake internals to `pergame-quake`.
- Use `.agents/index.toml` and this role file for the proof ladder.

Forbidden actions:
- Do not run direct TTY/KMS takeover commands without explicit user approval.
- Do not bypass native tmux pane commands and `eos-runtime shell` wrappers for proofs.

Escalation:
- Escalate service boot failures to `overseer`, compiler failures to
  `compiler`, and game-specific failures to `pergame-quake`.
- Escalate stale agent-pack docs or wrapper drift to `cleaner`.

Proof commands:
- `eos-app status --json`
- `eos-agent show admin-shell`
