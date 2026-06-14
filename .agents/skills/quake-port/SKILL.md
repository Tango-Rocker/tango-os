# Quake Port Skill

## When To Use

Use this skill when changing QuakeSpasm source, wrappers, asset manifests, or `engineos run quake`.

## Commands To Run

```bash
./engines/quakespasm/engineos/fetch.sh --dry-run
./engines/quakespasm/engineos/build.sh --dry-run
./tools/engineos/engineos build engine quake --dry-run
./engines/quakespasm/engineos/smoke-test.sh
./tools/engineos/engineos run quake --smoke
./tools/engineos/engineos logs engine --last 200
```

## Files That Matter

```text
engines/quakespasm/
packages/engineos-quake-template/assets.toml
docs/asset-policy.md
artifacts/logs/engine.log
```

## Known Traps

- Do not commit commercial Quake assets.
- Prefer SDL2 and OpenGL for the first loop.
- Keep launch behavior deterministic before adding engine-runner control.

## Expected Output

The smoke path should succeed without commercial assets and record whether the QuakeSpasm binary is available.

## Recovery Steps

If the binary is missing, keep the wrapper smoke path passing, then add source checkout and build instructions under `engines/quakespasm/upstream`.
