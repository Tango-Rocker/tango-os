#!/usr/bin/env bash
set -euo pipefail

state_dir() {
  if [[ -n "${ENGINEOS_OBSERVABILITY_STATE_DIR:-}" ]]; then
    printf '%s\n' "$ENGINEOS_OBSERVABILITY_STATE_DIR"
  elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s\n' "$XDG_STATE_HOME/engineos"
  else
    printf '%s\n' "${HOME:-/tmp}/.local/state/engineos"
  fi
}

STATE_DIR="$(state_dir)"
STATE_FILE="$STATE_DIR/observability.conf"
EVENTS_FILE="${ENGINEOS_OBSERVABILITY_EVENTS:-$STATE_DIR/events.jsonl}"

usage() {
  cat <<'HELP'
Usage:
  observability.sh status
  observability.sh enable|disable
  observability.sh prompt-login [--shell zsh|bash]
  observability.sh record --kind <kind> [metadata...]
  observability.sh tail [--last N]
  observability.sh export [--out <file>]
  observability.sh purge
  observability.sh hook zsh|bash
  observability.sh metrics [--format prometheus|json] [--out <file>]
  observability.sh exporter start|stop|status|serve|once [--host <addr>] [--port <port>]
  observability.sh tui [--once] [--watch <seconds>]

Metadata-only v0 records hashes and classifications, not raw shell commands,
raw route requests, or AI prompt/response bodies.
HELP
}

die() {
  printf 'eos-observe: %s\n' "$*" >&2
  exit 1
}

ensure_state_dir() {
  install -d -m 0700 "$STATE_DIR"
}

write_state() {
  local enabled="$1"
  ensure_state_dir
  umask 077
  {
    printf 'schema=engineos-observability-state-v0\n'
    printf 'enabled=%s\n' "$enabled"
    printf 'mode=metadata-only\n'
    printf 'events=%s\n' "$EVENTS_FILE"
  } >"$STATE_FILE"
}

is_enabled() {
  [[ -r "$STATE_FILE" ]] && grep -Fx 'enabled=true' "$STATE_FILE" >/dev/null 2>&1
}

cmd_status() {
  local state="disabled"
  is_enabled && state="enabled"
  printf 'observability: %s\n' "$state"
  printf 'mode: metadata-only\n'
  printf 'state: %s\n' "$STATE_FILE"
  printf 'events: %s\n' "$EVENTS_FILE"
}

cmd_enable() {
  write_state true
  printf 'observability enabled: metadata-only\n'
}

cmd_disable() {
  write_state false
  printf 'observability disabled\n'
}

cmd_prompt_login() {
  local shell_name=""
  local answer=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --shell)
        shift
        shell_name="${1:-}"
        [[ -n "$shell_name" ]] || die "--shell requires a value"
        ;;
      *)
        die "unknown prompt-login option: $1"
        ;;
    esac
    shift
  done

  [[ -r "$STATE_FILE" ]] && return 0

  if [[ -n "${ENGINEOS_OBSERVABILITY_PROMPT_RESPONSE:-}" ]]; then
    answer="$ENGINEOS_OBSERVABILITY_PROMPT_RESPONSE"
  else
    [[ -t 0 && -t 1 ]] || return 0
    printf 'Enable EngineOS metadata-only observability for shell and agent route events? [y/N] '
    read -r answer || answer=""
  fi

  case "${answer,,}" in
    y|yes)
      cmd_enable
      ;;
    *)
      cmd_disable
      ;;
  esac

  [[ -n "$shell_name" ]] && printf 'observability prompt handled for shell: %s\n' "$shell_name"
}

cmd_record() {
  local kind="event"
  local source="engineos"
  local shell_name=""
  local status=""
  local command_text=""
  local cwd_text=""
  local role=""
  local confidence=""
  local risk=""
  local reason=""
  local proof=""
  local request_text=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind)
        shift
        kind="${1:-}"
        ;;
      --source)
        shift
        source="${1:-}"
        ;;
      --shell)
        shift
        shell_name="${1:-}"
        ;;
      --status)
        shift
        status="${1:-}"
        ;;
      --command)
        shift
        command_text="${1:-}"
        ;;
      --cwd)
        shift
        cwd_text="${1:-}"
        ;;
      --role)
        shift
        role="${1:-}"
        ;;
      --confidence)
        shift
        confidence="${1:-}"
        ;;
      --risk)
        shift
        risk="${1:-}"
        ;;
      --reason)
        shift
        reason="${1:-}"
        ;;
      --proof)
        shift
        proof="${1:-}"
        ;;
      --request)
        shift
        request_text="${1:-}"
        ;;
      *)
        die "unknown record option: $1"
        ;;
    esac
    shift
  done

  [[ -n "$kind" ]] || die "--kind is required"
  [[ "$kind" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "kind must be lowercase hyphenated metadata"

  is_enabled || return 0
  ensure_state_dir

  ENGINEOS_OBS_KIND="$kind" \
    ENGINEOS_OBS_SOURCE="$source" \
    ENGINEOS_OBS_SHELL="$shell_name" \
    ENGINEOS_OBS_STATUS="$status" \
    ENGINEOS_OBS_COMMAND="$command_text" \
    ENGINEOS_OBS_CWD="$cwd_text" \
    ENGINEOS_OBS_ROLE="$role" \
    ENGINEOS_OBS_CONFIDENCE="$confidence" \
    ENGINEOS_OBS_RISK="$risk" \
    ENGINEOS_OBS_REASON="$reason" \
    ENGINEOS_OBS_PROOF="$proof" \
    ENGINEOS_OBS_REQUEST="$request_text" \
    python3 - <<'PY' >>"$EVENTS_FILE"
import datetime
import hashlib
import json
import os
import re
import shlex


def sha(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8", errors="replace")).hexdigest()


def command_name(command: str) -> str:
    try:
        parts = shlex.split(command, posix=True)
    except ValueError:
        parts = command.strip().split()
    while parts and ("=" in parts[0] and not parts[0].startswith("-")):
        parts.pop(0)
    while parts and parts[0] in {"sudo", "command", "time"}:
        parts.pop(0)
    if parts and parts[0] == "env":
        parts.pop(0)
        while parts and "=" in parts[0]:
            parts.pop(0)
    if not parts:
        return "unknown"
    return os.path.basename(parts[0])[:80]


def maybe_int(value: str):
    if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
        return int(value)
    return value


def maybe_float(value: str):
    try:
        return float(value)
    except ValueError:
        return value


now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
command = os.environ.get("ENGINEOS_OBS_COMMAND", "")
request = os.environ.get("ENGINEOS_OBS_REQUEST", "")
cwd = os.environ.get("ENGINEOS_OBS_CWD", "")
status = os.environ.get("ENGINEOS_OBS_STATUS", "")
confidence = os.environ.get("ENGINEOS_OBS_CONFIDENCE", "")

event = {
    "schema": "engineos-observability-v0",
    "ts": now,
    "kind": os.environ.get("ENGINEOS_OBS_KIND", "event"),
    "source": os.environ.get("ENGINEOS_OBS_SOURCE", "engineos"),
    "metadata_only": True,
}

for key, env_name in [
    ("shell", "ENGINEOS_OBS_SHELL"),
    ("role", "ENGINEOS_OBS_ROLE"),
    ("risk", "ENGINEOS_OBS_RISK"),
    ("reason", "ENGINEOS_OBS_REASON"),
    ("proof", "ENGINEOS_OBS_PROOF"),
]:
    value = os.environ.get(env_name, "")
    if value:
        event[key] = value

if status:
    event["status"] = maybe_int(status)
if confidence:
    event["confidence"] = maybe_float(confidence)
if cwd:
    event["cwd_hash"] = sha(cwd)
if command:
    event["command_hash"] = sha(command)
    event["command_name"] = command_name(command)
    event["command_redacted"] = True
    event["sensitive_pattern"] = bool(
        re.search(r"(token|secret|password|passwd|api[_-]?key|bearer)", command, re.I)
    )
if request:
    event["request_hash"] = sha(request)
    event["request_redacted"] = True

print(json.dumps(event, sort_keys=True, separators=(",", ":")))
PY
}

cmd_tail() {
  local last=20
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --last)
        shift
        last="${1:-}"
        [[ "$last" =~ ^[0-9]+$ ]] || die "--last requires a positive integer"
        ;;
      *)
        die "unknown tail option: $1"
        ;;
    esac
    shift
  done

  [[ -r "$EVENTS_FILE" ]] || {
    printf 'no observability events\n'
    return 0
  }
  tail -n "$last" "$EVENTS_FILE"
}

cmd_export() {
  local out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        shift
        out="${1:-}"
        [[ -n "$out" ]] || die "--out requires a path"
        ;;
      *)
        die "unknown export option: $1"
        ;;
    esac
    shift
  done

  if [[ -n "$out" ]]; then
    install -d -m 0700 "$(dirname "$out")"
    if [[ -r "$EVENTS_FILE" ]]; then
      install -m 0600 "$EVENTS_FILE" "$out"
    else
      : >"$out"
      chmod 0600 "$out"
    fi
    printf '%s\n' "$out"
  elif [[ -r "$EVENTS_FILE" ]]; then
    cat "$EVENTS_FILE"
  fi
}

cmd_purge() {
  rm -f "$EVENTS_FILE" "$STATE_FILE"
  printf 'observability purged\n'
}

agent_ledger_dir() {
  if [[ -n "${ENGINEOS_AGENT_LEDGER_DIR:-}" ]]; then
    printf '%s\n' "$ENGINEOS_AGENT_LEDGER_DIR"
  elif [[ -d "${ENGINEOS_ROOT:-}/tools/scripts" ]]; then
    printf '%s\n' "$ENGINEOS_ROOT/artifacts/agent-ledger"
  elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s\n' "$XDG_STATE_HOME/engineos/agent-ledger"
  else
    printf '%s\n' "${HOME:-/tmp}/.local/state/engineos/agent-ledger"
  fi
}

metrics_python() {
  python3 - <<'PY'
import collections
import datetime as dt
import json
import os
import pathlib
import sys


def read_jsonl(path):
    items = []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    items.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        pass
    return items


def parse_ts(value):
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def label(value):
    value = str(value if value not in (None, "") else "none")
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def labelset(labels):
    if not labels:
        return ""
    return "{" + ",".join(f'{key}="{label(value)}"' for key, value in labels.items()) + "}"


def metric_line(name, value, labels=None):
    return f"{name}{labelset(labels or {})} {value}"


def state_enabled(path):
    try:
        return "enabled=true" in pathlib.Path(path).read_text(encoding="utf-8")
    except FileNotFoundError:
        return False


def build_summary():
    state_file = os.environ["ENGINEOS_OBS_STATE_FILE"]
    events_file = os.environ["ENGINEOS_OBS_EVENTS_FILE"]
    ledger_dir = pathlib.Path(os.environ["ENGINEOS_AGENT_LEDGER_DIR"])
    queue_file = ledger_dir / "queue.jsonl"
    ledger_file = ledger_dir / "ledger.jsonl"
    lock_dir = ledger_dir / "dispatcher.lock"

    events = read_jsonl(events_file)
    queue = read_jsonl(queue_file)
    ledger = read_jsonl(ledger_file)

    obs_counts = collections.Counter()
    sensitive_counts = collections.Counter()
    for event in events:
        kind = event.get("kind", "unknown")
        source = event.get("source", "unknown")
        role = event.get("role", "none")
        risk = event.get("risk", "none")
        obs_counts[(kind, source, role, risk)] += 1
        if event.get("sensitive_pattern"):
            sensitive_counts[(kind, source)] += 1

    latest = {}
    ledger_counts = collections.Counter()
    for event in ledger:
        task_id = event.get("task_id", "")
        role = event.get("role", "none")
        name = event.get("event", "unknown")
        state = event.get("state", "unknown")
        reason = event.get("reason", "none")
        ledger_counts[(role, name, state, reason)] += 1
        if task_id:
            latest[task_id] = event

    task_counts = collections.Counter()
    oldest = {}
    now = dt.datetime.now(dt.timezone.utc)
    for task in queue:
        task_id = task.get("task_id", "")
        latest_event = latest.get(task_id, {})
        role = latest_event.get("role") or task.get("role", "none")
        state = latest_event.get("state", "queued")
        reason = latest_event.get("reason") or task.get("reason", "none")
        priority = task.get("priority", "normal")
        task_counts[(role, state, reason, priority)] += 1

        created_at = parse_ts(task.get("created_at"))
        if created_at is not None:
            age = max(0, int((now - created_at).total_seconds()))
            key = (role, state)
            oldest[key] = max(oldest.get(key, 0), age)

    return {
        "schema": "engineos-observability-metrics-v0",
        "observability": {
            "enabled": state_enabled(state_file),
            "state_file": state_file,
            "events_file": events_file,
            "events_total": len(events),
        },
        "agent": {
            "ledger_dir": str(ledger_dir),
            "queue_file": str(queue_file),
            "ledger_file": str(ledger_file),
            "dispatcher_lock": lock_dir.is_dir(),
            "queue_total": len(queue),
            "ledger_events_total": len(ledger),
        },
        "observability_counts": [
            {"kind": k, "source": s, "role": r, "risk": risk, "count": count}
            for (k, s, r, risk), count in sorted(obs_counts.items())
        ],
        "sensitive_counts": [
            {"kind": k, "source": s, "count": count}
            for (k, s), count in sorted(sensitive_counts.items())
        ],
        "task_counts": [
            {"role": r, "state": state, "reason": reason, "priority": priority, "count": count}
            for (r, state, reason, priority), count in sorted(task_counts.items())
        ],
        "oldest_task_age_seconds": [
            {"role": r, "state": state, "age_seconds": age}
            for (r, state), age in sorted(oldest.items())
        ],
        "ledger_counts": [
            {"role": r, "event": event, "state": state, "reason": reason, "count": count}
            for (r, event, state, reason), count in sorted(ledger_counts.items())
        ],
        "recent_ledger_events": ledger[-8:],
    }


summary = build_summary()
fmt = os.environ.get("ENGINEOS_OBS_METRICS_FORMAT", "prometheus")

if fmt == "json":
    print(json.dumps(summary, sort_keys=True, separators=(",", ":")))
    sys.exit(0)

if fmt != "prometheus":
    raise SystemExit(f"unsupported metrics format: {fmt}")

lines = [
    "# HELP engineos_observability_enabled EngineOS metadata-only observability enabled flag.",
    "# TYPE engineos_observability_enabled gauge",
    metric_line("engineos_observability_enabled", 1 if summary["observability"]["enabled"] else 0),
    "# HELP engineos_observability_events_total Metadata-only observability events by kind/source/role/risk.",
    "# TYPE engineos_observability_events_total counter",
]
for item in summary["observability_counts"]:
    lines.append(metric_line("engineos_observability_events_total", item["count"], {
        "kind": item["kind"],
        "source": item["source"],
        "role": item["role"],
        "risk": item["risk"],
    }))
lines.extend([
    "# HELP engineos_observability_sensitive_events_total Events whose command metadata matched a sensitive pattern.",
    "# TYPE engineos_observability_sensitive_events_total counter",
])
for item in summary["sensitive_counts"]:
    lines.append(metric_line("engineos_observability_sensitive_events_total", item["count"], {
        "kind": item["kind"],
        "source": item["source"],
    }))
lines.extend([
    "# HELP engineos_agent_tasks_current Current agent tasks by latest state.",
    "# TYPE engineos_agent_tasks_current gauge",
])
for item in summary["task_counts"]:
    lines.append(metric_line("engineos_agent_tasks_current", item["count"], {
        "role": item["role"],
        "state": item["state"],
        "reason": item["reason"],
        "priority": item["priority"],
    }))
lines.extend([
    "# HELP engineos_agent_task_oldest_age_seconds Oldest task age by role and state.",
    "# TYPE engineos_agent_task_oldest_age_seconds gauge",
])
for item in summary["oldest_task_age_seconds"]:
    lines.append(metric_line("engineos_agent_task_oldest_age_seconds", item["age_seconds"], {
        "role": item["role"],
        "state": item["state"],
    }))
lines.extend([
    "# HELP engineos_agent_ledger_events_total Agent ledger events by role/event/state/reason.",
    "# TYPE engineos_agent_ledger_events_total counter",
])
for item in summary["ledger_counts"]:
    lines.append(metric_line("engineos_agent_ledger_events_total", item["count"], {
        "role": item["role"],
        "event": item["event"],
        "state": item["state"],
        "reason": item["reason"],
    }))
lines.extend([
    "# HELP engineos_agent_dispatcher_lock Dispatcher lock held flag.",
    "# TYPE engineos_agent_dispatcher_lock gauge",
    metric_line("engineos_agent_dispatcher_lock", 1 if summary["agent"]["dispatcher_lock"] else 0),
    "# HELP engineos_agent_queue_records_total Total queue records in the durable queue JSONL.",
    "# TYPE engineos_agent_queue_records_total gauge",
    metric_line("engineos_agent_queue_records_total", summary["agent"]["queue_total"]),
    "# HELP engineos_agent_ledger_records_total Total ledger records in the durable ledger JSONL.",
    "# TYPE engineos_agent_ledger_records_total gauge",
    metric_line("engineos_agent_ledger_records_total", summary["agent"]["ledger_events_total"]),
])
print("\n".join(lines))
PY
}

cmd_metrics() {
  local format="prometheus"
  local out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format)
        shift
        format="${1:-}"
        ;;
      --out)
        shift
        out="${1:-}"
        [[ -n "$out" ]] || die "--out requires a path"
        ;;
      *)
        die "unknown metrics option: $1"
        ;;
    esac
    shift
  done

  case "$format" in
    prometheus|json) ;;
    *) die "--format expects prometheus or json" ;;
  esac

  local ledger_dir
  ledger_dir="$(agent_ledger_dir)"
  if [[ -n "$out" ]]; then
    install -d -m 0700 "$(dirname "$out")"
    ENGINEOS_OBS_STATE_FILE="$STATE_FILE" \
      ENGINEOS_OBS_EVENTS_FILE="$EVENTS_FILE" \
      ENGINEOS_AGENT_LEDGER_DIR="$ledger_dir" \
      ENGINEOS_OBS_METRICS_FORMAT="$format" \
      metrics_python >"$out"
    printf '%s\n' "$out"
  else
    ENGINEOS_OBS_STATE_FILE="$STATE_FILE" \
      ENGINEOS_OBS_EVENTS_FILE="$EVENTS_FILE" \
      ENGINEOS_AGENT_LEDGER_DIR="$ledger_dir" \
      ENGINEOS_OBS_METRICS_FORMAT="$format" \
      metrics_python
  fi
}

exporter_pid_file() {
  printf '%s\n' "$STATE_DIR/observability-exporter.pid"
}

cmd_exporter() {
  local action="${1:-status}"
  shift || true
  local host="127.0.0.1"
  local port="9109"
  local pid_file
  local log_file

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)
        shift
        host="${1:-}"
        ;;
      --port)
        shift
        port="${1:-}"
        [[ "$port" =~ ^[0-9]+$ ]] || die "--port requires an integer"
        ;;
      *)
        die "unknown exporter option: $1"
        ;;
    esac
    shift
  done

  ensure_state_dir
  pid_file="$(exporter_pid_file)"
  log_file="$STATE_DIR/observability-exporter.log"

  case "$action" in
    once)
      cmd_metrics --format prometheus
      ;;
    serve)
      ENGINEOS_OBSERVABILITY_SCRIPT="$0" \
        ENGINEOS_OBSERVABILITY_EXPORTER_HOST="$host" \
        ENGINEOS_OBSERVABILITY_EXPORTER_PORT="$port" \
        python3 - <<'PY'
import http.server
import os
import subprocess

script = os.environ["ENGINEOS_OBSERVABILITY_SCRIPT"]
host = os.environ.get("ENGINEOS_OBSERVABILITY_EXPORTER_HOST", "127.0.0.1")
port = int(os.environ.get("ENGINEOS_OBSERVABILITY_EXPORTER_PORT", "9109"))


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            payload = b"ok\n"
            self.send_response(200)
            self.send_header("content-type", "text/plain; charset=utf-8")
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path != "/metrics":
            self.send_error(404)
            return
        result = subprocess.run([script, "metrics"], check=False, text=True, capture_output=True)
        payload = result.stdout.encode("utf-8", errors="replace")
        self.send_response(200 if result.returncode == 0 else 500)
        self.send_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        return


with http.server.ThreadingHTTPServer((host, port), Handler) as server:
    print(f"eos-observe exporter listening on {host}:{port}", flush=True)
    server.serve_forever()
PY
      ;;
    start)
      if [[ -r "$pid_file" ]] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1; then
        printf 'observability exporter already running pid=%s\n' "$(cat "$pid_file")"
        return 0
      fi
      nohup "$0" exporter serve --host "$host" --port "$port" >"$log_file" 2>&1 &
      printf '%s\n' "$!" >"$pid_file"
      printf 'observability exporter started pid=%s url=http://%s:%s/metrics\n' "$!" "$host" "$port"
      ;;
    stop)
      if [[ -r "$pid_file" ]] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1; then
        kill "$(cat "$pid_file")" || true
        rm -f "$pid_file"
        printf 'observability exporter stopped\n'
      else
        rm -f "$pid_file"
        printf 'observability exporter not running\n'
      fi
      ;;
    status)
      if [[ -r "$pid_file" ]] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1; then
        printf 'observability exporter: running pid=%s\n' "$(cat "$pid_file")"
      else
        printf 'observability exporter: stopped\n'
      fi
      printf 'pid: %s\n' "$pid_file"
      printf 'log: %s\n' "$log_file"
      ;;
    *)
      die "exporter expects start, stop, status, serve, or once"
      ;;
  esac
}

render_tui_once() {
  local json
  json="$(cmd_metrics --format json)"
  ENGINEOS_OBS_TUI_JSON="$json" python3 - <<'PY'
import json
import os
from collections import defaultdict

data = json.loads(os.environ["ENGINEOS_OBS_TUI_JSON"])
obs = data["observability"]
agent = data["agent"]

print("EngineOS Observability")
print("======================")
print(f"observability: {'enabled' if obs['enabled'] else 'disabled'}  events={obs['events_total']}")
print(f"events file: {obs['events_file']}")
print(f"agent ledger: {agent['ledger_dir']}")
print(f"queue records={agent['queue_total']}  ledger events={agent['ledger_events_total']}  dispatcher_lock={'held' if agent['dispatcher_lock'] else 'free'}")
print()

print("Agent Tasks")
print("-----------")
if data["task_counts"]:
    for item in data["task_counts"]:
        print(f"{item['role']:<18} {item['state']:<10} {item['priority']:<7} {item['count']:>4}  reason={item['reason']}")
else:
    print("no agent tasks")
print()

print("Observability Events")
print("--------------------")
if data["observability_counts"]:
    for item in data["observability_counts"]:
        print(f"{item['kind']:<22} {item['source']:<12} role={item['role']:<16} risk={item['risk']:<8} count={item['count']}")
else:
    print("no observability events")
print()

print("Recent Ledger")
print("-------------")
for event in data["recent_ledger_events"]:
    print(f"{event.get('ts',''):<20} {event.get('role','none'):<16} {event.get('event',''):<16} {event.get('state',''):<10} reason={event.get('reason','none')}")
if not data["recent_ledger_events"]:
    print("no ledger events")
PY
}

cmd_tui() {
  local once=false
  local watch="2"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --once)
        once=true
        ;;
      --watch)
        shift
        watch="${1:-}"
        [[ "$watch" =~ ^[0-9]+$ ]] || die "--watch requires an integer"
        ;;
      *)
        die "unknown tui option: $1"
        ;;
    esac
    shift
  done

  if [[ "$once" == true ]]; then
    render_tui_once
    return 0
  fi

  while true; do
    printf '\033[H\033[2J'
    render_tui_once
    printf '\nrefresh=%ss; Ctrl-C to exit\n' "$watch"
    sleep "$watch"
  done
}

emit_zsh_hook() {
  cat <<'HOOK'
if [[ -z "${ENGINEOS_OBSERVABILITY_ZSH_HOOK:-}" ]] && command -v eos-observe >/dev/null 2>&1; then
  export ENGINEOS_OBSERVABILITY_ZSH_HOOK=1
  autoload -Uz add-zsh-hook
  __engineos_observability_last_command=""
  __engineos_observability_preexec() {
    __engineos_observability_last_command="$1"
  }
  __engineos_observability_precmd() {
    local status="$?"
    [[ -n "$__engineos_observability_last_command" ]] || return 0
    eos-observe record --kind shell-command --source shell --shell zsh --status "$status" --cwd "$PWD" --command "$__engineos_observability_last_command" >/dev/null 2>&1 || true
    __engineos_observability_last_command=""
  }
  add-zsh-hook preexec __engineos_observability_preexec
  add-zsh-hook precmd __engineos_observability_precmd
fi
HOOK
}

emit_bash_hook() {
  cat <<'HOOK'
if [[ -z "${ENGINEOS_OBSERVABILITY_BASH_HOOK:-}" ]] && command -v eos-observe >/dev/null 2>&1; then
  export ENGINEOS_OBSERVABILITY_BASH_HOOK=1
  __engineos_observability_last_command=""
  __engineos_observability_debug() {
    local cmd="${BASH_COMMAND:-}"
    case "$cmd" in
      __engineos_observability_*|PROMPT_COMMAND=*|trap\ *) return 0 ;;
    esac
    __engineos_observability_last_command="$cmd"
  }
  __engineos_observability_prompt() {
    local status="$?"
    [[ -n "$__engineos_observability_last_command" ]] || return 0
    eos-observe record --kind shell-command --source shell --shell bash --status "$status" --cwd "$PWD" --command "$__engineos_observability_last_command" >/dev/null 2>&1 || true
    __engineos_observability_last_command=""
  }
  trap '__engineos_observability_debug' DEBUG
  PROMPT_COMMAND="__engineos_observability_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
HOOK
}

cmd_hook() {
  local shell_name="${1:-}"
  case "$shell_name" in
    zsh)
      emit_zsh_hook
      ;;
    bash)
      emit_bash_hook
      ;;
    *)
      die "hook expects zsh or bash"
      ;;
  esac
}

cmd="${1:-status}"
shift || true

case "$cmd" in
  status)
    cmd_status "$@"
    ;;
  enable)
    cmd_enable "$@"
    ;;
  disable)
    cmd_disable "$@"
    ;;
  prompt-login)
    cmd_prompt_login "$@"
    ;;
  record)
    cmd_record "$@"
    ;;
  tail)
    cmd_tail "$@"
    ;;
  export)
    cmd_export "$@"
    ;;
  purge)
    cmd_purge "$@"
    ;;
  hook)
    cmd_hook "$@"
    ;;
  metrics)
    cmd_metrics "$@"
    ;;
  exporter)
    cmd_exporter "$@"
    ;;
  tui)
    cmd_tui "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown command: $cmd"
    ;;
esac
