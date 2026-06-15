project(
  'engineos-cube',
  'c',
  version: '0.1.0',
  default_options: [
    'buildtype=debugoptimized',
    'c_std=c11',
    'warning_level=2',
  ],
)

cc = meson.get_compiler('c')

sdl2_dep = dependency('sdl2', required: true)
glesv2_dep = dependency('glesv2', required: true)
math_dep = cc.find_library('m', required: true)

executable(
  'engineos-cube',
  'src/engineos-cube.c',
  dependencies: [
    sdl2_dep,
    glesv2_dep,
    math_dep,
  ],
  install: true,
)
