#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
DRY_RUN=false
HOST=""
DEST="/srv/engineos"
SKIP_BOOTSTRAP=false
RUN_PROOF=false
SSH_BIN="${ENGINEOS_SSH:-ssh}"
RSYNC_BIN="${ENGINEOS_RSYNC:-rsync}"
SSH_CONNECT_TIMEOUT="${ENGINEOS_SSH_CONNECT_TIMEOUT:-10}"
SSH_OPTS=(
  -o BatchMode=yes
  -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT"
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=1
  -o StrictHostKeyChecking=accept-new
)
RSYNC_RSH="$SSH_BIN -o BatchMode=yes -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o StrictHostKeyChecking=accept-new"

usage() {
  cat <<'HELP'
Usage: builder_handoff.sh [--dry-run] [--host user@host] [--dest /srv/engineos] [--skip-bootstrap] [--run-proof]

Sync this checkout to the Arch builder VM and run the PoC 0 builder path:
bootstrap, builder validation, real repo build, and repo validation.

With --run-proof, continue on the builder with the full build-lab proof:
builder validation, preflight, package lint, shell build, repo build, repo
validation, EngineDev ISO build, and artifact listing.

Real mode requires --host. Dry-run mode prints the exact commands.

Environment:
  ENGINEOS_SSH=<path>               Override SSH command
  ENGINEOS_RSYNC=<path>             Override rsync command
  ENGINEOS_SSH_CONNECT_TIMEOUT=<s>  Override SSH connect timeout
HELP
}

remote_dest() {
  printf '%s:%s\n' "$HOST" "$DEST"
}

print_step() {
  local label="$1"
  shift

  printf '\n==> %s\n' "$label"
  printf '    '
  quote_cmd "$@"
}

run_step() {
  local label="$1"
  shift

  print_step "$label" "$@"
  if [[ "$DRY_RUN" != true ]]; then
    "$@"
  fi
}

remote_setup_command() {
  printf "if [ -d '%s' ] && [ -w '%s' ]; then :; elif mkdir -p '%s' 2>/dev/null; then :; else sudo -n mkdir -p '%s' && sudo -n chown \"\$USER:\$USER\" '%s'; fi; test -w '%s'" \
    "$DEST" "$DEST" "$DEST" "$DEST" "$DEST" "$DEST"
}

remote_builder_command() {
  local commands=()

  if [[ "$SKIP_BOOTSTRAP" != true ]]; then
    commands+=("./tools/engineos/engineos bootstrap builder")
  fi
  if [[ "$RUN_PROOF" == true ]]; then
    commands+=("./tools/engineos/engineos proof build-lab")
  else
    commands+=(
      "./tools/engineos/engineos validate builder"
      "./tools/engineos/engineos build repo"
      "./tools/engineos/engineos validate repo"
    )
  fi

  printf "cd '%s'" "$DEST"
  local command
  for command in "${commands[@]}"; do
    printf " && %s" "$command"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --host)
      shift
      HOST="${1:-}"
      [[ -n "$HOST" ]] || die "--host requires user@host"
      ;;
    --dest)
      shift
      DEST="${1:-}"
      [[ -n "$DEST" ]] || die "--dest requires a path"
      ;;
    --skip-bootstrap)
      SKIP_BOOTSTRAP=true
      ;;
    --run-proof)
      RUN_PROOF=true
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown builder handoff option: $1"
      ;;
  esac
  shift
done

[[ "$DEST" == /* ]] || die "--dest must be an absolute path"
[[ "$DEST" != *"'"* ]] || die "--dest cannot contain single quotes"

if [[ -z "$HOST" ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    HOST="dev@<arch-builder-vm>"
  else
    die "real builder handoff requires --host user@host"
  fi
fi

printf 'EngineOS builder handoff\n'
printf '  root:           %s\n' "$ROOT"
printf '  host:           %s\n' "$HOST"
printf '  dest:           %s\n' "$DEST"
printf '  dry_run:        %s\n' "$DRY_RUN"
printf '  skip_bootstrap: %s\n' "$SKIP_BOOTSTRAP"
printf '  run_proof:      %s\n' "$RUN_PROOF"
printf '  ssh:            %s\n' "$SSH_BIN"
printf '  rsync:          %s\n' "$RSYNC_BIN"

run_step "local scaffold check" "$SCRIPT_DIR/preflight.sh" repo
run_step "prepare remote /srv checkout" "$SSH_BIN" "${SSH_OPTS[@]}" "$HOST" "$(remote_setup_command)"
run_step "sync checkout to builder" "$RSYNC_BIN" -a -e "$RSYNC_RSH" \
  --exclude artifacts/ \
  --exclude out/ \
  --exclude repo/ \
  --exclude work/ \
  --exclude tmp/ \
  --exclude 'packages/*/pkg/' \
  --exclude 'packages/*/src/' \
  --exclude 'packages/*.pkg.tar.*' \
  --exclude 'packages/*/*.pkg.tar.*' \
  --exclude engines/quakespasm/upstream/ \
  --exclude .git/ \
  "$ROOT/" \
  "$(remote_dest)/"
run_step "run builder package proof" "$SSH_BIN" "${SSH_OPTS[@]}" "$HOST" "$(remote_builder_command)"

printf '\nBuilder handoff sequence completed.\n'
if [[ "$DRY_RUN" == true ]]; then
  if [[ "$RUN_PROOF" == true ]]; then
    printf 'Next real command: ./tools/engineos/engineos builder handoff --host %s --run-proof\n' "$HOST"
  else
    printf 'Next real command: ./tools/engineos/engineos builder handoff --host %s\n' "$HOST"
  fi
else
  if [[ "$RUN_PROOF" == true ]]; then
    printf 'Next test VM command: ssh %s "cd %s && ./tools/engineos/engineos vm boot enginedev"\n' "$HOST" "$DEST"
    printf 'Next booted ISO command: engineos proof booted-iso --vm\n'
  else
    printf 'Next builder command: cd %s && ./tools/engineos/engineos proof build-lab\n' "$DEST"
  fi
fi
