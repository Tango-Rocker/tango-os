project(
  'engineos-shell',
  'c',
  version: '0.1.0',
  default_options: [
    'buildtype=debugoptimized',
    'c_std=c11',
    'warning_level=2',
  ],
)

cc = meson.get_compiler('c')

wlroots_dep = dependency('wlroots-0.19', required: false)
if not wlroots_dep.found()
  wlroots_dep = dependency('wlroots-0.18', required: false)
endif
if not wlroots_dep.found()
  wlroots_dep = dependency('wlroots', required: true)
endif

wayland_server_dep = dependency('wayland-server', required: true)
wayland_protocols_dep = dependency('wayland-protocols', required: true)
wayland_scanner_dep = dependency('wayland-scanner', required: true)
xkbcommon_dep = dependency('xkbcommon', required: true)
libpng_dep = dependency('libpng', required: true)
libjpeg_dep = dependency('libjpeg', required: true)
json_c_dep = dependency('json-c', required: true)
fcft_dep = dependency('fcft', required: true)
pixman_dep = dependency('pixman-1', required: true)
mux_inc = include_directories('../mux/include')

wayland_scanner = find_program(
  wayland_scanner_dep.get_variable(pkgconfig: 'wayland_scanner'),
  required: true,
)
xdg_shell_xml = wayland_protocols_dep.get_variable(pkgconfig: 'pkgdatadir') / 'stable/xdg-shell/xdg-shell.xml'
xdg_shell_protocol_header = custom_target(
  'xdg-shell-protocol-header',
  input: xdg_shell_xml,
  output: 'xdg-shell-protocol.h',
  command: [wayland_scanner, 'server-header', '@INPUT@', '@OUTPUT@'],
)
pointer_constraints_xml = wayland_protocols_dep.get_variable(pkgconfig: 'pkgdatadir') / 'unstable/pointer-constraints/pointer-constraints-unstable-v1.xml'
pointer_constraints_protocol_header = custom_target(
  'pointer-constraints-protocol-header',
  input: pointer_constraints_xml,
  output: 'pointer-constraints-unstable-v1-protocol.h',
  command: [wayland_scanner, 'server-header', '@INPUT@', '@OUTPUT@'],
)

executable(
  'engineos-shell',
  [
    'src/engineos-shell.c',
    'src/engineos-image.c',
    'src/engineos-mux-client.c',
    'src/engineos-terminal-renderer.c',
    'src/engineos-terminal-theme.c',
    'src/engineos-tmux-key.c',
    xdg_shell_protocol_header,
    pointer_constraints_protocol_header,
  ],
  c_args: ['-DWLR_USE_UNSTABLE'],
  include_directories: [mux_inc],
  dependencies: [
    wlroots_dep,
    wayland_server_dep,
    xkbcommon_dep,
    libpng_dep,
    libjpeg_dep,
    json_c_dep,
    fcft_dep,
    pixman_dep,
  ],
  install: true,
)

tmux_key_test = executable(
  'engineos-tmux-key-test',
  [
    'tests/tmux-key-name.c',
    'src/engineos-tmux-key.c',
  ],
  c_args: ['-DWLR_USE_UNSTABLE'],
  include_directories: [include_directories('src')],
  dependencies: [wlroots_dep, xkbcommon_dep],
)
test('tmux-key-name', tmux_key_test)

terminal_theme_test = executable(
  'engineos-terminal-theme-test',
  [
    'tests/terminal-theme.c',
    'src/engineos-terminal-theme.c',
  ],
  include_directories: [include_directories('src')],
  dependencies: [json_c_dep],
)
test('terminal-theme', terminal_theme_test)

install_subdir(
  'themes',
  install_dir: get_option('datadir') / 'engineos-shell',
)

mux_client_pane_race_test = executable(
  'engineos-mux-client-pane-race-test',
  [
    'tests/mux-client-pane-race.c',
    'src/engineos-mux-client.c',
  ],
  include_directories: [include_directories('src'), mux_inc],
  dependencies: [json_c_dep],
)
