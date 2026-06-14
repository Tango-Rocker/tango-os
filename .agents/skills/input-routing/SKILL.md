# Input Routing Skill

## When To Use

Use this skill when implementing focus modes, game capture, emergency release, input traces, or replay.

## Commands To Run

Future commands:

```bash
engineos test input
engineos record input traces/focus.json
engineos replay input traces/focus.json
```

Current scaffold checks:

```bash
./tools/engineos/engineos run shell --headless
./tools/engineos/engineos logs shell --last 200
```

## Files That Matter

```text
shell/
engine-runner/
tools/engineos/engineos
artifacts/logs/
```

## Known Traps

- Always preserve an emergency input release path.
- Separate terminal focus mode from game capture mode.
- Record enough trace metadata to replay failures.

## Expected Output

Input tests should prove focus transitions, pointer event context, and recovery behavior before game capture is enabled by default.

## Recovery Steps

If focus gets stuck in a test build, disable capture by default, add logging around mode transitions, and require explicit capture toggles.
