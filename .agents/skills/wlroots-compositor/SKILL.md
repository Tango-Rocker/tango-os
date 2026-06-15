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
./tools/engineos/engineos build shell --dry-run
./tools/engineos/engineos test compositor --headless
./tools/engineos/engineos test shell-actions
./tools/engineos/engineos test shell
./tools/engineos/engineos logs shell --last 200
```

For Runtime launchpad behavior:

```bash
./tools/engineos/engineos app manifest validate
./tools/engineos/engineos proof launchpad --runtime --dry-run
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
