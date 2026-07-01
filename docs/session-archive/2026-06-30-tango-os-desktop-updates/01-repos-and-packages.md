# Repository and Package Updates

## Skills Repository

The local `/home/dev/skills` directory was made into a Git repository and pushed to GitHub:

- Remote: `https://github.com/Tango-Rocker/skills.git`
- Initial commit: `0651045 Initial skills pack`
- EngineOS migration commit: `8e73b23 Add EngineOS skills`
- Installed globally into: `/var/lib/engineos/codex-dev/skills`
- Initial installed skills:
  - `avoid-ai-code-smells`
  - `setup-harness-scaffolding`
- Migrated EngineOS skills:
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

Codex needs a restart before these globally installed skills are available in a new session.

## EngineDev Helper Repo Mapping

The post-install payload now knows how to fetch/update helper repositories under the EngineDev user's dev directory:

- `/home/dev/codex-extractor` from `Tango-Rocker/session-extrator`
- `/home/dev/opencode-autonomy` from `Tango-Rocker/agent`
- `/home/dev/skills` from `Tango-Rocker/skills`

The setup flow gained:

- `RUN_DEV_REPOS=true`
- `--skip-dev-repos`
- validation that each helper repo exists after setup

The deploy wrapper forwards `--skip-dev-repos` and shows the repo fetch flag in dry-run output.

## Package Ownership Fix

`packages/engineos-tools/PKGBUILD` was adjusted to avoid packaging files owned by the engine runner package:

- Removed `engine_runner.sh`
- Removed `engine_runner_daemon.py`
- Removed `__pycache__`

This avoids file ownership conflicts when installing the rebuilt tools package.

## Packages Rebuilt and Installed

The live system was updated from the current checkout with:

- `engineos-tools 0.1.0-1`
- `engineos-config 0.1.0-3`
- `engineos-shell 0.1.0-4`

The local `engineos-tools` package was rebuilt more than once as small status-reporting and zsh profile behavior fixes landed.
