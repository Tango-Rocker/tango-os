# Current Status

Current focus: add a safe EngineDev autoinstall path so a booted ISO can install a persistent, self-hosting dev OS, clone the official Tang-OS repo into `/srv/engineos`, run post-install setup, and hand off to `dev` for Codex-driven EngineOS/game work.

PoC 0 build-lab acceptance is complete for EngineDev. The Arch builder can repeatably rebuild the local package repo and EngineDev ISO, the rebuilt ISO checksum passes, the ISO boots headlessly in QEMU, SSH comes up through the forwarded port, and `engineos proof booted-iso --vm` passes inside the clean live guest. The first-deploy dev environment follow-on is also proven: the guest has tmux, Docker, Docker Compose, Codex CLI, and the post-install payload applied.

## Current Artifacts

- Arch builder VM: `dev@172.22.52.109`
- Builder repo path: `/srv/engineos`
- Local package repo: `/srv/engineos/repo/x86_64`
- EngineDev ISO: `out/EngineDevOS-2026.06.15-x86_64.iso` on the builder
- EngineDev checksum: `out/EngineDevOS-2026.06.15-x86_64.iso.sha256`
- EngineRuntime ISO: `out/EngineRuntimeOS-2026.06.15-x86_64.iso`
- EngineRuntime checksum: `out/EngineRuntimeOS-2026.06.15-x86_64.iso.sha256`

The latest EngineDev ISO checksum passed on the builder with:

```bash
cd out
sha256sum -c EngineDevOS-2026.06.15-x86_64.iso.sha256
```

Current EngineDev checksum after the cached-package autoinstall rebuild:

```text
EngineDevOS-2026.06.15-x86_64.iso: OK
```

Current EngineRuntime checksum after the launchpad MVP proof rebuild:

```text
e4547a916d59765e962e7b0766ba3f18175f5cfd46e020df504451c8a2d7add2  EngineRuntimeOS-2026.06.15-x86_64.iso
```

## Working

- `engineos` is the control surface for builder setup, package builds, ISO builds, VM boot helpers, USB dry-runs, diagnostics, proofs, logs, assets, shell launches, engine launches, and tests.
- The Arch builder VM has the repo at `/srv/engineos`, validates cleanly, builds EngineOS packages, validates the local repo, and builds EngineDev/EngineRuntime ISOs.
- `engineos proof build-lab` completed on the Arch builder after rebuilding existing package artifacts with `makepkg -f`.
- A clean EngineDev ISO rebuild was forced by archiving the previous same-day artifact and removing `work/enginedev`; the fresh ISO was written at `2026-06-13 22:13 UTC`.
- The builder has a persistent 4 GiB `/swapfile`; `engineos build iso` uses disk-backed `TMPDIR=/srv/engineos/tmp`, can clean/archive ISO artifacts, remounts `/tmp` to 8 GiB when needed, and caps the archiso SquashFS step to 4 processors for stable builds on the tuned Hyper-V builder.
- EngineDev and EngineRuntime profiles write `/etc/engineos/version` and regenerate `/etc/issue` with the profile/build date.
- Installed-image `engineos preflight scripts` checks `/usr/bin/engineos` and `/usr/lib/engineos/scripts` instead of looking for source-tree paths.
- Installed script helpers treat `/usr/lib/engineos/scripts` as installed mode, use `/var/log/engineos` for logs and `/var/lib/engineos/captures` for default captures, avoiding `/usr/artifacts` permission failures.
- Installed Quake launch treats `/usr` and installed package prefixes as installed mode, uses `/var/log/engineos`, and uses `/usr/lib/engineos/scripts`.
- `engineos vm boot` uses a QEMU `-bios` compatible OVMF image (`OVMF.4m.fd`) instead of the pflash-only `OVMF_CODE.4m.fd`.
- EngineDev live ISO now configures explicit SSH password access for validation: `dev` / `dev`.
- EngineDev and EngineRuntime live ISOs set locale, keymap, UTC timezone, hostname, serial console output, and mask `systemd-firstboot.service` to avoid interactive first-boot prompts during VM validation.
- `engineos vm boot` can boot headlessly with `--display none --background`, writing pid, QEMU, and serial logs under the EngineOS state/log directories.
- The latest EngineDev ISO was rebuilt with `cow_spacesize=50%` and copied from the builder to the Windows host at `E:\dev\Tang-OS\out\EngineDevOS-2026.06.14-cowspace-x86_64.iso`, checksum `2cb8450fe6a4f520b1255ea6493d25250e7b5c0c27f9113de69e987ef57345fa`.
- `tools/scripts/create_iso_test_vm_hyperv.ps1` creates a separate Hyper-V ISO test VM, dry-run by default, for direct EngineDev/EngineRuntime validation outside the builder-hosted QEMU path.
- EngineDev and EngineRuntime UEFI boot entries set `cow_spacesize=50%`; on the 4 GiB Hyper-V test VM this raises the live writable overlay from archiso's 256 MiB default to 2.0 GiB. The checked-in boot entries also mask `serial-getty@ttyS0.service` to stop the Hyper-V serial-console restart loop, and `engineos preflight iso` enforces the EngineDev boot-entry settings.
- Hyper-V test VM `EngineOS-EngineDev-Test` was recreated from the cowspace-rebuilt June 14 EngineDev ISO and booted on the Default Switch at `172.22.49.144`; `engineos proof booted-iso --vm` passed there.
- `engineos deploy first` stages a repo-owned post-install payload into a booted EngineDev guest and runs first-time dev setup for tmux, zsh/oh-my-zsh, Docker, and Codex CLI.
- `engineos build iso enginedev --fast` generates a temporary zstd-compressed profile for faster dev ISO iteration while keeping checked-in profiles on xz.
- The fast EngineDev build completed in 134 seconds on the tuned builder. The resulting ISO is 1.8 GiB, checksum-valid, boots in QEMU, and passes `engineos proof booted-iso --vm` after first-deploy.
- First-deploy validation passed in the fresh guest: `tmux 3.6b` with mouse enabled and packaged plugin scripts configured, packaged oh-my-zsh with zsh plugin packages, `codex-cli 0.139.0`, Docker `29.5.2` with `overlayfs`, Docker Compose `5.1.4`, `dev` in the `docker` group, and `docker.service` active.
- First-deploy also passed on the separate Hyper-V EngineDev test VM: `tmux 3.6b`, `@engineos-plugins`, oh-my-zsh, `codex-cli 0.139.0`, Docker `29.5.2` with `overlayfs`/systemd cgroups, Docker Compose `5.1.4`, readable `/dev/input/event*` and `/dev/input/mouse0`, active PipeWire/Pulse services, and Quake smoke logs from `/usr/bin/quakespasm`.
- EngineDev self-host rehearsal passed in the Hyper-V test VM using the separate 32 GiB VHD: `/dev/sda` was partitioned/formatted as `ENGINEOS_DEV_SRV`, mounted at `/srv`, seeded with `/srv/engineos`, and survived reboot with the repo checkout plus local package repo artifacts intact. The live ISO root reverted package installs after reboot, as expected, while reinstalling `engineos-cli` from `/srv/engineos/repo/x86_64` restored the rebuilt package.
- `engineos install dev --dry-run --device <block-device>` now prints the safe EngineDev autoinstall plan: destructive disk layout, `/srv` persistence, optional ISO package cache use, official Tang-OS repo clone, local repo build, post-install payload execution, and first-boot handoff proof.
- `engineos install dev --device <block-device> --yes-i-understand-this-wipes-device` now has a guarded executor for the VM/bare-metal path. It wipes and partitions the target, installs Arch/EngineDev packages, configures systemd-boot, creates the `dev` user, enables NetworkManager/sshd/Docker, clones Tang-OS into `/srv/engineos`, builds the local package repo, runs the post-install payload, and writes `/srv/ENGINEOS_INSTALL_HANDOFF.txt`.
- EngineDev ISO builds now default to staging an installer package cache into generated EngineDev profiles at `/opt/engineos/install-cache/pkg`; `engineos install dev` validates that requested install package artifacts are present, uses the cache through a generated pacman config and `pacstrap -c -C ...`, falls back to normal pacman cache/mirrors when the cache is absent, and rejects incomplete caches with an explicit rebuild/`--no-package-cache` handoff.
- EngineDev autoinstall now defaults the source checkout to `https://github.com/Tango-Rocker/tango-os.git`, runs Git clones non-interactively, and supports private repo access through `--repo-token-file` / `ENGINEOS_REPO_TOKEN_FILE`. The token is copied only into the target runtime under root-only transient storage, used through a temporary `GIT_ASKPASS` helper, redacted from installer output, and removed immediately after clone.
- A full EngineDev autoinstall VM proof passed on June 15, 2026 using the rebuilt ISO `out/EngineDevOS-2026.06.15-x86_64.iso`, a disposable qcow2 target disk exposed as `/dev/vda`, and the private `Tango-Rocker/tango-os` repo on branch `main`. The live ISO package cache contained 1008 package artifacts under `/opt/engineos/install-cache/pkg`, `pacstrap` installed the cached 501-package transaction, `/srv/engineos` cloned to commit `23b8ebb`, and the installed target built 13 local package artifacts.
- The full VM autoinstall used the read-only GitHub token from `/run/engineos-secrets/tango-os-readonly.token` without printing it or embedding it permanently. Installed-disk checks confirmed `/root/.engineos/repo-token` and `/usr/local/bin/engineos-git-askpass` were absent after the clone.
- The installed EngineDev target booted from the qcow2 and passed the full non-skip post-install validation: `/usr/bin/engineos` exists, `engineos --help` works, `engineos doctor --vm` passes, builder mock validation and repo validation both report 0 failures and 0 warnings, `tmux 3.6b` and packaged zsh/oh-my-zsh config load, Docker `29.5.2` is active with `overlayfs`, Docker Compose `5.1.4` works, `codex-cli 0.139.0` is installed, `sshd` and NetworkManager are active, and `engineos-dev-shell.service` is enabled.
- The source fix for private repo cloning is proven, but the tested ISO predates that fix and was hot-patched in the live guest from current source to use `/usr/local/bin/engineos-git-askpass`. Rebuild the EngineDev ISO before treating the no-hotpatch path as baked into install media.
- The first real Hyper-V install attempt reached `pacstrap` against the VM's `/dev/sda` and downloaded the full 501-package transaction, proving the wipe, partition, format, mount, and mirrorlist repair steps. It then failed at keyring commit with `Public keyring not found` / `keyring is not writable`; the installer has been updated to stop using `pacstrap -K` and instead let pacstrap seed the target from the live ISO host keyring, matching pacstrap's default behavior.
- For the current Hyper-V EngineDev session, classic base Quake assets were manually staged from `E:\SteamLibrary\steamapps\common\Quake\id1\PAK0.PAK` and `PAK1.PAK` directly into `/home/dev/.local/share/engineos/quake/id1`; no bind mount is needed with the larger cowspace ISO.
- A timed real Quake launch passed over SSH on the Hyper-V EngineDev VM: `engineos run quake` found the registered assets, initialized an 800x600 OpenGL mode through Mesa llvmpipe, initialized PulseAudio (`pulseaudio - Dummy Output` after starting user PipeWire/Pulse services), loaded `demo1.dem`, executed `autoexec.cfg`, and was stopped by a 12-second timeout with no lingering Quake process and active VT restored to `tty1`.
- Hyper-V audio diagnosis: PipeWire/Pulse is running, but the VM has no ALSA sound card (`aplay -l` reports no soundcards and `/dev/snd` only has `seq`/`timer`), so PipeWire exposes only `auto_null`/Dummy Output. Elevated host inspection found no Hyper-V sound device exposed for `EngineOS-EngineDev-Test`; Enhanced Session Mode is enabled on the host, but this Arch live ISO is running through the basic Hyper-V console/SSH path, not an RDP audio-redirection guest session. This is a Hyper-V virtual hardware/console limitation for the current VM path, not a Quake wrapper issue.
- Quake hotkey diagnosis/fix: the generated `config.cfg` had old defaults (`a`/`d` as look up/down style binds and `MOUSE2` as forward). `engineos-quake-template` `pkgrel=2` now makes the Quake wrapper create a missing `id1/autoexec.cfg` with EngineOS defaults: WASD movement, `MOUSE1` attack, `MOUSE2` jump, `MOUSE3`/`e` mouselook, and `cl_alwaysrun 1`.
- Quake black-screen diagnosis/fix: the VM was still reachable over SSH and Hyper-V reported it running, so the failure was the visible console left in graphics/blank state after SDL/KMS termination rather than a kernel hang. The Quake wrapper now keeps Quake as a child process, traps `INT`/`TERM`/`HUP`, terminates the child, and resets the text console with `setterm`, `kbd_mode -a`, and `setfont` before exit.
- The current Hyper-V test VM was restarted after the black-screen report. `engineos proof booted-iso --vm` passed after restart at `172.22.49.144`; the manually staged Quake assets and hot-patched wrapper were reapplied, and `serial-getty@ttyS0.service` was masked for the live session. The booted ISO's `/proc/cmdline` still lacks the serial-getty mask until the next ISO rebuild from the updated profile.
- Current Hyper-V EngineDev login-shell validation passed at `dev@172.22.49.144`: `dev` has `/usr/bin/zsh` as its passwd login shell, interactive zsh loads oh-my-zsh from `/usr/share/oh-my-zsh`, `tmux 3.6b` starts, and a detached `engineos-proof` tmux session can launch a zsh pane (`tmux_zsh_ok:5.9.1`, `pane_command=zsh`). The live VM's legacy `/home/dev/.tmux.conf` was backed up to `/home/dev/.tmux.conf.engineos-legacy.bak` and replaced with the current EngineOS config; `tmux show -g @engineos-plugins` now reports `tmux-sensible tmux-yank tmux-resurrect tmux-continuum tmux-pain-control`.
- After rebooting the current Hyper-V EngineDev VM, inspection showed it is still the older June 14 ISO image: `engineos-shell` is not installed, no dev/runtime shell service exists, `WAYLAND_DISPLAY` is unset, and EGL reports Mesa llvmpipe. That explains why logging in lands on a plain zsh/tmux-capable TTY instead of the OpenGL shell. The running live guest was hot-patched again so `/home/dev/.tmux.conf` contains `@engineos-plugins` and `/home/dev/.zprofile` execs `tmux new-session -A -s engineos` for the next interactive login, but the shell/autostart fix requires a rebuilt EngineDev ISO.
- EngineDev is now patched for the rebuilt-image path: `archiso/enginedev/packages.x86_64` includes `engineos-shell`, `engineos-dev-shell.service` autostarts on `tty1` as `dev`, requires the shell-owned Wayland terminal path, and bootstraps the terminal only with `ENGINEOS_TERMINAL_SESSION_CMD=tmux new -A -s engineos`. EngineDev and EngineRuntime zsh login profiles now auto-attach tmux for interactive login shells, guarded by `ENGINEOS_AUTO_TMUX=0` for opt-out. First-deploy now backs up and replaces legacy EngineOS `.tmux.conf` and `.zprofile` files.
- The first-deploy payload now carries the same dev shell retrofit: it requests `engineos-shell` during package install, installs `/usr/local/bin/engineos-dev-shell-start`, installs `/etc/systemd/system/engineos-dev-shell.service`, enables the service when `engineos-shell` is available, and otherwise logs the exact blocker plus the enable command to rerun after installing/rebuilding. Payload preflight now requires the shell-start helper, service unit, managed zprofile, and tmux-owned Wayland launch markers.
- The shell-owned app launch contract is now explicit: `engineos app launch terminal|cube|quake` requires `WAYLAND_DISPLAY` by default, sets common Wayland client hints (`XDG_SESSION_TYPE`, `SDL_VIDEODRIVER`, GTK/Qt hints), unsets `DISPLAY` when the shell Wayland socket is active, logs `owner=engineos-shell` to `app.log`, writes cube output to `cube.log`, and dispatches Quake through the existing engine runner. The shell default launchpad commands now use `engineos app launch terminal`, `engineos app launch cube`, and `engineos app launch quake`; `engineos app status --json` reports log-derived shell/slot/app state for proofs.
- The launchpad app registry is now packaged at `/etc/engineos/apps.toml` from `packages/engineos-config/files/etc/engineos/apps.toml`. `engineos app manifest validate` checks the terminal, cube, and Quake slot contract, `engineos run shell` reads the manifest for default slot commands, and `engineos proof launchpad` validates the manifest before checking runtime logs.
- The first rebuilt EngineRuntime ISO booted in builder-hosted QEMU far enough to mount the 50% cowspace and reach login, but exposed two runtime-proof blockers: `engineos-live-setup.service` was ordered after `multi-user.target`, creating a cycle that skipped `engineos-engine-runner.service`, and Runtime did not yet enable explicit SSH password access for automated VM proof. The profile now runs live setup before the runtime services and configures `engineos` / `engineos` SSH validation access.
- A clean generated EngineRuntime ISO now passes `engineos proof booted-iso --runtime` in builder-hosted QEMU through SSH port 2223 with 0 boot-validation failures and 0 warnings. The final proven ISO is `EngineRuntimeOS-2026.06.15-x86_64.iso`, checksum `e4547a916d59765e962e7b0766ba3f18175f5cfd46e020df504451c8a2d7add2`.
- The final Runtime proof image contains `engineos-cli 0.1.0-12`, `engineos-cube 0.1.0-2`, `engineos-shell 0.1.0-4`, `engineos-engine-runner 0.1.0-5`, `engineos-config 0.1.0-3`, and `engineos-quakespasm 0.97.0-1`.
- Runtime autostart reaches `engineos-shell` on DRM/libinput under QEMU: `Virtual-1` modesets at 1280x800, the shell starts with `backend=drm,libinput`, and libinput reports the AT keyboard plus `ImExPS/2 Generic Explorer Mouse`. QEMU falls back to the wlroots pixman renderer because bochs-drm has no render node and GLES refuses software rendering; this is acceptable for the VM proof but not a bare-metal renderer proof.
- Runtime logging and recovery are now package-backed: the runner unit prepares `/var/log/engineos` and `/var/lib/engineos` as `root:wheel 0775` without `LogsDirectory=engineos`, `engineos` command/profile handling preserves explicit environment overrides, and `crash-bundle --runtime` captures isolated log directories correctly.
- The Runtime graphical shell entry point is now explicit: `engineos-shell` accepts `--bootstrap none|terminal|engine|launchpad` (`all` is an alias), `engineos run shell --tty` passes `--bootstrap launchpad` by default, and packaged `runtime.conf` sets `ENGINEOS_SHELL_BOOTSTRAP=launchpad` so Runtime starts terminal, cube, and engine launch commands after the shell Wayland socket is ready with cube as the active slot.
- `engineos proof launchpad` is now the focused MVP acceptance gate for the shell launchpad: it checks launchpad bootstrap, cube active slot, shell-owned terminal/cube/Quake app launch markers, cube renderer/frame evidence, and either a mapped engine slot or Quake asset/runtime guidance.
- `engineos proof launchpad --runtime` passes on the final EngineRuntime ISO. Runtime launches terminal, cube, and Quake through `engineos app launch ...`; terminal maps inactive, cube maps active and visible, and the engine slot logs `reason=process-exited-before-map` with Quake asset guidance when `pak0.pak` is absent.
- The cube launchpad app is a packaged SDL2/Wayland OpenGL ES client. Its live log records `video_driver=wayland`, Mesa GL renderer/version details, and `frames=1` after the first successful swap while continuing to run fullscreen as the active slot.
- The shell writes live state to `/run/user/1000/engineos/shell-state.json`. The final Runtime proof showed schema `engineos-shell-state-v0`, `bootstrap=launchpad`, `active_slot=cube`, terminal mapped but hidden, cube mapped and visible, and engine unmapped because assets were missing.
- `engineos-shell` now tracks shell-launched child processes by pid, records the intended launchpad role, marks launches when that role maps, reaps `SIGCHLD`, and logs exit status plus `reason=process-exited-before-map` for slot commands that die before creating a surface.
- Local validation for the shell bootstrap entry point passed after freeing WSL resources: `bash -n ...`, `tools/engineos/engineos build shell --dry-run`, `tools/engineos/engineos test shell-actions`, and `tools/engineos/engineos test shell` all completed. Expected local warnings remain: non-Arch host, missing `pkg-config` wlroots modules, and a WSL systemd user-session warning.
- Runtime terminal startup now lands directly in the configured dev shell: packaged `runtime.conf` sets `ENGINEOS_TERMINAL_SESSION_CMD='tmux new -A -s engineos'`, `engineos terminal` runs that command under `zsh -lc` inside the selected graphical terminal, and the Runtime `engineos` user inherits the checked-in `.zshrc`/`.tmux.conf` from `/etc/skel`.
- Runtime graphical client launch is now pinned to the shell-owned Wayland display: `engineos-shell` exports Wayland session hints and unsets `DISPLAY` for spawned terminal/engine clients, `engineos terminal` requires `WAYLAND_DISPLAY` by default and no longer falls back to `xterm`, and `engineos-runtime.service` sets `XDG_SESSION_TYPE=wayland` plus `ENGINEOS_TERMINAL_REQUIRE_WAYLAND=true`. VM renderer limitations still apply; hardware acceleration must be proven on the AMD target.
- `engineos vm boot` now supports `--audio hda`, which adds a QEMU ICH9 HDA controller and duplex codec. A Runtime VM booted with that option exposes `HDA Intel` in `/proc/asound/cards`, `aplay -l` lists `Generic Analog`, WirePlumber reports `Built-in Audio Analog Stereo` sink/source, and `speaker-test -D default` reaches the guest audio path. QEMU is using a discard backend, so this proves guest audio plumbing but not audible host output.
- EngineRuntime includes the Quake audio default path through `/etc/engineos/quake.conf` with `ENGINEOS_QUAKE_SDL_AUDIODRIVER=pulseaudio`.
- EngineRuntime TTY shell launch passes default terminal, cube, and engine commands into `engineos-shell`, so `Alt+Return`, `Alt+G`, `Alt+1`, `Alt+2`, `Alt+3`, and `Alt+Tab` have configured launchpad actions.
- EngineDev and EngineRuntime live users get input/audio/video/render access, PipeWire user units are globally enabled, and live setup repairs groups and udev state at boot.
- In the booted EngineDev guest, `dev` can read `/dev/input/event*` and `/dev/input/mouse0`, PipeWire/Pulse reports active through `pactl info`, and `engineos run quake --smoke` finds `/usr/bin/quakespasm`.
- QuakeSpasm is packaged and included with the Quake template package. Real user-provided Quake assets have been proven in a hot-patched EngineDev VM under Xvfb.
- The wlroots shell compiles on the Arch builder against `wlroots0.19` and has basic scene, input, focus, terminal launch, engine launch, and emergency release paths in source.
- Local focused tests cover CLI smoke paths, package/repo scaffolding, assets, logs, proof dry-runs, boot validation fixtures, shell actions, engine-runner environment forwarding, input traces, output validation, and render capture fallback.

## Not Yet Proven

- Interactive Quake keyboard/mouse/audio in a live Runtime console session with user assets.
- Persistent Quake asset mounting is not implemented yet; the current Hyper-V VM still loses manually copied assets on reboot because it is a live ISO, even though the writable overlay is now large enough for session-local copies.
- Real audible output is not proven in the current Hyper-V/basic QEMU path. Hyper-V is not presenting a sound device to Linux, and the QEMU HDA proof uses an audio discard backend; prove audible output on hardware or an audio-forwarding VM/RDP path.
- Visible hardware/frame-capture proof of the Runtime shell is still missing; the current Runtime proof is headless QEMU evidence from logs, state JSON, and app renderer/frame logs.
- Runtime launchpad with user-provided Quake assets is not proven yet, so the engine slot has not mapped as a live Quake surface in Runtime.
- Real USB writing to removable media.
- Bare-metal AMD boot, DRM/KMS validation, and hardware renderer proof.
- Hyper-V CPU/RAM settings are not changed from this repo; raising them requires elevated Windows PowerShell.

## Next Commands

Re-run the completed EngineDev VM proof if needed:

```bash
cd /srv/engineos
./tools/engineos/engineos build iso enginedev --fast --clean --archive-existing
./tools/engineos/engineos vm boot enginedev --display none --background --ssh-port 2222
sshpass -p dev ssh -p 2222 dev@127.0.0.1 'engineos proof booted-iso --vm'
sshpass -p dev ssh -p 2222 dev@127.0.0.1 'engineos proof shell-launch --vm'
```

Remote guest inspection after the rebuilt ISO boots:

```bash
ssh -p 2222 dev@127.0.0.1   # password: dev
engineos proof booted-iso --vm
tmux -V
tmux start-server \; show -g mouse \; show -g @engineos-plugins
zsh -ic 'echo $ZSH; echo $plugins'
docker info
codex --version
engineos run quake --smoke
engineos assets check quake
tail -n 200 /var/log/engineos/engine.log
```

First-deploy dev environment setup from the builder:

```bash
cd /srv/engineos
ENGINEOS_GUEST_PASSWORD=dev ./tools/engineos/engineos deploy first --host dev@127.0.0.1 --port 2222
sshpass -p dev ssh -p 2222 dev@127.0.0.1 'tmux -V; /home/dev/.local/bin/codex --version; docker info'
```

EngineDev autoinstall planner proof:

```bash
./tools/engineos/engineos install dev --dry-run --device /dev/sdX --repo-url https://github.com/Tango-Rocker/tango-os.git --branch main
./tools/engineos/engineos test install
./tools/engineos/engineos preflight repo --package engineos-cli
```

Re-run the completed EngineDev autoinstall VM proof if needed:

```bash
cd /srv/engineos
./tools/engineos/engineos build repo
./tools/engineos/engineos build iso enginedev --fast --clean --archive-existing
# boot the rebuilt ISO in the QEMU test VM with a disposable qcow2 target disk, then from the live guest:
find /opt/engineos/install-cache/pkg -maxdepth 1 -name '*.pkg.tar*' | wc -l
sudo engineos install dev --device /dev/vda --repo-url https://github.com/Tango-Rocker/tango-os.git --branch main --repo-token-file /run/engineos-secrets/tango-os-readonly.token --yes-i-understand-this-wipes-device
```

Runtime interactive retest:

```bash
cd /srv/engineos
./tools/engineos/engineos vm boot engineruntime --display none --background --ssh-port 2223 --audio hda
sshpass -p engineos ssh -p 2223 engineos@127.0.0.1 'engineos proof booted-iso --runtime'
sshpass -p engineos ssh -p 2223 engineos@127.0.0.1 'engineos app manifest validate'
sshpass -p engineos ssh -p 2223 engineos@127.0.0.1 'engineos proof launchpad --runtime'
sshpass -p engineos ssh -p 2223 engineos@127.0.0.1 'engineos logs runtime --last 200; engineos logs shell --last 200'
sshpass -p engineos ssh -p 2223 engineos@127.0.0.1 'cat /proc/asound/cards; wpctl status'
```

Windows Hyper-V ISO test VM:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\scripts\create_iso_test_vm_hyperv.ps1 -IsoPath .\out\EngineDevOS-2026.06.14-cowspace-x86_64.iso -Execute -Start
```

Current Hyper-V EngineDev test guest:

```bash
ssh dev@172.22.49.144   # password: dev
engineos proof booted-iso --vm
engineos run quake --smoke
engineos logs engine --last 80
```

Temporary Quake asset staging used for the current Hyper-V VM:

```bash
mkdir -p /home/dev/.local/share/engineos/quake/id1
# copy pak0.pak and pak1.pak into /home/dev/.local/share/engineos/quake/id1
engineos assets check quake
systemctl --user start pipewire.socket pipewire-pulse.socket wireplumber.service
timeout 12s engineos run quake
```

After launching Quake inside Runtime, inspect:

```bash
engineos logs engine --last 200
engineos logs shell --last 200
```

Expected markers:

- `QuakeSpasm audio_driver=pulseaudio`
- `launch commands terminal=... cube=... engine=...`
- `launch action label=bootstrap-cube role=cube`
- `launch action exit label=... role=... status=... mapped=...`
- `launchpad slot unavailable role=engine reason=process-exited-before-map` when Quake exits before mapping

## Resource Note

The builder was tuned from Windows Hyper-V and now validates with 6 vCPUs, 4 GiB swap, at least 8 GiB `/tmp`, OVMF, and no builder warnings. Earlier low-memory settings caused `pacstrap` kills, `mkinitcpio` `/tmp` failures, and SquashFS compression failures. The repo also works around constrained builders with persistent swap, disk-backed mkarchiso temp space, automatic `/tmp` tmpfs remounting, clean/archive ISO builds, and capped SquashFS compression.

For a real speed improvement, run elevated PowerShell on the Windows host. On this 40 GiB / 12 logical CPU host, the helper will choose generous defaults around 8 GiB startup RAM, 16 GiB maximum RAM, and 6 vCPUs:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\scripts\tune_builder_vm_hyperv.ps1 -Execute -Restart
```
