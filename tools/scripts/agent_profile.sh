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

cmd="${1:-list}"
shift || true

case "$cmd" in
  list)
    cmd_list "$@"
    ;;
  show)
    cmd_show "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown command: $cmd"
    ;;
esac
