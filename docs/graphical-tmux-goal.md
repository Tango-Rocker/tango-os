# EngineOS Native Graphical Tmux Goal

## Objective

Ship one tmux-compatible EngineOS desktop architecture. The EngineOS tmux 3.6b
fork is the authoritative session, window, pane, PTY, terminal, command,
layout, presentation, and image server. engineos-shell is its native Wayland
frontend and owns hardware display, composition, clipping, outputs, focus, and
input.

Every pane always retains a PTY console and may additionally present a Wayland,
game, or stream surface. Prefix+v toggles between the presentation and live
console. A graphical command remains the pane foreground process, and exiting
it restores the prompt.

## Required Runtime

- Install the fork as /usr/bin/tmux and replace the distribution tmux package.
- Preserve standard tmux commands, configuration, formats, plugins, text
  clients, and SSH attachment.
- Serve the graphical protocol from the default tmux server at
  $XDG_RUNTIME_DIR/engineos/mux.sock.
- Export revisioned layouts, terminal grids, damage, UI, input, presentation
  lifecycle, images, and errors.
- Register one graphical view per output and let the focused graphical view set
  canonical PTY size.
- Give each graphical presentation one live output lease.
- Resolve Wayland clients through dedicated launch scopes.
- Treat extra toplevels as pane-local tabs and keep transients attached.
- Render terminal grids and tmux UI with fcft plus GPU composition.
- Keep tty1 startup, recovery tty, emergency release, grim, logs, and
  observational shell-state.json.

## Native Commands

    launch-pane-app [-t pane] -- COMMAND
    split-pane-app [-h|-v] -- COMMAND
    pane-presentation [-t pane] app|console|toggle|close
    signal-pane-app [-t pane] INT|TERM|KILL
    respawn-pane-app [-t pane]
    pane-image [-t pane] show|hide ...

Wrappers:

    eos-app pane launch -- COMMAND
    eos-app pane split [-h|-v] -- COMMAND
    eos-app pane view app|console|toggle|close
    eos-app pane signal SIGNAL
    eos-app pane respawn
    eos-app pane list --json

## Completed Cutover Tasks

- Package the fork as the system tmux provider/replacement.
- Restore the normal tmux default socket namespace.
- Make shell startup native-only and fail closed.
- Remove shell-owned graphical terminal bootstrap and Foot dependency.
- Remove alternate mux binary and mode selection.
- Remove terminal registration and pane focus/geometry IPC.
- Remove launch tokens, environment scraping, and launch-bound files.
- Remove proxy windows and tmux hook subprocesses.
- Remove graphical terminal launcher and eos-terminal wrapper.
- Route cube, Falkon, Quake, pane images, keys, mouse, status, menus, and copy
  mode through native tmux commands/protocol.
- Replace rollback tests and proofs with native-only contracts.
- Update runtime configuration, packages, docs, recovery, and deployment paths.

## Acceptance Matrix

### Tmux compatibility

- Upstream tmux regression suite passes unchanged.
- Local and SSH PTY clients retain full terminal behavior.
- Split, resize, zoom, join, break, move-window, detach, and reattach work.
- Prefix bindings, formats, plugins, copy mode, prompts, status, and menus work.

### Terminal behavior

- stdout, stderr, ANSI, cursor, scrollback, signals, and foreground jobs work.
- Initial terminal frames and later damage refresh without clicks or view
  switches.
- Multiple panes retain independent grids and images.

### Graphical behavior

- Falkon maps only to its launch scope, accepts keyboard and pointer input,
  closes normally, toggles to console, and restores the prompt.
- Extra toplevels become tabs; dialogs and popups position and clip correctly.
- Quake retains capture, relative pointer, audio, emergency release, and console
  recovery.
- A presentation or image appears only on its lease owner.

### Hardware and recovery

- tty1 starts with DRM/libinput and the hardware renderer.
- No silent pixman, llvmpipe, softpipe, or other software fallback.
- Pane clipping is correct and terminal frames are nonblank.
- grim captures the composed output.
- Recovery tty, logs, crash bundles, and shell-state.json remain valid.

### Deletion proof

- /usr/bin/engine-mux is absent.
- No mux-mode setting or shell mux option exists.
- No hook subprocess, proxy window, environment scrape, launch token,
  terminal registration, launch-bound file, or persisted pane pixel geometry
  exists.
- Exactly one tmux pane/layout model is authoritative.

## Final Proof Commands

    ./tools/engineos/eos-test mux
    ./tools/scripts/tmux_upstream_regress.sh
    ./tools/engineos/eos-lint packages
    ./tools/engineos/eos-preflight all
    eos-proof shell-launch --bare-metal
    eos-proof native-kms
    eos-proof native-falkon
    eos-proof native-quake
    eos-validate boot --bare-metal

## Completion Rule

The goal is complete only after the native packages are installed on the live
host, the default tmux server and tty1 shell are running the new binaries, the
hardware proofs pass, and the deletion proof finds no rollback runtime path.

## Cutover Record

The irreversible package and tty1 cutover was performed on 2026-07-11. The
system tmux provider owns the default server and graphical frontend socket;
the hardware shell, immediate terminal refresh, Grim capture, scoped Falkon
presentation, presentation lease, and console restoration were proven live.
The final old server process exists only for the maintenance pane that executed
the migration and is retired when that pane exits; it no longer owns the
desktop frontend socket.
