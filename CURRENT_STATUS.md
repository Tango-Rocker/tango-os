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
  `engineos-shell 0.1.0-17`, `engineos-tools 0.1.0-29`, and
  `engineos-config 0.1.0-3`; force-installed the managed tmux config and
  `/usr/local/bin/engineos-tmux-pane-bridge`; and left
  `/run/user/1000/engineos/shell-state.json` JSON-readable with
  `pane_bindings`. The same deploy added `engineos-tmux-attach-primary` for
  shell-owned terminal startup, so restarts attach the existing primary tmux
  session before creating the fallback `engineos` session. Repeated shell
  restarts preserved one tmux server and its two attached clients: primary
  `/dev/pts/0` remains on session `2`, and secondary `/dev/pts/1` remains on
  `engineos-side`; no detached `engineos` session or proxy windows were
  created. `eos-app manifest validate` passes after restart. The live Falkon
  pane visual proof is still pending. The managed right-click status-window
  menu now includes `Move to Session...`; with one destination it moves the
  clicked stable window ID immediately, avoiding tmux's unreliable nested
  mouse menus, and resynchronizes pane geometry. The managed session-name menu
  also replaces tmux's client-terminating bare `new-session` action with
  detached creation followed by an explicit switch of the invoking client.
  The EngineOS command-surface hardening is deployed through
  `engineos-tools 0.1.0-29`: `eos-source-test` clears installed-session
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
- Native graphical mux migration stage 1 is installed side by side as
  `engineos-mux 3.6b-5` with the decoder boundary in
  `engineos-shell 0.1.0-20`, but native mode is not yet the live desktop
  default.
  The package builds the pinned
  official tmux 3.6b baseline as `engine-mux` with an isolated namespace. The
  fork server now owns the same-user `SOCK_SEQPACKET` frontend and constructs
  revisioned snapshots directly from tmux's session, window, and pane trees;
  the standalone `engine-muxd` and its `list-panes` subprocess path are removed.
  Its v1 handshake and atomic layout snapshots are exercised against real split
  panes and focus changes. The upstream regression scripts match an identically
  configured pristine build (21 pass and the same 11 host-baseline failures),
  including a passing environment-isolation test. The retired daemon binary
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
  pixels in the headless compositor. Status/menu/prompt models, ongoing damage
  consumption, glyph-atlas updates, and hardware-renderer acceptance remain.
  The canonical completion contract is
  [docs/graphical-tmux-goal.md](docs/graphical-tmux-goal.md).

## Not Yet Proven

- Runtime launchpad with user-provided Quake assets, including a mapped live
  Quake surface in Runtime.
- Interactive Quake keyboard, mouse, and audible audio in a live Runtime
  console session with user assets.
- Full `eos-proof shell-launch --bare-metal` still fails in the boot-validation
  gate: `getty@tty2.service` is not enabled, `engineos-recovery-help` is
  unavailable, `runtime-start.log` has no final
  startup decision, and the broad renderer heuristic sees an llvmpipe device.
  The restarted `engineos-shell` log itself shows AMD/radeonsi GLES2 rendering
  on the current shell, so the remaining failure is the broader boot gate, not
  the tmux pane bridge deploy path.
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
eos-app pane launch -- falkon
eos-game quake proof
eos-proof shell-launch --bare-metal
```

Bare-metal hardware gate:

```bash
eos-validate boot --bare-metal
eos-proof shell-launch --bare-metal
```

Agent and harness hygiene:

```bash
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-test agent-hygiene
./tools/engineos/eos-source-test agent
```
