#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  cat <<'HELP'
Usage:
  agent_route.sh route [--dry-run] "<request>"

Print role, confidence, risk, reason, and the smallest direct EngineOS proof.
Route metadata is recorded only when observability is enabled.
HELP
}

die() {
  printf 'eos-agent: %s\n' "$*" >&2
  exit 1
}

contains_any() {
  local text="$1"
  shift
  local pattern
  for pattern in "$@"; do
    [[ "$text" == *"$pattern"* ]] && return 0
  done
  return 1
}

route_request() {
  local request="$1"
  local lower
  local role="oracle"
  local confidence="0.60"
  local risk="low"
  local reason="broad request needs Oracle clarification"
  local reason_code="broad-router"
  local proof='eos-agent route --dry-run "<request>"'

  lower="$(printf '%s' "$request" | tr '[:upper:]' '[:lower:]')"

  if contains_any "$lower" "install dev" "usb write" "wipe" "format disk" "rm -rf" "pacman -r" "sudo "; then
    risk="high"
  elif contains_any "$lower" "build" "compile" "kernel" "aur" "service" "systemd" "tty" "kms" "runtime" "window" "wayland"; then
    risk="medium"
  fi

  if contains_any "$lower" "hygiene" "cleanup" "clean up" "stale" "duplicate" "duplicated" "agent pack" "skill docs" "profile drift" "wrapper drift" "index drift" "validation drift"; then
    role="cleaner"
    confidence="0.90"
    reason="request is agent-pack hygiene work"
    reason_code="agent-hygiene"
    proof="eos-agent hygiene check"
  elif contains_any "$lower" "quake" "quakespasm" "pak0" "pak1" "id1" "quake-generator"; then
    role="pergame-quake"
    confidence="0.92"
    reason="request is Quake-specific"
    reason_code="quake-specific"
    proof="eos-assets check quake"
  elif contains_any "$lower" "compile" "compiler" "c++" "c/c++" "build from source" "kernel" "aur" "makepkg" "pkgbuild" "package" "repo build"; then
    role="compiler"
    confidence="0.86"
    reason="request is source/package build work"
    reason_code="source-build"
    proof="eos-build repo --dry-run"
  elif contains_any "$lower" "wayland" "wlroots" "gl shell" "desktop" "window" "tiling" "app slot" "launchpad" "focus" "input routing" "register window" "swap window"; then
    role="admin-shell"
    confidence="0.84"
    reason="request is shell/window/session ownership"
    reason_code="shell-session"
    proof="eos-app status --json"
  elif contains_any "$lower" "3d" "scene" "game loop" "renderer" "rendering" "frame" "cube" "opengl" "engine capability" "tango-os platform"; then
    role="engine-builder"
    confidence="0.82"
    reason="request is engine or visual runtime work"
    reason_code="engine-visual"
    proof="eos-test render --smoke"
  elif contains_any "$lower" "maintenance" "troubleshoot" "service" "startup" "config" "configuration" "boot" "log" "doctor" "update" "systemd" "network" "docker" "grub" "swapfile"; then
    role="overseer"
    confidence="0.83"
    reason="request is OS maintenance or troubleshooting"
    reason_code="os-maintenance"
    proof="eos-doctor --mock"
  fi

  printf 'role=%s\n' "$role"
  printf 'confidence=%s\n' "$confidence"
  printf 'risk=%s\n' "$risk"
  printf 'reason=%s\n' "$reason"
  printf 'proof=%s\n' "$proof"

  "$SCRIPT_DIR/observability.sh" record \
    --kind agent-route \
    --source oracle \
    --role "$role" \
    --confidence "$confidence" \
    --risk "$risk" \
    --reason "$reason_code" \
    --proof "$proof" \
    --request "$request" >/dev/null 2>&1 || true
}

cmd="${1:-route}"
shift || true

case "$cmd" in
  route)
    dry_run=false
    while [[ $# -gt 0 && "${1:-}" == --* ]]; do
      case "$1" in
        --dry-run)
          dry_run=true
          ;;
        *)
          die "unknown route option: $1"
          ;;
      esac
      shift
    done
    [[ "$dry_run" == true ]] || die "route currently requires --dry-run"
    [[ $# -gt 0 ]] || die "route requires a request"
    route_request "$*"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown command: $cmd"
    ;;
esac
