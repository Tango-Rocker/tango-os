# Architecture

EngineOS is developed and proven on the live bare-metal EngineDev installation.
The source checkout, local package repository, installed packages, and running
shell are one controlled development loop. Generated ISO and VM paths remain
legacy references and are not part of routine acceptance.

```text
Git checkout on EngineDev
  -> eos dev plan/apply selects changed packages and local dependencies
  -> makepkg builds packages into repo/x86_64
  -> one pacman transaction updates the live install
  -> runtime refresh installs managed user helpers
  -> shell restart replaces engineos-shell without replacing tmux sessions
  -> eos-test/eos-proof validate source, package, and live behavior
```

## Ownership Layers

### Source And Packages

The repository is the source of truth. Persistent OS behavior belongs in
`packages/`, `shell/`, `tools/`, or tracked systemd/config payloads. Generated
package artifacts and runtime logs are evidence, not source.

`eos dev plan --range BASE..HEAD` maps committed files to packages, adds local
dependencies, and prints the deployment set. `eos dev apply` runs the real
preflight, tests, package build, install, cleanup, user refresh, and required
shell restart. The pre-push hook performs the same committed-range operation
and blocks publication when deployment fails.

### Shell And Applications

`engineos-shell` owns the Wayland display, outputs, scene graph, input focus,
app surfaces, image overlays, and pane-bound GUI rendering. Applications enter
the shell through `eos-app`; they do not discover compositor sockets or place
their own top-level windows outside the shell contract.

The app manifest defines terminal, secondary terminal, cube, and Quake slots.
Ordinary desktop applications can remain floating for diagnostics, while the
normal tmux-integrated GUI path is explicit:

```bash
eos-app pane launch -- COMMAND [ARGS...]
eos-app pane launch --game -- COMMAND [ARGS...]
eos-app pane view toggle
```

Native mode routes these wrappers to `engine-mux`, whose transient user scope
is the authoritative surface-to-pane identity. The compositor accepts only
clients in that scope and clips them beneath the pane's leased output scene.
Game presentations use the same identity while enabling direct Wayland input
and capture. Explicit legacy mode retains the one-shot-token bridge only until
native live acceptance.

### Tmux Pane Bridge

There is one tmux server with multiple sessions and clients. Managed terminals
register their real tty and output slot before attaching. Tmux hooks call
`engineos-tmux-pane-bridge` on focus and geometry changes; the bridge sends
exact socket, session, window, pane, client-tty, and geometry data to the shell.

The shell is authoritative for GUI bindings. Tmux options, titles, commands,
proxy tabs, and periodic polling are not binding sources. Shell restarts attach
the primary terminal to an existing session before creating a fallback and
reserve `engineos-side` for the secondary terminal.

MC image previews use the same pane and client-tty identity. Ambiguous or stale
ownership is an error rather than a guessed output.

### Native graphical mux migration

The bridge is the deployed path while the native tmux frontend is developed
side by side. [graphical-tmux.md](graphical-tmux.md) defines the compound
console/presentation model and records the implemented protocol foundation.
Selecting `engineos-shell --mux native` is explicit and fail-closed; it does
not make the current bridge evidence count as native mux acceptance. Native
pane images are compositor scene objects keyed by pane ID, generation, and the
tmux-owned client-view lease. Multiple panes may retain images concurrently;
an image is never reassigned from whichever pane happens to be focused. Each
graphical output's synthetic tmux client also has a view-addressed snapshot;
the server never substitutes another output's globally focused session.

### Quake Development

Quake uses the `eos-game quake` command surface and two per-user services:

- `engineos-level-agent.service` owns level-generation jobs.
- `engineos-quake.service` owns the current QuakeSpasm process.

The retired engine-runner package is not part of the architecture. Dgen is
built from an exact local `quake-generator` commit, and commercial Quake assets
remain user-owned outside the repository.

### Agent Harness

`AGENTS.md`, `.agents/index.toml`, role docs, and skills provide routing and
workflow policy. Direct `eos-*` commands remain the execution surface. The
harness does not maintain generated profiles, dispatch queues, or wrapper
copies.

The `codex-extractor` checkout provides `codex-insights 0.2.0`; reviews use
`gpt-5.6-luna` with medium reasoning. The autonomy gate pins that release and
fails closed when extraction fails, times out, or returns an incompatible
contract.

## Runtime State And Evidence

Primary state and evidence paths are:

```text
/run/user/1000/engineos/shell-state.json
/run/user/1000/engineos/preview.sock
/var/log/engineos/
repo/x86_64/
```

State files and sockets are same-user/private. Proof commands must validate
real markers and artifacts; dry runs and metadata-only captures are diagnostic
unless a command explicitly defines them as acceptance.

## Legacy Image Lab

`archiso/`, VM helpers, Hyper-V documents, and `/srv/engineos` builder guidance
record the earlier image lab. They can be re-enabled deliberately for future
appliance-image work, but they must not be selected by routine development,
deployment, proof, or agent routing.
