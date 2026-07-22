# Wargus Pointer Capture Defect Report

Date: 2026-07-21 UTC

This report records a live bare-metal EngineOS input-routing defect observed
while Wargus/Stratagus was mapped as a native game-pane presentation. It is a
shell ownership bug, not a missing diagonal-scroll implementation in
Stratagus.

## Outcome

- EngineOS game capture does not retain pointer ownership across the tmux
  status-row boundary.
- Moving toward the bottom of the Wargus surface can transfer pointer focus to
  tmux, make Stratagus process a window-leave event, reset edge scrolling, and
  then visibly jump when the shell confines the pointer back to the game.
- Stratagus already computes diagonal edge-scroll states. Losing pointer focus
  at the presentation boundary interrupts or clears those states.
- The shell state currently reports policy capture as `cursor.locked` even when
  the client did not request a Wayland locked-pointer constraint.
- No source or runtime behavior was changed during this investigation.

## User-Visible Symptoms

1. Moving the in-game cursor into a screen corner does not reliably scroll the
   map or editor diagonally.
2. Moving downward at the bottom of the game, adjacent to the tmux status line,
   makes the cursor jump.

## Environment

- Bare-metal EngineDev session using the DRM/libinput shell.
- `engineos-shell 0.1.0-83`
- `engineos-mux 3.6b-44`
- `engineos-tools 0.1.0-67`
- Shell PID at evidence collection: `82932`
- Two 1920x1080 outputs at scale 1.
- Wargus presentation geometry: 1920x1056.
- Tmux UI geometry: 45 rows with one status row at row 44, occupying the
  remaining bottom 24 pixels of the 1920x1080 output.
- Wargus saved preference:

  ```text
  /home/dev/wargus/build/userdata.wargus-linux/wc2/preferences.lua:13:wc2.preferences.GrabMouse = false
  ```

The launcher recorded the affected application path as:

```text
/home/dev/wargus/build/linux-stratagus/stratagus \
  -d /home/dev/wargus \
  -u /home/dev/wargus/build/userdata.wargus-linux
```

## Reproduction

Launch Wargus as an EngineOS game-pane presentation:

```bash
eos-app pane launch --game -- /home/dev/wargus/launch-linux.sh
```

Then:

1. Enter a game or the map editor with mouse edge scrolling enabled.
2. Move the cursor into a bottom corner to request simultaneous horizontal and
   vertical scrolling.
3. Continue moving downward toward the tmux status row.
4. Observe scrolling stop or become single-axis and the cursor jump as it
   crosses or returns from the boundary.

Keep `Alt+Escape` and `Ctrl+Alt+Backspace` available as emergency release
paths during every live validation run.

## Runtime Evidence

The mapped Wargus view was correctly recognized as a game presentation:

```text
00:04:43.438 focus view mode=game capture=game role=mux-presentation title=Wargus app_id=stratagus
00:04:43.439 native presentation mapped pane=%4 generation=1 pid=18620 surface=6 role=toplevel visible=true title=Wargus app_id=stratagus
```

During the same mapped session, the shell repeatedly allowed the global
pointer to leave the view and then warped it back to the last game pixel:

```text
00:09:21.450 cursor confined role=mux-presentation x=1351.5 y=1055.0 bounds=0.0,0.0 1920.0x1056.0 reason=pointer-target
00:09:27.418 cursor confined role=mux-presentation x=616.0 y=1055.0 bounds=0.0,0.0 1920.0x1056.0 reason=pointer-target
00:13:47.452 cursor confined role=mux-presentation x=965.8 y=1055.0 bounds=0.0,0.0 1920.0x1056.0 reason=pointer-target
```

There was no `pointer constraint requested` or `relative pointer requested`
entry for this Wargus client in the affected session. EngineOS nevertheless
hid the cursor and treated `capture=game` as a lock. This is policy capture,
not an active client-requested Wayland constraint.

## Root Cause

The relative-motion handler in `shell/src/engineos-shell.c` currently performs
these operations in this order:

1. Move the compositor's global cursor with `wlr_cursor_move`.
2. Classify the new location with `classify_pointer_target`.
3. If the location is tmux UI or a tmux pane, clear Wayland pointer focus and
   return.
4. Only afterward call `cursor_update_pointer_focus`, whose
   `cursor_target` path honors `server->game_capture`.

Relevant source locations:

- `cursor_handle_motion`: `shell/src/engineos-shell.c:5266`
- `cursor_handle_motion_absolute`: `shell/src/engineos-shell.c:5304`
- `classify_pointer_target`: `shell/src/engineos-shell.c:5133`
- game-capture target selection: `shell/src/engineos-shell.c:4970`
- manual confinement: `shell/src/engineos-shell.c:3940`

At y=1056, classification sees the tmux status row before game capture can
select the focused game surface. `clear_pointer_focus` therefore causes SDL to
emit a window-leave event. Wargus handles that event in
`/home/dev/wargus/build/stratagus-local/src/ui/mouse.cpp:981` by:

- setting `MouseScrollState = ScrollNone`; and
- resetting `CursorScreenPos` to the center of the video area.

The next motion routed back to Wargus is confined to y=1055, producing the
visible jump and destroying the prior diagonal scroll state.

Stratagus itself has explicit `ScrollLeftUp`, `ScrollLeftDown`,
`ScrollRightUp`, and `ScrollRightDown` handling in
`/home/dev/wargus/build/stratagus-local/src/ui/interface.cpp:1421`. No
Wargus-side diagonal
scroll fallback should be added to mask the compositor focus loss.

## Lock-State Observability Defect

`write_shell_state` currently serializes `cursor.locked` from
`should_lock_game_cursor(server)` at `shell/src/engineos-shell.c:3514`.
That predicate describes EngineOS game-capture policy; it does not prove that
`server->active_pointer_constraint` exists or that its type is
`WLR_POINTER_CONSTRAINT_V1_LOCKED`.

The state contract should distinguish at least:

- game capture policy is active;
- an active pointer constraint exists; and
- the active constraint type is `locked` or `confined`.

This matters because Wargus with `GrabMouse = false` needs absolute pointer
positions for software-cursor UI and edge scrolling, while Quake can request a
true relative-pointer lock for mouselook.

## Required Fix Boundary

The fix belongs in `engineos-shell`, at the shared pointer-routing boundary:

1. While game capture is active and a focused mapped game view exists, route
   pointer motion to that view before tmux UI/pane hit testing.
2. Apply the same ownership rule consistently to relative motion, absolute
   motion, buttons, and axes. The tmux status row must not receive pointer
   events while the game owns capture.
3. Preserve two client modes:
   - without a locked constraint, retain absolute coordinates and confine them
     to the game surface so RTS UI and edge scrolling continue to work;
   - with an active locked constraint, keep the compositor cursor stationary
     and deliver relative deltas according to the Wayland protocol.
4. Continue to release capture through the existing emergency shortcuts and on
   focus loss, unmap, destroy, and shell shutdown.
5. Report policy capture and actual Wayland constraint state separately in
   `shell-state.json`.

Do not solve this by expanding the game surface over the status row. Tmux owns
that row when capture is inactive, and the compositor must preserve that
ownership boundary.

## Regression Acceptance

Add a focused headless/native-mux contract that models a 1920x1056 game view
on a 1920x1080 output with a one-row tmux status area. It should prove:

- downward motion from y=1055 while game capture is active does not clear the
  game's Wayland pointer focus;
- no tmux mouse request is emitted for captured motion over the status row;
- absolute coordinates remain confined to y=1055 for an unlocked RTS client;
- simultaneous positive x/y motion at the bottom-right edge remains a
  two-axis game motion rather than a tmux transition;
- a client-requested locked constraint leaves the compositor cursor stationary
  while relative deltas continue;
- uncaptured graphical and terminal panes retain normal tmux status/menu mouse
  ownership; and
- `Alt+Escape` and `Ctrl+Alt+Backspace` still release capture to the console.

After source validation, repeat the reproduction with real Wargus on the
bare-metal DRM/libinput path. Headless success alone does not prove physical
pointer behavior.

## Validation Performed For This Report

These existing checks passed before the report was written:

```bash
./tools/engineos/eos-test compositor --headless
./tools/engineos/eos-test shell-actions
```

The compositor check reported:

```text
grim menu clear passed open_changed_channels=13754 closed_changed_channels=0
```

The shell-action check reported:

```text
native-only shell actions test passed
```

Neither check currently exercises captured game motion across the tmux status
boundary, so their success does not invalidate this report.

## Post-Fix Validation Commands

Run the narrowest source checks first:

```bash
./tools/engineos/eos-test compositor --headless
./tools/engineos/eos-test shell-actions
./tools/engineos/eos-test input
./tools/engineos/eos-source-test shell
```

Then rebuild and install through the normal package loop, followed by the live
Wargus reproduction and shell evidence capture. Do not treat a dry run as
runtime validation.

## Caveat

This report is based on the affected live session's shell state, launcher log,
shell log, and traced source path. No new replayable `eos-input record` trace
was captured because Wargus had already exited when the investigation began.
The post-fix bare-metal run should capture one if the issue is not fully
resolved by the focused regression.

## Resolution (2026-07-21)

`engineos-shell 0.1.0-84` fixes the shared pointer-routing boundary. While a
focused mapped game owns capture, the game is selected before tmux UI/pane hit
testing for relative motion, absolute motion, buttons, and axes. An unlocked
client such as Wargus with `GrabMouse = false` keeps absolute coordinates and
is confined to the game surface. A client-requested locked constraint instead
keeps the compositor cursor stationary and receives relative deltas.

The state contract now reports the separate concepts directly:

- `input.capture` is EngineOS game-capture policy;
- `cursor.constraint_active` reports an active Wayland pointer constraint;
- `cursor.constraint_type` is `locked`, `confined`, or `null`; and
- `cursor.locked` is true only for an active locked constraint.

The headless native-mux regression uses the real wlroots cursor handlers and
an exact 1920x1080 output with a 1920x1056 game view. It proves diagonal motion
at the bottom-right edge remains with the Wayland client, absolute input is
confined to `(1919, 1055)`, button and axis input over the status row do not
leak to tmux, a locked client receives relative deltas without cursor motion,
and console/emergency release plus application destruction clear capture.

The following checks passed:

```bash
./tools/engineos/eos-test compositor --headless
./tools/engineos/eos-test shell-actions
./tools/engineos/eos-test input
./tools/engineos/eos-source-test shell
./tools/engineos/eos-ci local --package engineos-shell \
  --test shell-actions --test input --install --clean-generated \
  --no-validate-repo
```

The package loop built and installed revision 84. Restarting
`engineos-dev-shell.service` produced shell PID 339681 without replacing tmux
PID 695; both live DRM outputs remained at 1920x1080 with hardware GLES and
zero frame failures. A real `engineos-wargus --editor` launch then mapped pane
`%4` as a captured game with no locked constraint. The focused graphical
client switched to Chroma about seven seconds later, so Wargus exited normally
before a physical boundary-motion trace could be captured. The automated
boundary proof is complete; the final quiet-desktop physical reproduction
remains an explicit acceptance item in `CURRENT_STATUS.md`.
