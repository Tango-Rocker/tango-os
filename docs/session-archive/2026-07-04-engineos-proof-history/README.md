# EngineOS Proof History Archive

Date: 2026-07-04 UTC

This archive holds durable proof history that used to live in
`CURRENT_STATUS.md`. Keep active status short; add only stable history here
when it materially helps future work.

## Builder And ISO Foundation

- PoC 0 completed for EngineDev: the Arch builder at `/srv/engineos` can
  rebuild the local package repo and EngineDev ISO, the ISO checksum passes,
  the ISO boots headlessly in QEMU, SSH comes up on the forwarded port, and
  `eos-proof booted-iso --vm` passes inside the clean live guest.
- EngineDev live ISO work added explicit SSH validation access, locale/keymap
  setup, `cow_spacesize=50%`, packaged `eos-install guide`, live Codex setup,
  `console=tty0` for bare-metal monitor output, and package-cache assisted
  install support.
- EngineRuntime reached a generated ISO with packaged runtime shell,
  launchpad, cube, QuakeSpasm, config, engine runner, runtime logs, and
  crash-bundle recovery. Builder-hosted QEMU proves runtime service startup and
  launchpad smoke behavior, but not hardware GL.

## EngineDev Install And First Deploy

- `eos-deploy first` proved the EngineDev post-install path in a booted guest:
  tmux, zsh/oh-my-zsh, Docker, Docker Compose, Codex CLI, dev convenience
  tools, and post-install logs were present and validated.
- EngineDev autoinstall gained guarded disk partitioning, package-cache use,
  private repo token support through transient `GIT_ASKPASS`, fstab generation
  fixes, and a noninteractive clone path for the private Tang-OS repo.
- A full VM autoinstall proof reached a booted installed target with
  `eos-doctor --vm`, Docker, Docker Compose, Codex, sshd, NetworkManager, and
  `engineos-dev-shell.service` active.

## Shell, Apps, And Runtime

- EngineDev and Runtime shell work established shell-owned Wayland app launch
  through `eos-app`, launchpad app manifests, terminal/cube/engine slots,
  pane-bounded cube and Quake launches, input focus routing, emergency release,
  relative pointer and pointer-constraints support, and shell-state JSON.
- Bare-metal EngineDev live proofs deployed shell follow-ups without ISO
  rebuilds: Quake pane bounds, game cursor capture, cube pane bounds, inactive
  pane-visible GL panels, MC image preview, MC Quick View preview updates, and
  Falkon startup crash recovery.
- The Falkon crash fix deployed as `engineos-shell 0.1.0-8`; it guards
  wlroots xdg-toplevel configure setters until xdg surfaces are initialized,
  preventing the `wlr_xdg_surface_schedule_configure` assertion seen during
  Falkon startup.

## Quake And Level Agent

- QuakeSpasm packaging, wrapper policy, asset checks, user-owned asset
  handling, default input binds, PulseAudio selection, and console reset after
  SDL/KMS shutdown were proven across VM and bare-metal EngineDev paths.
- Commercial Quake assets remain user-managed and out of repo/images.
- EngineDev-only level-agent V1 was live-proven without an ISO rebuild:
  `engineos-level-agent serve`, `eos-level-agent build ... --wait`,
  `status`, and `load` generated and compiled maps through
  `/home/dev/quake-generator` and loaded BSPs into the active Quake path.
- Quake console commands `agent`, `agent_status`, and `agent_load` were
  exercised through the tracked QuakeSpasm command patch.
- TrenchBroom setup is packaged and smoke-proven for game/profile generation
  and opening generated maps; manual GUI compile/run clicks remain unproven.

## Agent Harness

- The project moved to `eos-*` domain commands and removed project-status/docs
  MCP as an execution path. Future MCP work is reserved for read-only live
  runtime state only.
- Agent pack canonical sources are `.agents/index.toml`,
  `docs/agent-roles.md`, role-local `AGENTS.md` files, skills, and generated
  profiles/wrappers. `eos-agent hygiene check` validates role/path drift.
- `engineos-tools` owns the shared Bash dispatcher/runtime, public `eos-*`
  wrappers, domain modules under `tools/eos/`, post-install payload, update
  and observability helpers, and agent dispatcher/exporter units.

## Remaining Historical Caveats

- Hyper-V basic console sessions do not expose an ALSA sound card to Linux in
  the current lab; audible output belongs on hardware or an audio-forwarding VM
  path.
- VM graphics smoke is not hardware proof. Builder QEMU currently lacks a DRM
  render node for accelerated GL and Hyper-V reports llvmpipe.
- Secure Boot artifacts and keys were generated and verified locally, but
  firmware enrollment plus real USB boot remains unproven.
