#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
ACTION="${1:-help}"
shift || true
DRY_RUN=false
PLAN_ARGS=()

usage() {
  cat <<'HELP'
Usage:
  eos dev plan --range OLD..NEW
  eos dev apply --range OLD..NEW [--dry-run]

The range must describe committed work. apply refuses relevant dirty files,
builds the complete local dependency closure, installs it in one transaction,
then runs package-specific refresh and proof commands.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --range)
      shift
      [[ -n "${1:-}" ]] || die "--range requires OLD..NEW"
      PLAN_ARGS+=(--range "$1")
      ;;
    --ref-update)
      [[ $# -ge 5 ]] || die "--ref-update requires LOCAL_REF LOCAL_OID REMOTE_REF REMOTE_OID"
      PLAN_ARGS+=(--ref-update "$2" "$3" "$4" "$5")
      shift 4
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown eos dev option: $1"
      ;;
  esac
  shift
done

[[ "$ACTION" == plan || "$ACTION" == apply ]] || { usage >&2; exit 2; }
[[ ${#PLAN_ARGS[@]} -gt 0 ]] || die "$ACTION requires --range or --ref-update"

check_args=()
[[ "$ACTION" == apply ]] && check_args+=(--check-dirty)
plan_file="$(mktemp "${TMPDIR:-/tmp}/engineos-change-plan.XXXXXX")"
trap 'rm -f "$plan_file"' EXIT
python "$SCRIPT_DIR/change_plan.py" --root "$ROOT" "${PLAN_ARGS[@]}" "${check_args[@]}" >"$plan_file"

if [[ "$ACTION" == plan ]]; then
  cat "$plan_file"
  exit 0
fi

mapfile -t packages < <(python -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["packages"]))' "$plan_file")
mapfile -t tests < <(python -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["tests"]))' "$plan_file")

ci_args=(local --install --clean-generated --no-validate-repo)
[[ "$DRY_RUN" == true ]] && ci_args+=(--dry-run)
for package in "${packages[@]}"; do ci_args+=(--package "$package"); done
for test_scope in "${tests[@]}"; do ci_args+=(--test "$test_scope"); done
"$ROOT/tools/engineos/eos-ci" "${ci_args[@]}"

if [[ "$DRY_RUN" == true ]]; then
  printf 'DRY-RUN package refresh and live proofs for: %s\n' "${packages[*]}"
  exit 0
fi

if printf '%s\n' "${packages[@]}" | grep -Eq '^engineos-(quakespasm|level-agent)$'; then
  systemctl --user daemon-reload
fi

if printf '%s\n' "${packages[@]}" | grep -Eq '^engineos-(tools|config|shell)$'; then
  "$ROOT/tools/engineos/eos-runtime" shell refresh-user
fi
if printf '%s\n' "${packages[@]}" | grep -Eq '^engineos-(config|shell)$'; then
  "$ROOT/tools/engineos/eos-runtime" shell restart-live
  "$ROOT/tools/engineos/eos-app" manifest validate
fi

printf 'EngineOS committed-range apply complete\n'
