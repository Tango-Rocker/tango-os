# Current Status

Current focus: prove the EngineRuntime startup shell on the AMD target with
hardware GL acceleration, shell-owned Wayland clients, useful recovery logs,
and Quake launch through the EngineOS app stack.

Current deployment context: this session is the bare-metal EngineDev
installation. Do not build ISO profiles or ISO artifacts again until the user
explicitly re-enables that path.

Historical proof notes that no longer need to stay in the active status file
are archived in
[docs/session-archive/2026-07-04-engineos-proof-history/README.md](docs/session-archive/2026-07-04-engineos-proof-history/README.md).

## Current Artifacts

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
- PoC 0 and the EngineDev first-deploy follow-on are complete: the builder can
  rebuild the package repo and EngineDev ISO, a clean EngineDev guest boots,
  `eos-proof booted-iso --vm` passes, and first-deploy provides tmux, Docker,
  Docker Compose, Codex CLI, and the post-install payload.
- EngineRuntime has a generated ISO and packaged launchpad path. Runtime
  autostart, DRM/libinput shell startup, crash-bundle recovery,
  terminal/cube launchpad mapping, missing-Quake-asset handling,
  shell-state JSON, and emulated QEMU HDA audio plumbing are proven in
  builder-hosted QEMU.
- Bare-metal EngineDev has the current shell/app stack deployed without an ISO
  rebuild, including pane-bounds app launch, game cursor capture, MC image
  preview, Quick View preview integration, and the Falkon startup crash fix.
  The live shell package is `engineos-shell 0.1.0-8`.
- EngineDev-only Quake level-agent V1 is live-proven without an ISO rebuild:
  terminal `serve/build/status/load` works, Quake console
  `agent` / `agent_status` / `agent_load` works through the tracked
  QuakeSpasm command patch, and TrenchBroom setup/open-file smoke is packaged.
- Agent-pack hygiene currently passes. Canonical ownership is
  `.agents/index.toml` plus `docs/agent-roles.md`; reusable workflows belong
  in skills; CLI work stays on direct `eos-*` commands.

## Not Yet Proven

- Runtime launchpad with user-provided Quake assets, including a mapped live
  Quake surface in Runtime.
- Interactive Quake keyboard, mouse, and audible audio in a live Runtime
  console session with user assets.
- Hardware GL shell startup proof on the AMD target. VM paths are useful smoke
  tests only: the builder QEMU GL path lacks a render node and Hyper-V reports
  llvmpipe.
- Manual TrenchBroom GUI compile/run clicks. Setup generation, open-file smoke,
  and the equivalent compile/launch command path are proven.
- Visual live MC Quick View acceptance capture with the real
  `engine-image-preview` and shell preview path.
- Persistent Quake asset mounting across live ISO reboot.
- Real USB write and Secure Boot boot with an enrolled EngineOS db certificate.

## Next Commands

Runtime VM smoke before hardware:

```bash
cd /srv/engineos
./tools/engineos/eos-build iso engineruntime --fast --clean --archive-existing
./tools/engineos/eos-vm boot engineruntime --display none --background --ssh-port 2223 --audio hda
sshpass -p engineos ssh -p 2223 engineos@127.0.0.1 'eos-proof booted-iso --runtime'
sshpass -p engineos ssh -p 2223 engineos@127.0.0.1 'eos-app manifest validate'
sshpass -p engineos ssh -p 2223 engineos@127.0.0.1 'eos-proof launchpad --runtime'
```

Bare-metal hardware gate:

```bash
eos-validate boot --bare-metal
eos-proof shell-launch --bare-metal
eos-proof booted-iso --bare-metal
```

Agent and harness hygiene:

```bash
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-test agent-hygiene
./tools/engineos/eos-test agent
```
