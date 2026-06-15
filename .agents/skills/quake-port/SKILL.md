---
name: quake-port
description: Use when changing QuakeSpasm source, Quake package definitions, asset policy, engine wrapper behavior, app launch quake routing, or engine-runner integration.
---

# Quake Port Skill

Quake is the first engine loop proof. The shell should survive engine failure,
and commercial assets must stay outside the repo and ISO.

## Checks

```bash
./tools/engineos/engineos fetch engine quake --status
./tools/engineos/engineos build engine quake --dry-run
./tools/engineos/engineos validate engine quake --mock
./tools/engineos/engineos run quake --smoke
./tools/engineos/engineos assets check quake
./tools/engineos/engineos logs engine --last 200
```

For Runtime launchpad routing:

```bash
./tools/engineos/engineos app manifest validate
./tools/engineos/engineos proof launchpad --runtime --dry-run
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
