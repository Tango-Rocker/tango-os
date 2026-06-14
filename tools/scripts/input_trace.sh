#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ACTION="${1:-help}"
TRACE_PATH="${2:-}"

usage() {
  cat <<'HELP'
Usage: input_trace.sh record <trace.json>
       input_trace.sh replay <trace.json>

Record or replay a minimal input smoke trace. Real input capture is added in
the hardware phase.
HELP
}

require_trace_marker() {
  local path="$1"
  local pattern="$2"
  local message="$3"
  grep -q "$pattern" "$path" || die "$message"
}

record_trace() {
  local path="$1"
  [[ -n "$path" ]] || die "record requires a trace path"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'JSON'
{
  "format": "engineos-input-trace-v0",
  "events": [
    {"type": "focus", "mode": "shell"},
    {"type": "pointer", "event": "motion", "mode": "shell", "capture": false, "focus": "none", "device": "simulated-pointer"},
    {"type": "focus", "mode": "terminal"},
    {"type": "pointer", "event": "button", "mode": "terminal", "capture": false, "focus": "terminal", "button": "left", "state": "pressed", "device": "simulated-pointer"},
    {"type": "focus", "mode": "game"},
    {"type": "pointer", "event": "axis", "mode": "game", "capture": false, "focus": "game", "axis": "vertical", "value": 1, "device": "simulated-pointer"},
    {"type": "capture", "mode": "game", "enabled": true},
    {"type": "pointer", "event": "frame", "mode": "game", "capture": true, "focus": "game", "device": "simulated-pointer"},
    {"type": "capture", "mode": "game", "enabled": false},
    {"type": "emergency-release"}
  ]
}
JSON
  printf 'input trace recorded: %s\n' "$path"
}

replay_trace() {
  local path="$1"
  [[ -n "$path" ]] || die "replay requires a trace path"
  [[ -f "$path" ]] || die "missing input trace: $path"
  require_trace_marker "$path" '"format": "engineos-input-trace-v0"' "input trace has unknown format"
  require_trace_marker "$path" '"type": "focus", "mode": "shell"' "input trace missing shell focus mode"
  require_trace_marker "$path" '"type": "focus", "mode": "terminal"' "input trace missing terminal focus mode"
  require_trace_marker "$path" '"type": "focus", "mode": "game"' "input trace missing game focus mode"
  require_trace_marker "$path" '"type": "capture", "mode": "game", "enabled": true' "input trace missing capture enable"
  require_trace_marker "$path" '"type": "capture", "mode": "game", "enabled": false' "input trace missing capture disable"
  require_trace_marker "$path" '"type": "pointer", "event": "motion"' "input trace missing pointer motion event"
  require_trace_marker "$path" '"type": "pointer", "event": "button"' "input trace missing pointer button event"
  require_trace_marker "$path" '"type": "pointer", "event": "axis"' "input trace missing pointer axis event"
  require_trace_marker "$path" '"type": "pointer", "event": "frame"' "input trace missing pointer frame event"
  require_trace_marker "$path" '"capture": true' "input trace missing captured pointer context"
  require_trace_marker "$path" '"focus": "game"' "input trace missing game pointer focus context"
  require_trace_marker "$path" '"emergency-release"' "input trace does not include emergency-release"
  printf 'input trace replayed: %s\n' "$path"
}

case "$ACTION" in
  record)
    record_trace "$TRACE_PATH"
    ;;
  replay)
    replay_trace "$TRACE_PATH"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown input trace action: $ACTION"
    ;;
esac
