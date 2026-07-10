# Agent Harness

This is the practical operating harness for agents working on EngineOS. It keeps the project moving without turning a hobby build into a work ritual.

## Rule

Every task should leave one of these behind:

- a command that now works
- a clearer failure with logs
- a smaller next step
- a backlog entry for something intentionally deferred

## First Five Minutes

1. Read [../CURRENT_STATUS.md](../CURRENT_STATUS.md).
2. Read [../ROADMAP.md](../ROADMAP.md) only far enough to place the task.
3. Search with `rg` before opening large files.
4. Use LSP semantic navigation for supported code when it responds; see [agent-lsp.md](agent-lsp.md).
5. Pick the smallest proof command.
6. Send useful tangents to [../BACKLOG.md](../BACKLOG.md) instead of widening the task.

Useful orientation commands:

```bash
pwd
rg --files --hidden
./tools/engineos/eos --help
./tools/engineos/eos-test
./tools/engineos/eos-test agent
./tools/engineos/eos-agent hygiene check
```

## Command Policy

Use real local checks first. ISO, VM, QEMU, Hyper-V builder, and
generated-image paths are legacy/reference-only and are not part of routine
Tango-OS/Engine-OS work:

```bash
./tools/engineos/eos-doctor
./tools/engineos/eos-source-test agent
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-ci local --package engineos-tools --test agent-route --no-validate-repo --clean-generated
./tools/engineos/eos-preflight all
./tools/engineos/eos-lint packages
./tools/engineos/eos-release checklist --dry-run
```

Legacy image-lab commands remain in archived docs and scripts for reference,
but agents should not choose them for current work without explicit user
direction.

For agent harness changes, run:

```bash
./tools/engineos/eos-source-test agent
./tools/engineos/eos-test agent-hygiene
./tools/engineos/eos-preflight repo --package engineos-tools
```

For the post-change rebuild/reinstall/cleanup loop, use `eos-ci local`.
It runs real preflight, tests, package rebuilds, and repo validation by default;
`--dry-run` is only a command preview and does not count as validation.

```bash
./tools/engineos/eos-ci local --package engineos-tools --test agent --install --clean-generated
```

When working from any live checkout, use `--no-validate-repo` for package-only
local loops if repo validation is tied to the old image repository layout.
Use `eos-source-test <scope>` when the goal is source-checkout validation and
an installed EngineOS session may have exported `/usr` command paths. Direct
`eos-build`, `eos-lint`, and `eos-preflight` remain lower-level package checks;
prefer `eos-ci local` for the normal build/test/install loop. Proof commands
must verify acceptance markers and required evidence files, not diagnostic
substitutes.
Use `eos-runtime shell refresh-user` after reinstalling user-space tmux/pane
helpers, then `eos-runtime shell restart-live` for the live EngineDev shell
service restart path.

## Finish And Publish

Finished work should leave the repository with an explicit publishing
disposition, not just local edits:

1. Review `git status --short` and `git diff` before committing.
2. Commit only the files that belong to the finished task. Leave unrelated
   dirty work untouched.
3. Push the branch after validation passes.
4. If deploy-on-push is installed for this checkout, the `pre-push` hook runs
   the configured local deploy command for pushed branch refs before Git
   completes the push.
   Configure it with:

```bash
tools/hooks/install_git_push_deploy_hook.sh
```

   The hook computes deployment from the pushed commit range and refuses
   relevant dirty files. It deliberately fails the push if deployment fails;
   use `git config engineos.deployOnPush false` only for an intentional
   manual-publish exception.
5. Merge when branch policy, review state, and CI allow it; otherwise open or
   update the merge path and record the exact blocker.

Do not commit secrets, commercial game assets, generated build outputs, local
logs, or unrelated work. If push or merge is blocked by credentials, branch
policy, failing CI, or a dirty tree outside the task scope, report the blocker
and the exact command to resume from.

For local observability of agent work:

```bash
./tools/engineos/eos-observe metrics
./tools/engineos/eos-observe tail --last 20
```

Session records are not part of the default work loop. When a user asks for
one, read [../agentd.md](../agentd.md) for the archive path and writing style,
then write only the focused handoff record needed for that session.

Project-status/docs MCP is intentionally removed. CLI work uses direct
`eos-*` commands plus skills. Future EngineOS MCP work belongs only to
read-only live runtime state after observability and role routing are proven.

## Focus Boundaries

Do the next proof on the current track. Do not silently turn a task into:

- a GPU passthrough project
- a Steam/Proton project
- an NVIDIA compatibility pass
- HDR, VRR, or multi-monitor polish
- a rich 3D cockpit
- a broad rewrite of the CLI, shell, or package layout

If the idea is useful, add it to [../BACKLOG.md](../BACKLOG.md) with:

- why it matters
- likely phase
- the smallest later proof

Then return to the current task.

## Code Navigation

Use semantic tools where they work:

```text
mcp__sdl_scaffoliding_lsp.lsp_server_status
mcp__sdl_scaffoliding_lsp.lsp_document_symbols
mcp__sdl_scaffoliding_lsp.lsp_diagnostics
mcp__sdl_scaffoliding_lsp.lsp_workspace_diagnostics
mcp__sdl_scaffoliding_lsp.lsp_completions
mcp__sdl_scaffoliding_lsp.lsp_hover
mcp__sdl_scaffoliding_lsp.lsp_signature_help
mcp__sdl_scaffoliding_lsp.lsp_goto_definition
mcp__sdl_scaffoliding_lsp.lsp_goto_type_definition
mcp__sdl_scaffoliding_lsp.lsp_find_references
mcp__sdl_scaffoliding_lsp.lsp_find_implementations
mcp__sdl_scaffoliding_lsp.lsp_type_hierarchy
mcp__sdl_scaffoliding_lsp.lsp_call_hierarchy
mcp__sdl_scaffoliding_lsp.lsp_workspace_symbols
mcp__sdl_scaffoliding_lsp.lsp_related_files
mcp__sdl_scaffoliding_lsp.lsp_file_imports
mcp__sdl_scaffoliding_lsp.lsp_file_exports
mcp__sdl_scaffoliding_lsp.lsp_find_symbol
```

Use text and project checks for shell scripts, Markdown, PKGBUILDs, archiso files, and config:

```bash
rg "pattern"
bash -n tools/engineos/engineos tools/scripts/*.sh tools/eos/*/*.sh engines/quakespasm/engineos/*.sh tests/smoke.sh
shellcheck tools/engineos/engineos tools/scripts/*.sh tools/eos/*/*.sh engines/quakespasm/engineos/*.sh tests/smoke.sh
./tools/engineos/eos-preflight all
./tools/engineos/eos-lint packages
```

If `shellcheck`, compiler tooling, or LSP is unavailable, record the limitation and continue with the best local proof.

## Area Rules

Package rules:

- local packages live in `packages/<name>/PKGBUILD`
- package names use the `engineos-` prefix
- packages are the active deployment unit
- generated images are legacy/reference artifacts, not a routine deploy target

Graphics rules:

- headless shell before nested shell
- nested shell before direct TTY/KMS
- bare-metal AMD is the source of truth for DRM/KMS and real rendering behavior

Quake asset rules:

- do not commit commercial Quake assets
- keep asset metadata in a manifest
- generated test assets need redistributable licenses
- user-provided assets stay out of generated artifacts by default

## Handoff

Update [../CURRENT_STATUS.md](../CURRENT_STATUS.md) when a sprint acceptance condition changes. Keep it short:

- what works now
- what was tested
- what still does not work
- the next command to run
