#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
if [[ -n "${ENGINEOS_STATE_DIR:-}" ]]; then
  STATE_DIR="$ENGINEOS_STATE_DIR"
elif [[ -r "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/engineos/shell-state.json" ]]; then
  STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/engineos"
else
  STATE_DIR="$(engineos_default_state_dir "$ROOT")"
fi
if [[ -n "${ENGINEOS_LOG_DIR:-}" ]]; then
  LOG_DIR="$ENGINEOS_LOG_DIR"
elif [[ "$STATE_DIR" == "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/engineos" &&
    -d /var/log/engineos ]]; then
  LOG_DIR=/var/log/engineos
else
  LOG_DIR="$(engineos_default_log_dir "$ROOT")"
fi
APP_STATE_DIR="$STATE_DIR/apps"
SHELL_STATE_FILE="$STATE_DIR/shell-state.json"
LAUNCH_BOUNDS_DIR="$STATE_DIR/launch-bounds"
APPS_MANIFEST="$(engineos_apps_manifest "$ROOT")"
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
       app.sh launch terminal-secondary [args...]
       app.sh launch cube [--smoke]
       app.sh launch quake [--smoke] [--pane|--fullscreen|--output] [--map NAME] [--game MOD]
       app.sh recover preview|terminal|terminal-secondary|cube|quake
	   app.sh terminal register --slot terminal|terminal-secondary [--tty /dev/pts/N]
       app.sh pane launch [--game] [--pane TMUX_PANE] -- COMMAND [ARG...]
       app.sh pane split [-h|-v] [--game] [--pane TMUX_PANE] -- COMMAND [ARG...]
       app.sh pane view [--pane TMUX_PANE] app|console|toggle|close
       app.sh pane signal [--pane TMUX_PANE] INT|TERM|KILL
       app.sh pane respawn [--pane TMUX_PANE]
       app.sh pane focus [--pane TMUX_PANE]
       app.sh pane geometry [--pane TMUX_PANE]
       app.sh pane unbind [--pane TMUX_PANE]
       app.sh pane list [--json]
       app.sh pane sync [--all|cube|engine|quake]
       app.sh window list [--json]
       app.sh window focus WINDOW_ID
       app.sh window bind WINDOW_ID [--pane TMUX_PANE]
       app.sh window launch -- COMMAND [ARG...]
       app.sh status [--json]
       app.sh manifest path|show|validate

Launch graphical applications through the EngineOS shell-owned Wayland session.
The app layer enforces the common client environment and dispatches to the
terminal launcher, cube app, or per-user game service.

Quake launches from inside tmux default to the invoking pane's bounds. Use
--fullscreen or --output to clear pane bounds for the launch.
pane sync refreshes existing tmux-pane launch bounds and asks engineos-shell to
re-layout mapped panel clients without restarting them.
recover asks the running shell to refresh IPC or relaunch a shell-owned slot
without restarting the compositor service.
pane launch binds arbitrary GUI apps to the invoking tmux pane through the
authoritative native mux when native mode is active. The legacy bridge remains
available only while the shell is explicitly running in legacy mode. window
commands remain for diagnostics and manual recovery.
HELP
}

game_cmd_string() {
	if [[ -n "${ENGINEOS_GAME_CMD:-}" ]]; then
		printf '%s\n' "$ENGINEOS_GAME_CMD"
	elif [[ -x "$ROOT/tools/scripts/game.sh" ]]; then
		printf '%s\n' "$ROOT/tools/scripts/game.sh"
	else
		printf '%s\n' eos-game
  fi
}

log_line() {
  mkdir -p "$LOG_DIR"
  printf '[%s] app %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_DIR/app.log"
}

json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

json_string() {
  printf '"'
  json_escape "${1:-}"
  printf '"'
}

manifest_failures=0

manifest_fail() {
  printf 'FAIL %s\n' "$*" >&2
  manifest_failures=$((manifest_failures + 1))
}

manifest_ok() {
  printf 'OK   %s\n' "$*"
}

extract_token() {
  local line="$1"
  local key="$2"
  if [[ "$line" =~ (^|[[:space:]])${key}=([^[:space:]]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

last_line_matching() {
  local file="$1"
  local pattern="$2"
  if [[ -r "$file" ]]; then
    grep -E "$pattern" "$file" | tail -n 1 || true
  fi
}

shell_state_string() {
  local key="$1"
  [[ -r "$SHELL_STATE_FILE" ]] || return 1
  awk -v key="$key" '
    {
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\""
      if (match($0, pattern)) {
        value = substr($0, RSTART + RLENGTH)
        sub(/".*/, "", value)
        print value
        exit
      }
    }
  ' "$SHELL_STATE_FILE"
}

shell_state_slot_mapped_json() {
  local role="$1"
  [[ -r "$SHELL_STATE_FILE" ]] || return 1
  awk -v role="$role" '
    $0 ~ "\"" role "\"[[:space:]]*:" {
      in_slot = 1
    }
    in_slot && /"mapped"[[:space:]]*:[[:space:]]*true/ {
      print "true"
      exit
    }
    in_slot && /"mapped"[[:space:]]*:[[:space:]]*false/ {
      print "false"
      exit
    }
    in_slot && /}/ {
      exit
    }
  ' "$SHELL_STATE_FILE"
}

shell_state_slot_field_json() {
  local role="$1"
  local field="$2"
  [[ -r "$SHELL_STATE_FILE" ]] || return 1
  awk -v role="$role" -v field="$field" '
    $0 ~ "\"" role "\"[[:space:]]*:" {
      line = $0
      pattern = "\"" field "\"[[:space:]]*:[[:space:]]*"
      if (match(line, pattern)) {
        value = substr(line, RSTART + RLENGTH)
        if (substr(value, 1, 1) == "\"") {
          value = substr(value, 2)
          sub(/".*/, "", value)
          gsub(/\\/, "\\\\", value)
          gsub(/"/, "\\\"", value)
          printf "\"%s\"", value
        } else {
          sub(/[,}].*/, "", value)
          gsub(/[[:space:]]/, "", value)
          printf "%s", value
        }
        found = 1
        exit
      }
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$SHELL_STATE_FILE"
}

write_app_state() {
  local app="$1"
  local state="$2"
  local reason="${3:-}"
  shift 3 || true

  mkdir -p "$APP_STATE_DIR"
  {
    printf 'app=%s\n' "$app"
    printf 'state=%s\n' "$state"
    printf 'owner=engineos-shell\n'
    printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'display=%s\n' "${WAYLAND_DISPLAY:-missing}"
    printf 'sdl=%s\n' "${SDL_VIDEODRIVER:-unset}"
    printf 'pid=%s\n' "$$"
    if [[ -n "$reason" ]]; then
      printf 'reason=%s\n' "$reason"
    fi
    printf 'args='
    quote_cmd "$@"
  } >"$APP_STATE_DIR/$app.status"
}

launch_bounds_file() {
  local role="$1"
  printf '%s/%s.env\n' "$LAUNCH_BOUNDS_DIR" "$role"
}

clear_launch_bounds() {
  local role="$1"
  rm -f "$(launch_bounds_file "$role")"
}

is_nonnegative_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

is_positive_integer() {
  is_nonnegative_integer "$1" && (( 10#$1 > 0 ))
}

tmux_pane_geometry() {
  local target="${1:-${TMUX_PANE:-}}"
  [[ -n "${TMUX:-}" && -n "$target" ]] || return 1
  have_cmd tmux || return 1

  local values
  values="$(tmux display-message -p -t "$target" \
    '#{pane_left} #{pane_top} #{pane_width} #{pane_height} #{window_width} #{window_height} #{client_width} #{client_height}' 2>/dev/null)" ||
    return 1

  local pane_left pane_top pane_width pane_height window_width window_height client_width client_height
  read -r pane_left pane_top pane_width pane_height window_width window_height client_width client_height <<<"$values"
  is_nonnegative_integer "$pane_left" || return 1
  is_nonnegative_integer "$pane_top" || return 1
  is_positive_integer "$pane_width" || return 1
  is_positive_integer "$pane_height" || return 1
  is_positive_integer "$window_width" || return 1
  is_positive_integer "$window_height" || return 1
  if is_positive_integer "${client_width:-}" && (( 10#$client_width >= 10#$window_width )); then
    window_width="$client_width"
  fi
  if is_positive_integer "${client_height:-}" && (( 10#$client_height >= 10#$window_height )); then
    window_height="$client_height"
  fi

  printf '%s %s %s %s %s %s\n' \
    "$pane_left" "$pane_top" "$pane_width" "$pane_height" "$window_width" "$window_height"
}

tmux_pane_cell_size() {
  local target="${1:-${TMUX_PANE:-}}"
  [[ -n "${TMUX:-}" && -n "$target" ]] || return 1
  have_cmd tmux || return 1

  local values
  values="$(tmux display-message -p -t "$target" \
    '#{client_cell_width} #{client_cell_height}' 2>/dev/null)" ||
    return 1

  local cell_width cell_height
  read -r cell_width cell_height <<<"$values"
  is_positive_integer "${cell_width:-}" || return 1
  is_positive_integer "${cell_height:-}" || return 1

  printf '%s %s\n' "$cell_width" "$cell_height"
}

tmux_client_tty() {
  local target="${1:-${TMUX_PANE:-}}"
  [[ -n "${TMUX:-}" && -n "$target" ]] || return 1
  have_cmd tmux || return 1
  local client_tty
  client_tty="$(tmux display-message -p -t "$target" '#{client_tty}' 2>/dev/null)" ||
    return 1
  [[ "$client_tty" == /dev/* ]] || return 1
  printf '%s\n' "$client_tty"
}

tmux_socket_for_pane() {
  local target="${1:-${TMUX_PANE:-}}"
  local socket=""
  if [[ -n "${TMUX:-}" ]]; then
    socket="${TMUX%%,*}"
  fi
  local format_socket
  format_socket="$(tmux display-message -p -t "$target" '#{socket_path}' 2>/dev/null || true)"
  if [[ -n "$format_socket" && "$format_socket" != '#{socket_path}' ]]; then
    socket="$format_socket"
  fi
  printf '%s\n' "${socket:-default}"
}

tmux_pane_context() {
  local target="${1:-${TMUX_PANE:-}}"
  [[ -n "$target" ]] || return 1
  have_cmd tmux || return 1

  local identity
  identity="$(tmux display-message -p -t "$target" \
    '#{session_name} #{window_id} #{window_index} #{pane_id}' 2>/dev/null)" ||
    return 1

  local session window_id window_index pane_id
  read -r session window_id window_index pane_id <<<"$identity"
  [[ -n "$session" && -n "$window_id" && -n "$window_index" && -n "$pane_id" ]] ||
    return 1

  local geometry
  geometry="$(tmux_pane_geometry "$pane_id")" || return 1
  local pane_left pane_top pane_width pane_height window_width window_height
  read -r pane_left pane_top pane_width pane_height window_width window_height <<<"$geometry"

  local cell_width=0
  local cell_height=0
  local cell_size
  if cell_size="$(tmux_pane_cell_size "$pane_id")"; then
    read -r cell_width cell_height <<<"$cell_size"
  fi

  local socket
  socket="$(tmux_socket_for_pane "$pane_id")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$socket" "$session" "$window_id" "$window_index" "$pane_id" \
    "$pane_left" "$pane_top" "$pane_width" "$pane_height" \
    "$window_width" "$window_height" "$cell_width" "$cell_height"
}

pane_context_request_json() {
  local op="$1"
  local pane_id="$2"
  local token="${3:-}"
  local command_label="${4:-}"
	local client_tty="${5:-}"
  local context
  context="$(tmux_pane_context "$pane_id")" || return 1

  local socket session window_id window_index resolved_pane_id
  local pane_left pane_top pane_width pane_height window_width window_height
  local cell_width cell_height
  IFS=$'\t' read -r socket session window_id window_index resolved_pane_id \
    pane_left pane_top pane_width pane_height window_width window_height \
    cell_width cell_height <<<"$context"

  printf '{"version":1,"op":'
  json_string "$op"
  if [[ -n "$token" ]]; then
    printf ',"token":'
    json_string "$token"
  fi
  if [[ -n "$command_label" ]]; then
    printf ',"command_label":'
    json_string "$command_label"
  fi
	if [[ -z "$client_tty" ]]; then
		client_tty="$(tmux_client_tty "$pane_id" || true)"
	fi
	if [[ -n "$client_tty" ]]; then
		printf ',"client_tty":'
		json_string "$client_tty"
	fi
  printf ',"pane":{"socket":'
  json_string "$socket"
  printf ',"session":'
  json_string "$session"
  printf ',"window_id":'
  json_string "$window_id"
  printf ',"window_index":'
  json_string "$window_index"
  printf ',"pane_id":'
  json_string "$resolved_pane_id"
  printf '},"geometry":{"pane_left":%s,"pane_top":%s,"pane_width":%s,"pane_height":%s,"window_width":%s,"window_height":%s,"cell_width":%s,"cell_height":%s}}\n' \
    "$pane_left" "$pane_top" "$pane_width" "$pane_height" \
    "$window_width" "$window_height" "$cell_width" "$cell_height"
}

write_tmux_bounds() {
  local role="$1"
  local pane_left="$2"
  local pane_top="$3"
  local pane_width="$4"
  local pane_height="$5"
  local window_width="$6"
  local window_height="$7"
  local pane_id="${8:-${TMUX_PANE:-unknown}}"
  local file
  local tmp

  mkdir -p "$LAUNCH_BOUNDS_DIR"
  file="$(launch_bounds_file "$role")"
  tmp="$file.$$"
  {
    printf 'schema=engineos-launch-bounds-v0\n'
    printf 'role=%s\n' "$role"
    printf 'mode=pane\n'
    printf 'source=tmux\n'
    printf 'pane_id=%s\n' "$pane_id"
    printf 'pane_left=%s\n' "$pane_left"
    printf 'pane_top=%s\n' "$pane_top"
    printf 'pane_width=%s\n' "$pane_width"
    printf 'pane_height=%s\n' "$pane_height"
    printf 'window_width=%s\n' "$window_width"
    printf 'window_height=%s\n' "$window_height"
    if cell_size="$(tmux_pane_cell_size "$pane_id")"; then
      local cell_width cell_height
      read -r cell_width cell_height <<<"$cell_size"
      printf 'cell_width=%s\n' "$cell_width"
      printf 'cell_height=%s\n' "$cell_height"
    fi
    printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$tmp"
  mv "$tmp" "$file"
}

write_output_bounds() {
  local role="$1"
  local source="$2"
  local file
  local tmp

  mkdir -p "$LAUNCH_BOUNDS_DIR"
  file="$(launch_bounds_file "$role")"
  tmp="$file.$$"
  {
    printf 'schema=engineos-launch-bounds-v0\n'
    printf 'role=%s\n' "$role"
    printf 'mode=output\n'
    printf 'source=%s\n' "$source"
    printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$tmp"
  mv "$tmp" "$file"
}

write_engine_tmux_bounds() {
  write_tmux_bounds engine "$@"
}

write_engine_output_bounds() {
  write_output_bounds engine "$@"
}

launch_bounds_value() {
  local role="$1"
  local key="$2"
  local file
  file="$(launch_bounds_file "$role")"
  [[ -r "$file" ]] || return 1
  awk -F= -v key="$key" '
    $1 == key {
      print substr($0, length($1) + 2)
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$file"
}

normalize_layout_role() {
  case "${1:-}" in
    cube)
      printf 'cube\n'
      ;;
    engine|quake)
      printf 'engine\n'
      ;;
    *)
      return 1
      ;;
  esac
}

role_has_pane_bounds() {
  local role="$1"
  [[ "$(launch_bounds_value "$role" mode || true)" == "pane" ]]
}

sync_role_to_pane() {
  local role="$1"
  local pane_id="$2"
  local geometry

  geometry="$(tmux_pane_geometry "$pane_id")" || return 1
  # shellcheck disable=SC2086
  write_tmux_bounds "$role" $geometry "$pane_id"
  log_line "pane sync role=$role source=tmux pane=$pane_id bounds=$geometry"
  printf 'synced %s pane %s bounds %s\n' "$role" "$pane_id" "$geometry"
}

notify_shell_layout_sync() {
  if [[ "${ENGINEOS_APP_NOTIFY_SHELL:-true}" != "true" ]]; then
    log_line "pane sync notify=skipped reason=disabled"
    return 0
  fi

  if have_cmd pkill && pkill -HUP -x engineos-shell >/dev/null 2>&1; then
    log_line "pane sync notify=signal shell=engineos-shell"
    return 0
  fi

  local notified=false
  local failed=0
  if have_cmd pgrep; then
    local pid
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      if kill -HUP "$pid" >/dev/null 2>&1; then
        log_line "pane sync notify=signal pid=$pid"
        notified=true
      else
        log_line "pane sync notify=failed pid=$pid"
        failed=$((failed + 1))
      fi
    done < <(pgrep -x engineos-shell 2>/dev/null || true)
  else
    log_line "pane sync notify=failed reason=pgrep-unavailable"
    return 1
  fi

  if [[ "$notified" == true && "$failed" -eq 0 ]]; then
    return 0
  fi
  if [[ "$notified" == true ]]; then
    return 1
  fi

  log_line "pane sync notify=failed reason=shell-not-running"
  return 1
}

shell_ipc_socket() {
  if [[ -n "${ENGINEOS_SHELL_IPC_SOCKET:-}" ]]; then
    printf '%s\n' "$ENGINEOS_SHELL_IPC_SOCKET"
  elif [[ -n "${ENGINEOS_PREVIEW_SOCKET:-}" ]]; then
    printf '%s\n' "$ENGINEOS_PREVIEW_SOCKET"
  else
    printf '%s/preview.sock\n' "$STATE_DIR"
  fi
}

send_shell_ipc() {
  local socket_path="$1"
  local request="$2"
  python - "$socket_path" "$request" <<'PY'
import json
import socket
import sys

socket_path = sys.argv[1]
payload = (sys.argv[2] + "\n").encode("utf-8")
try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2.0)
        client.connect(socket_path)
        client.sendall(payload)
        chunks = []
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
            if b"\n" in chunk:
                break
except OSError as exc:
    print(f"shell IPC unavailable at {socket_path}: {exc}", file=sys.stderr)
    raise SystemExit(1)

raw = b"".join(chunks).split(b"\n", 1)[0]
if not raw:
    print("shell IPC returned an empty response", file=sys.stderr)
    raise SystemExit(1)
try:
    response = json.loads(raw.decode("utf-8"))
except (UnicodeDecodeError, json.JSONDecodeError) as exc:
    print(f"shell IPC returned invalid JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)
print(json.dumps(response, separators=(",", ":")))
if response.get("status") != "ok":
    print(response.get("error") or "shell IPC request failed", file=sys.stderr)
    raise SystemExit(1)
PY
}

send_pane_shell_ipc() {
  local action="$1"
  local request="$2"
  local socket_path
  local response
  socket_path="$(shell_ipc_socket)"
  if response="$(send_shell_ipc "$socket_path" "$request" 2>&1)"; then
    log_line "pane $action method=shell-ipc socket=$socket_path response=$response"
    return 0
  fi
  log_line "pane $action ipc=failed socket=$socket_path error=$response"
  printf 'eos-app: pane %s failed: %s\n' "$action" "$response" >&2
  return 1
}

run_terminal_register() {
  local slot="${ENGINEOS_TERMINAL_ROLE:-}"
  local terminal_tty=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --slot)
        shift
        [[ $# -gt 0 ]] || die "terminal register --slot requires a value"
        slot="$1"
        ;;
      --tty)
        shift
        [[ $# -gt 0 ]] || die "terminal register --tty requires a value"
        terminal_tty="$1"
        ;;
      help|--help|-h)
        usage
        return 0
        ;;
      *)
        die "unknown terminal register option: $1"
        ;;
    esac
    shift
  done
  case "$slot" in
    terminal|terminal-secondary) ;;
    *) die "terminal register requires --slot terminal or terminal-secondary" ;;
  esac
  if [[ -z "$terminal_tty" ]]; then
    terminal_tty="$(tty 2>/dev/null || true)"
  fi
  [[ "$terminal_tty" == /dev/* ]] ||
    die "terminal register requires a real tty"

  local request
  printf -v request '{"version":1,"op":"terminal-register","slot":"%s","tty":"%s"}' \
    "$(json_escape "$slot")" "$(json_escape "$terminal_tty")"
  send_shell_ipc "$(shell_ipc_socket)" "$request" >/dev/null
  log_line "terminal register slot=$slot tty=$terminal_tty"
}

run_terminal() {
  local sub="${1:-help}"
  shift || true
  case "$sub" in
    register)
      run_terminal_register "$@"
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      die "unknown app terminal action: $sub"
      ;;
  esac
}

run_window_list() {
  local json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json=true
        ;;
      help|--help|-h)
        usage
        return 0
        ;;
      *)
        die "unknown app window list option: $1"
        ;;
    esac
    shift
  done

  [[ -r "$SHELL_STATE_FILE" ]] || die "shell state is not readable: $SHELL_STATE_FILE"
  python - "$SHELL_STATE_FILE" "$json" <<'PY'
import json
import sys

state_file, as_json = sys.argv[1], sys.argv[2] == "true"
with open(state_file, "r", encoding="utf-8") as handle:
    state = json.load(handle)

windows = []
for item in state.get("windows", []):
    window_id = item.get("id")
    windows.append({
        "id": window_id,
        "role": item.get("role", "unknown"),
        "title": item.get("title", ""),
        "app_id": item.get("app_id", ""),
        "focused": bool(item.get("focused", False)),
        "visible": bool(item.get("visible", False)),
        "minimized": bool(item.get("minimized", False)),
        "layout": item.get("layout", ""),
        "x": item.get("x", 0),
        "y": item.get("y", 0),
        "width": item.get("width", 0),
        "height": item.get("height", 0),
        "bound": bool(item.get("bound", False)),
        "pane_key": item.get("pane_key", ""),
        "pane_id": item.get("pane_id", ""),
    })

if as_json:
    print(json.dumps({"ok": True, "windows": windows}, separators=(",", ":")))
else:
    print("ID\tROLE\tFOCUS\tVISIBLE\tLAYOUT\tSIZE\tAPP_ID\tTITLE")
    for window in windows:
        print("{id}\t{role}\t{focused}\t{visible}\t{layout}\t{width}x{height}\t{app_id}\t{title}".format(**window))
PY
}

run_window_focus() {
  local window_id="${1:-}"
  shift || true
  [[ $# -eq 0 ]] || die "window focus takes exactly one window id"
  is_positive_integer "$window_id" || die "window focus requires a positive numeric window id"

  local socket_path
  local request
  socket_path="$(shell_ipc_socket)"
  request="{\"version\":1,\"op\":\"focus-window\",\"window_id\":$window_id}"
  send_shell_ipc "$socket_path" "$request" >/dev/null
  log_line "window focus id=$window_id method=shell-ipc socket=$socket_path"
  printf 'focused window %s\n' "$window_id"
}

run_window_bind() {
	  local window_id="${1:-}"
	  shift || true
	  is_positive_integer "$window_id" || die "window bind requires a positive numeric window id"
	  log_line "window bind deprecated id=$window_id"
	  printf 'eos-app window bind is deprecated. Use eos-app pane launch -- COMMAND to create pane-bound GUI apps, or eos-app pane focus to focus an existing pane binding.\n' >&2
	  return 2
}

run_window_launch() {
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  [[ $# -gt 0 ]] || die "window launch requires a command"
  require_shell_display "window"
  prepare_client_env
  log_line "window launch owner=engineos-shell display=${WAYLAND_DISPLAY:-missing} command=$(quote_cmd "$@")"
  exec "$@"
}

run_window() {
  local sub="${1:-help}"
  shift || true
  case "$sub" in
    list)
      run_window_list "$@"
      ;;
    focus)
      run_window_focus "$@"
      ;;
    bind)
      run_window_bind "$@"
      ;;
    launch)
      run_window_launch "$@"
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      die "unknown app window action: $sub"
      ;;
  esac
}

recover_preview_ipc() {
  if notify_shell_layout_sync; then
    printf 'requested shell IPC refresh\n'
    return 0
  fi
  return 1
}

recover_slot() {
  local app="$1"
  local role
  local socket_path
  local request

  case "$app" in
    terminal|terminal-secondary|cube)
      role="$app"
      ;;
    engine|quake)
      role="engine"
      ;;
    *)
      die "unknown recover target: $app"
      ;;
  esac

  recover_preview_ipc >/dev/null || return 1
  sleep 0.1
  socket_path="$(shell_ipc_socket)"
  request="{\"version\":1,\"op\":\"launch\",\"slot\":\"$role\"}"
  send_shell_ipc "$socket_path" "$request" >/dev/null
  log_line "recover target=$app role=$role method=shell-ipc socket=$socket_path"
  printf 'requested %s recovery through running shell\n' "$app"
}

run_recover() {
  local target="${1:-}"
  shift || true
  [[ $# -eq 0 ]] || die "recover takes exactly one target"
  case "$target" in
    preview|ipc|mc)
      recover_preview_ipc
      ;;
    terminal|terminal-secondary|cube|engine|quake)
      recover_slot "$target"
      ;;
    help|--help|-h|"")
      usage
      ;;
    *)
      die "unknown recover target: $target"
      ;;
	esac
}

pane_launch_token() {
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%S%N 2>/dev/null || date -u +%s)"
  printf 'pane-%s-%s-%s\n' "$stamp" "$$" "${RANDOM:-0}"
}

pane_target_arg() {
  local pane_id="${TMUX_PANE:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pane)
        shift
        [[ $# -gt 0 ]] || die "pane --pane requires a tmux pane id"
        pane_id="$1"
        ;;
      help|--help|-h)
        usage
        return 2
        ;;
      *)
        die "unknown pane option: $1"
        ;;
    esac
    shift
  done
  [[ -n "$pane_id" ]] || die "pane command requires TMUX_PANE or --pane"
  printf '%s\n' "$pane_id"
}

native_pane_mode() {
  case "${ENGINEOS_MUX_MODE:-}" in
    native)
      return 0
      ;;
    legacy)
      return 1
      ;;
    "")
      ;;
    *)
      die "ENGINEOS_MUX_MODE must be legacy or native"
      ;;
  esac
  [[ -r "$SHELL_STATE_FILE" ]] || return 1
  local mode
  mode="$(python - "$SHELL_STATE_FILE" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        state = json.load(handle)
except (OSError, ValueError) as exc:
    raise SystemExit(f"cannot parse shell state: {exc}")
print(state.get("mux", {}).get("mode", "legacy"))
PY
)" || die "pane command could not read mux mode from $SHELL_STATE_FILE"
  case "$mode" in
    native) return 0 ;;
    legacy) return 1 ;;
    *) die "shell state contains an unsupported mux mode: $mode" ;;
  esac
}

native_mux_bin() {
  local candidate="${ENGINEOS_MUX_BIN:-}"
  if [[ -z "$candidate" ]]; then
    candidate="$(command -v engine-mux || true)"
  fi
  [[ -n "$candidate" && -x "$candidate" ]] ||
    die "native pane command requires engine-mux"
  printf '%s\n' "$candidate"
}

native_muxctl_bin() {
  local candidate="${ENGINEOS_MUXCTL_BIN:-}"
  if [[ -z "$candidate" ]]; then
    candidate="$(command -v engine-muxctl || true)"
  fi
  [[ -n "$candidate" && -x "$candidate" ]] ||
    die "native pane list requires engine-muxctl"
  printf '%s\n' "$candidate"
}

native_focused_pane() {
  local mux_bin clients focused_session pane
  mux_bin="$(native_mux_bin)"
  clients="$("$mux_bin" list-clients \
    -F '#{client_name}|#{client_flags}|#{session_id}')" ||
    die "native game launch could not list graphical mux clients"
  focused_session="$(awk -F '|' '
    $1 ~ /^engineos-view-[0-9]+$/ && $2 ~ /(^|,)focused(,|$)/ {
      print $3
      count++
    }
    END { if (count != 1) exit 1 }
  ' <<<"$clients")" ||
    die "native game launch requires exactly one focused graphical mux view"
  [[ "$focused_session" == \$* ]] ||
    die "focused graphical mux view has an invalid session identity"
  pane="$("$mux_bin" display-message -p -t "$focused_session:" '#{pane_id}')" ||
    die "native game launch could not resolve the focused mux pane"
  [[ "$pane" =~ ^%[0-9]+$ ]] ||
    die "focused graphical mux view has an invalid pane identity"
  printf '%s\n' "$pane"
}

require_native_pane_mode() {
  native_pane_mode ||
    die "pane $1 requires the EngineOS shell to run in native mux mode"
}

PANE_COMMAND=()
adapt_pane_command() {
  PANE_COMMAND=("$@")
  [[ ${#PANE_COMMAND[@]} -gt 0 ]] || return
  case "${PANE_COMMAND[0]##*/}" in
    falkon)
      local argument dedicated=false
      for argument in "${PANE_COMMAND[@]:1}"; do
        case "$argument" in
          --no-remote|-r) dedicated=true ;;
        esac
      done
      if [[ "$dedicated" == false ]]; then
        PANE_COMMAND=("${PANE_COMMAND[0]}" --no-remote
          "${PANE_COMMAND[@]:1}")
      fi
      ;;
  esac
}

run_pane_launch() {
  local pane_id="${TMUX_PANE:-}"
  local game=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --game|-g)
        game=true
        shift
        ;;
      --pane)
        shift
        [[ $# -gt 0 ]] || die "pane launch --pane requires a tmux pane id"
        pane_id="$1"
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done
  [[ $# -gt 0 ]] || die "pane launch requires a command"
  adapt_pane_command "$@"
  set -- "${PANE_COMMAND[@]}"

  if native_pane_mode; then
    local mux_bin
    local mux_args=(launch-pane-app)
    mux_bin="$(native_mux_bin)"
    if [[ -z "$pane_id" ]]; then
      pane_id="$(native_focused_pane)"
    fi
    [[ "$game" == false ]] || mux_args+=(-g)
    mux_args+=(-t "$pane_id" --)
    log_line "pane launch mode=native pane=$pane_id presentation=$([[ "$game" == true ]] && printf game || printf wayland) command=$(quote_cmd "$@")"
    "$mux_bin" "${mux_args[@]}" "$@"
    return
  fi
  [[ -n "${TMUX:-}" && -n "$pane_id" ]] ||
    die "legacy pane launch requires TMUX and TMUX_PANE"
  [[ "$game" == false ]] ||
    die "pane launch --game requires native mux mode"
  [[ "$pane_id" == "${TMUX_PANE:-}" ]] ||
    die "legacy pane launch cannot target a different pane"

  require_shell_display "pane"
  local token
  local command_label
  local request
  token="$(pane_launch_token)"
  command_label="${1##*/}"
  request="$(pane_context_request_json pane-launch "$TMUX_PANE" "$token" "$command_label")" ||
    die "pane launch could not read tmux context for pane $TMUX_PANE"
  send_pane_shell_ipc launch "$request"

  prepare_client_env
  export ENGINEOS_PANE_LAUNCH_TOKEN="$token"
	log_line "pane launch pane=$TMUX_PANE display=${WAYLAND_DISPLAY:-missing} command=$(quote_cmd "$@")"
	exec "$@"
}

run_pane_split() {
  local pane_id="${TMUX_PANE:-}"
  local orientation=""
  local game=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|-v)
        [[ -z "$orientation" || "$orientation" == "$1" ]] ||
          die "pane split horizontal and vertical modes conflict"
        orientation="$1"
        shift
        ;;
      --game|-g)
        game=true
        shift
        ;;
      --pane)
        shift
        [[ $# -gt 0 ]] || die "pane split --pane requires a tmux pane id"
        pane_id="$1"
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done
  [[ -n "${TMUX:-}" && -n "$pane_id" ]] ||
    die "pane split requires TMUX and TMUX_PANE or --pane"
  [[ $# -gt 0 ]] || die "pane split requires a command"
  adapt_pane_command "$@"
  set -- "${PANE_COMMAND[@]}"
  require_native_pane_mode split
  local mux_bin
  local mux_args=(split-pane-app)
  mux_bin="$(native_mux_bin)"
  [[ -z "$orientation" ]] || mux_args+=("$orientation")
  [[ "$game" == false ]] || mux_args+=(-g)
  mux_args+=(-t "$pane_id" --)
  log_line "pane split mode=native pane=$pane_id presentation=$([[ "$game" == true ]] && printf game || printf wayland) command=$(quote_cmd "$@")"
  "$mux_bin" "${mux_args[@]}" "$@"
}

run_pane_view() {
  local pane_id="${TMUX_PANE:-}"
  if [[ "${1:-}" == --pane ]]; then
    shift
    [[ $# -gt 0 ]] || die "pane view --pane requires a tmux pane id"
    pane_id="$1"
    shift
  fi
  local mode="${1:-}"
  shift || true
  [[ $# -eq 0 ]] || die "pane view takes one mode"
  case "$mode" in app|console|toggle|close) ;; *)
    die "pane view requires app, console, toggle, or close" ;;
  esac
  [[ -n "$pane_id" ]] || die "pane view requires TMUX_PANE or --pane"
  require_native_pane_mode view
  "$(native_mux_bin)" pane-presentation -t "$pane_id" "$mode"
}

run_pane_signal() {
  local pane_id="${TMUX_PANE:-}"
  if [[ "${1:-}" == --pane ]]; then
    shift
    [[ $# -gt 0 ]] || die "pane signal --pane requires a tmux pane id"
    pane_id="$1"
    shift
  fi
  local signal="${1:-}"
  shift || true
  [[ $# -eq 0 ]] || die "pane signal takes one signal"
  case "$signal" in INT|TERM|KILL) ;; *)
    die "pane signal requires INT, TERM, or KILL" ;;
  esac
  [[ -n "$pane_id" ]] || die "pane signal requires TMUX_PANE or --pane"
  require_native_pane_mode signal
  "$(native_mux_bin)" signal-pane-app -t "$pane_id" "$signal"
}

run_pane_respawn() {
  local pane_id
  pane_id="$(pane_target_arg "$@")" || return 0
  require_native_pane_mode respawn
  "$(native_mux_bin)" respawn-pane-app -t "$pane_id"
}

run_pane_focus() {
	local pane_id="${TMUX_PANE:-}"
	local client_tty=""
  local request
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--pane)
				shift
				[[ $# -gt 0 ]] || die "pane focus --pane requires a tmux pane id"
				pane_id="$1"
				;;
			--client-tty)
				shift
				[[ $# -gt 0 ]] || die "pane focus --client-tty requires a tty"
				client_tty="$1"
				;;
			help|--help|-h)
				usage
				return 0
				;;
			*)
				die "unknown pane focus option: $1"
				;;
		esac
		shift
	done
	[[ -n "$pane_id" ]] || die "pane focus requires TMUX_PANE or --pane"
	[[ -z "$client_tty" || "$client_tty" == /dev/* ]] ||
		die "pane focus --client-tty must be a /dev tty"
	request="$(pane_context_request_json pane-focus "$pane_id" "" "" "$client_tty")" ||
    die "pane focus could not read tmux context for pane $pane_id"
  send_pane_shell_ipc focus "$request"
  printf 'focused pane %s\n' "$pane_id"
}

run_pane_geometry() {
  local pane_id
  local request
  pane_id="$(pane_target_arg "$@")" || return 0
  request="$(pane_context_request_json pane-geometry "$pane_id")" ||
    die "pane geometry could not read tmux context for pane $pane_id"
  send_pane_shell_ipc geometry "$request"
  printf 'updated pane %s geometry\n' "$pane_id"
}

run_pane_unbind() {
  local pane_id
  local request
  pane_id="$(pane_target_arg "$@")" || return 0
  request="$(pane_context_request_json pane-unbind "$pane_id")" ||
    die "pane unbind could not read tmux context for pane $pane_id"
  send_pane_shell_ipc unbind "$request"
  printf 'unbound pane %s\n' "$pane_id"
}

run_pane_list() {
  local json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json=true
        ;;
      help|--help|-h)
        usage
        return 0
        ;;
      *)
        die "unknown app pane list option: $1"
        ;;
    esac
    shift
  done

	if native_pane_mode; then
		local snapshot
		snapshot="$("$(native_muxctl_bin)" snapshot)" ||
			die "native pane snapshot failed"
		python - "$snapshot" "$json" <<'PY'
import json
import sys

state, as_json = json.loads(sys.argv[1]), sys.argv[2] == "true"
panes = state.get("panes", [])
if as_json:
    print(json.dumps({"ok": True, "revision": state.get("revision", 0),
                      "panes": panes}, separators=(",", ":")))
else:
    print("PANE\tACTIVE\tPRESENTATION\tVIEW\tMAPPED\tTABS\tSCOPE\tCOMMAND")
    for pane in panes:
        print("{pane_id}\t{active}\t{presentation}\t{view_mode}\t{mapped}\t"
              "{surface_tabs}\t{scope}\t{command}".format(
                  pane_id=pane.get("pane_id", ""),
                  active=bool(pane.get("active", False)),
                  presentation=pane.get("presentation", "terminal"),
                  view_mode=pane.get("view_mode", "presentation"),
                  mapped=bool(pane.get("mapped", False)),
                  surface_tabs=pane.get("surface_tabs", 0),
                  scope=pane.get("process_scope", ""),
                  command=pane.get("app_command") or pane.get("command", "")))
PY
		return
	fi

	local response
	response="$(send_shell_ipc "$(shell_ipc_socket)" \
		'{"version":1,"op":"pane-list"}')" || return 1
	python - "$response" "$json" <<'PY'
import json
import sys

state, as_json = json.loads(sys.argv[1]), sys.argv[2] == "true"
bindings = state.get("pane_bindings", [])
if as_json:
    print(json.dumps(state, separators=(",", ":")))
else:
    print("KEY\tFOCUS\tPENDING\tVIEW\tPANE\tCOMMAND")
    for binding in bindings:
        view_id = binding.get("view_id")
        print("{key}\t{focused}\t{pending}\t{view}\t{pane}\t{command}".format(
            key=binding.get("key", ""),
            focused=bool(binding.get("focused", False)),
            pending=bool(binding.get("pending", False)),
            view=view_id if view_id is not None else "",
            pane=binding.get("pane_id", ""),
            command=binding.get("command_label", ""),
        ))
PY
}

run_pane_sync() {
	local sync_all=false
	local roles=()
  local role
  local normalized
  local current_pane="${TMUX_PANE:-}"
  local changed=0
  local failed=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all|-a)
        sync_all=true
        ;;
      cube|engine|quake)
        normalized="$(normalize_layout_role "$1")" || die "unknown pane sync role: $1"
        roles+=("$normalized")
        ;;
      help|--help|-h)
        usage
        return 0
        ;;
      *)
        die "unknown pane sync option: $1"
        ;;
    esac
    shift
  done

  if [[ "$sync_all" == false && "${#roles[@]}" -eq 0 && -z "$current_pane" ]]; then
    die "pane sync requires TMUX_PANE unless --all or a role with stored pane bounds is used"
  fi

  if [[ "${#roles[@]}" -eq 0 ]]; then
    for role in cube engine; do
      role_has_pane_bounds "$role" || continue
      if [[ "$sync_all" == true ||
          "$(launch_bounds_value "$role" pane_id || true)" == "$current_pane" ]]; then
        roles+=("$role")
      fi
    done
  fi

  if [[ "${#roles[@]}" -eq 0 ]]; then
    log_line "pane sync noop reason=no-pane-bound-roles pane=${current_pane:-unknown}"
    printf 'no pane-bound roles to sync\n'
    return 0
  fi

  for role in "${roles[@]}"; do
    local pane_id="$current_pane"
    if [[ "$sync_all" == true || -z "$pane_id" ]]; then
      pane_id="$(launch_bounds_value "$role" pane_id || true)"
    fi
    if [[ -z "$pane_id" ]]; then
      log_line "pane sync skipped role=$role reason=missing-pane-id"
      failed=$((failed + 1))
      continue
    fi
    if sync_role_to_pane "$role" "$pane_id"; then
      changed=$((changed + 1))
    else
      log_line "pane sync skipped role=$role pane=$pane_id reason=tmux-geometry-unavailable"
      failed=$((failed + 1))
    fi
  done

  if (( changed > 0 )); then
    if ! notify_shell_layout_sync; then
      failed=$((failed + 1))
    fi
  fi
  (( failed == 0 ))
}

run_pane() {
  local sub="${1:-help}"
  shift || true

	case "$sub" in
	    launch)
	      run_pane_launch "$@"
	      ;;
	    split)
	      run_pane_split "$@"
	      ;;
	    view)
	      run_pane_view "$@"
	      ;;
	    signal)
	      run_pane_signal "$@"
	      ;;
	    respawn)
	      run_pane_respawn "$@"
	      ;;
	    focus)
	      run_pane_focus "$@"
	      ;;
	    geometry)
	      run_pane_geometry "$@"
	      ;;
	    unbind)
	      run_pane_unbind "$@"
	      ;;
	    list)
	      run_pane_list "$@"
	      ;;
	    sync)
	      run_pane_sync "$@"
	      ;;
    help|--help|-h)
      usage
      ;;
    *)
      die "unknown app pane action: $sub"
      ;;
  esac
}

QUAKE_LAUNCH_ARGS=()
CUBE_LAUNCH_ARGS=()

prepare_cube_layout() {
  local layout_mode="auto"
  CUBE_LAUNCH_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pane)
        layout_mode="pane"
        ;;
      --output|--no-pane)
        layout_mode="output"
        ;;
      --smoke|--smoke-ms)
        CUBE_LAUNCH_ARGS+=("$1")
        if [[ "$1" == "--smoke-ms" && $# -gt 1 ]]; then
          shift
          CUBE_LAUNCH_ARGS+=("$1")
        fi
        ;;
      *)
        CUBE_LAUNCH_ARGS+=("$1")
        ;;
    esac
    shift
  done

  if [[ "$layout_mode" == "output" ]]; then
    write_output_bounds cube "app"
    log_line "layout app=cube mode=output source=app"
    return
  fi

  local geometry
  if geometry="$(tmux_pane_geometry)"; then
    # shellcheck disable=SC2086
    write_tmux_bounds cube $geometry
    log_line "layout app=cube mode=pane source=tmux bounds=$geometry"
    return
  fi

  clear_launch_bounds cube
  log_line "layout app=cube mode=output source=no-tmux"
}

prepare_quake_layout() {
  local layout_mode="auto"
  local saw_window_flag=false
  local saw_smoke=false
  QUAKE_LAUNCH_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pane)
        layout_mode="pane"
        ;;
      --fullscreen)
        layout_mode="output"
        QUAKE_LAUNCH_ARGS+=("$1")
        saw_window_flag=true
        ;;
      --output|--no-pane)
        layout_mode="output"
        ;;
      --window)
        QUAKE_LAUNCH_ARGS+=("$1")
        saw_window_flag=true
        ;;
      --smoke)
        QUAKE_LAUNCH_ARGS+=("$1")
        saw_smoke=true
        ;;
      *)
        QUAKE_LAUNCH_ARGS+=("$1")
        ;;
    esac
    shift
  done

  if [[ "$saw_smoke" == true ]]; then
    clear_launch_bounds engine
    log_line "layout app=quake mode=output source=smoke"
    return
  fi

  if [[ "$layout_mode" == "output" ]]; then
    write_engine_output_bounds "app"
    log_line "layout app=quake mode=output source=app"
    return
  fi

  local geometry
  if geometry="$(tmux_pane_geometry)"; then
    # shellcheck disable=SC2086
    write_engine_tmux_bounds $geometry
    if [[ "$saw_window_flag" == false ]]; then
      QUAKE_LAUNCH_ARGS+=(--window)
    fi
    log_line "layout app=quake mode=pane source=tmux bounds=$geometry"
    return
  fi

  clear_launch_bounds engine
  log_line "layout app=quake mode=output source=no-tmux"
}

prepare_native_quake_args() {
  local saw_window=false
  QUAKE_LAUNCH_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pane)
        ;;
      --output|--no-pane|--fullscreen)
        die "native pane Quake does not accept $1; launch it outside the pane for output-wide presentation"
        ;;
      --window)
        saw_window=true
        QUAKE_LAUNCH_ARGS+=("$1")
        ;;
      *)
        QUAKE_LAUNCH_ARGS+=("$1")
        ;;
    esac
    shift
  done
  [[ "$saw_window" == true ]] || QUAKE_LAUNCH_ARGS+=(--window)
}

require_shell_display() {
  if [[ "${ENGINEOS_APP_REQUIRE_WAYLAND:-true}" == "true" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    write_app_state "${1:-unknown}" "failed" "missing-wayland-display"
    log_line "launch failed reason=missing-wayland-display app=${1:-unknown}"
    printf 'eos-app: WAYLAND_DISPLAY is required so engineos-shell owns graphical clients.\n' >&2
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
      write_app_state "$app" "launch-requested" "" "$@"
      log_line "launch app=terminal owner=engineos-shell display=${WAYLAND_DISPLAY:-missing}"
      ENGINEOS_TERMINAL_ROLE=terminal \
        exec "$SCRIPT_DIR/terminal_launcher.sh" -- "$@"
      ;;
    terminal-secondary)
      require_shell_display "$app"
      prepare_client_env
      write_app_state "$app" "launch-requested" "" "$@"
      log_line "launch app=terminal-secondary owner=engineos-shell display=${WAYLAND_DISPLAY:-missing}"
      ENGINEOS_TERMINAL_APP_ID="${ENGINEOS_TERMINAL_APP_ID:-engineos-terminal-secondary}" \
        ENGINEOS_TERMINAL_ROLE=terminal-secondary \
        ENGINEOS_TERMINAL_TITLE="${ENGINEOS_TERMINAL_TITLE:-EngineOS Side}" \
        ENGINEOS_TERMINAL_SESSION_CMD="${ENGINEOS_TERMINAL_SECONDARY_SESSION_CMD:-tmux new -A -s engineos-side}" \
        exec "$SCRIPT_DIR/terminal_launcher.sh" -- "$@"
      ;;
    cube)
      require_shell_display "$app"
      prepare_client_env
      prepare_cube_layout "$@"
      export SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR=0
      export SDL_VIDEO_WAYLAND_PREFER_LIBDECOR=0
      write_app_state "$app" "launch-requested" "" "${CUBE_LAUNCH_ARGS[@]}"
      log_line "launch app=cube owner=engineos-shell display=${WAYLAND_DISPLAY:-missing} sdl=${SDL_VIDEODRIVER:-unset} libdecor=${SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR:-unset} args=${CUBE_LAUNCH_ARGS[*]} log=$LOG_DIR/cube.log"
      exec engineos-cube "${CUBE_LAUNCH_ARGS[@]}" >>"$LOG_DIR/cube.log" 2>&1
      ;;
    quake)
      require_shell_display "$app"
      prepare_client_env
		if native_pane_mode; then
			local pane_id="${TMUX_PANE:-}"
			if [[ -z "$pane_id" ]]; then
				pane_id="$(native_focused_pane)"
			fi
			prepare_native_quake_args "$@"
			write_app_state "$app" "launch-requested" "" "${QUAKE_LAUNCH_ARGS[@]}"
			log_line "launch app=quake owner=native-mux pane=$pane_id display=${WAYLAND_DISPLAY:-missing} sdl=${SDL_VIDEODRIVER:-unset} args=${QUAKE_LAUNCH_ARGS[*]}"
			run_pane_launch --game --pane "$pane_id" -- \
				"$(game_cmd_string)" quake play --foreground \
				"${QUAKE_LAUNCH_ARGS[@]}"
			return
		fi
      prepare_quake_layout "$@"
      write_app_state "$app" "launch-requested" "" "${QUAKE_LAUNCH_ARGS[@]}"
      log_line "launch app=quake owner=engineos-shell display=${WAYLAND_DISPLAY:-missing} sdl=${SDL_VIDEODRIVER:-unset} args=${QUAKE_LAUNCH_ARGS[*]}"
      exec "$(game_cmd_string)" quake play "${QUAKE_LAUNCH_ARGS[@]}"
      ;;
    *)
      die "unknown app id: $app"
      ;;
  esac
}

slot_mapped_json() {
  local role="$1"
  local shell_log="$LOG_DIR/shell.log"
  local line
  local mapped

  mapped="$(shell_state_slot_mapped_json "$role" || true)"
  if [[ -n "$mapped" ]]; then
    printf '%s' "$mapped"
    return
  fi

  line="$(last_line_matching "$shell_log" "(view mapped role=$role([[:space:]]|$)|view unmapped role=$role([[:space:]]|$)|view destroyed role=$role([[:space:]]|$)|launchpad slot mapped inactive role=$role([[:space:]]|$))")"
  if [[ -z "$line" ]]; then
    printf 'null'
  elif [[ "$line" == *"view mapped role=$role"* || "$line" == *"launchpad slot mapped inactive role=$role"* ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

app_launch_state() {
  local app="$1"
  local app_log="$LOG_DIR/app.log"
  local line

  line="$(last_line_matching "$app_log" "(launch app=$app([[:space:]]|$)|launch failed .*app=$app([[:space:]]|$))")"
  if [[ -n "$line" ]]; then
    if [[ "$line" == *"launch failed"* ]]; then
      printf 'failed\n'
    else
      printf 'launch-requested\n'
    fi
    return
  fi

  if [[ "$app" == "terminal" && -r "$LOG_DIR/terminal.log" ]] &&
      grep -F 'owner=engineos-shell' "$LOG_DIR/terminal.log" >/dev/null; then
    printf 'launch-requested\n'
    return
  fi

  printf 'missing\n'
}

app_last_log() {
  local app="$1"
  local line

  line="$(last_line_matching "$LOG_DIR/app.log" "(launch app=$app([[:space:]]|$)|launch failed .*app=$app([[:space:]]|$))")"
  if [[ -z "$line" && "$app" == "terminal" ]]; then
    line="$(last_line_matching "$LOG_DIR/terminal.log" "(launch command=|launch failed)")"
  fi
  printf '%s\n' "$line"
}

slot_last_shell_log() {
  local role="$1"
  last_line_matching "$LOG_DIR/shell.log" "(launch action mapped .*role=$role([[:space:]]|$)|launch action exit .*role=$role([[:space:]]|$)|launchpad slot unavailable role=$role([[:space:]]|$)|view mapped role=$role([[:space:]]|$)|view unmapped role=$role([[:space:]]|$)|view destroyed role=$role([[:space:]]|$))"
}

shell_active_slot() {
  local line
  local value
  value="$(shell_state_string active_slot || true)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return
  fi
  line="$(last_line_matching "$LOG_DIR/shell.log" "launchpad active slot=")"
  extract_token "$line" "slot"
}

shell_bootstrap_mode() {
  local line
  local value
  value="$(shell_state_string bootstrap || true)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return
  fi
  line="$(last_line_matching "$LOG_DIR/shell.log" "bootstrap mode=")"
  extract_token "$line" "mode"
}

print_slot_json() {
  local role="$1"
  local app="$2"
  local state
  local last
  local shell_last
  local display
  local command
  state="$(app_launch_state "$app")"
  last="$(app_last_log "$app")"
  shell_last="$(slot_last_shell_log "$role")"
  display="$(extract_token "$last" "display")"
  command="$(engineos_app_manifest_value "$APPS_MANIFEST" "$app" command || true)"

  printf '    "%s": {' "$role"
  printf '"app":'
  json_string "$app"
  printf ',"command":'
  json_string "${command:-unknown}"
  printf ',"launch_state":'
  json_string "$state"
  printf ',"mapped":'
  slot_mapped_json "$role"
  printf ',"visible":'
  shell_state_slot_field_json "$role" visible || printf 'null'
  printf ',"layout":'
  shell_state_slot_field_json "$role" layout || printf 'null'
  printf ',"fullscreen":'
  shell_state_slot_field_json "$role" fullscreen || printf 'null'
  printf ',"x":'
  shell_state_slot_field_json "$role" x || printf 'null'
  printf ',"y":'
  shell_state_slot_field_json "$role" y || printf 'null'
  printf ',"width":'
  shell_state_slot_field_json "$role" width || printf 'null'
  printf ',"height":'
  shell_state_slot_field_json "$role" height || printf 'null'
  printf ',"display":'
  json_string "${display:-unknown}"
  printf ',"owner":'
  json_string "engineos-shell"
  printf ',"last_log":'
  json_string "$last"
  printf ',"shell_last_log":'
  json_string "$shell_last"
  printf '}'
}

run_status_json() {
  local active_slot
  local bootstrap
  local shell_running=false

  active_slot="$(shell_active_slot)"
  bootstrap="$(shell_bootstrap_mode)"
  if have_cmd pgrep && pgrep -x engineos-shell >/dev/null 2>&1; then
    shell_running=true
  fi

  printf '{\n'
  printf '  "ok": true,\n'
  printf '  "log_dir": '
  json_string "$LOG_DIR"
  printf ',\n'
  printf '  "state_dir": '
  json_string "$STATE_DIR"
  printf ',\n'
  printf '  "shell_state": '
  json_string "$SHELL_STATE_FILE"
  printf ',\n'
  printf '  "manifest": '
  json_string "$APPS_MANIFEST"
  printf ',\n'
  printf '  "environment": {"wayland_display":'
  json_string "${WAYLAND_DISPLAY:-unset}"
  printf ',"xdg_session_type":'
  json_string "${XDG_SESSION_TYPE:-unset}"
  printf ',"sdl_videodriver":'
  json_string "${SDL_VIDEODRIVER:-unset}"
  printf '},\n'
  printf '  "shell": {"running":%s,"bootstrap":' "$shell_running"
  json_string "${bootstrap:-unknown}"
  printf ',"active_slot":'
  json_string "${active_slot:-unknown}"
  printf ',"log":'
  json_string "$LOG_DIR/shell.log"
  printf '},\n'
  printf '  "slots": {\n'
  print_slot_json terminal terminal
  printf ',\n'
  print_slot_json terminal-secondary terminal-secondary
  printf ',\n'
  print_slot_json cube cube
  printf ',\n'
  print_slot_json engine quake
  printf '\n  },\n'
  printf '  "logs": {"app":'
  json_string "$LOG_DIR/app.log"
  printf ',"terminal":'
  json_string "$LOG_DIR/terminal.log"
  printf ',"cube":'
  json_string "$LOG_DIR/cube.log"
  printf ',"engine":'
  json_string "$LOG_DIR/engine.log"
  printf '}\n'
  printf '}\n'
}

run_status() {
  local json=false
  local active_slot
  local bootstrap
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json=true
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown app status option: $1"
        ;;
    esac
    shift
  done

  if [[ "$json" == true ]]; then
    run_status_json
    return
  fi

  printf 'EngineOS app launcher\n'
  printf '  WAYLAND_DISPLAY: %s\n' "${WAYLAND_DISPLAY:-unset}"
  printf '  XDG_SESSION_TYPE: %s\n' "${XDG_SESSION_TYPE:-unset}"
  printf '  SDL_VIDEODRIVER: %s\n' "${SDL_VIDEODRIVER:-unset}"
  printf '  log: %s/app.log\n' "$LOG_DIR"
  printf '  cube_log: %s/cube.log\n' "$LOG_DIR"
  printf '  state: %s/apps\n' "$STATE_DIR"
  printf '  shell_state: %s\n' "$SHELL_STATE_FILE"
  bootstrap="$(shell_bootstrap_mode)"
  active_slot="$(shell_active_slot)"
  printf '  shell_bootstrap: %s\n' "${bootstrap:-unknown}"
  printf '  active_slot: %s\n' "${active_slot:-unknown}"
  printf '  terminal: %s\n' "$(app_launch_state terminal)"
  printf '  terminal-secondary: %s\n' "$(app_launch_state terminal-secondary)"
  printf '  cube: %s\n' "$(app_launch_state cube)"
  printf '  quake: %s\n' "$(app_launch_state quake)"
}

manifest_get() {
  local app="$1"
  local key="$2"
  engineos_app_manifest_value "$APPS_MANIFEST" "$app" "$key"
}

manifest_expect_value() {
  local app="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(manifest_get "$app" "$key" || true)"
  if [[ "$actual" == "$expected" ]]; then
    manifest_ok "$app.$key = $expected"
  else
    manifest_fail "$app.$key expected '$expected' got '${actual:-missing}'"
  fi
}

manifest_expect_nonempty() {
  local app="$1"
  local key="$2"
  local actual

  actual="$(manifest_get "$app" "$key" || true)"
  if [[ -n "$actual" ]]; then
    manifest_ok "$app.$key present"
  else
    manifest_fail "$app.$key missing"
  fi
}

manifest_expect_app_id() {
  local app="$1"
  local app_id="$2"

  if engineos_app_manifest_array_contains "$APPS_MANIFEST" "$app" app_ids "$app_id"; then
    manifest_ok "$app.app_ids contains $app_id"
  else
    manifest_fail "$app.app_ids missing $app_id"
  fi
}

run_manifest_validate() {
  manifest_failures=0

  printf 'EngineOS app manifest validation\n'
  printf '  manifest: %s\n' "$APPS_MANIFEST"

  if [[ ! -r "$APPS_MANIFEST" ]]; then
    manifest_fail "manifest is not readable: $APPS_MANIFEST"
    printf 'App manifest validation summary: %s failure(s)\n' "$manifest_failures"
    return 1
  fi

  manifest_expect_value terminal slot terminal
  manifest_expect_value terminal role terminal
  manifest_expect_value terminal command "eos-app launch terminal"
  manifest_expect_value terminal package foot
  manifest_expect_app_id terminal foot
  manifest_expect_nonempty terminal log
  manifest_expect_value terminal input normal
  manifest_expect_value terminal instance dedicated

  manifest_expect_value terminal-secondary slot terminal-secondary
  manifest_expect_value terminal-secondary role terminal-secondary
  manifest_expect_value terminal-secondary command "eos-app launch terminal-secondary"
  manifest_expect_value terminal-secondary package foot
  manifest_expect_app_id terminal-secondary engineos-terminal-secondary
  manifest_expect_nonempty terminal-secondary log
  manifest_expect_value terminal-secondary input normal
  manifest_expect_value terminal-secondary instance dedicated

  manifest_expect_value cube slot cube
  manifest_expect_value cube role cube
  manifest_expect_value cube command "eos-app launch cube"
  manifest_expect_value cube smoke_command "eos-app launch cube --smoke"
  manifest_expect_value cube package engineos-cube
  manifest_expect_app_id cube engineos-cube
  manifest_expect_value cube health gl-renderer-and-frames
  manifest_expect_value cube input normal
  manifest_expect_value cube instance dedicated

  manifest_expect_value quake slot engine
  manifest_expect_value quake role engine
  manifest_expect_value quake command "eos-app launch quake"
  manifest_expect_value quake smoke_command "eos-app launch quake --smoke"
  manifest_expect_value quake package engineos-quakespasm
  manifest_expect_app_id quake quakespasm
  manifest_expect_value quake assets quake
  manifest_expect_value quake input game
  manifest_expect_value quake instance dedicated

  manifest_expect_value falkon slot pane
  manifest_expect_value falkon role pane
  manifest_expect_value falkon command "eos-app pane launch -- falkon"
  manifest_expect_value falkon package falkon
  manifest_expect_app_id falkon org.kde.falkon
  manifest_expect_value falkon input normal
  manifest_expect_value falkon instance dedicated

  printf 'App manifest validation summary: %s failure(s)\n' "$manifest_failures"
  [[ "$manifest_failures" -eq 0 ]]
}

run_manifest() {
  local sub="${1:-help}"
  shift || true

  case "$sub" in
    path)
      printf '%s\n' "$APPS_MANIFEST"
      ;;
    show)
      [[ -r "$APPS_MANIFEST" ]] || die "app manifest missing: $APPS_MANIFEST"
      cat "$APPS_MANIFEST"
      ;;
    validate)
      run_manifest_validate
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      die "unknown app manifest action: $sub"
      ;;
  esac
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
      printf '  command:  eos-app launch %s' "${app:-missing}"
      printf ' %q' "$@"
      printf '\n'
      exit 0
    fi
    run_launch "$@"
    ;;
  status)
    run_status "$@"
    ;;
  recover)
    run_recover "$@"
    ;;
	terminal)
		run_terminal "$@"
		;;
  pane)
    run_pane "$@"
    ;;
  window)
    run_window "$@"
    ;;
  manifest)
    run_manifest "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown app action: $ACTION"
    ;;
esac
