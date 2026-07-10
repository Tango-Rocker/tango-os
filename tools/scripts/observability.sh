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
  observability.sh metrics [--format prometheus|json] [--out <file>]

Metadata-only v1 records hashes and classifications, not raw shell commands,
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
    printf 'schema=engineos-observability-state-v1\n'
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
    "schema": "engineos-observability-v1",
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

metrics_python() {
  python3 - <<'PY'
import collections
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
    events = read_jsonl(events_file)

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

    return {
        "schema": "engineos-observability-metrics-v1",
        "observability": {
            "enabled": state_enabled(state_file),
            "state_file": state_file,
            "events_file": events_file,
            "events_total": len(events),
        },
        "observability_counts": [
            {"kind": k, "source": s, "role": r, "risk": risk, "count": count}
            for (k, s, r, risk), count in sorted(obs_counts.items())
        ],
        "sensitive_counts": [
            {"kind": k, "source": s, "count": count}
            for (k, s), count in sorted(sensitive_counts.items())
        ],
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

	if [[ -n "$out" ]]; then
    install -d -m 0700 "$(dirname "$out")"
    ENGINEOS_OBS_STATE_FILE="$STATE_FILE" \
      ENGINEOS_OBS_EVENTS_FILE="$EVENTS_FILE" \
		  ENGINEOS_OBS_METRICS_FORMAT="$format" \
      metrics_python >"$out"
    printf '%s\n' "$out"
  else
    ENGINEOS_OBS_STATE_FILE="$STATE_FILE" \
      ENGINEOS_OBS_EVENTS_FILE="$EVENTS_FILE" \
		  ENGINEOS_OBS_METRICS_FORMAT="$format" \
      metrics_python
  fi
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
  metrics)
    cmd_metrics "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown command: $cmd"
    ;;
esac
