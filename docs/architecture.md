# EngineOS Architecture

EngineOS is an Arch-based bare-metal development OS. The active graphical stack
has two authorities with a strict boundary.

## Tmux Server

The EngineOS tmux 3.6b fork is installed as /usr/bin/tmux and replaces the
upstream distribution package. It owns sessions, windows, panes, PTYs,
foreground process groups, terminal grids, scrollback, commands, layouts,
presentation scopes, surface tabs, images, and graphical leases. Standard tmux
commands, formats, configuration, plugins, local text clients, and SSH clients
remain compatible.

The default server publishes $XDG_RUNTIME_DIR/engineos/mux.sock. The versioned
SOCK_SEQPACKET protocol carries revisioned snapshots, cell damage, UI models,
input, presentation lifecycle, image chunks, and explicit errors.

## Graphical Shell

engineos-shell remains the wlroots compositor. It owns DRM/KMS, GBM/EGL,
hardware rendering, outputs, scene trees, clipping, focus, the Wayland seat,
pointer constraints, screencopy, wallpaper, recovery controls, and
observational state.

Each output registers a graphical tmux view. The focused view determines
canonical PTY size. Terminal grids and tmux UI are rendered with fcft glyph
rasterization and GPU composition. Wayland presentation buffers are composed
inside clipped pane scene subtrees.

## Pane Contract

Every pane always retains a PTY console. A pane can additionally present a
Wayland, game, or stream surface. A graphical command remains the PTY foreground
job, and Prefix+v toggles the presentation and console.

launch-pane-app creates a dedicated transient user scope. The shell maps only
clients whose PID tmux resolves to that scope. Independent toplevels become
pane-local tabs and transient surfaces stay attached to their parent. When the
app exits, tmux removes the presentation and restores the console.

## Input

Console keys and mouse events go to tmux. Graphical input goes to the Wayland
seat, except prefix sequences, which remain tmux commands. Game panes retain
relative pointer, constraints, capture, and emergency release.

## Observability And Recovery

shell-state.json reports mux revisions, views, renderer evidence, frame commits,
presentation leases, surfaces, images, focus, and input. It is never
authoritative. tty1 runs the compositor; the recovery tty and crash/log tools
remain independent of graphical success.

## Removed Architecture

There is no mux mode switch, side-by-side server, graphical terminal bootstrap,
terminal registration, proxy window, hook bridge, launch token, environment
scrape, pane geometry IPC, persisted pixel geometry, or automatic fallback.

ISO and VM materials remain historical references; live acceptance uses local
package builds and bare-metal proofs.
