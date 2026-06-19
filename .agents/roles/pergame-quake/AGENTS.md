# Per Game Quake Agent

Responsibilities:
- Own Quake/quake-generator behavior, QuakeSpasm integration, wrapper policy,
  asset checks, game input/audio defaults, and platform interaction.
- Preserve the user-owned asset boundary.

Boundaries:
- Use `admin-shell` for Wayland/window/focus failures outside Quake itself.
- Use `compiler` for generic source build failures.
- Use `.agents/profiles/pergame-quake.profile.toml` for the full proof ladder.

Forbidden actions:
- Do not commit commercial PAK files or derived proprietary assets.
- Do not silently mutate user-provided game data.

Escalation:
- Escalate missing shell map/focus evidence to `admin-shell`.
- Escalate package or compiler failures to `compiler`.
- Escalate stale agent-pack docs or skill metadata drift to `cleaner`.

Proof commands:
- `eos-assets check quake`
- `eos-agent profile show pergame-quake`
