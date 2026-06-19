# EngineRuntime Archiso Profile

This profile is the runtime appliance image. The Arch builder VM can build it with `mkarchiso`; runtime autostart and interactive Quake input/audio still need live Runtime or bare-metal proof.

Hyper-V basic console testing is useful for boot, recovery, service logs, input visibility, and Quake smoke checks. It is not a real audio proof path for Linux guests in this setup: the guest sees no ALSA sound card and PipeWire/Pulse falls back to Dummy Output. Treat audio as proven only on bare metal or another VM/RDP path that exposes an audio device.

Dry-run:

```bash
../../tools/engineos/eos-build iso engineruntime --dry-run
```

Real build and VM boot on the Arch builder VM:

```bash
../../tools/engineos/eos-build iso engineruntime --fast --clean --archive-existing
../../tools/engineos/eos-vm boot engineruntime --dry-run
../../tools/engineos/eos-vm boot engineruntime --display none --background --ssh-port 2223
```

After booting a runtime ISO:

```bash
ssh -p 2223 engineos@127.0.0.1   # password: engineos
eos-proof booted-iso --runtime
```

The profile creates an `engineos` user in the `wheel` group with the validation password `engineos`, enables NetworkManager and SSH for VM proofs, runs `engineos-live-setup.service` once at boot before runtime services, starts `engineos-engine-runner.service`, enables `engineos-runtime.service` for guarded shell autostart on `tty1`, enables `getty@tty2.service` as the recovery TTY, and installs `engineos-recovery-help` for the recovery login path.

Runtime autostart can be disabled with the kernel command-line flag:

```text
engineos.noautostart
```

Runtime defaults live in `/etc/engineos/runtime.conf`.

From the recovery TTY, start with:

```bash
engineos-recovery-help
eos-logs runtime --last 200
eos-crash-bundle
```
