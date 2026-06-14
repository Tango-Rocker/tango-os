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
  STATE_DIR="${ENGINEOS_STATE_DIR:-$(engineos_default_state_dir "$ROOT")}"
  LOG_DIR="${ENGINEOS_LOG_DIR:-$(engineos_default_log_dir "$ROOT")}"
else
  STATE_DIR="${ENGINEOS_STATE_DIR:-$(engineos_default_state_dir "$ROOT")}"
  LOG_DIR="${ENGINEOS_LOG_DIR:-$(engineos_default_log_dir "$ROOT")}"
fi

SOCKET_FILE="${ENGINEOS_ENGINE_SOCKET:-$STATE_DIR/engine-runner.sock}"
DAEMON_PID_FILE="$STATE_DIR/engine-runner.pid"
DAEMON_SCRIPT="$SCRIPT_DIR/engine_runner_daemon.py"

usage() {
  cat <<'HELP'
Usage: engine_runner.sh status
       engine_runner.sh launch quake [--smoke]
       engine_runner.sh quit
       engine_runner.sh restart [quake] [--smoke]
       engine_runner.sh daemon-stop

The runner uses a Unix domain socket protocol internally:
  engine.status
  engine.launch
  engine.quit
  engine.restart
HELP
}

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$LOG_DIR"
}

python_bin() {
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
  elif command -v python >/dev/null 2>&1; then
    command -v python
  else
    return 1
  fi
}

daemon_running() {
  [[ -S "$SOCKET_FILE" ]]
}

start_daemon() {
  local py
  py="$(python_bin)" || die "python3 is required for engine-runner socket mode"
  [[ -f "$DAEMON_SCRIPT" ]] || die "engine runner daemon missing: $DAEMON_SCRIPT"

  ensure_dirs
  if daemon_running; then
    return 0
  fi

  ENGINEOS_ROOT="$ROOT" \
  ENGINEOS_STATE_DIR="$STATE_DIR" \
  ENGINEOS_LOG_DIR="$LOG_DIR" \
    "$py" "$DAEMON_SCRIPT" --daemon --socket "$SOCKET_FILE" >>"$LOG_DIR/engine-runner.log" 2>&1 &
  printf '%s\n' "$!" >"$DAEMON_PID_FILE"

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    daemon_running && return 0
    sleep 0.1
  done

  die "engine runner daemon did not create socket: $SOCKET_FILE"
}

request() {
  local method="$1"
  shift || true
  local py
  py="$(python_bin)" || die "python3 is required for engine-runner socket mode"
  start_daemon
  ENGINEOS_ROOT="$ROOT" \
  ENGINEOS_STATE_DIR="$STATE_DIR" \
  ENGINEOS_LOG_DIR="$LOG_DIR" \
    "$py" "$DAEMON_SCRIPT" --client --socket "$SOCKET_FILE" "$method" "$@"
}

ACTION="${1:-help}"
shift || true

case "$ACTION" in
  status)
    request engine.status
    ;;
  launch)
    target="${1:-}"
    [[ -n "$target" ]] || die "engine launch requires a target"
    shift || true
    request engine.launch "$target" "$@"
    ;;
  quit)
    request engine.quit
    ;;
  restart)
    if [[ $# -gt 0 ]]; then
      target="$1"
      shift || true
      request engine.restart "$target" "$@"
    else
      request engine.restart
    fi
    ;;
  daemon-stop)
    request engine.daemon.stop
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown engine action: $ACTION"
    ;;
esac
