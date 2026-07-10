# Engine Mux protocol foundation

This directory is migration stage 1 for the graphical tmux design. The
`engineos-mux` package builds the official tmux 3.6b baseline as the
side-by-side `engine-mux` fork and patches its default socket label to
`engine-mux`; it does not replace `/usr/bin/tmux`. The fork server owns the
versioned frontend boundary and derives snapshots directly from its canonical
session, window, and pane structures.

`engine-mux` exposes a private `SOCK_SEQPACKET` socket at
`$XDG_RUNTIME_DIR/engineos/mux.sock`. Frames have a fixed network-byte-order
header and a bounded payload. The implemented v1 messages are handshake,
complete layout snapshot, full binary terminal-grid snapshot, and explicit
errors. Unsupported command and grid-damage messages fail; they are not
reported as successful.

Run a local contract proof:

```bash
meson setup build/mux mux
meson compile -C build/mux
./tools/engineos/eos-test mux
```

The next migration proof is to export revisioned terminal-grid damage before
the shell renders a terminal pane.
