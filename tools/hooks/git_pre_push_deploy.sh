#!/usr/bin/env bash
set -euo pipefail

remote_name="${1:-}"
remote_url="${2:-}"

die() {
  printf 'engineos git pre-push deploy: %s\n' "$*" >&2
  exit 1
}

git_config() {
  git config --get "$1" 2>/dev/null || true
}

git_config_bool() {
  local key="$1"
  local value
  value="$(git_config "$key")"
  case "$value" in
    true|yes|on|1)
      return 0
      ;;
  esac
  return 1
}

root="$(git rev-parse --show-toplevel 2>/dev/null)" ||
  die "must run inside the EngineOS Git checkout"
cd "$root"

deploy_enabled="${ENGINEOS_GIT_PUSH_DEPLOY:-$(git_config engineos.deployOnPush)}"
case "$deploy_enabled" in
  false|no|off|0)
    printf 'EngineOS deploy-on-push disabled\n'
    exit 0
    ;;
esac

ref_update_args=()
branch_updates=()
while read -r local_ref local_oid remote_ref remote_oid; do
  [[ -n "${local_ref:-}" ]] || continue
  case "$local_ref" in
    refs/heads/*)
      [[ "$local_oid" != "0000000000000000000000000000000000000000" ]] || continue
      branch_updates+=("${local_ref#refs/heads/}")
      ref_update_args+=(--ref-update "$local_ref" "$local_oid" "$remote_ref" "$remote_oid")
      ;;
  esac
done

if [[ ${#branch_updates[@]} -eq 0 ]]; then
  printf 'EngineOS deploy-on-push: no branch updates in push; skipping deploy\n'
  exit 0
fi

deploy_command="./tools/engineos/eos dev apply"

printf 'EngineOS deploy-on-push\n'
printf '  remote:   %s\n' "${remote_name:-<unknown>}"
printf '  url:      %s\n' "${remote_url:-<unknown>}"
printf '  branches:\n'
printf '    - %s\n' "${branch_updates[@]}"
printf '  command:  %s\n' "$deploy_command"
printf '\n'

ENGINEOS_ROOT="$root" \
ENGINEOS_SCRIPT_DIR="$root/tools/scripts" \
ENGINEOS_EOS_DIR="$root/tools/eos" \
  "$root/tools/engineos/eos" dev apply "${ref_update_args[@]}"
