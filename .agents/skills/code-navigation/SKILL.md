---
name: code-navigation
description: Use when navigating unfamiliar EngineOS code, checking symbols, locating definitions/references, or deciding whether LSP can help in this harness.
---

# Code Navigation Skill

Prefer semantic navigation when the LSP MCP is responding. In this harness it
has previously failed with `Transport closed`, so do not block EngineOS proofs
on it.

## First Steps

```bash
rg --files
rg "pattern"
```

For Bash, Markdown, PKGBUILDs, archiso profiles, and package lists, use text
search and project checks. These files are not LSP-backed here.

## LSP Flow

When LSP responds for a supported source file:

1. Check server status.
2. Use document symbols for an outline.
3. Use diagnostics after opening the file.
4. Use definition/references before deleting or changing behavior.
5. Use hover/signature help for types and API details.

See `docs/agent-lsp.md` for the exact tool names and current limitations.

## Local Checks

```bash
bash -n tools/engineos/engineos tools/scripts/*.sh tools/eos/*/*.sh engines/quakespasm/engineos/*.sh tests/smoke.sh archiso/enginedev/profiledef.sh archiso/engineruntime/profiledef.sh
./tools/engineos/eos-test shell
./tools/engineos/eos-preflight repo --package engineos-shell
```

Compiler truth for wlroots/C compatibility belongs on the Arch builder VM.
