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
  is `engineos-shell 0.1.0-15`.
- Bare-metal EngineDev has a systemd-boot fallback entry,
  `enginedev-restore-engineos-20260704.conf`, pointing at copied
  `/boot/vmlinuz-linux-restore-engineos-20260704` and
  `/boot/initramfs-linux-restore-engineos-20260704.img`. The normal default
  remains `enginedev.conf`.
- EngineDev-only Quake level-agent V1 is live-proven without an ISO rebuild:
  terminal `serve/build/status/load` works, Quake console
  `agent` / `agent_status` / `agent_load` works through the tracked
  QuakeSpasm command patch, and TrenchBroom setup/open-file smoke is packaged.
  The live editor path now uses `engineos-level-agent 0.1.0-8` and
  `engineos-trenchbroom 2026.1-4`; the packaged `trenchbroom` and
  `engineos-trenchbroom` commands both regenerate the canonical
  `EngineOSQuake` profile before opening the real editor binary, with entity
  definitions resolved from `Quake.fgd` inside that profile, the TrenchBroom
  game path set to the resolved EngineOS Quake asset root, and Quake model
  loading configured with `gfx/palette.lmp`. The package also carries an
  EngineOS source patch so clicking a point entity in the entity browser creates
  it at the map origin and selects it. Entity browser placement through the
  shell's Wayland drag/drop path is also live-confirmed on the current
  EngineDev session.
- Agent-pack hygiene currently passes. Canonical ownership is
  `.agents/index.toml` plus `docs/agent-roles.md`; reusable workflows belong
  in skills; CLI work stays on direct `eos-*` commands.
- Tmux-mirrored GUI window tracking is live on the bare-metal EngineDev
  session: mapped shell windows have session-local IDs in shell state,
  `eos-app window list|focus|bind|launch` is the control surface, tmux proxy
  helpers mirror non-terminal GUI windows, and pane-bound generic GUI windows
  are resized/clipped through per-window bounds. GUI proxy tabs now bind
  windows using tmux client cell dimensions, refresh bounds on tmux tab/layout
  and client-resize hooks, bring the app forward when the proxy tab is
  selected, bind matching launcher panes such as a `falkon` tmux window
  directly to the shell window instead of requiring a generated proxy tab, hide
  pane-bound GUI windows again when a normal tmux tab is selected, and suppress
  no-op pane sync text in hook output. The rebuilt
  `engineos-shell` and `engineos-tools` packages were reinstalled,
  `engineos-dev-shell.service` was restarted, and live Qt/Falkon proxy
  focus/bind was proven with window bounds written under
  `/run/user/1000/engineos/window-bounds/`.

## Not Yet Proven

- Runtime launchpad with user-provided Quake assets, including a mapped live
  Quake surface in Runtime.
- Interactive Quake keyboard, mouse, and audible audio in a live Runtime
  console session with user assets.
- Hardware GL shell startup proof on the AMD target.
- Manual TrenchBroom GUI compile/run click-through proof. Setup generation,
  open-file smoke, packaged launcher setup, the equivalent compile/launch
  command path, entity-browser placement, and OS-level Wayland drag-and-drop
  are proven.
- Visual live MC Quick View acceptance capture with the real
  `engine-image-preview` and shell preview path.
- Persistent Quake asset handling outside generated ISO images.
- Real Secure Boot and installer work only if explicitly re-enabled.

## Next Commands

Bare-metal/source-checkout loop:

```bash
./tools/engineos/eos-ci local --test agent --install --clean-generated --no-validate-repo
eos-app manifest validate
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
./tools/engineos/eos-test agent
```
