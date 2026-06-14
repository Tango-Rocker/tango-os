# Asset Policy

EngineOS can include generated and redistributable assets. It must not include commercial game data by default.

## Allowed

- generated test maps or placeholder assets with clear redistributable licensing
- upstream assets whose license permits redistribution
- local metadata describing where user-provided assets should be placed

## Not Allowed

- commercial Quake `pak` files
- assets copied from installed games without redistribution rights
- unclear sample media

## Manifest Rule

Engine ports should describe assets in a manifest:

```toml
[[asset]]
name = "generated-test-map"
source = "generated"
license = "CC0"
redistributable = true
allowed_in_iso = true

[[asset]]
name = "id1/pak0.pak"
source = "user-provided"
license = "commercial"
redistributable = false
allowed_in_iso = false
```

## Current Commands

```bash
engineos assets explain quake
engineos assets prepare quake
engineos assets check quake
engineos assets path quake
```

`engineos assets prepare quake` creates the default user directory:

```text
~/.local/share/engineos/quake/id1
```

`engineos assets check quake` looks for `id1/pak0.pak` in the documented user-provided paths or in `ENGINEOS_QUAKE_ID1`. `engineos assets path quake` prints the resolved `id1` directory when assets are present.

System-local assets may be placed under:

```text
/var/lib/engineos/assets/quake/id1
```

The packaged config file `/etc/engineos/quake.conf` documents the system-local default. User or environment overrides may set:

```bash
ENGINEOS_QUAKE_ID1=/path/to/id1
```
