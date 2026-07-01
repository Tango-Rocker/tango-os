# EngineOS Cube

`engineos-cube` is the first custom EngineOS graphical app. It is a small
SDL2/Wayland OpenGL ES client that renders a rotating cube and logs renderer
evidence for launchpad proofs.

Expected entry points:

```bash
engineos-cube
engineos-cube --smoke
eos-app launch cube
eos-app launch cube --smoke --smoke-ms 3000
```

The app intentionally remains a normal Wayland client. The EngineOS shell owns
launching, focus, fullscreen slot visibility, and input routing.

When launched through `eos-app launch cube` from inside tmux, the launcher
writes the current pane geometry to the shell's launch-bounds state. The shell
then sizes the cube to the matching output sub-rectangle. `engineos-cube` logs
the negotiated `window_size` and `drawable_size` in `cube.log` so panel-bounds
proofs can compare requested tmux geometry, shell layout, and client drawable
size.
