---
name: crash-forensics
description: Use when shell, runtime service, engine, VM boot, graphics, audio, input, package, or proof behavior fails and evidence must be gathered before changing code.
---

# Crash Forensics Skill

Collect evidence before guessing.

## Sequence

```bash
./tools/engineos/eos-doctor
./tools/engineos/eos-logs all --last 200
./tools/engineos/eos-app status --json
./tools/engineos/eos-app manifest validate
./tools/engineos/eos-crash-bundle
```

Inside a live EngineOS session:

```bash
eos-proof shell-launch
eos-proof native-kms
eos-crash-bundle --runtime
eos-logs runtime --last 200
eos-logs shell --last 200
eos-logs engine --last 200
```

## Preserve

- Exact failed command and working directory.
- Git status and commit.
- VM/bare-metal mode.
- Last shell/app/engine/runtime logs.
- App status JSON and shell state JSON.
- Crash bundle path.

## Rule

Do not hide crash loops by disabling recovery TTY, running the compositor as
root, or deleting logs.
