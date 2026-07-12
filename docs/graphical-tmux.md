# Native Graphical Tmux

EngineOS uses one authoritative tmux 3.6b fork installed as /usr/bin/tmux.
The default tmux server owns every session, window, pane, PTY, grid, scrollback,
command, layout, presentation scope, and presentation lease. engineos-shell is
the native graphical frontend and compositor.

The server exposes a versioned SOCK_SEQPACKET frontend at
$XDG_RUNTIME_DIR/engineos/mux.sock. JSON frames carry layout, lifecycle, UI,
commands, input, and errors; compact binary frames carry terminal grids and
cell damage. Revisions make layout changes atomic and stale requests explicit.

Every pane always has a PTY console and may additionally have terminal,
Wayland, game, or stream presentation. Prefix+v toggles presentation and
console. Graphical apps run as normal foreground PTY jobs in dedicated user
scopes. The compositor maps a Wayland client only after tmux resolves its PID
to that scope.

Additional toplevels from the same scope become tabs. Popups remain attached
to parents. Each presentation has one live graphical output lease; other views
show the backing console and metadata.

Runtime commands:

    launch-pane-app [-t pane] -- COMMAND
    split-pane-app [-h|-v] -- COMMAND
    pane-presentation [-t pane] app|console|toggle|close
    signal-pane-app [-t pane] INT|TERM|KILL
    respawn-pane-app [-t pane]
    pane-image [-t pane] show|hide ...

Ergonomic wrappers:

    eos-app pane launch -- COMMAND
    eos-app pane split -h -- COMMAND
    eos-app pane view toggle
    eos-app pane signal TERM
    eos-app pane list --json

The final cutover removed the alternate engine-mux binary, mode switches,
shell-owned Foot bootstrap, proxy windows, terminal registration, geometry
IPC/files, launch tokens, environment scraping, bridge hooks, and rollback
fallbacks. Ordinary local and SSH tmux clients remain supported.

Validation:

    ./tools/engineos/eos-test mux
    ./tools/scripts/tmux_upstream_regress.sh
    eos-proof native-kms
    eos-proof native-falkon
    eos-proof native-quake
