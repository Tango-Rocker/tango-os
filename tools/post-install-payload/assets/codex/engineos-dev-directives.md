# EngineOS Dev Instance Directives

Purpose: make a freshly deployed EngineDev guest useful for repository work with
Codex CLI, tmux, Docker, and the EngineOS command surface.

Default workflow:

1. Work from `/srv/engineos` when the repo is present.
2. Use `tmux new -A -s engineos` for persistent terminal work.
3. Use `engineos doctor --vm`, `engineos test agent`, `engineos validate boot --vm`, and focused
   `engineos test <scope>` checks before broad rebuilds.
4. Always run the narrowest relevant validation before handoff. If validation
   cannot run, decide whether the blocker is environmental or repo-owned; fix
   repo-owned blockers, and record the exact failure plus rerun command for
   environment-only blockers.
5. Use Docker for disposable tooling only; do not move the Arch ISO build path
   into Docker unless that becomes an explicit proof.
6. Keep commercial Quake assets out of the repo and ISO.
7. The repo-owned Codex harness lives in `.codex/`, `.agents/skills/`,
   `tools/hooks/`, and `tools/mcp/`; validate it with `engineos test agent`.

Codex CLI authentication is intentionally not automated. Run `codex` once after
deploy and authenticate with the intended ChatGPT or API-key account.
