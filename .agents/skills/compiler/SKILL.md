---
name: compiler
description: Compile C/C++ apps, local EngineOS packages, kernel-adjacent tools, and reviewed third-party or AUR-style source for the target system. Use for package builds, repo rebuilds, compiler errors, and source integration.
---

# Compiler

Use the Arch builder VM for real compiler acceptance. Local work should prefer
dry-runs, package lint, and syntax checks until builder proof is needed.

## Workflow

1. Review source/package inputs before running third-party build recipes.
2. Prefer repo-owned package definitions over ad hoc installs.
3. Keep generated artifacts out of source control.
4. Escalate runtime/service behavior to `overseer` or `admin-shell`.

## Commands

```bash
eos-build repo --dry-run
eos-package engineos-shell --dry-run
eos-lint packages
eos-build shell --dry-run
```
