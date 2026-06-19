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
- Keep traces replayable with `eos-input record` / `eos-input replay`.

## Checks

```bash
./tools/engineos/eos-test input
./tools/engineos/eos-test shell-actions
./tools/engineos/eos-input record artifacts/input-trace.json
./tools/engineos/eos-input replay artifacts/input-trace.json
```

For runtime validation:

```bash
eos-proof launchpad --runtime
eos-logs shell --last 200
```

## Files

```text
shell/
tools/scripts/input_trace.sh
tools/scripts/test_runner.sh
docs/mvp-plan.md
```
