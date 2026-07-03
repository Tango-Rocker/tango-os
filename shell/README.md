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
engineos proof shell-launch --dry-run
```

Current state:

- `shell/src/engineos-shell.c` creates a Wayland display, starts a wlroots backend, creates a scene graph and xdg-shell global, adds mapped toplevels to the scene, sends scene frame-done notifications, forwards keyboard input to the focused toplevel, logs toplevel lifecycle and output/input discovery, logs selected connector/mode/refresh/backend evidence for TTY/KMS proof, tracks pointer devices through a wlroots cursor, forwards pointer motion/button/axis/frame events to clients when a toplevel is targeted, handles default/client cursor images, exposes `WAYLAND_DISPLAY`, and can exit via a smoke timer.
- Keyboard bindings in the real shell path: `Alt+Escape` exits, `Alt+Tab` cycles mapped launchpad slots, `Alt+1` activates/launches terminal, `Alt+2` activates/launches the cube app, `Alt+3` activates/launches Quake, `Alt+Return` launches the configured terminal command, `Alt+G` launches the configured engine command, `Alt+F1` switches to shell mode, `Alt+F2` switches to terminal mode, `Alt+F3` switches to game mode, `Alt+C` toggles game capture, and `Ctrl+Alt+Backspace` performs emergency release. When an image preview is visible, unmodified `F3` closes only that shell-owned preview surface.
- Toplevels are classified as `terminal`, `cube`, `engine`, or `unknown` from app id/title hints. Known launchpad slots are output-sized by default, inactive non-pane slots are hidden, and unknown views are logged outside the swap ring. Cube and engine launches can also carry per-role launch-bounds requests under `$ENGINEOS_STATE_DIR/launch-bounds/*.env`; `layout=tmux-pane` requests scale the client to the matching output sub-rectangle and remain visible as panel views while another terminal or pane slot is active. Output/fullscreen cube and engine launches keep the exclusive slot-style behavior.
- Shell-launched slot commands are tracked by pid. `SIGCHLD` reaping logs process exit status, whether the role mapped before exit, and `reason=process-exited-before-map` when a launchpad slot command dies before creating a surface.
- Input state is logged as `shell`, `terminal`, or `game` mode with a `game` or `none` capture flag. Shell mode clears keyboard focus and swallows non-shell keys; terminal and game modes forward keyboard input to the focused matching surface.
- Pointer devices update seat capabilities, the wlroots cursor is constrained to the output layout, output scales load an XCursor theme, client cursor image requests are honored only for the pointer-focused client, scene hit-testing updates pointer focus, and button presses can click-focus terminal/engine toplevels. When the engine slot is active and mapped, game capture automatically hides the cursor, ignores client cursor image requests, confines pointer coordinates to the focused engine view, advertises relative-pointer/pointer-constraints support, forwards relative motion deltas for mouselook past window edges, and forwards normal pointer events to the game until `Alt+C`, `Alt+F1/F2`, or `Ctrl+Alt+Backspace` releases capture. Gamepad routing remains later work.
- `SIGHUP` asks the real shell to re-read launch-bounds files, reapply launchpad visibility, and rewrite shell state. `eos-app pane sync` uses this for tmux resize/layout hooks so mapped pane-bound cube and engine clients can move with their panes without being restarted.
- The shell waits for at least one output after the wlroots backend starts before spawning shell-owned clients, so Qt/Wayland clients do not launch into a compositor that has not advertised outputs yet. The EngineDev shell start wrapper refreshes stale same-user `engineos-shell` processes and `wayland-*` runtime sockets before relaunching the compositor.
- The shell listens for image preview requests on `$XDG_RUNTIME_DIR/engineos/preview.sock` by default, or `$ENGINEOS_STATE_DIR/preview.sock` when the state directory is overridden. `engine-image-preview` sends `ping`, `show`, and `hide` requests for MC integration; `show` decodes PNG/JPEG with libpng/libjpeg-turbo, tags requests with terminal slot and owner data, clamps decoded dimensions, and renders a contained scene buffer inside the owning terminal/tmux pane bounds when available. MC `View`/`Open` requests return immediately after showing the sidecar and leave a parent watcher for MC-exit cleanup, `F3` closes the visible preview from the shell, owner-scoped hide requests prevent old watcher processes from hiding a newer preview, and shell shutdown leaves the shared socket path for the next shell instance.
- `engineos run shell --headless` prefers an installed `engineos-shell --headless` binary and falls back to an explicit headless smoke log.
- `engineos run shell --nested` prefers an installed `engineos-shell --nested --startup 'engineos app launch terminal' --terminal 'engineos app launch terminal' --cube 'engineos app launch cube' --engine 'engineos app launch quake'` binary path and falls back to an explicit nested smoke log.
- `engineos run shell --tty` is the Runtime graphical entry point; with the real binary it passes `--bootstrap launchpad` by default so the shell starts terminal, cube, and engine commands after the Wayland socket is ready, with cube as the active slot.
- `engineos terminal` launches a Wayland-native terminal (`foot`, then other Wayland-capable fallbacks) and requires `WAYLAND_DISPLAY` by default, so graphical clients stay owned by the EngineOS shell instead of falling back to X11 or a raw TTY path. Runtime sets `ENGINEOS_TERMINAL_SESSION_CMD='tmux new -A -s engineos'`, so the bootstrapped terminal opens directly into the persistent tmux session under zsh.
- `engineos-shell` exports Wayland session hints for spawned terminal/engine clients and unsets `DISPLAY` when its Wayland socket is active. This enforces shell ownership of app surfaces; it does not by itself prove hardware GL acceleration in VMs that expose only llvmpipe/pixman.
- `engineos proof shell-launch` validates the running shell process, renderer diagnostics, terminal/tmux ownership logs, and app launch ownership markers after a rebuilt ISO boots.
- `engineos proof launchpad` validates the launchpad MVP contract: launchpad bootstrap, cube as the active slot, shell-owned terminal/cube/Quake app launch markers, cube renderer/frame evidence, and a mapped engine slot. Quake asset/runtime guidance remains useful diagnostics, but it is not proof that the engine slot works.
- The real shell writes `/run/user/1000/engineos/shell-state.json` by default, or `$ENGINEOS_STATE_DIR/shell-state.json` when overridden. The state file records the schema, bootstrap mode, active/pending slot, input mode/capture, slot mapped/visible state, and live launch records for proofs and `engineos app status`.
- `/etc/engineos/apps.toml` is the packaged launchpad app registry. In the source tree it lives at `packages/engineos-config/files/etc/engineos/apps.toml`; `engineos app manifest validate` checks the declared terminal, cube, and Quake slot contract.
- `engineos run shell --headless|--nested|--tty` fails closed when `engineos-shell` is missing; there is no successful shell stub path.
- `engineos validate shell` checks shell source inputs, build dry-run, missing-binary fail-closed behavior, and fake installed-shell argument pass-through.
- `engineos outputs list` records DRM connector status and preferred modes before hardware shell attempts; `engineos outputs validate --single` and `--dual-static` provide quick connector-count checks.
- `ENGINEOS_SHELL_SMOKE=true engineos run shell --headless` asks the real binary to start and self-terminate when the binary is installed.
- `ENGINEOS_SHELL_STARTUP='foot' engineos run shell --nested` overrides the nested startup command.
- `ENGINEOS_SHELL_BOOTSTRAP=launchpad engineos run shell --tty` selects startup launch mode: `none`, `terminal`, `engine`, or `launchpad`; `all` remains an alias for `launchpad`.
- `ENGINEOS_TERMINAL_SLOT_CMD='engineos app launch terminal'` overrides the shell slot command for the terminal role.
- `ENGINEOS_TERMINAL_CMD='foot'` overrides the terminal emulator selected by `engineos terminal`.
- `ENGINEOS_TERMINAL_SESSION_CMD='tmux new -A -s engineos'` runs a shell command inside the selected terminal.
- `ENGINEOS_APPS_MANIFEST=/path/to/apps.toml` overrides the app registry used by CLI validation and shell-runner default commands.
- `engineos app launch terminal|cube|quake` is the app launch contract used by the shell. It enforces the shell-owned Wayland display, sets common Wayland client hints, disables SDL/libdecor for cube to avoid GTK decoration crashes, writes cube output to `cube.log`, and dispatches terminal/Quake to their existing runners.
- `engineos app pane sync` refreshes tmux-pane launch bounds for the current pane, while `engineos app pane sync --all` refreshes all stored pane-bound cube/engine roles from their recorded tmux pane IDs.
- `ENGINEOS_CUBE_CMD='engineos app launch cube'` overrides the cube launch command.
- `ENGINEOS_ENGINE_CMD='engineos app launch quake'` overrides the engine launch command.

Build on the Arch builder VM:

```bash
./tools/engineos/engineos package engineos-shell
./tools/engineos/engineos build shell
./tools/engineos/engineos test app
./tools/engineos/engineos test compositor --headless
```
