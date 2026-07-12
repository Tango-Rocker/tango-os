---
name: engine-builder
description: Build EngineOS/Tango-OS scenes, demos, game loops, renderer checks, and visual runtime proofs. Use for 3D scene work, game prototypes, renderer evidence, and engine platform capabilities outside Quake-specific ownership.
---

# Engine Builder

Ground visual work in the native tmux pane-presentation workflow and renderer
evidence. Do not start polish-heavy cockpit work before the MVP path asks for it.

## Workflow

1. Identify the runtime surface: mux console, Wayland presentation, or game pane.
2. Add the smallest scene or renderer proof that can be captured.
3. Verify with frame/log evidence, not only process startup.
4. Escalate compositor ownership to `admin-shell` and Quake-specific work to
   `pergame-quake`.

## Commands

```bash
eos-capture frame --target shell
eos-test render --smoke
eos-test shell
eos-app manifest validate
```
