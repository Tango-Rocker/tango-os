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
HOST="dev@127.0.0.1"
PORT="2222"
PAYLOAD=""
REMOTE_DIR="/tmp/engineos-post-first-deploy"
DRY_RUN=false
STRICT_HOST_KEY_CHECKING="no"
RUN_CODEX=true
RUN_DOCKER=true
RUN_PACMAN=true
RUN_DEV_REPOS=true
FORCE_CONFIG=false

usage() {
  cat <<'HELP'
Usage: post_first_deploy.sh [options]

SSH into a freshly booted EngineDev guest, copy the post-install payload, and
run first-time dev environment setup.

Options:
  --host user@host          Guest SSH target (default: dev@127.0.0.1)
  --port port              Guest SSH port (default: 2222)
  --payload path           Payload directory to copy
  --remote-dir path        Remote staging directory (default: /tmp/engineos-post-first-deploy)
  --password password      Use sshpass with this password
  --dry-run                Print actions without connecting
  --strict-host-key        Keep OpenSSH strict host key checking enabled
  --skip-codex             Do not install/upgrade Codex CLI
  --skip-docker            Do not install/start Docker
  --skip-pacman            Do not install Arch packages
  --skip-dev-repos         Do not clone/update EngineDev helper repos
  --force-config           Replace managed tmux/Docker config files
  -h, --help               Show this help

Environment:
  ENGINEOS_GUEST_PASSWORD  Password used through sshpass when set
  ENGINEOS_SSH             SSH command override
  ENGINEOS_SCP             SCP command override
HELP
}

payload_default() {
  if [[ -d "$ROOT/tools/post-install-payload" ]]; then
    printf '%s\n' "$ROOT/tools/post-install-payload"
    return
  fi
  printf '%s\n' "$ROOT/share/engineos/post-install-payload"
}

quote_join() {
  local out=""
  local arg
  for arg in "$@"; do
    printf -v out '%s%q ' "$out" "$arg"
  done
  printf '%s' "$out"
}

require_payload() {
  [[ -d "$PAYLOAD" ]] || die "post-first-deploy payload not found: $PAYLOAD"
  [[ -x "$PAYLOAD/scripts/setup_dev_environment.sh" ]] ||
    die "payload setup script is not executable: $PAYLOAD/scripts/setup_dev_environment.sh"
}

build_ssh_base() {
  SSH_CMD="${ENGINEOS_SSH:-ssh}"
  SCP_CMD="${ENGINEOS_SCP:-scp}"
  SSH_BASE=("$SSH_CMD" -p "$PORT")
  SCP_BASE=("$SCP_CMD" -P "$PORT")

  if [[ "$STRICT_HOST_KEY_CHECKING" == "no" ]]; then
    SSH_BASE+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    SCP_BASE+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
  fi

  if [[ -n "${ENGINEOS_GUEST_PASSWORD:-}" ]]; then
    have_cmd sshpass || die "ENGINEOS_GUEST_PASSWORD is set but sshpass is not available"
    SSH_BASE=(sshpass -p "$ENGINEOS_GUEST_PASSWORD" "${SSH_BASE[@]}")
    SCP_BASE=(sshpass -p "$ENGINEOS_GUEST_PASSWORD" "${SCP_BASE[@]}")
  fi
}

remote_setup_args() {
  local args=(--payload "$REMOTE_DIR")
  "$RUN_CODEX" || args+=(--skip-codex)
  "$RUN_DOCKER" || args+=(--skip-docker)
  "$RUN_PACMAN" || args+=(--skip-pacman)
  "$RUN_DEV_REPOS" || args+=(--skip-dev-repos)
  "$FORCE_CONFIG" && args+=(--force-config)
  printf '%s\0' "${args[@]}"
}

dry_run() {
  build_ssh_base

  printf 'EngineOS post-first-deploy dry-run\n'
  printf '  host:       %s\n' "$HOST"
  printf '  port:       %s\n' "$PORT"
  printf '  payload:    %s\n' "$PAYLOAD"
  printf '  remote-dir: %s\n' "$REMOTE_DIR"
  printf '  codex:      %s\n' "$RUN_CODEX"
  printf '  docker:     %s\n' "$RUN_DOCKER"
  printf '  pacman:     %s\n' "$RUN_PACMAN"
  printf '  repos:      %s\n' "$RUN_DEV_REPOS"
  printf '\nCommands:\n'
  printf '  %s%s %q\n' "$(quote_join "${SSH_BASE[@]}")" "$HOST" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"
  printf '  %s-r %q %s:%q\n' "$(quote_join "${SCP_BASE[@]}")" "$PAYLOAD/." "$HOST" "$REMOTE_DIR/"

  local setup_args=()
  while IFS= read -r -d '' arg; do
    setup_args+=("$arg")
  done < <(remote_setup_args)
  printf '  %s%s %q\n' "$(quote_join "${SSH_BASE[@]}")" "$HOST" "bash '$REMOTE_DIR/scripts/setup_dev_environment.sh' $(quote_join "${setup_args[@]}")"
  printf '\nNext real command: eos-deploy first --host %s --port %s\n' "$HOST" "$PORT"
}

run_deploy() {
  build_ssh_base

  local setup_args=()
  while IFS= read -r -d '' arg; do
    setup_args+=("$arg")
  done < <(remote_setup_args)

  printf 'EngineOS post-first-deploy\n'
  printf '  host:       %s\n' "$HOST"
  printf '  port:       %s\n' "$PORT"
  printf '  payload:    %s\n' "$PAYLOAD"
  printf '  remote-dir: %s\n' "$REMOTE_DIR"

  "${SSH_BASE[@]}" "$HOST" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"
  "${SCP_BASE[@]}" -r "$PAYLOAD/." "$HOST:$REMOTE_DIR/"
  "${SSH_BASE[@]}" "$HOST" "bash '$REMOTE_DIR/scripts/setup_dev_environment.sh' $(quote_join "${setup_args[@]}")"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="${2:-}"
      [[ -n "$HOST" ]] || die "--host requires a value"
      shift 2
      ;;
    --port)
      PORT="${2:-}"
      [[ -n "$PORT" ]] || die "--port requires a value"
      shift 2
      ;;
    --payload)
      PAYLOAD="${2:-}"
      [[ -n "$PAYLOAD" ]] || die "--payload requires a value"
      shift 2
      ;;
    --remote-dir)
      REMOTE_DIR="${2:-}"
      [[ -n "$REMOTE_DIR" && "$REMOTE_DIR" == /* ]] || die "--remote-dir requires an absolute path"
      shift 2
      ;;
    --password)
      ENGINEOS_GUEST_PASSWORD="${2:-}"
      [[ -n "$ENGINEOS_GUEST_PASSWORD" ]] || die "--password requires a value"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --strict-host-key)
      STRICT_HOST_KEY_CHECKING="yes"
      shift
      ;;
    --skip-codex)
      RUN_CODEX=false
      shift
      ;;
    --skip-docker)
      RUN_DOCKER=false
      shift
      ;;
    --skip-pacman)
      RUN_PACMAN=false
      shift
      ;;
    --skip-dev-repos)
      RUN_DEV_REPOS=false
      shift
      ;;
    --force-config)
      FORCE_CONFIG=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown post-first-deploy option: $1"
      ;;
  esac
done

PAYLOAD="${PAYLOAD:-$(payload_default)}"
require_payload

if "$DRY_RUN"; then
  dry_run
else
  run_deploy
fi
