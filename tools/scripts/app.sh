#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
LOG_DIR="${ENGINEOS_LOG_DIR:-$(engineos_default_log_dir "$ROOT")}"
DRY_RUN=false
ACTION="${1:-help}"
shift || true

if [[ "$ACTION" == "--dry-run" ]]; then
  DRY_RUN=true
  ACTION="${1:-help}"
  shift || true
fi

usage() {
  cat <<'HELP'
Usage: app.sh launch terminal [args...]
       app.sh launch quake [--smoke]
       app.sh status

Launch graphical applications through the EngineOS shell-owned Wayland session.
The app layer enforces the common client environment and dispatches to the
existing terminal and engine runners.
HELP
}

engineos_cmd_string() {
  if [[ -n "${ENGINEOS_CMD:-}" ]]; then
    printf '%s\n' "$ENGINEOS_CMD"
    return
  fi
  if [[ -x "$ROOT/tools/engineos/engineos" ]]; then
    printf '%s\n' "$ROOT/tools/engineos/engineos"
  else
    printf '%s\n' engineos
  fi
}

log_line() {
  mkdir -p "$LOG_DIR"
  printf '[%s] app %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_DIR/app.log"
}

require_shell_display() {
  if [[ "${ENGINEOS_APP_REQUIRE_WAYLAND:-true}" == "true" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    log_line "launch failed reason=missing-wayland-display app=${1:-unknown}"
    printf 'engineos app: WAYLAND_DISPLAY is required so engineos-shell owns graphical clients.\n' >&2
    return 125
  fi
}

prepare_client_env() {
  export XDG_SESSION_TYPE=wayland
  export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland}"
  export GDK_BACKEND="${GDK_BACKEND:-wayland}"
  export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    unset DISPLAY
  fi
}

run_launch() {
  local app="${1:-}"
  [[ -n "$app" ]] || die "app launch requires an app id"
  shift || true

  case "$app" in
    terminal)
      require_shell_display "$app"
      prepare_client_env
      log_line "launch app=terminal owner=engineos-shell display=${WAYLAND_DISPLAY:-missing}"
      exec "$SCRIPT_DIR/terminal_launcher.sh" -- "$@"
      ;;
    quake)
      require_shell_display "$app"
      prepare_client_env
      log_line "launch app=quake owner=engineos-shell display=${WAYLAND_DISPLAY:-missing} sdl=${SDL_VIDEODRIVER:-unset} args=$*"
      exec "$(engineos_cmd_string)" engine launch quake "$@"
      ;;
    *)
      die "unknown app id: $app"
      ;;
  esac
}

run_status() {
  printf 'EngineOS app launcher\n'
  printf '  WAYLAND_DISPLAY: %s\n' "${WAYLAND_DISPLAY:-unset}"
  printf '  XDG_SESSION_TYPE: %s\n' "${XDG_SESSION_TYPE:-unset}"
  printf '  SDL_VIDEODRIVER: %s\n' "${SDL_VIDEODRIVER:-unset}"
  printf '  log: %s/app.log\n' "$LOG_DIR"
}

case "$ACTION" in
  launch)
    if [[ "$DRY_RUN" == true ]]; then
      app="${1:-}"
      shift || true
      printf 'EngineOS app launch dry-run\n'
      printf '  app:      %s\n' "${app:-missing}"
      printf '  display:  %s\n' "${WAYLAND_DISPLAY:-unset}"
      printf '  owner:    engineos-shell\n'
      printf '  command:  engineos app launch %s' "${app:-missing}"
      printf ' %q' "$@"
      printf '\n'
      exit 0
    fi
    run_launch "$@"
    ;;
  status)
    run_status
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown app action: $ACTION"
    ;;
esac
