---
name: archiso-build
description: Use when changing archiso profiles, package lists, pacman config, local repo generation, package cache staging, systemd boot/session defaults, or ISO build workflow.
---

# Archiso Build Skill

## Scope

Use this skill for files under `archiso/`, local package definitions under
`packages/`, and build wrappers that affect `engineos build repo` or
`engineos build iso`.

## Rules

- Do not edit generated `work/` or `out/` artifacts as source.
- Prefer `./tools/engineos/engineos build iso ...` over direct `mkarchiso`.
- Keep EngineDev and EngineRuntime profile differences explicit.
- Real package and ISO builds belong on the Arch builder VM at `/srv/engineos`.
- Keep commercial game assets out of packages and ISO profiles.

## Checks

Local dry-runs:

```bash
./tools/engineos/engineos lint packages
./tools/engineos/engineos preflight repo
./tools/engineos/engineos build repo --dry-run
./tools/engineos/engineos build iso enginedev --dry-run
./tools/engineos/engineos build iso engineruntime --dry-run
```

Builder VM proof:

```bash
cd /srv/engineos
./tools/engineos/engineos build repo
./tools/engineos/engineos build iso enginedev --fast --clean --archive-existing
./tools/engineos/engineos build iso engineruntime --fast --clean --archive-existing
```

## Files

```text
archiso/enginedev/profiledef.sh
archiso/enginedev/packages.x86_64
archiso/enginedev/pacman.conf
archiso/engineruntime/profiledef.sh
archiso/engineruntime/packages.x86_64
archiso/engineruntime/pacman.conf
tools/scripts/build_iso.sh
tools/scripts/build_repo.sh
tools/scripts/preflight.sh
packages/*/PKGBUILD
```
