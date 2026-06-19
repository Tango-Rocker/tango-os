---
name: quake-port
description: Use when changing QuakeSpasm source, Quake package definitions, asset policy, engine wrapper behavior, app launch quake routing, or engine-runner integration.
---

# Quake Port Skill

Quake is the first engine loop proof. The shell should survive engine failure,
and commercial assets must stay outside the repo and ISO.

## Checks

```bash
./tools/engineos/eos-build fetch engine quake --status
./tools/engineos/eos-build engine quake --dry-run
./tools/engineos/eos-validate engine quake --mock
./tools/engineos/eos-runtime quake --smoke
./tools/engineos/eos-assets check quake
./tools/engineos/eos-logs engine --last 200
```

For Runtime launchpad routing:

```bash
./tools/engineos/eos-app manifest validate
./tools/engineos/eos-proof launchpad --runtime --dry-run
```

## Files

```text
engines/quakespasm/
packages/engineos-quakespasm/PKGBUILD
packages/engineos-quake-template/
packages/engineos-config/files/etc/engineos/quake.conf
docs/asset-policy.md
tools/scripts/assets.sh
tools/scripts/app.sh
tools/scripts/engine_runner.sh
artifacts/logs/engine.log
```
