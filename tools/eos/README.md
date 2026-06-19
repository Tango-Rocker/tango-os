# EngineOS Tool Domains

`tools/eos` holds implementation modules for the public `eos-*` commands.
`tools/scripts` remains as a compatibility shim layer and shared helper home.

Domain boundaries:

- `builder/`: Arch builder VM bootstrap, handoff, and builder-to-guest proof orchestration.
- `vm/`: local VM boot helpers and VM-only host automation.
- `os-dev/`: actions against an already booted or installed EngineDev development OS.
- `bare-metal/`: destructive or hardware-facing install, USB, and Secure Boot workflows.
- `proof/`: proof runners and boot validation routers that cross environment modes.
- `test/`: local harness entrypoints and smoke tests.

Bare-metal modules must stay behind explicit dry-run or confirmation gates.
VM, builder, and OS-dev modules should not call bare-metal modules except through
documented proof dry-runs.
