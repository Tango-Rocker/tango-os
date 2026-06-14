# Agent Workflow

The `engineos` CLI is the control surface for humans and agents. MCP wrappers should call known CLI commands later instead of exposing arbitrary shell access first.

## Default Loop

```bash
./tools/engineos/engineos doctor --mock
./tools/engineos/engineos bootstrap builder --dry-run
./tools/engineos/engineos validate builder --mock
./tools/engineos/engineos validate repo --dry-run
./tools/engineos/engineos proof build-lab --dry-run
./tools/engineos/engineos test vm
./tools/engineos/engineos build repo --dry-run
./tools/engineos/engineos build iso --dry-run
./tools/engineos/engineos test
```

On the Arch builder VM, replace dry-runs with real builds after package definitions are ready:

```bash
./tools/engineos/engineos bootstrap builder
./tools/engineos/engineos validate builder
./tools/engineos/engineos proof build-lab
./tools/engineos/engineos vm boot enginedev
```

## Status Discipline

When work changes build behavior, update `CURRENT_STATUS.md` with:

- what now works
- what is still blocked
- the next command to run

## MCP Direction

Future MCP servers should wrap these commands:

```text
engineos build repo
engineos build iso <profile>
engineos bootstrap builder
engineos validate builder
engineos validate repo
engineos proof build-lab
engineos proof booted-iso --vm
engineos vm boot <profile>
engineos test [scope]
engineos logs <unit>
engineos crash-bundle [--vm|--runtime|--bare-metal]
engineos doctor
```

CLI first. MCP wrappers later.
