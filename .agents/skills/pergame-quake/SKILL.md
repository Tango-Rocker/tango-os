---
name: pergame-quake
description: Own Quake and quake-generator work for EngineOS, including QuakeSpasm source integration, wrappers, assets, game input/audio defaults, smoke tests, and platform interaction. Use for Quake-specific game code and runtime behavior.
---

# Per Game Quake

Read `docs/asset-policy.md` and the `quake-port` skill for QuakeSpasm/package
work. Preserve the user-owned commercial asset boundary.

## Workflow

1. Check asset state before launching Quake.
2. Keep wrapper changes in repo-owned scripts or package assets.
3. Verify game launch with engine logs and smoke tests.
4. Escalate Wayland/window/focus issues to `admin-shell` and generic build
   failures to `compiler`.

## Commands

```bash
eos-assets check quake
eos-game quake play --smoke
eos-logs engine --last 200
eos-test assets
```
