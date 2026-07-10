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
complete layout snapshot, full binary terminal-grid snapshot, sparse grid
damage, scrollback pages, pane input, graphical-view registration, tmux key
input, focused-view transfer, and explicit errors. Stale revisions fail with an
explicit complete resynchronization requirement. Unsupported command messages
fail; they are not reported as successful. Layout snapshots expose
copy-mode/history state.

Each native shell output registers as a real tmux client attached to the
selected session. Its grid dimensions participate in tmux's normal canonical
size calculation, while secondary nonfocused views ignore size. Discrete key
frames enter `server_client_handle_key`, so configured prefixes, key tables,
copy-mode bindings, formats, and plugins keep tmux semantics. Graphical clients
do not own a terminal tty and are excluded only from tty redraw/reset paths.
Focused-view requests atomically promote one graphical size owner and demote
all others. Disconnecting that owner promotes a surviving graphical client.

Run a local contract proof:

```bash
meson setup build/mux mux
meson compile -C build/mux
./tools/engineos/eos-test mux
```

The next migration proof is status, menu, and prompt models, followed by mouse
and copy-mode interaction.
