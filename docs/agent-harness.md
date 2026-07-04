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

Use real local checks first. Keep dry-runs for destructive, remote, USB, and
builder-only previews:

```bash
./tools/engineos/eos-doctor --vm
./tools/engineos/eos-test agent
./tools/engineos/eos-builder handoff --dry-run --host dev@<builder-vm-ip>
./tools/engineos/eos-builder handoff --dry-run --host dev@<builder-vm-ip> --run-proof
./tools/engineos/eos-builder doctor-proof --dry-run --host dev@<builder-vm-ip>
./tools/engineos/eos-deploy first --dry-run --host dev@127.0.0.1 --port 2222
./tools/engineos/eos-builder bootstrap --dry-run
./tools/engineos/eos-agent hygiene check
./tools/engineos/eos-agent dispatch status
./tools/engineos/eos-ci local --package engineos-tools --test agent-route --no-validate-repo --clean-generated
./tools/engineos/eos-preflight all
./tools/engineos/eos-lint packages
./tools/engineos/eos-proof build-lab --dry-run
./tools/engineos/eos-proof hardware-ready --dry-run --profile engineruntime --device /dev/sdX
./tools/engineos/eos-release checklist --dry-run
./tools/engineos/eos-test vm
./tools/engineos/eos-test usb
./tools/engineos/eos-build iso --dry-run
./tools/engineos/eos-build iso enginedev --fast --dry-run
```

Use real builds only on the Arch builder VM:

```bash
cd /srv/engineos
./tools/engineos/eos-builder bootstrap
./tools/engineos/eos-validate builder
./tools/engineos/eos-proof build-lab
./tools/engineos/eos-build iso enginedev --fast --clean --archive-existing
./tools/engineos/eos-proof release-candidate
./tools/engineos/eos-proof hardware-ready --profile engineruntime --device /dev/sdX
./tools/engineos/eos-vm boot enginedev --display none --background --ssh-port 2222
ENGINEOS_GUEST_PASSWORD=dev ./tools/engineos/eos-deploy first --host dev@127.0.0.1 --port 2222
./tools/engineos/eos-vm boot engineruntime
```

To move the current checkout onto the Arch builder VM and run the first real
builder checks from the host side:

```bash
./tools/engineos/eos-builder handoff --host dev@<builder-vm-ip>
./tools/engineos/eos-builder handoff --host dev@<builder-vm-ip> --run-proof
```

After the EngineDev VM is booted by the builder and SSH is forwarded on port
2222, use the host-side combined build-and-doctor directive:

```bash
./tools/engineos/eos-builder doctor-proof --host dev@<builder-vm-ip>
```

It SSHes into the builder for `proof build-lab`, then SSHes from the builder
into the booted EngineDev guest and runs `eos-doctor --vm`.
If WSL cannot route to the Hyper-V builder but Windows OpenSSH can, use
`ENGINEOS_SSH=ssh.exe` for the host-to-builder leg.

If the Arch builder VM does not exist yet, use
[builder-vm-hyperv.md](builder-vm-hyperv.md) on Windows Hyper-V.

Inside a generated ISO:

```bash
eos-proof booted-iso --vm
eos-proof booted-iso --runtime
```

For first-deploy setup of a booted EngineDev guest, see
[dev-instance.md](dev-instance.md). The payload lives in
`tools/post-install-payload/`; do not add secrets or commercial game assets to
that payload.

For agent harness changes, run:

```bash
./tools/engineos/eos-test agent
./tools/engineos/eos-test agent-hygiene
./tools/engineos/eos-test agent-dispatcher
./tools/engineos/eos-preflight repo --package engineos-tools
```

For the post-change rebuild/reinstall/cleanup loop, use `eos-ci local`.
It runs real preflight, tests, package rebuilds, and repo validation by default;
`--dry-run` is only a command preview and does not count as validation.

```bash
./tools/engineos/eos-ci local --package engineos-tools --test agent --install --clean-generated
```

When working from a non-`/srv/engineos` checkout on EngineDev, use
`--no-validate-repo` for a package-only reinstall loop, then run the full
command from `/srv/engineos` for repo acceptance.

## Finish And Publish

Finished work should leave the repository with an explicit publishing
disposition, not just local edits:

1. Review `git status --short` and `git diff` before committing.
2. Commit only the files that belong to the finished task. Leave unrelated
   dirty work untouched.
3. Push the branch after validation passes.
4. Merge when branch policy, review state, and CI allow it; otherwise open or
   update the merge path and record the exact blocker.

Do not commit secrets, commercial game assets, generated build outputs, local
logs, or unrelated work. If push or merge is blocked by credentials, branch
policy, failing CI, or a dirty tree outside the task scope, report the blocker
and the exact command to resume from.

Agent work may queue follow-up Cleaner tasks only through explicit queue
commands or validation hooks. The v0 dispatcher is local, repo-scoped, durable
JSONL, and manual-drain:

```bash
./tools/engineos/eos-agent queue list
./tools/engineos/eos-agent dispatch drain --dry-run
```

For local observability of agent work:

```bash
./tools/engineos/eos-observe metrics
./tools/engineos/eos-observe tui
./tools/engineos/eos-observe exporter once
```

External collectors can scrape the EngineOS exporter when needed.

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
- ISO contents come from official Arch packages, local EngineOS packages, or archiso profile files
- avoid one-off manual copies into images unless profile-owned and documented

Graphics rules:

- headless shell before nested shell
- nested shell before direct TTY/KMS
- VM graphics is smoke confidence only
- bare-metal AMD is the source of truth for DRM/KMS and real rendering behavior

Quake asset rules:

- do not commit commercial Quake assets
- keep asset metadata in a manifest
- generated test assets need redistributable licenses
- user-provided assets stay out of the ISO by default

## Handoff

Update [../CURRENT_STATUS.md](../CURRENT_STATUS.md) when a sprint acceptance condition changes. Keep it short:

- what works now
- what was tested
- what still does not work
- the next command to run
