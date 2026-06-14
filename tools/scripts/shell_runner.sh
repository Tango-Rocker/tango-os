#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"

if [[ -r /etc/engineos/profile.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/engineos/profile.conf
fi

if engineos_is_source_root "$ROOT"; then
  LOG_DIR="${ENGINEOS_LOG_DIR:-$(engineos_default_log_dir "$ROOT")}"
else
  LOG_DIR="${ENGINEOS_LOG_DIR:-$(engineos_default_log_dir "$ROOT")}"
fi

MODE="${1:-help}"
SHELL_BIN="${ENGINEOS_SHELL_BIN:-engineos-shell}"
LOG_FILE="$LOG_DIR/shell.log"

engineos_cmd_string() {
  if [[ -x "$ROOT/tools/engineos/engineos" ]]; then
    printf '%q' "$ROOT/tools/engineos/engineos"
  else
    printf 'engineos'
  fi
}

ENGINEOS_CMD_STRING="$(engineos_cmd_string)"
DEFAULT_TERMINAL="${ENGINEOS_TERMINAL_CMD:-$ENGINEOS_CMD_STRING terminal}"
DEFAULT_ENGINE="${ENGINEOS_ENGINE_CMD:-$ENGINEOS_CMD_STRING engine launch quake --smoke}"

usage() {
  cat <<'HELP'
Usage: shell_runner.sh --headless
       shell_runner.sh --nested
       shell_runner.sh --tty

Run the EngineOS shell path. Headless and nested can smoke locally. TTY is
the Runtime graphical entry point and bootstraps terminal plus engine by
default when the real shell binary is installed.
HELP
}

log_line() {
  mkdir -p "$LOG_DIR"
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE"
}

run_real_shell_if_available() {
  local mode="$1"
  local smoke_args=()
  local startup_args=()
  local launch_args=()
  local bootstrap_args=()
  if [[ "${ENGINEOS_SHELL_SMOKE:-false}" == "true" ]]; then
    smoke_args+=(--smoke)
  fi
  launch_args+=(--terminal "$DEFAULT_TERMINAL")
  launch_args+=(--engine "$DEFAULT_ENGINE")
  if [[ -n "${ENGINEOS_SHELL_STARTUP:-}" ]]; then
    startup_args+=(--startup "$ENGINEOS_SHELL_STARTUP")
  elif [[ -z "${ENGINEOS_SHELL_BOOTSTRAP:-}" && "$mode" == "nested" && "${ENGINEOS_SHELL_AUTO_STARTUP:-true}" == "true" ]]; then
    startup_args+=(--startup "$DEFAULT_TERMINAL")
  fi
  if [[ -n "${ENGINEOS_SHELL_BOOTSTRAP:-}" ]]; then
    bootstrap_args+=(--bootstrap "$ENGINEOS_SHELL_BOOTSTRAP")
  elif [[ "$mode" == "tty" ]]; then
    bootstrap_args+=(--bootstrap all)
  fi

  if command -v "$SHELL_BIN" >/dev/null 2>&1; then
    log_line "shell binary found: $SHELL_BIN mode=$mode"
    case "$mode" in
      headless)
        WLR_BACKENDS="${WLR_BACKENDS:-headless}" WLR_HEADLESS_OUTPUTS="${WLR_HEADLESS_OUTPUTS:-1}" exec "$SHELL_BIN" --headless "${smoke_args[@]}" "${startup_args[@]}" "${launch_args[@]}" "${bootstrap_args[@]}"
        ;;
      nested)
        exec "$SHELL_BIN" --nested "${smoke_args[@]}" "${startup_args[@]}" "${launch_args[@]}" "${bootstrap_args[@]}"
        ;;
      tty)
        exec "$SHELL_BIN" --tty "${smoke_args[@]}" "${startup_args[@]}" "${launch_args[@]}" "${bootstrap_args[@]}"
        ;;
    esac
  fi
  return 1
}

case "$MODE" in
  --headless)
    if run_real_shell_if_available headless; then
      exit 0
    fi
    log_line "engineos-shell headless smoke backend=headless result=stub-ok"
    ;;
  --nested)
    if run_real_shell_if_available nested; then
      exit 0
    fi
    if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
      log_line "engineos-shell nested smoke backend=nested display=missing result=stub-ok"
    else
      log_line "engineos-shell nested smoke backend=nested display=available result=stub-ok"
    fi
    ;;
  --tty)
    if run_real_shell_if_available tty; then
      exit 0
    fi
    if [[ "${ENGINEOS_ALLOW_TTY_STUB:-false}" == "true" ]]; then
      log_line "engineos-shell tty smoke backend=drm result=stub-ok"
    else
      log_line "engineos-shell tty backend=drm result=not-implemented"
      printf 'engineos-shell --tty is not implemented yet; run this on bare-metal AMD after the wlroots shell exists.\n' >&2
      exit 1
    fi
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "shell runner expected --headless, --nested, or --tty"
    ;;
esac
