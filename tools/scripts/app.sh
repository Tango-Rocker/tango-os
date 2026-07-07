#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
LOG_DIR="${ENGINEOS_LOG_DIR:-$(engineos_default_log_dir "$ROOT")}"
STATE_DIR="${ENGINEOS_STATE_DIR:-$(engineos_default_state_dir "$ROOT")}"
APP_STATE_DIR="$STATE_DIR/apps"
SHELL_STATE_FILE="$STATE_DIR/shell-state.json"
LAUNCH_BOUNDS_DIR="$STATE_DIR/launch-bounds"
WINDOW_BOUNDS_DIR="$STATE_DIR/window-bounds"
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
       app.sh pane sync [--all|cube|engine|quake]
       app.sh window list [--json]
       app.sh window focus WINDOW_ID
       app.sh window bind WINDOW_ID [--pane TMUX_PANE]
       app.sh window launch -- COMMAND [ARG...]
       app.sh status [--json]
       app.sh manifest path|show|validate

Launch graphical applications through the EngineOS shell-owned Wayland session.
The app layer enforces the common client environment and dispatches to the
terminal launcher, cube app, or engine runner.

Quake launches from inside tmux default to the invoking pane's bounds. Use
--fullscreen or --output to clear pane bounds for the launch.
pane sync refreshes existing tmux-pane launch bounds and asks engineos-shell to
re-layout mapped panel clients without restarting them.
recover asks the running shell to refresh IPC or relaunch a shell-owned slot
without restarting the compositor service.
window commands inspect, focus, bind, or launch arbitrary shell-managed GUI
windows such as Qt apps and browsers.
HELP
}

runtime_cmd_string() {
  if [[ -n "${ENGINEOS_RUNTIME_CMD:-}" ]]; then
    printf '%s\n' "$ENGINEOS_RUNTIME_CMD"
    return
  fi
  if [[ -x "$ROOT/tools/engineos/eos-runtime" ]]; then
    printf '%s\n' "$ROOT/tools/engineos/eos-runtime"
  else
    printf '%s\n' eos-runtime
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

shell_relayout_windows() {
  local socket_path
  local response
  if [[ "${ENGINEOS_APP_NOTIFY_SHELL:-true}" != "true" ]]; then
    log_line "window relayout notify=skipped reason=disabled"
    return 0
  fi
  socket_path="$(shell_ipc_socket)"
  if response="$(send_shell_ipc "$socket_path" '{"version":1,"op":"relayout-windows"}' 2>&1)"; then
    log_line "window relayout method=shell-ipc socket=$socket_path"
    return 0
  fi
  log_line "window relayout ipc=failed socket=$socket_path error=$response"
  notify_shell_layout_sync
}

window_bounds_file() {
  local window_id="$1"
  printf '%s/%s.env\n' "$WINDOW_BOUNDS_DIR" "$window_id"
}

write_window_tmux_bounds() {
  local window_id="$1"
  local pane_left="$2"
  local pane_top="$3"
  local pane_width="$4"
  local pane_height="$5"
  local window_width="$6"
  local window_height="$7"
  local pane_id="${8:-${TMUX_PANE:-unknown}}"
  local file
  local tmp

  mkdir -p "$WINDOW_BOUNDS_DIR"
  file="$(window_bounds_file "$window_id")"
  tmp="$file.$$"
  {
    printf 'schema=engineos-window-bounds-v0\n'
    printf 'window_id=%s\n' "$window_id"
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
  python - "$SHELL_STATE_FILE" "$WINDOW_BOUNDS_DIR" "$json" <<'PY'
import json
import os
import sys

state_file, bounds_dir, as_json = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
with open(state_file, "r", encoding="utf-8") as handle:
    state = json.load(handle)

windows = []
for item in state.get("windows", []):
    window_id = item.get("id")
    bound = False
    pane_id = ""
    if isinstance(window_id, int):
        bounds_file = os.path.join(bounds_dir, f"{window_id}.env")
        if os.path.exists(bounds_file):
            bound = True
            with open(bounds_file, "r", encoding="utf-8") as handle:
                for line in handle:
                    key, _, value = line.strip().partition("=")
                    if key == "pane_id":
                        pane_id = value
                        break
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
        "bound": bound,
        "pane_id": pane_id,
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

  local pane_id="${TMUX_PANE:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pane)
        shift
        [[ $# -gt 0 ]] || die "window bind --pane requires a tmux pane id"
        pane_id="$1"
        ;;
      help|--help|-h)
        usage
        return 0
        ;;
      *)
        die "unknown app window bind option: $1"
        ;;
    esac
    shift
  done
  [[ -n "$pane_id" ]] || die "window bind requires TMUX_PANE or --pane"

  local geometry
  geometry="$(tmux_pane_geometry "$pane_id")" ||
    die "window bind could not read tmux geometry for pane $pane_id"
  # shellcheck disable=SC2086
  write_window_tmux_bounds "$window_id" $geometry "$pane_id"
  shell_relayout_windows
  log_line "window bind id=$window_id source=tmux pane=$pane_id bounds=$geometry"
  printf 'bound window %s to pane %s bounds %s\n' "$window_id" "$pane_id" "$geometry"
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
      prepare_quake_layout "$@"
      write_app_state "$app" "launch-requested" "" "${QUAKE_LAUNCH_ARGS[@]}"
      log_line "launch app=quake owner=engineos-shell display=${WAYLAND_DISPLAY:-missing} sdl=${SDL_VIDEODRIVER:-unset} args=${QUAKE_LAUNCH_ARGS[*]}"
      exec "$(runtime_cmd_string)" engine launch quake "${QUAKE_LAUNCH_ARGS[@]}"
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

  manifest_expect_value terminal-secondary slot terminal-secondary
  manifest_expect_value terminal-secondary role terminal-secondary
  manifest_expect_value terminal-secondary command "eos-app launch terminal-secondary"
  manifest_expect_value terminal-secondary package foot
  manifest_expect_app_id terminal-secondary engineos-terminal-secondary
  manifest_expect_nonempty terminal-secondary log
  manifest_expect_value terminal-secondary input normal

  manifest_expect_value cube slot cube
  manifest_expect_value cube role cube
  manifest_expect_value cube command "eos-app launch cube"
  manifest_expect_value cube smoke_command "eos-app launch cube --smoke"
  manifest_expect_value cube package engineos-cube
  manifest_expect_app_id cube engineos-cube
  manifest_expect_value cube health gl-renderer-and-frames
  manifest_expect_value cube input normal

  manifest_expect_value quake slot engine
  manifest_expect_value quake role engine
  manifest_expect_value quake command "eos-app launch quake"
  manifest_expect_value quake smoke_command "eos-app launch quake --smoke"
  manifest_expect_value quake package engineos-quakespasm
  manifest_expect_app_id quake quakespasm
  manifest_expect_value quake assets quake
  manifest_expect_value quake input game

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
