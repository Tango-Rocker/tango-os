# EngineDev Instance Bootstrap

This is the managed setup and refresh path for the live bare-metal EngineDev
installation. Legacy guest/ISO deployment remains available in the archived
image-lab tooling but is not the routine workflow.

## Result

The development user should have:

- current Codex CLI, installed through its detected managed install path
- `codex-extractor` checkout and pinned `codex-insights 0.2.0` command
- bounded project-overseer timer with metadata-only token accounting
- `opencode-autonomy`, `quake-generator`, and shared `skills` checkouts
- the EngineOS system tmux fork with restart-safe text and graphical clients
- zsh and packaged shell plugins
- Docker installed, active, and usable by the development user
- EngineOS shell, tools, cube, Quake, dgen, level-agent, and editor packages
- setup logs under `/var/log/engineos/post-first-deploy.log`

Codex authentication remains manual. Run `codex` once as the development user
and authenticate with the intended account.

## Managed Setup

From the live Tang-OS checkout:

```bash
cd /home/dev/Tang-OS
sudo ./tools/post-install-payload/scripts/setup_dev_environment.sh \
  --payload ./tools/post-install-payload \
  --user dev
```

Use `--force-config` only when replacing EngineOS-managed tmux, zsh, Docker, or
shell-service configuration is intentional. Unmanaged user files are preserved.

Useful partial refreshes:

```bash
sudo ./tools/post-install-payload/scripts/setup_dev_environment.sh \
  --payload ./tools/post-install-payload --user dev --skip-docker --skip-pacman

eos-runtime shell refresh-user
eos-runtime shell restart-live
```

`refresh-user` installs the tracked tmux helpers and sources the managed tmux
configuration. `restart-live` succeeds only after systemd replaces the shell
PID; the new terminals reattach the existing tmux server and sessions.

## Helper Repositories

The setup normalizes helper checkouts under the development user's home:

```text
~/codex-extractor
~/opencode-autonomy
~/quake-generator
~/skills
```

Existing clean repositories fast-forward from their upstream. Dirty
repositories are fetched but not rewritten. Dgen packaging uses an exact commit
from `~/quake-generator`; missing source or commit is a hard build failure.

The repository checkout is named `codex-extractor`, while its released Python
package and command are named `codex-insights`. Setup installs tag `v0.2.0` in:

```text
~/.local/share/codex-insights/venv
~/.local/bin/codex-insights
```

Reviews default to `gpt-5.6-luna` with medium reasoning. Archive directories
are private, raw session copies are mode `0600`, and deletion requires an
explicit `codex-insights prune --execute` operation.

## Package Deployment

Routine source changes use committed-range package deployment:

```bash
./tools/engineos/eos dev plan --range <base>..<head>
./tools/engineos/eos dev apply --range <base>..<head>
```

Install the repository pre-push hook once:

```bash
tools/hooks/install_git_push_deploy_hook.sh
```

The hook rejects relevant dirty files, builds the changed package set plus
local dependencies, performs one package transaction, refreshes managed user
state, restarts the shell when required, and blocks the push on failure.

## Validation

```bash
tmux -V
tmux list-clients -F '#{client_tty} #{session_name} #{pane_id}'
docker info
codex --version
codex-insights --version
eos-agent supervisor status --root /home/dev/Tang-OS --json
systemctl --user status engineos-agent-supervisor.timer
eos-agent hygiene check
eos-app manifest validate
eos-app pane list --json
eos-game quake status
cat /var/log/engineos/post-first-deploy.log
```

Expected tmux topology is one server with the primary client attached to the
existing work session and the secondary client attached to `engineos-side`.
Multiple sessions are normal; multiple tmux servers or a newly-created orphan
`engineos` session after every shell restart are not.

If Docker group membership was just added, start a new login session before
testing Docker without sudo.

## Security Boundaries

Do not place commercial Quake assets, API keys, Codex credentials, SSH private
keys, repository tokens, or raw session archives in the post-install payload.
The payload is tracked and packageable. Private repository credentials must use
an external temporary credential mechanism and must be removed after use.

## Legacy Image Lab

The old `eos-deploy first`, Hyper-V builder, generated ISO, and destructive
installer procedures are historical references. Use
[builder-vm-hyperv.md](builder-vm-hyperv.md) and
[../EngineOS_Windows_VM_Execution_Plan.md](../EngineOS_Windows_VM_Execution_Plan.md)
only when image work is explicitly re-enabled.
