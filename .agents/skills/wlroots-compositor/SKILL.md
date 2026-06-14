# wlroots Compositor Skill

## When To Use

Use this skill when changing `shell/`, compositor launch commands, or wlroots dependencies.

## Commands To Run

```bash
./tools/engineos/engineos build shell --dry-run
./tools/engineos/engineos run shell --headless
./tools/engineos/engineos test compositor --headless
./tools/engineos/engineos logs shell --last 200
```

## Files That Matter

```text
shell/
packages/engineos-shell/PKGBUILD
tools/engineos/engineos
artifacts/logs/shell.log
```

## Known Traps

- Headless mode comes before nested mode.
- Nested compositor behavior depends on the VM graphics stack.
- Direct TTY/KMS belongs on bare-metal AMD after VM smoke tests pass.

## Expected Output

The first implementation should start, log backend selection, accept a clean shutdown, and leave enough logs to diagnose startup failures.

## Recovery Steps

If nested mode fails, keep headless tests passing and record the VM renderer from `engineos doctor --vm`.
