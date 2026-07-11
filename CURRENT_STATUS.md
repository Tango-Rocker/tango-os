# Current Status

Current focus: continue Tango-OS/Engine-OS as a bare-metal/source-checkout
system, with package rebuild/reinstall loops and live shell/app proofs.

Current deployment context: this session is the bare-metal EngineDev
installation. ISO, VM, QEMU, Hyper-V builder, and generated image paths are
decoupled from active work. Do not route routine build, proof, deploy, or
publish tasks through them unless the user explicitly re-enables the legacy
image lab.

Historical proof notes that no longer need to stay in the active status file
are archived in
[docs/session-archive/2026-07-04-engineos-proof-history/README.md](docs/session-archive/2026-07-04-engineos-proof-history/README.md).

## Legacy Image Artifacts

These are historical proof artifacts only; they are not the active work path:

- Arch builder VM: `dev@172.23.74.185`
- Builder repo path: `/srv/engineos`
- Builder local package repo: `/srv/engineos/repo/x86_64`
- EngineDev ISO: `out/EngineDevOS-2026.06.16-x86_64.iso`
- EngineRuntime ISO: `out/EngineRuntimeOS-2026.06.15-x86_64.iso`
- EngineRuntime checksum: `e4547a916d59765e962e7b0766ba3f18175f5cfd46e020df504451c8a2d7add2`

## Working Now

- `eos-*` is the active command surface for builds, proofs, packages, app
  launch, logs, assets, agent operations, observability, and runtime checks.
  `/usr/bin/engineos` is only a legacy discovery shim.
- The old image lab proved package repo, EngineDev image boot, EngineRuntime
  autostart, recovery logs, launchpad mapping, missing-Quake-asset handling,
  shell-state JSON, and emulated audio plumbing. That evidence is archived and
  no longer drives active work.
- Bare-metal EngineDev has the current shell/app stack deployed without an ISO
  rebuild, including pane-bounds app launch, game cursor capture, MC image
  preview, Quick View preview integration, the Falkon startup crash fix, and
  Wayland drag-and-drop support for Qt/editor clients. The live shell package
  now uses the event-driven tmux pane bridge described below.
- Bare-metal EngineDev has a systemd-boot fallback entry,
  `enginedev-restore-engineos-20260704.conf`, pointing at copied
  `/boot/vmlinuz-linux-restore-engineos-20260704` and
  `/boot/initramfs-linux-restore-engineos-20260704.img`. The normal default
  remains `enginedev.conf`.
- EngineDev-only Quake work now has one user-facing workflow:
  `eos-game quake setup|create|build|edit|play|reload|status|proof|stop`.
  The tracked `engineos-quake.service` and `engineos-level-agent.service`
  user units replace the retired `engineos-engine-runner` package and service.
  The live install has `engineos-dgen 0.1.0-1`,
  `engineos-level-agent 0.1.0-9`, and `engineos-quakespasm 0.97.0-2`;
  `engineos-engine-runner` is absent. Dgen is built from the exact local
  `quake-generator` commit, and package builds fail when that source or commit
  is unavailable instead of silently substituting another generator.
- Agent-pack hygiene currently passes with a smaller role/skill router and no
  dispatch queue or profile indirection. Session extraction is provided by
  the `codex-extractor` checkout and its `codex-insights 0.2.0` command, using
  Luna on medium reasoning. The autonomy harness pins that exact extractor
  contract and fails closed. Codex is updated
  to the verified current release, `codex-cli 0.144.1`; npm updates are handled
  by the managed root-owned install path.
- Bare-metal EngineDev has the v1 tmux pane bridge deployed through the local
  package reinstall/restart loop. `eos-app pane launch -- COMMAND` registers a
  tmux pane launch token with `engineos-shell`, shell state owns
  `pane_bindings`, generic GUI clients are laid out as `tmux-pane-gui`, and
  `engineos-tmux-pane-bridge` reports focus and geometry from tmux hooks
  without proxy tabs or a polling daemon. Cube/engine pane launches still use
  the existing `launch-bounds/*.env` path. The 2026-07-09/10 deploy refreshed
  `engineos-shell 0.1.0-17`, `engineos-tools 0.1.0-36`, and
  `engineos-config 0.1.0-3`; force-installed the managed tmux config and
  `/usr/local/bin/engineos-tmux-pane-bridge`; and left
  `/run/user/1000/engineos/shell-state.json` JSON-readable with
  `pane_bindings`. The same deploy added `engineos-tmux-attach-primary` for
  shell-owned terminal startup, so restarts attach the existing primary tmux
  session before creating the fallback `engineos` session. Repeated shell
  restarts preserved one tmux server and its two attached clients: primary
  `/dev/pts/0` remains on session `2`, and secondary `/dev/pts/1` remains on
  `engineos-side`; no detached `engineos` session or proxy windows were
  created. `eos-app manifest validate` passes after restart. This bridge is now
  rollback-only: the live native Falkon pane contract passes through the
  isolated native-mux proof described below. The managed right-click status-window
  menu now includes `Move to Session...`; with one destination it moves the
  clicked stable window ID immediately, avoiding tmux's unreliable nested
  mouse menus, and resynchronizes pane geometry. The managed session-name menu
  also replaces tmux's client-terminating bare `new-session` action with
  detached creation followed by an explicit switch of the invoking client.
  The EngineOS command-surface hardening is deployed through
  `engineos-tools 0.1.0-41`: `eos-source-test` clears installed-session
  contamination, `eos-proof` fails closed on required evidence, repeatable
  package selection is normalized through `eos-ci local`, and
  `eos-runtime shell restart-live` only reports success when a new
  `engineos-shell` PID is verified.
- MC Quick View now routes through an exact tmux client identity instead of a
  stale terminal-role environment variable. The live `eos-proof mc-preview`
  run from pane `%3` passed its installed image contract, IPC ping, and real
  show/hide path. Shell evidence maps `%3` through `/dev/pts/0` to the primary
  `terminal` slot and renders inside `x=960 y=180 size=960x720` with
  `bounds=960x1080`; the former incorrect secondary placement was at `x=3000`.
  Pane `%6` independently resolves through `/dev/pts/1` to
  `terminal-secondary`. The proof log is
  `/var/log/engineos/proof-mc-preview-20260710T002615Z.log`.
- Native graphical mux migration is installed side by side as
  `engineos-mux 3.6b-36` with the decoder/renderer/control boundary in
  `engineos-shell 0.1.0-53`, but native mode is not yet the live desktop
  default.
  The package builds the pinned
  official tmux 3.6b baseline as `engine-mux` with an isolated namespace. The
  fork server now owns the same-user `SOCK_SEQPACKET` frontend and constructs
  revisioned snapshots directly from tmux's session, window, and pane trees;
  the standalone `engine-muxd` and its `list-panes` subprocess path are removed.
  Its v1 handshake and atomic layout snapshots are exercised against real split
  panes and focus changes. The unchanged upstream regression scripts match an
  identically configured pristine build at 23 pass and 9 host failures on the
  current run; `copy-mode-test-vi` and `cursor-test4` remain timing-sensitive in
  repeated runs, while `new-session-environment` passes consistently. The
  retired daemon binary
  and user unit are absent from the live package. `engineos-shell
  --mux native` requires that handshake and snapshot before compositor startup,
  exposes the observed revision in `shell-state.json`, and fails instead of
  falling back when the mux service is absent. The server now exports full
  visible terminal grids as bounded binary cell frames preserving UTF-8,
  combining and wide characters, colour, attributes, hyperlinks, cursor, and
  alternate-screen metadata. Per-pane grid revisions now produce sparse cell
  damage and force complete resynchronization after stale revisions. Paged
  scrollback and copy-mode metadata are exported without exceeding bounded
  frames. Native shell startup now selects the active pane, validates and
  retains its binary grid, and reports pane/grid/nonblank evidence in
  `shell-state.json`. A per-pane wlroots scene subtree now presents a
  FreeType/fontconfig-rasterized terminal buffer and proves nonblank glyph
  pixels in the headless compositor. The server now pushes one flow-controlled
  invalidation per client; the shell consumes sparse damage through its Wayland
  event loop, advances the grid revision, and refreshes the scene without a
  polling daemon. Each native shell output now registers as a real tmux client
  with its output identity, pixel bounds, scale, and canonical rows/columns;
  secondary views do not participate in canonical size. Native terminal mode
  sends tmux key names through that client, so normal keys, configurable
  prefixes, key tables, copy-mode tables, and plugin bindings retain tmux
  semantics. The contract proves a custom `C-a` prefix binding, real
  `list-clients` registration, event-driven PTY/grid damage, and graphical
  client cleanup. Pointer clicks now transfer focused-view and canonical-size
  ownership, keyboard routing follows the promoted view, output loss promotes
  a surviving view, and a temporary graphical client restores the prior shell
  owner when it disconnects. The contract proves an 80x24 to 100x30 canonical
  resize and cross-client focus restoration. The frontend now exports a
  bounded semantic UI model for styled status rows, messages, prompts with
  input and screen cursor positions, and active menus with selection, key, and
  command metadata. Menu rows, borders, and styles are rendered by tmux before
  export, so the shell does not need a second tmux-format renderer. Its
  contract opens the normal tmux command prompt and a
  configured menu through the native key path and verifies their actual model
  contents. Per-view UI hashes now produce bounded event-driven invalidations;
  the shell retains styled rows and composites status and menus over the pane
  grid at tmux's coordinates. The headless contract targets the shell's real
  graphical client, opens a menu and then a command prompt, and requires each
  transition and its geometry to appear as rendered UI in `shell-state.json`.
  Native pointer events now carry focused client-view cell coordinates,
  buttons, wheel direction, and keyboard modifiers into tmux's normal SGR
  mouse classifier. Tmux remains responsible for pane, border, status, menu,
  and copy-mode hit-testing. The control proof keeps press, motion, and release
  frames on one registered graphical client and places an event-loop barrier
  between them. The contract now proves a real `MouseDown1Pane` binding,
  wheel-triggered copy mode, drag selection into a tmux paste buffer, border
  resizing, ranged status-window selection, status-menu opening, and menu-item
  command activation. The shell routes pointer motion, buttons, and vertical
  scroll through that same boundary. The contract passes against the exact
  `engineos-mux 3.6b-34` and `engineos-shell 0.1.0-52` package binaries. The
  native renderer now keeps FreeType-rasterized, colour-keyed glyphs in a GPU
  texture atlas and draws them into double-buffered per-pane GPU targets.
  Sparse tmux cell damage is retained through the mux client, expanded only
  for wide-glyph and cursor neighbours, applied as clipped GPU draws, and
  reported to the wlroots scene as pixel damage. Full UI transitions redraw
  atomically. `shell-state.json` records renderer mode, atlas entries, damaged
  cells, GPU-readback nonblank pixels, and frame count. The installed package
  contract passes through the local AMD render node with GLES2, `radeonsi`, a
  nonblank target readback, and a later frame touching fewer cells than the
  full grid; pixman is explicitly labeled `cpu-pixman-smoke` rather than
  silently accepted as hardware.
  One frontend connection now subscribes to every active pane grid. The shell
  retains those grids across authoritative snapshot refreshes, forces a full
  resynchronization when canonical pane dimensions change, and renders each
  pane under its own clipped wlroots scene subtree with a separate mux UI
  overlay. Per-pane state evidence includes subscription readiness, grid
  revision, pixel bounds, renderer, damage, and frame. The installed contract
  proves two nonoverlapping pane scenes and independently advances a
  nonselected pane's revision and render frame under both pixman smoke and the
  local AMD/radeonsi GLES2 renderer. A pane application PID is no longer
  exposed until systemd confirms it belongs to the registered transient scope,
  closing the split-pane signal race without falling back to process-group
  identity.
  Native focus now follows tmux's active pane rather than the pane selected at
  compositor startup. Canonical grid resizes force a complete pane-grid
  resynchronization, and tmux's authoritative pane visibility keeps zoomed-out
  scenes retained but disabled. The headless and AMD/radeonsi contracts cover
  resize, zoom/unzoom, and one hundred focus transitions without stale scene
  geometry. A core captured while introducing this proof exposed an incomplete
  synthetic tty invariant in graphical clients; initializing the tty owner
  fixes ordinary `select-pane` redraw handling without enabling tty output.
  Pane ID `%0` is accepted for graphical presentation mapping, and asynchronous
  invalidations are consumed safely while switching selected grids.
  Graphical snapshots are now scoped to the focused mux client's attached
  session and active window, while unscoped diagnostic snapshots deduplicate
  linked canonical windows. The shell follows authoritative session switches
  and refreshes its pane set after output registration. Headless pixman and
  AMD/radeonsi contracts now cover inactive-window isolation, join, break,
  swap, cross-session move-window, linked windows, session switching, and
  compositor detach/reattach while preserving pane ID and generation.
  The mux server now also owns compound pane presentation and view state,
  stable pane generations, globally unique transient user scopes, mapped
  surface roles, and pane-local toplevel counts. The installed native commands
  are `launch-pane-app`, `split-pane-app`, `pane-presentation`,
  `signal-pane-app`, and `respawn-pane-app`; `prefix+v` is a native default
  binding. Existing panes launch the graphical command as their foreground PTY
  job, while new graphical splits use `engine-pane-host` and become login-shell
  panes after the application exits. The presentation protocol resolves mapped
  client PIDs through the registered systemd scope, rejects unrelated PIDs,
  rejects stale pane generations and duplicate surface IDs, distinguishes
  toplevel tabs from transient/popup surfaces, and restores the console after
  exit. The installed mux contract proves stdout/stderr retention, foreground
  process groups, signal and respawn behavior, scope isolation, presentation
  toggling, split-host restoration, and the required 15-second unmapped-surface
  failure in the pane console. The server now resolves a Wayland client PID to
  exactly one registered pane scope without a caller-supplied pane guess and
  publishes presentation-state invalidations to graphical views. Native shell
  mode obtains the Wayland client credentials, rejects unscoped clients,
  issues authoritative map/unmap frames, reparents accepted toplevels beneath
  the clipped mux pane scene, and switches terminal versus graphical
  visibility from mux view state. It exports configured tmux prefix keys so
  prefix commands remain mux-owned while ordinary graphical-mode keys go
  directly to the Wayland seat. The deterministic headless XDG contract proves
  wrong-scope rejection, scoped binding, console/application toggling, scene
  observability, app exit, and terminal restoration against installed package
  binaries. Native XDG popups now inherit their owning pane and scope;
  transient toplevels retain logical parentage and pane-local clipping without
  inflating the tab count. Independent toplevels become pane-local tabs, only
  one tab group is visible, and closing the active tab promotes its sibling and
  associated transient group. `shell-state.json` exposes popup counts, surface
  roles, tab counts, and per-surface visibility. The mux also preserves pending
  launch scopes across systemd-run PTY handoff while retaining immediate
  split-pane-host shell restoration and the 15-second unmapped failure. The
  installed contract proves the complete popup/transient/two-tab lifecycle.
  Tmux now owns the active surface ID and exports it through snapshots and the
  `pane_active_surface` format. `select-pane-surface` accepts a target pane and
  `next`, `previous`, or an ID; it changes that authoritative state, rejects
  popup/transient IDs, and invalidates graphical clients. The shell renders
  the selected toplevel and its transient group. The installed contract proves forward,
  backward, explicit rejection, compositor activation, and active-tab exit
  promotion. The mux snapshot now exports authoritative `left`, `top`,
  `columns`, and `rows` for every pane. The shell rejects malformed or duplicate
  pane models, retains the complete set, and records each stable identity,
  generation, geometry, active state, and presentation state under
  `shell-state.json`'s mux pane list. The installed contract compares split
  geometry with tmux's own pane formats and proves the shell retains both
  nonoverlapping panes. Graphical signals, close, and the unmapped-launch
  timeout now signal the authoritative transient systemd scope through the user
  manager, eliminating the fast-map race and avoiding stale process-group
  guesses. Per-pane scenes and the complete terminal topology lifecycle now
  pass in headless contracts. Each mapped graphical presentation now has an
  authoritative frontend-client/output-view lease stored by tmux and exposed
  through snapshots, formats, and `shell-state.json`. Focus transfers the
  lease, temporary graphical clients restore the previous owner on disconnect,
  destroyed or out-of-window views lose ownership, and the shell settles
  concurrent invalidations instead of retaining stale lease state. The exact
  installed `engineos-mux 3.6b-34` and `engineos-shell 0.1.0-52` binaries pass
  the complete two-output contract through AMD/radeonsi GLES2. Every output
  now owns a layout-positioned mux scene root with a console buffer node for
  every pane. The live XDG toplevel/transient set is parented only beneath the
  leased output's clipped pane subtree; nonowners keep their console copies,
  and a lease outside this compositor detaches and hides the presentation
  subtree. `shell-state.json` reports root coordinates, pane-copy counts, and
  bound versus visible presentation surfaces per output. Native pane images
  are now authoritative tmux console state rather than shell-local previews.
  `pane-image` retains bounded PNG/JPEG bytes, MIME type, owner, image ID, pane
  generation, and a client-view lease. The frontend advertises
  `pane-image-v1` and transports versioned 64 KiB chunks; the shell validates
  the full identity and byte count before memory decoding into the leased pane
  scene. `engine-image-preview` selects this path in native mode, and the shell
  rejects direct native pane-image mutation over `preview.sock`. Images are
  hidden above live graphical presentations and revealed with their backing
  consoles. `shell-state.json` publishes mux image metadata, decoded scene
  identity, and per-output visibility. The deterministic contract transports
  a multi-chunk image larger than 64 KiB, retains two independent pane images,
  proves owner-scoped removal and nonfocused-output isolation, and exercises
  console/application toggling. The exact installed radeonsi contract and the
  legacy preview contract both pass. Native game
  presentations now have an explicit mux type
  on launch and split, preserve that type across respawn, and use direct
  Wayland input with capture, cursor confinement, constraints, and the existing
  emergency-release path. Showing the console releases capture and returning
  to the presentation restores it. Native-mode `eos-app pane
  launch|split|view|signal|respawn|list` calls `engine-mux` directly and fails
  instead of falling back to bridge IPC; `eos-app launch quake` routes through
  a game pane and retains the pane PTY. The deterministic installed headless
  contract proves launch from the pane foreground job, game map, lease
  isolation, toggle, exit, respawn, and terminal restoration. Real Quake with
  user assets and bare-metal input/audio remain acceptance work. The frontend
  now accepts view-addressed snapshot requests and returns the exact synthetic
  tmux client's session/window model with explicit client, view, and output
  identity. It rejects unregistered view IDs instead of returning the globally
  focused view. A deterministic two-session contract proves two views on one
  frontend connection retain disjoint session attachments even while only one
  is focused, and the shell now explicitly addresses its focused output when
  refreshing state. The shell also retains a validated view-addressed model
  for every registered output, including its authoritative session, selected
  pane, pane generation, pane count, and revision. The pixman source contract
  and exact installed AMD/radeonsi contract move only the nonfocused output's
  synthetic tmux client to a temporary session, prove both output models
  remain present simultaneously, and prove the model follows reattachment.
  Every output model now resolves a retained, subscribed terminal grid for
  each pane, including panes outside the focused session. Nonfocused damage
  advances that output's grid revision without changing the focused session.
  State invalidations consumed while servicing grid or JSON requests remain
  sticky until every output snapshot settles, preventing ordering-dependent
  stale caches. Every output-pane scene now owns an independent terminal
  renderer, render target, damage stream, buffer, and statistics. Canonical
  grids are cloned or transferred safely when focus crosses sessions, while
  linked outputs render their own targets before shared damage is cleared.
  The deterministic contract proves a nonfocused session has exactly its own
  pane renderers and that terminal damage advances its selected renderer
  frame. Every output now also retains its own validated status/menu/prompt
  model, GPU renderer, buffer, damage, and frame statistics. UI responses are
  rejected unless they identify the requested view; invalidations remain
  view-scoped and output snapshots settle against the focused global model
  before state is published. The contract assigns a unique status string to
  a nonfocused session and proves only that output's UI renderer advances.
  The frontend now retains UI subscriptions for every registered output.
  Keyboard frames use the focused output model's pane identity and generation;
  pointer hit testing uses that output's UI geometry, and drags remain attached
  to their originating view. Focus transitions settle output snapshots before
  routing resumes. Presentation toplevels, transients, and explicit pane
  previews resolve the pane's owning output even when it is not focused. The
  deterministic two-session contract maps a Wayland client and image only on
  the nonfocused output while proving focused input identity remains
  unchanged.
  Simultaneous ordinary local and SSH tmux-client acceptance now passes
  against the same native pane tree. Local and remote `xterm-256color` clients
  each attach through a real 50x20 PTY while two graphical output clients
  remain registered, render the graphical pane's live backing console plus
  `wayland:presentation:2` metadata, execute the tmux command prompt, and drive
  the native `prefix+v` binding. The SSH contract starts an isolated
  loopback-only OpenSSH server with generated host/client keys, proves
  public-key authentication and a remote command session in the server log,
  forces a remote PTY, and runs `engine-mux attach-session` through that
  transport. The graphical shell observes each console transition and returns
  to the presentation, while either client's smaller dimensions leave the
  graphical canonical window size unchanged. The fork excludes ordinary
  clients from sizing only for windows owned by registered graphical views;
  ordinary tmux sizing remains unchanged for all other windows. Package
  `engineos-mux 3.6b-34`, packaged proof driver in `engineos-tools 0.1.0-41`,
  the installed pixman contract, and the exact installed AMD/radeonsi GLES2
  contract pass. Direct-KMS clipping now has a repeatable live acceptance
  command: `eos-proof native-kms`. It starts an isolated native mux session,
  temporarily restarts tty1 against that socket, and requires the real
  `drm,libinput` backend, a DRM GBM allocator, AMD/radeonsi GLES2, connector
  modesets, and successful scene-output commits. The 2026-07-11 run exercised
  two 1920x1080 outputs and two nonblank pane buffers per output; every buffer
  stayed inside its output and did not overlap its sibling through split,
  resize, zoom, and unzoom. Both outputs reported positive frame commits and
  zero commit failures. The proof restored the prior legacy desktop and
  removed its isolated mux server. Evidence is retained in
  `/var/log/engineos/proof-native-kms-20260711T100643Z/`.
  `eos-proof native-falkon` now passes the corresponding real application
  boundary on tty1. Falkon launches through `eos-app` with an enforced
  `--no-remote` dedicated instance, maps as `org.kde.falkon` only after its PID
  resolves to the pane's transient user scope, owns the pane PTY foreground
  process group, and keeps its live console output. The proof switches between
  presentation and console, signals the app, verifies the shell regains the
  foreground PTY and accepts a post-exit marker, then restores legacy mode.
  Evidence is retained in
  `/var/log/engineos/proof-native-falkon-20260711T104436Z/`. The same checkpoint
  raises mux frontend/client socket buffers so a valid 240x67 grid cannot fail
  as `grid-too-large`, and `engine-pane-host` explicitly retires empty split
  application scopes before starting the replacement login shell.
  `eos-proof native-quake` now passes the real game boundary with the user's
  registered Quake assets. It proves the pane foreground PTY and authoritative
  scope, mapped `quakespasm` game presentation, AMD RX 5600 XT/radeonsi GL,
  an uncorked PipeWire/Pulse stream on the ALSA hardware sink, capture and
  cursor lock, `prefix + v` console/application toggles, a real
  Ctrl+Alt+Backspace event through uinput, emergency capture release and
  recovery, clean process exit, prompt restoration, and rollback to the prior
  shell mode. Evidence is retained in
  `/var/log/engineos/proof-native-quake-20260711T110032Z/`. Recovery/startup
  acceptance now also passes. `engineos-config 0.1.0-5` installs tty2 as a
  recovery getty, `engineos-tools 0.1.0-47` installs
  `engineos-recovery-help`, and the real tty2 `agetty` is active. The installed
  `eos-proof shell-launch --bare-metal` run verifies the active EngineDev
  startup decision, tty1 shell service, tty2 recovery service, recovery
  command, DRM/libinput backend, and RX 5600 XT/radeonsi renderer. Generic EGL
  enumeration still exposes a separate llvmpipe device, but it no longer
  overrides direct evidence from the active shell. Evidence is retained in
  `/var/log/engineos/proof-shell-launch-bare-metal-20260711T111350Z.log`.
  Upstream-suite closure and cutover remain open.
  The canonical completion contract is
  [docs/graphical-tmux-goal.md](docs/graphical-tmux-goal.md).

## Not Yet Proven

- Runtime launchpad with user-provided Quake assets, including a mapped live
  Quake surface in Runtime.
- Interactive Quake keyboard, mouse, and audible audio in a live Runtime
  console session with user assets.
- Manual TrenchBroom GUI compile/run click-through proof. Setup generation,
  open-file smoke, packaged launcher setup, the equivalent compile/launch
  command path, entity-browser placement, and OS-level Wayland drag-and-drop
  are proven.
- Screenshot-based MC Quick View acceptance capture. The real live renderer,
  output selection, pane geometry, and show/hide IPC path are proven. The
  2026-07-10 `eos-proof mc-preview --visual` attempt failed closed because the
  compositor does not expose the screen-capture protocol required by `grim`;
  metadata-only output was not accepted as visual proof.
- Persistent Quake asset handling outside generated ISO images.
- Real Secure Boot and installer work only if explicitly re-enabled.

## Next Commands

Bare-metal/source-checkout loop:

```bash
./tools/engineos/eos-source-test agent
./tools/engineos/eos-test mux
./tools/engineos/eos-ci local --test agent --install --clean-generated --no-validate-repo
eos-app manifest validate
eos-proof mc-preview
./tools/engineos/eos-test mux
eos-proof shell-launch --bare-metal
```

Bare-metal hardware gate:

```bash
ENGINEOS_MUX_TEST_RENDERER=gles2 ENGINEOS_MUX_REQUIRE_RADEONSI=true \
  ./tools/engineos/eos-test mux
```

Agent and harness hygiene:

```bash
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-test agent-hygiene
./tools/engineos/eos-source-test agent
```
