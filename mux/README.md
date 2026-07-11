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
input, graphical mouse input, focused-view transfer, semantic UI models, and
explicit errors. Snapshot requests can name a registered graphical view; the
response identifies its frontend client, view, and output and contains only
that synthetic tmux client's attached session and active window. A stale,
foreign, or unregistered view is an error rather than an implicit fallback to
the globally focused client. The UI
model exports styled status rows, prompts and their input/screen cursors,
messages, and tmux-rendered menu rows with selection, keys, and command
metadata. Stale
revisions fail with an explicit complete resynchronization requirement.
Unsupported command messages fail; they are not reported as successful. Layout
snapshots expose copy-mode/history state.

After the first UI request, tmux hashes the rendered per-view model and sends a
bounded invalidation only when it changes. This updates status, message, prompt,
and menu presentation without compositor polling.

Each native shell output registers as a real tmux client attached to the
selected session. Its grid dimensions participate in tmux's normal canonical
size calculation, while secondary nonfocused views ignore size. Discrete key
frames enter `server_client_handle_key`, so configured prefixes, key tables,
copy-mode bindings, formats, and plugins keep tmux semantics. Graphical clients
do not own a terminal tty and are excluded only from tty redraw/reset paths.
Focused-view requests atomically promote one graphical size owner and demote
all others. Disconnecting that owner promotes a surviving graphical client.

Mouse frames carry cell coordinates, press/release/motion/wheel state, and
Shift/Meta/Ctrl modifiers for the focused graphical view. The frontend creates
the same SGR mouse state as a terminal client and passes it through tmux's
normal client-key path. Tmux therefore remains authoritative for pane, border,
status, menu, and copy-mode hit-testing and bindings. Persistent mouse
sequences retain tmux's button and overlay state across frames, with an
event-loop barrier between actions. The contract proves drag selection, border
resize, ranged status selection, menu opening, and menu-item activation.

Run a local contract proof:

```bash
meson setup build/mux mux
meson compile -C build/mux
./tools/engineos/eos-test mux
```

The next migration proof is retaining and rendering each output's scoped model
concurrently, followed by terminal-image transport and direct-KMS acceptance.
