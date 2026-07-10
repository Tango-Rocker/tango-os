# EngineOS Shell

This directory contains the wlroots 0.19 compositor used by the live EngineDev
installation. `engineos-shell` owns the Wayland display, outputs, scene graph,
input routing, app surfaces, pane-bound GUI views, and image overlays.

## Run And Prove

```bash
eos-runtime shell --headless
eos-runtime shell --nested
eos-runtime shell restart-live
eos-app manifest validate
eos-app status --json
eos-test shell-actions
eos-test shell
eos-test input
```

The live shell is managed by `engineos-dev-shell.service`. Use
`eos-runtime shell refresh-user` after changing tmux/user helpers and
`eos-runtime shell restart-live` for a verified PID-replacing restart.

Native graphical mux migration is opt-in with `--mux native` or
`ENGINEOS_MUX_MODE=native`. That mode must connect to
`$XDG_RUNTIME_DIR/engineos/mux.sock` (override with `ENGINEOS_MUX_SOCKET`) and
receive a valid versioned snapshot before compositor setup. The default remains
`legacy` until the terminal-grid renderer reaches live acceptance. See
[`docs/graphical-tmux.md`](../docs/graphical-tmux.md).

Native mode also selects the active tmux pane, validates and retains its full
binary terminal grid, and records pane identity, grid revision, dimensions,
cursor, and nonblank-cell evidence in `shell-state.json`. A pane-local scene
subtree displays a CPU-rasterized FreeType terminal buffer through wlroots
composition. Damage refresh, glyph-atlas caching, and live hardware acceptance
remain before native mode becomes the default.

## Surface Model

Toplevels are classified as `terminal`, `cube`, `engine`, or `unknown`.
Manifest slots are output-sized and shell-owned. Ordinary unknown views are
managed as floating windows with focus, move, minimize, maximize, and
fullscreen handling.

The normal tmux-integrated GUI path is explicit:

```bash
eos-app pane launch -- COMMAND [ARGS...]
eos-app pane focus
eos-app pane geometry
eos-app pane unbind
eos-app pane list --json
```

`pane launch` requires a managed terminal and tmux context. It registers a
one-shot token with the shell and places the token in the launched client's
environment. The shell binds only the exact mapped Wayland process carrying
that pending token. Missing, duplicate, expired, and unknown tokens fail
explicitly.

Bindings are stored in memory and published without tokens in
`shell-state.json`. Bound views use `layout=tmux-pane-gui`, are clipped to the
owning terminal output and pane rectangle, and are rendered/focused from tmux
focus events. `eos-app window list|focus|launch` remains diagnostic only.

Cube and Quake still support the older role-specific
`$ENGINEOS_STATE_DIR/launch-bounds/*.env` path for pane/output/fullscreen
launches. Generic Qt/browser/editor binding does not use those files.

## Tmux Bridge

Managed terminals register their real tty and output slot before attaching to
tmux. `engineos-tmux-pane-bridge` is called by tmux hooks and reports exact
socket, session, window, pane, client tty, focus, and geometry over shell IPC.
It handles every session in the active server.

The bridge is event-driven. It does not create proxy GUI windows, poll every
few seconds, infer bindings from titles/commands, or store authority in tmux
options. Shell state is authoritative.

The primary terminal uses `engineos-tmux-attach-primary`, which reattaches an
existing work session before creating the fallback `engineos` session. The
secondary terminal uses `engineos-side`. Both clients share one tmux server.

Right-clicking a window name in the tmux status bar keeps the standard window
menu and adds `Move to Session...`. With one other session, that action moves
the clicked stable window ID immediately. With multiple destinations, tmux's
native session chooser opens; double-click a session or select it and press
Enter. The move uses the destination's next free index and runs a pane-bridge
sync.

Right-clicking the session name keeps tmux's session menu, but `New Session`
uses an EngineOS-safe sequence: create an auto-named session detached, capture
its stable ID, then switch only the invoking client. A shell-owned terminal
therefore remains open while its tmux client changes sessions.

## Image Preview

The shell listens on `$XDG_RUNTIME_DIR/engineos/preview.sock`, or the equivalent
path under `$ENGINEOS_STATE_DIR`. The socket accepts same-UID peers, uses
newline-framed bounded JSON, and lives in a private state directory.

`engine-image-preview` includes tmux pane identity and client tty. The shell
resolves the exact registered terminal output; ambiguous ownership is rejected.
PNG/JPEG parsing lives in `shell/src/engineos-image.c`, decoded dimensions are
bounded, and the scene buffer is clipped to the target pane.

```bash
engine-image-preview --quick-view IMAGE --panel right
engine-image-preview --wallpaper IMAGE --opacity 70
engine-image-preview --hide
eos-app recover preview
eos-proof mc-preview
```

MC Quick View replaces the same owner-scoped preview as selection changes.
Old watcher processes cannot hide a newer preview. Unmodified `F3` closes the
visible shell-owned preview or wallpaper surface.

## Input And Focus

The shell tracks `shell`, `terminal`, and `game` modes. Keyboard and pointer
focus follow the selected view. Quake capture hides the cursor, uses relative
pointer/constraint protocols for mouselook, and releases on `Alt+C`,
`Alt+F1/F2`, or `Ctrl+Alt+Backspace`.

Core bindings:

- `Alt+Escape`: exit shell
- `Alt+Tab`: cycle mapped toplevels
- `Alt+1`, `Alt+2`, `Alt+3`: terminal, cube, Quake slots
- `Alt+Return`: launch terminal
- `Alt+G`: launch Quake
- `Alt+F1/F2/F3`: shell, terminal, game input modes
- `Alt+F9` or `Alt+M`: minimize focused floating window
- `Alt+F10` or `Alt+X`: toggle maximize
- `Alt+Arrow`: move focused floating window
- `Alt+C`: toggle game capture
- `Ctrl+Alt+Backspace`: emergency release

The shell also exposes clipboard, primary-selection, data-control,
drag-and-drop, relative-pointer, and pointer-constraint protocols needed by
terminal, Qt/editor, and game clients. Xdg popups remain parented to their
toplevel scene tree.

## State And Logs

```text
/run/user/1000/engineos/shell-state.json
/run/user/1000/engineos/preview.sock
/var/log/engineos/shell.log
/etc/engineos/apps.toml
```

State records bootstrap/slot/input state, windows, token-free pane bindings,
terminal client registrations, and launch records. `eos-app status --json` and
`eos-app pane list --json` expose the supported diagnostic views.

## Build

Build against the live Arch/wlroots environment:

```bash
./tools/engineos/eos-build shell
./tools/engineos/eos-preflight repo --package engineos-shell
./tools/engineos/eos-ci local \
  --package engineos-shell \
  --test shell-actions --test shell --test input \
  --install --clean-generated --no-validate-repo
```

The shell fails closed when its real binary, required renderer evidence, IPC
state, or acceptance artifacts are missing. Dry-run output and metadata-only
captures do not count as live rendering proof.
