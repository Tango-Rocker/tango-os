# Backlog

This is the place for useful tangents. Add ideas here instead of expanding the current task.

## Rules

- Keep entries short.
- Include why the idea matters.
- Include the likely phase.
- Do not treat this as a promise to build everything.

## Later Ideas

### Installed Chroma Worker Request CLI

Why: `/usr/bin/chroma-worker request snapshot` passes a `Path` directly to
`socket.connect` and raises `TypeError` on the current Python, although the
Chroma UI client converts the same path to `str` and the live worker/UI path
works. Add a focused CLI contract test when revisiting worker tooling.

Likely phase: current desktop reliability follow-up, separate from live app
mapping acceptance.

### Pixman Nonfocused Presentation Timing

Why: the live terminal-theme assertion passes under both Pixman and GLES2, and
the full GLES2 mux contract passes, but repeated full Pixman runs later time out
while routing a second nonfocused presentation even though state shows it bound
to the intended retained output. This needs a focused timing/RCA pass separate
from terminal theming.

Likely phase: current native-mux hardening after the live radeonsi theme proof.

### Native Ctrl+C Teardown Safety

Why: an unsupported graphical `Ctrl+C` key currently terminates the native
shell, and teardown can then SIGSEGV in `wlr_cursor_detach_input_device` from
`pointer_destroy`. Normal pane signals must not take down tty1, and recovery
cleanup must be safe even after an input-routing error.

Likely phase: current native-mux hardening, immediately after physical refresh
acceptance and before legacy-path removal.

### Falkon Pane Stress Proof

Why: process-scope binding and pane scene layout are covered by tests, but the
live terminal-to-Falkon focus path still needs a repeated switch test with a
real mapped Qt surface and captured evidence.

Likely phase: current shell PoC, after screen capture or another accepted visual
evidence path exists.

### Boot Validation Cleanup

Why: the active AMD shell reports radeonsi hardware rendering, while the broad
boot gate still fails on missing recovery assets and an unrelated llvmpipe
device heuristic.

Likely phase: current bare-metal runtime gate; make the validator identify the
active shell renderer and require the tracked recovery units/files.

### Package Signing

Why: useful once the local package repo is stable.

Likely phase: after MVP or late polish.

### Rich 3D Cockpit

Why: this is part of the long-term identity of the project.

Likely phase: after the shell can boot, launch clients, recover input, and collect logs on bare-metal AMD.

### Steam or Proton Research

Why: useful for a broader game appliance later.

Likely phase: after MVP.

### Multi-Monitor Dynamic Layout

Why: useful once single-monitor TTY/KMS behavior is stable.

Likely phase: polish after MVP.

### Shell Overlays And Tiling

Why: compositor-owned overlays, window placement, and tiling are the right way
to draw above terminal/game/app surfaces without pretending clients share one GL
context.

Likely phase: after bare-metal GL shell startup and input recovery are proven.
