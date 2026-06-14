# Archiso Build Skill

## When To Use

Use this skill when changing `archiso/*`, local package lists, ISO build scripts, or anything that affects `engineos build iso`.

## Commands To Run

```bash
./tools/engineos/engineos lint packages
./tools/engineos/engineos build iso --dry-run
./tools/engineos/engineos build repo --dry-run
```

On the Arch builder VM after package changes:

```bash
./tools/engineos/engineos build repo
./tools/engineos/engineos build iso enginedev
```

## Files That Matter

```text
archiso/enginedev/profiledef.sh
archiso/enginedev/packages.x86_64
archiso/enginedev/pacman.conf
tools/scripts/build_iso.sh
tools/scripts/build_repo.sh
packages/*/PKGBUILD
```

## Known Traps

- Real `mkarchiso` builds require Arch Linux.
- The source tree should live on a Linux filesystem inside the builder VM.
- The local repo must be built before an ISO can consume local EngineOS packages.

## Expected Output

Dry-run output should show the selected profile, work directory, output directory, and exact `mkarchiso` command.

## Recovery Steps

If the ISO build fails, run `engineos doctor --vm`, check package availability with `pacman -Sl`, rebuild the local repo, and remove only the documented `work/<profile>` build directory before retrying.
