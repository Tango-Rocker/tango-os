# EngineOS Execution Plan: Windows Host + Arch VM Build Lab

**Status:** Draft v0.1  
**Date:** 2026-06-10  
**Project:** EngineDev OS first, game-runtime appliance later  
**Host assumption:** Windows 10/11 desktop or laptop  
**Target hardware later:** AMD GPU + Mesa on bare metal

This document adapts the EngineOS plan to a Windows-hosted VM workflow. The core idea is to build the whole project from Windows without polluting Windows itself. Windows hosts the lab. The Arch VM is the forge. The generated ISO is the artifact. Bare-metal AMD testing comes later when graphics correctness matters.

---

## 1. Short version of the architecture

```text
Windows host
  -> Builder VM: Arch Linux installed on ext4
       -> owns source repo
       -> builds packages
       -> builds archiso images with mkarchiso
       -> runs Codex / tmux / editor / tests
       -> runs headless or nested compositor tests

  -> Test VM: boots generated EngineDev ISO
       -> validates ISO boot
       -> validates TTY workflow
       -> validates engineos doctor
       -> validates package installation
       -> validates headless/nested shell where possible

Later:
  -> Bare-metal AMD machine or bootable USB test
       -> validates real DRM/KMS
       -> validates AMD Mesa behavior
       -> validates multi-monitor
       -> validates low-latency game mode
```

The VM is not the final graphics truth. It is the construction yard.

---

## 2. Important VM reality check

A virtual machine is excellent for:

```text
- building Arch packages
- building mkarchiso images
- testing systemd units
- testing TTY boot
- testing repo layout
- testing Codex/agent workflows
- testing QuakeSpasm compilation
- testing engine-runner process control
- testing wlroots in headless or nested mode
- testing logs, crash bundles, and CLI commands
```

A virtual machine is not enough for final validation of:

```text
- real AMD DRM/KMS behavior
- direct TTY/KMS compositor ownership
- real multi-monitor timing
- low-latency game input
- VRR/HDR/fractional scaling
- GPU hangs or driver resets
- external game performance
```

We should not fight GPU passthrough in Sprint 0. Hyper-V Discrete Device Assignment can assign whole PCIe devices to VMs, including graphics devices, but it has Windows Server-oriented requirements, hardware compatibility constraints, MMIO configuration work, and security implications. Treat that as a later research spike, not as the build foundation.

Recommended first path:

```text
Build in VM.
Smoke-test in VM.
Graphics-truth-test on bare-metal AMD later.
```

---

## 3. VM platform recommendation

Default choice for this plan:

```text
Primary: VMware Workstation Pro on Windows
Fallback: VirtualBox
Special case: Hyper-V for build-only VMs, not early graphics work
```

### VMware Workstation Pro

Use this if available. It is usually the most convenient Windows-hosted Linux desktop VM path, and its virtual graphics stack is more useful for early nested compositor experiments than pure build-only virtualization. Still, the guest sees a virtual GPU, not your real AMD GPU.

Recommended use:

```text
- Builder VM
- Test VM
- optional nested graphical smoke tests
```

### VirtualBox

Good enough for:

```text
- Arch builder VM
- ISO creation
- TTY testing
- package testing
```

Lower confidence for:

```text
- accelerated Wayland/OpenGL compositor testing
- input latency testing
- anything close to final game behavior
```

### Hyper-V

Good enough for:

```text
- build-only VM
- command-line Arch environment
- ISO generation
```

Avoid for Sprint 0 graphics unless there is a strong reason. GPU passthrough through DDA is an advanced track.

---

## 4. VM resource profile

### Builder VM

```text
CPU:       6 to 12 vCPUs if available
RAM:       16 GB minimum, 24 to 32 GB preferred
Disk:      160 GB minimum, 250 GB preferred
Firmware: UEFI
Network:  NAT is fine; bridged is convenient for SSH
Graphics: 3D acceleration enabled if supported
Storage:  virtual NVMe/SATA, ext4 inside guest
```

Disk space should not be stingy. Arch package caches, ISO work directories, build trees, debug symbols, and engine assets will chew through storage like a small mechanical goat.

### Test VM

```text
CPU:       4 to 8 vCPUs
RAM:       8 to 16 GB
Disk:      40 to 80 GB
Firmware: UEFI
Boot:      generated EngineDev ISO
Network:  NAT
Graphics: 3D acceleration enabled if supported
```

---

## 5. Critical source-control rule

Keep the repo inside the Arch builder VM on a Linux filesystem.

Do this:

```text
/srv/engineos
/home/dev/src/engineos
```

Do not do this for primary builds:

```text
C:\Users\...\engineos mounted into Linux shared folder
/mnt/hgfs/engineos
/media/sf_engineos
```

Windows shared folders are useful for moving final ISO files. They are not the right place for source-of-truth builds because permissions, executable bits, symlinks, path case behavior, filesystem notifications, and performance can become little goblins with clipboards.

Recommended workflow:

```text
- Repo lives inside Arch VM.
- Edit through SSH from Windows if desired.
- Use VS Code Remote SSH, Neovim over SSH, or Ghostty/SSH.
- Export ISO artifacts to Windows via scp or a shared artifact-only folder.
```

---

## 6. Windows host setup

### 6.1 Required Windows tools

Install or prepare:

```text
- VM platform: VMware Workstation Pro, VirtualBox, or Hyper-V
- Git for Windows, optional but useful
- OpenSSH client, usually built into modern Windows
- VS Code + Remote SSH extension, optional
- A terminal: Windows Terminal recommended
- At least 250 GB free disk if possible
```

### 6.2 Windows PowerShell helpers

Find the builder VM IP later:

```powershell
ssh dev@<builder-vm-ip>
```

Copy ISO from builder VM to Windows:

```powershell
scp dev@<builder-vm-ip>:/srv/engineos/out/*.iso "$env:USERPROFILE\Downloads\"
```

Copy logs or crash bundles:

```powershell
scp -r dev@<builder-vm-ip>:/srv/engineos/artifacts/crash-bundles/latest "$env:USERPROFILE\Downloads\engineos-crash-bundle"
```

---

## 7. Builder VM installation plan

Use a minimal Arch install. The builder VM should be boring. Boring is good. Boring does not summon driver fog.

### 7.1 Create VM

VM settings:

```text
Name:       engineos-builder
OS type:    Linux / Arch Linux 64-bit if available
Firmware:   UEFI
CPU:        8 vCPU target
RAM:        16 GB minimum
Disk:       160 GB minimum
Network:    NAT or bridged
Graphics:   enable 3D acceleration if available
ISO:        official Arch Linux ISO
```

### 7.2 Install Arch

The quickest path is to use `archinstall` from the official Arch ISO if available. Manual install is also fine. Keep the system simple:

```text
Filesystem: ext4
Bootloader: systemd-boot or GRUB
Desktop:    none required for the builder
User:       dev
Hostname:   engineos-builder
Services:   NetworkManager, sshd
```

Suggested package set during or immediately after install:

```bash
sudo pacman -Syu
sudo pacman -S --needed \
  base-devel git archiso sudo openssh networkmanager \
  vim neovim tmux zsh bash-completion \
  python python-pip python-virtualenv \
  jq ripgrep fd just rsync unzip zip \
  cmake meson ninja clang lld gcc gdb lldb make pkgconf \
  mesa mesa-utils vulkan-tools vulkan-radeon libdrm \
  wayland wayland-protocols wlroots xorg-xwayland \
  libinput xorg-xinput xorg-xkbcomp \
  pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils \
  sdl2 openal freetype2 libpng libjpeg-turbo libogg libvorbis mpg123
```

Enable services:

```bash
sudo systemctl enable --now NetworkManager
sudo systemctl enable --now sshd
```

Add `dev` to sudo if not already done:

```bash
sudo EDITOR=vim visudo
```

Ensure this line exists:

```text
%wheel ALL=(ALL:ALL) ALL
```

Then:

```bash
sudo usermod -aG wheel dev
```

Log out and back in.

---

## 8. Initial directory layout inside builder VM

Create project space:

```bash
sudo mkdir -p /srv/engineos
sudo chown -R dev:dev /srv/engineos
cd /srv/engineos
```

Initial tree:

```text
/srv/engineos/
  README.md
  ROADMAP.md
  CURRENT_STATUS.md
  AGENTS.md
  LICENSES.md

  archiso/
    enginedev/
    engineruntime/

  packages/
    engineos-config/
    engineos-cli/
    engineos-shell/
    engineos-engine-runner/
    engineos-quake-template/
    engineos-agent-tools/

  shell/
  engine-runner/
  engines/
    quakespasm/
    vkquake/
    ioq3/

  tools/
    engineos/
    scripts/
    mcp/
    codex/

  docs/
  .agents/
    skills/
```

---

## 9. EngineOS build model

The build should have three layers:

```text
Layer 1: Source repo
  shell source
  engine-runner source
  tools
  docs
  archiso profiles
  package definitions

Layer 2: Local pacman repo
  engineos-config
  engineos-cli
  engineos-shell-git
  engineos-engine-runner-git
  engineos-quake-template-git
  engineos-agent-tools

Layer 3: Generated ISO
  enginedev ISO first
  engineruntime ISO later
```

Nothing important should be copied into the image by hand. It should come from:

```text
- official Arch packages
- local EngineOS packages
- archiso profile files
- documented first-boot scripts
```

---

## 10. Archiso profile plan

`mkarchiso` builds an ISO from a profile directory. EngineOS should use that directly.

Initial profile:

```text
archiso/enginedev/
  profiledef.sh
  packages.x86_64
  pacman.conf
  airootfs/
    etc/
      systemd/
      pacman.conf.d/
    usr/
      local/bin/
    opt/
      engineos/
```

Build command wrapper:

```bash
./tools/scripts/build_iso.sh enginedev
```

Underlying command:

```bash
sudo mkarchiso \
  -v \
  -w /srv/engineos/work/enginedev \
  -o /srv/engineos/out \
  /srv/engineos/archiso/enginedev
```

Expected output:

```text
/srv/engineos/out/EngineDevOS-YYYY.MM.DD-x86_64.iso
```

---

## 11. EngineDev OS package baseline

`archiso/enginedev/packages.x86_64` should start with:

```text
base
linux
linux-firmware
systemd
sudo
git
openssh
networkmanager
vim
neovim
tmux
zsh
bash-completion
base-devel
cmake
meson
ninja
clang
lld
gcc
gdb
lldb
make
pkgconf
python
python-pip
jq
ripgrep
fd
just
rsync
unzip
zip
mesa
mesa-utils
vulkan-radeon
vulkan-tools
libdrm
wayland
wayland-protocols
wlroots
xorg-xwayland
libinput
pipewire
pipewire-alsa
pipewire-pulse
wireplumber
alsa-utils
sdl2
openal
freetype2
libpng
libjpeg-turbo
libogg
libvorbis
mpg123
engineos-config
engineos-cli
engineos-agent-tools
```

Add `ghostty` only if it is straightforward from the selected Arch repository path. If it is not in the official repos in the builder environment, package it later rather than blocking Sprint 1.

---

## 12. `engineos` CLI plan

The CLI is the steering wheel for both humans and agents.

Initial commands:

```bash
engineos --help
engineos doctor
engineos doctor --vm
engineos build repo
engineos build iso enginedev
engineos package engineos-cli
engineos run quake
engineos run nested
engineos logs shell
engineos logs engine
engineos crash-bundle
engineos test
```

### 12.1 `engineos doctor --vm`

Must print:

```text
Host/virtualization:
  systemd-detect-virt result
  VM vendor if detectable

Kernel:
  uname -a

GPU:
  lspci display devices
  kernel driver
  OpenGL renderer if available
  Vulkan summary if available
  llvmpipe/softpipe warning if detected

Display:
  active session
  Wayland display if set
  DRM devices

Audio:
  pipewire status
  wireplumber status

Build tools:
  archiso version
  gcc/clang
  meson/ninja/cmake

EngineOS:
  git commit
  local package versions
  profile name
```

Sample implementation helpers:

```bash
systemd-detect-virt || true
uname -a
lspci -nnk | grep -A3 -E 'VGA|3D|Display' || true
glxinfo -B || true
vulkaninfo --summary || true
systemctl --user status pipewire wireplumber || true
pacman -Q archiso mesa wlroots wayland pipewire wireplumber || true
```

---

## 13. Agent workflow: Codex, AGENTS.md, SKILL.md, MCP

Codex should not have to guess how the strange machine works. The repo should teach it.

### 13.1 Required files

```text
AGENTS.md
CURRENT_STATUS.md
docs/agent-workflow.md
.agents/skills/archiso-build/SKILL.md
.agents/skills/crash-forensics/SKILL.md
.agents/skills/wlroots-compositor/SKILL.md
.agents/skills/quake-port/SKILL.md
.agents/skills/render-gl/SKILL.md
.agents/skills/input-routing/SKILL.md
```

### 13.2 AGENTS.md minimum content

```text
- project mission
- repo map
- approved commands
- dangerous commands
- build/test expectations
- package rules
- renderer rules
- wlroots rules
- Quake asset rules
- log locations
- crash bundle command
- how to update CURRENT_STATUS.md
```

### 13.3 Skill rule

Each skill must include:

```text
- when to use this skill
- commands to run
- files that matter
- known traps
- expected output
- recovery steps
```

### 13.4 MCP rule

Do not expose arbitrary shell first. MCP servers should wrap known `engineos` CLI commands.

First MCP servers:

```text
engineos-build-mcp
  engineos_build_repo()
  engineos_build_iso(profile)
  engineos_run_tests(scope)

engineos-logs-mcp
  engineos_get_logs(unit, lines)
  engineos_crash_bundle()
  engineos_doctor()

engineos-render-mcp
  engineos_capture_frame(target)
  engineos_compare_frame(test_name)
  engineos_list_outputs()
```

ROI rule:

```text
CLI first.
MCP wraps CLI later.
```

---

## 14. QuakeSpasm seed engine plan

Start with QuakeSpasm because it is OpenGL-oriented, SDL-friendly, and closer to the first engine goal than a Vulkan-first port.

Initial path:

```text
engines/quakespasm/
  upstream/
  patches/
  engineos/
    build.sh
    run.sh
    smoke-test.sh
    control-protocol.md
```

First changes:

```text
- build cleanly on EngineDev OS
- run as SDL2 app
- prefer Wayland when inside compositor
- output logs predictably
- add deterministic launch wrapper
- add asset manifest
- add engineos run quake
```

No commercial Quake assets should be included in the repo or ISO by default.

Asset manifest:

```toml
[[asset]]
name = "generated-test-map"
source = "generated"
license = "CC0"
redistributable = true
allowed_in_iso = true

[[asset]]
name = "id1/pak0.pak"
source = "user-provided"
license = "commercial"
redistributable = false
allowed_in_iso = false
```

---

## 15. wlroots compositor plan inside VM

The first shell must run nested or headless before it tries to own a real TTY/KMS session.

### 15.1 Development modes

```text
Mode A: headless
  WLR_BACKENDS=headless
  useful for CI/smoke tests
  no real display required

Mode B: nested Wayland/X11
  runs inside an existing compositor/session
  useful for visible dev iteration

Mode C: real TTY/KMS
  owns DRM/KMS through logind
  not first in VM
  real validation on bare-metal AMD later
```

### 15.2 First compositor acceptance

```text
- starts headless
- starts nested if graphical VM supports it
- accepts one xdg-shell client
- launches Ghostty or fallback terminal
- launches QuakeSpasm as client
- logs focus events
- exits cleanly
```

### 15.3 VM-friendly commands

```bash
engineos run shell --headless
engineos run shell --nested
engineos test compositor --headless
engineos logs shell --last 200
```

Do not block progress on fancy virtual GPU problems. If accelerated nested rendering is flaky, keep a headless compositor test path and push real graphics testing to the AMD machine.

---

## 16. Test VM plan

The test VM exists to boot generated ISOs, not to be the development environment.

Create VM:

```text
Name:       engineos-test
Firmware:   UEFI
CPU:        4 to 8 vCPU
RAM:        8 to 16 GB
Disk:       40 to 80 GB
Boot ISO:   /srv/engineos/out/EngineDevOS-*.iso
```

Validation sequence:

```text
1. Boot ISO.
2. Confirm TTY login.
3. Run engineos doctor --vm.
4. Confirm NetworkManager.
5. Confirm PipeWire/WirePlumber package presence.
6. Confirm local EngineOS packages installed.
7. Run headless compositor smoke test.
8. Run Quake build or packaged Quake smoke test.
9. Export logs if failure.
```

Test VM commands:

```bash
engineos doctor --vm
engineos test
engineos test compositor --headless
engineos run quake --smoke
engineos crash-bundle
```

---

## 17. Bare-metal AMD checkpoint

Do this after the VM lab can build and boot an ISO.

Bare-metal validation machine:

```text
GPU:       AMDGPU-supported card
Monitors:  1 first, then 2
Boot:      USB generated from EngineDev ISO
Mode:      TTY-first
```

Validation sequence:

```text
1. Boot EngineDev ISO from USB.
2. Run engineos doctor.
3. Confirm Mesa renderer is real AMD, not llvmpipe.
4. Confirm Vulkan sees AMD device.
5. Start engineos-shell from TTY.
6. Launch terminal client.
7. Launch QuakeSpasm client.
8. Test input capture.
9. Test dual-monitor static layout.
10. Collect crash bundle after every failure.
```

Bare-metal is where DRM/KMS truth lives. The VM is only the rehearsal stage.

---

## 18. ROI execution roadmap

### Sprint 0: Windows + Builder VM foundation

Deliverables:

```text
- VM platform selected
- Arch builder VM installed
- SSH into builder VM from Windows
- /srv/engineos created
- base build packages installed
- engineos CLI stub created
- first snapshot of builder VM taken
```

Acceptance:

```bash
ssh dev@<builder-vm-ip>
cd /srv/engineos
engineos --help
engineos doctor --vm
```

---

### Sprint 1: Repo skeleton and agent rails

Deliverables:

```text
- repo tree created
- README.md
- ROADMAP.md
- CURRENT_STATUS.md
- AGENTS.md
- docs/architecture.md
- docs/agent-workflow.md
- docs/asset-policy.md
- .agents/skills/archiso-build/SKILL.md
- .agents/skills/crash-forensics/SKILL.md
- tools/engineos CLI skeleton
```

Acceptance:

```bash
engineos --help
engineos doctor --mock
engineos build iso --dry-run
engineos build repo --dry-run
```

---

### Sprint 2: Bootable EngineDev ISO

Deliverables:

```text
- archiso/enginedev profile
- packages.x86_64 baseline
- pacman.conf
- airootfs defaults
- dev user setup
- NetworkManager enabled
- engineos-config package skeleton
- engineos-cli package skeleton
```

Acceptance:

```bash
engineos build iso enginedev
ls -lh out/*.iso
```

Then boot in test VM and run:

```bash
engineos doctor --vm
```

---

### Sprint 3: Local pacman repo

Deliverables:

```text
- package build scripts
- local repo-add flow
- engineos.db generated
- archiso consumes local repo
```

Acceptance:

```bash
engineos build repo
pacman -Sl engineos
engineos build iso enginedev
```

---

### Sprint 4: QuakeSpasm first engine loop

Deliverables:

```text
- QuakeSpasm source/fork path
- build wrapper
- run wrapper
- asset manifest
- no commercial assets in image
- engineos run quake
```

Acceptance:

```bash
engineos run quake --smoke
engineos logs engine --last 200
```

---

### Sprint 5: Headless/nested wlroots shell

Deliverables:

```text
- engineos-shell source skeleton
- wlroots init
- headless backend smoke test
- nested backend attempt
- basic logging
- surface placeholder
```

Acceptance:

```bash
engineos test compositor --headless
engineos run shell --headless
engineos logs shell --last 200
```

Optional if VM graphics supports it:

```bash
engineos run shell --nested
```

---

### Sprint 6: Terminal and game as clients

Deliverables:

```text
- launch terminal client
- Ghostty if packaged, fallback terminal otherwise
- launch QuakeSpasm client
- basic focus switching
- shell logs child lifecycle
```

Acceptance:

```bash
engineos run shell --nested
# inside shell: launch terminal and quake
engineos crash-bundle
```

---

### Sprint 7: First 3D cockpit

Deliverables:

```text
- surfaces rendered as simple panels
- command palette placeholder
- terminal panel
- game panel
- frame capture command
```

Acceptance:

```bash
engineos capture frame --target shell
engineos test render --smoke
```

---

### Sprint 8: Engine runner protocol

Deliverables:

```text
- engineos-engine-runner
- Unix domain socket
- engine.status
- engine.launch
- engine.quit
- engine.restart
- stdout/stderr log capture
```

Acceptance:

```bash
engineos engine status
engineos engine launch quake
engineos engine restart
engineos logs engine --last 200
```

---

### Sprint 9: Input capture and recovery

Deliverables:

```text
- shell focus mode
- terminal focus mode
- game focus mode
- game capture toggle
- emergency release
- input record/replay skeleton
```

Acceptance:

```bash
engineos test input
engineos record input traces/focus.json
engineos replay input traces/focus.json
```

---

### Sprint 10: Bare-metal AMD pass

Deliverables:

```text
- USB boot path documented
- engineos doctor validates AMD GPU
- real TTY/KMS shell attempt
- single-monitor success
- dual-monitor static config smoke test
```

Acceptance:

```bash
engineos doctor
engineos run shell --tty
engineos test outputs --single
engineos test outputs --dual-static
engineos crash-bundle
```

---

### Sprint 11: Runtime appliance profile

Deliverables:

```text
- archiso/engineruntime profile
- smaller package set
- autostart shell
- autostart selected game
- recovery TTY remains
```

Acceptance:

```bash
engineos build iso engineruntime
# boot in test VM first
# then boot bare-metal AMD
```

---

## 19. Immediate command checklist

Inside the Arch builder VM:

```bash
sudo pacman -Syu
sudo pacman -S --needed git archiso base-devel python jq ripgrep fd just cmake meson ninja clang lld gcc gdb lldb
sudo mkdir -p /srv/engineos
sudo chown -R "$USER:$USER" /srv/engineos
cd /srv/engineos
```

Create first files:

```bash
touch README.md ROADMAP.md CURRENT_STATUS.md AGENTS.md LICENSES.md
mkdir -p archiso/enginedev archiso/engineruntime
mkdir -p packages/{engineos-config,engineos-cli,engineos-shell,engineos-engine-runner,engineos-quake-template,engineos-agent-tools}
mkdir -p shell/src engine-runner/src engines/{quakespasm,vkquake,ioq3}
mkdir -p tools/{engineos,scripts,mcp,codex}
mkdir -p docs
mkdir -p .agents/skills/{archiso-build,crash-forensics,wlroots-compositor,quake-port,render-gl,input-routing}
```

Create first CLI stub:

```bash
cat > tools/engineos/engineos <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-help}"
shift || true

case "$cmd" in
  help|--help|-h)
    cat <<'HELP'
engineos commands:
  doctor [--vm]
  build repo
  build iso <enginedev|engineruntime>
  run quake
  run shell --headless|--nested|--tty
  logs shell|engine
  crash-bundle
  test [scope]
HELP
    ;;
  doctor)
    echo "EngineOS doctor"
    echo "virt: $(systemd-detect-virt || true)"
    echo "kernel: $(uname -a)"
    echo "archiso: $(pacman -Q archiso 2>/dev/null || true)"
    echo "mesa: $(pacman -Q mesa 2>/dev/null || true)"
    echo "wlroots: $(pacman -Q wlroots 2>/dev/null || true)"
    lspci -nnk | grep -A3 -E 'VGA|3D|Display' || true
    ;;
  *)
    echo "engineos: unknown command: $cmd" >&2
    exit 2
    ;;
esac
EOS
chmod +x tools/engineos/engineos
sudo ln -sf /srv/engineos/tools/engineos/engineos /usr/local/bin/engineos
```

Run:

```bash
engineos doctor --vm
```

---

## 20. Do-not-do-yet list

Do not spend early time on:

```text
- GPU passthrough
- Hyper-V DDA
- Vulkan rewrite
- direct-KMS engine mode
- embedded Ghostty renderer
- native hot-loaded game modules
- Steam/Proton support
- NVIDIA
- HDR
- VRR
- fractional scaling
- immutable OS
```

The early work is boring on purpose. We need foundations, logs, repeatable builds, and a VM lab before the 3D shell starts wearing armor.

---

## 21. Source references checked

- Arch `mkarchiso` manual: https://man.archlinux.org/man/mkarchiso.1.en
- Wayland architecture: https://wayland.freedesktop.org/architecture.html
- wlroots project README: https://github.com/swaywm/wlroots
- Ghostty project README: https://github.com/ghostty-org/ghostty
- QuakeSpasm project README: https://github.com/sezero/quakespasm
- OpenAI Codex CLI docs: https://developers.openai.com/codex/cli
- Microsoft Hyper-V DDA graphics device docs: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/deploy/deploying-graphics-devices-using-dda

---

## 22. Final execution principle

The first real win is not a 3D desktop. The first real win is this:

```text
Windows host
  -> Arch builder VM
       -> engineos doctor works
       -> mkarchiso builds EngineDev ISO
  -> Test VM
       -> generated ISO boots
       -> TTY works
       -> logs are collectible
```

Once that exists, the project becomes tractable. The lab is lit. Then we start wiring the cockpit.
