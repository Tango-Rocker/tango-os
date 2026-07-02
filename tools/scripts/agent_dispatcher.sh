#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"

usage() {
  cat <<'HELP'
Usage:
  agent_dispatcher.sh queue add --role <role> --reason <code> --summary <text> --proof <cmd> [--source <event>] [--priority low|normal|high]
  agent_dispatcher.sh queue list [--status queued|running|done|failed|blocked|cancelled] [--json]
  agent_dispatcher.sh queue show <task-id>
  agent_dispatcher.sh queue cancel <task-id>
  agent_dispatcher.sh dispatch drain [--limit N] [--role <role>|all] [--execute|--dry-run]
  agent_dispatcher.sh dispatch status
  agent_dispatcher.sh dispatch wake

Repo-local durable queue/ledger for EngineOS agent work. Draining is manual and
single-worker in v0.
HELP
}

die() {
  printf 'eos-agent dispatcher: %s\n' "$*" >&2
  exit 1
}

ledger_dir() {
  if [[ -n "${ENGINEOS_AGENT_LEDGER_DIR:-}" ]]; then
    printf '%s\n' "$ENGINEOS_AGENT_LEDGER_DIR"
  elif engineos_is_source_root "$ROOT"; then
    printf '%s\n' "$ROOT/artifacts/agent-ledger"
  elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s\n' "$XDG_STATE_HOME/engineos/agent-ledger"
  else
    printf '%s\n' "${HOME:-/tmp}/.local/state/engineos/agent-ledger"
  fi
}

LEDGER_DIR="$(ledger_dir)"
QUEUE_FILE="$LEDGER_DIR/queue.jsonl"
LEDGER_FILE="$LEDGER_DIR/ledger.jsonl"
RUNS_DIR="$LEDGER_DIR/runs"
LOCK_DIR="$LEDGER_DIR/dispatcher.lock"
WAKE_FIFO="$LEDGER_DIR/wake.fifo"

ensure_ledger_dir() {
  install -d -m 0700 "$LEDGER_DIR" "$RUNS_DIR"
}

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

new_task_id() {
  printf 'task-%s-%s-%s\n' "$(date -u '+%Y%m%dT%H%M%SZ')" "$$" "${RANDOM:-0}"
}

json_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

json_field() {
  local line="$1"
  local field="$2"
  printf '%s\n' "$line" | sed -n "s/.*\"$field\":\"\\([^\"]*\\)\".*/\\1/p"
}

valid_role() {
  local role="$1"
  [[ "$role" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  "$SCRIPT_DIR/agent_profile.sh" show "$role" >/dev/null 2>&1
}

policy_block_reason() {
  local text="${1,,}"
  case "$text" in
    *"sudo "*|*" sudo"*|*"pacman -r"*|*"pacman -s"*|*"paru "*|*"yay "*)
      printf 'package-or-sudo-operation'
      return 0
      ;;
    *"rm -rf"*|*"mkfs"*|*"dd if="*|*"dd of="*|*"/dev/sd"*|*"usb write"*|*"install dev"*)
      printf 'disk-or-destructive-operation'
      return 0
      ;;
    *"systemctl enable"*|*"systemctl disable"*|*"systemctl start"*|*"systemctl stop"*|*"systemctl restart"*)
      printf 'service-state-operation'
      return 0
      ;;
    *"external_directory"*|*"outside repo"*|*"/etc/"*|*"/usr/"*)
      printf 'external-directory-operation'
      return 0
      ;;
  esac
  return 1
}

append_queue_record() {
  local task_id="$1"
  local role="$2"
  local reason="$3"
  local summary="$4"
  local proof="$5"
  local source="$6"
  local priority="$7"

  {
    printf '{"schema":"engineos-agent-task-v0","created_at":'
    json_string "$(now_utc)"
    printf ',"task_id":'
    json_string "$task_id"
    printf ',"role":'
    json_string "$role"
    printf ',"priority":'
    json_string "$priority"
    printf ',"reason":'
    json_string "$reason"
    printf ',"source":'
    json_string "$source"
    printf ',"summary":'
    json_string "$summary"
    printf ',"proof":'
    json_string "$proof"
    printf '}\n'
  } >>"$QUEUE_FILE"
}

append_ledger_event() {
  local task_id="$1"
  local event="$2"
  local state="$3"
  local role="${4:-}"
  local reason="${5:-}"
  local detail="${6:-}"

  ensure_ledger_dir
  {
    printf '{"schema":"engineos-agent-ledger-v0","ts":'
    json_string "$(now_utc)"
    printf ',"task_id":'
    json_string "$task_id"
    printf ',"event":'
    json_string "$event"
    printf ',"state":'
    json_string "$state"
    [[ -n "$role" ]] && {
      printf ',"role":'
      json_string "$role"
    }
    [[ -n "$reason" ]] && {
      printf ',"reason":'
      json_string "$reason"
    }
    [[ -n "$detail" ]] && {
      printf ',"detail":'
      json_string "$detail"
    }
    printf '}\n'
  } >>"$LEDGER_FILE"
}

record_dispatch_metadata() {
  local role="$1"
  local reason="$2"
  local proof="$3"
  local summary="$4"

  "$SCRIPT_DIR/observability.sh" record \
    --kind agent-dispatch \
    --source dispatcher \
    --role "$role" \
    --reason "$reason" \
    --proof "$proof" \
    --request "$summary" >/dev/null 2>&1 || true
}

latest_state() {
  local task_id="$1"
  local line
  [[ -r "$LEDGER_FILE" ]] || {
    printf 'queued\n'
    return
  }
  line="$(grep -F "\"task_id\":\"$task_id\"" "$LEDGER_FILE" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$line" ]] || {
    printf 'queued\n'
    return
  }
  json_field "$line" state
}

queue_line_for_id() {
  local task_id="$1"
  [[ -r "$QUEUE_FILE" ]] || return 1
  grep -F "\"task_id\":\"$task_id\"" "$QUEUE_FILE" | tail -n 1
}

cmd_queue_add() {
  local role=""
  local reason=""
  local summary=""
  local proof=""
  local source="manual"
  local priority="normal"
  local task_id
  local block_reason=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)
        shift
        role="${1:-}"
        ;;
      --reason)
        shift
        reason="${1:-}"
        ;;
      --summary)
        shift
        summary="${1:-}"
        ;;
      --proof)
        shift
        proof="${1:-}"
        ;;
      --source)
        shift
        source="${1:-}"
        ;;
      --priority)
        shift
        priority="${1:-}"
        ;;
      *)
        die "unknown queue add option: $1"
        ;;
    esac
    shift
  done

  [[ -n "$role" ]] || die "queue add requires --role"
  [[ -n "$reason" ]] || die "queue add requires --reason"
  [[ -n "$summary" ]] || die "queue add requires --summary"
  [[ -n "$proof" ]] || die "queue add requires --proof"
  valid_role "$role" || die "unknown role: $role"
  case "$priority" in
    low|normal|high) ;;
    *) die "priority must be low, normal, or high" ;;
  esac

  ensure_ledger_dir
  task_id="$(new_task_id)"
  append_queue_record "$task_id" "$role" "$reason" "$summary" "$proof" "$source" "$priority"
  append_ledger_event "$task_id" queued queued "$role" "$reason" ""
  record_dispatch_metadata "$role" "$reason" "$proof" "$summary"

  if block_reason="$(policy_block_reason "$summary $proof")"; then
    append_ledger_event "$task_id" blocked blocked "$role" "$block_reason" "repo-only automation policy blocked this task"
    printf 'blocked task_id=%s role=%s reason=%s\n' "$task_id" "$role" "$block_reason"
    return 3
  fi

  printf 'queued task_id=%s role=%s priority=%s\n' "$task_id" "$role" "$priority"
}

cmd_queue_list() {
  local filter=""
  local json=false
  local line
  local task_id
  local role
  local state
  local reason
  local summary
  local first=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)
        shift
        filter="${1:-}"
        ;;
      --json)
        json=true
        ;;
      *)
        die "unknown queue list option: $1"
        ;;
    esac
    shift
  done

  [[ -r "$QUEUE_FILE" ]] || {
    if [[ "$json" == true ]]; then
      printf '{"schema":"engineos-agent-queue-v0","tasks":[]}\n'
    else
      printf 'no queued agent tasks\n'
    fi
    return 0
  }

  if [[ "$json" == true ]]; then
    printf '{"schema":"engineos-agent-queue-v0","tasks":['
  fi

  while IFS= read -r line; do
    task_id="$(json_field "$line" task_id)"
    role="$(json_field "$line" role)"
    reason="$(json_field "$line" reason)"
    summary="$(json_field "$line" summary)"
    state="$(latest_state "$task_id")"
    [[ -z "$filter" || "$state" == "$filter" ]] || continue
    if [[ "$json" == true ]]; then
      [[ "$first" == true ]] || printf ','
      first=false
      printf '{"task_id":'
      json_string "$task_id"
      printf ',"state":'
      json_string "$state"
      printf ',"role":'
      json_string "$role"
      printf ',"reason":'
      json_string "$reason"
      printf ',"summary":'
      json_string "$summary"
      printf '}'
    else
      printf '%s state=%s role=%s reason=%s summary=%s\n' "$task_id" "$state" "$role" "$reason" "$summary"
    fi
  done <"$QUEUE_FILE"

  if [[ "$json" == true ]]; then
    printf ']}\n'
  fi
}

cmd_queue_show() {
  local task_id="${1:-}"
  local line
  [[ -n "$task_id" ]] || die "queue show requires a task id"
  line="$(queue_line_for_id "$task_id" || true)"
  [[ -n "$line" ]] || die "task not found: $task_id"
  printf 'task: %s\n' "$line"
  printf 'events:\n'
  if [[ -r "$LEDGER_FILE" ]]; then
    grep -F "\"task_id\":\"$task_id\"" "$LEDGER_FILE" || true
  fi
}

cmd_queue_cancel() {
  local task_id="${1:-}"
  local line
  local role
  [[ -n "$task_id" ]] || die "queue cancel requires a task id"
  line="$(queue_line_for_id "$task_id" || true)"
  [[ -n "$line" ]] || die "task not found: $task_id"
  role="$(json_field "$line" role)"
  append_ledger_event "$task_id" cancelled cancelled "$role" manual "cancelled by queue command"
  printf 'cancelled task_id=%s\n' "$task_id"
}

write_prompt() {
  local task_id="$1"
  local role="$2"
  local summary="$3"
  local proof="$4"
  local run_dir="$RUNS_DIR/$task_id"

  install -d -m 0700 "$run_dir"
  {
    printf '# EngineOS Queued Agent Task\n\n'
    printf 'Role: `%s`\n\n' "$role"
    printf 'Policy: repo-only edits and validation commands. Block sudo, package operations, USB/disk operations, service changes, external directories, and raw prompt/AI I/O storage.\n\n'
    printf 'Use `AGENTS.md`, `.agents/index.toml`, `eos-agent profile show %s`, and the role skill before editing.\n\n' "$role"
    printf 'Task summary:\n%s\n\n' "$summary"
    printf 'Required proof command:\n```bash\n%s\n```\n' "$proof"
  } >"$run_dir/prompt.md"
  printf '%s\n' "$run_dir/prompt.md"
}

run_codex_adapter() {
  local prompt_file="$1"
  local run_dir="$2"

  if ! command -v codex >/dev/null 2>&1; then
    printf 'codex command not found\n' >"$run_dir/stderr.log"
    return 125
  fi

  if [[ -n "${ENGINEOS_AGENT_CODEX_CMD:-}" ]]; then
    (cd "$ROOT" && bash -lc "$ENGINEOS_AGENT_CODEX_CMD" <"$prompt_file" >"$run_dir/stdout.log" 2>"$run_dir/stderr.log")
  else
    (cd "$ROOT" && codex exec --skip-git-repo-check <"$prompt_file" >"$run_dir/stdout.log" 2>"$run_dir/stderr.log")
  fi
}

run_agent_task() {
  local task_id="$1"
  local role="$2"
  local summary="$3"
  local proof="$4"
  local prompt_file
  local run_dir="$RUNS_DIR/$task_id"
  local runner="${ENGINEOS_AGENT_RUNNER:-codex}"
  local rc=0

  prompt_file="$(write_prompt "$task_id" "$role" "$summary" "$proof")"
  append_ledger_event "$task_id" runner-invoked running "$role" "$runner" "prompt=$prompt_file"

  case "$runner" in
    codex)
      run_codex_adapter "$prompt_file" "$run_dir" || rc=$?
      ;;
    fixture-pass)
      printf 'fixture runner passed\n' >"$run_dir/stdout.log"
      : >"$run_dir/stderr.log"
      ;;
    fixture-fail)
      printf 'fixture runner failed\n' >"$run_dir/stderr.log"
      rc=17
      ;;
    *)
      printf 'unknown runner: %s\n' "$runner" >"$run_dir/stderr.log"
      rc=126
      ;;
  esac

  if [[ "$rc" -eq 125 ]]; then
    append_ledger_event "$task_id" blocked blocked "$role" codex-unavailable "codex runner unavailable"
    printf 'blocked task_id=%s reason=codex-unavailable\n' "$task_id"
    return 0
  elif [[ "$rc" -ne 0 ]]; then
    append_ledger_event "$task_id" failed failed "$role" runner-failed "runner exit=$rc"
    printf 'failed task_id=%s reason=runner-failed rc=%s\n' "$task_id" "$rc"
    return "$rc"
  fi

  if policy_block_reason "$proof" >/dev/null; then
    append_ledger_event "$task_id" blocked blocked "$role" proof-policy-block "proof command blocked by repo-only policy"
    printf 'blocked task_id=%s reason=proof-policy-block\n' "$task_id"
    return 0
  fi

  append_ledger_event "$task_id" proof-started running "$role" proof "$proof"
  if (cd "$ROOT" && bash -lc "$proof" >"$run_dir/proof.stdout.log" 2>"$run_dir/proof.stderr.log"); then
    append_ledger_event "$task_id" proof-passed running "$role" proof "$proof"
    append_ledger_event "$task_id" completed done "$role" done "task completed"
    printf 'completed task_id=%s\n' "$task_id"
  else
    rc=$?
    append_ledger_event "$task_id" proof-failed failed "$role" proof "proof exit=$rc"
    printf 'failed task_id=%s reason=proof-failed rc=%s\n' "$task_id" "$rc"
    return "$rc"
  fi
}

acquire_lock() {
  ensure_ledger_dir
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "dispatcher already running: $LOCK_DIR"
  fi
  trap 'rm -rf "$LOCK_DIR"' EXIT
}

cmd_dispatch_drain() {
  local limit=1
  local role_filter="all"
  local execute=false
  local drained=0
  local failures=0
  local line
  local task_id
  local role
  local state
  local summary
  local proof

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit)
        shift
        limit="${1:-}"
        [[ "$limit" =~ ^[0-9]+$ ]] || die "--limit requires an integer"
        ;;
      --role)
        shift
        role_filter="${1:-}"
        ;;
      --execute)
        execute=true
        ;;
      --dry-run)
        execute=false
        ;;
      *)
        die "unknown dispatch drain option: $1"
        ;;
    esac
    shift
  done

  acquire_lock
  [[ -r "$QUEUE_FILE" ]] || {
    printf 'no queued agent tasks\n'
    return 0
  }

  while IFS= read -r line; do
    task_id="$(json_field "$line" task_id)"
    role="$(json_field "$line" role)"
    state="$(latest_state "$task_id")"
    [[ "$state" == "queued" ]] || continue
    [[ "$role_filter" == "all" || "$role" == "$role_filter" ]] || continue

    summary="$(json_field "$line" summary)"
    proof="$(json_field "$line" proof)"
    if [[ "$execute" == true ]]; then
      append_ledger_event "$task_id" started running "$role" drain "manual drain"
      if ! run_agent_task "$task_id" "$role" "$summary" "$proof"; then
        failures=$((failures + 1))
      fi
    else
      printf 'dry-run task_id=%s role=%s proof=%s\n' "$task_id" "$role" "$proof"
    fi
    drained=$((drained + 1))
    [[ "$drained" -lt "$limit" ]] || break
  done <"$QUEUE_FILE"

  if [[ "$execute" == true ]]; then
    printf 'drain summary: %s task(s) considered, %s failure(s)\n' "$drained" "$failures"
    [[ "$failures" -eq 0 ]] || return 1
  else
    printf 'drain summary: %s task(s) considered\n' "$drained"
  fi
}

cmd_dispatch_status() {
  local queued=0
  local running=0
  local done=0
  local failed=0
  local blocked=0
  local cancelled=0
  local line
  local state
  local task_id

  if [[ -r "$QUEUE_FILE" ]]; then
    while IFS= read -r line; do
      task_id="$(json_field "$line" task_id)"
      state="$(latest_state "$task_id")"
      case "$state" in
        queued) queued=$((queued + 1)) ;;
        running) running=$((running + 1)) ;;
        done) done=$((done + 1)) ;;
        failed) failed=$((failed + 1)) ;;
        blocked) blocked=$((blocked + 1)) ;;
        cancelled) cancelled=$((cancelled + 1)) ;;
      esac
    done <"$QUEUE_FILE"
  fi

  printf 'agent ledger: %s\n' "$LEDGER_DIR"
  printf 'queued=%s running=%s done=%s failed=%s blocked=%s cancelled=%s\n' "$queued" "$running" "$done" "$failed" "$blocked" "$cancelled"
  [[ -d "$LOCK_DIR" ]] && printf 'dispatcher_lock=held\n' || printf 'dispatcher_lock=free\n'
}

cmd_dispatch_wake() {
  ensure_ledger_dir
  if [[ -p "$WAKE_FIFO" ]]; then
    :
  elif command -v mkfifo >/dev/null 2>&1 && mkfifo "$WAKE_FIFO" 2>/dev/null; then
    chmod 0600 "$WAKE_FIFO"
  else
    : >"$LEDGER_DIR/wake.fifo.unavailable"
    printf 'wake fifo unavailable on this platform; wrote wake marker\n'
    return 0
  fi

  if command -v timeout >/dev/null 2>&1 &&
      timeout 1 bash -c 'printf "wake\n" >"$1"' _ "$WAKE_FIFO" 2>/dev/null; then
    printf 'wake sent: %s\n' "$WAKE_FIFO"
  else
    printf 'wake fifo ready: %s\n' "$WAKE_FIFO"
  fi
}

main() {
  local area="${1:-}"
  local cmd="${2:-}"
  [[ -n "$area" ]] || {
    usage
    return 2
  }
  shift || true
  shift || true

  case "$area:$cmd" in
    queue:add)
      cmd_queue_add "$@"
      ;;
    queue:list)
      cmd_queue_list "$@"
      ;;
    queue:show)
      cmd_queue_show "$@"
      ;;
    queue:cancel)
      cmd_queue_cancel "$@"
      ;;
    dispatch:drain)
      cmd_dispatch_drain "$@"
      ;;
    dispatch:status)
      cmd_dispatch_status "$@"
      ;;
    dispatch:wake)
      cmd_dispatch_wake "$@"
      ;;
    help:*|--help:*|-h:*)
      usage
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
