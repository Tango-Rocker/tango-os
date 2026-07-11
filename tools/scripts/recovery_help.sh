#!/usr/bin/env bash
set -euo pipefail

cat <<'HELP'
EngineOS recovery

Useful commands:
  eos-logs shell --last 200
  eos-logs runtime --last 200
  eos-logs engine --last 200
  eos-doctor --bare-metal
  eos-crash-bundle --bare-metal

Disable EngineDev shell autostart for the next boot with:
  engineos.nodevshell

Disable EngineRuntime autostart for the next boot with:
  engineos.noautostart

Recovery TTY:
  tty2 remains available while the graphical shell owns tty1.
HELP
