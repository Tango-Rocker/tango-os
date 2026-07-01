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
    xdg_shell_protocol_header,
    pointer_constraints_protocol_header,
  ],
  c_args: ['-DWLR_USE_UNSTABLE'],
  dependencies: [
    wlroots_dep,
    wayland_server_dep,
    xkbcommon_dep,
  ],
  install: true,
)
