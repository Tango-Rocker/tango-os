---
name: wlroots-compositor
description: Use when changing engineos-shell, wlroots setup, Wayland protocol handling, launchpad slots, surface lifecycle, output layout, focus, or shell-owned app launch.
---

# wlroots Compositor Skill

The compositor is the desktop shell. Keep it observable, recoverable, and small.

## Invariants

- Headless/nested confidence comes before direct TTY/KMS changes.
- Runtime TTY/KMS proof belongs on the target AMD hardware path.
- `engineos-shell` owns the Wayland socket, shell launchpad state, input focus,
  output layout, and final client launch environment.
- Process supervision details stay in the app/engine wrappers unless shell UX
  state requires tracking a child process.
- Keep `/run/user/1000/engineos/shell-state.json` JSON-readable.

## Checks

```bash
./tools/engineos/eos-test compositor --headless
./tools/engineos/eos-test shell-actions
./tools/engineos/eos-test shell
./tools/engineos/eos-preflight repo --package engineos-shell
./tools/engineos/eos-logs shell --last 200
```

For Runtime launchpad behavior:

```bash
./tools/engineos/eos-app manifest validate
./tools/engineos/eos-test shell-actions
```

## Files

```text
shell/
packages/engineos-shell/PKGBUILD
packages/engineos-config/files/etc/engineos/apps.toml
tools/scripts/shell_runner.sh
tools/scripts/app.sh
tools/scripts/proof.sh
artifacts/logs/shell.log
```
