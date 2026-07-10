# EngineOS Roadmap

The detailed plan lives in [docs/mvp-plan.md](docs/mvp-plan.md). This file is the short map.

A sprint here means a focused work chunk, not a calendar promise. Each chunk should end with working commands, updated status, and fewer unknowns.

## Current Track

Current phase: bare-metal EngineOS loop proof.

Immediate target: prove the live bare-metal checkout can rebuild/reinstall the
needed packages, start the accelerated shell, reject software compositor
rendering, leave recovery logs, and launch terminal/cube/Quake through the
shell-owned Wayland app stack.

Historical image-lab PoC is complete and archived:

- the local package repo built
- EngineDev and EngineRuntime image paths were proven far enough for smoke
  confidence
- VM/ISO evidence is no longer an active acceptance path

Historical first-deploy proof is complete:

- the managed post-install payload configures the EngineDev user
- the live install has Codex CLI, tmux defaults, and Docker available
- Docker is enabled/started and `dev` is in the `docker` group
- the setup log is captured at `/var/log/engineos/post-first-deploy.log`

Current runtime proof command:

```bash
./tools/engineos/eos-ci local --test agent --install --clean-generated --no-validate-repo
./tools/engineos/eos-test mux
eos-app manifest validate
eos-proof mc-preview
eos-game quake proof
eos-proof shell-launch --bare-metal
eos-logs shell --last 200
```

Inside the live bare-metal recovery TTY/session:

```bash
eos-app manifest validate
eos-proof shell-launch --bare-metal
eos-logs runtime --last 200
eos-logs engine --last 200
eos-crash-bundle --runtime
```

## Phase Summary

### Phase 0: Build Lab Foundation

- Sprint 0: legacy builder/image setup
- Sprint 1: repo skeleton and agent rails
- Sprint 2: local package repo v0
- Sprint 3: legacy EngineDev image smoke
- PoC 0: build lab proof

### Phase 1: Engine Loop PoC

- Sprint 4: diagnostics and log baseline
- Sprint 5: QuakeSpasm build and asset policy
- Sprint 6: per-user Quake service and validated launch request
- PoC 1: engine loop proof

### Phase 2: Shell PoC

- Sprint 7: wlroots headless shell
- Sprint 8: nested shell with one client
- Sprint 9: shell launches terminal and app slots
- Sprint 10: minimal surface model
- PoC 2: shell proof

### Phase 3: Hardware Truth PoC

- Sprint 11: bare-metal boot path
- Sprint 12: TTY/KMS shell attempt
- Sprint 13: input capture and emergency release
- PoC 3: hardware shell proof

### Phase 4: MVP Build

- Sprint 14: live package reinstall path
- Sprint 15: runtime autostart with recovery outside image builds
- Sprint 16: user asset flow
- Sprint 17: reliability pass
- Sprint 18: MVP release candidate

MVP is complete when EngineRuntime boots on the AMD machine, starts the shell, launches terminal and QuakeSpasm, recovers input, and leaves useful logs/crash bundles.

Bare-metal handoff command:

```bash
eos-validate boot --bare-metal
eos-proof shell-launch --bare-metal
```

### Phase 5: Polish After MVP

- boot and first-minute UX
- shell feel
- performance and latency
- multi-monitor static layout
- build hygiene

EngineRuntime image work is archived. Current acceptance runs through package
updates and the installed bare-metal app stack. The pane bridge, exact MC
output routing, shell state, and per-user Quake workflow are proven; the
remaining hardware gate is boot/recovery completeness plus interactive Quake
assets, input, and audible audio.

The next hardware gate is explicit: `eos-validate boot --bare-metal` and
`eos-proof shell-launch --bare-metal` must reject pixman/llvmpipe/software
shell rendering and require GL-capable renderer evidence from the startup shell
log before later tiling or overlay shell work counts as progress.

Polish is important, but it should not block the first usable MVP.
