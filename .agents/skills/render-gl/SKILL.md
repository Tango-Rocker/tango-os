# Render GL Skill

## When To Use

Use this skill for OpenGL renderer checks, frame capture work, and VM graphics diagnostics.

## Commands To Run

```bash
./tools/engineos/engineos doctor --vm
glxinfo -B
vulkaninfo --summary
```

Future commands:

```bash
engineos capture frame --target shell
engineos test render --smoke
```

## Files That Matter

```text
tools/engineos/engineos
docs/architecture.md
shell/
engines/quakespasm/
```

## Known Traps

- llvmpipe is acceptable for some VM smoke tests but not final graphics validation.
- Real AMD Mesa behavior must be checked on bare metal.
- Avoid blocking early work on virtual GPU limitations.

## Expected Output

Diagnostics should identify the renderer, Vulkan device summary when available, and whether software rendering is in use.

## Recovery Steps

If GL tools are missing, install `mesa-utils` and `vulkan-tools` in the builder or test environment.

