#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
CALLER_ENGINEOS_LOG_DIR="${ENGINEOS_LOG_DIR-}"
CALLER_ENGINEOS_STATE_DIR="${ENGINEOS_STATE_DIR-}"
CALLER_ENGINEOS_PROFILE="${ENGINEOS_PROFILE-}"

if [[ -r /etc/engineos/profile.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/engineos/profile.conf
fi
if [[ -n "$CALLER_ENGINEOS_LOG_DIR" ]]; then
  ENGINEOS_LOG_DIR="$CALLER_ENGINEOS_LOG_DIR"
fi
if [[ -n "$CALLER_ENGINEOS_STATE_DIR" ]]; then
  ENGINEOS_STATE_DIR="$CALLER_ENGINEOS_STATE_DIR"
fi
if [[ -n "$CALLER_ENGINEOS_PROFILE" ]]; then
  ENGINEOS_PROFILE="$CALLER_ENGINEOS_PROFILE"
fi

if engineos_is_source_root "$ROOT"; then
  LOG_DIR="${ENGINEOS_LOG_DIR:-$(engineos_default_log_dir "$ROOT")}"
  STATE_DIR="${ENGINEOS_STATE_DIR:-$(engineos_default_state_dir "$ROOT")}"
else
  LOG_DIR="${ENGINEOS_LOG_DIR:-$(engineos_default_log_dir "$ROOT")}"
  STATE_DIR="${ENGINEOS_STATE_DIR:-$(engineos_default_state_dir "$ROOT")}"
fi

MODE="${1:-help}"
if [[ -n "${ENGINEOS_SHELL_BIN:-}" ]]; then
  SHELL_BIN="$ENGINEOS_SHELL_BIN"
elif engineos_is_source_root "$ROOT" && [[ -x "$ROOT/build/shell/engineos-shell" ]]; then
  SHELL_BIN="$ROOT/build/shell/engineos-shell"
else
  SHELL_BIN="engineos-shell"
fi
LOG_FILE="$LOG_DIR/shell.log"
export ENGINEOS_STATE_DIR="$STATE_DIR"

eos_app_cmd_string() {
  if [[ -x "$ROOT/tools/engineos/eos-app" ]]; then
    printf '%q' "$ROOT/tools/engineos/eos-app"
  else
    printf 'eos-app'
  fi
}

EOS_APP_CMD_STRING="$(eos_app_cmd_string)"
APPS_MANIFEST="$(engineos_apps_manifest "$ROOT")"

manifest_command_or_default() {
  local app="$1"
  local fallback="$2"
  local command=""

  command="$(engineos_app_manifest_value "$APPS_MANIFEST" "$app" command || true)"
  if [[ -z "$command" ]]; then
    printf '%s\n' "$fallback"
    return
  fi
  if [[ "$command" == engineos\ app* ]]; then
    printf '%s%s\n' "$EOS_APP_CMD_STRING" "${command#engineos app}"
  else
    printf '%s\n' "$command"
  fi
}

DEFAULT_TERMINAL="${ENGINEOS_TERMINAL_SLOT_CMD:-$(manifest_command_or_default terminal "$EOS_APP_CMD_STRING launch terminal")}"
DEFAULT_TERMINAL_SECONDARY="${ENGINEOS_TERMINAL_SECONDARY_SLOT_CMD:-$(manifest_command_or_default terminal-secondary "$EOS_APP_CMD_STRING launch terminal-secondary")}"
DEFAULT_CUBE="${ENGINEOS_CUBE_CMD:-$(manifest_command_or_default cube "$EOS_APP_CMD_STRING launch cube")}"
DEFAULT_ENGINE="${ENGINEOS_ENGINE_CMD:-$(manifest_command_or_default quake "$EOS_APP_CMD_STRING launch quake")}"

usage() {
  cat <<'HELP'
Usage: shell_runner.sh --headless
       shell_runner.sh --nested
       shell_runner.sh --tty

Run the EngineOS shell path. Headless and nested can smoke locally. TTY is
the Runtime graphical entry point and bootstraps the launchpad slots by
default when the real shell binary is installed.
HELP
}

log_line() {
  mkdir -p "$LOG_DIR"
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE"
}

tee_shell_output() {
  mkdir -p "$LOG_DIR"
  exec > >(tee -a "$LOG_FILE") 2>&1
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
  launch_args+=(--terminal-secondary "$DEFAULT_TERMINAL_SECONDARY")
  launch_args+=(--cube "$DEFAULT_CUBE")
  launch_args+=(--engine "$DEFAULT_ENGINE")
  if [[ -n "${ENGINEOS_SHELL_STARTUP:-}" ]]; then
    startup_args+=(--startup "$ENGINEOS_SHELL_STARTUP")
  elif [[ -z "${ENGINEOS_SHELL_BOOTSTRAP:-}" && "$mode" == "nested" && "${ENGINEOS_SHELL_AUTO_STARTUP:-true}" == "true" ]]; then
    startup_args+=(--startup "$DEFAULT_TERMINAL")
  fi
  if [[ -n "${ENGINEOS_SHELL_BOOTSTRAP:-}" ]]; then
    bootstrap_args+=(--bootstrap "$ENGINEOS_SHELL_BOOTSTRAP")
  elif [[ "$mode" == "tty" ]]; then
    bootstrap_args+=(--bootstrap launchpad)
  fi

  if command -v "$SHELL_BIN" >/dev/null 2>&1; then
    log_line "shell binary found: $SHELL_BIN mode=$mode"
    tee_shell_output
    case "$mode" in
      headless)
        WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS="${WLR_HEADLESS_OUTPUTS:-1}" exec "$SHELL_BIN" --headless "${smoke_args[@]}" "${startup_args[@]}" "${launch_args[@]}" "${bootstrap_args[@]}"
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
    log_line "engineos-shell headless backend=headless result=missing-shell shell=$SHELL_BIN"
    printf 'engineos-shell binary is unavailable for --headless: %s\n' "$SHELL_BIN" >&2
    exit 1
    ;;
  --nested)
    if run_real_shell_if_available nested; then
      exit 0
    fi
    if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
      log_line "engineos-shell nested backend=nested display=missing result=missing-shell shell=$SHELL_BIN"
    else
      log_line "engineos-shell nested backend=nested display=available result=missing-shell shell=$SHELL_BIN"
    fi
    printf 'engineos-shell binary is unavailable for --nested: %s\n' "$SHELL_BIN" >&2
    exit 1
    ;;
  --tty)
    if run_real_shell_if_available tty; then
      exit 0
    fi
    log_line "engineos-shell tty backend=drm result=missing-shell shell=$SHELL_BIN"
    printf 'engineos-shell binary is unavailable for --tty: %s\n' "$SHELL_BIN" >&2
    exit 1
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "shell runner expected --headless, --nested, or --tty"
    ;;
esac
