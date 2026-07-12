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
./tools/engineos/eos-doctor
./tools/engineos/eos-test render --smoke
./tools/engineos/eos-capture frame --target shell
```

In a live native-mux proof:

```bash
eos-logs app --last 200
eos-logs shell --last 200
eos-proof native-kms
```

Expected renderer evidence includes the hardware renderer, a committed nonblank
shell frame, and no silent software fallback.
