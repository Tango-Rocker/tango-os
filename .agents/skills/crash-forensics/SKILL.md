---
name: crash-forensics
description: Use when shell, runtime service, engine, VM boot, graphics, audio, input, package, or proof behavior fails and evidence must be gathered before changing code.
---

# Crash Forensics Skill

Collect evidence before guessing.

## Sequence

```bash
./tools/engineos/engineos doctor --mock
./tools/engineos/engineos logs all --last 200
./tools/engineos/engineos app status --json
./tools/engineos/engineos app manifest validate
./tools/engineos/engineos crash-bundle
```

Inside a booted ISO, use the mode that matches the session:

```bash
engineos proof booted-iso --vm
engineos proof launchpad --runtime
engineos crash-bundle --runtime
engineos logs runtime --last 200
engineos logs shell --last 200
engineos logs engine --last 200
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
