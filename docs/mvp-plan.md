# MVP Plan

This plan orders current work around live bare-metal proofs. Historical ISO and
VM milestones are archived context, not active acceptance gates.

## Product Shape

EngineDev is the current development system: a package-managed Arch install
running the EngineOS wlroots shell, persistent tmux sessions, shell-owned apps,
and the Quake development workflow. The later appliance remains a smaller
EngineRuntime system, but image generation resumes only when the live stack is
ready to package.

## Proven Foundation

The following foundations are already available:

- local EngineOS package builds and deterministic committed-range deployment
- live AMD/radeonsi shell startup and shell-owned Wayland clients
- terminal, secondary terminal, cube, and Quake app-manifest slots
- one tmux server with restart-safe primary/secondary session attachment
- event-driven pane focus/geometry and exact launch-token GUI binding
- exact MC image-preview routing by pane and terminal client tty
- QuakeSpasm, dgen, level-agent, and TrenchBroom package integration
- `eos-game quake` workflow with per-user Quake and level-agent services
- lean role/skill agent harness and fail-closed Luna session extraction

## Current Proof Ladder

### 1. Package And Harness Integrity

Goal: every change can be selected, built, installed, and published without
dirty-tree guessing or hidden fallback success.

Acceptance:

- `eos dev plan` maps committed files to the right packages and dependencies
- `eos-ci local` runs real preflight/tests/build/install/cleanup
- retired packages are absent from the live install and repository database
- agent hygiene, source tests, and package lint pass

Commands:

```bash
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-source-test agent
./tools/engineos/eos-preflight all
./tools/engineos/eos-lint packages
```

### 2. Shell And Pane Workflow

Goal: developers can keep terminal context while launching GUI tools into the
correct pane and output.

Acceptance:

- shell restart preserves existing tmux sessions and clients
- `eos-app pane launch -- COMMAND` binds only the exact launched client
- native `eos-app pane launch --game -- COMMAND` retains the pane console and
  releases capture when the console is shown
- pane focus and geometry are event-driven with no proxy windows or polling
- MC Quick View renders on the invoking terminal output and pane rectangle
- stale tokens, panes, and ambiguous output ownership fail explicitly

Commands:

```bash
eos-app manifest validate
eos-app pane list --json
eos-proof mc-preview
eos-app pane launch -- falkon
eos-app launch quake
```

Remaining evidence: a live Falkon focus-switch stress pass and the MC Quick
View screenshot acceptance run. The compositor now exposes screencopy and
xdg-output; real `grim` captures pass on headless pixman, headless radeonsi
GLES2, the live two-output layout, and a named physical output.

The replacement path is staged in parallel: the tmux 3.6b fork now owns the
versioned frontend, terminal grids, graphical clients, compound presentations,
leases, game panes, and independent lease-keyed pane previews. The exact
installed mux and shell packages are exercised by `eos-test mux`; independent
per-output sessions, terminal-image transport, real Falkon/Quake hardware
acceptance, and final bridge removal remain. See
[graphical-tmux.md](graphical-tmux.md).

### 3. Quake Development Loop

Goal: a developer can generate, edit, build, reload, and play a level without
managing service internals or stale runner processes.

Acceptance:

- dgen is built from the exact pinned `quake-generator` release
- the level agent fails closed on extractor/generator errors
- Quake runs through `engineos-quake.service`
- edit/build/play/reload operations share one user-facing command surface
- user assets remain outside the repository

Commands:

```bash
eos-game quake setup
eos-game quake create "a compact industrial arena" --wait
eos-game quake status
eos-game quake edit <job-id>
eos-game quake build "a compact industrial arena" --wait
eos-game quake play
eos-game quake proof
```

### 4. Bare-Metal Runtime Gate

Goal: close the remaining boot, recovery, input, audio, and renderer gaps on the
installed AMD system before producing a new appliance image.

Acceptance:

- boot validation observes the real startup decision and recovery path
- the active shell renderer is hardware GL, never pixman/llvmpipe/softpipe
- keyboard, pointer capture/release, and Quake focus work interactively
- user-provided Quake assets launch a mapped game surface
- audible PipeWire/Pulse output is proven on hardware
- crash bundles contain actionable shell, service, asset, and renderer evidence

Commands:

```bash
eos-validate boot --bare-metal
eos-proof shell-launch --bare-metal
eos-assets check quake
eos-game quake proof
eos-crash-bundle --runtime
```

## MVP Exit

The MVP exits when the installed AMD system reliably starts the accelerated
shell, preserves developer sessions, launches terminal and Quake through the
shell-owned app stack, recovers input, handles user assets, produces audible
audio, and leaves useful failure evidence.

Only then should EngineRuntime image work resume to package the already-proven
live behavior.

## Deferred Until After MVP

- Steam/Proton
- NVIDIA
- HDR and VRR
- dynamic multi-monitor layout
- rich 3D cockpit
- package signing
- read-only runtime MCP beyond the current direct CLI/state interfaces
