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

- `engine-mux` is built from the official tmux 3.6b tag commit
  `0623d1e968423ad0c192e0d8debf1258671063d5` with a fork-local default
  socket namespace; upstream `/usr/bin/tmux` is untouched.
- The `engine-mux` server exposes `$XDG_RUNTIME_DIR/engineos/mux.sock` as a
  same-user `SOCK_SEQPACKET` socket and derives snapshots directly from tmux's
  authoritative structures. Explicit `-L` and `-S` servers retain ordinary
  tmux behavior and do not compete for the canonical graphical socket.
- Protocol v1 frames contain magic, version, type, request ID, state revision,
  payload length, and flags in network byte order.
- Handshake, atomic complete layout snapshots, and explicit protocol errors are
  implemented. Snapshots contain stable tmux pane IDs, layout, PTY identity,
  canonical rows/columns, process metadata, and the initial terminal
  presentation model.
- A versioned binary full-grid frame exports the visible tmux `screen` without
  sending PTY bytes. Its fixed cells preserve up to 32 bytes of UTF-8 and
  combining data, width/padding, attributes, colours, underline colour,
  hyperlinks, cursor state, and alternate-screen state. The decoder contract
  proves ANSI colour plus wide and combining Unicode cells.
- Layout content changes advance the server revision. Mutation requests with a
  stale revision are rejected and direct the client to request a full snapshot.
- `engineos-shell --mux native` (or `ENGINEOS_MUX_MODE=native`) requires a
  successful v1 handshake and snapshot before compositor setup. Failure does
  not fall back to the bridge. The observed mode, socket, connection state, and
  mux revision are written to `shell-state.json`.

The in-server frontend exposes `layout-snapshot` and `terminal-grid-v1`.
Command execution, grid damage, scrollback, and graphical presentation
ownership still return explicit unsupported errors.

## Required next proof

Add per-pane grid revisions and compact damage frames, then render one
terminal-only mux session in `engineos-shell` before adding app scopes or
removing any bridge code.

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

## Upstream baseline and rebase procedure

The fork baseline is the exact commit above, not a moving `3.6b` reference.
Its GitHub commit archive is pinned in `packages/engineos-mux/PKGBUILD` with a
SHA-256 checksum. The commit archive is used because the release archive omits
the upstream `regress/` directory.

The unchanged upstream regression scripts were run against both a pristine
build and the patched fork on the Arch EngineDev host. Both matrices matched:
21 scripts passed and the same 11 scripts failed (`combine-test`,
`command-order`, `copy-mode-test-vi`, `cursor-test1` through `cursor-test4`,
`if-shell-TERM`, `input-keys`, `tty-keys`, and `utf8-test`). This is baseline
parity, not a claim that the host passes tests which also fail in pristine
tmux. In particular, `new-session-environment` passes in both builds and guards
normal custom-socket behavior when `XDG_RUNTIME_DIR` is absent.

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
