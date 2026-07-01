# Quake Cursor Capture Session

Date: 2026-07-01 UTC

This archive records the bare-metal EngineDev follow-up that fixed Quake mouse
capture under the shell-owned Wayland compositor path.

## Outcome

- `engineos-shell` now advertises `zwp_relative_pointer_manager_v1` through
  wlroots' relative-pointer manager.
- `engineos-shell` now advertises `zwp_pointer_constraints_v1` through wlroots'
  pointer-constraints manager.
- Game capture still hides the cursor and confines absolute pointer coordinates
  to the focused engine view.
- Game capture now also emits relative pointer deltas, so Quake mouselook can
  continue after the hidden cursor reaches a window edge.
- Pointer constraints are activated only when the mapped engine view owns game
  capture, and are released on capture exit, focus changes, engine unmap, engine
  destroy, and shell shutdown.
- Quake remained launched through `eos-app launch quake`; no ISO was built.

## Changed Files

- `shell/src/engineos-shell.c`
- `shell/meson.build`
- `shell/README.md`
- `tools/scripts/validate_shell.sh`
- `CURRENT_STATUS.md`

## Validation

Focused checks passed:

```bash
env -u ENGINEOS_ROOT -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_EOS_DIR -u ENGINEOS_LOG_DIR -u ENGINEOS_STATE_DIR -u ENGINEOS_SHELL_BOOTSTRAP -u ENGINEOS_TERMINAL_SESSION_CMD -u ENGINEOS_TERMINAL_REQUIRE_WAYLAND -u WLR_BACKENDS ./tools/engineos/eos-build shell
env -u ENGINEOS_ROOT -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_EOS_DIR -u ENGINEOS_LOG_DIR -u ENGINEOS_STATE_DIR -u ENGINEOS_SHELL_BOOTSTRAP -u ENGINEOS_TERMINAL_SESSION_CMD -u ENGINEOS_TERMINAL_REQUIRE_WAYLAND -u WLR_BACKENDS ./tools/engineos/eos-test shell
env -u ENGINEOS_ROOT -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_EOS_DIR -u ENGINEOS_LOG_DIR -u ENGINEOS_STATE_DIR -u ENGINEOS_SHELL_BOOTSTRAP -u ENGINEOS_TERMINAL_SESSION_CMD -u ENGINEOS_TERMINAL_REQUIRE_WAYLAND -u WLR_BACKENDS ./tools/engineos/eos-test input
git diff --check -- shell/src/engineos-shell.c shell/meson.build tools/scripts/validate_shell.sh shell/README.md CURRENT_STATUS.md
```

The local package was rebuilt and reinstalled:

```bash
env -u ENGINEOS_ROOT -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_EOS_DIR -u ENGINEOS_LOG_DIR -u ENGINEOS_STATE_DIR -u ENGINEOS_SHELL_BOOTSTRAP -u ENGINEOS_TERMINAL_SESSION_CMD -u ENGINEOS_TERMINAL_REQUIRE_WAYLAND -u WLR_BACKENDS ./tools/engineos/eos-build repo --package engineos-shell
sudo -n pacman -U --noconfirm /home/dev/Tang-OS/repo/x86_64/engineos-shell-0.1.0-4-x86_64.pkg.tar.zst
sudo -n systemctl restart engineos-dev-shell.service
eos-app launch quake
```

## Runtime Evidence

Final shell state showed:

```text
active_slot=engine
input.capture=true
cursor.locked=true
cursor.hidden=true
engine.layout=tmux-pane
```

`/var/log/engineos/shell.log` showed relative deltas continuing while the
surface coordinate was clamped at the edge:

```text
pointer focus role=engine sx=0.0 sy=759.2 reason=motion
relative pointer motion role=engine dx=-28.00 dy=0.00 reason=motion
```

`coredumpctl list engineos-shell --since '2026-07-01 22:18:45' --no-pager`
reported no coredumps.

## Notes

- Before this compositor change, QuakeSpasm logged
  `WARNING: SDL_SetRelativeMouseMode(SDL_TRUE) failed.` because the compositor
  did not advertise the required Wayland protocols.
- Recovery bindings remain `Alt+C`, `Alt+F1/F2`, and
  `Ctrl+Alt+Backspace`.
