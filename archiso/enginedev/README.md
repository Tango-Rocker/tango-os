# EngineDev Archiso Profile

This profile is the first bootable development image. It is intentionally broad: compilers, build tools, Mesa, Wayland, wlroots, PipeWire, SDL2, and local EngineOS packages are included so the test VM can validate the OS workflow before a smaller runtime image exists.

Dry-run:

```bash
../../tools/engineos/eos-build iso enginedev --dry-run
```

Real build on the Arch builder VM:

```bash
../../tools/engineos/eos-proof build-lab
../../tools/engineos/eos-vm boot enginedev --dry-run
../../tools/engineos/eos-vm boot enginedev
```

Manual VMware or VirtualBox booting is also fine. After booting the ISO in the test VM:

```bash
eos-proof booted-iso --vm
```

The profile creates a passwordless `dev` user in the `wheel` group, enables NetworkManager and sshd, includes the per-user Quake service, level-agent, pinned dungeon generator, and Quake template packages for installed smoke tests, and runs `engineos-live-setup.service` once at boot to prepare `/var/log/engineos`.
