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

As of 2026-07-11, the in-server frontend, authoritative layout snapshots,
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
boundary. The native terminal renderer now uses a colour-keyed GPU glyph atlas,
double-buffered pane targets, clipped sparse-cell draws, wlroots scene damage,
and a nonblank GPU readback. Its installed contract uses the local AMD render
node through GLES2/radeonsi and distinguishes the explicit pixman smoke path
from hardware rendering. Compound presentation commands, process scopes,
authoritative PID-to-pane resolution, compositor XDG map/unmap binding,
clipped presentation scenes, state-driven console/application visibility, and
configured-prefix routing in graphical mode are now implemented. A
deterministic XDG client proves that an unscoped surface is rejected, a scoped
surface maps only to its pane, presentation/console toggles reach the
compositor, and process exit restores the terminal. XDG popups and transient
toplevels now inherit the owning pane and registered scope, remain clipped to
that pane, and do not inflate its tab count. Extra independent toplevels become
pane-local tab groups; the shell exposes their roles and visibility, keeps one
group active, and promotes the primary plus its transient when the active tab
closes. Tmux now stores the active surface ID and owns
`select-pane-surface next|previous|ID`; snapshot invalidations drive the shell
to activate only that toplevel and its transient group. The installed
deterministic contract proves selection, invalid-role rejection, the full
surface-set lifecycle, and pending launch scopes across the systemd-run PTY
handoff. The server now retains simultaneous grid subscriptions for every
active pane, while the shell owns one clipped renderer and scene subtree per
pane plus a separate mux UI overlay. Grid resynchronization follows canonical
resize, and nonselected pane damage advances that pane's retained grid and
render frame. `shell-state.json` reports every pane's grid subscription,
revision, scene bounds, renderer, and frame. Both pixman smoke and AMD/radeonsi
GLES2 contracts prove two nonoverlapping panes and independent nonselected
damage. The shell now follows tmux's active pane dynamically, resynchronizes
canonical grid changes, and uses authoritative pane visibility to retain but
hide nonactive zoom scenes. The contract exercises resize, zoom/unzoom, and
one hundred focus transitions under both renderers. Synthetic graphical tmux
clients satisfy upstream tty ownership invariants, so ordinary `select-pane`
redraw logic remains safe while physical tty output stays disabled.
Authoritative presentation lease identity and focus/disconnect transfer are
now implemented: tmux stores one frontend-client/output-view owner for each
mapped presentation, exports it through snapshots and formats, rejects a
second live owner, clears invalid owners, and restores the preceding graphical
view when a temporary client disconnects. The shell exposes each registered
output view and lease in `shell-state.json`, gates graphical presentation
visibility on ownership, and retries snapshots when an intervening state
invalidation would otherwise leave stale focus or lease state. Pixman and the
exact installed AMD/radeonsi GLES2 packages pass the two-output transfer
contract. The compositor now creates one layout-positioned mux scene root per
output and one console node per pane under every root. It reparents the live
XDG toplevel/transient set only beneath the owning lease's clipped pane tree;
nonowners retain console copies, and external lease ownership detaches and
hides the local presentation. Observability and the installed contract prove
distinct output roots, complete pane-copy counts, one owning presentation
subtree, and zero presentation surfaces on the nonowner. Native pane previews
are now keyed by pane ID, generation, frontend client, and output-view lease;
their scene buffers live under the leased pane subtree, fail closed for an
external lease, and appear on exactly one output in the installed radeonsi
contract. The shell retains one preview per native pane rather than one global
preview, handles pane `%0` without a sentinel collision, exposes the complete
set plus per-output counts, and removes images by owner or exact pane identity.
The contract renders two pane images simultaneously and proves either can be
removed without changing its sibling. The frontend now serves view-addressed
snapshots: each response identifies the requested frontend client, output
view, and output name and contains only that synthetic tmux client's attached
session and active window. Invalid view IDs fail explicitly. The contract
registers two views on different sessions and proves both snapshots remain
independent while one view is nonfocused; shell refreshes now explicitly name
their focused output view. The shell retains a validated authoritative model
for each registered output, including session, selected pane and generation,
pane count, and revision. Its pixman source contract and exact installed
AMD/radeonsi contract move the nonfocused synthetic tmux client to another
session, observe both output models concurrently, and prove reattachment
updates only that output model. Every output model resolves retained,
subscribed grids for all of its panes; the contract proves damage in a
nonfocused session advances only that output model while the focused session
remains intact. State invalidations stay pending when encountered during grid
or JSON request servicing until all output snapshots settle. Independent
terminal renderers now live in each output-pane scene with their own render
targets, buffers, damage, and statistics. Canonical grid ownership survives
session focus changes, and nonfocused damage advances only the corresponding
output renderer. Each output now also owns a validated view-addressed UI model
and renderer for status rows, menus, messages, and prompts. UI invalidations
are retained per view, revision races settle before state publication, and a
nonfocused session-specific status update advances only its output renderer.
The frontend retains UI subscriptions for every registered output instead of
replacing the previous subscriber. Keyboard frames carry the focused output
model's pane ID and generation; pointer hit testing uses that output's UI
geometry, and a drag remains bound to its originating view. Focus changes
settle every affected output model before input resumes. Presentations,
transients, and explicit pane previews resolve the pane's owning output even
when it is not focused. The deterministic two-session contract maps a Wayland
client and an image only on the nonfocused output while proving focused input
identity is unchanged. Terminal image transport is now mux-owned rather than
shell-local: `pane-image` retains bounded PNG/JPEG bytes, owner, revision, pane
generation, and one graphical output lease in tmux. The frontend advertises
`pane-image-v1` and returns versioned 64 KiB binary chunks; the shell validates
the complete identity and byte count before decoding into the leased pane
scene. Native `engine-image-preview` uses this command, while direct native
pane-image mutation through `preview.sock` is rejected. The deterministic
contract transports a multi-chunk image, retains two pane images, proves
nonfocused output isolation, and proves an image appears with its console but
never above its graphical presentation. Exact installed AMD/radeonsi packages
pass the same contract. Ordinary local and SSH `xterm-256color` tmux clients
now attach to the same live window through real 50x20 PTYs while two graphical
output clients remain present. Both render backing-console output and
presentation metadata, execute a tmux command prompt, drive `prefix+v`, and do
not resize the graphical canonical window. The SSH proof uses a private
loopback OpenSSH server, generated keys, verified public-key authentication,
a forced remote PTY, and a remote `engine-mux attach-session` command. Engine
mux excludes ordinary clients from size calculation only when a registered
graphical view owns that window, preserving normal upstream sizing everywhere
else. The proof driver is installed by `engineos-tools 0.1.0-51`; its pixman
source contract and AMD/radeonsi shell contract pass. The current live package
set is `engineos-mux 3.6b-38`, `engineos-shell 0.1.0-56`,
`engineos-tools 0.1.0-51`, and `engineos-config 0.1.0-6`. Direct-KMS
clipping now passes through installed
`eos-proof native-kms` and `engineos-shell 0.1.0-56`. Graphical view
registration derives canonical rows and columns from each output's effective
pixel size and the renderer's font metrics. On both live 1920x1080 outputs the
view is 192x51 and its single pane target is 1920x1050; renderer frames and DRM
commits advance without pointer input. The workflow temporarily
attaches tty1 to an isolated two-pane native mux and requires the DRM/libinput
backend, a DRM GBM allocator, AMD/radeonsi GLES2, real connector modesets,
positive scene-output commits, and zero commit failures. Every pane buffer
remains nonoverlapping and inside each of two physical 1920x1080 outputs
through split, resize, zoom, and unzoom; zoom disables the hidden terminal
subtree on both outputs. The clean post-fix proof is retained in
`/var/log/engineos/proof-native-kms-20260711T141226Z/`; it restores the native
default desktop and removes its isolated mux server.
Real Falkon acceptance now passes through `eos-proof native-falkon` on tty1.
The proof launches through `eos-app`, verifies the dedicated `--no-remote`
adapter, authoritative transient scope and mapped client PID, PTY foreground
process group, live backing console, console/application toggles, process exit,
prompt restoration, and restoration of the prior shell mode. Evidence is
retained in `/var/log/engineos/proof-native-falkon-20260711T130532Z/`. The
transport now sizes both ends of the seqpacket connection for the protocol's
valid maximum, with a 240x67 regression proving large grid snapshots.
Split-pane hosts retire their empty application scope before entering the
replacement login shell. Real Quake now passes through `eos-proof native-quake`
with user-provided registered assets. The live proof verifies the pane PTY and
scope, the mapped `quakespasm` game presentation, RX 5600 XT/radeonsi GL,
an uncorked PipeWire/Pulse stream on the ALSA hardware sink, capture and cursor
lock, both directions of the native prefix binding, a real Ctrl+Alt+Backspace
event injected through uinput, capture release and recovery, process exit, and
prompt restoration. The emergency-release latch remains active across grid
damage until an explicit console/application transition. Evidence is retained
in `/var/log/engineos/proof-native-quake-20260711T131417Z/`. Bare-metal startup
and recovery acceptance now passes through the installed
`eos-proof shell-launch --bare-metal`. `engineos-config 0.1.0-6` makes tty2 a
vendor-enabled recovery getty, `engineos-tools 0.1.0-51` provides the recovery
operator command, and the proof requires the live EngineDev startup decision,
active tty1 shell, active tty2 getty, DRM/libinput backend, and RX 5600
XT/radeonsi renderer. Renderer acceptance is tied to the active compositor,
so an unrelated llvmpipe device exposed by generic EGL enumeration cannot
produce a false failure or a false success. Evidence is retained in
`/var/log/engineos/proof-shell-launch-bare-metal-20260711T131443Z.log`. Full
upstream-suite closure and native-default cutover now pass. Native
`game` is now an
authoritative launch/split presentation that survives respawn.
`eos-app pane launch|split|view|signal|respawn|list` routes directly to
`engine-mux` in native mode without launch-token or bridge fallback, and
`eos-app launch quake` selects a game pane when invoked from a native mux pane.
The shell gives mapped game presentations direct Wayland input, capture,
cursor confinement, constraints, emergency-release compatibility, and
capture-free console toggling. The deterministic installed contract proves
game launch from the pane foreground job, map, lease isolation, console/app
toggle, exit, respawn type preservation, and terminal restoration; the real
bare-metal proof above covers the corresponding engine and hardware path. The
server now
exports every
pane's authoritative cell origin and size,
and the shell validates and retains the complete pane set instead of discarding
every pane except the selected one. `shell-state.json` exposes those stable
pane identities, generations, layouts, and presentation states. The installed
split contract compares protocol geometry directly with tmux's pane formats
and proves shell observability retains both nonoverlapping panes. It now also
exercises inactive-window isolation, join, break, swap, cross-session
window moves, session switches, linked windows, and compositor detach/reattach.
Graphical snapshots contain only the focused client's attached active window;
unscoped diagnostic snapshots deduplicate linked canonical windows. Pane IDs
and generations remain stable through the entire lifecycle under pixman and
AMD/radeonsi GLES2. Application
signals, close, and launch timeout now target the registered transient systemd
scope through the user manager rather than trusting a sampled process group.

## Remaining Path To Completion

The protocol, native terminal renderer, interaction model, multi-output leases,
compound Wayland presentations, local/SSH text clients, real KMS clipping,
Falkon, and real Quake lifecycle are proven. The ordered completion gates are:

1. **Complete:** run a real Quake pane on bare metal with user assets and prove
   its foreground PTY, mapped game presentation, audio, pointer capture,
   `prefix + v`, emergency release, process exit, and console recovery.
2. **Complete:** close the bare-metal recovery gate. The recovery VT and helper
   are installed and active, the EngineDev startup decision is recorded, and
   `eos-proof shell-launch --bare-metal` distinguishes the active radeonsi
   shell from unrelated llvmpipe devices.
3. **Complete:** close the upstream tmux suite. The fail-closed harness builds
   the pinned pristine 3.6b comparator and EngineOS fork from the same verified
   archive and flags, applies named official upstream fixture-maintenance
   commits, and runs the 32 scripts unchanged in a clean environment. The fork
   passes 32/32; four failures remain only in the pristine comparator and prove
   the corresponding fork fixes. Evidence is retained in
   `/var/log/engineos/tmux-upstream-pass-20260711T123826Z/`.
4. **Complete:** enable native mux as the EngineDev default and run acceptance
   across restart, detach/reattach, local and SSH clients, two outputs,
   session/window moves, previews, Falkon, Quake, and recovery. Clean live
   evidence is retained in the KMS, Falkon, Quake, and shell-launch artifacts
   listed above. The managed tmux hooks are already absent.
5. **Next:** remove the remaining rollback architecture: bridge and
   proxy/window helpers,
   terminal registration, launch tokens, geometry IPC/files, shell-owned foot
   bootstrap, environment matching, and every package/config/test/doc
   reference to them.
6. Make the fork provide `/usr/bin/tmux`, document the pinned upstream baseline
   and rebase procedure, rerun package/source/hardware proofs, and publish the
   final scoped changes with one authoritative mux model remaining.

No gate is complete from a dry run, mock, metadata-only capture, hidden
fallback, or an environmental failure recorded as success.

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
- Keep tmux's exported grid, cursor, scrollback, and terminal state
  authoritative. Do not embed a second terminal client or create another PTY
  merely to reuse its renderer.
- Put font discovery, fallback, shaping, rasterization, glyph caching, and GPU
  target updates behind an explicit renderer boundary so a proven glyph
  provider can replace the current implementation without changing mux state.
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
- Normalize libinput events once, resolve each event to a typed terminal,
  Wayland-surface, game, or shell target, then dispatch through that target's
  protocol boundary instead of interleaving those policies in cursor callbacks.
- Track keyboard focus, pointer focus, and pointer grabs independently. Bind
  each pressed pointer button to its original target until release, including
  popups, subsurfaces, and presentation-mode transitions.
- Close graphical panes by requesting XDG toplevel close first, waiting for
  actual unmap or process exit, then escalating to scope TERM after a bounded
  timeout; reserve KILL for an explicit command. Do not clear authoritative
  presentation state before lifecycle evidence arrives.
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

- `launch-pane-app [-g] [-t pane] -- COMMAND`
- `split-pane-app [-g] [-h|-v] -- COMMAND`
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
- `eos-app pane launch --game -- COMMAND`
- `eos-app pane split [-h|-v] -- COMMAND`
- `eos-app pane view app|console|toggle`
- `eos-app pane signal SIGNAL`
- `eos-app pane list --json`

The native `select-pane-surface [-t pane] next|previous|ID` command selects an
authoritative pane-local toplevel tab and is available to graphical and text
clients.

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
