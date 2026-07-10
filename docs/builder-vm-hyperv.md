# Hyper-V Arch Builder VM

> **Legacy image-lab reference:** This builder is not used for routine
> EngineOS development or acceptance. Use the live bare-metal package workflow
> in [../README.md](../README.md) unless the image lab is explicitly re-enabled.

This is the practical path for making `dev@<builder-vm-ip>` real on a Windows
host with Hyper-V.

Use the official Arch Linux installer ISO from
<https://archlinux.org/download/>. The Arch downloads page notes that the image
is intended for new installs and can be mounted as an ISO file.

## Create the VM

Run PowerShell as Administrator from the repo root.

Check available switches:

```powershell
Get-VMSwitch | Select-Object Name,SwitchType
```

Dry-run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\scripts\create_builder_vm_hyperv.ps1 -IsoPath "C:\path\to\archlinux-x86_64.iso"
```

Create and start:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\scripts\create_builder_vm_hyperv.ps1 -IsoPath "C:\path\to\archlinux-x86_64.iso" -Execute -Start
```

Defaults:

- VM name: `EngineOS-Builder`
- memory: 8 GiB
- CPUs: 4
- disk: 160 GiB dynamic VHDX
- switch: `Default Switch`
- Secure Boot: off

If `Default Switch` is not visible, create or choose a Hyper-V switch and pass
`-SwitchName "<name>"`. An external switch is easiest when you want the builder
to get a LAN address.

If an existing builder was created with too little memory, tune it from an
elevated PowerShell. The helper is dry-run by default and chooses generous
settings from the host resources:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\scripts\tune_builder_vm_hyperv.ps1
powershell -ExecutionPolicy Bypass -File .\tools\scripts\tune_builder_vm_hyperv.ps1 -Execute -Restart
```

For a 40 GiB / 12 logical CPU host, the helper targets 4 GiB minimum RAM, 8 GiB
startup RAM, 16 GiB maximum RAM, and 6 vCPUs. Low-memory builders should also
keep swap enabled inside Arch. The current project builder uses a persistent
4 GiB `/swapfile`; `eos-build iso` uses `/srv/engineos/tmp`, remounts
`/tmp` to 8 GiB when it is tmpfs, and limits SquashFS compression parallelism
for reliable low-memory builds.

Example external switch creation:

```powershell
Get-NetAdapter
New-VMSwitch -Name "EngineOS External" -NetAdapterName "<adapter name>" -AllowManagementOS $true
```

## Install Arch

Open the VM console in Hyper-V Manager. In the Arch live environment:

```bash
timedatectl set-ntp true
archinstall
```

Recommended install choices for this builder:

- disk layout: wipe the VM disk
- filesystem: ext4 or btrfs
- bootloader: systemd-boot
- profile: minimal
- network: NetworkManager
- additional packages: `openssh sudo git rsync vim`
- user: create `dev`, make it a sudo user

After install, reboot into the installed system and log in as `dev`.

## Make SSH Reachable

Inside the installed Arch VM:

```bash
sudo systemctl enable --now NetworkManager
sudo systemctl enable --now sshd
ip -4 addr
```

If `dev` cannot use sudo yet:

```bash
su -
EDITOR=vim visudo
```

Enable the wheel line:

```text
%wheel ALL=(ALL:ALL) ALL
```

Then:

```bash
usermod -aG wheel dev
passwd dev
```

From the Windows host, prove reachability:

```powershell
ssh dev@<builder-vm-ip> "uname -a && cat /etc/arch-release"
```

From WSL or another shell with `rsync`, run the EngineOS handoff dry-run:

```bash
./tools/engineos/eos-builder handoff --dry-run --host dev@<builder-vm-ip> --run-proof
```

When that looks right, start the real PoC 0 builder proof:

```bash
./tools/engineos/eos-builder handoff --host dev@<builder-vm-ip> --run-proof
```

The repo will land at `/srv/engineos` inside the builder. The real validation
requires that exact path because the archiso profiles use
`file:///srv/engineos/repo/$arch`.
