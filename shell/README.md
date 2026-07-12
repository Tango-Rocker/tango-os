# EngineOS Shell

engineos-shell is the native wlroots graphical frontend for the EngineOS tmux
3.6b fork. It is not a terminal-slot launcher and has no alternate mux mode.

## Ownership

Tmux owns sessions, windows, panes, PTYs, terminal grids, scrollback, commands,
layouts, presentation scopes, surface tabs, and graphical leases. The shell
owns DRM/KMS, rendering, output registration, clipping, Wayland surface
binding, focus, pointer/keyboard routing, screencopy, and emergency release.

Every output registers a graphical tmux view over
$XDG_RUNTIME_DIR/engineos/mux.sock. Startup fails closed if the authoritative
server cannot complete the handshake and first snapshot.

## Pane Presentation

Every pane retains its PTY console. A pane may additionally present a Wayland,
game, or stream surface. Prefix+v toggles the presentation and backing console.
Extra independent toplevels in the same process scope become pane-local tabs;
popups and transient dialogs remain attached and clipped to their parent.

Graphical clients are accepted only when tmux resolves their PID to the launch
scope created by launch-pane-app. No environment scraping, next-window guess,
launch token, or pixel geometry file participates in binding.

## Input And Rendering

Terminal keys and mouse events are translated to tmux key and mouse frames.
Normal graphical input goes directly to the Wayland seat; prefix sequences
remain tmux commands. Game panes retain pointer constraints, relative pointer
support, and capture toggling. Alt+Tab leaves a pane presentation for its tmux
console and toggles back to the mapped app when pressed again on that pane. On
a pane without a mapped app, Alt+Tab advances tmux windows. Alt+Escape and
Ctrl+Alt+Backspace release graphical input to the backing console; neither
shortcut terminates the compositor.

Terminal grids, borders, status rows, prompts, messages, and menus are rendered
with fcft glyph rasterization and GPU composition. Application buffers are
composed under pane-local clipped scene subtrees. Pane images are fetched from
tmux by pane ID, generation, image ID, and client-view lease.

## IPC And State

The shell preview socket is limited to observability ping, output wallpaper,
wallpaper removal, diagnostic window focus, and relayout. Pane apps and pane
images are tmux commands, not shell IPC.

shell-state.json is observational. It reports mux revisions, output views,
terminal render evidence, presentation leases, mapped surfaces, renderer,
focus, input, wallpaper, and frame commits. It is never a source of layout or
identity.

## Commands

    engineos-shell --headless
    engineos-shell --nested
    engineos-shell --tty
    engineos-shell --smoke-ms 1000

    eos-app pane launch -- falkon
    eos-app pane split -h -- falkon
    eos-app pane view toggle
    eos-app pane signal TERM
    eos-app pane list --json

## Validation

    meson setup build/shell shell
    meson compile -C build/shell
    ./tools/engineos/eos-test mux
    ./tools/engineos/eos-proof native-kms

Direct-TTY acceptance requires the hardware renderer, correct clipping,
nonblank terminal frames, autonomous damage refresh, working grim capture,
recovery tty access, and no silent software fallback.
