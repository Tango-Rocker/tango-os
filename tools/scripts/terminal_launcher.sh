#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
DRY_RUN=false
PRINT_COMMAND=false
TERMINAL_ARGS=()

LOG_DIR="${ENGINEOS_LOG_DIR:-$(engineos_default_log_dir "$ROOT")}"

usage() {
  cat <<'HELP'
Usage: terminal_launcher.sh [--dry-run] [--print-command] [--] [terminal-args...]

Launch the first available Wayland graphical terminal. ENGINEOS_TERMINAL_CMD
overrides auto-detection. ENGINEOS_TERMINAL_CANDIDATES can override the fallback
list. ENGINEOS_TERMINAL_SESSION_CMD runs a shell command inside terminals that
support an argv separator, such as foot.
HELP
}

log_line() {
  mkdir -p "$LOG_DIR"
  printf '[%s] terminal %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_DIR/terminal.log"
}

terminal_candidates() {
  if [[ -n "${ENGINEOS_TERMINAL_CANDIDATES:-}" ]]; then
    printf '%s\n' ${ENGINEOS_TERMINAL_CANDIDATES}
  else
    printf '%s\n' foot weston-terminal alacritty kitty wezterm
  fi
}

select_terminal() {
  local candidate

  if [[ -n "${ENGINEOS_TERMINAL_CMD:-}" ]]; then
    printf '%s\n' "$ENGINEOS_TERMINAL_CMD"
    return 0
  fi

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if have_cmd "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(terminal_candidates)

  return 1
}

candidate_summary() {
  local first=true
  local candidate

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if [[ "$first" == true ]]; then
      first=false
    else
      printf ','
    fi
    printf '%s' "$candidate"
  done < <(terminal_candidates)
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --print-command)
      PRINT_COMMAND=true
      ;;
    --)
      shift
      TERMINAL_ARGS+=("$@")
      break
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      TERMINAL_ARGS+=("$1")
      ;;
  esac
  shift
done

if terminal_cmd="$(select_terminal)"; then
  if [[ "$PRINT_COMMAND" == true ]]; then
    printf '%s\n' "$terminal_cmd"
    exit 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    printf 'EngineOS terminal launcher dry-run\n'
    printf '  command: %s\n' "$terminal_cmd"
    if [[ -n "${ENGINEOS_TERMINAL_SESSION_CMD:-}" ]]; then
      printf '  session: %s\n' "$ENGINEOS_TERMINAL_SESSION_CMD"
    fi
    if [[ ${#TERMINAL_ARGS[@]} -gt 0 ]]; then
      printf '  args:    '
      quote_cmd "${TERMINAL_ARGS[@]}"
    fi
    exit 0
  fi

  if [[ "${ENGINEOS_TERMINAL_REQUIRE_WAYLAND:-true}" == "true" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    log_line "launch failed reason=missing-wayland-display command=$terminal_cmd"
    printf 'engineos terminal: WAYLAND_DISPLAY is required so the EngineOS shell owns graphical clients.\n' >&2
    exit 125
  fi

  export XDG_SESSION_TYPE=wayland
  unset DISPLAY

  log_line "launch command=$terminal_cmd display=${WAYLAND_DISPLAY:-missing} owner=engineos-shell"

  if [[ -n "${ENGINEOS_TERMINAL_CMD:-}" ]]; then
    if [[ ${#TERMINAL_ARGS[@]} -gt 0 ]]; then
      log_line "custom command ignores extra args count=${#TERMINAL_ARGS[@]}"
    fi
    exec /bin/sh -lc "exec $ENGINEOS_TERMINAL_CMD"
  fi

  if [[ -n "${ENGINEOS_TERMINAL_SESSION_CMD:-}" && ${#TERMINAL_ARGS[@]} -eq 0 ]]; then
    log_line "session command=$ENGINEOS_TERMINAL_SESSION_CMD"
    exec "$terminal_cmd" -- zsh -lc "exec $ENGINEOS_TERMINAL_SESSION_CMD"
  fi

  exec "$terminal_cmd" "${TERMINAL_ARGS[@]}"
fi

if [[ "$PRINT_COMMAND" == true ]]; then
  exit 1
fi

summary="$(candidate_summary)"
if [[ "$DRY_RUN" == true ]]; then
  printf 'EngineOS terminal launcher dry-run\n'
  printf '  command: missing\n'
  printf '  candidates: %s\n' "$summary"
  exit 0
fi

log_line "launch failed reason=no-terminal-candidate candidates=$summary"
printf 'engineos terminal: no graphical terminal found. Tried: %s\n' "$summary" >&2
exit 127
