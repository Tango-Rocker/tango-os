# EngineOS Cube

`engineos-cube` is the first custom EngineOS graphical app. It is a small
SDL2/Wayland OpenGL ES client that renders a rotating cube and logs renderer
evidence for launchpad proofs.

Expected entry points:

```bash
engineos-cube
engineos-cube --smoke
engineos app launch cube
```

The app intentionally remains a normal Wayland client. The EngineOS shell owns
launching, focus, fullscreen slot visibility, and input routing.
