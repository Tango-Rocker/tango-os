#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -n "${ENGINEOS_SCRIPT_DIR:-}" ]]; then
  SCRIPT_DIR="$ENGINEOS_SCRIPT_DIR"
else
  SCRIPT_DIR="$(cd "$MODULE_DIR/../../scripts" && pwd -P)"
fi
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
DRY_RUN=false
HOST=""
DEST="/srv/engineos"
GUEST_USER="dev"
GUEST_HOST="127.0.0.1"
GUEST_PORT="2222"
BUILD_COMMAND="./tools/engineos/eos-proof build-lab"
DOCTOR_COMMAND="eos-doctor --vm"
SKIP_BUILD=false
SSH_BIN="${ENGINEOS_SSH:-ssh}"
GUEST_SSH_BIN="${ENGINEOS_GUEST_SSH:-ssh}"
SSH_CONNECT_TIMEOUT="${ENGINEOS_SSH_CONNECT_TIMEOUT:-10}"

usage() {
  cat <<'HELP'
Usage: builder_doctor_proof.sh --host user@builder [options]

Run the PoC 0 host-side build and guest doctor validation:
  1. SSH into the Arch builder and run the build command.
  2. SSH from the builder into the booted EngineDev guest.
  3. Run eos-doctor --vm inside that guest.

Options:
  --dry-run                 Print commands without running them
  --host user@builder       Arch builder SSH target
  --dest /srv/engineos      Repo path on the builder (default: /srv/engineos)
  --guest-user dev          EngineDev guest SSH user (default: dev)
  --guest-host 127.0.0.1    Guest host as seen from builder (default: 127.0.0.1)
  --guest-port 2222         Guest SSH port as seen from builder (default: 2222)
  --build-command <cmd>     Builder command to run (default: build-lab proof)
  --doctor-command <cmd>    Guest doctor command (default: eos-doctor --vm)
  --skip-build              Only run the guest doctor SSH step
  ENGINEOS_SSH=<path>       Override host-to-builder SSH command
  ENGINEOS_GUEST_SSH=<path> Override builder-to-guest SSH command

The default guest target matches `eos-vm boot enginedev`, which forwards
builder port 2222 to guest port 22.
HELP
}

shell_join() {
  local arg
  local quoted
  local first=true
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    if [[ "$first" == true ]]; then
      printf '%s' "$quoted"
      first=false
    else
      printf ' %s' "$quoted"
    fi
  done
}

remote_build_command() {
  printf 'cd %s && %s' "$(shell_join "$DEST")" "$BUILD_COMMAND"
}

remote_doctor_command() {
  local nested=(
    "$GUEST_SSH_BIN"
    -o BatchMode=yes
    -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT"
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=1
    -o StrictHostKeyChecking=accept-new
    -p "$GUEST_PORT"
    "$GUEST_USER@$GUEST_HOST"
    "$DOCTOR_COMMAND"
  )

  printf 'cd %s && ' "$(shell_join "$DEST")"
  shell_join "${nested[@]}"
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --host)
      shift
      HOST="${1:-}"
      [[ -n "$HOST" ]] || die "--host requires user@builder"
      ;;
    --dest)
      shift
      DEST="${1:-}"
      [[ -n "$DEST" ]] || die "--dest requires a path"
      ;;
    --guest-user)
      shift
      GUEST_USER="${1:-}"
      [[ -n "$GUEST_USER" ]] || die "--guest-user requires a user"
      ;;
    --guest-host)
      shift
      GUEST_HOST="${1:-}"
      [[ -n "$GUEST_HOST" ]] || die "--guest-host requires a host"
      ;;
    --guest-port)
      shift
      GUEST_PORT="${1:-}"
      [[ -n "$GUEST_PORT" ]] || die "--guest-port requires a port"
      ;;
    --build-command)
      shift
      BUILD_COMMAND="${1:-}"
      [[ -n "$BUILD_COMMAND" ]] || die "--build-command requires a command"
      ;;
    --doctor-command)
      shift
      DOCTOR_COMMAND="${1:-}"
      [[ -n "$DOCTOR_COMMAND" ]] || die "--doctor-command requires a command"
      ;;
    --skip-build)
      SKIP_BUILD=true
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown builder doctor proof option: $1"
      ;;
  esac
  shift
done

[[ "$DEST" == /* ]] || die "--dest must be an absolute path"

if [[ -z "$HOST" ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    HOST="dev@<builder-vm-ip>"
  else
    die "real builder doctor proof requires --host user@builder"
  fi
fi

printf 'EngineOS builder doctor proof\n'
printf '  root:           %s\n' "$ROOT"
printf '  host:           %s\n' "$HOST"
printf '  dest:           %s\n' "$DEST"
printf '  guest:          %s@%s:%s\n' "$GUEST_USER" "$GUEST_HOST" "$GUEST_PORT"
printf '  dry_run:        %s\n' "$DRY_RUN"
printf '  skip_build:     %s\n' "$SKIP_BUILD"
printf '  build_command:  %s\n' "$BUILD_COMMAND"
printf '  doctor_command: %s\n' "$DOCTOR_COMMAND"
printf '  ssh:            %s\n' "$SSH_BIN"
printf '  guest_ssh:      %s\n' "$GUEST_SSH_BIN"

run_step "local scaffold check" "$SCRIPT_DIR/preflight.sh" repo
if [[ "$SKIP_BUILD" != true ]]; then
  run_step "run builder build proof" "$SSH_BIN" -o BatchMode=yes -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT" "$HOST" "$(remote_build_command)"
fi
run_step "run EngineDev guest doctor through builder" "$SSH_BIN" -o BatchMode=yes -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT" "$HOST" "$(remote_doctor_command)"

printf '\nBuilder doctor proof completed.\n'
