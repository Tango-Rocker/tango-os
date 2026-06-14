# QuakeSpasm Control Protocol

This is a placeholder for the first EngineOS engine control protocol.

Initial commands:

- `engine.status`
- `engine.launch quake`
- `engine.quit`
- `engine.restart`

Initial log streams:

- stdout
- stderr
- lifecycle events

The first implementation can be a shell wrapper. Move to the engine runner socket protocol after the launch and log behavior is stable.

## Current Build Commands

```bash
engineos build engine quake --dry-run
engineos build engine quake --fetch
```

The default upstream mirror is `https://github.com/sezero/quakespasm.git`. QuakeSpasm's upstream Linux instructions build from the `Quake` subdirectory with `make`; EngineOS uses `make -C upstream/Quake USE_SDL2=1`.
