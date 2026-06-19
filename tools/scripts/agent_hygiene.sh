#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
CHECK_ROOT="${ENGINEOS_AGENT_HYGIENE_ROOT:-$ROOT}"
COMMAND="check"
JSON=false
FIX_PLAN=false
ENQUEUE=false

ISSUE_CODES=()
ISSUE_MESSAGES=()

usage() {
  cat <<'HELP'
Usage:
  agent_hygiene.sh check [--json] [--fix-plan] [--enqueue]

Validate EngineOS agent-pack hygiene without editing files. --enqueue writes a
Cleaner task to the repo-local agent queue only when drift is detected.
HELP
}

die() {
  printf 'eos-agent hygiene: %s\n' "$*" >&2
  exit 1
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

add_issue() {
  local code="$1"
  local message="$2"
  ISSUE_CODES+=("$code")
  ISSUE_MESSAGES+=("$message")
}

has_issue() {
  [[ "${#ISSUE_CODES[@]}" -gt 0 ]]
}

check_file() {
  local path="$1"
  local code="$2"
  [[ -f "$CHECK_ROOT/$path" ]] || add_issue "$code" "missing file: $path"
}

check_contains() {
  local path="$1"
  local needle="$2"
  local code="$3"
  [[ -f "$CHECK_ROOT/$path" ]] || return 0
  grep -F -- "$needle" "$CHECK_ROOT/$path" >/dev/null ||
    add_issue "$code" "$path missing expected text: $needle"
}

generated_profile_contains() {
  local role="$1"
  local needle="$2"
  ENGINEOS_AGENT_INDEX="$CHECK_ROOT/.agents/index.toml" \
    "$SCRIPT_DIR/agent_metadata.sh" profile "$role" | grep -F -- "$needle" >/dev/null ||
    add_issue "generated-profile-drift" "generated profile for $role missing expected text: $needle"
}

generated_wrapper_contains() {
  local role="$1"
  local needle="$2"
  ENGINEOS_AGENT_INDEX="$CHECK_ROOT/.agents/index.toml" \
    "$SCRIPT_DIR/agent_metadata.sh" wrapper "$role" | grep -F -- "$needle" >/dev/null ||
    add_issue "generated-wrapper-drift" "generated wrapper for $role missing expected text: $needle"
}

index_roles() {
  local index="$CHECK_ROOT/.agents/index.toml"
  [[ -f "$index" ]] || return 0
  awk -F'"' '/^id = "/ { print $2 }' "$index"
}

role_in_index() {
  local role="$1"
  local indexed
  while IFS= read -r indexed; do
    [[ "$indexed" == "$role" ]] && return 0
  done < <(index_roles)
  return 1
}

check_unindexed_files() {
  local path
  local role

  [[ -d "$CHECK_ROOT/.agents/roles" ]] && while IFS= read -r path; do
    role="$(basename "$(dirname "$path")")"
    role_in_index "$role" || add_issue "unindexed-role" "role AGENTS file is not in .agents/index.toml: $role"
  done < <(find "$CHECK_ROOT/.agents/roles" -mindepth 2 -maxdepth 2 -name AGENTS.md -print)

  return 0
}

check_stale_project_mcp_refs() {
  local paths=()
  local root_path
  local file
  local hit

  for path in .codex AGENTS.md docs .agents packages/engineos-tools tools/codex tools/post-install-payload/assets/codex; do
    [[ -e "$CHECK_ROOT/$path" ]] && paths+=("$CHECK_ROOT/$path")
  done
  [[ "${#paths[@]}" -gt 0 ]] || return 0

  hit=""
  for root_path in "${paths[@]}"; do
    if [[ -f "$root_path" ]]; then
      if grep -E -q 'engineos_mcp_server.py|project_status|read_status|tools/mcp' "$root_path"; then
        hit="$root_path"
        break
      fi
    elif [[ -d "$root_path" ]]; then
      while IFS= read -r file; do
        if grep -E -q 'engineos_mcp_server.py|project_status|read_status|tools/mcp' "$file"; then
          hit="$file"
          break 2
        fi
      done < <(find "$root_path" -type f -print)
    fi
  done

  [[ -z "$hit" ]] || add_issue "stale-project-mcp" "removed project MCP reference remains: ${hit#"$CHECK_ROOT/"}"
  return 0
}

check_markdown_links() {
  local file
  local match
  local target
  local base
  local resolved

  for file in AGENTS.md docs/agent-roles.md docs/agent-profiles.md docs/engineos-agent-pack.md; do
    [[ -f "$CHECK_ROOT/$file" ]] || continue
    base="$(dirname "$file")"
    while IFS= read -r match; do
      target="${match#*](}"
      target="${target%)}"
      target="${target%%#*}"
      [[ -n "$target" ]] || continue
      case "$target" in
        http:*|https:*|mailto:*|/*|app://*|*.png|*.jpg|*.gif)
          continue
          ;;
      esac
      resolved="$target"
      [[ "$base" != "." ]] && resolved="$base/$target"
      [[ -e "$CHECK_ROOT/$resolved" ]] ||
        add_issue "broken-doc-link" "$file links to missing local path: $target"
    done < <(grep -oE '\[[^][]+\]\([^)]+\)' "$CHECK_ROOT/$file" || true)
  done
  return 0
}

check_role() {
  local role="$1"
  local index=".agents/index.toml"
  local role_doc=".agents/roles/$role/AGENTS.md"
  local skill=".agents/skills/$role/SKILL.md"
  local direct_proofs=0
  local mode="subagent"

  [[ "$role" == "oracle" ]] && mode="primary"

  check_file "$role_doc" "missing-role-doc"
  check_file "$skill" "missing-role-skill"

  check_contains "$index" "role_doc = \"$role_doc\"" "index-role-doc-drift"
  check_contains "$index" "skill = \"$skill\"" "index-skill-drift"
  check_contains "$index" "route_triggers = [" "index-route-trigger-missing"

  for heading in 'Responsibilities:' 'Boundaries:' 'Forbidden actions:' 'Escalation:' 'Proof commands:'; do
    check_contains "$role_doc" "$heading" "role-heading-missing"
  done
  if [[ -f "$CHECK_ROOT/$role_doc" ]]; then
    direct_proofs="$(grep -c '^- `engineos ' "$CHECK_ROOT/$role_doc" || true)"
    [[ "$direct_proofs" -le 4 ]] ||
      add_issue "duplicated-proof-block" "$role_doc repeats a full proof matrix; keep role-local commands short"
  fi

  generated_profile_contains "$role" 'schema = "engineos-agent-profile-v0"'
  generated_profile_contains "$role" "role = \"$role\""
  generated_profile_contains "$role" "mode = \"$mode\""
  generated_profile_contains "$role" "role_doc = \"$role_doc\""
  generated_profile_contains "$role" "skill = \"$skill\""
  generated_profile_contains "$role" 'observability_policy = "metadata-only'
  for field in 'route_triggers = [' 'handoff_targets = [' 'proof_commands = [' 'allowed_read = [' 'ask_before = [' 'forbidden = ['; do
    generated_profile_contains "$role" "$field"
  done

  check_contains "$skill" '---' "skill-frontmatter-missing"
  check_contains "$skill" "name: $role" "skill-name-drift"
  check_contains "$skill" 'description:' "skill-description-missing"
  if [[ -f "$CHECK_ROOT/$skill" ]] && grep -F 'TODO' "$CHECK_ROOT/$skill" >/dev/null; then
    add_issue "skill-todo" "$skill still contains TODO"
  fi
  check_file ".agents/skills/$role/agents/openai.yaml" "missing-skill-openai-metadata"

  generated_wrapper_contains "$role" 'description:'
  generated_wrapper_contains "$role" "mode: $mode"
  generated_wrapper_contains "$role" "docs/agent-roles.md"
  generated_wrapper_contains "$role" "$skill"
  if [[ "$role" == "oracle" ]]; then
    generated_wrapper_contains "$role" 'edit: ask'
    generated_wrapper_contains "$role" 'bash: ask'
  else
    for permission in 'read: allow' 'glob: allow' 'grep: allow' 'list: allow' 'edit: ask' 'bash: ask' 'external_directory: ask'; do
      generated_wrapper_contains "$role" "$permission"
    done
  fi
}

run_checks() {
  local role
  local role_count=0

  check_file ".agents/index.toml" "missing-agent-index"
  check_contains ".agents/index.toml" 'schema = "engineos-agent-index-v0"' "agent-index-schema-missing"
  check_file "docs/agent-roles.md" "missing-agent-roles-doc"
  check_file "docs/agent-profiles.md" "missing-agent-profiles-doc"
  check_file "docs/engineos-agent-pack.md" "missing-agent-pack-doc"

  while IFS= read -r role; do
    [[ -n "$role" ]] || continue
    role_count=$((role_count + 1))
    check_role "$role"
  done < <(index_roles)

  [[ "$role_count" -gt 0 ]] || add_issue "agent-index-empty" ".agents/index.toml has no role records"
  role_in_index cleaner || add_issue "cleaner-not-indexed" "cleaner role is not in .agents/index.toml"
  check_unindexed_files
  check_stale_project_mcp_refs
  check_markdown_links
  return 0
}

emit_human() {
  local i
  if has_issue; then
    printf 'Agent hygiene check failed: %s issue(s)\n' "${#ISSUE_CODES[@]}"
    for i in "${!ISSUE_CODES[@]}"; do
      printf 'FAIL %s: %s\n' "${ISSUE_CODES[$i]}" "${ISSUE_MESSAGES[$i]}"
    done
    if [[ "$FIX_PLAN" == true ]]; then
      printf '\nCleaner fix plan:\n'
      printf '1. Update .agents/index.toml and role/profile/wrapper paths until every indexed file exists.\n'
      printf '2. Remove stale project MCP file references and keep MCP docs limited to future read-only live runtime state.\n'
      printf '3. Move repeated role/proof detail into docs/agent-roles.md or profiles; keep role AGENTS.md files short.\n'
      printf '4. Rerun eos-agent hygiene check and eos-test agent.\n'
    fi
  else
    printf 'Agent hygiene check passed\n'
  fi
}

emit_json() {
  local i
  printf '{"schema":"engineos-agent-hygiene-v0","status":'
  if has_issue; then
    printf '"fail","issue_count":%s,"issues":[' "${#ISSUE_CODES[@]}"
    for i in "${!ISSUE_CODES[@]}"; do
      [[ "$i" -eq 0 ]] || printf ','
      printf '{"code":'
      json_string "${ISSUE_CODES[$i]}"
      printf ',"message":'
      json_string "${ISSUE_MESSAGES[$i]}"
      printf '}'
    done
    printf ']}'
  else
    printf '"pass","issue_count":0,"issues":[]}'
  fi
  printf '\n'
}

enqueue_cleaner_task() {
  local summary
  has_issue || return 0
  summary="Agent hygiene drift detected: ${#ISSUE_CODES[@]} issue(s); first=${ISSUE_CODES[0]}"
  "$SCRIPT_DIR/agent_dispatcher.sh" queue add \
    --role cleaner \
    --reason hygiene-drift \
    --summary "$summary" \
    --proof "eos-agent hygiene check" \
    --source agent-hygiene \
    --priority normal
}

cmd_check() {
  run_checks
  if [[ "$JSON" == true ]]; then
    emit_json
  else
    emit_human
  fi
  [[ "$ENQUEUE" == true ]] && enqueue_cleaner_task
  has_issue && return 1
  return 0
}

COMMAND="${1:-check}"
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON=true
      ;;
    --fix-plan)
      FIX_PLAN=true
      ;;
    --enqueue)
      ENQUEUE=true
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
  shift
done

case "$COMMAND" in
  check)
    cmd_check
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown command: $COMMAND"
    ;;
esac
