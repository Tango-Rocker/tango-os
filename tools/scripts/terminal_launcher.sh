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
       terminal_launcher.sh save-layout [--dry-run]

Launch the first available Wayland graphical terminal. ENGINEOS_TERMINAL_CMD
overrides auto-detection. ENGINEOS_TERMINAL_CANDIDATES can override the fallback
list. ENGINEOS_TERMINAL_SESSION_CMD runs a shell command inside terminals that
support an argv separator, such as foot.

save-layout records the current tmux sessions, windows, panes, layouts, and
restart commands through tmux-resurrect. The EngineOS tmux config restores the
saved layout automatically on future logins.
HELP
}

log_line() {
  mkdir -p "$LOG_DIR"
  printf '[%s] terminal %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_DIR/terminal.log"
}

find_resurrect_save_script() {
  local candidate

  for candidate in \
      "${ENGINEOS_TMUX_RESURRECT_SAVE_SCRIPT:-}" \
      /usr/share/tmux/plugins/tmux-resurrect/scripts/save.sh \
      "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" \
      "$HOME/.config/tmux/plugins/tmux-resurrect/scripts/save.sh"; do
    [[ -n "$candidate" ]] || continue
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

cmd_save_layout() {
  local dry_run=false
  local save_script=""
  local session_count=""
  local hostname_dir=""
  local save_status=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      help|--help|-h)
        cat <<'HELP'
Usage: eos-terminal save-layout [--dry-run]

Save the current tmux sessions/windows/panes as the login default. The
EngineOS shell-owned terminal monitors attach to their restored tmux sessions
on the next login.
HELP
        return 0
        ;;
      *)
        printf 'eos-terminal: unknown save-layout option: %s\n' "$1" >&2
        return 2
        ;;
    esac
    shift
  done

  if ! have_cmd tmux; then
    printf 'eos-terminal: tmux is required to save the terminal layout.\n' >&2
    return 127
  fi

  if ! session_count="$(tmux list-sessions 2>/dev/null | wc -l)"; then
    printf 'eos-terminal: no tmux server is running; open the EngineOS terminal first.\n' >&2
    return 1
  fi

  if ! save_script="$(find_resurrect_save_script)"; then
    printf 'eos-terminal: tmux-resurrect save script is missing. Install engineos-tmux-plugins.\n' >&2
    return 127
  fi

  if [[ "$dry_run" == true ]]; then
    printf 'EngineOS terminal save-layout dry-run\n'
    printf '  tmux sessions: %s\n' "$session_count"
    printf '  save script:   %s\n' "$save_script"
    printf '  restore:       enabled by EngineOS tmux config\n'
    return 0
  fi

  tmux set-option -gq @continuum-restore on
  tmux set-option -gq @resurrect-capture-pane-contents off
  tmux set-option -gq @resurrect-processes ':all:'

  if ! have_cmd hostname; then
    hostname_dir="$(mktemp -d "${TMPDIR:-/tmp}/engineos-hostname.XXXXXX")"
    cat >"$hostname_dir/hostname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${HOSTNAME:-engineos}"
EOF
    chmod 0755 "$hostname_dir/hostname"
  fi

  if [[ -n "$hostname_dir" ]]; then
    PATH="$hostname_dir:$PATH" "$save_script" || save_status=$?
    rm -rf "$hostname_dir"
  else
    "$save_script" || save_status=$?
  fi
  if [[ "$save_status" -ne 0 ]]; then
    printf 'eos-terminal: tmux-resurrect save failed with status %s.\n' "$save_status" >&2
    return "$save_status"
  fi
  log_line "saved tmux layout sessions=$session_count script=$save_script"
  printf 'Saved current tmux layout as the EngineOS login default.\n'
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

terminal_metadata_args() {
  local terminal_cmd="$1"
  local app_id="${ENGINEOS_TERMINAL_APP_ID:-}"
  local title="${ENGINEOS_TERMINAL_TITLE:-}"
  local decorations="${ENGINEOS_TERMINAL_DECORATIONS:-none}"

  case "$(basename "$terminal_cmd")" in
    foot)
      if [[ "$decorations" == "none" ]]; then
        printf '%s\0%s\0' --override csd.preferred=none
        printf '%s\0%s\0' --override csd.size=0
      fi
      [[ -z "$app_id" ]] || printf '%s\0%s\0' --app-id "$app_id"
      [[ -z "$title" ]] || printf '%s\0%s\0' --title "$title"
      ;;
    alacritty)
      [[ -z "$app_id" ]] || printf '%s\0%s\0' --class "$app_id"
      [[ -z "$title" ]] || printf '%s\0%s\0' --title "$title"
      ;;
    kitty)
      [[ -z "$app_id" ]] || printf '%s\0%s\0' --class "$app_id"
      [[ -z "$title" ]] || printf '%s\0%s\0' --title "$title"
      ;;
    wezterm)
      [[ -z "$title" ]] || printf '%s\0%s\0' start --title "$title"
      ;;
  esac
}

case "${1:-}" in
  save|save-layout)
    shift || true
    cmd_save_layout "$@"
    exit $?
    ;;
esac

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
  if [[ -z "${ENGINEOS_TERMINAL_CMD:-}" ]]; then
    while IFS= read -r -d '' arg; do
      TERMINAL_ARGS+=("$arg")
    done < <(terminal_metadata_args "$terminal_cmd")
  fi

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
    printf 'eos-terminal: WAYLAND_DISPLAY is required so the EngineOS shell owns graphical clients.\n' >&2
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

  if [[ -n "${ENGINEOS_TERMINAL_SESSION_CMD:-}" ]]; then
    log_line "session command=$ENGINEOS_TERMINAL_SESSION_CMD"
		terminal_role="${ENGINEOS_TERMINAL_ROLE:-terminal}"
		case "$terminal_role" in
			terminal|terminal-secondary) ;;
			*)
				log_line "launch failed reason=invalid-terminal-role role=$terminal_role"
				printf 'eos-terminal: invalid terminal role: %s\n' "$terminal_role" >&2
				exit 2
				;;
		esac
		exec "$terminal_cmd" "${TERMINAL_ARGS[@]}" -- zsh -lc \
			"unset TMUX TMUX_PANE; eos-app terminal register --slot $terminal_role; exec $ENGINEOS_TERMINAL_SESSION_CMD"
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
printf 'eos-terminal: no graphical terminal found. Tried: %s\n' "$summary" >&2
exit 127
