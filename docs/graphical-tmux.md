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

## Implemented foundation

The migration is side by side and disabled by default:

- `engine-mux` is built from the pinned official tmux 3.6b release with a
  fork-local default socket namespace; upstream `/usr/bin/tmux` is untouched.
- `engine-muxd` requires exactly tmux 3.6b and exposes
  `$XDG_RUNTIME_DIR/engineos/mux.sock` as a same-user `SOCK_SEQPACKET` socket.
- Protocol v1 frames contain magic, version, type, request ID, state revision,
  payload length, and flags in network byte order.
- Handshake, atomic complete layout snapshots, and explicit protocol errors are
  implemented. Snapshots contain stable tmux pane IDs, layout, PTY identity,
  canonical rows/columns, process metadata, and the initial terminal
  presentation model.
- Layout content changes advance the server revision. Mutation requests with a
  stale revision are rejected and direct the client to request a full snapshot.
- `engineos-shell --mux native` (or `ENGINEOS_MUX_MODE=native`) requires a
  successful v1 handshake and snapshot before compositor setup. Failure does
  not fall back to the bridge. The observed mode, socket, connection state, and
  mux revision are written to `shell-state.json`.

The current separately packaged fork baseline and `engine-muxd` process are a
protocol proof, not the cutover architecture. They deliberately
expose only `layout-snapshot`; command execution, grid transport, and graphical
presentation ownership return explicit unsupported errors.

## Required next proof

Move the frontend socket into the `engine-mux` server process and run the
upstream tmux suite unchanged. Then add compact
terminal grid snapshots/damage and render one terminal-only mux session in
`engineos-shell` before adding app scopes or removing any bridge code.

Later stages add compound presentations and `prefix + v`, dedicated transient
app scopes, surface-to-scope binding, multiple output views and presentation
leases, game panes, and pane-local images. The legacy bridge, geometry IPC,
launch tokens, launch-bounds files, and shell-owned foot bootstrap are removed
only after native live acceptance.

## Contract proof

```bash
./tools/engineos/eos-test mux
./tools/engineos/eos-preflight repo --package engineos-mux --package engineos-shell
./tools/engineos/eos-lint packages --package engineos-mux --package engineos-shell
```

The mux test creates a real isolated tmux server, reads its initial snapshot,
performs a real split, proves the snapshot revision and pane count change, and
checks stale-request and shell fail-closed behavior.
