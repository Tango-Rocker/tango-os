project(
  'engineos-chatgpt',
  'c',
  version: '0.1.0',
  default_options: [
    'buildtype=debugoptimized',
    'c_std=c11',
    'warning_level=3',
    'werror=true',
  ],
)

wpe_webkit_dep = dependency('wpe-webkit-2.0', version: '>=2.44', required: true)
wpe_platform_dep = dependency('wpe-platform-2.0', version: '>=2.0', required: true)
libcap_dep = dependency('libcap', required: true)

chatgpt = executable(
  'engineos-chatgpt',
  'src/engineos-chatgpt.c',
  dependencies: [
    wpe_webkit_dep,
    wpe_platform_dep,
    libcap_dep,
  ],
  install: true,
)

test('uri-policy', chatgpt, args: ['--self-test'])
