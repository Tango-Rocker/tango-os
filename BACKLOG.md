# Backlog

This is the place for useful tangents. Add ideas here instead of expanding the current task.

## Rules

- Keep entries short.
- Include why the idea matters.
- Include the likely phase.
- Do not treat this as a promise to build everything.

## Later Ideas

### Session Mining Action Queue

Why: the 2026-07-08 full Codex session review found recurring proof,
environment, and ergonomics issues across 46 local sessions. Highest-value
EngineOS candidates are fail-closed proof gates, a source-tree validation
wrapper, multi-package `eos-*` handling, live visual proof helpers, MC preview
proof, pane/window management proofs, and cleaner git/package disposition.

Likely phase: current PoC/MVP hardening; use the generated local evidence under
`.agent-insights/out/full-20260708/` while it remains available on this machine.

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
