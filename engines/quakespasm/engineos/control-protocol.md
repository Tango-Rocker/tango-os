# QuakeSpasm Launch Contract

Quake is owned by the per-user `engineos-quake.service`; there is no persistent
root engine daemon or private engine socket.

`eos-game quake play` writes a mode-`0600` JSON request under the user's
EngineOS runtime directory and restarts the user unit. The request schema is
`engineos-quake-launch/v1` and accepts only:

- `map` and `game`: safe Quake names
- `smoke`: boolean
- `window` and `fullscreen`: mutually exclusive booleans
- `id1`: resolved user-owned asset directory

`/usr/lib/engineos/game/engineos-quake-service` validates the request,
constructs the runner arguments, keeps only the required graphical-session
environment, and execs `/usr/share/engineos/quake/run.sh`. Malformed requests
fail before Quake starts.

Use:

```bash
eos-game quake play
eos-game quake status
eos-game quake stop
eos-game quake proof
```

Build QuakeSpasm from source with:

```bash
eos-build engine quake --dry-run
eos-build engine quake --fetch
```

The default upstream mirror is `https://github.com/sezero/quakespasm.git`.
EngineOS builds from the upstream `Quake` directory with SDL2 enabled.
