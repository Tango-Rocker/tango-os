# Current Status

Current focus: continue from the completed EngineDev first-deploy dev environment proof into the next Runtime/engine-loop proofs.

PoC 0 build-lab acceptance is complete for EngineDev. The Arch builder can repeatably rebuild the local package repo and EngineDev ISO, the rebuilt ISO checksum passes, the ISO boots headlessly in QEMU, SSH comes up through the forwarded port, and `engineos proof booted-iso --vm` passes inside the clean live guest. The first-deploy dev environment follow-on is also proven: the guest has tmux, Docker, Docker Compose, Codex CLI, and the post-install payload applied.

## Current Artifacts

- Arch builder VM: `dev@172.22.52.109`
- Builder repo path: `/srv/engineos`
- Local package repo: `/srv/engineos/repo/x86_64`
- EngineDev ISO: `out/EngineDevOS-2026.06.14-x86_64.iso` on the builder; copied to Windows as `out/EngineDevOS-2026.06.14-cowspace-x86_64.iso`
- EngineDev checksum: `out/EngineDevOS-2026.06.14-x86_64.iso.sha256`
- EngineRuntime ISO: `out/EngineRuntimeOS-2026.06.14-x86_64.iso`
- EngineRuntime checksum: `out/EngineRuntimeOS-2026.06.14-x86_64.iso.sha256`

The latest EngineDev ISO checksum passed on the builder with:

```bash
cd out
sha256sum -c EngineDevOS-2026.06.14-x86_64.iso.sha256
```

Current EngineDev checksum after the cowspace rebuild:

```text
2cb8450fe6a4f520b1255ea6493d25250e7b5c0c27f9113de69e987ef57345fa  EngineDevOS-2026.06.14-x86_64.iso
```

Current EngineRuntime checksum after the Runtime autostart proof rebuild:

```text
4c567278b635bf469742705aac5ed78ee5a22a7665271e4b4bd028262554007a  EngineRuntimeOS-2026.06.14-x86_64.iso
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
- The first rebuilt EngineRuntime ISO booted in builder-hosted QEMU far enough to mount the 50% cowspace and reach login, but exposed two runtime-proof blockers: `engineos-live-setup.service` was ordered after `multi-user.target`, creating a cycle that skipped `engineos-engine-runner.service`, and Runtime did not yet enable explicit SSH password access for automated VM proof. The profile now runs live setup before the runtime services and configures `engineos` / `engineos` SSH validation access.
- A clean generated EngineRuntime ISO now passes `engineos proof booted-iso --runtime` in builder-hosted QEMU through SSH port 2223. The proof validated Runtime boot checks, `engineos-cli 0.1.0-6`, `engineos-engine-runner 0.1.0-2`, QuakeSpasm smoke, asset guidance, reliability/crash-bundle checks, and the systemd Runtime autostart path.
- Runtime autostart reaches `engineos-shell` on DRM/libinput under QEMU: `Virtual-1` modesets at 1280x800, the shell starts with `backend=drm,libinput`, and libinput reports the AT keyboard plus `ImExPS/2 Generic Explorer Mouse`. QEMU falls back to the wlroots pixman renderer because bochs-drm has no render node and GLES refuses software rendering; this is acceptable for the VM proof but not a bare-metal renderer proof.
- Runtime logging and recovery are now package-backed: the runner unit prepares `/var/log/engineos` and `/var/lib/engineos` as `root:wheel 0775` without `LogsDirectory=engineos`, `engineos` command/profile handling preserves explicit environment overrides, and `crash-bundle --runtime` captures isolated log directories correctly.
- The Runtime graphical shell entry point is now explicit: `engineos-shell` accepts `--bootstrap none|terminal|engine|all`, `engineos run shell --tty` passes `--bootstrap all` by default, and packaged `runtime.conf` sets `ENGINEOS_SHELL_BOOTSTRAP=all` so Runtime starts both terminal and engine launch commands after the shell Wayland socket is ready.
- Local validation for the shell bootstrap entry point passed after freeing WSL resources: `bash -n ...`, `tools/engineos/engineos build shell --dry-run`, `tools/engineos/engineos test shell-actions`, and `tools/engineos/engineos test shell` all completed. Expected local warnings remain: non-Arch host, missing `pkg-config` wlroots modules, and a WSL systemd user-session warning.
- Runtime terminal startup now lands directly in the configured dev shell: packaged `runtime.conf` sets `ENGINEOS_TERMINAL_SESSION_CMD='tmux new -A -s engineos'`, `engineos terminal` runs that command under `zsh -lc` inside the selected graphical terminal, and the Runtime `engineos` user inherits the checked-in `.zshrc`/`.tmux.conf` from `/etc/skel`.
- Runtime graphical client launch is now pinned to the shell-owned Wayland display: `engineos-shell` exports Wayland session hints and unsets `DISPLAY` for spawned terminal/engine clients, `engineos terminal` requires `WAYLAND_DISPLAY` by default and no longer falls back to `xterm`, and `engineos-runtime.service` sets `XDG_SESSION_TYPE=wayland` plus `ENGINEOS_TERMINAL_REQUIRE_WAYLAND=true`. VM renderer limitations still apply; hardware acceleration must be proven on the AMD target.
- `engineos vm boot` now supports `--audio hda`, which adds a QEMU ICH9 HDA controller and duplex codec. A Runtime VM booted with that option exposes `HDA Intel` in `/proc/asound/cards`, `aplay -l` lists `Generic Analog`, WirePlumber reports `Built-in Audio Analog Stereo` sink/source, and `speaker-test -D default` reaches the guest audio path. QEMU is using a discard backend, so this proves guest audio plumbing but not audible host output.
- EngineRuntime includes the Quake audio default path through `/etc/engineos/quake.conf` with `ENGINEOS_QUAKE_SDL_AUDIODRIVER=pulseaudio`.
- EngineRuntime TTY shell launch passes default terminal and engine commands into `engineos-shell`, so `Alt+Return` and `Alt+G` have configured actions.
- EngineDev and EngineRuntime live users get input/audio/video/render access, PipeWire user units are globally enabled, and live setup repairs groups and udev state at boot.
- In the booted EngineDev guest, `dev` can read `/dev/input/event*` and `/dev/input/mouse0`, PipeWire/Pulse reports active through `pactl info`, and `engineos run quake --smoke` finds `/usr/bin/quakespasm`.
- QuakeSpasm is packaged and included with the Quake template package. Real user-provided Quake assets have been proven in a hot-patched EngineDev VM under Xvfb.
- The wlroots shell compiles on the Arch builder against `wlroots0.19` and has basic scene, input, focus, terminal launch, engine launch, and emergency release paths in source.
- Local focused tests cover CLI smoke paths, package/repo scaffolding, assets, logs, proof dry-runs, boot validation fixtures, shell actions, engine-runner environment forwarding, input traces, output validation, and render capture fallback.

## Not Yet Proven

- Interactive Quake keyboard/mouse/audio in a live Runtime console session with user assets.
- Persistent Quake asset mounting is not implemented yet; the current Hyper-V VM still loses manually copied assets on reboot because it is a live ISO, even though the writable overlay is now large enough for session-local copies.
- Real audible output is not proven in the current Hyper-V/basic QEMU path. Hyper-V is not presenting a sound device to Linux, and the QEMU HDA proof uses an audio discard backend; prove audible output on hardware or an audio-forwarding VM/RDP path.
- Real nested or TTY graphical shell session with visible output and frame capture.
- Real Runtime `--bootstrap all` launch with visible terminal/tmux and engine surfaces.
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

Runtime interactive retest:

```bash
cd /srv/engineos
./tools/engineos/engineos vm boot engineruntime --display none --background --ssh-port 2223 --audio hda
sshpass -p engineos ssh -p 2223 engineos@127.0.0.1 'engineos proof booted-iso --runtime'
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
- `launch commands terminal=... engine=...`

## Resource Note

The builder was tuned from Windows Hyper-V and now validates with 6 vCPUs, 4 GiB swap, at least 8 GiB `/tmp`, OVMF, and no builder warnings. Earlier low-memory settings caused `pacstrap` kills, `mkinitcpio` `/tmp` failures, and SquashFS compression failures. The repo also works around constrained builders with persistent swap, disk-backed mkarchiso temp space, automatic `/tmp` tmpfs remounting, clean/archive ISO builds, and capped SquashFS compression.

For a real speed improvement, run elevated PowerShell on the Windows host. On this 40 GiB / 12 logical CPU host, the helper will choose generous defaults around 8 GiB startup RAM, 16 GiB maximum RAM, and 6 vCPUs:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\scripts\tune_builder_vm_hyperv.ps1 -Execute -Restart
```
