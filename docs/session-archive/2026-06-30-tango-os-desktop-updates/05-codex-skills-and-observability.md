# Codex Skills and Observability Behavior

## EngineOS Skills Migration

The Tang-OS / EngineOS skills that lived in `/home/dev/Tang-OS/.agents/skills` were copied into `/home/dev/skills` as first-class skill directories.

The migration preserved whole skill directories, including `agents/openai.yaml` helper files where present.

Migrated skills:

- `admin-shell`
- `archiso-build`
- `cleaner`
- `code-navigation`
- `compiler`
- `crash-forensics`
- `engine-builder`
- `engineos`
- `input-routing`
- `oracle`
- `overseer`
- `pergame-quake`
- `quake-port`
- `render-gl`
- `wlroots-compositor`

The `/home/dev/skills/README.md` was updated to describe both general development skills and Tang-OS / EngineOS skills.

The skills repo was committed and pushed:

```text
8e73b23 Add EngineOS skills
```

## Global Codex Install

All skill directories from `/home/dev/skills` were synced into:

```text
/var/lib/engineos/codex-dev/skills
```

Restart Codex to load newly installed global skills in future sessions.

## Zsh Observability Hook Change

The default zsh profile behavior was changed to stop installing the per-command observability hook after each interactive shell start.

Removed default `eos-observe hook zsh` installation from:

- `tools/post-install-payload/assets/zshrc`
- `tools/post-install-payload/assets/zprofile`
- live `/home/dev/.zshrc`
- live `/home/dev/.zprofile`

Kept login-time observability handling:

```bash
eos-observe prompt-login --shell zsh || true
```

This means the opt-in/status prompt can still run once during login, but the `__engineos_observability_*` preexec/precmd hook is not installed by default for every interactive shell.

The already-loaded hook was also removed from live zsh tmux panes during the session.

Validation after the change:

```bash
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=/home/dev/Tang-OS ./tools/eos/test/test_runner.sh observability
env -u ENGINEOS_SCRIPT_DIR ENGINEOS_ROOT=/home/dev/Tang-OS ./tools/eos/test/test_runner.sh post-first-deploy
```

Both checks passed.

