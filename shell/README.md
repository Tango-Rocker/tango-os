# EngineOS Shell

This directory holds the first wlroots-based shell bootstrap.

Initial implementation order:

1. headless backend smoke test
2. nested Wayland or X11 backend
3. direct TTY/KMS path on bare-metal AMD

Expected CLI entry points:

```bash
engineos run shell --headless
engineos run shell --nested
engineos validate shell
engineos test compositor --headless
engineos logs shell --last 200
```

Current state:

- `shell/src/engineos-shell.c` creates a Wayland display, starts a wlroots backend, creates a scene graph and xdg-shell global, adds mapped toplevels to the scene, sends scene frame-done notifications, forwards keyboard input to the focused toplevel, logs toplevel lifecycle and output/input discovery, logs selected connector/mode/refresh/backend evidence for TTY/KMS proof, tracks pointer devices through a wlroots cursor, forwards pointer motion/button/axis/frame events to clients when a toplevel is targeted, handles default/client cursor images, exposes `WAYLAND_DISPLAY`, and can exit via a smoke timer.
- Keyboard bindings in the real shell path: `Alt+Escape` exits, `Alt+Tab` cycles mapped toplevels, `Alt+Return` launches the configured terminal command, `Alt+G` launches the configured engine command, `Alt+F1` switches to shell mode, `Alt+F2` switches to terminal mode, `Alt+F3` switches to game mode, `Alt+C` toggles game capture, and `Ctrl+Alt+Backspace` performs emergency release.
- Toplevels are classified as `terminal`, `engine`, or `unknown` from app id/title hints. Focus, map, unmap, destroy, and layout logs include the active role.
- Input state is logged as `shell`, `terminal`, or `game` mode with a `game` or `none` capture flag. Shell mode clears keyboard focus and swallows non-shell keys; terminal and game modes forward keyboard input to the focused matching surface.
- Pointer state is currently source-level only: pointer devices update seat capabilities, the wlroots cursor is constrained to the output layout, output scales load an XCursor theme, client cursor image requests are honored only for the pointer-focused client, scene hit-testing updates pointer focus, button presses can click-focus terminal/engine toplevels, and pointer events are logged with input mode/capture/focus/cursor context. Cursor policy and click-to-focus still need compile and nested/TTY runtime proof before being trusted as MVP behavior; gamepad routing remains later work.
- `engineos run shell --headless` prefers an installed `engineos-shell --headless` binary and falls back to an explicit headless smoke log.
- `engineos run shell --nested` prefers an installed `engineos-shell --nested --startup 'engineos terminal' --terminal 'engineos terminal' --engine 'engineos engine launch quake --smoke'` binary path and falls back to an explicit nested smoke log.
- `engineos run shell --tty` is the Runtime graphical entry point; with the real binary it passes `--bootstrap all` by default so the shell starts both the terminal and engine commands after the Wayland socket is ready.
- `engineos terminal` launches a Wayland-native terminal (`foot`, then other Wayland-capable fallbacks) and requires `WAYLAND_DISPLAY` by default, so graphical clients stay owned by the EngineOS shell instead of falling back to X11 or a raw TTY path. Runtime sets `ENGINEOS_TERMINAL_SESSION_CMD='tmux new -A -s engineos'`, so the bootstrapped terminal opens directly into the persistent tmux session under zsh.
- `engineos-shell` exports Wayland session hints for spawned terminal/engine clients and unsets `DISPLAY` when its Wayland socket is active. This enforces shell ownership of app surfaces; it does not by itself prove hardware GL acceleration in VMs that expose only llvmpipe/pixman.
- `engineos run shell --tty` fails unless `ENGINEOS_ALLOW_TTY_STUB=true` because real TTY/KMS work belongs to the hardware phase.
- `engineos validate shell` checks shell source inputs, build dry-run, fallback logs, TTY fail-closed behavior, explicit TTY stub mode, and fake installed-shell argument pass-through.
- `engineos outputs list` records DRM connector status and preferred modes before hardware shell attempts; `engineos outputs validate --single` and `--dual-static` provide quick connector-count checks.
- `ENGINEOS_SHELL_SMOKE=true engineos run shell --headless` asks the real binary to start and self-terminate when the binary is installed.
- `ENGINEOS_SHELL_STARTUP='foot' engineos run shell --nested` overrides the nested startup command.
- `ENGINEOS_SHELL_BOOTSTRAP=all engineos run shell --tty` selects startup launch mode: `none`, `terminal`, `engine`, or `all`.
- `ENGINEOS_TERMINAL_CMD='foot'` overrides the terminal launch command.
- `ENGINEOS_TERMINAL_SESSION_CMD='tmux new -A -s engineos'` runs a shell command inside the selected terminal.
- `ENGINEOS_ENGINE_CMD='engineos engine launch quake --smoke'` overrides the engine launch command.

Build on the Arch builder VM:

```bash
./tools/engineos/engineos package engineos-shell
./tools/engineos/engineos build shell
./tools/engineos/engineos test compositor --headless
```
