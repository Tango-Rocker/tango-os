# Cube Pane-Bounds PoC

Date: 2026-07-01

Context: bare-metal EngineDev installation. ISO builds remain paused.

## Goal

Use the lightweight cube app to validate shell-owned panel/pane bounds before
returning to Quake.

## Changes

- `eos-app launch cube` now writes tmux-derived `launch-bounds/cube.env`.
- `engineos-shell` now reads per-role launch-bounds files instead of only
  `engine.env`, so cube and engine can both use the same pane geometry path.
- Cube launches disable SDL/libdecor to avoid the GTK/glycin decoration abort.
- `engineos-cube` logs startup, resize, first-frame, and final
  `window_size`/`drawable_size` values to `cube.log`.

## Validation

Source validation:

```bash
env -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_SHELL_BOOTSTRAP -u ENGINEOS_SHELL_STARTUP ENGINEOS_ROOT=$PWD ./tools/scripts/validate_shell.sh
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=$PWD ./tools/eos/test/test_runner.sh app
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=$PWD ./tools/engineos/eos-build shell
git diff --check
```

Package/deploy path:

```bash
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=$PWD ./tools/engineos/eos-build repo --package engineos-shell
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=$PWD ./tools/engineos/eos-build repo --package engineos-cube
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=$PWD ./tools/engineos/eos-build repo --package engineos-tools
sudo -n pacman -U --noconfirm repo/x86_64/engineos-cube-0.1.0-2-x86_64.pkg.tar.zst repo/x86_64/engineos-shell-0.1.0-4-x86_64.pkg.tar.zst repo/x86_64/engineos-tools-0.1.0-1-any.pkg.tar.zst
sudo -n systemctl restart engineos-dev-shell.service
```

Live proof from a temporary split tmux pane:

```text
app layout app=cube mode=pane source=tmux bounds=0 34 240 32 240 66
layout view role=cube layout=tmux-pane x=0 y=556 size=1920x524 fullscreen=false
first_frame window_size=1920x524 drawable_size=1920x524
frames=228
result=smoke-ok
```

Crash check:

```bash
coredumpctl list --since '2026-07-01 22:50:02' --no-pager
```

Result:

```text
No coredumps found.
```

## Quake Follow-Up Probe

A short Quake probe through the same temporary split-pane path showed the shell
side is now applying engine pane bounds:

```text
app layout app=quake mode=pane source=tmux bounds=0 34 132 32 240 66
layout view role=engine layout=tmux-pane x=0 y=556 size=1056x524 fullscreen=false
launchpad active slot=engine mode=game capture=game reason=layout-request-mapped
view unmapped role=engine
view destroyed role=engine
No coredumps found.
```

QuakeSpasm did not flush its `Video mode ...` line before the timed probe was
terminated. The remaining Quake validation is client-side: use a longer clean
shutdown or add explicit client-size instrumentation so the Quake log can be
compared against the shell layout the same way `cube.log` was compared.
