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

On an AMD development host, exercise the native pane renderer itself with:

```bash
ENGINEOS_MUX_TEST_RENDERER=gles2 ENGINEOS_MUX_REQUIRE_RADEONSI=true eos-test mux
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

Native mode validates and retains every active tmux pane's full binary terminal
grid and records pane identity, grid revision, dimensions, cursor, and
nonblank-cell evidence in `shell-state.json`. Each pane has its own clipped
wlroots scene subtree, renderer, and double-buffered target; tmux UI uses a
separate overlay. CPU-rasterized FreeType glyphs are cached in a colour-keyed
GPU atlas. Flow-controlled server invalidations retain sparse cell coordinates
for every subscribed pane, update only affected glyph/cursor neighbours with
clipped GPU draws, and pass matching pixel damage to the owning pane scene; no
polling process is involved. Pixman is an explicit
`cpu-pixman-smoke` path, while GLES2 and Vulkan use the atlas path. Every
native output registers as a real tmux client, with one focused size owner, and
keyboard events use tmux key names so prefixes and key tables remain
authoritative in the server. Pointer clicks transfer focused size ownership;
output loss promotes a surviving view. Styled status lines, messages, prompts,
and menus are rendered by tmux, invalidated without polling, retained by the
mux client, and composited over the pane grid at tmux's coordinates. Their
observed mode and geometry are recorded in `shell-state.json`. Pointer motion,
buttons, modifiers, and vertical scroll are mapped to focused-view terminal
cells and sent to tmux for authoritative hit-testing; wheel input uses tmux's
copy-mode bindings. Drag selection, border/status/menu click proofs,
status/menu command activation, AMD radeonsi atlas rendering, sparse cell
damage, nonblank GPU readback, multi-pane scene bounds, independent nonselected
damage, dynamic active-pane adoption, resize, zoom/unzoom, one hundred focus
transitions, inactive-window isolation, join/break/swap, cross-session window
moves, linked windows, detach/reattach, and scoped compound presentations have
contract coverage. Graphical snapshots follow only the attached session's
active window, so linked or inactive windows cannot duplicate pane scenes.
Tmux now assigns every mapped presentation one frontend-client/output-view
lease. Focus transfer, temporary-client disconnect restoration, invalid-view
cleanup, tmux formats, and `shell-state.json` output-view evidence pass against
the exact installed AMD/radeonsi GLES2 packages. Each output now owns a
layout-positioned mux scene root and a console copy for every pane. The live
XDG presentation subtree is reparented only beneath its lease owner's clipped
pane; nonowners retain consoles, while external ownership detaches the local
presentation from all output roots. `shell-state.json` exposes root positions,
pane-copy counts, and bound/visible presentation counts. Native previews are
keyed by pane ID, generation, frontend client, and output-view lease, parented
under the leased pane scene, rejected for external ownership, and reported per
output. Multiple native panes retain independent previews, including pane
`%0`; owner-scoped removal leaves sibling images intact. The installed
radeonsi contract proves decoded images remain on their owning output while
the legacy preview contract remains green. Independent per-output session
models now have a server-side view-addressed snapshot boundary and explicit
focused-output shell refresh. Every registered output also retains its own
validated session, selected-pane, generation, pane-count, and revision model
in `shell-state.json`; the contract proves a nonfocused output can move to
another session without overwriting the focused model and that its cache
follows reattachment. Independent nonfocused grid/UI renderers and input
promotion remain. Each output model already resolves retained, subscribed pane
grids—including panes in a different nonfocused session—and reports grid
readiness, subscription coverage, and selected-grid revision. State
invalidations remain sticky across request servicing so output snapshots
cannot silently miss a concurrent session or layout transition.
Terminal image transport, direct-KMS clipping, ordinary simultaneous
text-client acceptance, and final live hardware acceptance remain before
native mode becomes the default.

## Surface Model

Toplevels are classified as `terminal`, `cube`, `engine`, or `unknown`.
Manifest slots are output-sized and shell-owned. Ordinary unknown views are
managed as floating windows with focus, move, minimize, maximize, and
fullscreen handling.

The normal tmux-integrated GUI path is explicit:

```bash
eos-app pane launch -- COMMAND [ARGS...]
eos-app pane launch --game -- COMMAND [ARGS...]
eos-app pane split -h -- COMMAND [ARGS...]
eos-app pane view app|console|toggle|close
eos-app pane signal INT|TERM|KILL
eos-app pane respawn
eos-app pane list --json
```

In native mode these wrappers call the authoritative `engine-mux` commands.
They never register bridge tokens or fall back after a native command fails.
`--game` selects a game presentation; the shell routes direct Wayland input,
capture, constraints, and cursor confinement to it. `prefix + v` or `pane view
toggle` reveals the retained console and releases capture. `eos-app launch
quake` automatically takes this game-pane path when invoked from a native mux
pane.

In explicit legacy mode, only `pane launch` retains the staged one-shot token
path. The remaining native pane commands fail visibly instead of pretending a
bridge operation is equivalent.

Bindings are stored in memory and published without tokens in
`shell-state.json`. Bound views use `layout=tmux-pane-gui`, are clipped to the
owning terminal output and pane rectangle, and are rendered/focused from tmux
focus events. `eos-app window list|focus|launch` remains diagnostic only.

Cube and output-wide legacy Quake launches still support the older role-specific
`$ENGINEOS_STATE_DIR/launch-bounds/*.env` path for pane/output/fullscreen
launches. Native game panes do not use those files.

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
