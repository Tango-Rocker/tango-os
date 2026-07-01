# Validation and Runtime Evidence

## Source Checks

The following focused checks passed from the source checkout:

```bash
bash -n tools/scripts/app.sh tools/scripts/terminal_launcher.sh tools/scripts/shell_runner.sh tools/scripts/validate_shell.sh tools/eos/test/test_runner.sh
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=/home/dev/Tang-OS ./tools/eos/test/test_runner.sh shell-actions
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=/home/dev/Tang-OS ./tools/eos/test/test_runner.sh app
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=/home/dev/Tang-OS ./tools/eos/test/test_runner.sh terminal
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=/home/dev/Tang-OS ENGINEOS_SHELL_BOOTSTRAP= ./tools/scripts/validate_shell.sh
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=/home/dev/Tang-OS ./tools/engineos/eos-build shell --dry-run
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=/home/dev/Tang-OS ./tools/engineos/eos-build shell
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=/home/dev/Tang-OS ./tools/eos/test/test_runner.sh observability
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=/home/dev/Tang-OS ./tools/eos/test/test_runner.sh post-first-deploy
```

Notes:

- `validate_shell.sh` ended with `0 failure(s), 0 warning(s)`.
- `observability` smoke and `post-first-deploy` dry-run passed after removing the default zsh hook install.
- Shell compile succeeded with existing unused-function warnings for `focus_next_view` and `focus_matching_role`.
- Running installed `eos-*` without forcing `ENGINEOS_ROOT` can resolve to `/usr`; source validations used `ENGINEOS_ROOT=/home/dev/Tang-OS` and unset `ENGINEOS_SCRIPT_DIR`.

## Installed Runtime Checks

After package install and service restart:

```bash
eos-app manifest validate
eos-app status --json
eos-outputs list
systemctl status engineos-dev-shell.service --no-pager
tmux ls
```

Observed runtime state:

- `engineos-dev-shell.service` active.
- `terminal` mapped.
- `terminal-secondary` mapped.
- Connected outputs:
  - `card0-HDMI-A-2`, 1920x1080
  - `card1-HDMI-A-1`, 1920x1080
- tmux sessions:
  - `engineos`
  - `engineos-side`

Final shell log evidence:

```text
layout view role=terminal x=0 y=0 fullscreen=1920x1080 active_slot=terminal title=foot app_id=foot
layout view role=terminal-secondary x=1920 y=0 fullscreen=1920x1080 active_slot=terminal title=EngineOS Side app_id=engineos-terminal-secondary
```

## Live Service Restarts

The shell service was restarted after package installation:

```bash
sudo systemctl restart engineos-dev-shell.service
```

Existing tmux sessions persisted across shell restarts.

## Skills Runtime Check

The global Codex skills directory was checked after migration:

```text
/var/lib/engineos/codex-dev/skills
```

Installed non-system skills at session end:

```text
admin-shell
archiso-build
avoid-ai-code-smells
cleaner
code-navigation
compiler
crash-forensics
engine-builder
engineos
input-routing
oracle
overseer
pergame-quake
quake-port
render-gl
setup-harness-scaffolding
wlroots-compositor
```
