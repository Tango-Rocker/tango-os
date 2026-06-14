# Code Navigation Skill

## When To Use

Use this skill when tracing code behavior, renaming symbols, checking diagnostics, or deciding whether LSP or text search is the right tool.

## Commands To Run

For current Bash-heavy work:

```bash
rg "pattern"
bash -n tools/engineos/engineos tools/scripts/*.sh
shellcheck tools/engineos/engineos tools/scripts/*.sh
```

For supported source files, use the LSP MCP when it responds:

```text
mcp__sdl_scaffoliding_lsp.lsp_server_status
lsp_server_status
lsp_document_symbols
lsp_diagnostics
lsp_workspace_diagnostics
lsp_completions
lsp_hover
lsp_signature_help
lsp_goto_definition
lsp_goto_type_definition
lsp_find_references
lsp_find_implementations
lsp_type_hierarchy
lsp_call_hierarchy
lsp_workspace_symbols
lsp_find_symbol
lsp_related_files
lsp_file_imports
lsp_file_exports
```

## Files That Matter

```text
docs/agent-lsp.md
tools/engineos/engineos
tools/scripts/
shell/
engine-runner/
```

## Known Traps

- The current LSP MCP is available as `mcp__sdl_scaffoliding_lsp`, but the local status probe has failed with `Transport closed`.
- Diagnostics, workspace-symbol, file import/export, type-hierarchy, call-hierarchy, completions, and find-symbol tools are exposed after `tool_search`, but live calls still depend on the MCP transport responding.
- `lsp_smart_search` and `lsp_rename` are not currently exposed in this session.
- `.sh` files are not currently configured for LSP in this harness.
- Extensionless Bash files are not currently configured for LSP.
- `rg` is still the right tool for docs, config, package lists, and string search.
- C/wlroots API compatibility is proven by the Arch builder VM compiler until local LSP is stable.

## Expected Output

Use semantic LSP results only when the MCP supports the file language and responds successfully. Otherwise, use shell syntax checks, `shellcheck` if available, project dry-runs, and focused text search.

## Recovery Steps

If LSP reports unsupported language, stop trying to force it. Record the limitation if relevant and use the project checks instead.
