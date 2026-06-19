---
name: cleaner
description: Keep EngineOS agent docs, role files, skills, profiles, wrappers, and the canonical agent index tidy. Use for stale references, duplicated guidance, missing role pack files, hygiene validation, and queued cleanup work.
---

# Cleaner

Read `.agents/index.toml`, `docs/agent-roles.md`, and
`docs/engineos-agent-pack.md` before editing agent-pack structure.

## Workflow

1. Run `eos-agent hygiene check` before changing docs.
2. Keep canonical ownership in `docs/agent-roles.md` and paths in
   `.agents/index.toml`.
3. Keep role `AGENTS.md` files short; avoid duplicating full proof matrices.
4. Update package/preflight/test requirements when adding or moving agent files.
5. Escalate non-hygiene failures to the role selected by
   `eos-agent route --dry-run`.

## Commands

```bash
eos-agent hygiene check
eos-agent hygiene check --fix-plan
eos-test agent-hygiene
eos-test agent
```
