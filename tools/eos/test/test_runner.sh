#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_SCRIPT_DIR="$(cd "$MODULE_DIR/../../scripts" && pwd -P)"
if [[ -d "$SOURCE_SCRIPT_DIR" && "${ENGINEOS_SCRIPT_DIR:-}" == /usr/lib/engineos/scripts* ]]; then
  SCRIPT_DIR="$SOURCE_SCRIPT_DIR"
elif [[ -n "${ENGINEOS_SCRIPT_DIR:-}" ]]; then
  SCRIPT_DIR="$ENGINEOS_SCRIPT_DIR"
else
  SCRIPT_DIR="$SOURCE_SCRIPT_DIR"
fi
BUILDER_DIR="$(cd "$MODULE_DIR/../builder" && pwd -P)"
BARE_METAL_DIR="$(cd "$MODULE_DIR/../bare-metal" && pwd -P)"
OS_DEV_DIR="$(cd "$MODULE_DIR/../os-dev" && pwd -P)"
PROOF_DIR="$(cd "$MODULE_DIR/../proof" && pwd -P)"
VM_DIR="$(cd "$MODULE_DIR/../vm" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
SCOPE="${1:-smoke}"
shift || true

usage() {
  cat <<'HELP'
Usage: test_runner.sh [smoke|all]
       test_runner.sh agent
       test_runner.sh agent-hygiene
       test_runner.sh agent-dispatcher
       test_runner.sh observability
       test_runner.sh agent-route
       test_runner.sh compositor --headless
       test_runner.sh shell-actions
       test_runner.sh engine-runner-env
       test_runner.sh image-preview
       test_runner.sh app
       test_runner.sh assets
       test_runner.sh reliability
       test_runner.sh logs
       test_runner.sh artifacts
       test_runner.sh release
       test_runner.sh terminal
       test_runner.sh vm
       test_runner.sh usb
       test_runner.sh secure-boot
       test_runner.sh update-check
       test_runner.sh installation-guide
       test_runner.sh install
       test_runner.sh proof
       test_runner.sh installed-preflight
       test_runner.sh ci
       test_runner.sh builder-handoff
       test_runner.sh builder-doctor
       test_runner.sh post-first-deploy
       test_runner.sh builder
       test_runner.sh bootstrap
       test_runner.sh repo
       test_runner.sh boot
       test_runner.sh engine
       test_runner.sh shell
       test_runner.sh input
       test_runner.sh outputs --single|--dual-static
       test_runner.sh render --smoke
HELP
}

run_smoke() {
  exec "$MODULE_DIR/smoke_test.sh"
}

run_all_step() {
  printf '\n==> eos-test'
  printf ' %s' "$@"
  printf '\n'
  "$MODULE_DIR/test_runner.sh" "$@"
}

run_all() {
  printf 'EngineOS full local test suite\n'
  run_all_step smoke
  run_all_step agent
  run_all_step agent-hygiene
  run_all_step agent-dispatcher
  run_all_step observability
  run_all_step agent-route
  run_all_step compositor --headless
  run_all_step shell-actions
  run_all_step engine-runner-env
  run_all_step image-preview
  run_all_step app
  run_all_step assets
  run_all_step reliability
  run_all_step logs
  run_all_step artifacts
  run_all_step release
  run_all_step terminal
  run_all_step vm
  run_all_step usb
  run_all_step secure-boot
  run_all_step update-check
  run_all_step installation-guide
  run_all_step install
  run_all_step proof
  run_all_step installed-preflight
  run_all_step ci
  run_all_step builder-handoff
  run_all_step builder-doctor
  run_all_step post-first-deploy
  run_all_step builder
  run_all_step bootstrap
  run_all_step repo
  run_all_step boot
  run_all_step engine
  run_all_step shell
  run_all_step input
  run_all_step outputs --single
  run_all_step outputs --dual-static
  run_all_step render --smoke
  printf '\nengineos full local test suite passed\n'
}

post_install_payload_dir() {
  if [[ -d "$ROOT/tools/post-install-payload" ]]; then
    printf '%s\n' "$ROOT/tools/post-install-payload"
    return
  fi
  printf '%s\n' "$ROOT/share/engineos/post-install-payload"
}

run_compositor() {
  local mode="${1:---headless}"
  case "$mode" in
    --headless)
      ENGINEOS_SHELL_SMOKE=true exec "$SCRIPT_DIR/shell_runner.sh" --headless
      ;;
    --nested)
      ENGINEOS_SHELL_SMOKE=true exec "$SCRIPT_DIR/shell_runner.sh" --nested
      ;;
    *)
      die "compositor test expects --headless or --nested"
      ;;
  esac
}

run_agent() {
  local role
  local profile
  local skill
  local wrapper
  local tmp_dir="${TMPDIR:-/tmp}/engineos-agent-test-$$"

  cleanup_agent() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_agent RETURN
  mkdir -p "$tmp_dir"

  "$SCRIPT_DIR/preflight.sh" repo --package engineos-tools >/dev/null
  "$SCRIPT_DIR/package_lint.sh" --package engineos-tools >/dev/null
  "$SCRIPT_DIR/agent_hygiene.sh" check >/dev/null

  if find "$ROOT/.codex" "$ROOT/packages/engineos-tools" \
      -path '*/pkg/*' -prune -o \
      -path '*/src/*' -prune -o \
      -type f -print0 |
      xargs -0 grep -n 'engineos_mcp_server.py\|project_status\|read_status' >/dev/null 2>&1; then
    die "project-status MCP references remain in Codex config or agent package"
  fi
  [[ ! -e "$ROOT/tools/mcp/engineos_mcp_server.py" ]] ||
    die "removed project MCP server still exists"
  grep -F 'tools/hooks/session_start.py' "$ROOT/.codex/hooks.example.json" >/dev/null ||
    die "Codex hook example does not reference the session-start hook"
  grep -F 'docs/agent-roles.md' "$ROOT/docs/engineos-agent-pack.md" >/dev/null ||
    die "agent pack docs do not reference the role spec"
  grep -F 'agentd.md' "$ROOT/docs/engineos-agent-pack.md" >/dev/null ||
    die "agent pack docs do not reference the progressive-disclosure directive file"
  grep -F 'docs/agent-profiles.md' "$ROOT/docs/engineos-agent-pack.md" >/dev/null ||
    die "agent pack docs do not reference profile docs"
  grep -F '.agents/index.toml' "$ROOT/docs/engineos-agent-pack.md" >/dev/null ||
    die "agent pack docs do not reference the canonical agent index"

  for role in oracle overseer compiler admin-shell engine-builder pergame-quake cleaner; do
    [[ -f "$ROOT/.agents/roles/$role/AGENTS.md" ]] ||
      die "role AGENTS.md missing: $role"
    for heading in 'Responsibilities:' 'Boundaries:' 'Forbidden actions:' 'Escalation:' 'Proof commands:'; do
      grep -F "$heading" "$ROOT/.agents/roles/$role/AGENTS.md" >/dev/null ||
        die "role $role missing heading: $heading"
    done

    profile="$tmp_dir/$role.profile.toml"
    "$SCRIPT_DIR/agent_metadata.sh" profile "$role" >"$profile"
    grep -F 'schema = "engineos-agent-profile-v0"' "$profile" >/dev/null ||
      die "agent profile missing schema: $role"
    grep -F "role = \"$role\"" "$profile" >/dev/null ||
      die "agent profile role mismatch: $role"
    grep -F "role_doc = \".agents/roles/$role/AGENTS.md\"" "$profile" >/dev/null ||
      die "agent profile does not reference role AGENTS.md: $role"
    grep -F "skill = \".agents/skills/$role/SKILL.md\"" "$profile" >/dev/null ||
      die "agent profile does not reference role skill: $role"
    grep -F "opencode_wrapper = \".opencode/agents/$role.md\"" "$profile" >/dev/null ||
      die "agent profile does not reference OpenCode wrapper: $role"
    grep -F 'observability_policy = "metadata-only' "$profile" >/dev/null ||
      die "agent profile does not declare metadata-only observability: $role"
    for field in 'route_triggers = [' 'handoff_targets = [' 'proof_commands = [' 'allowed_read = [' 'ask_before = [' 'forbidden = ['; do
      grep -F "$field" "$profile" >/dev/null ||
        die "agent profile $role missing field: $field"
    done
    if [[ "$role" == "oracle" ]]; then
      grep -F 'mode = "primary"' "$profile" >/dev/null ||
        die "Oracle profile is not primary"
    else
      grep -F 'mode = "subagent"' "$profile" >/dev/null ||
        die "agent profile is not subagent: $role"
    fi

    [[ -f "$ROOT/.agents/skills/$role/SKILL.md" ]] ||
      die "role skill missing: $role"
    grep -Fx -- '---' "$ROOT/.agents/skills/$role/SKILL.md" >/dev/null ||
      die "role skill missing frontmatter fence: $role"
    grep -F "name: $role" "$ROOT/.agents/skills/$role/SKILL.md" >/dev/null ||
      die "role skill name mismatch: $role"
    grep -F 'description:' "$ROOT/.agents/skills/$role/SKILL.md" >/dev/null ||
      die "role skill missing description: $role"
    if grep -F 'TODO' "$ROOT/.agents/skills/$role/SKILL.md" >/dev/null; then
      die "role skill still contains TODO: $role"
    fi

    wrapper="$tmp_dir/$role.md"
    "$SCRIPT_DIR/agent_metadata.sh" wrapper "$role" >"$wrapper"
    grep -F 'description:' "$wrapper" >/dev/null ||
      die "OpenCode wrapper missing description: $role"
    grep -F "docs/agent-roles.md" "$wrapper" >/dev/null ||
      die "OpenCode wrapper does not reference shared role docs: $role"
    grep -F ".agents/skills/$role/SKILL.md" "$wrapper" >/dev/null ||
      die "OpenCode wrapper does not reference shared skill: $role"
    if [[ "$role" == "oracle" ]]; then
      grep -F 'mode: primary' "$wrapper" >/dev/null ||
        die "Oracle wrapper is not primary"
      grep -F 'edit: ask' "$wrapper" >/dev/null ||
        die "Oracle wrapper edit permission is not ask"
      grep -F 'bash: ask' "$wrapper" >/dev/null ||
        die "Oracle wrapper bash permission is not ask"
    else
      grep -F 'mode: subagent' "$wrapper" >/dev/null ||
        die "OpenCode wrapper is not subagent: $role"
      for permission in 'read: allow' 'glob: allow' 'grep: allow' 'list: allow' 'edit: ask' 'bash: ask' 'external_directory: ask'; do
        grep -F "$permission" "$wrapper" >/dev/null ||
          die "OpenCode wrapper $role missing permission: $permission"
      done
    fi
  done

  "$SCRIPT_DIR/agent_profile.sh" list | grep -Fx 'oracle' >/dev/null ||
    die "agent profile list does not include oracle"
  "$SCRIPT_DIR/agent_profile.sh" list | grep -Fx 'cleaner' >/dev/null ||
    die "agent profile list does not include cleaner"
  "$SCRIPT_DIR/agent_profile.sh" show pergame-quake | grep -F 'role = "pergame-quake"' >/dev/null ||
    die "agent profile show does not print pergame-quake"
  "$SCRIPT_DIR/agent_profile.sh" show cleaner | grep -F 'role = "cleaner"' >/dev/null ||
    die "agent profile show does not print cleaner"
  "$ROOT/tools/engineos/eos-agent" capabilities >"$tmp_dir/capabilities.txt"
  grep -F 'schema=engineos-agent-capabilities-v0' "$tmp_dir/capabilities.txt" >/dev/null ||
    die "agent capabilities output missing schema"
  grep -F 'role=oracle' "$tmp_dir/capabilities.txt" >/dev/null ||
    die "agent capabilities output does not include oracle"
  grep -F 'role=cleaner' "$tmp_dir/capabilities.txt" >/dev/null ||
    die "agent capabilities output does not include cleaner"
  grep -F 'skill=.agents/skills/oracle/SKILL.md' "$tmp_dir/capabilities.txt" >/dev/null ||
    die "agent capabilities output does not include skill path"

  printf 'agent harness smoke test passed\n'
}

run_agent_hygiene() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-agent-hygiene-test-$$"
  local fixture="$tmp_dir/fixture"
  local out="$tmp_dir/out.txt"
  local ledger="$tmp_dir/ledger"

  cleanup_agent_hygiene() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_agent_hygiene RETURN

  mkdir -p "$fixture/.agents/roles/cleaner" \
    "$fixture/.agents/skills/cleaner/agents" \
    "$fixture/docs" \
    "$fixture/.codex"

  "$SCRIPT_DIR/agent_hygiene.sh" check >/dev/null
  "$SCRIPT_DIR/agent_hygiene.sh" check --json >"$out"
  grep -F '"status":"pass"' "$out" >/dev/null ||
    die "agent hygiene json did not report a clean pass"

  cat >"$fixture/.agents/index.toml" <<'EOF_INDEX'
schema = "engineos-agent-index-v0"

[[roles]]
id = "cleaner"
display_name = "EngineOS Cleaner"
mode = "subagent"
role_doc = ".agents/roles/cleaner/AGENTS.md"
profile = ".agents/profiles/cleaner.profile.toml"
skill = ".agents/skills/wrong/SKILL.md"
opencode_wrapper = ".opencode/agents/cleaner.md"
route_triggers = ["cleanup"]
EOF_INDEX
  cat >"$fixture/.agents/roles/cleaner/AGENTS.md" <<'EOF_ROLE'
# Cleaner Agent

Responsibilities:
- Keep docs tidy.

Boundaries:
- Stay local.

Forbidden actions:
- No sudo.

Escalation:
- Ask Oracle.

Proof commands:
- `engineos one`
- `engineos two`
- `engineos three`
- `engineos four`
- `engineos five`
EOF_ROLE
  cat >"$fixture/.agents/skills/cleaner/SKILL.md" <<'EOF_SKILL'
---
name: cleaner
description: Fixture cleaner skill.
---

# Cleaner
EOF_SKILL
  printf 'interface:\n  display_name: "Cleaner"\n  short_description: "Fixture"\n' >"$fixture/.agents/skills/cleaner/agents/openai.yaml"
  printf '[bad](missing.md)\n' >"$fixture/docs/engineos-agent-pack.md"
  printf 'roles engineos_mcp_server.py\n' >"$fixture/docs/agent-roles.md"
  printf 'profiles\n' >"$fixture/docs/agent-profiles.md"
  printf 'server = "engineos_mcp_server.py"\n' >"$fixture/.codex/config.toml"

  if ENGINEOS_AGENT_HYGIENE_ROOT="$fixture" "$SCRIPT_DIR/agent_hygiene.sh" check --fix-plan >"$out" 2>&1; then
    die "agent hygiene accepted a stale fixture"
  fi
  grep -F 'stale-project-mcp' "$out" >/dev/null ||
    {
      cat "$out" >&2
      die "agent hygiene fixture did not detect stale MCP reference"
    }
  grep -F 'duplicated-proof-block' "$out" >/dev/null ||
    die "agent hygiene fixture did not detect duplicated proof block"
  grep -F 'generated-wrapper-drift' "$out" >/dev/null ||
    die "agent hygiene fixture did not detect generated wrapper drift"
  grep -F 'broken-doc-link' "$out" >/dev/null ||
    die "agent hygiene fixture did not detect broken doc link"

  if ENGINEOS_AGENT_HYGIENE_ROOT="$fixture" \
      ENGINEOS_AGENT_LEDGER_DIR="$ledger" \
      "$SCRIPT_DIR/agent_hygiene.sh" check --enqueue >"$out" 2>&1; then
    die "agent hygiene enqueue fixture unexpectedly passed"
  fi
  grep -F 'queued task_id=' "$out" >/dev/null ||
    die "agent hygiene --enqueue did not queue Cleaner task"
  grep -F '"role":"cleaner"' "$ledger/queue.jsonl" >/dev/null ||
    die "agent hygiene --enqueue queue record is not for cleaner"

  printf 'agent hygiene smoke test passed\n'
}

run_agent_dispatcher() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-agent-dispatcher-test-$$"
  local ledger="$tmp_dir/ledger"
  local out="$tmp_dir/out.txt"
  local task_id
  local cancelled_id

  cleanup_agent_dispatcher() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_agent_dispatcher RETURN

  mkdir -p "$tmp_dir"

  ENGINEOS_AGENT_LEDGER_DIR="$ledger" \
    "$SCRIPT_DIR/agent_dispatcher.sh" queue add \
      --role cleaner \
      --reason test \
      --summary "tidy indexed agent docs" \
      --proof "true" \
      --source test >"$out"
  task_id="$(sed -n 's/.*task_id=\([^ ]*\).*/\1/p' "$out")"
  [[ -n "$task_id" ]] || die "agent dispatcher did not print task id"

  ENGINEOS_AGENT_LEDGER_DIR="$ledger" "$SCRIPT_DIR/agent_dispatcher.sh" queue list >"$out"
  grep -F "$task_id state=queued role=cleaner" "$out" >/dev/null ||
    die "agent dispatcher list did not show queued cleaner task"

  ENGINEOS_AGENT_LEDGER_DIR="$ledger" "$SCRIPT_DIR/agent_dispatcher.sh" queue show "$task_id" >"$out"
  grep -F '"event":"queued"' "$out" >/dev/null ||
    die "agent dispatcher show did not include queued event"

  ENGINEOS_AGENT_LEDGER_DIR="$ledger" "$SCRIPT_DIR/agent_dispatcher.sh" dispatch drain --dry-run --limit 1 >"$out"
  grep -F "dry-run task_id=$task_id role=cleaner proof=true" "$out" >/dev/null ||
    die "agent dispatcher dry-run drain did not show queued task"

  ENGINEOS_AGENT_LEDGER_DIR="$ledger" "$SCRIPT_DIR/agent_dispatcher.sh" dispatch wake >"$out"
  if [[ ! -p "$ledger/wake.fifo" && ! -f "$ledger/wake.fifo.unavailable" ]]; then
    die "agent dispatcher wake did not create fifo or platform marker"
  fi

  ENGINEOS_AGENT_LEDGER_DIR="$ledger" \
    ENGINEOS_AGENT_RUNNER=fixture-pass \
    "$SCRIPT_DIR/agent_dispatcher.sh" dispatch drain --execute --limit 1 >"$out"
  grep -F "completed task_id=$task_id" "$out" >/dev/null ||
    die "agent dispatcher fixture execution did not complete task"

  ENGINEOS_AGENT_LEDGER_DIR="$ledger" "$SCRIPT_DIR/agent_dispatcher.sh" queue list --status done >"$out"
  grep -F "$task_id state=done role=cleaner" "$out" >/dev/null ||
    die "agent dispatcher did not list completed task as done"

  ENGINEOS_AGENT_LEDGER_DIR="$ledger" \
    "$SCRIPT_DIR/agent_dispatcher.sh" queue add \
      --role cleaner \
      --reason fail \
      --summary "fail this task" \
      --proof "true" \
      --source test >"$out"
  task_id="$(sed -n 's/.*task_id=\([^ ]*\).*/\1/p' "$out")"
  [[ -n "$task_id" ]] || die "agent dispatcher did not print failing task id"
  if ENGINEOS_AGENT_LEDGER_DIR="$ledger" \
      ENGINEOS_AGENT_RUNNER=fixture-fail \
      "$SCRIPT_DIR/agent_dispatcher.sh" dispatch drain --execute --limit 1 >"$out"; then
    die "agent dispatcher fixture failure did not fail drain"
  fi
  grep -F "failed task_id=$task_id reason=runner-failed rc=17" "$out" >/dev/null ||
    die "agent dispatcher fixture failure did not report runner failure"
  grep -F 'drain summary: 1 task(s) considered, 1 failure(s)' "$out" >/dev/null ||
    die "agent dispatcher drain failure summary was not explicit"
  ENGINEOS_AGENT_LEDGER_DIR="$ledger" "$SCRIPT_DIR/agent_dispatcher.sh" queue list --status failed >"$out"
  grep -F "$task_id state=failed role=cleaner" "$out" >/dev/null ||
    die "agent dispatcher did not list failed task as failed"

  if ENGINEOS_AGENT_LEDGER_DIR="$ledger" \
      "$SCRIPT_DIR/agent_dispatcher.sh" queue add \
        --role cleaner \
        --reason blocked \
        --summary "try sudo package removal" \
        --proof "sudo pacman -R engineos-tools" \
        --source test >"$out" 2>&1; then
    die "agent dispatcher accepted blocked sudo/package task"
  fi
  grep -F 'blocked task_id=' "$out" >/dev/null ||
    die "agent dispatcher did not report blocked policy task"

  ENGINEOS_AGENT_LEDGER_DIR="$ledger" \
    "$SCRIPT_DIR/agent_dispatcher.sh" queue add \
      --role cleaner \
      --reason cancel \
      --summary "cancel this task" \
      --proof "true" \
      --source test >"$out"
  cancelled_id="$(sed -n 's/.*task_id=\([^ ]*\).*/\1/p' "$out")"
  ENGINEOS_AGENT_LEDGER_DIR="$ledger" "$SCRIPT_DIR/agent_dispatcher.sh" queue cancel "$cancelled_id" >"$out"
  grep -F "cancelled task_id=$cancelled_id" "$out" >/dev/null ||
    die "agent dispatcher cancel did not report cancellation"

  mkdir -p "$ledger/dispatcher.lock"
  if ENGINEOS_AGENT_LEDGER_DIR="$ledger" "$SCRIPT_DIR/agent_dispatcher.sh" dispatch drain --dry-run >"$out" 2>&1; then
    die "agent dispatcher ignored existing lock"
  fi
  grep -F 'dispatcher already running' "$out" >/dev/null ||
    die "agent dispatcher lock failure did not explain itself"

  printf 'agent dispatcher smoke test passed\n'
}

run_observability() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-observability-test-$$"
  local out="$tmp_dir/out.txt"
  local export_file="$tmp_dir/export/events.jsonl"
  local events="$tmp_dir/state/events.jsonl"
  local ledger="$tmp_dir/ledger"
  local stubborn_pid=""

  cleanup_observability() {
    if [[ -n "$stubborn_pid" ]]; then
      kill -KILL "$stubborn_pid" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp_dir"
  }
  trap cleanup_observability RETURN

  mkdir -p "$tmp_dir"

  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    "$SCRIPT_DIR/observability.sh" record --kind shell-command --source shell --shell bash --status 0 --cwd "$tmp_dir" --command 'echo should-not-write' >/dev/null
  [[ ! -e "$events" ]] ||
    die "observability wrote events while disabled"

  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    ENGINEOS_OBSERVABILITY_PROMPT_RESPONSE=yes \
    "$SCRIPT_DIR/observability.sh" prompt-login --shell bash >"$out"
  grep -F 'observability enabled: metadata-only' "$out" >/dev/null ||
    die "observability prompt-login did not enable from yes response"

  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    "$SCRIPT_DIR/observability.sh" record --kind shell-command --source shell --shell bash --status 7 --cwd "$tmp_dir/secret-path" --command 'curl -H "Authorization: Bearer token-secret" https://example.invalid' >/dev/null
  [[ -f "$events" ]] || die "observability did not write enabled event"
  grep -F '"kind":"shell-command"' "$events" >/dev/null ||
    die "observability event missing kind"
  grep -F '"command_hash":"' "$events" >/dev/null ||
    die "observability event missing command hash"
  grep -F '"command_redacted":true' "$events" >/dev/null ||
    die "observability event does not mark command redaction"
  grep -F '"sensitive_pattern":true' "$events" >/dev/null ||
    die "observability did not detect sensitive command pattern"
  if grep -F 'token-secret' "$events" >/dev/null ||
      grep -F 'Authorization' "$events" >/dev/null ||
      grep -F 'secret-path' "$events" >/dev/null; then
    die "observability stored raw command or cwd data"
  fi

  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    "$ROOT/tools/engineos/eos-doctor" --vm >/dev/null
  grep -F '"kind":"engineos-command"' "$events" >/dev/null ||
    die "observability did not record eos command metadata"
  if grep -F 'eos-doctor --vm' "$events" >/dev/null; then
    die "observability stored raw eos command"
  fi

  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    "$SCRIPT_DIR/observability.sh" tail --last 2 >"$out"
  grep -F '"kind":"shell-command"' "$out" >/dev/null ||
    die "observability tail did not show event"

  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    "$SCRIPT_DIR/observability.sh" export --out "$export_file" >"$out"
  [[ -f "$export_file" ]] || die "observability export did not create output file"
  grep -F '"metadata_only":true' "$export_file" >/dev/null ||
    die "observability export missing metadata-only event"

  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    ENGINEOS_AGENT_LEDGER_DIR="$ledger" \
    "$SCRIPT_DIR/agent_dispatcher.sh" queue add \
      --role cleaner \
      --reason observability-test \
      --summary "observe queue metrics" \
      --proof "true" \
      --source test >/dev/null
  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    ENGINEOS_AGENT_LEDGER_DIR="$ledger" \
    ENGINEOS_AGENT_RUNNER=fixture-pass \
    "$SCRIPT_DIR/agent_dispatcher.sh" dispatch drain --execute --limit 1 >/dev/null

  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    ENGINEOS_AGENT_LEDGER_DIR="$ledger" \
    "$SCRIPT_DIR/observability.sh" metrics >"$out"
  grep -F 'engineos_observability_events_total' "$out" >/dev/null ||
    die "observability metrics missing event counter"
  grep -F 'engineos_agent_tasks_current{role="cleaner",state="done"' "$out" >/dev/null ||
    die "observability metrics missing cleaner done task gauge"
  grep -F 'engineos_agent_ledger_events_total' "$out" >/dev/null ||
    die "observability metrics missing ledger event counter"
  if grep -F 'observe queue metrics' "$out" >/dev/null; then
    die "observability metrics exposed raw task summary"
  fi

  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    ENGINEOS_AGENT_LEDGER_DIR="$ledger" \
    "$SCRIPT_DIR/observability.sh" metrics --format json >"$out"
  grep -F '"schema":"engineos-observability-metrics-v0"' "$out" >/dev/null ||
    die "observability metrics json missing schema"

  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    ENGINEOS_AGENT_LEDGER_DIR="$ledger" \
    "$SCRIPT_DIR/observability.sh" exporter once >"$out"
  grep -F 'engineos_agent_tasks_current' "$out" >/dev/null ||
    die "observability exporter one-shot missing task metric"

  if ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
      "$SCRIPT_DIR/observability.sh" exporter start --host 192.0.2.1 --port 19109 >"$out" 2>&1; then
    die "observability exporter start succeeded for an unbindable host"
  fi
  grep -E 'observability exporter (failed to start|did not become healthy)' "$out" >/dev/null ||
    die "observability exporter start failure was not explicit"
  [[ ! -f "$tmp_dir/state/observability-exporter.pid" ]] ||
    die "observability exporter start left a pid file after startup failure"

  if ! command -v setsid >/dev/null 2>&1; then
    die "setsid unavailable; cannot test observability exporter stop failure"
  fi
  setsid sh -c 'trap "" TERM; while :; do sleep 1; done' >/dev/null 2>&1 &
  stubborn_pid="$!"
  printf '%s\n' "$stubborn_pid" >"$tmp_dir/state/observability-exporter.pid"
  if ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
      "$SCRIPT_DIR/observability.sh" exporter stop >"$out" 2>&1; then
    die "observability exporter stop succeeded while process ignored SIGTERM"
  fi
  grep -F 'stop requested but pid is still running' "$out" >/dev/null ||
    die "observability exporter stop did not expose stubborn process"
  [[ -f "$tmp_dir/state/observability-exporter.pid" ]] ||
    die "observability exporter stop removed pid file for still-running process"
  kill -KILL "$stubborn_pid" >/dev/null 2>&1 || true
  wait "$stubborn_pid" 2>/dev/null || true
  stubborn_pid=""
  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    "$SCRIPT_DIR/observability.sh" exporter stop >"$out"
  grep -F 'observability exporter not running' "$out" >/dev/null ||
    die "observability exporter stop did not clean stale pid after forced kill"

  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    ENGINEOS_AGENT_LEDGER_DIR="$ledger" \
    "$SCRIPT_DIR/observability.sh" tui --once >"$out"
  grep -F 'EngineOS Observability' "$out" >/dev/null ||
    die "observability TUI one-shot missing title"
  grep -F 'cleaner' "$out" >/dev/null ||
    die "observability TUI one-shot missing cleaner row"

  "$SCRIPT_DIR/observability.sh" hook zsh >"$out"
  grep -F 'add-zsh-hook preexec' "$out" >/dev/null ||
    die "zsh observability hook missing preexec"
  "$SCRIPT_DIR/observability.sh" hook bash >"$out"
  grep -F 'PROMPT_COMMAND=' "$out" >/dev/null ||
    die "bash observability hook missing PROMPT_COMMAND"
  grep -F 'eos-observe prompt-login --shell zsh' "$ROOT/tools/post-install-payload/assets/zprofile" >/dev/null ||
    die "zprofile does not prompt for observability opt-in"
  if grep -F 'eos-observe hook zsh' "$ROOT/tools/post-install-payload/assets/zshrc" >/dev/null ||
      grep -F 'eos-observe hook zsh' "$ROOT/tools/post-install-payload/assets/zprofile" >/dev/null; then
    die "managed zsh files should not install per-command observability hooks"
  fi
  grep -F 'eos-observe prompt-login --shell bash' "$ROOT/archiso/enginedev/airootfs/etc/skel/.bash_profile" >/dev/null ||
    die "EngineDev bash profile does not prompt for observability opt-in"
  grep -F 'eos-observe hook bash' "$ROOT/archiso/engineruntime/airootfs/etc/skel/.bash_profile" >/dev/null ||
    die "EngineRuntime bash profile does not install observability hook"

  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    "$SCRIPT_DIR/observability.sh" purge >/dev/null
  [[ ! -e "$events" ]] ||
    die "observability purge left event log behind"

  printf 'observability smoke test passed\n'
}

run_agent_route() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-agent-route-test-$$"
  local out="$tmp_dir/out.txt"
  local events="$tmp_dir/state/events.jsonl"

  cleanup_agent_route() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_agent_route RETURN

  mkdir -p "$tmp_dir"

  "$SCRIPT_DIR/agent_route.sh" route --dry-run "compile a C++ repo from source for the target" >"$out"
  grep -F 'role=compiler' "$out" >/dev/null ||
    die "agent route did not select compiler"
  grep -F 'risk=medium' "$out" >/dev/null ||
    die "agent route did not assign compiler risk"
  grep -F 'proof=eos-ci local --no-validate-repo --clean-generated' "$out" >/dev/null ||
    die "agent route did not suggest compiler proof"

  "$SCRIPT_DIR/agent_route.sh" route --dry-run "quake generator needs pak assets and input defaults" >"$out"
  grep -F 'role=pergame-quake' "$out" >/dev/null ||
    die "agent route did not select pergame-quake"

  "$SCRIPT_DIR/agent_route.sh" route --dry-run "manage wayland windows and tiling app slots" >"$out"
  grep -F 'role=admin-shell' "$out" >/dev/null ||
    die "agent route did not select admin-shell"

  "$SCRIPT_DIR/agent_route.sh" route --dry-run "clean up stale duplicated skill docs and profile drift" >"$out"
  grep -F 'role=cleaner' "$out" >/dev/null ||
    die "agent route did not select cleaner"

  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    "$SCRIPT_DIR/observability.sh" enable >/dev/null
  ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir/state" \
    "$SCRIPT_DIR/agent_route.sh" route --dry-run "troubleshoot service startup logs" >"$out"
  grep -F 'role=overseer' "$out" >/dev/null ||
    die "agent route did not select overseer"
  grep -F 'proof=eos-doctor' "$out" >/dev/null ||
    die "agent route did not suggest overseer proof"
  grep -F '"kind":"agent-route"' "$events" >/dev/null ||
    die "agent route did not record metadata when observability enabled"
  grep -F '"request_hash":"' "$events" >/dev/null ||
    die "agent route metadata missing request hash"
  if grep -F 'troubleshoot service startup logs' "$events" >/dev/null; then
    die "agent route stored raw request"
  fi

  printf 'agent route smoke test passed\n'
}

run_installed_preflight() {
  local tmp_dir="/tmp/engineos-installed-preflight-$$"
  local root_dir="$tmp_dir/usr"
  local bin_dir="$tmp_dir/usr/bin"
  local script_dir="$tmp_dir/usr/lib/engineos/scripts"
  local eos_dir="$tmp_dir/usr/lib/engineos/eos"
  local lib_bin_dir="$tmp_dir/usr/lib/engineos/bin"
  local out="$tmp_dir/preflight.txt"

  cleanup_installed_preflight() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_installed_preflight RETURN

  mkdir -p "$bin_dir" "$script_dir" "$eos_dir" "$lib_bin_dir"
  cp "$ROOT/tools/engineos/eos" "$bin_dir/eos"
  for cmd in eos-doctor eos-build eos-agent eos-observe eos-test; do
    cp "$ROOT/tools/engineos/eos-wrapper" "$bin_dir/$cmd"
  done
  cp "$ROOT/tools/engineos/engineos" "$bin_dir/engineos"
  cp "$ROOT/tools/scripts/"*.sh "$script_dir/"
  cp -R "$ROOT/tools/eos"/. "$eos_dir/"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$lib_bin_dir/engine-runner-daemon"
  chmod +x "$bin_dir/"* "$script_dir/"*.sh "$eos_dir"/*/*.sh "$lib_bin_dir/engine-runner-daemon"

  ENGINEOS_INSTALLED_IMAGE=true \
    ENGINEOS_ROOT="$root_dir" \
    ENGINEOS_INSTALLED_BIN_DIR="$bin_dir" \
    ENGINEOS_INSTALLED_SCRIPT_DIR="$script_dir" \
    ENGINEOS_INSTALLED_EOS_DIR="$eos_dir" \
    ENGINEOS_INSTALLED_LIB_BIN_DIR="$lib_bin_dir" \
    "$SCRIPT_DIR/preflight.sh" scripts >"$out"

  grep -F "OK   $bin_dir/eos" "$out" >/dev/null ||
    die "installed preflight did not check installed eos dispatcher"
  grep -F "OK   $bin_dir/eos-doctor" "$out" >/dev/null ||
    die "installed preflight did not check installed eos-doctor"
  grep -F "OK   $eos_dir/proof/proof.sh" "$out" >/dev/null ||
    die "installed preflight did not check installed proof module"
  grep -F 'Preflight summary: 0 failure(s)' "$out" >/dev/null ||
    die "installed preflight did not pass"

  printf 'installed preflight test passed\n'
}

run_ci() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-ci-test-$$"
  local out="$tmp_dir/ci.txt"

  cleanup_ci() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_ci RETURN
  mkdir -p "$tmp_dir"

  "$ROOT/tools/engineos/eos-ci" local --dry-run --package engineos-tools --test agent --install --clean-generated >"$out"
  grep -F 'EngineOS local CI pipeline' "$out" >/dev/null ||
    die "ci dry-run did not print pipeline header"
  grep -F 'DRY-RUN ' "$out" >/dev/null ||
    die "ci dry-run did not print commands"
  grep -F 'eos-test agent' "$out" >/dev/null ||
    die "ci dry-run did not include requested test scope"
  grep -F 'eos-build repo --package engineos-tools' "$out" >/dev/null ||
    die "ci dry-run did not include real package rebuild command"
  grep -F 'sudo -n pacman -U --noconfirm' "$out" >/dev/null ||
    die "ci dry-run did not include reinstall command"
  grep -F 'eos-validate repo' "$out" >/dev/null ||
    die "ci dry-run did not include real repo validation command"

  if "$ROOT/tools/engineos/eos-ci" local --package not-a-package >"$out" 2>&1; then
    die "ci accepted an unknown package"
  fi
  grep -F 'unknown EngineOS package: not-a-package' "$out" >/dev/null ||
    die "ci unknown package error was not clear"

  if "$ROOT/tools/engineos/eos-ci" local --package engineos-tools --test ci >"$out" 2>&1; then
    die "ci real mode should reject repo validation outside /srv/engineos"
  fi
  grep -F 'real repo validation must run from /srv/engineos' "$out" >/dev/null ||
    die "ci repo validation location error was not clear"

  printf 'ci loop smoke test passed\n'
}

run_shell_actions() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-shell-actions-$$"
  local fake_shell="$tmp_dir/engineos-shell"
  local args_file="$tmp_dir/args.txt"

  cleanup_shell_actions() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_shell_actions RETURN

  mkdir -p "$tmp_dir/logs"
  cat >"$fake_shell" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ENGINEOS_FAKE_SHELL_ARGS"
printf 'fake shell stdout marker\n'
FAKE
  chmod +x "$fake_shell"

  ENGINEOS_SHELL_BIN="$fake_shell" \
    ENGINEOS_FAKE_SHELL_ARGS="$args_file" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    ENGINEOS_TERMINAL_SLOT_CMD="foot --server" \
    ENGINEOS_CUBE_CMD="eos-app launch cube --smoke" \
    ENGINEOS_ENGINE_CMD="eos-app launch quake --smoke" \
    "$SCRIPT_DIR/shell_runner.sh" --nested >/dev/null

  grep -Fx -- "--nested" "$args_file" >/dev/null || die "shell actions test missing --nested"
  grep -Fx -- "--terminal" "$args_file" >/dev/null || die "shell actions test missing --terminal"
  grep -Fx -- "foot --server" "$args_file" >/dev/null || die "shell actions test missing terminal command"
  grep -Fx -- "--terminal-secondary" "$args_file" >/dev/null || die "shell actions test missing --terminal-secondary"
  grep -E -- '(^|/)eos-app launch terminal-secondary$' "$args_file" >/dev/null || die "shell actions test missing secondary terminal app command"
  grep -Fx -- "--cube" "$args_file" >/dev/null || die "shell actions test missing --cube"
  grep -Fx -- "eos-app launch cube --smoke" "$args_file" >/dev/null || die "shell actions test missing cube command"
  grep -Fx -- "--engine" "$args_file" >/dev/null || die "shell actions test missing --engine"
  grep -Fx -- "eos-app launch quake --smoke" "$args_file" >/dev/null || die "shell actions test missing app command"

  ENGINEOS_SHELL_BIN="$fake_shell" \
    ENGINEOS_FAKE_SHELL_ARGS="$args_file" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    ENGINEOS_SHELL_BOOTSTRAP= \
    "$SCRIPT_DIR/shell_runner.sh" --tty >/dev/null

  grep -Fx -- "--tty" "$args_file" >/dev/null || die "shell actions test missing --tty"
  grep -Fx -- "--terminal" "$args_file" >/dev/null || die "shell actions tty missing --terminal"
  grep -E -- '(^|/)eos-app launch terminal$' "$args_file" >/dev/null || die "shell actions tty missing default terminal app command"
  grep -Fx -- "--terminal-secondary" "$args_file" >/dev/null || die "shell actions tty missing --terminal-secondary"
  grep -E -- '(^|/)eos-app launch terminal-secondary$' "$args_file" >/dev/null || die "shell actions tty missing default secondary terminal app command"
  grep -Fx -- "--cube" "$args_file" >/dev/null || die "shell actions tty missing --cube"
  grep -E -- '(^|/)eos-app launch cube$' "$args_file" >/dev/null || die "shell actions tty missing default cube command"
  grep -Fx -- "--engine" "$args_file" >/dev/null || die "shell actions tty missing --engine"
  grep -E -- '(^|/)eos-app launch quake$' "$args_file" >/dev/null || die "shell actions tty missing default app command"
  grep -Fx -- "--bootstrap" "$args_file" >/dev/null || die "shell actions tty missing --bootstrap"
  grep -Fx -- "launchpad" "$args_file" >/dev/null || die "shell actions tty missing bootstrap launchpad"
  grep -F 'fake shell stdout marker' "$tmp_dir/logs/shell.log" >/dev/null ||
    die "shell actions did not tee real shell output to shell log"

  printf 'shell actions smoke test passed\n'
}

run_engine_runner_env() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-runner-env-$$"
  local out="$tmp_dir/out.txt"
  local stubborn_pid=""

  cleanup_engine_runner_env() {
    if [[ -n "$stubborn_pid" ]]; then
      kill -KILL "-$stubborn_pid" >/dev/null 2>&1 || kill -KILL "$stubborn_pid" >/dev/null 2>&1 || true
    fi
    ENGINEOS_STATE_DIR="$tmp_dir/run" ENGINEOS_LOG_DIR="$tmp_dir/logs" "$SCRIPT_DIR/engine_runner.sh" daemon-stop >/dev/null 2>&1 || true
    rm -rf "$tmp_dir"
  }
  trap cleanup_engine_runner_env RETURN

  mkdir -p "$tmp_dir/run" "$tmp_dir/logs"

  mkdir -p "$tmp_dir/not-a-source-root"
  if ENGINEOS_ROOT="$tmp_dir/not-a-source-root" \
      ENGINEOS_STATE_DIR="$tmp_dir/fail-run" \
      ENGINEOS_LOG_DIR="$tmp_dir/fail-logs" \
      ENGINEOS_ENGINE_RUNNER_DAEMON="$tmp_dir/missing-daemon" \
      "$SCRIPT_DIR/engine_runner.sh" status >"$out" 2>&1; then
    die "engine runner used Python fallback without explicit opt-in"
  fi
  grep -F 'ENGINEOS_ENGINE_RUNNER_ALLOW_PYTHON_FALLBACK=true' "$out" >/dev/null ||
    die "engine runner fallback failure did not require explicit opt-in"

  local ENGINEOS_ENGINE_RUNNER_ALLOW_PYTHON_FALLBACK=true
  export ENGINEOS_ENGINE_RUNNER_ALLOW_PYTHON_FALLBACK

  ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    "$SCRIPT_DIR/engine_runner.sh" status >"$out"
  grep -F 'engine status: stopped' "$out" >/dev/null ||
    die "engine runner initial status was not stopped"

  if ENGINEOS_STATE_DIR="$tmp_dir/run" \
      ENGINEOS_LOG_DIR="$tmp_dir/logs" \
      "$SCRIPT_DIR/engine_runner.sh" restart >"$out" 2>&1; then
    die "engine runner restart without previous target should fail"
  fi
  grep -F 'no previous engine target to restart' "$out" >/dev/null ||
    die "engine runner restart without target did not explain the failure"

  if ! command -v setsid >/dev/null 2>&1; then
    die "setsid unavailable; cannot test stubborn engine stop behavior"
  fi
  setsid sh -c 'trap "" TERM; while :; do sleep 1; done' >/dev/null 2>&1 &
  stubborn_pid="$!"
  printf '%s\n' "$stubborn_pid" >"$tmp_dir/run/engine.pid"
  printf 'quake\n' >"$tmp_dir/run/engine.target"
  printf '["--smoke"]' >"$tmp_dir/run/engine.args.json"
  if ENGINEOS_STATE_DIR="$tmp_dir/run" \
      ENGINEOS_LOG_DIR="$tmp_dir/logs" \
      "$SCRIPT_DIR/engine_runner.sh" restart >"$out" 2>&1; then
    die "engine runner restart succeeded while previous engine ignored SIGTERM"
  fi
  grep -F 'engine restart aborted: engine stop requested but pid is still running' "$out" >/dev/null ||
    die "engine runner restart did not expose previous engine stop failure"
  kill -KILL "-$stubborn_pid" >/dev/null 2>&1 || kill -KILL "$stubborn_pid" >/dev/null 2>&1 || true
  wait "$stubborn_pid" 2>/dev/null || true
  stubborn_pid=""
  rm -f "$tmp_dir/run/engine.pid" "$tmp_dir/run/engine.target" "$tmp_dir/run/engine.args.json"

  mkdir "$tmp_dir/run/engine.pid"
  if ENGINEOS_STATE_DIR="$tmp_dir/run" \
      ENGINEOS_LOG_DIR="$tmp_dir/logs" \
      WAYLAND_DISPLAY="engineos-test-wayland" \
      "$SCRIPT_DIR/engine_runner.sh" launch quake --smoke >"$out" 2>&1; then
    die "engine runner launch succeeded when engine state could not be recorded"
  fi
  grep -F 'launch failed to record engine state' "$out" >/dev/null ||
    die "engine runner launch did not expose state recording failure"
  rm -rf "$tmp_dir/run/engine.pid"

  ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/engine_runner.sh" launch quake --smoke >"$out"
  grep -F 'engine launched: quake' "$out" >/dev/null ||
    die "engine runner launch did not report quake launch"

  ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    "$SCRIPT_DIR/engine_runner.sh" status >"$out"
  grep -F 'target: quake' "$out" >/dev/null ||
    die "engine runner status did not retain quake target"

  ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/engine_runner.sh" restart >"$out"
  grep -F 'engine launched: quake' "$out" >/dev/null ||
    die "engine runner restart did not relaunch previous quake target"

  ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    "$SCRIPT_DIR/engine_runner.sh" quit >"$out"
  grep -E 'engine (already )?stopped|engine stop requested' "$out" >/dev/null ||
    die "engine runner quit did not report a stopped/stopping engine"

  if ! grep -F 'display=engineos-test-wayland' "$tmp_dir/logs/engine.log" >/dev/null; then
    die "engine runner did not forward WAYLAND_DISPLAY to launch log"
  fi
  if [[ "$(grep -c 'socket launch quake --smoke display=engineos-test-wayland' "$tmp_dir/logs/engine.log")" -lt 2 ]]; then
    die "engine runner lifecycle did not log both launch and restart"
  fi

  printf 'engine runner lifecycle smoke test passed\n'
}

run_image_preview() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-image-preview-test-$$"
  local fake_bin="$tmp_dir/bin"
  local tool_bin="$tmp_dir/tool-bin"
  local out="$tmp_dir/out.txt"
  local err="$tmp_dir/err.txt"
  local png="$tmp_dir/sample.png"
  local jpg="$tmp_dir/sample.jpg"
  local sock="$tmp_dir/preview.sock"
  local preview_bin="$ROOT/tools/engineos/engine-image-preview"
  local shell_bin="$ROOT/build/shell/engineos-shell"
  local shell_pid=""

  cleanup_image_preview() {
    if [[ -n "$shell_pid" ]]; then
      kill "$shell_pid" >/dev/null 2>&1 || true
      wait "$shell_pid" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp_dir"
  }
  trap cleanup_image_preview RETURN

  mkdir -p "$fake_bin" "$tmp_dir/dir"
  if [[ ! -x "$preview_bin" ]]; then
    preview_bin="${ENGINEOS_INSTALLED_BIN_DIR:-/usr/bin}/engine-image-preview"
  fi
  [[ -x "$preview_bin" ]] || die "engine-image-preview helper is not executable"

  python - "$png" "$jpg" <<'PY'
import base64
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_bytes(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADAQMAAACOOjyFAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURSJmzP///8VU6LMAAAABYktHRAH/Ai3eAAAAB3RJTUUH6gcCFi0VNn7nGQAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAyNi0wNy0wMlQyMjo0NToyMSswMDowMIBjV7MAAAAldEVYdGRhdGU6bW9kaWZ5ADIwMjYtMDctMDJUMjI6NDU6MjErMDA6MDDxPu8PAAAAKHRFWHRkYXRlOnRpbWVzdGFtcAAyMDI2LTA3LTAyVDIyOjQ1OjIxKzAwOjAwpivO0AAAAAtJREFUCNdjYAABAAAGAAFm9MlsAAAAAElFTkSuQmCC"
))
pathlib.Path(sys.argv[2]).write_bytes(base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAADAAQDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAAB//EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAVAQEBAAAAAAAAAAAAAAAAAAAHCP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/ACJUoPf/2Q=="
))
PY

  PATH="$fake_bin:$PATH" \
    ENGINEOS_PREVIEW_SLOT=terminal-secondary \
    "$preview_bin" --view "$png" --dry-run >"$out"
  grep -F '"op":"show"' "$out" >/dev/null ||
    die "image preview dry-run did not emit show op"
  grep -F '"anchor":"active-pane"' "$out" >/dev/null ||
    die "image preview dry-run did not request active pane anchor"
  grep -F '"slot":"terminal-secondary"' "$out" >/dev/null ||
    die "image preview dry-run did not include terminal slot"
  grep -F '"owner":' "$out" >/dev/null ||
    die "image preview dry-run did not include owner token"
  grep -F "\"path\":\"$png\"" "$out" >/dev/null ||
    die "image preview dry-run did not include resolved path"

  cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "display-message" ]]; then
  printf '10 5 80 24 160 48\n'
  exit 0
fi
exit 1
FAKE
  chmod +x "$fake_bin/tmux"

  PATH="$fake_bin:$PATH" \
    TMUX_PANE="%1" \
    "$preview_bin" --open "$png" --dry-run >"$out"
  for field in '"x":10' '"y":5' '"width":80' '"height":24' '"window_width":160' '"window_height":48'; do
    grep -F "$field" "$out" >/dev/null ||
      die "image preview dry-run did not include tmux bounds field $field"
  done

  if "$preview_bin" --view "$tmp_dir/missing.png" --dry-run >"$out" 2>"$err"; then
    die "image preview accepted missing path"
  fi
  grep -F 'cannot read image path' "$err" >/dev/null ||
    die "image preview missing path error was not visible"

  if "$preview_bin" --view "$tmp_dir/dir" --dry-run >"$out" 2>"$err"; then
    die "image preview accepted directory"
  fi
  grep -F 'image path is a directory' "$err" >/dev/null ||
    die "image preview directory error was not visible"

  printf 'not an image\n' >"$tmp_dir/not-image.txt"
  if "$preview_bin" --view "$tmp_dir/not-image.txt" --dry-run >"$out" 2>"$err"; then
    die "image preview accepted unsupported image"
  fi
  grep -F 'unsupported image type' "$err" >/dev/null ||
    die "image preview unsupported type error was not visible"

  if ENGINEOS_PREVIEW_SOCKET="$sock" "$preview_bin" --ping >"$out" 2>"$err"; then
    die "image preview ping should fail when IPC socket is missing"
  fi
  grep -F 'shell preview IPC unavailable' "$err" >/dev/null ||
    die "image preview missing IPC error was not visible"

  python - "$sock" <<'PY' &
import os
import socket
import sys
path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(1)
client, _ = server.accept()
client.recv(4096)
client.sendall(b'{"version":1,"status":"ok","capabilities":["ping"]}\n')
client.close()
server.close()
PY
  local server_pid=$!
  for _ in {1..50}; do
    [[ -S "$sock" ]] && break
    sleep 0.02
  done
  ENGINEOS_PREVIEW_SOCKET="$sock" "$preview_bin" --ping >"$out" 2>"$err"
  wait "$server_pid"
  grep -F 'shell preview IPC ready' "$err" >/dev/null ||
    die "image preview ping success did not report readiness"

  if [[ -x "$shell_bin" ]]; then
    local shell_state="$tmp_dir/shell-state"
    local shell_log="$tmp_dir/shell.log"
    ENGINEOS_STATE_DIR="$shell_state" \
      WLR_BACKENDS=headless \
      WLR_HEADLESS_OUTPUTS=1 \
      WLR_RENDERER_ALLOW_SOFTWARE=1 \
      "$shell_bin" --headless --smoke-ms 3000 >"$shell_log" 2>&1 &
    shell_pid=$!
    for _ in {1..100}; do
      [[ -S "$shell_state/preview.sock" ]] && break
      sleep 0.03
    done
    [[ -S "$shell_state/preview.sock" ]] ||
      die "compiled shell did not create preview IPC socket"

    ENGINEOS_PREVIEW_SOCKET="$shell_state/preview.sock" "$preview_bin" --ping >"$out" 2>"$err"
    ENGINEOS_PREVIEW_SOCKET="$shell_state/preview.sock" "$preview_bin" --view "$png" >"$out" 2>"$err"
    ENGINEOS_PREVIEW_SOCKET="$shell_state/preview.sock" "$preview_bin" --view "$jpg" >"$out" 2>"$err"
    ENGINEOS_PREVIEW_SOCKET="$shell_state/preview.sock" "$preview_bin" --hide >"$out" 2>"$err"
    wait "$shell_pid"
    shell_pid=""

    grep -F "image preview shown path=$png" "$shell_log" | grep -F "image=4x3" >/dev/null ||
      die "compiled shell did not decode and show PNG preview"
    grep -F "image preview shown path=$jpg" "$shell_log" | grep -F "image=4x3" >/dev/null ||
      die "compiled shell did not decode and show JPEG preview"
    grep -F "image preview hidden reason=ipc-hide" "$shell_log" >/dev/null ||
      die "compiled shell did not hide image preview"
  fi

  printf 'image preview contract test passed\n'
}

run_app() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-app-test-$$"
  local fake_bin="$tmp_dir/bin"
  local log_dir="$tmp_dir/logs"
  local out="$tmp_dir/out.txt"
  local launched="$tmp_dir/launched.txt"

  cleanup_app() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_app RETURN

  mkdir -p "$fake_bin" "$log_dir" "$tmp_dir/run"
  cat >"$fake_bin/eos-runtime" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$ENGINEOS_FAKE_APP_LAUNCHED"
FAKE
  cat >"$fake_bin/engineos-cube" <<'FAKE'
#!/usr/bin/env bash
printf 'fake cube %s\n' "$*"
printf 'libdecor=%s\n' "${SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR:-unset}"
FAKE
  cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "display-message" ]]; then
  printf '%s\n' "${ENGINEOS_FAKE_TMUX_GEOMETRY:-10 5 80 24 160 48}"
  exit 0
fi
exit 1
FAKE
  cat >"$fake_bin/pkill" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
  cat >"$fake_bin/pgrep" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
  chmod +x "$fake_bin/eos-runtime" "$fake_bin/engineos-cube" "$fake_bin/tmux" "$fake_bin/pkill" "$fake_bin/pgrep"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_RUNTIME_CMD="$fake_bin/eos-runtime" \
    ENGINEOS_FAKE_APP_LAUNCHED="$launched" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/app.sh" launch quake --smoke >"$out"
  grep -F 'engine launch quake --smoke' "$launched" >/dev/null ||
    die "app launcher did not dispatch quake through engine runner"
  grep -F 'app launch app=quake owner=engineos-shell display=engineos-test-wayland sdl=wayland args=--smoke' "$log_dir/app.log" >/dev/null ||
    die "app launcher did not log shell-owned quake launch"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_RUNTIME_CMD="$fake_bin/eos-runtime" \
    ENGINEOS_FAKE_APP_LAUNCHED="$launched" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    TMUX="$tmp_dir/tmux-socket,1,0" \
    TMUX_PANE="%1" \
    "$SCRIPT_DIR/app.sh" launch quake >"$out"
  grep -F 'engine launch quake --window' "$launched" >/dev/null ||
    die "app launcher did not force pane-bounded quake into windowed mode"
  grep -F 'mode=pane' "$tmp_dir/run/launch-bounds/engine.env" >/dev/null ||
    die "app launcher did not write pane bounds request"
  grep -F 'pane_left=10' "$tmp_dir/run/launch-bounds/engine.env" >/dev/null ||
    die "app launcher pane bounds missing tmux pane left"
  grep -F 'window_height=48' "$tmp_dir/run/launch-bounds/engine.env" >/dev/null ||
    die "app launcher pane bounds missing tmux window height"
  grep -F 'app layout app=quake mode=pane source=tmux bounds=10 5 80 24 160 48' "$log_dir/app.log" >/dev/null ||
    die "app launcher did not log tmux pane bounds"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_RUNTIME_CMD="$fake_bin/eos-runtime" \
    ENGINEOS_FAKE_APP_LAUNCHED="$launched" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    TMUX="$tmp_dir/tmux-socket,1,0" \
    TMUX_PANE="%1" \
    "$SCRIPT_DIR/app.sh" launch quake --fullscreen >"$out"
  grep -F 'engine launch quake --fullscreen' "$launched" >/dev/null ||
    die "app launcher did not pass quake fullscreen flag"
  grep -F 'mode=output' "$tmp_dir/run/launch-bounds/engine.env" >/dev/null ||
    die "app launcher did not clear pane bounds for fullscreen launch"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    TMUX="$tmp_dir/tmux-socket,1,0" \
    TMUX_PANE="%1" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/app.sh" launch cube --smoke >"$out"
  grep -F 'app launch app=cube owner=engineos-shell display=engineos-test-wayland sdl=wayland libdecor=0 args=--smoke' "$log_dir/app.log" >/dev/null ||
    die "app launcher did not log shell-owned cube launch"
  grep -F 'mode=pane' "$tmp_dir/run/launch-bounds/cube.env" >/dev/null ||
    die "app launcher did not write pane bounds request for cube"
  grep -F 'pane_left=10' "$tmp_dir/run/launch-bounds/cube.env" >/dev/null ||
    die "app launcher cube pane bounds missing tmux pane left"
  grep -F 'app layout app=cube mode=pane source=tmux bounds=10 5 80 24 160 48' "$log_dir/app.log" >/dev/null ||
    die "app launcher did not log tmux pane bounds for cube"
  grep -F 'fake cube --smoke' "$log_dir/cube.log" >/dev/null ||
    die "app launcher did not write cube output to cube log"
  grep -F 'libdecor=0' "$log_dir/cube.log" >/dev/null ||
    die "app launcher did not disable libdecor for cube"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_APP_NOTIFY_SHELL=false \
    ENGINEOS_FAKE_TMUX_GEOMETRY="20 6 70 20 160 48" \
    TMUX="$tmp_dir/tmux-socket,1,0" \
    TMUX_PANE="%1" \
    "$SCRIPT_DIR/app.sh" pane sync cube >"$out"
  grep -F 'pane_left=20' "$tmp_dir/run/launch-bounds/cube.env" >/dev/null ||
    die "app pane sync did not refresh cube pane left"
  grep -F 'pane_height=20' "$tmp_dir/run/launch-bounds/cube.env" >/dev/null ||
    die "app pane sync did not refresh cube pane height"
  grep -F 'synced cube pane %1 bounds 20 6 70 20 160 48' "$out" >/dev/null ||
    die "app pane sync did not report refreshed cube bounds"
  grep -F 'app pane sync role=cube source=tmux pane=%1 bounds=20 6 70 20 160 48' "$log_dir/app.log" >/dev/null ||
    die "app pane sync did not log refreshed cube bounds"

  if PATH="$fake_bin:$PATH" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_STATE_DIR="$tmp_dir/run" \
      ENGINEOS_FAKE_TMUX_GEOMETRY="25 8 66 19 160 48" \
      TMUX="$tmp_dir/tmux-socket,1,0" \
      TMUX_PANE="%1" \
      "$SCRIPT_DIR/app.sh" pane sync cube >"$out" 2>&1; then
    die "app pane sync succeeded when shell notification could not be delivered"
  fi
  grep -F 'pane_left=25' "$tmp_dir/run/launch-bounds/cube.env" >/dev/null ||
    die "app pane sync failure path did not refresh cube pane bounds before notifying"
  grep -F 'pane sync notify=failed reason=shell-not-running' "$log_dir/app.log" >/dev/null ||
    die "app pane sync did not log failed shell notification"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_APP_NOTIFY_SHELL=false \
    ENGINEOS_FAKE_TMUX_GEOMETRY="30 7 60 18 160 48" \
    TMUX="$tmp_dir/tmux-socket,1,0" \
    "$SCRIPT_DIR/app.sh" pane sync --all >"$out"
  grep -F 'pane_left=30' "$tmp_dir/run/launch-bounds/cube.env" >/dev/null ||
    die "app pane sync --all did not refresh stored cube pane"
  grep -F 'synced cube pane %1 bounds 30 7 60 18 160 48' "$out" >/dev/null ||
    die "app pane sync --all did not use stored pane id"

  if env -u WAYLAND_DISPLAY -u DISPLAY \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_STATE_DIR="$tmp_dir/run" \
      "$SCRIPT_DIR/app.sh" launch quake --smoke >/dev/null 2>&1; then
    die "app launcher should require WAYLAND_DISPLAY by default"
  fi
  grep -F 'reason=missing-wayland-display app=quake' "$log_dir/app.log" >/dev/null ||
    die "app launcher did not log missing Wayland display"

  ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_STATE_DIR="$tmp_dir/run" \
    "$SCRIPT_DIR/app.sh" --dry-run launch terminal --class EngineOS >"$out"
  grep -F 'EngineOS app launch dry-run' "$out" >/dev/null ||
    die "app launcher dry-run missing header"
  grep -F 'app:      terminal' "$out" >/dev/null ||
    die "app launcher dry-run missing app id"

  printf '[2026-01-01T00:00:00Z] app launch app=terminal owner=engineos-shell display=engineos-test-wayland\n' >>"$log_dir/app.log"
  {
    printf '[2026-01-01T00:00:00Z] bootstrap mode=launchpad\n'
    printf '[2026-01-01T00:00:01Z] launchpad active slot=cube mode=terminal capture=none reason=bootstrap-launchpad\n'
    printf '[2026-01-01T00:00:02Z] view mapped role=cube title=engineos-cube app_id=engineos-cube mapped_total=1\n'
  } >"$log_dir/shell.log"
  cat >"$tmp_dir/run/shell-state.json" <<'JSON'
{
  "schema": "engineos-shell-state-v0",
  "active_slot": "terminal",
  "pending_slot": "unknown",
  "slots": {
    "terminal": {"mapped": true, "visible": true, "layout": "output", "fullscreen": false, "x": 0, "y": 0, "width": 1600, "height": 900, "title": "EngineOS", "app_id": "foot"},
    "cube": {"mapped": true, "visible": true, "layout": "tmux-pane", "fullscreen": false, "x": 200, "y": 100, "width": 700, "height": 375, "title": "engineos-cube", "app_id": "engineos-cube"},
    "engine": {"mapped": false, "visible": false, "layout": "", "fullscreen": false, "x": 0, "y": 0, "width": 0, "height": 0, "title": "", "app_id": ""}
  }
}
JSON
  ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_STATE_DIR="$tmp_dir/run" \
    "$SCRIPT_DIR/app.sh" status --json >"$out"
  grep -F '"active_slot":"terminal"' "$out" >/dev/null ||
    die "app status json did not report shell-state active terminal slot"
  grep -F '"manifest": "' "$out" >/dev/null ||
    die "app status json did not report manifest path"
  grep -F '"terminal": {"app":"terminal","command":"eos-app launch terminal","launch_state":"launch-requested"' "$out" >/dev/null ||
    die "app status json did not report terminal launch state"
  grep -F '"terminal-secondary": {"app":"terminal-secondary","command":"eos-app launch terminal-secondary","launch_state":"missing"' "$out" >/dev/null ||
    die "app status json did not report secondary terminal slot"
  grep -F '"cube": {"app":"cube","command":"eos-app launch cube","launch_state":"launch-requested","mapped":true' "$out" >/dev/null ||
    die "app status json did not report mapped cube state"
  grep -F '"visible":true,"layout":"tmux-pane","fullscreen":false,"x":200,"y":100,"width":700,"height":375' "$out" >/dev/null ||
    die "app status json did not report pane visibility and bounds from shell state"
  grep -F '"shell_last_log":"[2026-01-01T00:00:02Z] view mapped role=cube title=engineos-cube app_id=engineos-cube mapped_total=1"' "$out" >/dev/null ||
    die "app status json did not report shell lifecycle evidence"
  [[ -f "$tmp_dir/run/apps/cube.status" ]] ||
    die "app launcher did not write cube state record"

  "$SCRIPT_DIR/app.sh" manifest validate >"$out"
  grep -F 'App manifest validation summary: 0 failure(s)' "$out" >/dev/null ||
    die "app manifest validation did not pass"
  grep -F 'cube.app_ids contains engineos-cube' "$out" >/dev/null ||
    die "app manifest validation did not check cube app id"
  grep -F 'terminal-secondary.app_ids contains engineos-terminal-secondary' "$out" >/dev/null ||
    die "app manifest validation did not check secondary terminal app id"

  printf 'app launcher smoke test passed\n'
}

run_assets() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-assets-test-$$"
  local id1="$tmp_dir/home/.local/share/engineos/quake/id1"
  local log_dir="$tmp_dir/logs"
  local fake_bin="$tmp_dir/bin/quakespasm"

  cleanup_assets() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_assets RETURN

  mkdir -p "$tmp_dir/home" "$tmp_dir/bin" "$log_dir"

  if HOME="$tmp_dir/home" "$SCRIPT_DIR/assets.sh" check quake >/dev/null 2>&1; then
    die "assets test expected missing Quake assets to fail"
  fi

  HOME="$tmp_dir/home" "$SCRIPT_DIR/assets.sh" prepare quake >/dev/null
  [[ -d "$id1" ]] || die "assets prepare did not create default id1 directory"
  printf 'test pak placeholder\n' >"$id1/pak0.pak"

  [[ "$(HOME="$tmp_dir/home" "$SCRIPT_DIR/assets.sh" path quake)" == "$id1" ]] ||
    die "assets path did not resolve default id1 directory"

  local config_id1="$tmp_dir/config-id1"
  mkdir -p "$tmp_dir/home/.config/engineos" "$config_id1"
  printf 'ENGINEOS_QUAKE_ID1=%s\n' "$config_id1" >"$tmp_dir/home/.config/engineos/quake.conf"
  printf 'config pak placeholder\n' >"$config_id1/pak0.pak"
  [[ "$(HOME="$tmp_dir/home" "$SCRIPT_DIR/assets.sh" path quake)" == "$config_id1" ]] ||
    die "assets path did not honor user config"

  local env_id1="$tmp_dir/env-id1"
  mkdir -p "$env_id1"
  printf 'env pak placeholder\n' >"$env_id1/pak0.pak"
  [[ "$(HOME="$tmp_dir/home" ENGINEOS_QUAKE_ID1="$env_id1" "$SCRIPT_DIR/assets.sh" path quake)" == "$env_id1" ]] ||
    die "assets path did not prefer environment override"

  cat >"$fake_bin" <<'FAKE'
#!/usr/bin/env bash
printf 'fake quakespasm args: %s\n' "$*"
FAKE
  chmod +x "$fake_bin"

  HOME="$tmp_dir/home" \
    ENGINEOS_QUAKE_ID1="$id1" \
    ENGINEOS_QUAKE_SDL_AUDIODRIVER="pulseaudio" \
    ENGINEOS_QUAKE_ARGS="-window -width 640 -height 480" \
    PATH="$tmp_dir/bin:$PATH" \
    ENGINEOS_ROOT="$ROOT" \
    ENGINEOS_LOG_DIR="$log_dir" \
    QUAKESPASM_BIN="quakespasm" \
    "$ROOT/engines/quakespasm/engineos/run.sh" >/dev/null

  grep -F "QuakeSpasm basedir=$tmp_dir/home/.local/share/engineos/quake" "$log_dir/engine.log" >/dev/null ||
    die "quake run wrapper did not log resolved basedir"
  grep -F "QuakeSpasm audio_driver=pulseaudio" "$log_dir/engine.log" >/dev/null ||
    die "quake run wrapper did not log configured SDL audio driver"
  grep -F "QuakeSpasm configured_args=-window -width 640 -height 480" "$log_dir/engine.log" >/dev/null ||
    die "quake run wrapper did not log configured launch args"
  [[ -f "$id1/autoexec.cfg" ]] ||
    die "quake run wrapper did not create default autoexec.cfg"
  grep -F 'bind "w" "+forward"' "$id1/autoexec.cfg" >/dev/null ||
    die "quake default autoexec missing WASD forward binding"
  grep -F 'bind "MOUSE2" "+jump"' "$id1/autoexec.cfg" >/dev/null ||
    die "quake default autoexec missing mouse jump binding"
  grep -F '+mlook' "$id1/autoexec.cfg" >/dev/null ||
    die "quake default autoexec missing mouselook"

  local installed_log_dir="$tmp_dir/installed-logs"
  ENGINEOS_ROOT="/usr" \
    ENGINEOS_LOG_DIR="$installed_log_dir" \
    ENGINEOS_LOG_TEE=false \
    QUAKESPASM_BIN="quakespasm" \
    PATH="$tmp_dir/bin:$PATH" \
    "$ROOT/engines/quakespasm/engineos/run.sh" --smoke >/dev/null
  [[ -f "$installed_log_dir/engine.log" ]] ||
    die "quake installed-mode smoke did not write to configured log dir"
  grep -F 'QuakeSpasm smoke wrapper' "$installed_log_dir/engine.log" >/dev/null ||
    die "quake installed-mode smoke did not log expected marker"
  grep -F 'result=ok' "$installed_log_dir/engine.log" >/dev/null ||
    die "quake installed-mode smoke did not report real binary success"
  if [[ -e /usr/artifacts ]]; then
    die "quake installed-mode smoke created /usr/artifacts"
  fi

  local installed_root="$tmp_dir/installed-prefix/usr"
  local installed_script_dir="$tmp_dir/installed-scripts"
  local installed_env_out="$tmp_dir/installed-env.txt"
  mkdir -p "$installed_root/bin" "$installed_root/lib/engineos/scripts" "$installed_root/tools/scripts" "$installed_script_dir"
  cp "$ROOT/tools/engineos/eos" "$installed_root/bin/eos"
  cp "$ROOT/tools/engineos/eos-wrapper" "$installed_root/bin/eos-terminal"
  cat >"$installed_script_dir/terminal_launcher.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$ENGINEOS_LOG_DIR" >"$installed_env_out"
EOF
  chmod +x "$installed_root/bin/eos" "$installed_root/bin/eos-terminal" "$installed_script_dir/terminal_launcher.sh"
  env -u ENGINEOS_LOG_DIR \
    ENGINEOS_ROOT="$installed_root" \
    ENGINEOS_SCRIPT_DIR="$installed_script_dir" \
    "$installed_root/bin/eos-terminal" >/dev/null
  [[ "$(cat "$installed_env_out")" == "/var/log/engineos" ]] ||
    die "eos-installed-prefix default log dir was not /var/log/engineos"
  if [[ -e "$installed_root/artifacts" ]]; then
    die "eos-installed-prefix default created artifacts under installed root"
  fi

  printf 'assets smoke test passed\n'
}

run_reliability() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-reliability-$$"
  local log_dir="$tmp_dir/logs"
  local bundle_dir="$tmp_dir/bundle"
  local fake_bin="$tmp_dir/bin"
  local drm_sysfs="$tmp_dir/sys/class/drm"
  local runtime_conf="$tmp_dir/runtime.conf"
  local recovery_help=""
  local runtime_start=""
  local runtime_login_profile=""
  local runtime_issue=""

  cleanup_reliability() {
    ENGINEOS_STATE_DIR="$tmp_dir/run" ENGINEOS_LOG_DIR="$log_dir" "$SCRIPT_DIR/engine_runner.sh" daemon-stop >/dev/null 2>&1 || true
    rm -rf "$tmp_dir" || {
      sleep 0.2
      rm -rf "$tmp_dir"
    }
  }
  trap cleanup_reliability RETURN

  mkdir -p "$log_dir" "$bundle_dir" "$fake_bin" "$tmp_dir/home" "$tmp_dir/run" "$drm_sysfs/card0-HDMI-A-1"
  printf 'connected\n' >"$drm_sysfs/card0-HDMI-A-1/status"
  printf 'enabled\n' >"$drm_sysfs/card0-HDMI-A-1/enabled"
  printf '1920x1080\n1280x720\n' >"$drm_sysfs/card0-HDMI-A-1/modes"

  if command -v engineos-recovery-help >/dev/null 2>&1; then
    recovery_help="$(command -v engineos-recovery-help)"
  elif [[ -x "$ROOT/archiso/engineruntime/airootfs/usr/local/bin/engineos-recovery-help" ]]; then
    recovery_help="$ROOT/archiso/engineruntime/airootfs/usr/local/bin/engineos-recovery-help"
  fi
  [[ -x "$recovery_help" ]] || die "runtime recovery helper is not executable"

  if command -v engineos-runtime-start >/dev/null 2>&1; then
    runtime_start="$(command -v engineos-runtime-start)"
  elif [[ -x "$ROOT/archiso/engineruntime/airootfs/usr/local/bin/engineos-runtime-start" ]]; then
    runtime_start="$ROOT/archiso/engineruntime/airootfs/usr/local/bin/engineos-runtime-start"
  fi
  [[ -x "$runtime_start" ]] || die "runtime start helper is not executable"

  "$recovery_help" >"$tmp_dir/recovery-help.txt"
  grep -F 'eos-logs runtime --last 200' "$tmp_dir/recovery-help.txt" >/dev/null ||
    die "runtime recovery helper does not point to runtime logs"
  grep -F 'eos-crash-bundle' "$tmp_dir/recovery-help.txt" >/dev/null ||
    die "runtime recovery helper does not point to crash bundle"
  grep -F 'engineos.noautostart' "$tmp_dir/recovery-help.txt" >/dev/null ||
    die "runtime recovery helper does not mention autostart disable flag"

  if [[ -r "$ROOT/archiso/engineruntime/airootfs/etc/skel/.bash_profile" ]]; then
    runtime_login_profile="$ROOT/archiso/engineruntime/airootfs/etc/skel/.bash_profile"
  elif [[ -r /etc/skel/.bash_profile ]]; then
    runtime_login_profile="/etc/skel/.bash_profile"
  elif [[ -r "${HOME:-}/.bash_profile" ]]; then
    runtime_login_profile="${HOME}/.bash_profile"
  fi
  [[ -r "$runtime_login_profile" ]] || die "runtime login profile is not readable"
  grep -F 'engineos-recovery-help' "$runtime_login_profile" >/dev/null ||
    die "runtime login profile does not show recovery helper"

  if [[ -r "$ROOT/archiso/engineruntime/airootfs/etc/issue" ]]; then
    runtime_issue="$ROOT/archiso/engineruntime/airootfs/etc/issue"
  elif [[ -r /etc/issue ]]; then
    runtime_issue="/etc/issue"
  fi
  [[ -r "$runtime_issue" ]] || die "runtime issue file is not readable"
  grep -F 'eos-logs runtime --last 200' "$runtime_issue" >/dev/null ||
    die "runtime issue does not point to runtime logs"

  printf 'shell failure marker\n' >"$log_dir/shell.log"
  printf 'engine failure marker\n' >"$log_dir/engine.log"
  printf 'ENGINEOS_RUNTIME_AUTOSTART=1\nENGINEOS_RUNTIME_SHELL_MODE=--headless\n' >"$runtime_conf"
  cat >"$fake_bin/eos-runtime" <<'FAKE'
#!/usr/bin/env bash
printf 'fake eos-runtime failure: %s\n' "$*" >&2
exit 77
FAKE
  chmod +x "$fake_bin/eos-runtime"
  cat >"$fake_bin/ip" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "addr show")
    printf '1: lo: <LOOPBACK,UP> mtu 65536\n'
    printf '2: eth0: <BROADCAST,UP> mtu 1500\n'
    ;;
  "route show"|"route show default")
    printf 'default via 192.0.2.1 dev eth0 proto dhcp\n'
    ;;
  *)
    printf 'fake ip: %s\n' "$*" >&2
    exit 2
    ;;
esac
FAKE
  chmod +x "$fake_bin/ip"
  cat >"$fake_bin/nmcli" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "general status")
    printf 'STATE CONNECTIVITY WIFI-HW WIFI WWAN-HW WWAN\n'
    printf 'connected full enabled enabled enabled enabled\n'
    ;;
  "device status")
    printf 'DEVICE TYPE STATE CONNECTION\n'
    printf 'eth0 ethernet connected EngineOS test\n'
    ;;
  *)
    printf 'fake nmcli: %s\n' "$*" >&2
    exit 2
    ;;
esac
FAKE
  chmod +x "$fake_bin/nmcli"
  cat >"$fake_bin/resolvectl" <<'FAKE'
#!/usr/bin/env bash
[[ "$*" == "status" ]] || exit 2
printf 'Global\n'
printf '       DNS Servers: 192.0.2.53\n'
FAKE
  chmod +x "$fake_bin/resolvectl"

  if ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_RUNTIME_CMD="$fake_bin/eos-runtime" \
      "$runtime_start" >/dev/null 2>&1; then
    die "reliability test expected runtime shell failure"
  fi

  grep -F 'EngineOS shell failed rc=77' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime failure was not logged"
  grep -F 'recovery hint: switch to tty2 and run engineos-recovery-help' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime failure log did not include recovery helper hint"
  grep -F 'recovery logs: eos-logs runtime --last 200' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime failure log did not include runtime logs hint"
  grep -F 'recovery bundle: eos-crash-bundle' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime failure log did not include crash bundle hint"

  printf 'ENGINEOS_RUNTIME_AUTOSTART=0\nENGINEOS_RUNTIME_SHELL_MODE=--headless\n' >"$runtime_conf"
  if ! ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_RUNTIME_CMD="$fake_bin/eos-runtime" \
      "$runtime_start" >/dev/null 2>&1; then
    die "reliability test expected runtime config disable to succeed"
  fi
  grep -F 'runtime autostart disabled by runtime.conf' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime config disable was not logged"
  grep -F 'recovery hint: switch to tty2 and run engineos-recovery-help' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime config disable log did not include recovery helper hint"

  printf 'ENGINEOS_RUNTIME_AUTOSTART=1\nENGINEOS_RUNTIME_SHELL_MODE=--headless\n' >"$runtime_conf"
  printf 'quiet engineos.noautostart\n' >"$tmp_dir/cmdline"
  if ! ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_PROC_CMDLINE="$tmp_dir/cmdline" \
      ENGINEOS_RUNTIME_CMD="$fake_bin/eos-runtime" \
      "$runtime_start" >/dev/null 2>&1; then
    die "reliability test expected runtime kernel disable to succeed"
  fi
  grep -F 'runtime autostart disabled by kernel command line' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime kernel disable was not logged"
  grep -F 'recovery logs: eos-logs runtime --last 200' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime kernel disable log did not include runtime logs hint"

  mkdir -p "$tmp_dir/run"
  cat >"$tmp_dir/run/shell-state.json" <<'JSON'
{
  "schema": "engineos-shell-state-v0",
  "active_slot": "cube",
  "bootstrap": "launchpad",
  "slots": {
    "cube": {"mapped": true, "visible": true}
  }
}
JSON

  rm -f "$fake_bin/eos-runtime"
  HOME="$tmp_dir/home" \
    XDG_CONFIG_HOME="$tmp_dir/home/.config" \
    GOCACHE="$tmp_dir/go-build-cache" \
    GOMODCACHE="$tmp_dir/go-mod-cache" \
    GOTELEMETRY=off \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_CRASH_BUNDLE_DIR="$bundle_dir" \
    ENGINEOS_DRM_SYSFS="$drm_sysfs" \
    PATH="$fake_bin:$PATH" \
    "$SCRIPT_DIR/crash_bundle.sh" --runtime >/dev/null

  [[ -f "$bundle_dir/metadata.txt" ]] || die "crash bundle missing metadata"
  [[ -f "$bundle_dir/doctor.txt" ]] || die "crash bundle missing doctor output"
  [[ -f "$bundle_dir/outputs.txt" ]] || die "crash bundle missing output state"
  [[ -f "$bundle_dir/app-status.json" ]] || die "crash bundle missing app status"
  [[ -f "$bundle_dir/app-manifest-validate.txt" ]] || die "crash bundle missing app manifest validation"
  [[ -f "$bundle_dir/state/shell-state.json" ]] || die "crash bundle missing shell state"
  [[ -f "$bundle_dir/config/apps.toml" ]] || die "crash bundle missing app manifest config"
  [[ -f "$bundle_dir/network-summary.txt" ]] || die "crash bundle missing network summary"
  [[ -f "$bundle_dir/network/ip-address.txt" ]] || die "crash bundle missing ip address output"
  [[ -f "$bundle_dir/network/ip-route.txt" ]] || die "crash bundle missing ip route output"
  [[ -f "$bundle_dir/network/resolvectl-status.txt" ]] || die "crash bundle missing resolvectl output"
  [[ -f "$bundle_dir/network/nmcli-device.txt" ]] || die "crash bundle missing nmcli device output"
  [[ -f "$bundle_dir/assets-quake.txt" ]] || die "crash bundle missing asset check"
  [[ -f "$bundle_dir/assets-quake-explain.txt" ]] || die "crash bundle missing asset explanation"
  [[ -f "$bundle_dir/logs/shell.log" ]] || die "crash bundle missing shell log"
  [[ -f "$bundle_dir/logs/engine.log" ]] || die "crash bundle missing engine log"
  [[ -f "$bundle_dir/logs/runtime-start.log" ]] || die "crash bundle missing runtime log"
  grep -F 'mode=runtime' "$bundle_dir/metadata.txt" >/dev/null ||
    die "crash bundle metadata did not record runtime mode"
  grep -F 'doctor.sh --vm' "$bundle_dir/doctor.txt" >/dev/null ||
    die "runtime crash bundle did not run VM doctor mode"
  grep -F '"slots": {' "$bundle_dir/app-status.json" >/dev/null ||
    die "crash bundle app status did not include slot state"
  grep -F '"schema": "engineos-shell-state-v0"' "$bundle_dir/state/shell-state.json" >/dev/null ||
    die "crash bundle shell state did not preserve schema"
  grep -F 'App manifest validation summary: 0 failure(s)' "$bundle_dir/app-manifest-validate.txt" >/dev/null ||
    die "crash bundle app manifest validation did not pass"
  grep -F '[apps.cube]' "$bundle_dir/config/apps.toml" >/dev/null ||
    die "crash bundle app manifest did not include cube section"
  grep -F 'Quake assets missing' "$bundle_dir/assets-quake.txt" >/dev/null ||
    die "crash bundle asset check did not capture missing asset failure"
  grep -F 'connector: card0-HDMI-A-1 status=connected' "$bundle_dir/outputs.txt" >/dev/null ||
    die "crash bundle did not capture connected DRM output"
  grep -F 'shell failure marker' "$bundle_dir/logs/shell.log" >/dev/null ||
    die "crash bundle did not copy shell log contents"
  grep -F 'EngineOS shell failed rc=77' "$bundle_dir/logs/runtime-start.log" >/dev/null ||
    die "crash bundle did not copy runtime failure log"
  grep -F 'recovery bundle: eos-crash-bundle' "$bundle_dir/logs/runtime-start.log" >/dev/null ||
    die "crash bundle did not copy runtime recovery hint"
  grep -F 'default via 192.0.2.1 dev eth0 proto dhcp' "$bundle_dir/network-summary.txt" >/dev/null ||
    die "crash bundle network summary did not capture default route"
  grep -F 'eth0 ethernet connected EngineOS test' "$bundle_dir/network/nmcli-device.txt" >/dev/null ||
    die "crash bundle did not capture NetworkManager device state"
  grep -F 'DNS Servers: 192.0.2.53' "$bundle_dir/network/resolvectl-status.txt" >/dev/null ||
    die "crash bundle did not capture resolver state"

  printf 'reliability smoke test passed\n'
}

run_logs() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-logs-test-$$"
  local log_dir="$tmp_dir/logs"
  local out="$tmp_dir/out.txt"

  cleanup_logs() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_logs RETURN

  mkdir -p "$log_dir"
  printf 'shell old line\nshell newest line\n' >"$log_dir/shell.log"
  printf 'engine marker\n' >"$log_dir/engine.log"
  printf 'runtime marker\n' >"$log_dir/runtime-start.log"
  printf 'live setup marker\n' >"$log_dir/live-setup.log"
  printf 'doctor marker\n' >"$log_dir/doctor-firstboot.log"

  ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/eos-logs" shell --last 1 --files >"$out"
  grep -F 'shell newest line' "$out" >/dev/null ||
    die "logs shell did not include newest shell line"
  if grep -F 'shell old line' "$out" >/dev/null; then
    die "logs shell --last 1 included older shell line"
  fi

  ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/eos-logs" runtime --files >"$out"
  grep -F 'runtime marker' "$out" >/dev/null ||
    die "logs runtime did not include runtime-start log"

  ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/eos-logs" all --files >"$out"
  grep -F 'engine marker' "$out" >/dev/null ||
    die "logs all did not include engine log"
  grep -F 'doctor marker' "$out" >/dev/null ||
    die "logs all did not include doctor firstboot log"

  ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/eos-logs" boot --files >"$out"
  grep -F 'No file log target for boot; use --journal.' "$out" >/dev/null ||
    die "logs boot --files did not explain journal usage"

  if ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/eos-logs" nonsense >/dev/null 2>&1; then
    die "logs accepted an unknown target"
  fi

  printf 'logs smoke test passed\n'
}

run_artifacts() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-artifacts-$$"
  local out_dir="$tmp_dir/out"
  local export_dir="$tmp_dir/export"
  local iso="$out_dir/EngineOS-test-x86_64.iso"

  cleanup_artifacts() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_artifacts RETURN

  mkdir -p "$out_dir"
  printf 'fake iso payload\n' >"$iso"

  ENGINEOS_OUT_DIR="$out_dir" "$SCRIPT_DIR/artifacts.sh" checksum >/dev/null
  [[ -f "$iso.sha256" ]] || die "artifact checksum was not created"
  grep -F 'EngineOS-test-x86_64.iso' "$iso.sha256" >/dev/null ||
    die "artifact checksum does not reference ISO"

  ENGINEOS_OUT_DIR="$out_dir" "$SCRIPT_DIR/artifacts.sh" list >/dev/null
  ENGINEOS_OUT_DIR="$out_dir" "$SCRIPT_DIR/artifacts.sh" export "$export_dir" >/dev/null
  [[ -f "$export_dir/EngineOS-test-x86_64.iso" ]] || die "artifact export missing ISO"
  [[ -f "$export_dir/EngineOS-test-x86_64.iso.sha256" ]] || die "artifact export missing checksum"

  printf 'artifacts smoke test passed\n'
}

run_release() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-release-test-$$"
  local out_dir="$tmp_dir/out"
  local export_dir="$tmp_dir/export"
  local report="$tmp_dir/release.md"
  local dev_iso="$out_dir/EngineDevOS-test-x86_64.iso"
  local runtime_iso="$out_dir/EngineRuntimeOS-test-x86_64.iso"

  cleanup_release() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_release RETURN

  mkdir -p "$out_dir"
  printf 'fake dev iso payload\n' >"$dev_iso"
  printf 'fake runtime iso payload\n' >"$runtime_iso"

  "$SCRIPT_DIR/release.sh" checklist --dry-run --out-dir "$out_dir" --report "$report.dry-run" >/dev/null
  grep -F 'Expected EngineDev ISO' "$report.dry-run" >/dev/null ||
    die "release dry-run report missing EngineDev expectation"
  grep -F '`engineos-quakespasm`' "$report.dry-run" >/dev/null ||
    die "release dry-run report missing engineos-quakespasm package expectation"
  grep -F '`engineos-cube`' "$report.dry-run" >/dev/null ||
    die "release dry-run report missing engineos-cube package expectation"

  "$SCRIPT_DIR/release.sh" checklist --out-dir "$out_dir" --export-dir "$export_dir" --report "$report" >/dev/null
  [[ -f "$dev_iso.sha256" ]] || die "release checklist missing EngineDev checksum"
  [[ -f "$runtime_iso.sha256" ]] || die "release checklist missing EngineRuntime checksum"
  [[ -f "$export_dir/EngineDevOS-test-x86_64.iso" ]] || die "release export missing EngineDev ISO"
  [[ -f "$export_dir/EngineRuntimeOS-test-x86_64.iso" ]] || die "release export missing EngineRuntime ISO"
  grep -F 'Bare-metal AMD' "$report" >/dev/null ||
    die "release report missing bare-metal proof section"
  grep -F '/usr/bin/quakespasm' "$report" >/dev/null ||
    die "release report missing QuakeSpasm binary proof item"
  grep -F 'eos-outputs validate --single' "$report" >/dev/null ||
    die "release report missing output validation proof item"
  grep -F 'eos-proof launchpad --runtime' "$report" >/dev/null ||
    die "release report missing launchpad proof item"
  grep -F 'eos-app manifest validate' "$report" >/dev/null ||
    die "release report missing app manifest proof item"
  grep -F 'eos-terminal' "$report" >/dev/null ||
    die "release report missing terminal proof item"
  grep -F 'eos-crash-bundle --bare-metal' "$report" >/dev/null ||
    die "release report missing bare-metal crash bundle proof item"
  grep -F 'proof hardware-ready' "$report" >/dev/null ||
    die "release report missing hardware-ready proof item"

  printf 'release checklist smoke test passed\n'
}

run_terminal() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-terminal-test-$$"
  local fake_bin="$tmp_dir/bin"
  local log_dir="$tmp_dir/logs"
  local launched="$tmp_dir/launched.txt"
  local out="$tmp_dir/out.txt"

  cleanup_terminal() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_terminal RETURN

  mkdir -p "$fake_bin" "$log_dir"
  cat >"$fake_bin/alacritty" <<'FAKE'
#!/usr/bin/env bash
printf 'alacritty %s\n' "$*" >"$ENGINEOS_FAKE_TERMINAL_LAUNCHED"
FAKE
  cat >"$fake_bin/foot" <<'FAKE'
#!/usr/bin/env bash
printf 'foot %s\n' "$*" >"$ENGINEOS_FAKE_TERMINAL_LAUNCHED"
FAKE
  chmod +x "$fake_bin/alacritty"
  chmod +x "$fake_bin/foot"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_TERMINAL_CANDIDATES="missing-terminal alacritty" \
    "$SCRIPT_DIR/terminal_launcher.sh" --print-command >"$out"
  grep -Fx 'alacritty' "$out" >/dev/null ||
    die "terminal launcher did not select fallback terminal"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_FAKE_TERMINAL_LAUNCHED="$launched" \
    ENGINEOS_TERMINAL_CANDIDATES="missing-terminal alacritty" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/terminal_launcher.sh" -- --class EngineOS >/dev/null
  grep -F 'alacritty --class EngineOS' "$launched" >/dev/null ||
    die "terminal launcher did not exec selected terminal with args"
  grep -F 'launch command=alacritty display=engineos-test-wayland' "$log_dir/terminal.log" >/dev/null ||
    die "terminal launcher did not log selected terminal launch"
  grep -F 'owner=engineos-shell' "$log_dir/terminal.log" >/dev/null ||
    die "terminal launcher did not log EngineOS shell ownership"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_FAKE_TERMINAL_LAUNCHED="$launched" \
    ENGINEOS_TERMINAL_CANDIDATES="foot" \
    ENGINEOS_TERMINAL_APP_ID="engineos-terminal" \
    ENGINEOS_TERMINAL_TITLE="EngineOS Terminal" \
    ENGINEOS_TERMINAL_SESSION_CMD="tmux new -A -s engineos" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/terminal_launcher.sh" >/dev/null
  grep -F 'foot --override csd.preferred=none --override csd.size=0 --app-id engineos-terminal --title EngineOS Terminal -- zsh -lc exec tmux new -A -s engineos' "$launched" >/dev/null ||
    die "terminal launcher did not disable foot titlebar decorations"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_FAKE_TERMINAL_LAUNCHED="$launched" \
    ENGINEOS_TERMINAL_CANDIDATES="alacritty" \
    ENGINEOS_TERMINAL_APP_ID="engineos-terminal-secondary" \
    ENGINEOS_TERMINAL_TITLE="EngineOS Side" \
    ENGINEOS_TERMINAL_SESSION_CMD="tmux new -A -s engineos" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/terminal_launcher.sh" >/dev/null
  grep -F 'alacritty --class engineos-terminal-secondary --title EngineOS Side -- zsh -lc exec tmux new -A -s engineos' "$launched" >/dev/null ||
    die "terminal launcher did not start named tmux session through zsh"
  grep -F 'session command=tmux new -A -s engineos' "$log_dir/terminal.log" >/dev/null ||
    die "terminal launcher did not log tmux session command"

  if env -u WAYLAND_DISPLAY -u DISPLAY \
      PATH="$fake_bin:$PATH" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_TERMINAL_CANDIDATES="alacritty" \
      "$SCRIPT_DIR/terminal_launcher.sh" >/dev/null 2>&1; then
    die "terminal launcher should require WAYLAND_DISPLAY by default"
  fi
  grep -F 'reason=missing-wayland-display' "$log_dir/terminal.log" >/dev/null ||
    die "terminal launcher did not log missing Wayland display"

  ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_TERMINAL_CANDIDATES="missing-terminal" \
    "$SCRIPT_DIR/terminal_launcher.sh" --dry-run >"$out"
  grep -F 'command: missing' "$out" >/dev/null ||
    die "terminal dry-run did not report missing candidates"

  if ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_TERMINAL_CANDIDATES="missing-terminal" \
      "$SCRIPT_DIR/terminal_launcher.sh" >/dev/null 2>&1; then
    die "terminal launcher should fail when no terminal candidate exists"
  fi
  grep -F 'reason=no-terminal-candidate' "$log_dir/terminal.log" >/dev/null ||
    die "terminal launcher did not log missing terminal failure"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_TERMINAL_CANDIDATES="alacritty" \
    "$ROOT/tools/engineos/eos-terminal" --dry-run >"$out"
  grep -F 'command: alacritty' "$out" >/dev/null ||
    die "eos-terminal did not route to terminal launcher"

  printf 'terminal launcher smoke test passed\n'
}

run_vm() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-vm-test-$$"
  local dev_iso="$tmp_dir/out/EngineDevOS-test-x86_64.iso"
  local runtime_iso="$tmp_dir/out/EngineRuntimeOS-test-x86_64.iso"
  local out="$tmp_dir/vm.txt"

  cleanup_vm() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_vm RETURN

  mkdir -p "$tmp_dir/out"
  printf 'fake dev iso payload\n' >"$dev_iso"
  printf 'fake runtime iso payload\n' >"$runtime_iso"

  "$VM_DIR/vm.sh" boot enginedev --dry-run --out-dir "$tmp_dir/out" --memory 1024 --cpus 1 --display none --no-kvm >"$out"
  grep -F 'eos-proof booted-iso --vm' "$out" >/dev/null ||
    die "enginedev VM dry-run did not print VM proof command"
  grep -F 'display:  none' "$out" >/dev/null ||
    die "enginedev VM dry-run did not print selected display backend"
  if grep -F 'OVMF_CODE' "$out" >/dev/null; then
    die "enginedev VM dry-run used pflash OVMF_CODE as a -bios image"
  fi
  env -u WAYLAND_DISPLAY -u DISPLAY "$VM_DIR/vm.sh" boot enginedev --dry-run --iso "$dev_iso" --memory 1024 --cpus 1 --no-kvm >"$out"
  grep -F 'display:  none' "$out" >/dev/null ||
    die "enginedev VM dry-run did not default to headless display without a graphical session"
  "$VM_DIR/vm.sh" boot enginedev --dry-run --iso "$dev_iso" --memory 1024 --cpus 1 --display none --background --no-kvm >"$out"
  grep -F -- '-daemonize' "$out" >/dev/null ||
    die "enginedev VM background dry-run did not daemonize QEMU"
  grep -F 'qemu-enginedev-serial.log' "$out" >/dev/null ||
    die "enginedev VM background dry-run did not print serial log path"
  "$VM_DIR/vm.sh" boot enginedev --dry-run --iso "$dev_iso" --memory 1024 --cpus 1 --display none --no-kvm >"$out"
  grep -F 'profile:  enginedev' "$out" >/dev/null ||
    die "enginedev VM dry-run did not print selected profile"

  "$VM_DIR/vm.sh" boot engineruntime --dry-run --out-dir "$tmp_dir/out" --memory 1024 --cpus 1 --display none --no-kvm >"$out"
  grep -F 'eos-proof booted-iso --runtime' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not print runtime proof command"
  "$VM_DIR/vm.sh" boot engineruntime --dry-run --iso "$runtime_iso" --memory 1024 --cpus 1 --display none --no-kvm >"$out"
  grep -F 'profile:  engineruntime' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not print selected profile"
  "$VM_DIR/vm.sh" boot engineruntime --dry-run --iso "$runtime_iso" --memory 1024 --cpus 1 --display none --audio hda --no-kvm >"$out"
  grep -F 'audio:    hda' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not print selected audio mode"
  grep -F -- '-device ich9-intel-hda' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not include HDA controller"
  grep -F -- '-device hda-duplex\,audiodev=audio0' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not include HDA duplex codec"
  env -u WAYLAND_DISPLAY -u DISPLAY "$VM_DIR/vm.sh" boot engineruntime --dry-run --iso "$runtime_iso" --memory 1024 --cpus 1 --gl --no-kvm >"$out"
  grep -F 'display:  egl-headless,gl=on' "$out" >/dev/null ||
    die "engineruntime GL VM dry-run did not select egl-headless GL display"
  grep -F 'gl:       true' "$out" >/dev/null ||
    die "engineruntime GL VM dry-run did not print GL mode"
  grep -F -- '-vga none' "$out" >/dev/null ||
    die "engineruntime GL VM dry-run did not disable default VGA"
  grep -F -- '-device virtio-vga-gl' "$out" >/dev/null ||
    die "engineruntime GL VM dry-run did not include virtio-vga-gl"
  if "$VM_DIR/vm.sh" boot engineruntime --dry-run --iso "$runtime_iso" --memory 1024 --cpus 1 --display none --gl --no-kvm >"$out" 2>&1; then
    die "engineruntime GL VM dry-run accepted display none"
  fi
  grep -F -- '--gl requires a GL-capable display backend' "$out" >/dev/null ||
    die "engineruntime GL VM dry-run did not explain display none rejection"

  printf 'vm boot dry-run test passed\n'
}

run_usb() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-usb-test-$$"
  local iso="$tmp_dir/out/EngineRuntimeOS-test-x86_64.iso"

  cleanup_usb() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_usb RETURN

  mkdir -p "$tmp_dir/out"
  printf 'fake iso payload\n' >"$iso"

  "$BARE_METAL_DIR/usb.sh" list >/dev/null
  "$BARE_METAL_DIR/usb.sh" write --dry-run --iso "$iso" --device /dev/engineos-test-usb >/dev/null
  "$BARE_METAL_DIR/usb.sh" write --dry-run --profile engineruntime --out-dir "$tmp_dir/out" --device /dev/engineos-test-usb >/dev/null

  if "$BARE_METAL_DIR/usb.sh" write --iso "$iso" --device /dev/engineos-test-usb >/dev/null 2>&1; then
    die "usb write should require explicit destructive acknowledgement outside dry-run"
  fi

  printf 'usb write dry-run test passed\n'
}

run_secure_boot() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-secure-boot-test-$$"
  local key_dir="$tmp_dir/keys"
  local iso="$tmp_dir/out/EngineRuntimeOS-test-x86_64.iso"
  local out="$tmp_dir/out.txt"

  cleanup_secure_boot() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_secure_boot RETURN

  mkdir -p "$(dirname "$iso")"
  printf 'fake iso payload\n' >"$iso"

  "$BARE_METAL_DIR/secure_boot.sh" keys create --out-dir "$key_dir" --dry-run >"$out"
  grep -F 'EngineOS Secure Boot key creation' "$out" >/dev/null ||
    die "secure-boot key dry-run missing header"
  grep -F 'openssl req' "$out" >/dev/null ||
    die "secure-boot key dry-run missing openssl command"

  mkdir -p "$key_dir"
  printf 'fake key\n' >"$key_dir/db.key"
  printf 'fake cert\n' >"$key_dir/db.crt"
  printf 'fake der cert\n' >"$key_dir/db.cer"

  "$BARE_METAL_DIR/secure_boot.sh" keys status --key-dir "$key_dir" >"$out"
  grep -F 'status: ready' "$out" >/dev/null ||
    die "secure-boot key status did not report ready"

  "$BARE_METAL_DIR/secure_boot.sh" sign-iso --iso "$iso" --key-dir "$key_dir" --dry-run >"$out"
  grep -F '/EFI/BOOT/BOOTx64.EFI' "$out" >/dev/null ||
    die "secure-boot sign dry-run did not mention bootloader signing"
  grep -F '/arch/boot/x86_64/vmlinuz-linux' "$out" >/dev/null ||
    die "secure-boot sign dry-run did not mention kernel signing"

  "$BARE_METAL_DIR/secure_boot.sh" enroll-handoff --key-dir "$key_dir" >"$out"
  grep -F 'Do not clear existing Microsoft keys' "$out" >/dev/null ||
    die "secure-boot enrollment handoff does not protect Windows keys"

  printf 'secure-boot dry-run test passed\n'
}

run_installation_guide() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-installation-guide-test-$$"
  local out="$tmp_dir/guide.txt"

  cleanup_installation_guide() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_installation_guide RETURN

  mkdir -p "$tmp_dir"
  "$SCRIPT_DIR/installation_guide.sh" >"$out"
  grep -F 'EngineDev installation guide' "$out" >/dev/null ||
    die "installation guide missing header"
  grep -F 'codex --version' "$out" >/dev/null ||
    die "installation guide does not tell the live user to validate Codex"
  grep -F -- '--repo-token-file /run/engineos-secrets/tango-os-readonly.token' "$out" >/dev/null ||
    die "installation guide missing private repo token path"
  grep -F 'prompts are disabled' "$out" >/dev/null ||
    die "installation guide does not explain the git prompt failure"
  grep -F 'sudo genfstab -U /mnt/engineos' "$out" >/dev/null ||
    die "installation guide missing fstab recovery command"

  "$ROOT/tools/engineos/eos-install" guide >"$out"
  grep -F 'EngineDev installation guide' "$out" >/dev/null ||
    die "eos-install guide did not dispatch to guide script"

  grep -F '/usr/local/bin/engineos-live-codex-setup' "$ROOT/archiso/enginedev/profiledef.sh" >/dev/null ||
    die "EngineDev profile does not mark live Codex setup executable"
  grep -F 'systemctl enable engineos-live-codex-setup.service' "$ROOT/archiso/enginedev/airootfs/root/customize_airootfs.sh" >/dev/null ||
    die "EngineDev profile does not enable live Codex setup"
  grep -F 'console=ttyS0' "$ROOT/archiso/enginedev/efiboot/loader/entries/01-enginedev-linux.conf" >/dev/null &&
    die "EngineDev boot entry still redirects bare-metal boot to serial"

  printf 'installation guide smoke test passed\n'
}

run_install() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-install-test-$$"
  local fake_bin="$tmp_dir/bin"
  local seed="$tmp_dir/seed"
  local package_cache="$tmp_dir/pkg-cache"
  local pacman_conf="$tmp_dir/pacman.conf"
  local target="$tmp_dir/target"
  local token_file="$tmp_dir/repo-token"
  local out="$tmp_dir/install.txt"
  local log="$tmp_dir/commands.log"

  cleanup_install() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_install RETURN

  mkdir -p "$fake_bin" "$seed/.git" "$seed/tools" "$package_cache"
  printf 'seed\n' >"$seed/README.md"
  while IFS= read -r package; do
    printf 'fake package\n' >"$package_cache/$package-1-1-any.pkg.tar.zst"
  done < <(engineos_install_packages)
  cat >"$pacman_conf" <<'EOF_PACMAN'
[options]
Architecture = auto
SigLevel = Required DatabaseOptional

[core]
Include = /etc/pacman.d/mirrorlist
EOF_PACMAN
  "$BARE_METAL_DIR/install_dev.sh" dev \
    --dry-run \
    --target "$target" \
    --no-home-ntfs >"$tmp_dir/install-default.txt"
  grep -F 'device:   /dev/disk/by-id/ata-WDC_WD10EZEX-00WN4A0_WD-WCC6Y1ZP5EAX' "$tmp_dir/install-default.txt" >/dev/null ||
    die "install dry-run did not default to the configured F: disk by-id path"
  grep -F 'home:     installed root filesystem' "$tmp_dir/install-default.txt" >/dev/null ||
    die "install dry-run did not honor --no-home-ntfs"

  "$BARE_METAL_DIR/install_dev.sh" dev \
    --dry-run \
    --device /dev/engineos-test-disk \
    --target "$target" \
    --repo-url https://example.invalid/tang-os.git \
    --branch main >"$out"

  grep -F 'EngineOS EngineDev autoinstall plan' "$out" >/dev/null ||
    die "install dry-run missing plan header"
  grep -F 'device:   /dev/engineos-test-disk' "$out" >/dev/null ||
    die "install dry-run missing target device"
  grep -F 'home:     LABEL=Tango mounted at /home as NTFS' "$out" >/dev/null ||
    die "install dry-run missing default NTFS home mount"
  grep -F 'EngineDev /var, 128G, ext4 label ENGINEOS_VAR' "$out" >/dev/null ||
    die "install dry-run missing /var partition plan"
  grep -F 'persistent /srv workspace' "$out" >/dev/null ||
    die "install dry-run missing persistent /srv plan"
  grep -F 'cache:    /opt/engineos/install-cache/pkg' "$out" >/dev/null ||
    die "install dry-run missing ISO package cache plan"
  grep -F 'repo auth: none; clone runs non-interactively' "$out" >/dev/null ||
    die "install dry-run missing repo auth plan"
  grep -F 'env GIT_TERMINAL_PROMPT=0 git clone https://example.invalid/tang-os.git /srv/engineos' "$out" >/dev/null ||
    die "install dry-run missing official repo clone"
  grep -F 'setup_dev_environment.sh --payload /usr/share/engineos/post-install-payload --user dev' "$out" >/dev/null ||
    die "install dry-run missing post-install payload handoff"
  grep -F 'chown -R dev:dev /srv/engineos' "$out" >/dev/null ||
    die "install dry-run did not assign source workspace to dev"
  grep -F 'runuser -u dev -- env -u ENGINEOS_ROOT -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_LOG_DIR /srv/engineos/tools/engineos/eos-build repo' "$out" >/dev/null ||
    die "install dry-run did not build source repo as dev with cleared EngineOS wrapper env"
  grep -F 'proof booted-iso --bare-metal' "$out" >/dev/null ||
    die "install dry-run missing bare-metal handoff proof"

  printf 'fake-token\n' >"$token_file"
  "$BARE_METAL_DIR/install_dev.sh" dev \
    --dry-run \
    --device /dev/engineos-test-disk \
    --target "$target" \
    --repo-url https://example.invalid/tang-os.git \
    --repo-token-file "$token_file" \
    --branch main >"$out"
  grep -F 'repo auth: token file supplied (redacted)' "$out" >/dev/null ||
    die "install dry-run did not redact repo token file"
  grep -F 'GIT_ASKPASS=/usr/local/bin/engineos-git-askpass GIT_TERMINAL_PROMPT=0 git clone https://example.invalid/tang-os.git /srv/engineos' "$out" >/dev/null ||
    die "install dry-run missing private repo askpass clone"
  if grep -F 'fake-token' "$out" >/dev/null || grep -F "$token_file" "$out" >/dev/null; then
    die "install dry-run leaked repo token file details"
  fi

  cat >"$fake_bin/sudo" <<'FAKE'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
exec "$@"
FAKE
  cat >"$fake_bin/lsblk" <<'FAKE'
#!/usr/bin/env bash
printf 'lsblk %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
exit 0
FAKE
  cat >"$fake_bin/findmnt" <<'FAKE'
#!/usr/bin/env bash
printf 'findmnt %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
exit 1
FAKE
  cat >"$fake_bin/wipefs" <<'FAKE'
#!/usr/bin/env bash
printf 'wipefs %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
FAKE
  cat >"$fake_bin/sfdisk" <<'FAKE'
#!/usr/bin/env bash
printf 'sfdisk %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
cat >/dev/null
FAKE
  cat >"$fake_bin/udevadm" <<'FAKE'
#!/usr/bin/env bash
printf 'udevadm %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
FAKE
  cat >"$fake_bin/mkfs.fat" <<'FAKE'
#!/usr/bin/env bash
printf 'mkfs.fat %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
FAKE
  cat >"$fake_bin/mkfs.ext4" <<'FAKE'
#!/usr/bin/env bash
printf 'mkfs.ext4 %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
FAKE
  cat >"$fake_bin/mount" <<'FAKE'
#!/usr/bin/env bash
printf 'mount %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
mkdir -p "${@: -1}"
FAKE
  cat >"$fake_bin/findfs" <<'FAKE'
#!/usr/bin/env bash
printf 'findfs %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
printf '/dev/fake-home\n'
FAKE
  cat >"$fake_bin/pacstrap" <<'FAKE'
#!/usr/bin/env bash
printf 'pacstrap %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
target=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      target="$1"
      break
      ;;
  esac
done
[[ -n "$target" ]] || exit 2
mkdir -p "$target/etc/pacman.d" "$target/etc/sudoers.d" "$target/boot" "$target/var" "$target/srv" "$target/home" "$target/usr/share/engineos/post-install-payload/scripts"
touch "$target/usr/share/engineos/post-install-payload/scripts/setup_dev_environment.sh"
chmod +x "$target/usr/share/engineos/post-install-payload/scripts/setup_dev_environment.sh"
printf '[options]\n' >"$target/etc/pacman.conf"
FAKE
  cat >"$fake_bin/genfstab" <<'FAKE'
#!/usr/bin/env bash
printf 'genfstab %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
printf 'UUID=fake-root / ext4 rw 0 1\n'
FAKE
  cat >"$fake_bin/arch-chroot" <<'FAKE'
#!/usr/bin/env bash
printf 'arch-chroot %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
cat >/dev/null || true
FAKE
  cat >"$fake_bin/blkid" <<'FAKE'
#!/usr/bin/env bash
printf 'blkid %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
printf '00000000-0000-4000-8000-000000000000\n'
FAKE
  cat >"$fake_bin/git" <<'FAKE'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
FAKE
  chmod +x "$fake_bin"/*

  PATH="$fake_bin:$PATH" \
    ENGINEOS_INSTALL_ALLOW_FAKE_DEVICE=true \
    ENGINEOS_INSTALL_PACMAN_CONF="$pacman_conf" \
    ENGINEOS_FAKE_INSTALL_LOG="$log" \
    "$BARE_METAL_DIR/install_dev.sh" dev \
      --device /dev/engineos-test-disk \
      --target "$target" \
      --repo-url https://example.invalid/tang-os.git \
      --repo-seed "$seed" \
      --package-cache "$package_cache" \
      --branch main \
      --skip-codex \
      --yes-i-understand-this-wipes-device >"$tmp_dir/install-real.txt"

  grep -F 'EngineDev autoinstall completed' "$tmp_dir/install-real.txt" >/dev/null ||
    die "install executor did not complete with fake commands"
  grep -F 'wipefs --all /dev/engineos-test-disk' "$log" >/dev/null ||
    die "install executor did not wipe target"
  grep -F 'sfdisk /dev/engineos-test-disk' "$log" >/dev/null ||
    die "install executor did not partition target"
  grep -F 'mkfs.ext4 -F -L ENGINEOS_VAR /dev/engineos-test-disk3' "$log" >/dev/null ||
    die "install executor did not format /var partition"
  grep -F 'mount /dev/engineos-test-disk3 '"$target"'/var' "$log" >/dev/null ||
    die "install executor did not mount /var partition"
  grep -F 'mount -t ntfs-3g -o uid=1000,gid=1000,umask=022,fmask=133,dmask=022,windows_names,nofail,x-systemd.device-timeout=10s LABEL=Tango '"$target"'/home' "$log" >/dev/null ||
    die "install executor did not mount default NTFS home volume"
  grep -F 'arch-chroot '"$target"' useradd -M -d /home/dev -G wheel,input,audio,video,render,docker -s /usr/bin/zsh dev' "$log" >/dev/null ||
    die "install executor did not create NTFS-home user without useradd -m"
  grep -F 'pacstrap -c -C ' "$log" >/dev/null ||
    die "install executor did not run pacstrap with cached host package mode"
  grep -F "CacheDir = $package_cache" /tmp/engineos-install-pacman-*.conf >/dev/null ||
    die "install executor did not generate cached pacman config"
  grep -F 'cp -a '"$seed"'/. '"$target"'/tmp/tang-os-seed/' "$log" >/dev/null ||
    die "install executor did not stage seed repo"
  grep -F 'arch-chroot '"$target"' env GIT_TERMINAL_PROMPT=0 git clone file:///tmp/tang-os-seed /srv/engineos' "$log" >/dev/null ||
    die "install executor did not clone seed repo in target"
  grep -F 'arch-chroot '"$target"' chown -R dev:dev /srv/engineos' "$log" >/dev/null ||
    die "install executor did not assign source workspace to dev"
  grep -F 'arch-chroot '"$target"' runuser -u dev -- env -u ENGINEOS_ROOT -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_LOG_DIR /srv/engineos/tools/engineos/eos-build repo' "$log" >/dev/null ||
    die "install executor did not build source repo as dev with cleared EngineOS wrapper env"
  grep -F 'arch-chroot '"$target"' /usr/share/engineos/post-install-payload/scripts/setup_dev_environment.sh' "$log" >/dev/null ||
    die "install executor did not run post-install payload"
  grep -F 'Server = file:///srv/engineos/repo/$arch' "$target/etc/pacman.conf" >/dev/null ||
    die "install executor did not configure installed local pacman repo"
  [[ -f "$target/srv/ENGINEOS_INSTALL_HANDOFF.txt" ]] ||
    die "install executor did not write handoff marker"

  rm -rf "$target" "$log"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_INSTALL_ALLOW_FAKE_DEVICE=true \
    ENGINEOS_INSTALL_PACMAN_CONF="$pacman_conf" \
    ENGINEOS_FAKE_INSTALL_LOG="$log" \
    "$BARE_METAL_DIR/install_dev.sh" dev \
      --device /dev/engineos-test-disk \
      --target "$target" \
      --repo-url https://example.invalid/tang-os.git \
      --repo-token-file "$token_file" \
      --package-cache "$package_cache" \
      --branch main \
      --skip-codex \
      --yes-i-understand-this-wipes-device >"$tmp_dir/install-private-repo.txt"

  grep -F 'repo auth: token file supplied (redacted)' "$tmp_dir/install-private-repo.txt" >/dev/null ||
    die "install executor did not report redacted repo token auth"
  grep -F 'arch-chroot '"$target"' env GIT_ASKPASS=/usr/local/bin/engineos-git-askpass GIT_TERMINAL_PROMPT=0 git clone https://example.invalid/tang-os.git /srv/engineos' "$log" >/dev/null ||
    die "install executor did not clone private repo with askpass"
  if grep -F 'fake-token' "$tmp_dir/install-private-repo.txt" >/dev/null || grep -F 'fake-token' "$log" >/dev/null; then
    die "install executor leaked repo token"
  fi
  [[ ! -e "$target/root/.engineos/repo-token" ]] ||
    die "install executor left repo token in target"
  [[ ! -e "$target/usr/local/bin/engineos-git-askpass" ]] ||
    die "install executor left git askpass helper in target"

  rm -rf "$target" "$log" "$package_cache"
  mkdir -p "$package_cache"
  printf 'fake package\n' >"$package_cache/base-1-1-any.pkg.tar.zst"
  if PATH="$fake_bin:$PATH" \
    ENGINEOS_INSTALL_ALLOW_FAKE_DEVICE=true \
    ENGINEOS_INSTALL_PACMAN_CONF="$pacman_conf" \
    ENGINEOS_FAKE_INSTALL_LOG="$log" \
    "$BARE_METAL_DIR/install_dev.sh" dev \
      --device /dev/engineos-test-disk \
      --target "$target" \
      --repo-url https://example.invalid/tang-os.git \
      --repo-seed "$seed" \
      --package-cache "$package_cache" \
      --branch main \
      --skip-codex \
      --yes-i-understand-this-wipes-device >"$tmp_dir/install-partial-cache.txt" 2>"$tmp_dir/install-partial-cache.err"; then
    die "install executor should reject an incomplete package cache"
  fi
  grep -F 'EngineDev install package cache is incomplete' "$tmp_dir/install-partial-cache.err" >/dev/null ||
    die "install executor did not explain incomplete package cache"

  if "$BARE_METAL_DIR/install_dev.sh" dev --device /dev/engineos-test-disk >/dev/null 2>&1; then
    die "install real mode should require explicit wipe acknowledgement"
  fi

  printf 'EngineDev installer dry-run test passed\n'
}

run_proof() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-proof-test-$$"

  cleanup_proof() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_proof RETURN

  mkdir -p "$tmp_dir/logs"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" release-candidate --dry-run --out-dir "$tmp_dir/out" >"$tmp_dir/release-candidate.txt"
  grep -F 'build EngineRuntime ISO dry-run' "$tmp_dir/release-candidate.txt" >/dev/null ||
    die "release-candidate proof did not include EngineRuntime ISO dry-run"
  grep -F 'release checklist' "$tmp_dir/release-candidate.txt" >/dev/null ||
    die "release-candidate proof did not run release checklist"
  grep -F 'Release-candidate proof preview completed; no release-candidate proof was executed.' "$tmp_dir/release-candidate.txt" >/dev/null ||
    die "release-candidate dry-run did not clearly identify itself as a preview"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" hardware-ready --dry-run --profile engineruntime --out-dir "$tmp_dir/out" --device /dev/engineos-test-usb >"$tmp_dir/hardware-ready.txt"
  grep -F 'eos-usb write --profile engineruntime' "$tmp_dir/hardware-ready.txt" >/dev/null ||
    die "hardware-ready proof did not include runtime USB write dry-run"
  grep -F 'eos-proof booted-iso --bare-metal' "$tmp_dir/hardware-ready.txt" >/dev/null ||
    die "hardware-ready proof did not point to bare-metal proof"
  grep -F 'Hardware-ready proof preview completed; no hardware-ready proof was executed.' "$tmp_dir/hardware-ready.txt" >/dev/null ||
    die "hardware-ready dry-run did not clearly identify itself as a preview"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" booted-iso --vm --dry-run >"$tmp_dir/booted-vm.txt"
  grep -F 'Quake smoke dry-run' "$tmp_dir/booted-vm.txt" >/dev/null ||
    die "booted VM proof did not include Quake smoke step"
  grep -F 'eos-logs engine --last 200' "$tmp_dir/booted-vm.txt" >/dev/null ||
    die "booted VM proof did not include engine log step"
  grep -F 'eos-crash-bundle --vm' "$tmp_dir/booted-vm.txt" >/dev/null ||
    die "booted VM proof did not include VM crash bundle mode"
  grep -F 'Booted-ISO proof preview completed; no booted-ISO proof was executed.' "$tmp_dir/booted-vm.txt" >/dev/null ||
    die "booted VM dry-run did not clearly identify itself as a preview"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" booted-iso --runtime --dry-run >"$tmp_dir/booted-runtime.txt"
  grep -F 'runtime reliability dry-run' "$tmp_dir/booted-runtime.txt" >/dev/null ||
    die "booted runtime proof did not include runtime reliability step"
  grep -F 'eos-logs runtime --last 200' "$tmp_dir/booted-runtime.txt" >/dev/null ||
    die "booted runtime proof did not include runtime log step"
  grep -F 'eos-crash-bundle --runtime' "$tmp_dir/booted-runtime.txt" >/dev/null ||
    die "booted runtime proof did not include runtime crash bundle mode"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" booted-iso --bare-metal --dry-run >"$tmp_dir/booted-bare-metal.txt"
  grep -F 'eos-outputs validate --single' "$tmp_dir/booted-bare-metal.txt" >/dev/null ||
    die "booted bare-metal proof did not include explicit output validation"
  grep -F 'eos-crash-bundle --bare-metal' "$tmp_dir/booted-bare-metal.txt" >/dev/null ||
    die "booted bare-metal proof did not include bare-metal crash bundle mode"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" shell-launch --runtime --dry-run >"$tmp_dir/shell-launch.txt"
  grep -F 'Shell-launch proof preview completed; no shell-launch proof was executed.' "$tmp_dir/shell-launch.txt" >/dev/null ||
    die "shell-launch dry-run did not clearly identify itself as a preview"
  grep -F 'grep -E' "$tmp_dir/shell-launch.txt" | grep -F 'renderer diagnostics' >/dev/null ||
    die "shell-launch proof did not check renderer diagnostics"
  grep -F 'app launch app=terminal owner=engineos-shell' "$tmp_dir/shell-launch.txt" >/dev/null ||
    die "shell-launch proof did not check terminal launch ownership"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" shell-launch --bare-metal --dry-run >"$tmp_dir/shell-launch-bare-metal.txt"
  grep -F 'bare-metal shell renderer dry-run' "$tmp_dir/shell-launch-bare-metal.txt" >/dev/null ||
    die "bare-metal shell-launch proof did not include shell renderer gate"
  grep -F 'wlr_renderer=(gles2|vulkan)' "$tmp_dir/shell-launch-bare-metal.txt" >/dev/null ||
    die "bare-metal shell-launch proof did not require GL-capable renderer evidence"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" launchpad --runtime --dry-run >"$tmp_dir/launchpad.txt"
  grep -F 'Launchpad proof preview completed; no launchpad proof was executed.' "$tmp_dir/launchpad.txt" >/dev/null ||
    die "launchpad dry-run did not clearly identify itself as a preview"
  grep -F 'eos-app status --json' "$tmp_dir/launchpad.txt" >/dev/null ||
    die "launchpad proof did not check structured app status"
  grep -F 'eos-app manifest validate' "$tmp_dir/launchpad.txt" >/dev/null ||
    die "launchpad proof did not validate app manifest"
  grep -F 'app=(terminal|cube|quake)' "$tmp_dir/launchpad.txt" >/dev/null ||
    die "launchpad proof did not check all app ownership markers"
  grep -F "grep -F 'view mapped role=engine'" "$tmp_dir/launchpad.txt" >/dev/null ||
    die "launchpad proof did not require a mapped engine slot"

  local launchpad_logs="$tmp_dir/launchpad-logs"
  local launchpad_state="$tmp_dir/launchpad-state"
  mkdir -p "$launchpad_logs" "$launchpad_state"
  {
    printf '[2026-01-01T00:00:00Z] engineos-shell mode=tty backend=drm,libinput wayland_display=wayland-1\n'
    printf '[2026-01-01T00:00:01Z] bootstrap mode=launchpad\n'
    printf '[2026-01-01T00:00:02Z] launchpad active slot=cube mode=terminal capture=none reason=bootstrap-launchpad\n'
    printf '[2026-01-01T00:00:03Z] launch action label=bootstrap-terminal role=terminal pid=100 command=eos-app launch terminal\n'
    printf '[2026-01-01T00:00:04Z] launch action label=bootstrap-cube role=cube pid=101 command=eos-app launch cube\n'
    printf '[2026-01-01T00:00:05Z] launch action label=bootstrap-engine role=engine pid=102 command=eos-app launch quake\n'
    printf '[2026-01-01T00:00:06Z] view mapped role=cube title=engineos-cube app_id=engineos-cube mapped_total=1\n'
    printf '[2026-01-01T00:00:07Z] launch action exit label=bootstrap-engine role=engine pid=102 status=exited code=1 mapped=false command=eos-app launch quake\n'
    printf '[2026-01-01T00:00:08Z] launchpad slot unavailable role=engine reason=process-exited-before-map status=exited code=1\n'
  } >"$launchpad_logs/shell.log"
  cat >"$launchpad_state/shell-state.json" <<'JSON'
{
  "schema": "engineos-shell-state-v0",
  "pid": 999,
  "mode": "tty",
  "wayland_display": "wayland-1",
  "bootstrap": "launchpad",
  "active_slot": "cube",
  "pending_slot": "unknown",
  "input": {"mode": "terminal", "capture": false},
  "counts": {"outputs": 1, "keyboards": 1, "pointers": 1, "views": 1},
  "last_reason": "launch-exit",
  "slots": {
    "terminal": {"mapped": false, "visible": false, "title": "", "app_id": ""},
    "cube": {"mapped": true, "visible": true, "title": "engineos-cube", "app_id": "engineos-cube"},
    "engine": {"mapped": false, "visible": false, "title": "", "app_id": ""}
  },
  "launches": []
}
JSON
  {
    printf '[2026-01-01T00:00:03Z] app launch app=terminal owner=engineos-shell display=wayland-1\n'
    printf '[2026-01-01T00:00:04Z] app launch app=cube owner=engineos-shell display=wayland-1 sdl=wayland args= log=%s/cube.log\n' "$launchpad_logs"
    printf '[2026-01-01T00:00:05Z] app launch app=quake owner=engineos-shell display=wayland-1 sdl=wayland args=\n'
  } >"$launchpad_logs/app.log"
  {
    printf 'EngineOS cube app\n'
    printf 'gl_renderer=llvmpipe test renderer\n'
    printf 'frames=8\n'
    printf 'result=smoke-ok\n'
  } >"$launchpad_logs/cube.log"
  printf 'Quake assets missing: id1/pak0.pak was not found.\n' >"$launchpad_logs/engine.log"
  if ENGINEOS_LOG_DIR="$launchpad_logs" ENGINEOS_STATE_DIR="$launchpad_state" \
      "$PROOF_DIR/proof.sh" launchpad --runtime >"$tmp_dir/launchpad-real-missing-engine.txt" 2>&1; then
    die "launchpad proof accepted missing Quake assets as engine proof"
  fi
  grep -F 'Quake asset/runtime guidance is not launchpad proof' "$tmp_dir/launchpad-real-missing-engine.txt" >/dev/null ||
    die "launchpad proof failure did not explain missing engine mapping"

  printf '[2026-01-01T00:00:09Z] view mapped role=engine title=QuakeSpasm app_id=quakespasm mapped_total=2\n' >>"$launchpad_logs/shell.log"
  printf 'QuakeSpasm basedir=%s\n' "$tmp_dir/home/.local/share/engineos/quake" >"$launchpad_logs/engine.log"
  ENGINEOS_LOG_DIR="$launchpad_logs" ENGINEOS_STATE_DIR="$launchpad_state" \
    "$PROOF_DIR/proof.sh" launchpad --runtime >"$tmp_dir/launchpad-real.txt"
  grep -F 'Launchpad proof runner completed' "$tmp_dir/launchpad-real.txt" >/dev/null ||
    die "launchpad proof did not pass with mapped engine fixture logs"

  if ! find "$tmp_dir/logs" -maxdepth 1 -type f -name 'proof-booted-iso-*.log' -size +0c -print -quit | grep -q .; then
    die "proof dry-run did not create non-empty proof logs"
  fi
  if ! find "$tmp_dir/logs" -maxdepth 1 -type f -name 'proof-release-candidate-*.log' -size +0c -print -quit | grep -q .; then
    die "release-candidate proof dry-run did not create non-empty proof log"
  fi
  if ! find "$tmp_dir/logs" -maxdepth 1 -type f -name 'proof-hardware-ready-*.log' -size +0c -print -quit | grep -q .; then
    die "hardware-ready proof dry-run did not create non-empty proof log"
  fi

  printf 'proof dry-run test passed\n'
}

run_builder() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-builder-test-$$"
  local out="$tmp_dir/builder.txt"

  cleanup_builder() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_builder RETURN
  mkdir -p "$tmp_dir"

  if is_arch_linux && [[ "$ROOT" == "/srv/engineos" ]]; then
    "$SCRIPT_DIR/validate_builder.sh" >"$out"
    grep -F 'Builder validation summary: 0 failure(s)' "$out" >/dev/null ||
      die "real builder validation did not report clean summary"
  else
    if "$SCRIPT_DIR/validate_builder.sh" >"$out" 2>&1; then
      die "builder validation passed outside the real builder context"
    fi
    grep -E 'real builder validation must run on Arch Linux|repo root must be /srv/engineos' "$out" >/dev/null ||
      die "builder validation failure did not explain the real builder requirement"
  fi

  printf 'builder validation contract test passed\n'
}

run_builder_handoff() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-builder-handoff-$$"
  local out="$tmp_dir/handoff.txt"

  cleanup_builder_handoff() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_builder_handoff RETURN

  mkdir -p "$tmp_dir"

  "$BUILDER_DIR/builder_handoff.sh" --dry-run --host dev@192.0.2.10 --dest /srv/engineos >"$out"
  grep -F 'dev@192.0.2.10' "$out" >/dev/null ||
    die "builder handoff dry-run did not include ssh target"
  grep -F -- '-o BatchMode=yes' "$out" >/dev/null ||
    die "builder handoff dry-run did not use non-interactive ssh"
  grep -F -- '-o ConnectTimeout=' "$out" >/dev/null ||
    die "builder handoff dry-run did not use ssh connect timeout"
  grep -F 'rsync -a' "$out" >/dev/null ||
    die "builder handoff dry-run did not include rsync"
  grep -F -- '-e ssh\' "$out" >/dev/null ||
    die "builder handoff dry-run did not route rsync through configured ssh"
  grep -F '/srv/engineos' "$out" >/dev/null ||
    die "builder handoff dry-run did not target /srv/engineos"
  grep -F './tools/engineos/eos-builder\ bootstrap' "$out" >/dev/null ||
    die "builder handoff dry-run did not include bootstrap"
  grep -F './tools/engineos/eos-validate\ builder' "$out" >/dev/null ||
    die "builder handoff dry-run did not include builder validation"
  grep -F './tools/engineos/eos-build\ repo' "$out" >/dev/null ||
    die "builder handoff dry-run did not include real repo build"
  grep -F './tools/engineos/eos-validate\ repo' "$out" >/dev/null ||
    die "builder handoff dry-run did not include repo validation"
  if grep -F -- '--delete' "$out" >/dev/null; then
    die "builder handoff dry-run should not delete remote files by default"
  fi

  "$BUILDER_DIR/builder_handoff.sh" --dry-run --host dev@192.0.2.10 --skip-bootstrap >"$out"
  if grep -F './tools/engineos/eos-builder\ bootstrap' "$out" >/dev/null; then
    die "builder handoff --skip-bootstrap still included bootstrap"
  fi

  "$BUILDER_DIR/builder_handoff.sh" --dry-run --host dev@192.0.2.10 --run-proof >"$out"
  grep -F './tools/engineos/eos-builder\ bootstrap' "$out" >/dev/null ||
    die "builder handoff --run-proof did not include bootstrap"
  grep -F './tools/engineos/eos-proof\ build-lab' "$out" >/dev/null ||
    die "builder handoff --run-proof did not include build-lab proof"
  grep -F 'Next real command: ./tools/engineos/eos-builder handoff --host dev@192.0.2.10 --run-proof' "$out" >/dev/null ||
    die "builder handoff --run-proof did not preserve the real command hint"

  if "$BUILDER_DIR/builder_handoff.sh" --host dev@192.0.2.10 --dest relative/path >/dev/null 2>&1; then
    die "builder handoff accepted a relative destination"
  fi

  printf 'builder handoff dry-run test passed\n'
}

run_builder_doctor() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-builder-doctor-$$"
  local out="$tmp_dir/doctor-proof.txt"

  cleanup_builder_doctor() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_builder_doctor RETURN

  mkdir -p "$tmp_dir"
  "$BUILDER_DIR/builder_doctor_proof.sh" --dry-run --host dev@192.0.2.10 --guest-port 2223 >"$out"
  grep -F 'dev@192.0.2.10' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include builder ssh target"
  grep -F './tools/engineos/eos-proof build-lab' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include build-lab proof"
  grep -F -- '-p\ 2223' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include guest ssh port"
  grep -F 'dev@127.0.0.1' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include guest ssh target"
  grep -F 'eos-doctor\\\ --vm' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include VM doctor command"

  "$BUILDER_DIR/builder_doctor_proof.sh" --dry-run --host dev@192.0.2.10 --skip-build >"$out"
  if grep -F 'run builder build proof' "$out" >/dev/null; then
    die "builder doctor proof --skip-build still ran build-lab proof"
  fi
  grep -F 'eos-doctor\\\ --vm' "$out" >/dev/null ||
    die "builder doctor proof --skip-build did not include VM doctor command"

  printf 'builder doctor proof dry-run test passed\n'
}

run_post_first_deploy() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-post-first-deploy-test-$$"
  local out="$tmp_dir/post-first-deploy.txt"
  local payload_dir
  payload_dir="$(post_install_payload_dir)"

  cleanup_post_first_deploy() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_post_first_deploy RETURN

  mkdir -p "$tmp_dir"
  "$OS_DEV_DIR/post_first_deploy.sh" --dry-run --host dev@192.0.2.55 --port 2225 >"$out"
  grep -F 'EngineOS post-first-deploy dry-run' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing header"
  grep -F 'dev@192.0.2.55' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing guest host"
  grep -F -- '-P 2225' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing scp port"
  grep -F "$payload_dir" "$out" >/dev/null ||
    die "post-first-deploy dry-run missing payload path"
  grep -F 'setup_dev_environment.sh' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing remote setup script"
  grep -F -- '--payload' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing setup payload argument"
  grep -F 'Next real command: eos-deploy first --host dev@192.0.2.55 --port 2225' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing real command hint"

  "$OS_DEV_DIR/post_first_deploy.sh" --dry-run --host dev@192.0.2.55 --skip-codex --skip-docker --skip-pacman --skip-dev-repos >"$out"
  grep -F -- '--skip-codex' "$out" >/dev/null ||
    die "post-first-deploy dry-run did not preserve --skip-codex"
  grep -F -- '--skip-docker' "$out" >/dev/null ||
    die "post-first-deploy dry-run did not preserve --skip-docker"
  grep -F -- '--skip-pacman' "$out" >/dev/null ||
    die "post-first-deploy dry-run did not preserve --skip-pacman"
  grep -F -- '--skip-dev-repos' "$out" >/dev/null ||
    die "post-first-deploy dry-run did not preserve --skip-dev-repos"

  [[ -f "$payload_dir/assets/tmux.conf" ]] ||
    die "post-first-deploy payload missing tmux config"
  grep -F 'set -g mouse on' "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not enable mouse support"
  grep -F "@engineos-plugins" "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not declare packaged plugins"
  grep -F "/usr/share/tmux/plugins/tmux-sensible/sensible.tmux" "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not source packaged plugins"
  grep -F 'set -g status-style bg=colour235,fg=colour250' "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not set the EngineOS color status style"
  grep -F '#{pane_current_path}' "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config status line does not show pane path"
  grep -F 'engineos-tmux-pane-sync --all' "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not wire EngineOS pane sync hooks"
  grep -F 'after-select-pane' "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not sync after pane selection"
  if grep -F 'eos-app pane sync --all >/dev/null 2>&1 || true' "$payload_dir/assets/tmux.conf" >/dev/null ||
      grep -F 'eos-app pane sync >/dev/null 2>&1 || true' "$payload_dir/assets/tmux.conf" >/dev/null; then
    die "post-first-deploy tmux config silently ignores pane sync failures"
  fi
  [[ -x "$payload_dir/scripts/engineos-tmux-pane-sync" ]] ||
    die "post-first-deploy payload missing tmux pane sync helper"
  grep -F 'tmux-warning' "$payload_dir/scripts/engineos-tmux-pane-sync" >/dev/null ||
    die "post-first-deploy tmux pane sync helper does not log failures"
  [[ -f "$payload_dir/assets/zshrc" ]] ||
    die "post-first-deploy payload missing zsh config"
  [[ -f "$payload_dir/assets/zprofile" ]] ||
    die "post-first-deploy payload missing zprofile config"
  grep -F '/usr/share/oh-my-zsh' "$payload_dir/assets/zshrc" >/dev/null ||
    die "post-first-deploy zsh config does not use packaged oh-my-zsh"
  grep -F 'zsh-autosuggestions.zsh' "$payload_dir/assets/zshrc" >/dev/null ||
    die "post-first-deploy zsh config does not source packaged plugins"
  grep -F 'tmux new-session -A -s engineos' "$payload_dir/assets/zprofile" >/dev/null ||
    die "post-first-deploy zprofile does not auto-attach tmux"
  grep -F 'tools/scripts/update_check.sh" --init' "$payload_dir/assets/zprofile" >/dev/null ||
    die "post-first-deploy zprofile does not run source update init check"
  grep -F 'eos-update check --init' "$payload_dir/assets/zprofile" >/dev/null ||
    die "post-first-deploy zprofile does not run update init check"
  grep -F 'engineos_profile_run()' "$payload_dir/assets/zprofile" >/dev/null ||
    die "post-first-deploy zprofile does not expose login hook failures"
  grep -F 'profile-warning' "$payload_dir/assets/zprofile" >/dev/null ||
    die "post-first-deploy zprofile does not log login hook warnings"
  if grep -F 'eos-observe prompt-login --shell zsh || true' "$payload_dir/assets/zprofile" >/dev/null ||
      grep -F 'update_check.sh" --init || true' "$payload_dir/assets/zprofile" >/dev/null ||
      grep -F 'eos-update check --init || true' "$payload_dir/assets/zprofile" >/dev/null; then
    die "post-first-deploy zprofile silently ignores login hook failures"
  fi
  [[ -f "$payload_dir/assets/docker/daemon.json" ]] ||
    die "post-first-deploy payload missing Docker config"
  [[ -x "$payload_dir/scripts/setup_dev_environment.sh" ]] ||
    die "post-first-deploy payload setup script is not executable"
  [[ -x "$payload_dir/scripts/engineos-dev-shell-start" ]] ||
    die "post-first-deploy payload dev shell start script is not executable"
  grep -F 'engineos-tmux-pane-sync' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not install tmux pane sync helper"
  [[ -f "$payload_dir/assets/systemd/engineos-dev-shell.service" ]] ||
    die "post-first-deploy payload missing dev shell service"
  grep -F 'ENGINEOS_TERMINAL_REQUIRE_WAYLAND=true' "$payload_dir/assets/systemd/engineos-dev-shell.service" >/dev/null ||
    die "post-first-deploy dev shell service does not require Wayland terminal ownership"
  grep -F 'ENGINEOS_TERMINAL_SESSION_CMD=tmux new -A -s engineos' "$payload_dir/assets/systemd/engineos-dev-shell.service" >/dev/null ||
    die "post-first-deploy dev shell service does not launch tmux"
  grep -F 'engineos-shell' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not request engineos-shell"
  grep -F 'engineos-tools' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not request engineos-tools"
  grep -F 'engineos-cube' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not request engineos-cube"
  if grep -F 'best_effort()' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
      grep -F 'WARN best-effort failed' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null; then
    die "post-first-deploy setup still contains best-effort service handling"
  fi
  if grep -F 'systemctl enable docker.service >/dev/null 2>&1 || true' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
      grep -F 'systemctl enable engineos-observe-exporter.service >/dev/null 2>&1 || true' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
      grep -F 'systemctl restart engineos-observe-exporter.service >/dev/null 2>&1 || true' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
      grep -F 'systemctl daemon-reload || true' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
      grep -F 'chsh -s /usr/bin/zsh "$TARGET_USER" || true' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null; then
    die "post-first-deploy setup silently ignores service or shell setup failures"
  fi
  grep -F 'codex-extractor' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not fetch codex-extractor"
  grep -F 'session-extrator' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not fetch session-extrator"
  grep -F 'opencode-autonomy' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not fetch opencode-autonomy"
  grep -F 'agent' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not fetch agent"
  grep -F 'skills' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not fetch skills"
  grep -F 'Tango-Rocker' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not fetch from Tango-Rocker"

  printf 'post-first-deploy dry-run test passed\n'
}

run_update_check() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-update-check-test-$$"
  local repo="$tmp_dir/tango-os"
  local out="$tmp_dir/update-check.txt"

  cleanup_update_check() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_update_check RETURN

  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email engineos@example.invalid
  git -C "$repo" config user.name "EngineOS Test"
  printf 'one\n' >"$repo/VERSION"
  git -C "$repo" add VERSION
  git -C "$repo" commit -q -m 'v0.1.0'
  git -C "$repo" tag v0.1.0
  printf 'two\n' >"$repo/VERSION"
  git -C "$repo" commit -q -am 'v0.2.0'
  git -C "$repo" tag v0.2.0
  git -C "$repo" checkout -q v0.1.0

  ENGINEOS_TANGO_OS_ROOT="$repo" \
    ENGINEOS_ENGINE_OS_ROOT="$tmp_dir/missing-engine" \
    "$SCRIPT_DIR/update_check.sh" --no-fetch --dry-run --yes --skip-post-install >"$out"

  grep -F 'tango-os: newer semver tag available: v0.1.0 -> v0.2.0' "$out" >/dev/null ||
    die "update check did not report semver tag upgrade"
  grep -F 'dry-run: git -C '"$repo"' checkout v0.2.0' "$out" >/dev/null ||
    die "update check dry-run did not print planned checkout"
  grep -F 'engine-os: skipped; Git checkout not found' "$out" >/dev/null ||
    die "update check did not skip missing engine-os checkout"

  if ENGINEOS_ENGINE_OS_ROOT="$tmp_dir/missing-engine" \
      "$SCRIPT_DIR/update_check.sh" --component engine-os --no-fetch --dry-run --yes --skip-post-install >"$out" 2>&1; then
    die "update check accepted an explicitly requested missing engine-os checkout"
  fi
  grep -F 'engine-os checkout not found at' "$out" >/dev/null ||
    die "update check did not fail explicit missing engine-os checkout clearly"

  if ENGINEOS_TANGO_OS_ROOT="$repo" \
      "$SCRIPT_DIR/update_check.sh" --component tango-os --dry-run --yes --skip-post-install >"$out" 2>&1; then
    die "update check succeeded when tag fetch failed"
  fi
  grep -F 'could not fetch tags from origin' "$out" >/dev/null ||
    die "update check fetch failure was not explicit"

  ENGINEOS_TANGO_OS_ROOT="$repo" \
    "$SCRIPT_DIR/update_check.sh" --component tango-os --no-fetch --yes --skip-post-install >"$out"
  [[ "$(git -C "$repo" describe --tags --exact-match)" == "v0.2.0" ]] ||
    die "update check did not checkout accepted semver tag"

  printf 'update check test passed\n'
}

run_bootstrap() {
  "$BUILDER_DIR/bootstrap_builder.sh" --dry-run >/dev/null
  "$BUILDER_DIR/bootstrap_builder.sh" --print-packages | grep -Fx 'archiso' >/dev/null ||
    die "builder bootstrap package list missing archiso"
  "$BUILDER_DIR/bootstrap_builder.sh" --print-packages | grep -Fx 'wlroots0.19' >/dev/null ||
    die "builder bootstrap package list missing wlroots0.19"
  printf 'builder bootstrap dry-run test passed\n'
}

run_repo() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-repo-test-$$"
  local out="$tmp_dir/build-repo.txt"

  cleanup_repo() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_repo RETURN

  mkdir -p "$tmp_dir"
  "$SCRIPT_DIR/build_repo.sh" --dry-run >"$out"
  grep -F 'makepkg: rebuild existing package artifacts with -f' "$out" >/dev/null ||
    die "repo dry-run did not document forced package rebuilds"
  grep -F 'repo-add: after each package' "$out" >/dev/null ||
    die "repo dry-run did not document incremental repo-add"
  grep -F 'latest package artifacts' "$out" >/dev/null ||
    die "repo dry-run did not document latest-artifact selection"
  grep -F 'local deps: already-built engineos-* runtime dependencies' "$out" >/dev/null ||
    die "repo dry-run did not document local dependency handling"
  grep -F 'package logs:' "$out" >/dev/null ||
    die "repo dry-run did not document package log directory"
  grep -F 'package sources:' "$out" >/dev/null ||
    die "repo dry-run did not document package source directory"
  grep -F 'package build dir:' "$out" >/dev/null ||
    die "repo dry-run did not document package build directory"
  grep -F 'packages/engineos-quakespasm' "$out" >/dev/null ||
    die "repo dry-run did not include engineos-quakespasm"

  "$SCRIPT_DIR/validate_repo.sh" --dry-run >"$out"
  grep -F 'engineos-quakespasm-*.pkg.tar.*' "$out" >/dev/null ||
    die "repo validation dry-run did not expect engineos-quakespasm artifact"
  if [[ "$ROOT" != "/srv/engineos" ]]; then
    if "$SCRIPT_DIR/validate_repo.sh" >"$out" 2>&1; then
      die "repo validation passed outside /srv/engineos"
    fi
    grep -F 'repo directory mismatch: archiso expects /srv/engineos/repo' "$out" >/dev/null ||
      die "repo validation did not explain /srv/engineos requirement"
  fi
  printf 'repo validation smoke test passed\n'
}

run_boot() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-boot-test-$$"
  local fake_bin="$tmp_dir/bin"
  local tool_bin="$tmp_dir/tool-bin"
  local log_dir="$tmp_dir/logs"
  local runtime_conf="$tmp_dir/runtime.conf"
  local apps_manifest="$tmp_dir/apps.toml"
  local drm_sysfs="$tmp_dir/sys/class/drm"
  local dri_dir="$tmp_dir/dev/dri"
  local out="$tmp_dir/out.txt"
  local doctor_log="$tmp_dir/doctor-args.txt"

  cleanup_boot() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_boot RETURN

  mkdir -p "$fake_bin" "$tool_bin" "$log_dir" "$drm_sysfs/card0-HDMI-A-1" "$dri_dir"
  for tool in bash date dirname grep; do
    ln -s "$(command -v "$tool")" "$tool_bin/$tool"
  done
  {
    printf 'ENGINEOS_SHELL_BOOTSTRAP=launchpad\n'
    printf 'ENGINEOS_CUBE_CMD="eos-app launch cube"\n'
    printf 'ENGINEOS_ENGINE_CMD="eos-app launch quake"\n'
    printf 'ENGINEOS_RUNTIME_RECOVERY_TTY=tty2\n'
    printf 'ENGINEOS_TERMINAL_SESSION_CMD="tmux new -A -s engineos"\n'
  } >"$runtime_conf"
  cat >"$apps_manifest" <<'EOF_MANIFEST'
[apps.terminal]
slot = "terminal"
role = "terminal"
command = "eos-app launch terminal"
package = "foot"
app_ids = ["foot"]
log = "terminal.log"
input = "normal"

[apps.terminal-secondary]
slot = "terminal-secondary"
role = "terminal-secondary"
command = "eos-app launch terminal-secondary"
package = "foot"
app_ids = ["engineos-terminal-secondary"]
log = "terminal.log"
input = "normal"

[apps.cube]
slot = "cube"
role = "cube"
command = "eos-app launch cube"
smoke_command = "eos-app launch cube --smoke"
package = "engineos-cube"
app_ids = ["engineos-cube"]
log = "cube.log"
health = "gl-renderer-and-frames"
input = "normal"

[apps.quake]
slot = "engine"
role = "engine"
command = "eos-app launch quake"
smoke_command = "eos-app launch quake --smoke"
package = "engineos-quakespasm"
app_ids = ["quakespasm"]
log = "engine.log"
assets = "quake"
input = "game"
EOF_MANIFEST
  {
    printf '[2026-01-01T00:00:00Z] starting EngineOS shell mode=--tty recovery=tty2\n'
    printf '[2026-01-01T00:00:01Z] EngineOS shell failed rc=77; recovery TTY should remain available\n'
  } >"$log_dir/runtime-start.log"
  printf 'connected\n' >"$drm_sysfs/card0-HDMI-A-1/status"
  printf 'enabled\n' >"$drm_sysfs/card0-HDMI-A-1/enabled"
  printf '1920x1080\n' >"$drm_sysfs/card0-HDMI-A-1/modes"
  : >"$dri_dir/card0"
  : >"$dri_dir/renderD128"

  cat >"$fake_bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  is-enabled|is-active|status)
    exit 0
    ;;
  *)
    printf 'fake systemctl: %s\n' "$*" >&2
    exit 2
    ;;
esac
FAKE
  chmod +x "$fake_bin/systemctl"

  cat >"$fake_bin/pacman" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "-Q" ]]; then
  if [[ -n "${ENGINEOS_FAKE_MISSING_PACKAGE:-}" && "${2:-}" == "$ENGINEOS_FAKE_MISSING_PACKAGE" ]]; then
    exit 1
  fi
  exit 0
fi
printf 'fake pacman: %s\n' "$*" >&2
exit 2
FAKE
  chmod +x "$fake_bin/pacman"

  cat >"$fake_bin/eos-app" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "manifest" && "$2" == "validate" ]]; then
  printf 'EngineOS app manifest validation\n'
  printf '  manifest: %s\n' "${ENGINEOS_APPS_MANIFEST:-missing}"
  printf 'OK   cube.app_ids contains engineos-cube\n'
  printf 'App manifest validation summary: 0 failure(s)\n'
  exit 0
fi
printf 'fake eos-app %s\n' "$*"
FAKE
  chmod +x "$fake_bin/eos-app"

  cat >"$fake_bin/quakespasm" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  cat >"$fake_bin/engineos-cube" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  chmod +x "$fake_bin/quakespasm" "$fake_bin/engineos-cube"

  cat >"$fake_bin/engineos-recovery-help" <<'FAKE'
#!/usr/bin/env bash
printf 'eos-logs runtime --last 200\n'
printf 'eos-crash-bundle\n'
printf 'engineos.noautostart\n'
FAKE
  chmod +x "$fake_bin/engineos-recovery-help"
  cat >"$fake_bin/engineos-recovery-help-fail" <<'FAKE'
#!/usr/bin/env bash
printf 'eos-logs runtime --last 200\n'
printf 'eos-crash-bundle\n'
printf 'engineos.noautostart\n'
exit 8
FAKE
  chmod +x "$fake_bin/engineos-recovery-help-fail"

  cat >"$fake_bin/lspci" <<'FAKE'
#!/usr/bin/env bash
printf '03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi test GPU\n'
FAKE
  chmod +x "$fake_bin/lspci"

  cat >"$fake_bin/doctor-ok" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ENGINEOS_FAKE_DOCTOR_ARGS"
printf 'EngineOS doctor fixture\n'
printf 'OpenGL core profile renderer: AMD RADV\n'
FAKE
  chmod +x "$fake_bin/doctor-ok"
  cat >"$fake_bin/doctor-fail" <<'FAKE'
#!/usr/bin/env bash
printf 'doctor fixture failed\n' >&2
exit 9
FAKE
  chmod +x "$fake_bin/doctor-fail"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_RUNTIME_CONF="$runtime_conf" \
    ENGINEOS_APPS_MANIFEST="$apps_manifest" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
    ENGINEOS_FAKE_DOCTOR_ARGS="$doctor_log" \
    "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1
  grep -F "app manifest exists: $apps_manifest" "$out" >/dev/null ||
    die "runtime boot validation did not require app manifest"
  grep -F 'app manifest validates' "$out" >/dev/null ||
    die "runtime boot validation did not validate app manifest"
  grep -F 'runtime recovery TTY configured: tty2' "$out" >/dev/null ||
    die "runtime boot validation did not read runtime recovery TTY fixture"
  grep -F 'package installed: engineos-shell' "$out" >/dev/null ||
    die "runtime boot validation did not require engineos-shell"
  grep -F 'package installed: ttf-dejavu' "$out" >/dev/null ||
    die "runtime boot validation did not require terminal fonts"
  grep -F 'command available: quakespasm' "$out" >/dev/null ||
    die "runtime boot validation did not check quakespasm command"
  grep -F 'command available: engineos-cube' "$out" >/dev/null ||
    die "runtime boot validation did not check engineos-cube command"
  grep -F 'runtime shell bootstrap starts launchpad' "$out" >/dev/null ||
    die "runtime boot validation did not check launchpad bootstrap"
  grep -F 'runtime autostart log records startup decision' "$out" >/dev/null ||
    die "runtime boot validation did not check autostart startup log"
  grep -F 'runtime autostart log records outcome' "$out" >/dev/null ||
    die "runtime boot validation did not check autostart outcome log"
  grep -Fx -- '--vm' "$doctor_log" >/dev/null ||
    die "runtime boot validation did not call doctor in VM mode"

  if PATH="$fake_bin:$PATH" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$tmp_dir/missing-logs" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
      "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1; then
    die "runtime boot validation accepted missing EngineOS log directory"
  fi
  grep -F "$tmp_dir/missing-logs missing" "$out" >/dev/null ||
    die "runtime boot validation did not expose missing EngineOS log directory"

  if PATH="$fake_bin:$PATH" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
      ENGINEOS_FAKE_MISSING_PACKAGE="engineos-cube" \
      "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1; then
    die "runtime boot validation accepted missing required package"
  fi
  grep -F 'package missing: engineos-cube' "$out" >/dev/null ||
    die "runtime boot validation did not expose missing required package"

  mv "$fake_bin/engineos-cube" "$fake_bin/engineos-cube-ok"
  if PATH="$fake_bin:$tool_bin" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
      bash "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1; then
    die "runtime boot validation accepted missing package command"
  fi
  grep -F 'command unavailable: engineos-cube' "$out" >/dev/null ||
    die "runtime boot validation did not expose missing package command"
  mv "$fake_bin/engineos-cube-ok" "$fake_bin/engineos-cube"

  if PATH="$fake_bin:$PATH" \
      ENGINEOS_RUNTIME_CONF="$tmp_dir/missing-runtime.conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
      "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1; then
    die "runtime boot validation accepted missing runtime config"
  fi
  grep -F 'missing-runtime.conf missing' "$out" >/dev/null ||
    die "runtime boot validation did not expose missing runtime config"

  if PATH="$fake_bin:$PATH" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-fail" \
      ENGINEOS_VALIDATE_DOCTOR_OUT="$tmp_dir/runtime-doctor-fail.out" \
      "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1; then
    die "runtime boot validation accepted failing doctor"
  fi
  grep -F 'doctor failed' "$out" >/dev/null ||
    die "runtime boot validation did not expose failing doctor"

  mv "$fake_bin/engineos-recovery-help" "$fake_bin/engineos-recovery-help-ok"
  cp "$fake_bin/engineos-recovery-help-fail" "$fake_bin/engineos-recovery-help"
  chmod +x "$fake_bin/engineos-recovery-help"
  if PATH="$fake_bin:$PATH" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
      ENGINEOS_FAKE_DOCTOR_ARGS="$doctor_log" \
      "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1; then
    die "runtime boot validation accepted failing recovery help"
  fi
  grep -F 'recovery help command failed' "$out" >/dev/null ||
    die "runtime boot validation did not expose failing recovery help"
  mv "$fake_bin/engineos-recovery-help-ok" "$fake_bin/engineos-recovery-help"

  printf '[2026-01-01T00:00:00Z] starting EngineOS shell mode=--tty recovery=tty2\n' >"$log_dir/runtime-start.log"
  printf '[2026-01-01T00:00:00Z] renderer diagnostics backend=drm,libinput wlr_renderer=pixman\n' >"$log_dir/shell.log"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_RUNTIME_CONF="$runtime_conf" \
    ENGINEOS_APPS_MANIFEST="$apps_manifest" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
    ENGINEOS_FAKE_DOCTOR_ARGS="$doctor_log" \
    "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1
  grep -F 'runtime shell service active: engineos-runtime.service' "$out" >/dev/null ||
    die "runtime boot validation did not accept active runtime shell service"
  if grep -F 'runtime autostart appears to still be running' "$out" >/dev/null; then
    die "runtime boot validation warned for active runtime shell service"
  fi
  grep -F 'shell renderer log shows software rendering; acceptable only for VM smoke paths' "$out" >/dev/null ||
    die "runtime boot validation did not keep pixman shell evidence as a VM warning"

  : >"$doctor_log"
  printf '[2026-01-01T00:00:00Z] renderer diagnostics backend=drm,libinput wlr_renderer=gles2 EGL platform=gbm\n' >"$log_dir/shell.log"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_RUNTIME_CONF="$runtime_conf" \
    ENGINEOS_APPS_MANIFEST="$apps_manifest" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_DRI_DIR="$dri_dir" \
    ENGINEOS_DRM_SYSFS="$drm_sysfs" \
    ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
    ENGINEOS_FAKE_DOCTOR_ARGS="$doctor_log" \
    "$PROOF_DIR/validate_boot.sh" --bare-metal >"$out"
  grep -F "$dri_dir exists" "$out" >/dev/null ||
    die "bare-metal boot validation did not use DRI fixture"
  grep -F 'at least one connected DRM output' "$out" >/dev/null ||
    die "bare-metal boot validation did not validate connected DRM output"
  grep -F 'AMD display device visible to lspci' "$out" >/dev/null ||
    die "bare-metal boot validation did not verify AMD display fixture"
  grep -F 'shell renderer log exists' "$out" >/dev/null ||
    die "bare-metal boot validation did not check shell renderer log"
  grep -F 'bare-metal shell renderer has GL-capable evidence' "$out" >/dev/null ||
    die "bare-metal boot validation did not require GL-capable shell evidence"
  grep -Fx -- '--bare-metal' "$doctor_log" >/dev/null ||
    die "bare-metal boot validation did not call doctor in bare-metal mode"
  grep -F 'bare-metal doctor completed' "$out" >/dev/null ||
    die "bare-metal boot validation did not require doctor success"

  if PATH="$fake_bin:$PATH" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_DRI_DIR="$dri_dir" \
      ENGINEOS_DRM_SYSFS="$drm_sysfs" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-fail" \
      ENGINEOS_VALIDATE_DOCTOR_OUT="$tmp_dir/doctor-fail.out" \
      "$PROOF_DIR/validate_boot.sh" --bare-metal >"$out" 2>&1; then
    die "bare-metal boot validation accepted failing doctor"
  fi
  grep -F 'bare-metal doctor failed' "$out" >/dev/null ||
    die "bare-metal boot validation did not expose failing doctor"

  printf '[2026-01-01T00:00:00Z] renderer diagnostics backend=drm,libinput wlr_renderer=pixman\n' >"$log_dir/shell.log"
  if PATH="$fake_bin:$PATH" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_DRI_DIR="$dri_dir" \
      ENGINEOS_DRM_SYSFS="$drm_sysfs" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
      ENGINEOS_FAKE_DOCTOR_ARGS="$doctor_log" \
      "$PROOF_DIR/validate_boot.sh" --bare-metal >"$out" 2>&1; then
    die "bare-metal boot validation accepted pixman shell renderer evidence"
  fi
  grep -F 'shell renderer log shows software rendering' "$out" >/dev/null ||
    die "bare-metal boot validation did not reject pixman shell renderer evidence"

  printf 'boot validation fixture test passed\n'
}

run_engine() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-engine-test-$$"
  local fetch_out="$tmp_dir/fetch.txt"

  cleanup_engine() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_engine RETURN

  mkdir -p "$tmp_dir"
  QUAKESPASM_UPSTREAM_DIR="$tmp_dir/upstream" \
    "$ROOT/tools/engineos/eos-build" fetch engine quake --dry-run >"$fetch_out"
  grep -F 'QuakeSpasm fetch dry-run' "$fetch_out" >/dev/null ||
    die "engine fetch dry-run missing marker"
  grep -F 'fetch.sh --status' "$fetch_out" >/dev/null ||
    die "engine fetch dry-run did not point to status"

  QUAKESPASM_UPSTREAM_DIR="$tmp_dir/upstream" \
    "$ROOT/tools/engineos/eos-build" fetch engine quake --status >"$fetch_out"
  grep -F 'state:    missing' "$fetch_out" >/dev/null ||
    die "engine fetch status did not report missing checkout"
  mkdir -p "$tmp_dir/upstream"
  QUAKESPASM_UPSTREAM_DIR="$tmp_dir/upstream" \
    "$ROOT/tools/engineos/eos-build" fetch engine quake --status >"$fetch_out"
  grep -F 'state:    empty-directory' "$fetch_out" >/dev/null ||
    die "engine fetch status did not report empty checkout directory"

  "$SCRIPT_DIR/build_engine.sh" quake --dry-run >"$fetch_out"
  grep -F 'MP3LIB=mpg123' "$fetch_out" >/dev/null ||
    die "engine build dry-run did not select mpg123"
  grep -F 'VORBISLIB=vorbis' "$fetch_out" >/dev/null ||
    die "engine build dry-run did not select vorbis"

  if QUAKESPASM_UPSTREAM_DIR="$tmp_dir/upstream" \
      "$SCRIPT_DIR/validate_engine.sh" quake >"$fetch_out" 2>&1; then
    die "engine validation accepted missing QuakeSpasm upstream checkout"
  fi
  grep -F 'upstream directory exists but is not a git checkout' "$fetch_out" >/dev/null ||
    die "engine validation did not fail missing upstream checkout explicitly"

  "$SCRIPT_DIR/validate_engine.sh" quake >/dev/null
  printf 'engine validation smoke test passed\n'
}

run_shell() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-shell-test-$$"
  local fake_bin="$tmp_dir/bin"
  local out="$tmp_dir/out.txt"

  cleanup_shell() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_shell RETURN
  mkdir -p "$fake_bin"

  cat >"$fake_bin/pkg-config" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
  chmod +x "$fake_bin/pkg-config"
  if PATH="$fake_bin:$PATH" "$SCRIPT_DIR/validate_shell.sh" >"$out" 2>&1; then
    die "shell validation accepted missing wlroots pkg-config modules"
  fi
  grep -F 'wlroots pkg-config modules unavailable' "$out" >/dev/null ||
    die "shell validation did not fail missing wlroots modules explicitly"

  "$SCRIPT_DIR/validate_shell.sh" >/dev/null
  ENGINEOS_ROOT=/usr "$SCRIPT_DIR/validate_shell.sh" >/dev/null
  printf 'shell validation smoke test passed\n'
}

run_input() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-input-test-$$"
  local trace="$tmp_dir/input.json"
  local old_trace="$tmp_dir/old-input.json"

  cleanup_input() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_input RETURN

  mkdir -p "$tmp_dir"
  "$SCRIPT_DIR/input_trace.sh" record "$trace" >/dev/null
  "$SCRIPT_DIR/input_trace.sh" replay "$trace" >/dev/null

  grep -F '"type": "pointer", "event": "motion"' "$trace" >/dev/null ||
    die "input trace test missing pointer motion event"
  grep -F '"type": "pointer", "event": "button"' "$trace" >/dev/null ||
    die "input trace test missing pointer button event"
  grep -F '"type": "pointer", "event": "axis"' "$trace" >/dev/null ||
    die "input trace test missing pointer axis event"
  grep -F '"type": "pointer", "event": "frame"' "$trace" >/dev/null ||
    die "input trace test missing pointer frame event"
  grep -F '"capture": true' "$trace" >/dev/null ||
    die "input trace test missing captured pointer context"
  grep -F '"focus": "game"' "$trace" >/dev/null ||
    die "input trace test missing game focus pointer context"

  cat >"$old_trace" <<'JSON'
{
  "format": "engineos-input-trace-v0",
  "events": [
    {"type": "focus", "mode": "shell"},
    {"type": "focus", "mode": "terminal"},
    {"type": "focus", "mode": "game"},
    {"type": "capture", "mode": "game", "enabled": true},
    {"type": "capture", "mode": "game", "enabled": false},
    {"type": "emergency-release"}
  ]
}
JSON
  if "$SCRIPT_DIR/input_trace.sh" replay "$old_trace" >/dev/null 2>&1; then
    die "input replay accepted a trace without pointer events"
  fi

  printf 'input smoke test passed\n'
}

run_outputs() {
  local mode="${1:---single}"
  local tmp_dir="${TMPDIR:-/tmp}/engineos-outputs-test-$$"
  local sysfs="$tmp_dir/sys/class/drm"
  local out="$tmp_dir/outputs.txt"

  cleanup_outputs() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_outputs RETURN

  mkdir -p "$sysfs/card0-HDMI-A-1" "$sysfs/card0-DP-1" "$sysfs/card0-DP-2"
  printf 'connected\n' >"$sysfs/card0-HDMI-A-1/status"
  printf 'enabled\n' >"$sysfs/card0-HDMI-A-1/enabled"
  printf '1920x1080\n1280x720\n' >"$sysfs/card0-HDMI-A-1/modes"
  printf 'connected\n' >"$sysfs/card0-DP-1/status"
  printf 'enabled\n' >"$sysfs/card0-DP-1/enabled"
  printf '2560x1440\n1920x1080\n' >"$sysfs/card0-DP-1/modes"
  printf 'disconnected\n' >"$sysfs/card0-DP-2/status"
  printf 'disabled\n' >"$sysfs/card0-DP-2/enabled"
  : >"$sysfs/card0-DP-2/modes"

  case "$mode" in
    --single)
      "$SCRIPT_DIR/outputs.sh" validate --single --sysfs "$sysfs" >"$out"
      grep -F 'connector: card0-HDMI-A-1 status=connected' "$out" >/dev/null ||
        die "outputs single test did not list connected HDMI"
      grep -F 'connector: card0-DP-2 status=disconnected enabled=disabled preferred_mode=none' "$out" >/dev/null ||
        die "outputs single test did not report empty mode files as none"
      grep -F 'Output validation passed for --single' "$out" >/dev/null ||
        die "outputs single test did not validate"
      ;;
    --dual-static)
      "$SCRIPT_DIR/outputs.sh" validate --dual-static --sysfs "$sysfs" >"$out"
      grep -F 'connector: card0-DP-1 status=connected' "$out" >/dev/null ||
        die "outputs dual test did not list connected DP"
      grep -F 'Output validation passed for --dual-static' "$out" >/dev/null ||
        die "outputs dual test did not validate"
      ;;
    *)
      die "outputs test expects --single or --dual-static"
      ;;
  esac

  printf 'outputs smoke %s passed\n' "$mode"
}

run_render() {
  local mode="${1:---smoke}"
  local tmp_dir="${TMPDIR:-/tmp}/engineos-render-test-$$"
  local captured=""
  local fallback=""
  local failed_capture=""
  [[ "$mode" == "--smoke" ]] || die "render test currently supports only --smoke"

  cleanup_render() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_render RETURN

  mkdir -p "$tmp_dir/bin" "$tmp_dir/captures"
  cat >"$tmp_dir/bin/grim" <<'FAKE'
#!/usr/bin/env bash
printf 'fake png payload\n' >"$1"
FAKE
  chmod +x "$tmp_dir/bin/grim"

  captured="$(PATH="$tmp_dir/bin:$PATH" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    ENGINEOS_CAPTURE_DIR="$tmp_dir/captures" \
    "$SCRIPT_DIR/capture_frame.sh" --target shell)"

  [[ -f "$captured" ]] || die "render capture did not create image artifact"
  [[ "$captured" == *.png ]] || die "render capture did not return a png artifact"
  grep -F 'result=image' "${captured%.png}.txt" >/dev/null ||
    die "render capture metadata did not record image result"
  grep -F 'tool=grim' "${captured%.png}.txt" >/dev/null ||
    die "render capture metadata did not record grim tool"

  fallback="$(ENGINEOS_CAPTURE_DIR="$tmp_dir/captures" \
    ENGINEOS_CAPTURE_TOOL=metadata \
    "$SCRIPT_DIR/capture_frame.sh" --target shell)"
  [[ -f "$fallback" ]] || die "render fallback did not create metadata artifact"
  grep -F 'result=metadata' "$fallback" >/dev/null ||
    die "render fallback metadata did not record metadata result"

  cat >"$tmp_dir/bin/grim" <<'FAKE'
#!/usr/bin/env bash
exit 12
FAKE
  chmod +x "$tmp_dir/bin/grim"
  if PATH="$tmp_dir/bin:$PATH" \
      WAYLAND_DISPLAY="engineos-test-wayland" \
      ENGINEOS_CAPTURE_DIR="$tmp_dir/captures" \
      "$SCRIPT_DIR/capture_frame.sh" --target shell >"$tmp_dir/failed-capture.out" 2>&1; then
    die "render capture auto mode succeeded when grim failed"
  fi
  failed_capture="$(sed -n 's/^frame capture failed; metadata: //p' "$tmp_dir/failed-capture.out" | tail -n 1)"
  [[ -f "$failed_capture" ]] || die "render capture failure did not create metadata artifact"
  grep -F 'result=failed' "$failed_capture" >/dev/null ||
    die "render capture failure metadata did not record failed result"

  printf 'render smoke test passed\n'
}

case "$SCOPE" in
  smoke)
    run_smoke
    ;;
  all)
    run_all
    ;;
  agent)
    run_agent
    ;;
  agent-hygiene)
    run_agent_hygiene
    ;;
  agent-dispatcher)
    run_agent_dispatcher
    ;;
  observability)
    run_observability
    ;;
  agent-route)
    run_agent_route
    ;;
  compositor)
    run_compositor "$@"
    ;;
  shell-actions)
    run_shell_actions
    ;;
  engine-runner-env)
    run_engine_runner_env
    ;;
  image-preview)
    run_image_preview
    ;;
  app)
    run_app
    ;;
  assets)
    run_assets
    ;;
  reliability)
    run_reliability
    ;;
  logs)
    run_logs
    ;;
  artifacts)
    run_artifacts
    ;;
  release)
    run_release
    ;;
  terminal)
    run_terminal
    ;;
  vm)
    run_vm
    ;;
  usb)
    run_usb
    ;;
  secure-boot)
    run_secure_boot
    ;;
  update-check)
    run_update_check
    ;;
  installation-guide)
    run_installation_guide
    ;;
  install)
    run_install
    ;;
  proof)
    run_proof
    ;;
  installed-preflight)
    run_installed_preflight
    ;;
  ci)
    run_ci
    ;;
  builder-handoff)
    run_builder_handoff
    ;;
  builder-doctor)
    run_builder_doctor
    ;;
  post-first-deploy)
    run_post_first_deploy
    ;;
  builder)
    run_builder
    ;;
  bootstrap)
    run_bootstrap
    ;;
  repo)
    run_repo
    ;;
  boot)
    run_boot
    ;;
  engine)
    run_engine
    ;;
  shell)
    run_shell
    ;;
  input)
    run_input
    ;;
  outputs)
    run_outputs "$@"
    ;;
  render)
    run_render "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown test scope: $SCOPE"
    ;;
esac
