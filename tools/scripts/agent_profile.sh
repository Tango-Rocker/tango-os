#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
METADATA_SCRIPT="$SCRIPT_DIR/agent_metadata.sh"

usage() {
  cat <<'HELP'
Usage:
  agent_profile.sh list
  agent_profile.sh show <role>
  agent_profile.sh capabilities

Print structured EngineOS agent profile metadata. Profiles are declarative and
do not execute agent actions.
HELP
}

die() {
  printf 'eos-agent profile: %s\n' "$*" >&2
  exit 1
}

cmd_list() {
  "$METADATA_SCRIPT" roles | sort
}

cmd_show() {
  local role="${1:-}"
  [[ -n "$role" ]] || die "show requires a role"
  [[ "$role" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid role: $role"
  "$METADATA_SCRIPT" profile "$role"
}

cmd_capabilities() {
  local role profile display mode skill role_doc triggers

  printf 'schema=engineos-agent-capabilities-v0\n'
  printf 'source=%s\n' ".agents/index.toml"
  while IFS= read -r role; do
    [[ -n "$role" ]] || continue
    profile="$("$METADATA_SCRIPT" profile "$role")"
    display="$(awk -F'"' '$1 == "display_name = " { print $2; exit }' <<<"$profile")"
    mode="$(awk -F'"' '$1 == "mode = " { print $2; exit }' <<<"$profile")"
    skill="$(awk -F'"' '$1 == "skill = " { print $2; exit }' <<<"$profile")"
    role_doc="$(awk -F'"' '$1 == "role_doc = " { print $2; exit }' <<<"$profile")"
    triggers="$(awk '$1 == "route_triggers" { sub("^route_triggers = ", ""); print; exit }' <<<"$profile")"

    printf '\nrole=%s\n' "$role"
    printf 'display_name=%s\n' "$display"
    printf 'mode=%s\n' "$mode"
    printf 'skill=%s\n' "$skill"
    printf 'role_doc=%s\n' "$role_doc"
    printf 'route_triggers=%s\n' "$triggers"
  done < <("$METADATA_SCRIPT" roles | sort)
}

cmd="${1:-list}"
shift || true

case "$cmd" in
  list)
    cmd_list "$@"
    ;;
  show)
    cmd_show "$@"
    ;;
  capabilities|capability)
    cmd_capabilities "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown command: $cmd"
    ;;
esac
