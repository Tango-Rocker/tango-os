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
       app.sh launch cube [--smoke]
       app.sh launch quake [--smoke]
       app.sh status [--json]
       app.sh manifest path|show|validate

Launch graphical applications through the EngineOS shell-owned Wayland session.
The app layer enforces the common client environment and dispatches to the
terminal launcher, cube app, or engine runner.
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
      exec "$SCRIPT_DIR/terminal_launcher.sh" -- "$@"
      ;;
    cube)
      require_shell_display "$app"
      prepare_client_env
      write_app_state "$app" "launch-requested" "" "$@"
      log_line "launch app=cube owner=engineos-shell display=${WAYLAND_DISPLAY:-missing} sdl=${SDL_VIDEODRIVER:-unset} args=$* log=$LOG_DIR/cube.log"
      exec engineos-cube "$@" >>"$LOG_DIR/cube.log" 2>&1
      ;;
    quake)
      require_shell_display "$app"
      prepare_client_env
      write_app_state "$app" "launch-requested" "" "$@"
      log_line "launch app=quake owner=engineos-shell display=${WAYLAND_DISPLAY:-missing} sdl=${SDL_VIDEODRIVER:-unset} args=$*"
      exec "$(runtime_cmd_string)" engine launch quake "$@"
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

  line="$(last_line_matching "$shell_log" "(view mapped role=$role|view unmapped role=$role|view destroyed role=$role|launchpad slot mapped inactive role=$role)")"
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

  line="$(last_line_matching "$app_log" "(launch app=$app|launch failed .*app=$app)")"
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

  line="$(last_line_matching "$LOG_DIR/app.log" "(launch app=$app|launch failed .*app=$app)")"
  if [[ -z "$line" && "$app" == "terminal" ]]; then
    line="$(last_line_matching "$LOG_DIR/terminal.log" "(launch command=|launch failed)")"
  fi
  printf '%s\n' "$line"
}

slot_last_shell_log() {
  local role="$1"
  last_line_matching "$LOG_DIR/shell.log" "(launch action mapped .*role=$role|launch action exit .*role=$role|launchpad slot unavailable role=$role|view mapped role=$role|view unmapped role=$role|view destroyed role=$role)"
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
