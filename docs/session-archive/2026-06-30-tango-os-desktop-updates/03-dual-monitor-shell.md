# Dual-Monitor Shell Implementation

## Goal

Use the second monitor for a separate terminal with a separate tmux session, while both terminals remain visible and active.

## Runtime Shape

- Main terminal slot:
  - Shell role: `terminal`
  - App command: `eos-app launch terminal`
  - tmux session: `engineos`
  - Placement: leftmost output, currently `x=0 y=0`

- Side terminal slot:
  - Shell role: `terminal-secondary`
  - App command: `eos-app launch terminal-secondary`
  - tmux session: `engineos-side`
  - Placement: rightmost output, currently `x=1920 y=0`

## Shell Changes

`shell/src/engineos-shell.c` gained:

- `ENGINEOS_SURFACE_TERMINAL_SECONDARY`
- `--terminal-secondary CMD`
- role classification for `engineos-terminal-secondary`
- `Alt+4` keybinding for the side terminal
- bootstrap spawning for the secondary terminal
- state output for the secondary slot
- visible terminal semantics so both terminal roles remain mapped even when inactive
- output placement by layout coordinate:
  - normal launchpad roles use the leftmost output
  - `terminal-secondary` uses the rightmost output

The final right-side placement fix replaced index-based output selection with coordinate-based selection. This makes the side terminal land on the right even if DRM connector enumeration changes.

## App Layer Changes

`packages/engineos-config/files/etc/engineos/apps.toml` gained:

```toml
[apps.terminal-secondary]
slot = "terminal-secondary"
role = "terminal-secondary"
command = "eos-app launch terminal-secondary"
package = "foot"
app_ids = ["engineos-terminal-secondary", "terminal-secondary"]
log = "terminal.log"
health = "terminal-owner-log"
input = "normal"
capture = "none"
```

`tools/scripts/app.sh` gained:

- `eos-app launch terminal-secondary`
- status output for `terminal-secondary`
- manifest validation for the new app
- stricter token matching so `terminal` does not accidentally match `terminal-secondary`

`tools/scripts/terminal_launcher.sh` gained:

- metadata args from:
  - `ENGINEOS_TERMINAL_APP_ID`
  - `ENGINEOS_TERMINAL_TITLE`
- session startup while preserving terminal args

The secondary launcher defaults are:

```text
ENGINEOS_TERMINAL_APP_ID=engineos-terminal-secondary
ENGINEOS_TERMINAL_TITLE=EngineOS Side
ENGINEOS_TERMINAL_SESSION_CMD=tmux new -A -s engineos-side
```

`tools/scripts/shell_runner.sh` gained:

- manifest lookup for `terminal-secondary`
- `--terminal-secondary "$DEFAULT_TERMINAL_SECONDARY"`
- preservation of caller-provided `ENGINEOS_LOG_DIR`, `ENGINEOS_STATE_DIR`, and `ENGINEOS_PROFILE` after loading `/etc/engineos/profile.conf`

