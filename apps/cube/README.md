# EngineOS Cube

`engineos-cube` is the first custom EngineOS graphical app. It is a small
SDL2/Wayland OpenGL ES client that renders a rotating cube and logs renderer
evidence for pane-presentation proofs.

Expected entry points:

```bash
engineos-cube
engineos-cube --smoke
eos-app launch cube
eos-app launch cube --smoke --smoke-ms 3000
```

The app intentionally remains a normal Wayland client. Tmux launches it in a
pane scope; the EngineOS shell owns composition, clipping, focus, and input.

When launched through `eos-app launch cube`, tmux supplies authoritative pane
geometry over the frontend protocol and the shell clips the surface to its pane
scene. `engineos-cube` logs the negotiated `window_size` and `drawable_size` in
`cube.log` for presentation-size proof.
