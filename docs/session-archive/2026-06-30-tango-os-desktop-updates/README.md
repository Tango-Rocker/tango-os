# Tango-OS Desktop Updates Session

Date: 2026-06-30 UTC

This archive records the session that updated EngineDev helper repos, browser defaults, Codex skills, package ownership, shell observability behavior, and the live dual-monitor terminal workflow.

## Outcome

- Created and pushed the local `skills` repository to `Tango-Rocker/skills`.
- Installed local skills globally under `/var/lib/engineos/codex-dev/skills`.
- Migrated the Tang-OS / EngineOS skill pack into `Tango-Rocker/skills` and globally installed it for Codex.
- Set Falkon as the default browser for auth-capable flows.
- Installed and verified the terminal Spotify client path with `spotify_player`.
- Rebuilt and installed current local EngineOS packages from the checkout.
- Added first-class support for a secondary terminal slot in `engineos-shell`.
- Started two persistent tmux sessions:
  - `engineos` on the main terminal.
  - `engineos-side` on the side terminal.
- Restarted the live shell so both terminal windows are mapped at the same time.
- Switched placement so the side terminal lands on the rightmost monitor.
- Removed default zsh per-command observability hook installation so the observability prompt only appears at login.

## Live State Verified

- `engineos-dev-shell.service` is active.
- Two DRM connectors are connected at 1920x1080.
- `eos-app status --json` reports both `terminal` and `terminal-secondary` mapped.
- Shell logs show:
  - Main terminal: `x=0 y=0`
  - Side terminal: `x=1920 y=0`
- `tmux ls` reports:
  - `engineos`
  - `engineos-side`

## Key Controls

- `Alt+1`: focus or launch the main terminal slot.
- `Alt+4`: focus or launch the secondary terminal slot.
- Both terminal slots remain visible while focus changes.

## Installed Package Touches

Local packages rebuilt and reinstalled during the session:

- `engineos-tools 0.1.0-1`
- `engineos-config 0.1.0-3`
- `engineos-shell 0.1.0-4`

## Deeper Notes

- [Repository and package updates](01-repos-and-packages.md)
- [Browser and terminal app choices](02-browser-and-terminal-apps.md)
- [Dual-monitor shell implementation](03-dual-monitor-shell.md)
- [Validation and runtime evidence](04-validation-and-runtime.md)
- [Codex skills and observability behavior](05-codex-skills-and-observability.md)
- [Open follow-ups](06-follow-ups.md)
