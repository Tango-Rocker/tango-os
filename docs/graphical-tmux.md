# Graphical tmux migration

The complete objective, ordered workstreams, and final acceptance contract are
defined in [graphical-tmux-goal.md](graphical-tmux-goal.md). This document
records the migration design and current implemented foundation.

EngineOS is migrating from the tmux pane bridge to a native graphical frontend
for a tmux 3.6b fork. Tmux remains authoritative for sessions, windows, panes,
PTYs, terminal grids, commands, and layout. `engineos-shell` remains the
Wayland compositor and owns rendering, clipping, outputs, focus, input, and
application surfaces.

Every pane has a permanent console (PTY, terminal grid, cursor, images, and
scrollback) and one presentation (`terminal`, `wayland`, `game`, or `stream`).
A graphical presentation sits above its console; it does not replace the PTY.
The final `prefix + v` binding switches the visible layer.

## Implemented stack

The migration remains side by side and disabled by default, but the native path
now covers the complete terminal and compound-presentation foundation:

- `engine-mux` is pinned to tmux 3.6b commit
  `0623d1e968423ad0c192e0d8debf1258671063d5` and owns the same-user,
  revisioned `SOCK_SEQPACKET` frontend.
- Tmux exports authoritative pane topology, binary grids, sparse damage,
  scrollback, copy mode, status, borders, menus, prompts, mouse classification,
  graphical client views, and presentation leases. The compositor never parses
  PTY escape sequences or reconstructs tmux layout.
- `engineos-shell` keeps one clipped GPU terminal target per pane and one scene
  copy per output. AMD/radeonsi GLES2 evidence covers glyph-atlas rendering,
  sparse updates, nonblank readback, multi-pane scenes, topology changes, and
  two-output lease isolation.
- Wayland presentations are bound by transient systemd scope, not environment
  matching. Popups and transients stay with their parents; independent
  toplevels become pane-local tabs. `prefix + v` switches to the retained
  console.
- Native `game` presentations use the same scope and lease model, route direct
  Wayland input, capture and confine the cursor, release capture in console
  mode, and preserve their type across respawn. Native `eos-app pane` wrappers
  call `engine-mux` directly; `eos-app launch quake` selects a game pane.
- Pane previews are keyed by pane ID, generation, frontend client, and output
  lease, render on only the owning output, and coexist independently across
  panes. Owner-scoped removal cannot clear a sibling pane's image.
- Snapshot requests may address an exact graphical output view. Tmux returns
  only that synthetic client's attached session and active window, identifies
  the client/view/output in the response, and rejects stale or foreign view
  IDs. The shell uses this scope for focused-output refreshes; caching and
  rendering now remain live for every nonfocused output concurrently.
- Ordinary local and SSH `xterm-256color` clients can attach through real PTYs
  beside two graphical views. Both render the graphical pane's backing console
  and presentation metadata, execute the tmux command prompt, and drive
  `prefix + v`. The SSH contract verifies generated-key authentication and a
  forced remote command PTY against an isolated loopback OpenSSH server.
  Registered graphical views retain canonical window sizing, so smaller text
  clients receive normal tmux padding instead of resizing the desktop; windows
  without graphical views retain upstream sizing behavior.

## Remaining acceptance boundary

Before cutover, prove real Falkon and Quake sessions, user-asset Quake capture
and emergency release, the complete upstream suite, and the bare-metal
boot/recovery gate. Native mode then becomes the default;
only after that acceptance are the bridge, hooks, launch tokens, geometry
files, shell-owned foot bootstrap, and rollback path removed.

## Contract proof

```bash
./tools/engineos/eos-test mux
./tools/engineos/eos-test app
./tools/engineos/eos-test game-workflow
./tools/engineos/eos-preflight repo --package engineos-mux --package engineos-shell
./tools/engineos/eos-lint packages --package engineos-mux --package engineos-shell
ENGINEOS_MUX_TEST_RENDERER=gles2 ENGINEOS_MUX_REQUIRE_RADEONSI=true \
  ./tools/engineos/eos-test mux
eos-proof native-kms
```

The mux contract uses a real isolated tmux server, deterministic PTY and
Wayland clients, two compositor outputs, and the selected renderer. It covers
grid and UI transport, topology lifecycle, leases, previews, Wayland tabs and
transients, game capture/console transitions, respawn, and teardown. The app
and game-workflow contracts separately prove native wrapper routing and that
pane-owned Quake executes its runner in the foreground instead of escaping to
the user service. `eos-proof native-kms` is the live-only gate: it temporarily
restarts tty1 against an isolated native session, captures split/resize/zoom
state and KMS logs, and restores the prior desktop mode.

## Upstream baseline and rebase procedure

The fork baseline is the exact commit above, not a moving `3.6b` reference.
Its GitHub commit archive is pinned in `packages/engineos-mux/PKGBUILD` with a
SHA-256 checksum. The commit archive is used because the release archive omits
the upstream `regress/` directory.

The unchanged upstream regression scripts are run against both a pristine
build and the patched fork on the Arch EngineDev host. The original matrix was
21 pass and 11 host failures. The 2026-07-10 rerun matched at 23 pass and 9
failures for both builds. `copy-mode-test-vi` and `cursor-test4` vary across
repeated runs in both trees, so the acceptance signal is no fork-only stable
failure rather than one lucky invocation. This is baseline parity, not a claim
that the host passes tests which also fail in pristine tmux. In particular,
`new-session-environment` passes in both builds and guards normal custom-socket
behavior when `XDG_RUNTIME_DIR` is absent.

For an upstream rebase:

1. Select and record one exact upstream commit, update `_commit`, the archive
   checksum, and `pkgver` if applicable.
2. Reapply the default-namespace patch, then port the in-server frontend patch
   against the new `server.c`, `tmux.h`, and build manifest. Do not replace
   direct tmux structure access with command subprocesses.
3. Build a pristine tree and the patched tree with the same configure flags.
4. Run every upstream `regress/*.sh` script unchanged against both binaries in
   isolated runtime directories. Investigate every matrix difference; do not
   accept a fork-only failure.
5. Run `./tools/engineos/eos-test mux`, package preflight/lint, and the live
   native-shell proof before changing the recorded baseline.
