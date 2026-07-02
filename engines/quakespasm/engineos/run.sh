#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "${SCRIPT_PATH%/*}" && pwd -P)"
ROOT="${ENGINEOS_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd -P)}"
if [[ "$ROOT" != /usr && "$ROOT" != /usr/* && -d "$ROOT/tools/scripts" ]]; then
  LOG_DIR="${ENGINEOS_LOG_DIR:-$ROOT/artifacts/logs}"
else
  LOG_DIR="${ENGINEOS_LOG_DIR:-/var/log/engineos}"
fi
UPSTREAM="${QUAKESPASM_UPSTREAM_DIR:-$ROOT/engines/quakespasm/upstream}"
BUILT_BIN="$UPSTREAM/Quake/quakespasm"
BIN=""
BIN_SOURCE=""
SMOKE=false
ID1_PATH=""
QUAKE_ARGS=()
CLI_QUAKE_ARGS=()
CHILD_PID=""

ASSETS="$ROOT/tools/scripts/assets.sh"
if [[ "$ROOT" == /usr || "$ROOT" == /usr/* || ! -x "$ASSETS" ]]; then
  ASSETS="/usr/lib/engineos/scripts/assets.sh"
fi

load_quake_config() {
  local config
  local env_quake_id1="${ENGINEOS_QUAKE_ID1-}"
  local env_quake_id1_default="${ENGINEOS_QUAKE_ID1_DEFAULT-}"
  local env_quake_sdl_audiodriver="${ENGINEOS_QUAKE_SDL_AUDIODRIVER-}"
  local env_quake_args="${ENGINEOS_QUAKE_ARGS-}"
  for config in /etc/engineos/quake.conf "${HOME:-}/.config/engineos/quake.conf"; do
    if [[ -r "$config" ]]; then
      # shellcheck disable=SC1090
      source "$config"
    fi
  done
  if [[ -n "$env_quake_id1" ]]; then
    ENGINEOS_QUAKE_ID1="$env_quake_id1"
  fi
  if [[ -n "$env_quake_id1_default" ]]; then
    ENGINEOS_QUAKE_ID1_DEFAULT="$env_quake_id1_default"
  fi
  if [[ -n "$env_quake_sdl_audiodriver" ]]; then
    ENGINEOS_QUAKE_SDL_AUDIODRIVER="$env_quake_sdl_audiodriver"
  fi
  if [[ -n "$env_quake_args" ]]; then
    ENGINEOS_QUAKE_ARGS="$env_quake_args"
  fi
}

append_configured_quake_args() {
  if [[ -n "${ENGINEOS_QUAKE_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    QUAKE_ARGS+=($ENGINEOS_QUAKE_ARGS)
  fi
}

append_cli_quake_args() {
  if [[ "${#CLI_QUAKE_ARGS[@]}" -gt 0 ]]; then
    QUAKE_ARGS+=("${CLI_QUAKE_ARGS[@]}")
  fi
}

restore_text_console() {
  [[ -t 0 || -t 1 ]] || return 0

  case "${XDG_SESSION_TYPE:-}" in
    tty|"")
      ;;
    *)
      return 0
      ;;
  esac

  if [[ -w /dev/tty ]]; then
    TERM=linux setterm -reset -clear all >/dev/tty 2>/dev/null || true
    printf '\033c' >/dev/tty 2>/dev/null || true
  fi
  if command -v kbd_mode >/dev/null 2>&1 && [[ -r /dev/tty ]]; then
    kbd_mode -a </dev/tty >/dev/null 2>&1 || true
  fi
  if command -v setfont >/dev/null 2>&1 && [[ -r /dev/tty ]]; then
    setfont </dev/tty >/dev/null 2>&1 || true
  fi
}

terminate_child() {
  if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" >/dev/null 2>&1; then
    kill "$CHILD_PID" >/dev/null 2>&1 || true
    wait "$CHILD_PID" >/dev/null 2>&1 || true
  fi
  CHILD_PID=""
}

handle_signal() {
  local status="$1"
  terminate_child
  restore_text_console
  exit "$status"
}

trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM HUP

ensure_quake_defaults() {
  local id1_dir="$1"
  local autoexec="$id1_dir/autoexec.cfg"

  if [[ -e "$autoexec" ]]; then
    return
  fi

  cat >"$autoexec" <<'EOF'
// EngineOS default Quake controls. This file is only created when missing.
bind "w" "+forward"
bind "s" "+back"
bind "a" "+moveleft"
bind "d" "+moveright"
bind "SPACE" "+jump"
bind "MOUSE1" "+attack"
bind "MOUSE2" "+jump"
bind "MOUSE3" "+mlook"
bind "SHIFT" "+speed"
bind "CTRL" "+attack"
bind "q" "impulse 10"
bind "e" "+mlook"
bind "TAB" "+showscores"
bind "`" "toggleconsole"
bind "~" "toggleconsole"
lookspring "0"
lookstrafe "0"
cl_alwaysrun "1"
sensitivity "3"
+mlook
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke)
      SMOKE=true
      ;;
    --help|-h)
      cat <<'HELP'
Usage: run.sh [--smoke] [--window|--fullscreen] [--width N] [--height N]

Run QuakeSpasm through the EngineOS wrapper.

Environment:
  QUAKESPASM_BIN          explicit binary or command override
  QUAKESPASM_UPSTREAM_DIR upstream source/build directory
  ENGINEOS_QUAKE_ARGS     extra QuakeSpasm arguments from config/env
HELP
      exit 0
      ;;
    --window)
      CLI_QUAKE_ARGS+=("-window")
      ;;
    --fullscreen)
      CLI_QUAKE_ARGS+=("-fullscreen")
      ;;
    --width)
      shift
      [[ -n "${1:-}" && "$1" =~ ^[0-9]+$ ]] || {
        printf 'quakespasm run: --width expects a positive integer\n' >&2
        exit 2
      }
      CLI_QUAKE_ARGS+=("-width" "$1")
      ;;
    --height)
      shift
      [[ -n "${1:-}" && "$1" =~ ^[0-9]+$ ]] || {
        printf 'quakespasm run: --height expects a positive integer\n' >&2
        exit 2
      }
      CLI_QUAKE_ARGS+=("-height" "$1")
      ;;
    *)
      printf 'quakespasm run: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

mkdir -p "$LOG_DIR"

log_stream() {
  if [[ "${ENGINEOS_LOG_TEE:-true}" == "false" ]]; then
    cat >>"$LOG_DIR/engine.log"
  else
    tee -a "$LOG_DIR/engine.log"
  fi
}

binary_available() {
  local candidate="$1"
  if [[ "$candidate" == */* ]]; then
    [[ -x "$candidate" ]]
  else
    command -v "$candidate" >/dev/null 2>&1
  fi
}

resolve_binary() {
  if [[ -n "${QUAKESPASM_BIN:-}" ]]; then
    BIN="$QUAKESPASM_BIN"
    BIN_SOURCE="override"
  elif command -v quakespasm >/dev/null 2>&1; then
    BIN="$(command -v quakespasm)"
    BIN_SOURCE="path"
  elif [[ -x "$BUILT_BIN" ]]; then
    BIN="$BUILT_BIN"
    BIN_SOURCE="upstream"
  else
    BIN="quakespasm"
    BIN_SOURCE="missing"
  fi
}

resolve_binary
load_quake_config
append_configured_quake_args
append_cli_quake_args

if [[ -n "${ENGINEOS_QUAKE_SDL_AUDIODRIVER:-}" && -z "${SDL_AUDIODRIVER:-}" ]]; then
  export SDL_AUDIODRIVER="$ENGINEOS_QUAKE_SDL_AUDIODRIVER"
fi
if [[ -n "${WAYLAND_DISPLAY:-}" && -z "${SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR:-}" ]]; then
  export SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR=0
fi

if [[ "$SMOKE" == true ]]; then
  {
    printf 'QuakeSpasm smoke wrapper\n'
    printf 'binary=%s\n' "$BIN"
    printf 'binary_source=%s\n' "$BIN_SOURCE"
    printf 'upstream_binary=%s\n' "$BUILT_BIN"
    if binary_available "$BIN"; then
      printf 'binary_status=available\n'
      printf 'result=ok\n'
    else
      printf 'binary_status=missing\n'
      printf 'result=failed\n'
    fi
  } | log_stream
  binary_available "$BIN"
  exit 0
fi

if ! binary_available "$BIN"; then
  printf 'QuakeSpasm binary not found: %s\n' "$BIN" | log_stream >&2
  printf 'Looked for: QUAKESPASM_BIN override, quakespasm on PATH, %s\n' "$BUILT_BIN" | log_stream >&2
  exit 1
fi

if [[ -x "$ASSETS" ]]; then
  "$ASSETS" check quake | log_stream
  ID1_PATH="$("$ASSETS" path quake)"
else
  printf 'Asset checker not found: %s\n' "$ASSETS" | log_stream >&2
  exit 1
fi

BASE_DIR="$(cd "$ID1_PATH/.." && pwd -P)"
ensure_quake_defaults "$ID1_PATH"
printf 'QuakeSpasm binary=%s source=%s\n' "$BIN" "$BIN_SOURCE" | log_stream
printf 'QuakeSpasm basedir=%s\n' "$BASE_DIR" | log_stream
printf 'QuakeSpasm audio_driver=%s\n' "${SDL_AUDIODRIVER:-auto}" | log_stream
printf 'QuakeSpasm video_driver=%s wayland_display=%s gl_integration=sdl2-client compositor=engineos-shell\n' \
  "${SDL_VIDEODRIVER:-auto}" "${WAYLAND_DISPLAY:-missing}" | log_stream
if [[ "${#QUAKE_ARGS[@]}" -gt 0 ]]; then
  printf 'QuakeSpasm configured_args=%s\n' "${QUAKE_ARGS[*]}" | log_stream
fi
"$BIN" -basedir "$BASE_DIR" "${QUAKE_ARGS[@]}" &
CHILD_PID="$!"
wait "$CHILD_PID"
status="$?"
CHILD_PID=""
restore_text_console
exit "$status"
