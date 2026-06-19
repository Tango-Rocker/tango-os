# MVP Plan

This is the working plan from the current build lab to the first usable EngineRuntime appliance. Keep it ordered around proofs, not process.

## Product Shape

EngineOS has two images:

- EngineDev OS: development and diagnostics image for building confidence.
- EngineRuntime OS: smaller game-runtime image that boots into the EngineOS shell and launches QuakeSpasm.

The Windows host is the lab controller. The Arch builder VM is the build truth and owns `/srv/engineos`.

## Proof Ladder

### PoC 0: Build Lab

Goal: prove that the builder can repeatably build packages, build EngineDev, boot it, and collect diagnostics.

Acceptance:

- repo exists on the Arch builder at `/srv/engineos`
- `eos-validate builder` passes on the builder
- `eos-build repo` and `eos-validate repo` pass
- `eos-build iso enginedev` produces `EngineDevOS-*.iso`
- EngineDev boots in a test VM
- `eos-proof booted-iso --vm` passes inside the guest

Current status: PoC 0 EngineDev build-lab acceptance is complete. The first-deploy dev environment follow-on is also complete: Codex CLI, tmux defaults, Docker, and the post-install payload were proven in clean EngineDev guests.

Commands:

```bash
cd /srv/engineos
./tools/engineos/eos-validate builder
./tools/engineos/eos-build repo
./tools/engineos/eos-validate repo
./tools/engineos/eos-build iso enginedev
./tools/engineos/eos-vm boot enginedev --display none --background --ssh-port 2222
ENGINEOS_GUEST_PASSWORD=dev ./tools/engineos/eos-deploy first --host dev@127.0.0.1 --port 2222
```

Inside EngineDev:

```bash
eos-proof booted-iso --vm
tmux -V
docker info
codex --version
```

### PoC 1: Engine Loop

Goal: prove QuakeSpasm can launch through EngineOS with assets, logs, and crash evidence.

Acceptance:

- `eos-assets check quake` explains missing assets and passes with user-provided assets
- `eos-runtime quake --smoke` works in a generated ISO
- engine logs show launch arguments and audio driver
- crash bundle includes Quake asset state and engine logs

Current status: QuakeSpasm and the Quake template are packaged. Real assets were proven in a hot-patched EngineDev Hyper-V VM, Quake launches through EngineOS, logs the PulseAudio driver, executes generated default controls, and exits cleanly under timeout. Hyper-V basic console exposes only PipeWire/Pulse dummy output, so real audio still needs bare metal or an audio-capable VM/RDP path.

### PoC 2: Shell Loop

Goal: prove the shell can run, display clients, route input, launch terminal, and launch Quake.

Acceptance:

- `eos-build shell` passes on the Arch builder
- nested shell visibly runs under Wayland or X11
- TTY shell path starts in Runtime
- `Alt+Return` launches a terminal
- `Alt+G` launches Quake through EngineOS
- emergency release works and logs useful state

Current status: the shell compiles against `wlroots0.19`; local tests cover action wiring and source markers. Runtime service/autostart now passes in a generated EngineRuntime ISO, and the shell reaches DRM/libinput under QEMU with keyboard and pointer devices. The next shell slice is visible nested/TTY polish and interactive launch validation.

### PoC 3: Hardware Truth

Goal: prove the runtime image on the AMD target with real DRM/KMS, input, audio, and logs.

Acceptance:

- EngineRuntime boots on the AMD machine
- startup shell renderer is GL-capable and is not pixman/llvmpipe/softpipe
- at least one DRM output is connected and validated
- keyboard/mouse/game input reaches shell and Quake
- audio works through PipeWire/Pulse
- recovery TTY and crash bundle work

Current status: no bare-metal proof yet. Builder-hosted QEMU can expose an emulated ICH9 HDA device with `eos-vm boot --audio hda`; that proves guest ALSA/PipeWire plumbing but not real audible output.

## MVP

MVP is complete when EngineRuntime boots on the AMD machine, starts the shell, launches terminal and QuakeSpasm, recovers input, and leaves useful logs/crash bundles.

Release-candidate commands:

```bash
cd /srv/engineos
./tools/engineos/eos-proof release-candidate
./tools/engineos/eos-release checklist --out-dir out
```

Hardware handoff:

```bash
./tools/engineos/eos-proof hardware-ready --profile engineruntime --device /dev/sdX
eos-proof booted-iso --bare-metal
```

## Deferred Until After MVP

- Steam/Proton
- NVIDIA
- HDR and VRR
- dynamic multi-monitor layout
- rich 3D cockpit
- package signing
- read-only live runtime MCP after observability and role routing are stable
