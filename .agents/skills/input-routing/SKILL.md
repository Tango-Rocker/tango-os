---
name: input-routing
description: Use when changing shell input focus, pointer capture, keyboard shortcuts, emergency release, input traces, or game-vs-shell routing behavior.
---

# Input Routing Skill

Input bugs can make the machine feel broken. Preserve recovery and collect
traces before changing routing policy.

## Rules

- Keep an emergency release path available.
- Do not let game focus permanently steal shell focus.
- TTY/KMS input changes need VM smoke first and bare-metal proof later.
- Keep traces replayable with `engineos record input` / `engineos replay input`.

## Checks

```bash
./tools/engineos/engineos test input
./tools/engineos/engineos test shell-actions
./tools/engineos/engineos record input artifacts/input-trace.json
./tools/engineos/engineos replay input artifacts/input-trace.json
```

For runtime validation:

```bash
engineos proof launchpad --runtime
engineos logs shell --last 200
```

## Files

```text
shell/
tools/scripts/input_trace.sh
tools/scripts/test_runner.sh
docs/mvp-plan.md
```
