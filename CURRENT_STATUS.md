# Current Status

Current focus: complete and prove the irreversible native graphical tmux
cutover on the bare-metal EngineDev installation.

ISO, VM, QEMU, Hyper-V, and generated-image workflows are historical reference
paths. Routine work uses source checkout package loops and the installed tty1
shell.

## Native Mux Cutover

The source tree now has one runtime architecture:

- the EngineOS tmux 3.6b fork installs as /usr/bin/tmux, provides and replaces
  the Arch tmux package, and uses tmux's normal default server socket;
- the same tmux server exposes $XDG_RUNTIME_DIR/engineos/mux.sock for graphical
  frontend clients;
- engineos-shell always connects to that frontend and fails closed when it is
  unavailable;
- tmux owns sessions, windows, panes, PTYs, grids, scrollback, commands,
  presentation scopes, and layout;
- the shell owns DRM/KMS, GPU composition, clipping, outputs, focus, input,
  Wayland surfaces, and observational shell-state.json;
- pane apps launch only through native tmux commands; pane images use the native
  pane-image command;
- login attaches with tmux new-session -A -s engineos.

Removed runtime paths include the side-by-side engine-mux binary, mux mode
selection, shell-owned Foot bootstrap, terminal registration, pane geometry
IPC, launch-bound files, launch tokens, environment scraping, proxy windows,
bridge hooks, eos-terminal, and the old graphical terminal launcher.

The native packages are installed on the bare-metal host. The default tmux
server owns the frontend socket and tty1 is running `engineos-shell --tty`
against it. The old side-by-side server is detached from the desktop and is
retained only until the Codex maintenance pane that performed this migration
exits.

## Working Baseline

- Direct tty1 DRM/libinput shell with radeonsi hardware rendering.
- Native terminal glyph rendering through fcft and the GPU atlas.
- Native tmux key, mouse, status, menu, copy-mode, resize, and presentation
  protocol paths.
- Scoped Falkon and Quake presentations with console toggle and emergency
  input release.
- Global presentation escape: Alt+Tab toggles a pane between its mapped app and
  backing console; on panes without a mapped app it advances tmux windows.
  Alt+Escape and Ctrl+Alt+Backspace release to the console without terminating
  the compositor.
- Pane-local PNG/JPEG previews and output-scoped wallpaper IPC.
- Recovery tty, shell logs, crash bundles, screencopy/grim, and observational
  shell state.

Live cutover evidence from 2026-07-11 through 2026-07-12:

- `engineos-mux 3.6b-42`, `engineos-shell 0.1.0-79`, and the native config and
  tools packages are installed; `/usr/bin/tmux -V` reports `tmux 3.6b`;
- `/usr/bin/engine-mux`, `/usr/bin/eos-terminal`, and the graphical terminal
  launcher are absent;
- tty1 uses DRM/libinput and `gpu-fcft-atlas-gles2` on both 1920x1080 outputs;
- a terminal marker advanced grid revision 1 to 13 and renderer frame 3 to 9
  without a view switch, and both output commits matched those revisions;
- Grim produced a nonblank 3840x1080 composed screenshot;
- Falkon mapped as a scoped pane presentation only on lease view 1 while the
  other output retained the backing console, and TERM restored the console;
- Chroma mapped as a scoped Qt Wayland presentation with app ID
  `stable-diffusion-chroma`; the installed shell routes global escape and
  window navigation through the native mux instead of cycling Qt transients or
  terminating Wayland;
- an initial `engineos-shell 0.1.0-77` Alt+Tab test exposed a scene-lifetime
  use-after-destroy when advancing away from a pane with a mapped Wayland
  presentation; the coredump resolved to `refresh_native_terminal_scene` and
  `wlr_scene_node_reparent`;
- `engineos-shell 0.1.0-78` detaches bound Wayland views before destroying an
  inactive pane scene. `0.1.0-79` makes Alt+Tab toggle both directions whenever
  the pane retains a mapped app, using next-window only when no app is mapped.
  Live input proofs completed app to console, console back to the same app, and
  Alt+Escape to console on one shell PID with zero service restarts.

## Acceptance

The live cutover satisfies the following:

- command -v tmux is /usr/bin/tmux and tmux -V reports tmux 3.6b;
- /usr/bin/engine-mux and all retired helper binaries are absent;
- the default tmux server owns the frontend socket;
- engineos-dev-shell.service is active on tty1 with radeonsi and no restart or
  coredump;
- a terminal pane refreshes without a view switch;
- prefix keys, arrows, right-click menus, Falkon close/input, grim, and repeated
  image preview operate through the native path;
- source/package checks pass;
- there are zero hook subprocesses, proxy windows, environment matches,
  persisted pixel geometries, or rollback mode settings.

## Deployed Live Terminal Themes

The checkout and tty1 deployment now have a versioned terminal-theme contract for
`engineos-shell`:

- `engineos-dark` and `gruvbox-dark` define the default foreground/background
  and all 16 ANSI colors;
- `eos-runtime shell theme apply NAME` updates existing pane and tmux-UI
  renderers without restarting tmux or the compositor;
- malformed themes fail before changing the active palette, and a render
  failure rolls back the prior palette;
- `shell-state.json` reports the active name, generation, defaults, and ANSI
  colors.

Meson tests, package builds for `engineos-shell` and `engineos-tools`, and the
full headless GLES2 native-mux contract pass. On 2026-07-17 the tty1 deployment
was upgraded to `engineos-shell 0.1.0-80` and `engineos-tools 0.1.0-59`, the
live shell was restarted while retaining tmux server PID 690, and
`gruvbox-dark` was applied in flight as generation 2. The live state reports
foreground `#ebdbb2`, background `#282828`, renderer
`gpu-fcft-atlas-gles2`, and zero frame failures on both outputs. A radeonsi
frame capture is recorded at
`artifacts/captures/shell-20260717T032058Z.png`.

## Desktop Reliability Deployment

The 2026-07-19 source/package pass implements the Sprint 17 desktop ownership
correction and is installed on tty1:

- pointer delivery is classified per region as tmux UI, tmux pane, Wayland
  surface, or none, with press-to-release domain latching; Qt keeps keyboard
  focus while status, menus, borders, and other panes remain mouse-owned by
  tmux;
- pane/output scenes, presentation attachments, and image attachments reconcile
  in dependency order. Missing output scenes and superseded image revisions
  defer, malformed images are isolated by image ID, and only mux
  transport/protocol loss remains compositor-fatal;
- `pane-image -e` supplies MC's ephemeral preview lifetime. The repo-owned
  `engineos-mc` package passes MC's real PID to the helper and retains helper
  stderr under the EngineOS runtime log directory;
- tmux ACS cells are normalized to Unicode box drawing. The shared CPU/GLES
  style decoder covers bold, italic, dim, reverse, hidden, underline variants
  and colors, strikeout, overline, and blink;
- Gruvbox Dark is the compiled and system terminal default. A successful
  runtime theme apply is persisted, and shell state reports theme source/error
  plus preview reconciliation status/error;
- manifest commands now provide direct `falkon` and `chroma` shims backed by
  absolute pane-launch argv. Launching outside a focused native pane fails
  explicitly instead of creating an unmanaged Wayland client;
- Chroma queue/backend ownership is in `chroma-worker.service`, with the
  mode-0600 `chroma-worker/v1` socket, SQLite single-writer queue, transactional
  output reservations, atomic completion, bounded retries, restart recovery,
  retained history, and unknown-port rejection;
- Spotify migration preserves credentials and unrelated settings while
  selecting the matching Gruvbox theme, enabling audio visualization, and
  reserving ten playback rows.

Installed package revisions are `engineos-config 0.1.0-10`,
`engineos-mux 3.6b-44`, `engineos-shell 0.1.0-82`,
`engineos-tools 0.1.0-62`, and `engineos-mc 4.8.33-1`. The native mux contract,
image-preview test, app/Chroma/Spotify test, and all shell Meson renderer/theme
tests pass. The mux proof also covers the transient-systemd-scope respawn race:
scope signals reconcile the short registration window, and accepted TERM/KILL
requests retire presentation state immediately while retaining the saved
respawn command.

The first live restart exposed a pointer-routing failure during the package
cutover. The replaced tmux server PID 704 dumped core, and the recovered shell
then treated ordinary mouse-target rejection on a non-authoritative output as
mux transport loss, causing two more compositor restarts. Evidence is preserved
at `artifacts/crash-bundles/20260720T001210Z`. Shell revision 82 keeps rejected
or stale pointer cells nonfatal, suppresses idle hover dispatch to
non-authoritative output views, and retains compositor-fatal handling for real
mux transport/protocol loss. It was installed and restarted without replacing
the recovered tmux server PID 3745788; both outputs report
`gpu-fcft-atlas-gles2`, zero frame failures, Gruvbox from `persisted-user`, and
idle preview reconciliation with no service restart after the fix.

The local CI installer now explicitly approves only libalpm's conflict-removal
question when `engineos-mc` is in the transaction. This preserves the atomic
stock-`mc` to `engineos-mc` replacement that plain noninteractive `pacman -U`
previously rejected.

## Remaining Acceptance Work

The unchanged upstream regression suite exposes a pre-existing scheduling race
in its cursor fixtures: both the pristine 3.6b comparator and the fork can
occasionally query the cursor before the fixture child writes its initial PTY
data. A broad event-loop workaround was rejected because it regressed upstream
control-client sizing. The exact evidence is under
`/tmp/engineos-tmux-upstream-20260711T225801Z`; this is a test-fixture timing
issue, not a retained runtime fallback.

The next physical acceptance pass exercises the remaining interactive paths:

    eos-proof native-kms
    eos-proof mc-preview
    falkon
    chroma
    systemctl --user status chroma-worker.service
    eos-runtime shell theme apply gruvbox-dark
    eos-proof native-quake
    eos-validate boot --bare-metal

Live acceptance must repeatedly switch away from MC image previews without a
shell restart, click tmux UI/borders/other panes while Qt remains presented,
restart the graphical shell during an active Chroma generation and observe the
committed output, and verify changing Spotify spectrum bars and Gruvbox
persistence after restart.
