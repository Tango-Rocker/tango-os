# EngineOS

EngineOS is a Windows-hosted, Arch-built OS lab for an EngineDev ISO first and a game-runtime appliance later. The Windows machine hosts the VM workflow. The Arch builder VM owns the source tree, builds local packages, and produces bootable ISO artifacts with `mkarchiso`.

Current target: finish the EngineDev first-deploy dev environment follow-on after PoC 0. The clean EngineDev ISO builds, boots, and passes `engineos proof booted-iso --vm`; the next proof is a fully usable dev guest with Codex CLI, tmux, Docker, and a repo-owned post-install payload. See [CURRENT_STATUS.md](CURRENT_STATUS.md) for current artifact paths and next commands.

## Quick Start

From a Linux shell in the repository root:

```bash
./tools/engineos/engineos --help
./tools/engineos/engineos doctor --mock
./tools/engineos/engineos doctor --vm
./tools/engineos/engineos doctor --bare-metal
./tools/engineos/engineos bootstrap builder --dry-run
./tools/engineos/engineos validate builder --mock
./tools/engineos/engineos validate repo --dry-run
./tools/engineos/engineos preflight all
./tools/engineos/engineos builder doctor-proof --dry-run --host dev@<builder-vm-ip>
./tools/engineos/engineos deploy first --dry-run --host dev@127.0.0.1 --port 2222
./tools/engineos/engineos proof build-lab --dry-run
./tools/engineos/engineos release checklist --dry-run
./tools/engineos/engineos usb list
./tools/engineos/engineos build shell --dry-run
./tools/engineos/engineos build iso --dry-run
./tools/engineos/engineos build iso enginedev --fast --dry-run
./tools/engineos/engineos build repo --dry-run
./tools/engineos/engineos engine status
./tools/engineos/engineos assets explain quake
./tools/engineos/engineos assets prepare quake
./tools/engineos/engineos build engine quake --dry-run
./tools/engineos/engineos validate engine quake
./tools/engineos/engineos validate shell
./tools/engineos/engineos logs all --files
./tools/engineos/engineos test compositor --headless
./tools/engineos/engineos test shell-actions
./tools/engineos/engineos test engine-runner-env
./tools/engineos/engineos test assets
./tools/engineos/engineos test reliability
./tools/engineos/engineos test logs
./tools/engineos/engineos test artifacts
./tools/engineos/engineos test vm
./tools/engineos/engineos test engine
./tools/engineos/engineos test shell
./tools/engineos/engineos test input
./tools/engineos/engineos test render --smoke
./tools/engineos/engineos test
```

`engineos capture frame --target shell` writes a PNG when `grim` or ImageMagick `import` is available, otherwise it writes a metadata artifact that records why capture fell back.

Inside a booted EngineDev ISO, validate the live environment with:

```bash
engineos proof booted-iso --vm
```

Inside a booted EngineRuntime ISO:

```bash
engineos proof booted-iso --runtime
```

Runtime autostart can be disabled with the `engineos.noautostart` kernel command-line flag.

Quake assets are user-provided and are not included in the ISO by default. The default user copy path is:

```text
~/.local/share/engineos/quake/id1/pak0.pak
```

Use `engineos assets prepare quake` to create the directory and `engineos assets check quake` to verify it.
After `engineos build engine quake --fetch` produces `engines/quakespasm/upstream/Quake/quakespasm`, `engineos run quake` can use that built binary automatically.

On the intended Arch builder VM, install the baseline build tools first:

```bash
./tools/engineos/engineos bootstrap builder --dry-run
./tools/engineos/engineos bootstrap builder
```

To inspect the exact package set without installing it:

```bash
./tools/engineos/engineos bootstrap builder --print-packages
```

## Repository Map

```text
archiso/              mkarchiso profiles
packages/             local Arch package definitions
shell/                wlroots shell source area
engine-runner/        process control daemon/client source area
engines/              engine ports and wrappers
tools/engineos/       top-level CLI
tools/scripts/        build, test, and diagnostic helpers
tools/mcp/            future MCP wrappers around the CLI
tools/codex/          Codex workflow helpers
docs/                 architecture and operating docs
.agents/skills/       project-local agent skills
tests/                smoke checks for the scaffold
```

## Docs

Start here:

- [CURRENT_STATUS.md](CURRENT_STATUS.md): current truth, artifacts, blockers, and next commands
- [ROADMAP.md](ROADMAP.md): short phase map
- [docs/README.md](docs/README.md): docs index by purpose
- [docs/mvp-plan.md](docs/mvp-plan.md): proof ladder to MVP
- [docs/architecture.md](docs/architecture.md): stable system shape
- [docs/agent-harness.md](docs/agent-harness.md): agent command policy
- [docs/builder-vm-hyperv.md](docs/builder-vm-hyperv.md): Windows Hyper-V builder setup
- [docs/dev-instance.md](docs/dev-instance.md): EngineDev first-deploy setup
- [AGENTS.md](AGENTS.md): agent entrypoint
- [BACKLOG.md](BACKLOG.md): deferred tangents

## Build Model

The project is built in three layers:

1. Source repo: code, tools, archiso profiles, docs, and package definitions.
2. Local pacman repo: EngineOS packages built from `packages/*`.
3. Generated ISO: `enginedev` first, `engineruntime` later.

The build scripts support dry-runs outside Arch. Real ISO and package builds require an Arch builder VM with `archiso`, `makepkg`, and `repo-add`.

On Windows Hyper-V, use [docs/builder-vm-hyperv.md](docs/builder-vm-hyperv.md)
to create the Arch builder VM and make `dev@<builder-vm-ip>` reachable.

The repo should live at `/srv/engineos` on a Linux-native filesystem because the archiso profiles consume the local package repo from `file:///srv/engineos/repo/$arch`.

On the Arch builder VM, the current proof sequence is:

```bash
./tools/engineos/engineos bootstrap builder --dry-run
./tools/engineos/engineos bootstrap builder
./tools/engineos/engineos validate builder
./tools/engineos/engineos proof build-lab
```

That command runs preflight, package lint, shell build, local repo build, EngineDev ISO build, and artifact listing with a timestamped proof log under `artifacts/logs`.
It also validates the local repo artifacts before the ISO build step.

ISO builds use `TMPDIR=/srv/engineos/tmp` so mkinitcpio does not fill the builder's `/tmp` tmpfs. The current builder also has a persistent 4 GiB swapfile; increasing Hyper-V RAM still requires an elevated Windows shell.

For faster EngineDev iteration, use the generated fast-compression profile:

```bash
./tools/engineos/engineos build iso enginedev --fast --clean --archive-existing
```

`--fast` switches only the generated build profile to SquashFS `zstd` level 3.
The checked-in archiso profile remains on `xz` for release-candidate builds.

If you want to boot the generated ISO with QEMU from the builder VM, install QEMU plus OVMF firmware and run:

```bash
./tools/engineos/engineos vm boot enginedev --dry-run
./tools/engineos/engineos vm boot enginedev
```

The helper discovers the newest `EngineDevOS-*.iso` under `out/` by default. Manual VMware or VirtualBox booting is still fine; the required guest commands are the same.

Inside the booted guest, run:

```bash
engineos proof booted-iso --vm
```

To turn the booted EngineDev guest into a working development instance, run from
the builder:

```bash
ENGINEOS_GUEST_PASSWORD=dev ./tools/engineos/engineos deploy first --host dev@127.0.0.1 --port 2222
```

The deploy command copies `tools/post-install-payload/` into the guest, installs
or verifies tmux/Docker/Codex CLI, starts Docker, and writes
`/var/log/engineos/post-first-deploy.log`.

After the EngineDev VM is already booted by the builder with SSH forwarded on
port 2222, the host-side combined build-and-doctor validation is:

```bash
./tools/engineos/engineos builder doctor-proof --host dev@<builder-vm-ip>
```

That command SSHes into the builder, runs the build-lab proof, then SSHes from
the builder into the booted EngineDev guest and runs `engineos doctor --vm`.
On this Windows/WSL lab, use `ENGINEOS_SSH=ssh.exe` if WSL cannot route to the
Hyper-V builder but Windows OpenSSH can.

After a real ISO build, export artifacts and checksums to a host-visible directory:

```bash
./tools/engineos/engineos artifacts export /path/to/export
```

For an MVP release-candidate report after both ISOs exist:

```bash
./tools/engineos/engineos release checklist --out-dir out --export-dir /path/to/export
```

To prepare a USB stick for bare-metal testing, inspect devices and dry-run the write first:

```bash
./tools/engineos/engineos usb list
./tools/engineos/engineos usb write --profile engineruntime --device /dev/sdX --dry-run
```

The real write requires `--yes-i-understand-this-wipes-device` and refuses non-block-device targets.
