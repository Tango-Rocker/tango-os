# EngineOS Roadmap

The detailed plan lives in [docs/mvp-plan.md](docs/mvp-plan.md). This file is the short map.

A sprint here means a focused work chunk, not a calendar promise. Each chunk should end with working commands, updated status, and fewer unknowns.

## Current Track

Current phase: EngineRuntime/engine-loop proof.

Immediate target: prove the generated EngineRuntime ISO boots, starts the runtime service, leaves recovery logs, and can launch the EngineOS shell/Quake path far enough to collect useful evidence.

PoC 0 is complete:

- the repo lives in the Arch builder VM
- the local package repo builds
- EngineDev ISO builds
- EngineDev ISO boots in a clean test VM
- `engineos proof booted-iso --vm` passes inside the ISO

Follow-on dev-instance proof is complete:

- `engineos deploy first` copies the post-install payload to the booted EngineDev guest
- the guest has Codex CLI, tmux defaults, and Docker available
- Docker is enabled/started and `dev` is in the `docker` group
- the setup log is captured at `/var/log/engineos/post-first-deploy.log`

Hyper-V is useful for clean VM boot, SSH, writable live-overlay, input visibility, and Quake smoke/runtime log checks. It is not a real audio proof path for the current Linux live ISO because basic Hyper-V console sessions do not expose an ALSA sound card to the guest; audio acceptance belongs on bare metal or an audio-capable VM/RDP path.

Current runtime proof command:

```bash
cd /srv/engineos
./tools/engineos/engineos build iso engineruntime --fast --clean --archive-existing
./tools/engineos/engineos vm boot engineruntime --display none --background --ssh-port 2223 --audio hda
sshpass -p engineos ssh -p 2223 engineos@127.0.0.1 'engineos proof booted-iso --runtime'
```

Inside EngineRuntime recovery TTY/session:

```bash
engineos proof booted-iso --runtime
engineos logs runtime --last 200
engineos logs engine --last 200
engineos crash-bundle --runtime
```

For VM audio plumbing proof, boot with `--audio hda`. This exposes a QEMU
ICH9 HDA device to the guest and lets PipeWire/WirePlumber create an ALSA-backed
sink/source. The current builder QEMU path discards host audio output, so it is
not a real audible-output proof.

## Phase Summary

### Phase 0: Build Lab Foundation

- Sprint 0: Builder VM setup
- Sprint 1: repo skeleton and agent rails
- Sprint 2: local package repo v0
- Sprint 3: EngineDev ISO boots in test VM
- PoC 0: build lab proof

### Phase 1: Engine Loop PoC

- Sprint 4: diagnostics and log baseline
- Sprint 5: QuakeSpasm build and asset policy
- Sprint 6: engine runner v0
- PoC 1: engine loop proof

### Phase 2: Shell PoC

- Sprint 7: wlroots headless shell
- Sprint 8: nested shell with one client
- Sprint 9: shell launches terminal and engine
- Sprint 10: minimal surface model
- PoC 2: shell proof

### Phase 3: Hardware Truth PoC

- Sprint 11: bare-metal boot path
- Sprint 12: TTY/KMS shell attempt
- Sprint 13: input capture and emergency release
- PoC 3: hardware shell proof

### Phase 4: MVP Build

- Sprint 14: EngineRuntime ISO profile
- Sprint 15: runtime autostart with recovery
- Sprint 16: user asset flow
- Sprint 17: reliability pass
- Sprint 18: MVP release candidate

MVP is complete when EngineRuntime boots on the AMD machine, starts the shell, launches terminal and QuakeSpasm, recovers input, and leaves useful logs/crash bundles.

Bare-metal handoff command:

```bash
./tools/engineos/engineos proof hardware-ready --profile engineruntime --device /dev/sdX
engineos proof booted-iso --bare-metal
```

### Phase 5: Polish After MVP

- boot and first-minute UX
- shell feel
- performance and latency
- multi-monitor static layout
- build hygiene

EngineRuntime has a generated ISO and packaged runtime path. Runtime autostart, DRM/libinput shell startup, crash-bundle recovery, and emulated VM audio-device plumbing are proven; interactive Quake with user assets and audible hardware audio still need live proof.

Polish is important, but it should not block the first usable MVP.
