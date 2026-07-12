# EngineOS

EngineOS is a hobby OS lab built on Arch Linux. The active target is the live
bare-metal EngineDev system: a wlroots shell, shell-owned Wayland apps,
hardware GL evidence, recovery logs, and Quake development through one
user-facing command surface.

ISO, VM, QEMU, Hyper-V builder, and generated-image workflows are retained as
legacy reference paths. They are not part of routine development unless the
image lab is explicitly re-enabled.

## Start Here

Read [CURRENT_STATUS.md](CURRENT_STATUS.md) for current proof state and the
next command. The normal source-checkout loop is:

```bash
./tools/engineos/eos --help
./tools/engineos/eos-source-test agent
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-lint packages
./tools/engineos/eos-preflight all
./tools/engineos/eos-test shell-actions
./tools/engineos/eos-test shell
./tools/engineos/eos-test input
```

Use `eos-source-test <scope>` when the installed session exports `/usr` paths
that could otherwise mask source changes. Use `eos-ci local` for a real package
build/reinstall loop.

## Live Development

The EngineOS tmux 3.6b fork is the system `tmux` and the only session, window,
pane, PTY, grid, command, presentation, and layout authority. `engineos-shell`
is its native graphical frontend and owns DRM/KMS, GPU composition, clipping,
outputs, focus, input, and Wayland surfaces.

```bash
eos-runtime shell refresh-user
eos-runtime shell restart-live
eos-app manifest validate
eos-app pane launch -- falkon
eos-app pane list --json
```

Login attaches directly with `tmux new-session -A -s engineos`. Each EngineOS
output registers a graphical tmux view; ordinary local or SSH tmux clients
remain compatible text clients.

Right-click a tmux window name and select `Move to Session...` to send that
window to another session without recreating its panes or processes.

MC image previews use the native pane-image command and are keyed by pane,
generation, and graphical view lease.

## Quake Workflow

Quake runs as a tmux game-pane presentation. The level agent uses the installed,
commit-pinned `dgen` release and a separate Codex MCP client per job.

```bash
eos-game quake setup
eos-game quake create "a short flooded gatehouse" --wait
eos-game quake status
eos-game quake edit <job-id>
eos-game quake play
eos-game quake proof
```

Commercial Quake assets are never stored in this repository. The default
user-owned path is `~/.local/share/engineos/quake/id1/pak0.pak`; verify it with
`eos-assets check quake`.

## Deployment

Deployment is computed from committed Git ranges, not the dirty working tree.
The planner maps changed files to packages, adds local package dependencies,
builds in dependency order, and performs one package transaction.

```bash
./tools/engineos/eos dev plan --range <base>..<head>
./tools/engineos/eos dev apply --range <base>..<head>
tools/hooks/install_git_push_deploy_hook.sh
```

The pre-push hook refuses relevant dirty files and fails the push when package
deployment or proof fails. This keeps published commits and the running
EngineDev package state aligned.

## Agent Harness

`.agents/index.toml` is the single role index. The router and hygiene checker
read it directly; there are no generated profiles, wrapper copies, queues, or
inactive lifecycle hooks.

```bash
./tools/engineos/eos-agent route "fix Quake focus after reload"
./tools/engineos/eos-agent show pergame-quake
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-observe metrics
```

The `codex-extractor` checkout provides the pinned `codex-insights 0.2.0`
command. Reviews use `gpt-5.6-luna` with medium reasoning; raw archives are
private and cleanup is explicit through `codex-insights prune`.

## Repository Map

```text
packages/                  local Arch package definitions
shell/                     wlroots compositor
engines/quakespasm/        QuakeSpasm source integration
tools/engineos/            eos-* entrypoints
tools/scripts/             command implementations
tools/game/                per-user game service adapters
tools/level-agent/         Quake level-agent implementation
tools/post-install-payload managed live-user configuration
.agents/                   role index, role rules, and skills
docs/                      architecture and workflow documentation
archiso/                   legacy generated-image profiles
```

## Documentation

- [CURRENT_STATUS.md](CURRENT_STATUS.md): live truth, blockers, and next proof
- [ROADMAP.md](ROADMAP.md): PoC, sprint, and MVP sequence
- [docs/agent-harness.md](docs/agent-harness.md): command and publication policy
- [docs/agent-roles.md](docs/agent-roles.md): role ownership
- [shell/README.md](shell/README.md): compositor behavior and interfaces
- [docs/dev-instance.md](docs/dev-instance.md): bare-metal EngineDev setup
- [BACKLOG.md](BACKLOG.md): intentionally deferred work
