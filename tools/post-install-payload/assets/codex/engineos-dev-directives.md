# EngineOS Dev Instance Directives

Purpose: make a freshly deployed EngineDev guest useful for repository work with
Codex CLI, tmux, Docker, and the EngineOS command surface.

Default workflow:

1. Work from the live source checkout on bare metal.
2. Use `engineos-tmux-attach-primary` for persistent terminal work.
3. Use `eos-doctor`, `eos-source-test agent`,
   `eos-validate boot --bare-metal`, and focused `eos-source-test <scope>`
   checks before broad rebuilds.
4. Always run the narrowest relevant validation before handoff. If validation
   cannot run, decide whether the blocker is environmental or repo-owned; fix
   repo-owned blockers, and record the exact failure plus rerun command for
   environment-only blockers.
5. Use Docker for disposable tooling only; do not move OS build or deploy paths
   into Docker unless that becomes an explicit proof.
6. Keep commercial Quake assets out of the repo.
7. The repo-owned agent harness lives in `.codex/`, `.agents/index.toml`,
	`.agents/roles/`, `.agents/skills/`, `tools/scripts/agent_router.py`, and
	`tools/scripts/agent_hygiene.py`; validate it with `eos-source-test agent`.
8. For finished work that should deploy automatically on publish, install the
   repo hook with `tools/hooks/install_git_push_deploy_hook.sh`. It writes
	`.git/hooks/pre-push` and derives the package build/install set from pushed
	commits. The hook rejects relevant dirty files and does not call ISO, VM, or
	builder-handoff paths.
9. Session analysis uses pinned `codex-insights 0.2.0` with
   `gpt-5.6-luna` at medium reasoning. The first-deploy setup installs it in an
   isolated user environment; verify it with `codex-insights --version`.

Codex CLI authentication is intentionally not automated. Run `codex` once after
deploy and authenticate with the intended ChatGPT or API-key account.
