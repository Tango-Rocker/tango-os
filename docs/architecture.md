# Architecture

EngineOS uses a Windows-hosted VM lab to build an Arch-based OS image without depending on the Windows filesystem for source-of-truth builds.

```text
Windows host
  -> Arch builder VM
       -> owns /srv/engineos
       -> builds local packages
       -> builds archiso images
       -> runs CLI, tests, editor, and agent workflows

  -> Test VM
       -> boots generated EngineDev ISO
       -> validates TTY, packages, logs, and smoke tests

Later:
  -> Bare-metal AMD machine
       -> validates real DRM/KMS, Mesa, outputs, latency, and game behavior
```

## Layers

### Layer 1: Source Repo

The repository contains code, docs, package definitions, archiso profiles, and tooling. It should live inside the Arch builder VM on ext4 or another Linux filesystem.

### Layer 2: Local Pacman Repo

EngineOS packages are built with `makepkg` and collected into a local repository with `repo-add`. The archiso profile consumes this repository through its `pacman.conf`.

### Layer 3: Generated ISOs

`mkarchiso` builds EngineDev from `archiso/enginedev` and EngineRuntime from `archiso/engineruntime`. Both profiles consume the local EngineOS package repo from `file:///srv/engineos/repo/$arch`.

EngineDev is the lab image: SSH, diagnostics, build tools, packaged QuakeSpasm, and proof commands.

EngineRuntime is the appliance image: runtime user, guarded autostart, recovery TTY, EngineOS shell, QuakeSpasm, and runtime logs.

## First Graphics Path

The compositor should progress through these modes:

1. headless wlroots backend
2. nested Wayland or X11 backend
3. real TTY/KMS backend on bare-metal AMD

VM graphics can validate process control and smoke behavior. Bare metal validates the real graphics stack.

## Builder Resources

The builder is allowed to be modest, but ISO builds need enough RAM and disk-backed temp space. The current repo build path expects:

- repo at `/srv/engineos`
- persistent swap available on low-memory builders
- `TMPDIR=/srv/engineos/tmp` for `mkarchiso`
- local package repo at `/srv/engineos/repo/x86_64`
