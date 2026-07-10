#!/usr/bin/env bash
set -euo pipefail

FORCE=false

usage() {
  cat <<'HELP'
Usage: install_git_push_deploy_hook.sh [options]

Install an EngineOS Git pre-push hook that runs a local deploy command for
pushed branch updates. The default command rebuilds/reinstalls changed local
packages through eos-ci without using ISO, VM, or builder handoff paths.

The installed hook always invokes the committed-range-aware `eos dev apply`
workflow. It cannot be replaced with a working-tree-based command.

Options:
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
git config --unset engineos.deployCommand >/dev/null 2>&1 || true
git config --unset engineos.deployHost >/dev/null 2>&1 || true
git config --unset engineos.deployDest >/dev/null 2>&1 || true
git config --unset engineos.deployRunProof >/dev/null 2>&1 || true

printf 'Installed EngineOS deploy-on-push hook\n'
printf '  hook:      %s\n' "$hook"
printf '  command:   eos dev apply <Git ref updates>\n'
