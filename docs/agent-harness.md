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
4. Use LSP MCP for supported code when it responds; see [agent-lsp.md](agent-lsp.md).
5. Pick the smallest proof command.
6. Send useful tangents to [../BACKLOG.md](../BACKLOG.md) instead of widening the task.

Useful orientation commands:

```bash
pwd
rg --files --hidden
./tools/engineos/engineos --help
./tools/engineos/engineos test
```

## Command Policy

Use dry-runs outside the Arch builder VM:

```bash
./tools/engineos/engineos doctor --mock
./tools/engineos/engineos builder handoff --dry-run --host dev@<builder-vm-ip>
./tools/engineos/engineos builder handoff --dry-run --host dev@<builder-vm-ip> --run-proof
./tools/engineos/engineos builder doctor-proof --dry-run --host dev@<builder-vm-ip>
./tools/engineos/engineos deploy first --dry-run --host dev@127.0.0.1 --port 2222
./tools/engineos/engineos bootstrap builder --dry-run
./tools/engineos/engineos validate builder --mock
./tools/engineos/engineos validate repo --dry-run
./tools/engineos/engineos preflight all
./tools/engineos/engineos lint packages
./tools/engineos/engineos proof build-lab --dry-run
./tools/engineos/engineos proof hardware-ready --dry-run --profile engineruntime --device /dev/sdX
./tools/engineos/engineos release checklist --dry-run
./tools/engineos/engineos test vm
./tools/engineos/engineos test usb
./tools/engineos/engineos build shell --dry-run
./tools/engineos/engineos build repo --dry-run
./tools/engineos/engineos build iso --dry-run
./tools/engineos/engineos build iso enginedev --fast --dry-run
```

Use real builds only on the Arch builder VM:

```bash
cd /srv/engineos
./tools/engineos/engineos bootstrap builder
./tools/engineos/engineos validate builder
./tools/engineos/engineos proof build-lab
./tools/engineos/engineos build iso enginedev --fast --clean --archive-existing
./tools/engineos/engineos proof release-candidate
./tools/engineos/engineos proof hardware-ready --profile engineruntime --device /dev/sdX
./tools/engineos/engineos vm boot enginedev --display none --background --ssh-port 2222
ENGINEOS_GUEST_PASSWORD=dev ./tools/engineos/engineos deploy first --host dev@127.0.0.1 --port 2222
./tools/engineos/engineos vm boot engineruntime
```

To move the current checkout onto the Arch builder VM and run the first real
builder checks from the host side:

```bash
./tools/engineos/engineos builder handoff --host dev@<builder-vm-ip>
./tools/engineos/engineos builder handoff --host dev@<builder-vm-ip> --run-proof
```

After the EngineDev VM is booted by the builder and SSH is forwarded on port
2222, use the host-side combined build-and-doctor directive:

```bash
./tools/engineos/engineos builder doctor-proof --host dev@<builder-vm-ip>
```

It SSHes into the builder for `proof build-lab`, then SSHes from the builder
into the booted EngineDev guest and runs `engineos doctor --vm`.
If WSL cannot route to the Hyper-V builder but Windows OpenSSH can, use
`ENGINEOS_SSH=ssh.exe` for the host-to-builder leg.

If the Arch builder VM does not exist yet, use
[builder-vm-hyperv.md](builder-vm-hyperv.md) on Windows Hyper-V.

Inside a generated ISO:

```bash
engineos proof booted-iso --vm
engineos proof booted-iso --runtime
```

For first-deploy setup of a booted EngineDev guest, see
[dev-instance.md](dev-instance.md). The payload lives in
`tools/post-install-payload/`; do not add secrets or commercial game assets to
that payload.

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
bash -n tools/engineos/engineos tools/scripts/*.sh engines/quakespasm/engineos/*.sh tests/smoke.sh
shellcheck tools/engineos/engineos tools/scripts/*.sh engines/quakespasm/engineos/*.sh tests/smoke.sh
./tools/engineos/engineos preflight all
./tools/engineos/engineos lint packages
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
