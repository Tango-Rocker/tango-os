# Agent LSP and MCP Notes

Use LSP for semantic code navigation when the language server is available and responding. Use `rg` and project checks for text, config, docs, package lists, shell scripts, and archiso profiles.

## Current MCP State

Checked on 2026-06-11 with `tool_search` and `lsp_server_status`:

- LSP MCP name: `mcp__sdl_scaffoliding_lsp`
- Exposed tools include `lsp_server_status`, `lsp_start_server`, `lsp_stop_server`, `lsp_document_symbols`, `lsp_file_imports`, `lsp_file_exports`, `lsp_diagnostics`, `lsp_workspace_diagnostics`, `lsp_completions`, `lsp_hover`, `lsp_signature_help`, `lsp_goto_definition`, `lsp_goto_type_definition`, `lsp_find_references`, `lsp_find_implementations`, `lsp_type_hierarchy`, `lsp_call_hierarchy`, `lsp_workspace_symbols`, `lsp_find_symbol`, and `lsp_related_files`
- Some LSP tools are exposed lazily; use `tool_search` for the exact tool name before assuming it is unavailable
- `lsp_smart_search` and `lsp_rename` are not currently exposed in this session
- `lsp_server_status` currently fails with `Transport closed` in this harness
- Previous document-symbol probes against `shell/src/engineos-shell.c` also returned `Transport closed`
- `.sh` files are not configured for LSP in this harness
- extensionless Bash entrypoints, such as `tools/engineos/engineos`, are not configured for LSP
- PKGBUILDs, Markdown, archiso profiles, and package lists should use text/project checks

That means this local harness cannot currently prove semantic C diagnostics. Use syntax checks and shell tooling here, then use compiler output and a working LSP on the Arch builder VM once the shell package is being built there.

## Preferred LSP Flow

When LSP is responding and the file language is supported:

1. `lsp_server_status`
2. `lsp_document_symbols` for a file outline before broad edits
3. `lsp_diagnostics` for opened files, or `lsp_workspace_diagnostics` for project state already seen by the server
4. `lsp_completions` when available completions clarify an API surface
5. `lsp_hover` and `lsp_signature_help` for type or call context
6. `lsp_goto_definition` for exact declarations
7. `lsp_goto_type_definition` when a value's interface matters
8. `lsp_find_references` before deletion or behavior changes
9. `lsp_related_files`, `lsp_file_imports`, or `lsp_file_exports` to understand file relationships
10. `lsp_find_implementations`, `lsp_type_hierarchy`, or `lsp_call_hierarchy` when relationships matter
11. `lsp_workspace_symbols` or `lsp_find_symbol` when the symbol name is known but the file is not

Use `lsp_start_server` only when auto-start does not happen and the server is known to exist.

## Current Shell-Script Path

For Bash-heavy work:

```bash
bash -n tools/engineos/engineos tools/scripts/*.sh engines/quakespasm/engineos/*.sh tests/smoke.sh archiso/enginedev/profiledef.sh archiso/engineruntime/profiledef.sh
shellcheck tools/engineos/engineos tools/scripts/*.sh engines/quakespasm/engineos/*.sh tests/smoke.sh
```

If `shellcheck` is missing, say so and still run `bash -n`.

## Current C/wlroots Path

For `shell/src/engineos-shell.c`, this Windows/WSL harness can inspect text and run dry-runs, but it cannot currently prove wlroots API compatibility.

Use locally:

```bash
./tools/engineos/engineos build shell --dry-run
./tools/engineos/engineos package engineos-shell --dry-run
```

Use on the Arch builder VM:

```bash
./tools/engineos/engineos build shell
./tools/engineos/engineos build repo
```

Treat compiler output against Arch `wlroots0.19` as the source of truth until LSP is stable.

## Future Setup Checklist

When source code grows enough to benefit from persistent semantic tooling:

- C/C++: install `clangd`, generate `compile_commands.json`, and document the build command
- C/wlroots: prefer Arch builder VM compiler output against `wlroots0.19`; LSP is helper context, not acceptance proof until `clangd` and compile commands are working
- Rust: install `rust-analyzer`, keep `Cargo.toml` at the relevant project root
- Python: add the chosen formatter, test command, and language server expectation
- TypeScript: add the package manager command and language server expectation if web tooling appears

Do not block PoC 0 on LSP setup. Add stronger LSP support when there is enough real source code and builder VM tooling to benefit from it.
