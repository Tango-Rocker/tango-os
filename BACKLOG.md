# Backlog

This is the place for useful tangents. Add ideas here instead of expanding the current task.

## Rules

- Keep entries short.
- Include why the idea matters.
- Include the likely phase.
- Do not treat this as a promise to build everything.

## Later Ideas

### Shell Screen Capture

Why: live MC and GUI routing can be proven through shell geometry/state logs,
but `eos-proof mc-preview --visual` cannot capture a real frame because the
compositor does not expose the protocol required by `grim`.

Likely phase: current MVP hardening after the boot/recovery gate; add a
security-reviewed capture protocol and prove that metadata-only output remains
insufficient.

### Falkon Pane Stress Proof

Why: token binding and pane geometry are covered by tests, but the live
terminal-to-Falkon focus path still needs a repeated switch test with a real
mapped Qt surface and captured evidence.

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
