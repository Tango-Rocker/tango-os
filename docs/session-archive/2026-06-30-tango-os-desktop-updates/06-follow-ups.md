# Open Follow-Ups

## Commit and Push

The Tang-OS checkout has uncommitted changes from this session. Review and commit intentionally before pushing.

Changed areas include:

- `shell/src/engineos-shell.c`
- `tools/scripts/app.sh`
- `tools/scripts/shell_runner.sh`
- `tools/scripts/terminal_launcher.sh`
- `tools/scripts/validate_shell.sh`
- `tools/eos/test/test_runner.sh`
- `packages/engineos-config/files/etc/engineos/apps.toml`
- `packages/engineos-tools/PKGBUILD`
- post-first-deploy repo update scripts
- managed zsh profile assets
- `docs/session-archive/2026-06-30-tango-os-desktop-updates/`

## Restart Codex

Restart Codex to pick up the globally installed EngineOS skills from:

```text
/var/lib/engineos/codex-dev/skills
```

## Terminal Font Scaling

The requested 25 percent terminal font increase was not completed. Likely places to inspect next:

- foot configuration in the EngineDev user config
- packaged skeleton config
- post-install payload config files

## WhatsApp TUI

No official Arch package was installed for WhatsApp TUI because the request required official packages only.

## Status Output Polish

The status command now token-matches `terminal` and `terminal-secondary` separately in source and was reinstalled through `engineos-tools`. Confirm the installed package includes this after any future package rebuild.

## Longer-Term Shell Polish

Possible later work:

- Make output policy configurable by connector name.
- Add explicit output names to shell state JSON.
- Add a focused compositor test for rightmost secondary-terminal placement.
