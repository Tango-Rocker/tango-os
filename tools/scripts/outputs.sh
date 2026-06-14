#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ACTION="${1:-list}"
shift || true

SYSFS="${ENGINEOS_DRM_SYSFS:-/sys/class/drm}"
MODE="--single"

usage() {
  cat <<'HELP'
Usage: outputs.sh list [--sysfs <dir>]
       outputs.sh validate --single|--dual-static [--sysfs <dir>]

Inspect DRM connector state from /sys/class/drm. This is a hardware proof aid:
VM results are useful smoke context, but AMD bare-metal is the source of truth.
HELP
}

read_field() {
  local path="$1"
  local fallback="$2"
  local value=""
  if [[ -r "$path" ]]; then
    value="$(sed -n '1p' "$path" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
    else
      printf '%s\n' "$fallback"
    fi
  else
    printf '%s\n' "$fallback"
  fi
}

connector_paths() {
  [[ -d "$SYSFS" ]] || return 0
  find "$SYSFS" -maxdepth 1 \( -type d -o -type l \) -name 'card*-*' -print 2>/dev/null | sort
}

connected_count() {
  local connector
  local status
  local count=0

  while IFS= read -r connector; do
    [[ -n "$connector" ]] || continue
    status="$(read_field "$connector/status" "unknown")"
    if [[ "$status" == "connected" ]]; then
      count=$((count + 1))
    fi
  done < <(connector_paths)

  printf '%s\n' "$count"
}

list_outputs() {
  local connector
  local name
  local status
  local enabled
  local mode
  local found=false

  printf 'EngineOS outputs\n'
  printf '  sysfs: %s\n' "$SYSFS"

  if [[ ! -d "$SYSFS" ]]; then
    printf '  result: sysfs-missing\n'
    return 0
  fi

  while IFS= read -r connector; do
    [[ -n "$connector" ]] || continue
    found=true
    name="$(basename "$connector")"
    status="$(read_field "$connector/status" "unknown")"
    enabled="$(read_field "$connector/enabled" "unknown")"
    mode="$(read_field "$connector/modes" "none")"
    printf '  connector: %s status=%s enabled=%s preferred_mode=%s\n' "$name" "$status" "$enabled" "$mode"
  done < <(connector_paths)

  if [[ "$found" != true ]]; then
    printf '  result: no-connectors\n'
  fi
}

validate_outputs() {
  local count
  local required=1

  case "$MODE" in
    --single)
      required=1
      ;;
    --dual-static)
      required=2
      ;;
    *)
      die "outputs validate expects --single or --dual-static"
      ;;
  esac

  list_outputs
  count="$(connected_count)"
  printf '  connected: %s\n' "$count"
  printf '  required:  %s\n' "$required"

  if [[ "$count" -lt "$required" ]]; then
    die "connected DRM outputs below required count for $MODE: $count < $required"
  fi
  printf 'Output validation passed for %s\n' "$MODE"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sysfs)
      shift
      SYSFS="${1:-}"
      [[ -n "$SYSFS" ]] || die "--sysfs requires a directory"
      ;;
    --single|--dual-static)
      MODE="$1"
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown outputs option: $1"
      ;;
  esac
  shift
done

case "$ACTION" in
  list)
    list_outputs
    ;;
  validate)
    validate_outputs
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown outputs action: $ACTION"
    ;;
esac
