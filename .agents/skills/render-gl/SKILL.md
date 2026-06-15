---
name: render-gl
description: Use for OpenGL renderer changes, frame capture, cube renderer evidence, Mesa/Vulkan diagnostics, shell visible-frame checks, or future renderer boundary work.
---

# Render GL Skill

OpenGL/Mesa is the current proof path. VM software rendering is useful smoke
evidence but does not replace bare-metal AMD validation.

## Rules

- Keep raw GL work behind renderer/backend files.
- Prefer simple visible frame evidence before visual polish.
- Record renderer name/version and whether software rendering is in use.
- Do not block early proofs on virtual GPU limitations.

## Checks

```bash
./tools/engineos/engineos doctor --mock
./tools/engineos/engineos test render --smoke
./tools/engineos/engineos capture frame --target shell
./tools/engineos/engineos proof launchpad --runtime --dry-run
```

In a booted Runtime proof:

```bash
engineos logs app --last 200
engineos logs shell --last 200
engineos proof launchpad --runtime
```

Expected Runtime evidence includes cube log `gl_renderer=` and `frames=`.
