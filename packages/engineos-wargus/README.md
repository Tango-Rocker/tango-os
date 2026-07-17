# EngineOS Wargus Adapter

This package contains only the `engineos-wargus` launch adapter. It does not
contain the Stratagus engine, Warcraft II data, extracted graphics, audio,
maps, campaigns, or other commercial assets.

By default the adapter delegates to the repo-owned
`/home/dev/wargus/launch-linux.sh`. Set `ENGINEOS_WARGUS_LAUNCHER` to an
alternate executable path when the Wargus checkout lives elsewhere. All
arguments are passed through unchanged, and a missing launcher is a hard
failure.

The persistent EngineOS entry is launched with:

```sh
eos-app launch wargus
```

Run the deterministic first-Horde-mission acceptance smoke with:

```sh
eos-app launch wargus --smoke
```

The adapter expands `--smoke` to the repository-owned rapid/windowed launch
of `tools/eos-gameplay-smoke.lua`. The smoke fails when the checkout does not
contain the user's locally extracted campaign data.
