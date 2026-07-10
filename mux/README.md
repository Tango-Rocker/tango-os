# Engine Mux protocol foundation

This directory is migration stage 1 for the graphical tmux design. The
`engineos-mux` package builds the official tmux 3.6b baseline as the
side-by-side `engine-mux` fork and patches its default socket label to
`engine-mux`; it does not replace `/usr/bin/tmux`. `engine-muxd` proves the
versioned frontend boundary against that canonical server. Native mode fails
if the baseline is not exactly tmux 3.6b.

`engine-muxd` exposes a private `SOCK_SEQPACKET` socket at
`$XDG_RUNTIME_DIR/engineos/mux.sock`. Frames have a fixed network-byte-order
header and a bounded payload. The implemented v1 messages are handshake,
complete layout snapshot, and explicit errors. Unsupported command or grid
messages fail; they are not reported as successful.

Run a local contract proof:

```bash
meson setup build/mux mux
meson compile -C build/mux
./tools/engineos/eos-test mux
```

The next migration proof is to move this protocol implementation into the
`engine-mux` server process and export terminal grid snapshots/damage before
the shell renders a terminal pane.
