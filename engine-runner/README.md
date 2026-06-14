# Engine Runner

The engine runner manages game process lifecycle through a Unix domain socket.

Current CLI:

```bash
engineos engine status
engineos engine launch quake --smoke
engineos engine quit
engineos engine restart quake --smoke
engineos logs engine --last 200
```

Current socket protocol:

- `engine.status`
- `engine.launch`
- `engine.quit`
- `engine.restart`
- stdout and stderr capture
- predictable log paths
- selected display/session environment forwarding on launch and restart

Implementation:

- CLI wrapper: `tools/scripts/engine_runner.sh`
- Unix socket daemon: `tools/scripts/engine_runner_daemon.py`
- packaged systemd unit: `engineos-engine-runner.service`
- default source-tree socket: `artifacts/run/engine-runner.sock`
- installed socket: `${XDG_RUNTIME_DIR:-/tmp}/engineos/engine-runner.sock`
- runtime service socket: `/run/engineos/engine-runner.sock`

The runtime systemd path keeps the daemon alive separately from the shell, but
launch requests still forward environment such as `WAYLAND_DISPLAY`,
`DISPLAY`, `XDG_RUNTIME_DIR`, and `DBUS_SESSION_BUS_ADDRESS` so game clients
can attach to the compositor that requested the launch.

MCP wrappers should call the `engineos engine ...` CLI surface instead of talking to the socket directly until the protocol stabilizes.
