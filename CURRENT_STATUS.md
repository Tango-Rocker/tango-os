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

## Agent Workflow Cost Supervisor

The project now has an installed project-overseer supervisor rather than only
an OS operations overseer. `eos-agent supervisor` keeps a private,
metadata-only token ledger, hashes session identifiers, omits prompts and
responses, and batch-gates `codex-insights` review to five newly completed
Tang-OS sessions. Each review is limited to one 160-line evidence chunk per
session and uses `gpt-5.4-mini` with low reasoning. A persistent six-hour user
timer is enabled and active; its first installed one-shot run completed
successfully, and the next trigger was scheduled for 2026-07-22 16:12 local.

The July 22 baseline contains 50 completed sessions and 2,232,994,211 total
tokens, including 49,012,293 uncached input tokens and 77 compactions. The
latest five-session historical window averages 34,997,816 total tokens,
1,089,151 uncached input tokens, 84,101 output tokens, and 2 compactions, which
passes the configured budget. Historical sessions were seeded without model
review, so supervisor reviewer overhead is currently zero tokens. This is a
baseline, not proof of savings: `post_baseline_ready` remains false until five
future sessions complete. Currency cost is intentionally not estimated until
verified model pricing is configured.

The supervisor contract test covers initialization, batch gating, bounded
extractor arguments, metadata privacy, token accounting, and visible extractor
failure. A separate integration proof exercised the installed
`codex-insights watch` path across five synthetic completed sessions with a
fake reviewer, confirmed five bounded review calls, and confirmed that raw
session archives were absent.

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
`engineos-mux 3.6b-45`, `engineos-shell 0.1.0-84`,
`engineos-tools 0.1.0-70`, and `engineos-mc 4.8.33-1`. The native mux contract,
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

A 2026-07-19 follow-up found that the direct `falkon` and `chroma` shims could
still be invoked from a native pane whose shell predated the compositor and
therefore lacked `WAYLAND_DISPLAY`. `engineos-tools 0.1.0-63` discovers the
display reported by the current shell only when its Unix socket accepts a
connection, then carries `XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`, and the Wayland
backend variables in the exact tmux-injected launch command. Stale shell state
continues to fail closed. Revision 63 was installed through the deploy-on-push
package closure, which passed the app, mux, and agent tests and restarted the
live shell successfully. Its first live no-argument Falkon proof reached the
new Wayland launch command and exposed a second launcher error: Falkon refuses
`--no-remote` with its default profile. The source follow-up in
`engineos-tools 0.1.0-64` selects the dedicated `engineos` profile unless the
caller supplies one.

Revision 64 is installed and the live shell restarted successfully as PID
3934865 with the existing tmux server retained. Its deploy gate passed the app,
mux, and agent tests; one earlier push attempt stopped on an intermittent mux
shell-history assertion, while the immediate exact rerun and the next complete
deploy gate passed. The live Chroma error about an unknown listener on port
7862 resolved to the retired raw `chroma_launcher_qt.py` scope
`engine-pane-704-15-1.scope`, which also owned the legacy `sd-server`. Stopping
that stale EngineOS scope released the port without touching user files. The
durable worker remains active as PID 3909433 with zero restarts, no queued job,
and no backend PID. With `WAYLAND_DISPLAY` deliberately unset, fresh selected
panes mapped Chroma PID 3945970 and Falkon PID 3947076 through current
`engine-pane-3745788-*` scopes, reported display `wayland-0`, and returned to
clean terminal presentation state after TERM. The shell still reports
`gpu-fcft-atlas-gles2`, two outputs with zero frame failures, and a connected
native mux. Closing that Falkon instance exposed a cursor-lifecycle bug: the
shell retained Falkon's client cursor surface after the focused view was
destroyed, leaving pointer events active but the cursor invisible. Restarting
the live shell restored the cursor immediately. Shell revision 83 tracks
client-owned cursor images and restores the shell default when a focused view
is minimized, unmapped, or destroyed. Revision 83 passed the source smoke,
headless compositor contract, package build, and deploy-on-push app/mux/shell
action/agent gate. The initial revision-83 live shell ran as PID 4018250. A
live Falkon close proof moved a uinput pointer through the normal libinput path
onto the focused client, observed `cursor.client_owned: true` and client
hotspots, then observed `cursor image=restored` plus terminal state with both
`hidden` and `client_owned` false after TERM.

A second 2026-07-19 Chroma follow-up installed `engineos-tools 0.1.0-65` so a
new Qt client reconnects to worker-owned artifacts as well as queue state. The
worker snapshot now advertises its durable log directory, current and per-job
server-log paths, timestamps, and every reserved output. The Qt adapter rebuilds
those paths after launch, follows only a bounded initial tail plus appended
bytes without replay duplication, shows all output paths, and opens the worker
log directory instead of the retired raw launcher's directory. The focused app
suite includes the durable worker integration plus a synthetic Qt reconnect
contract. After installation, the worker restart recovered three retained jobs,
resumed job 9 with its backend, and advertised all three server-log paths plus
three output reservations. The new Qt client mapped in pane `%8`, and live UI
acceptance confirmed that the reconnect works. Runtime validation inspected
only socket metadata, process state, and path existence; no live log contents
were read.

A Spotify follow-up installed `engineos-tools 0.1.0-66` after
`spotify_player 0.23.0` rejected lowercase palette keys such as
`bright_yellow` when used as component-style colors. Palette table keys remain
lowercase, while every managed component foreground/background now uses its
exact Gruvbox `#RRGGBB` value as required by the upstream style parser. The app
contract rejects non-hex managed component colors, the real 0.23.0 binary
accepted a synthetic migrated config and advanced to its normal startup path,
and the live managed theme was migrated without replacing credentials or
unrelated settings.

The 2026-07-21 Spotify authentication follow-up installed
`engineos-tools 0.1.0-68`. The stock Falkon desktop entry was already the MIME
default, but Wayland-only `xdg-open` generic mode skipped MIME activation when
`DISPLAY` was unset and fell through to unavailable text browsers. The managed
user refresh now installs `engineos-falkon.desktop`, registers it for HTTP,
HTTPS, XHTML, and HTML, and exports
`BROWSER=/usr/bin/engineos-browser-open` through both zsh and the authoritative
tmux server. The absolute opener delegates URLs to `eos-app launch falkon`, so
shell-owned pane routing remains enforced. The initial `xdg-open` proof from a
disposable shell launched Falkon but missed Spotify's real lifecycle:
`spotify_player` spawns `$BROWSER` asynchronously while its OAuth callback
listener must remain alive in the invoking pane. Reusing that pane either
rejects the non-shell caller or replaces the listener. The opener now derives
the invoking window, creates and selects an adjacent native tmux window, and
targets Falkon at its new pane. A live pending-auth proof kept Spotify PID
89581 alive in pane `%10` while the exact Spotify authorization request mapped
Falkon in pane `%13` under `engine-pane-695-13-1.scope`. Runtime validation used
process, pane, and presentation state only; no log contents were read.

The first publication attempt after that change exposed a deploy-hook ordering
bug: the managed `BROWSER` value was already present when `xdg-settings` tried
to register the same desktop handler, and xdg-utils refuses that combination.
`engineos-tools 0.1.0-69` removes `BROWSER` only from the registration command;
the managed zsh and tmux values remain installed for application launches. The
shell-action contract now reproduces the real environment and fails if the
registration subprocess inherits `BROWSER`.

The 2026-07-21 Wargus pointer report exposed a shell ownership error at the
1920x1056 game boundary: captured motion reached the tmux status-row hit test
before the focused game view, which sent Stratagus a pointer-leave event and
reset its diagonal edge-scroll state. `engineos-shell 0.1.0-84` gives an active
game capture first ownership of motion, absolute motion, buttons, and axes.
Unlocked RTS clients retain confined absolute coordinates and their client
cursor, while a client-requested locked constraint keeps the compositor cursor
stationary and receives relative deltas. Shell state now distinguishes capture
policy from `constraint_active`, `constraint_type`, and the actual `locked`
state.

The native headless contract now creates an input device and proves the exact
1920x1080 output, 1920x1056 game surface, and one-row tmux status geometry. It
drives simultaneous x/y motion at the bottom-right corner, absolute motion,
button and axis events over the status row, client-requested relative lock,
console toggling, emergency release, and app destruction through the real
wlroots cursor handlers. The compositor, shell-action, input, source-shell,
package build, install, and cleanup checks pass. One compositor run stopped on
the existing intermittent graphical Up-history assertion; its exact rerun and
the final complete contract passed without weakening that assertion. Revision
84 is installed, and the system shell restarted as PID 339681 while retaining
tmux PID 695; both DRM outputs report 1920x1080, hardware GLES rendering, and
zero frame failures. A live `engineos-wargus --editor` launch mapped pane `%4`
as a captured game with no pointer constraint, but the active graphical client
switched to Chroma about seven seconds later. The automated boundary proof is
complete; a quiet-desktop physical pointer pass remains listed below rather
than being reported as observed.

After the revision-84 deployment, HDMI-A-1 stopped accepting terminal input
while HDMI-A-2 remained healthy. Runtime state showed both DRM outputs and all
physical devices healthy, but the primary output's synthetic tmux client
`engineos-view-7` had the `suspended` flag. The stock `C-b C-z` binding invokes
`suspend-client`; a synthetic graphical client has no terminal-side process to
send tmux's wakeup message, so that state was permanent until shell output
registration was rebuilt. Evidence is preserved at
`artifacts/crash-bundles/20260722T012006Z`. Restarting only engineos-shell
restored HDMI-A-1 as focused `engineos-view-9`, retained tmux PID 695, and left
both outputs on the hardware GLES renderer with zero frame failures.
`engineos-mux 3.6b-45` makes `server_client_suspend` ignore graphical clients,
and the native mux contract directly attempts `suspend-client` against the
focused output client and rejects any resulting `suspended` flag. Revision 45
is installed. The retained revision-44 tmux server remains PID 695 so its live
panes were not disrupted; its `C-b C-z` binding is unbound as a reversible
runtime guard until that server is next restarted onto revision 45.

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
    falkon  # repeat input and close acceptance
    chroma  # restart the shell during an active generation
    systemctl --user status chroma-worker.service
    eos-runtime shell theme apply gruvbox-dark
    eos-app launch wargus --editor  # repeat the physical boundary motion proof
    eos-proof native-quake
    eos-validate boot --bare-metal

Live acceptance must repeatedly switch away from MC image previews without a
shell restart, click tmux UI/borders/other panes while Qt remains presented,
restart the graphical shell during an active Chroma generation and observe the
committed output, and verify changing Spotify spectrum bars and Gruvbox
persistence after restart.
