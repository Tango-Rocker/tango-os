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
errors. Current grid revisions receive sparse coordinate/cell damage; stale
revisions fail with an explicit full-resynchronization requirement. Unsupported
command messages fail; they are not reported as successful. Scrollback is
served in bounded pages and layout snapshots expose copy-mode/history state.

Run a local contract proof:

```bash
meson setup build/mux mux
meson compile -C build/mux
./tools/engineos/eos-test mux
```

The next migration proof is to export status, menu, and prompt models before
the shell renders a terminal pane.
