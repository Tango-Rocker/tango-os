# Crash Forensics Skill

## When To Use

Use this skill when shell, engine, ISO boot, or test VM behavior fails and logs need to be gathered.

## Commands To Run

```bash
./tools/engineos/engineos logs shell --last 200
./tools/engineos/engineos logs engine --last 200
./tools/engineos/engineos crash-bundle
```

## Files That Matter

```text
artifacts/logs/
artifacts/crash-bundles/
tools/scripts/crash_bundle.sh
```

## Known Traps

- `journalctl` output may be unavailable outside a systemd boot.
- VM graphics failures are not final evidence about bare-metal AMD behavior.
- Missing logs are a bug in the command wrapper if the process was launched through `engineos`.

## Expected Output

`engineos crash-bundle` prints the bundle directory path and writes metadata, `doctor.txt`, available logs, engine status, Quake asset check output, preflight output, and journal files when available.

## Recovery Steps

If no logs are present, reproduce the failure through an `engineos run` or `engineos test` command so the wrapper can capture predictable output.
