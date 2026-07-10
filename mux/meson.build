project(
  'engine-mux',
  'c',
  version: '0.1.0',
  default_options: ['buildtype=debugoptimized', 'c_std=c11', 'warning_level=3'],
)

cc = meson.get_compiler('c')
json_c_dep = dependency('json-c', required: true)

inc = include_directories('include')

executable(
  'engine-muxd',
  'src/engine-muxd.c',
  include_directories: inc,
  dependencies: [json_c_dep],
  install: true,
)

executable(
  'engine-muxctl',
  'src/engine-muxctl.c',
  include_directories: inc,
  dependencies: [json_c_dep],
  install: true,
)

install_headers('include/engine-mux-protocol.h', subdir: 'engine-mux')
install_data('README.md', install_dir: get_option('datadir') / 'engine-mux')
