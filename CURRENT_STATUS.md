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
  has since advanced through the tmux-mirrored GUI window tracking work below.
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
- Bare-metal EngineDev has the v1 tmux pane bridge deployed through the local
  package reinstall/restart loop. `eos-app pane launch -- COMMAND` registers a
  tmux pane launch token with `engineos-shell`, shell state owns
  `pane_bindings`, generic GUI clients are laid out as `tmux-pane-gui`, and
  `engineos-tmux-pane-bridge` reports focus and geometry from tmux hooks
  without proxy tabs or a polling daemon. Cube/engine pane launches still use
  the existing `launch-bounds/*.env` path. The 2026-07-09 deploy refreshed
  `engineos-shell 0.1.0-16`, `engineos-tools 0.1.0-20`, and
  `engineos-config 0.1.0-3`; force-installed the managed tmux config and
  `/usr/local/bin/engineos-tmux-pane-bridge`; and left
  `/run/user/1000/engineos/shell-state.json` JSON-readable with
  `pane_bindings`. The same deploy added `engineos-tmux-attach-primary` for
  shell-owned terminal startup, so restarts attach the existing primary tmux
  session before creating the fallback `engineos` session. The live restart
  proof replaced shell PID 125037 with 167915 and verified only the expected
  sessions remain: primary client `tmux attach-session -t =2` on session `2`,
  and secondary client `tmux new -A -s engineos-side` on `engineos-side`; no
  detached `engineos` orphan session came back. `eos-app manifest validate`
  passes after the restart. The live Falkon pane visual proof is still pending.
  The EngineOS command-surface hardening is deployed through
  `engineos-tools 0.1.0-20`: `eos-source-test` clears installed-session
  contamination, `eos-proof` fails closed on required evidence, repeatable
  package selection is normalized through `eos-ci local`, and
  `eos-runtime shell restart-live` only reports success when a new
  `engineos-shell` PID is verified. The live shell package is
  `engineos-shell 0.1.0-16`.

## Not Yet Proven

- Runtime launchpad with user-provided Quake assets, including a mapped live
  Quake surface in Runtime.
- Interactive Quake keyboard, mouse, and audible audio in a live Runtime
  console session with user assets.
- Full `eos-proof shell-launch --bare-metal` still fails in the boot-validation
  gate: `ttf-dejavu` is missing, `getty@tty2.service` is not enabled,
  `engineos-recovery-help` is unavailable, `runtime-start.log` has no final
  startup decision, and the broad renderer heuristic sees an llvmpipe device.
  The restarted `engineos-shell` log itself shows AMD/radeonsi GLES2 rendering
  on the current shell, so the remaining failure is the broader boot gate, not
  the tmux pane bridge deploy path.
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
./tools/engineos/eos-source-test agent
./tools/engineos/eos-ci local --test agent --install --clean-generated --no-validate-repo
eos-app manifest validate
eos-app pane launch -- falkon
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
