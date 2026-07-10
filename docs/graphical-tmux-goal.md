# Goal: Complete EngineOS Native Graphical Tmux

## Objective

Transform the tmux 3.6b-based `engine-mux` fork and `engineos-shell` into one
native graphical multiplexer stack.

Tmux remains authoritative for sessions, windows, panes, PTYs, terminal grids,
scrollback, commands, and layout. `engineos-shell` remains authoritative for
Wayland, DRM/KMS, GPU rendering, outputs, clipping, focus, input, and graphical
surfaces.

Every pane permanently retains a working console and may additionally own a
Wayland, game, or stream presentation. `prefix + v` toggles between that
presentation and its live backing console.

The initial baseline was commit `57dfba0`: an isolated tmux 3.6b fork,
standalone frontend prototype, revisioned layout snapshots, native shell
handshake, packaging, and contract tests.

## Progress Snapshot

As of 2026-07-10, the in-server frontend, authoritative layout snapshots,
binary grids, sparse damage, scrollback/copy-mode metadata, headless native
terminal scene, event-driven refresh, and native keyboard control are
implemented side by side. Every shell output now registers as a real tmux
client with output geometry and canonical rows/columns. Discrete key frames use
tmux's normal client key path, including configured prefixes and key tables,
and graphical-client teardown is proven. Pointer focus now transfers the sole
graphical canonical-size owner, output loss promotes a survivor, and temporary
frontend clients restore prior ownership on disconnect. The server now exports
styled status rows, messages, command prompts with both input and screen cursor
positions, and already-rendered menu rows plus item/key/command metadata.
The shell retains and composites those rows over the pane grid and consumes
event-driven UI invalidations; headless contracts exercise live status, menu,
and command-prompt transitions. Native mouse frames now enter tmux's normal
SGR classifier with focused-view cell coordinates; the contract proves pane
hit-testing, wheel-triggered copy mode, drag selection, authoritative border
resize, ranged status selection, menu opening, and menu-command activation.
The shell routes motion, buttons, modifiers, and vertical scroll through that
boundary. Incremental GPU glyph-atlas updates, compound presentations, process
scopes, leases, games/images, hardware acceptance, and legacy cutover remain
open.

## Workstream 1: Integrate The Protocol Into Engine Mux

- Move the frontend `SOCK_SEQPACKET` listener into the `engine-mux` server
  event loop.
- Preserve the versioned frame header, bounded payloads, request IDs, and
  revisions.
- Enforce same-user peer credentials and private socket permissions.
- Generate snapshots directly from tmux session, window, and pane structures.
- Advance revisions from real tmux lifecycle and layout events.
- Support complete resynchronization after stale revisions.
- Support multiple concurrent graphical and text clients.
- Remove `engine-muxd` after in-server protocol parity.
- Record the upstream 3.6b baseline and rebase procedure.
- Run the upstream tmux test suite unchanged.

Exit criteria:

- `engine-muxctl snapshot` works without `engine-muxd`.
- No subprocess or `list-panes` query constructs authoritative state.
- Upstream tmux behavior remains intact.

## Workstream 2: Export Terminal State

- Export full terminal-grid snapshots as compact binary frames.
- Export damaged cells without retransmitting unchanged grids.
- Preserve Unicode, wide and combining characters, attributes, colors, cursor
  state, alternate screen, and hyperlinks.
- Export scrollback and copy-mode state.
- Export pane titles, borders, status lines, menus, prompts, and command
  metadata.
- Add payload limits, flow control, and explicit malformed-frame errors.
- Key pane state by stable pane ID and generation.
- Trigger full snapshots after generation or revision mismatches.
- Do not send raw PTY output to the compositor.

Exit criteria:

- A frontend can reconstruct an exact pane grid without parsing terminal escape
  sequences.
- Grid damage and complete resynchronization pass contract tests.

## Workstream 3: Build The Native Shell Terminal Renderer

- Separate compositor core, mux client, pane scene, terminal renderer, XDG
  binding, input routing, and observability where implementation requires it.
- Create one clipped wlroots scene subtree per mux pane.
- Implement GPU glyph-atlas rendering.
- Allow CPU glyph rasterization, but require GPU composition.
- Render cells, cursor, borders, status, prompts, menus, and copy mode.
- Apply only damaged-cell updates.
- Handle output scale and transforms.
- Reject pixman, llvmpipe, softpipe, or silent software fallback for hardware
  acceptance.
- Record mux revision, pane scenes, renderer, focus, and mapped surfaces in
  `shell-state.json`.

Exit criteria:

- A nonblank terminal frame renders in headless tests.
- Bare-metal rendering uses AMD/radeonsi hardware GL.
- Text remains correctly clipped during splits, resize, and zoom.

## Workstream 4: Complete Terminal Interaction

- Register one graphical mux client view per EngineOS output.
- Send canonical rows and columns to tmux.
- Let the focused graphical view determine canonical PTY size.
- Preserve normal padding behavior for ordinary text clients.
- Route prefix commands to `engine-mux`.
- Route normal console-mode keys to the pane PTY.
- Implement mouse selection, pane focus, resizing, status interaction, menus,
  prompts, and copy mode.
- Support split, resize, zoom, join, break, swap, move-window, session moves,
  detach, and reattach.
- Preserve standard tmux commands, formats, configuration, plugins, and SSH
  attachment.
- Bind `prefix + v` through a native mux command.

Exit criteria:

- Terminal-only native mode is fully usable without foot or bridge geometry
  hooks.
- An ordinary tmux client can operate the same panes simultaneously.
- One hundred focus transitions complete without relayout churn or stale
  geometry.

## Workstream 5: Add Compound Pane Presentations

Implement these authoritative pane objects:

- `PaneConsole`: PTY, foreground process group, grid, cursor, images, and
  scrollback.
- `PanePresentation`: `terminal`, `wayland`, `game`, or `stream`.
- `PaneSurfaceSet`: primary surface, transients, popups, and additional
  toplevel tabs.
- `PaneViewMode`: `presentation` or `console`.

Add native commands:

- `launch-pane-app [-t pane] -- COMMAND`
- `split-pane-app [-h|-v] -- COMMAND`
- `pane-presentation [-t pane] app|console|toggle|close`
- `signal-pane-app [-t pane] INT|TERM|KILL`
- `respawn-pane-app [-t pane]`

Exit criteria:

- Presentation state survives pane moves and layout changes.
- Every graphical pane always retains an operable backing console.
- Text clients display the backing console and presentation metadata.

## Workstream 6: Implement Graphical Process Ownership

- Launch graphical commands as foreground pane jobs with stdin, stdout, and
  stderr attached to the pane PTY.
- Use dedicated transient user scopes as the authoritative app-to-pane
  identity.
- Add `engine-pane-host` for newly created graphical panes.
- Start a login shell after the hosted application exits.
- Resolve mapped Wayland client PIDs to registered process scopes.
- Reject surfaces outside the registered scope.
- Remove environment scraping and next-mapped-window matching.
- Terminate launches that map no surface within 15 seconds.
- Report launch failures in the pane console.
- Default manifests to dedicated application instances.
- Add a Falkon adapter using `--no-remote`.
- Keep popups and dialogs attached to their parents.
- Turn extra independent toplevels from the same scope into pane-local tabs.
- Restore the console presentation automatically when the application exits.
- Preserve the console after shell restart and expose explicit respawn.

Exit criteria:

- Falkon is the pane foreground process.
- Its output remains visible through the backing console.
- `prefix + v` toggles between Falkon and the live console.
- Closing Falkon restores the prompt.
- Unrelated Wayland clients cannot steal the pane.

## Workstream 7: Complete Commands And UI Metadata

Provide these wrappers:

- `eos-app pane launch -- COMMAND`
- `eos-app pane split [-h|-v] -- COMMAND`
- `eos-app pane view app|console|toggle`
- `eos-app pane signal SIGNAL`
- `eos-app pane list --json`

Also:

- Show `T` for terminal, `G` for Wayland, `Q` for game, and `S` for stream.
- Display pane-local surface tab counts.
- Expose presentation, view mode, process scope, and lease state in formats.
- Keep failures explicit; wrappers must not silently invoke the legacy bridge.

## Workstream 8: Add Multiple Outputs And Leases

- Register session attachment, scale, pixel bounds, and canonical grid size for
  every graphical output view.
- Give each graphical presentation one live output lease.
- Transfer leases transactionally during session or window moves.
- Show backing consoles and presentation metadata on non-owning views.
- Prevent applications and images from rendering on the wrong output.
- Key images by pane ID, generation, and client-view lease.
- Never route images using only the currently focused pane.

Exit criteria:

- Moving a graphical window across sessions and outputs moves its lease
  atomically.
- The presentation and its images render only on the owning output.
- Linked sessions and secondary clients remain usable.

## Workstream 9: Add Games And Pane-Local Images

- Add native game presentations.
- Preserve direct Wayland game input where possible.
- Keep gamescope optional for virtual displays, frame limiting, or isolated
  Xwayland.
- Preserve pointer capture, relative motion, constraints, and emergency
  release.
- Route Quake through the native pane model.
- Move previews and terminal images to pane ID, generation, and lease
  ownership.
- Preserve console access while a game is running.

Exit criteria:

- Quake launches through a pane and retains its PTY console.
- Capture and emergency release work on bare metal.
- Images never leak to another pane or output.

## Workstream 10: Cut Over And Remove The Legacy Path

- Keep one explicit native-mode runtime setting during acceptance.
- Make native mode the EngineDev default after acceptance.
- Keep rollback only until live proof passes.
- Make the fork provide `/usr/bin/tmux` after compatibility acceptance.
- Remove shell-owned foot bootstrap.
- Remove tmux hook subprocesses and proxy-window helpers.
- Remove `terminal-register` and pane geometry IPC.
- Remove launch tokens and `launch-bounds/*.env`.
- Remove environment scraping and persisted pixel geometry.
- Remove the standalone protocol daemon.
- Remove rollback code after the agreed acceptance window.
- Update architecture, shell, deployment, recovery, operator, and rebase
  documentation.

Exit criteria:

- Native startup contains zero legacy hook subprocesses.
- No removed helper or protocol remains referenced by packages, tests,
  configuration, or documentation.
- One authoritative mux layout model remains.

## Required Validation

- Run the upstream tmux suite unchanged.
- Add deterministic PTY and Wayland integration clients.
- Verify stdout, stderr, ANSI behavior, scrollback, signals, foreground process
  groups, exit status, and prompt restoration.
- Test full snapshots, damage frames, stale revisions, malformed frames,
  reconnects, and server restart.
- Test extra toplevel tabs, popups, clipping, and dialogs.
- Exercise split, resize, zoom, join, break, swap, session moves, detach, and
  reattach.
- Attach ordinary local and SSH tmux clients.
- Run headless compositor, shell-action, input, package, and source tests.
- Run real package build, install, restart, and live-state validation.
- Run bare-metal AMD renderer proof.
- Verify tty1 startup, recovery VT, emergency release, logs, and
  `shell-state.json`.
- Verify Quake capture and pane-console recovery.
- Never count dry runs, metadata-only captures, mocks, or silent fallback as
  acceptance.

## Final Completion Criteria

This goal is complete only when:

- Tmux is the sole authority for panes, PTYs, grids, commands, and layout.
- `engineos-shell` renders and controls those panes natively.
- Every graphical pane retains a live console.
- Falkon and Quake satisfy the graphical-presentation contract.
- `prefix + v` reliably toggles presentation and console.
- Ordinary tmux and SSH clients remain compatible.
- Multiple outputs obey presentation leases.
- Hardware GL, clipping, input recovery, and observability pass on bare metal.
- The upstream tmux suite passes.
- EngineOS package and runtime proofs pass.
- There are zero bridge hooks, proxy windows, environment matches, launch
  tokens, geometry files, or duplicate authoritative models.

## Non-Goals

- Steam or Proton integration.
- NVIDIA support.
- HDR or VRR.
- Rich cockpit UI.
- General compositor redesign unrelated to mux panes.
- ISO, VM, QEMU, Hyper-V, or generated-image work.
- Replacing tmux semantics with a new session manager.

## Work Rule

Advance one exit criterion at a time. Each change must leave a real proof,
update `CURRENT_STATUS.md` when acceptance changes, and keep incomplete work
visible. Do not preserve the legacy bridge after native acceptance merely for
unspecified compatibility.
