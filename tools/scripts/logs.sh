#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
DEFAULT_LOG_DIR="$(engineos_default_log_dir "$ROOT")"

LOG_DIR="${ENGINEOS_LOG_DIR:-$DEFAULT_LOG_DIR}"
TARGET="${1:-}"
LAST=200
SOURCE="auto"

usage() {
  cat <<'HELP'
Usage: logs.sh shell|app|engine|runtime|live-setup|doctor|boot|all [--last N] [--files|--journal]

Show EngineOS logs from the local log directory and, when available, systemd journal.
HELP
}

target_files() {
  case "$1" in
    shell) printf '%s\n' "$LOG_DIR/shell.log" ;;
    app)
      printf '%s\n' \
        "$LOG_DIR/app.log" \
        "$LOG_DIR/cube.log"
      ;;
    engine) printf '%s\n' "$LOG_DIR/engine.log" ;;
    runtime) printf '%s\n' "$LOG_DIR/runtime-start.log" ;;
    live-setup) printf '%s\n' "$LOG_DIR/live-setup.log" ;;
    doctor) printf '%s\n' "$LOG_DIR/doctor-firstboot.log" ;;
    all)
      printf '%s\n' \
        "$LOG_DIR/live-setup.log" \
        "$LOG_DIR/doctor-firstboot.log" \
        "$LOG_DIR/runtime-start.log" \
        "$LOG_DIR/shell.log" \
        "$LOG_DIR/app.log" \
        "$LOG_DIR/cube.log" \
        "$LOG_DIR/engine.log"
      ;;
  esac
}

target_units() {
  case "$1" in
    shell) printf '%s\n' "engineos-shell.service" ;;
    engine) printf '%s\n' "engineos-engine-runner.service" ;;
    runtime) printf '%s\n' "engineos-runtime.service" ;;
    live-setup) printf '%s\n' "engineos-live-setup.service" ;;
    all)
      printf '%s\n' \
        "engineos-live-setup.service" \
        "engineos-runtime.service" \
        "engineos-shell.service" \
        "engineos-engine-runner.service"
      ;;
  esac
}

print_file_logs() {
  local found=false
  local file

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if [[ -f "$file" ]]; then
      found=true
      printf '==> %s <==\n' "$file"
      tail -n "$LAST" "$file"
    else
      printf 'No log file yet: %s\n' "$file"
    fi
  done < <(target_files "$TARGET")

  [[ "$found" == true ]]
}

print_journal_logs() {
  local found=false
  local unit

  if ! have_cmd journalctl; then
    printf 'journalctl unavailable\n'
    return 1
  fi

  if [[ "$TARGET" == "boot" ]]; then
    printf '==> journal: current boot <==\n'
    journalctl -b -n "$LAST" --no-pager 2>&1 || true
    return 0
  fi

  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    found=true
    printf '==> journal: %s <==\n' "$unit"
    journalctl -b -u "$unit" -n "$LAST" --no-pager 2>&1 || true
  done < <(target_units "$TARGET")

  [[ "$found" == true ]]
}

if [[ -z "$TARGET" || "$TARGET" == "help" || "$TARGET" == "--help" || "$TARGET" == "-h" ]]; then
  usage
  exit 0
fi
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --last)
      shift
      LAST="${1:-}"
      [[ "$LAST" =~ ^[0-9]+$ && "$LAST" -gt 0 ]] || die "--last requires a positive number"
      ;;
    --files)
      SOURCE="files"
      ;;
    --journal)
      SOURCE="journal"
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown logs option: $1"
      ;;
  esac
  shift
done

case "$TARGET" in
  shell|app|engine|runtime|live-setup|doctor|boot|all)
    ;;
  *)
    die "unknown logs target: $TARGET"
    ;;
esac

case "$SOURCE" in
  files)
    if [[ "$TARGET" == "boot" ]]; then
      printf 'No file log target for boot; use --journal.\n'
    else
      print_file_logs || true
    fi
    ;;
  journal)
    print_journal_logs || true
    ;;
  auto)
    if [[ "$TARGET" == "boot" ]]; then
      print_journal_logs || true
    elif ! print_file_logs; then
      print_journal_logs || true
    fi
    ;;
esac
