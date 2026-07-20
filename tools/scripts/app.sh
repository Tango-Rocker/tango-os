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
	   app.sh launch wargus [--smoke] [STRATAGUS_ARGS...]
	   app.sh launch chroma [args...]
	   app.sh recover preview
       app.sh pane launch [--game] [--pane TMUX_PANE] -- COMMAND [ARG...]
       app.sh pane split [-h|-v] [--game] [--pane TMUX_PANE] -- COMMAND [ARG...]
       app.sh pane view [--pane TMUX_PANE] app|console|toggle|close
       app.sh pane signal [--pane TMUX_PANE] INT|TERM|KILL
       app.sh pane respawn [--pane TMUX_PANE]
       app.sh pane list [--json]
       app.sh window list [--json]
       app.sh window focus WINDOW_ID
       app.sh status [--json]
       app.sh manifest path|show|validate

Launch graphical applications through tmux-owned panes in the EngineOS Wayland
session. The app layer enforces the common client environment and dispatches
native mux commands.

recover checks the compositor observability IPC without restarting it.
pane launch binds arbitrary GUI apps to the invoking tmux pane through the
authoritative tmux server. Window commands remain for diagnostics and manual
recovery.
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

write_app_state() {
  local app="$1"
  local state="$2"
  local reason="${3:-}"
  shift 3 || true

  mkdir -p "$APP_STATE_DIR"
  {
    printf 'app=%s\n' "$app"
    printf 'state=%s\n' "$state"
    printf 'owner=tmux\n'
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

is_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
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
    help|--help|-h)
      usage
      ;;
    *)
      die "unknown app window action: $sub"
      ;;
  esac
}

recover_preview_ipc() {
  send_shell_ipc "$(shell_ipc_socket)" '{"version":1,"op":"ping"}' >/dev/null
  printf 'shell IPC is responsive\n'
}

run_recover() {
  local target="${1:-}"
  shift || true
  [[ $# -eq 0 ]] || die "recover takes exactly one target"
  case "$target" in
    preview|ipc|mc)
      recover_preview_ipc
      ;;
    help|--help|-h|"")
      usage
      ;;
    *)
      die "unknown recover target: $target"
      ;;
	esac
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

tmux_bin() {
  local candidate="${ENGINEOS_TMUX_BIN:-}"
  if [[ -z "$candidate" ]]; then
    candidate="$(command -v tmux || true)"
  fi
  [[ -n "$candidate" && -x "$candidate" ]] ||
    die "pane command requires EngineOS tmux"
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
  mux_bin="$(tmux_bin)"
  clients="$("$mux_bin" list-clients \
    -F '#{client_name}|#{client_flags}|#{session_id}')" ||
    die "no focused native pane: could not list graphical mux clients"
  focused_session="$(awk -F '|' '
    $1 ~ /^engineos-view-[0-9]+$/ && $2 ~ /(^|,)focused(,|$)/ {
      print $3
      count++
    }
    END { if (count != 1) exit 1 }
  ' <<<"$clients")" ||
    die "no focused native pane: launch from an EngineOS graphical mux view"
  [[ "$focused_session" == \$* ]] ||
    die "no focused native pane: graphical view has an invalid session"
  pane="$("$mux_bin" display-message -p -t "$focused_session:" '#{pane_id}')" ||
    die "no focused native pane: graphical view has no selected pane"
  [[ "$pane" =~ ^%[0-9]+$ ]] ||
    die "no focused native pane: graphical view returned an invalid pane"
  printf '%s\n' "$pane"
}

PANE_COMMAND=()
adapt_pane_command() {
  PANE_COMMAND=("$@")
  [[ ${#PANE_COMMAND[@]} -gt 0 ]] || return
  case "${PANE_COMMAND[0]##*/}" in
    falkon)
      local argument dedicated=false profile=false
      for argument in "${PANE_COMMAND[@]:1}"; do
        case "$argument" in
          --no-remote|-r) dedicated=true ;;
          --profile|--profile=*|-p) profile=true ;;
        esac
      done
      if [[ "$dedicated" == false ]]; then
        PANE_COMMAND=("${PANE_COMMAND[0]}" --no-remote
          "${PANE_COMMAND[@]:1}")
      fi
      if [[ "$profile" == false ]]; then
        PANE_COMMAND=("${PANE_COMMAND[@]}" --profile engineos)
      fi
      ;;
  esac
}

forward_pane_client_env() {
  [[ -n "${WAYLAND_DISPLAY:-}" ]] || return 0
  PANE_COMMAND=(
    env -u DISPLAY
    "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
    "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-wayland}"
    "SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-wayland}"
    "GDK_BACKEND=${GDK_BACKEND:-wayland}"
    "QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-wayland}"
    "${PANE_COMMAND[@]}"
  )
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
  forward_pane_client_env
  set -- "${PANE_COMMAND[@]}"

  local mux_bin
  local mux_args=(launch-pane-app)
  mux_bin="$(tmux_bin)"
  if [[ -z "$pane_id" ]]; then
    pane_id="$(native_focused_pane)"
  fi
  [[ "$game" == false ]] || mux_args+=(-g)
  mux_args+=(-t "$pane_id" --)
  log_line "pane launch pane=$pane_id presentation=$([[ "$game" == true ]] && printf game || printf wayland) command=$(quote_cmd "$@")"
  "$mux_bin" "${mux_args[@]}" "$@"
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
  forward_pane_client_env
  set -- "${PANE_COMMAND[@]}"
  local mux_bin
  local mux_args=(split-pane-app)
  mux_bin="$(tmux_bin)"
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
  "$(tmux_bin)" pane-presentation -t "$pane_id" "$mode"
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
  "$(tmux_bin)" signal-pane-app -t "$pane_id" "$signal"
}

run_pane_respawn() {
  local pane_id
  pane_id="$(pane_target_arg "$@")" || return 0
  "$(tmux_bin)" respawn-pane-app -t "$pane_id"
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

	local snapshot
	snapshot="$("$(native_muxctl_bin)" snapshot)" ||
		die "pane snapshot failed"
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
	    list)
	      run_pane_list "$@"
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

prepare_quake_args() {
  local saw_window=false
  QUAKE_LAUNCH_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pane)
        ;;
      --output|--no-pane|--fullscreen)
        die "pane Quake does not accept $1"
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
  if [[ "${ENGINEOS_APP_REQUIRE_WAYLAND:-true}" != "true" ||
      -n "${WAYLAND_DISPLAY:-}" ]]; then
    return
  fi

  local display socket runtime_dir
  display="$(shell_state_string wayland_display || true)"
  runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if [[ "$display" == /* ]]; then
    socket="$display"
  elif [[ -n "$display" && "$display" != */* &&
      "$display" != *[!A-Za-z0-9._-]* ]]; then
    socket="$runtime_dir/$display"
  else
    socket=""
  fi
  if [[ -n "$socket" && -S "$socket" ]] &&
      python - "$socket" <<'PY'
import socket
import sys

try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(0.5)
        client.connect(sys.argv[1])
except OSError:
    raise SystemExit(1)
PY
  then
    export WAYLAND_DISPLAY="$display"
    log_line "client display derived source=shell-state display=$(printf '%q' "$display")"
    return
  fi

  write_app_state "${1:-unknown}" "failed" "missing-wayland-display"
  log_line "launch failed reason=missing-wayland-display app=${1:-unknown}"
  printf 'eos-app: WAYLAND_DISPLAY is unset and no live engineos-shell display could be derived from %s.\n' \
    "$SHELL_STATE_FILE" >&2
  return 125
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

run_manifest_launch() {
  local app="$1"
  shift
  local launch_mode
  local pane_id="${TMUX_PANE:-}"
  local user_service
  local -a manifest_argv=()

  launch_mode="$(manifest_get "$app" launch_mode || true)"
  [[ "$launch_mode" == "pane-wayland" ]] ||
    die "app $app has unsupported launch_mode: ${launch_mode:-missing}"
  if [[ -z "$pane_id" ]]; then
    pane_id="$(native_focused_pane)"
  fi
  require_shell_display "$app"
  prepare_client_env
  mapfile -t manifest_argv < <(
    engineos_app_manifest_array_lines "$APPS_MANIFEST" "$app" argv
  )
  [[ ${#manifest_argv[@]} -gt 0 ]] ||
    die "app $app manifest argv is missing"
  [[ "${manifest_argv[0]}" == /* ]] ||
    die "app $app manifest argv must start with an absolute executable"
  [[ -x "${manifest_argv[0]}" ]] ||
    die "app $app executable is unavailable: ${manifest_argv[0]}"
  user_service="$(manifest_get "$app" user_service || true)"
  if [[ -n "$user_service" ]]; then
    local systemctl_bin="${ENGINEOS_SYSTEMCTL_BIN:-systemctl}"
    command -v "$systemctl_bin" >/dev/null 2>&1 ||
      die "app $app requires user service $user_service but systemctl is unavailable"
    "$systemctl_bin" --user start "$user_service" ||
      die "app $app could not start user service $user_service"
  fi
  write_app_state "$app" "launch-requested" "" "$@"
  log_line "launch app=$app owner=tmux pane=$pane_id mode=$launch_mode command=$(quote_cmd "${manifest_argv[@]}" "$@")"
  run_pane_launch --pane "$pane_id" -- "${manifest_argv[@]}" "$@"
}

run_launch() {
  local app="${1:-}"
  [[ -n "$app" ]] || die "app launch requires an app id"
  shift || true

  case "$app" in
    terminal)
      write_app_state "$app" "launch-requested" "" "$@"
      log_line "launch app=terminal owner=tmux"
      "$(tmux_bin)" new-window "$@"
      ;;
    terminal-secondary)
      write_app_state "$app" "launch-requested" "" "$@"
      log_line "launch app=terminal-secondary owner=tmux session=engineos-side"
      "$(tmux_bin)" new-session -d -A -s engineos-side "$@"
      ;;
    cube)
      write_app_state "$app" "launch-requested" "" "$@"
      log_line "launch app=cube owner=tmux command=engineos-cube"
      run_pane_launch -- engineos-cube "$@"
      ;;
    quake)
      require_shell_display "$app"
      prepare_client_env
      local pane_id="${TMUX_PANE:-}"
      if [[ -z "$pane_id" ]]; then
        pane_id="$(native_focused_pane)"
      fi
      prepare_quake_args "$@"
      write_app_state "$app" "launch-requested" "" "${QUAKE_LAUNCH_ARGS[@]}"
      log_line "launch app=quake owner=tmux pane=$pane_id display=${WAYLAND_DISPLAY:-missing} sdl=${SDL_VIDEODRIVER:-unset} args=${QUAKE_LAUNCH_ARGS[*]}"
      run_pane_launch --game --pane "$pane_id" -- \
        "$(game_cmd_string)" quake play --foreground \
        "${QUAKE_LAUNCH_ARGS[@]}"
      ;;
    wargus)
      write_app_state "$app" "launch-requested" "" "$@"
      log_line "launch app=wargus owner=tmux command=engineos-wargus args=$(quote_cmd "$@")"
      run_pane_launch --game -- engineos-wargus "$@"
      ;;
    *)
      if [[ -n "$(engineos_app_manifest_section "$APPS_MANIFEST" "$app")" ]]; then
        run_manifest_launch "$app" "$@"
      else
        die "unknown app id: $app"
      fi
      ;;
  esac
}

app_launch_state() {
  local app="$1"
  local status_file="$APP_STATE_DIR/$app.status"
  if [[ -r "$status_file" ]]; then
    sed -n 's/^state=//p' "$status_file" | tail -n 1
  else
    printf 'missing\n'
  fi
}

run_status_json() {
  local shell_running=false
  have_cmd pgrep && pgrep -x engineos-shell >/dev/null 2>&1 && shell_running=true
  printf '{"ok":true,"authority":"tmux","shell_running":%s,"shell_state":' "$shell_running"
  json_string "$SHELL_STATE_FILE"
  printf ',"manifest":'
  json_string "$APPS_MANIFEST"
  printf ',"apps":{"terminal":'
  json_string "$(app_launch_state terminal)"
  printf ',"terminal-secondary":'
  json_string "$(app_launch_state terminal-secondary)"
  printf ',"cube":'
  json_string "$(app_launch_state cube)"
  printf ',"quake":'
  json_string "$(app_launch_state quake)"
  printf ',"wargus":'
  json_string "$(app_launch_state wargus)"
  printf ',"chroma":'
  json_string "$(app_launch_state chroma)"
  printf '}}\n'
}

run_status() {
  local json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=true ;;
      help|--help|-h) usage; return ;;
      *) die "unknown app status option: $1" ;;
    esac
    shift
  done
  if [[ "$json" == true ]]; then
    run_status_json
    return
  fi
  printf 'EngineOS app launcher (authority: tmux)\n'
  printf '  shell_state: %s\n' "$SHELL_STATE_FILE"
  printf '  terminal: %s\n' "$(app_launch_state terminal)"
  printf '  terminal-secondary: %s\n' "$(app_launch_state terminal-secondary)"
  printf '  cube: %s\n' "$(app_launch_state cube)"
  printf '  quake: %s\n' "$(app_launch_state quake)"
  printf '  wargus: %s\n' "$(app_launch_state wargus)"
  printf '  chroma: %s\n' "$(app_launch_state chroma)"
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

	manifest_expect_value cube slot pane
	manifest_expect_value cube role presentation
  manifest_expect_value cube command "eos-app launch cube"
  manifest_expect_value cube smoke_command "eos-app launch cube --smoke"
  manifest_expect_value cube package engineos-cube
  manifest_expect_app_id cube engineos-cube
  manifest_expect_value cube health gl-renderer-and-frames
  manifest_expect_value cube input normal
  manifest_expect_value cube instance dedicated

	manifest_expect_value quake slot pane
	manifest_expect_value quake role presentation
  manifest_expect_value quake command "eos-app launch quake"
  manifest_expect_value quake smoke_command "eos-app launch quake --smoke"
  manifest_expect_value quake package engineos-quakespasm
  manifest_expect_app_id quake quakespasm
  manifest_expect_value quake assets quake
  manifest_expect_value quake input game
  manifest_expect_value quake instance dedicated

  manifest_expect_value wargus slot pane
  manifest_expect_value wargus role presentation
  manifest_expect_value wargus command "eos-app launch wargus"
  manifest_expect_value wargus smoke_command "eos-app launch wargus --smoke"
  manifest_expect_value wargus package engineos-wargus
  manifest_expect_app_id wargus stratagus
  manifest_expect_value wargus log launcher.log
  manifest_expect_value wargus health pane-presentation
  manifest_expect_value wargus input game
  manifest_expect_value wargus capture optional
  manifest_expect_value wargus instance dedicated

  manifest_expect_value falkon slot pane
	manifest_expect_value falkon role presentation
  manifest_expect_value falkon command "eos-app launch falkon"
  manifest_expect_value falkon launch_mode pane-wayland
  manifest_expect_value falkon argv '["/usr/bin/falkon"]'
  manifest_expect_value falkon commands '["falkon"]'
  manifest_expect_value falkon package falkon
  manifest_expect_app_id falkon org.kde.falkon
  manifest_expect_value falkon input normal
  manifest_expect_value falkon instance dedicated

  manifest_expect_value chroma slot pane
	manifest_expect_value chroma role presentation
  manifest_expect_value chroma command "eos-app launch chroma"
  manifest_expect_value chroma launch_mode pane-wayland
  manifest_expect_value chroma commands '["chroma"]'
  manifest_expect_value chroma argv '["/usr/bin/chroma-launcher-client"]'
  manifest_expect_value chroma user_service chroma-worker.service
  manifest_expect_value chroma package stable-diffusion.cpp-pipefusion
  manifest_expect_app_id chroma stable-diffusion-chroma
  manifest_expect_value chroma health pane-presentation
  manifest_expect_value chroma input normal
  manifest_expect_value chroma instance dedicated

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
	  printf '  owner:    tmux\n'
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
