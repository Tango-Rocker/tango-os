#!/usr/bin/env bash
set -euo pipefail

COMMAND="./tools/engineos/eos-ci local --test agent --install --clean-generated --no-validate-repo"
FORCE=false

usage() {
  cat <<'HELP'
Usage: install_git_push_deploy_hook.sh [options]

Install an EngineOS Git pre-push hook that runs a local deploy command for
pushed branch updates. The default command rebuilds/reinstalls changed local
packages through eos-ci without using ISO, VM, or builder handoff paths.

Options:
  --command command  Local deploy command to run from the repo root.
  --force            Replace an existing non-EngineOS pre-push hook.
  -h, --help         Show this help.
HELP
}

die() {
  printf 'install git push deploy hook: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --command)
      shift
      COMMAND="${1:-}"
      [[ -n "$COMMAND" ]] || die "--command requires a command string"
      ;;
    --force)
      FORCE=true
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
  shift
done

root="$(git rev-parse --show-toplevel 2>/dev/null)" ||
  die "must run inside a Git checkout"
cd "$root"

helper="$root/tools/hooks/git_pre_push_deploy.sh"
[[ -x "$helper" ]] || die "deploy helper is not executable: $helper"

hooks_dir="$(git rev-parse --git-path hooks)"
mkdir -p "$hooks_dir"
hook="$hooks_dir/pre-push"

if [[ -e "$hook" ]] && ! grep -F 'EngineOS deploy-on-push hook' "$hook" >/dev/null 2>&1; then
  "$FORCE" || die "pre-push hook already exists; rerun with --force after reviewing $hook"
fi

cat >"$hook" <<HOOK
#!/usr/bin/env bash
# EngineOS deploy-on-push hook.
exec "$helper" "\$@"
HOOK
chmod 0755 "$hook"

git config engineos.deployOnPush true
git config engineos.deployCommand "$COMMAND"
git config --unset engineos.deployHost >/dev/null 2>&1 || true
git config --unset engineos.deployDest >/dev/null 2>&1 || true
git config --unset engineos.deployRunProof >/dev/null 2>&1 || true

printf 'Installed EngineOS deploy-on-push hook\n'
printf '  hook:      %s\n' "$hook"
printf '  command:   %s\n' "$COMMAND"
