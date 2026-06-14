#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
MODE="host"
DOCTOR_ARGS=()
ENGINEOS_LOG_DIR_OVERRIDE="${ENGINEOS_LOG_DIR-}"

usage() {
  cat <<'HELP'
Usage: crash_bundle.sh [--vm|--runtime|--bare-metal]

Collect EngineOS logs and machine state into a timestamped crash bundle.
Use --vm inside EngineDev test VMs, --runtime inside runtime VM proofs, and
--bare-metal on the target AMD machine.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)
      MODE="vm"
      DOCTOR_ARGS=(--vm)
      ;;
    --runtime)
      MODE="runtime"
      DOCTOR_ARGS=(--vm)
      ;;
    --bare-metal)
      MODE="bare-metal"
      DOCTOR_ARGS=(--bare-metal)
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown crash-bundle option: $1"
      ;;
  esac
  shift
done

if [[ -r /etc/engineos/profile.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/engineos/profile.conf
fi
if [[ -n "$ENGINEOS_LOG_DIR_OVERRIDE" ]]; then
  ENGINEOS_LOG_DIR="$ENGINEOS_LOG_DIR_OVERRIDE"
fi

if engineos_is_source_root "$ROOT"; then
  DEFAULT_LOG_DIR="$(engineos_default_log_dir "$ROOT")"
  DEFAULT_BUNDLE_DIR="$ROOT/artifacts/crash-bundles/$STAMP"
else
  DEFAULT_LOG_DIR="$(engineos_default_log_dir "$ROOT")"
  DEFAULT_BUNDLE_DIR="/var/log/engineos/crash-bundles/$STAMP"
fi

BUNDLE_DIR="${ENGINEOS_CRASH_BUNDLE_DIR:-$DEFAULT_BUNDLE_DIR}"
LOG_DIR="${ENGINEOS_LOG_DIR:-$DEFAULT_LOG_DIR}"

mkdir -p "$BUNDLE_DIR"

write_command() {
  local out_file="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    "$@" 2>&1 || true
  } >"$out_file"
}

write_unavailable() {
  local out_file="$1"
  local label="$2"
  printf '%s unavailable\n' "$label" >"$out_file"
}

{
  printf 'EngineOS crash bundle\n'
  printf 'created_utc=%s\n' "$STAMP"
  printf 'mode=%s\n' "$MODE"
  printf 'root=%s\n' "$ROOT"
  printf 'log_dir=%s\n' "$LOG_DIR"
  printf 'uname='
  uname -a 2>/dev/null || true
  printf 'virt='
  systemd-detect-virt 2>/dev/null || true
  printf 'cmdline='
  cat /proc/cmdline 2>/dev/null || true
} >"$BUNDLE_DIR/metadata.txt"

if [[ -x "$SCRIPT_DIR/doctor.sh" ]]; then
  write_command "$BUNDLE_DIR/doctor.txt" "$SCRIPT_DIR/doctor.sh" "${DOCTOR_ARGS[@]}"
fi

if command -v pacman >/dev/null 2>&1; then
  write_command "$BUNDLE_DIR/pacman-engineos.txt" pacman -Q archiso mesa wlroots wayland pipewire wireplumber engineos-config engineos-cli engineos-agent-tools engineos-shell engineos-engine-runner engineos-quakespasm engineos-quake-template
  write_command "$BUNDLE_DIR/pacman-local-repo.txt" pacman -Sl engineos
fi

if [[ -x "$ROOT/tools/engineos/engineos" ]]; then
  ENGINEOS="$ROOT/tools/engineos/engineos"
elif command -v engineos >/dev/null 2>&1; then
  ENGINEOS="$(command -v engineos)"
else
  ENGINEOS=""
fi

if [[ -n "$ENGINEOS" ]]; then
  write_command "$BUNDLE_DIR/engine-status.txt" "$ENGINEOS" engine status
  write_command "$BUNDLE_DIR/outputs.txt" "$ENGINEOS" outputs list
  write_command "$BUNDLE_DIR/assets-quake.txt" "$ENGINEOS" assets check quake
  write_command "$BUNDLE_DIR/assets-quake-explain.txt" "$ENGINEOS" assets explain quake
  write_command "$BUNDLE_DIR/assets-quake-path.txt" "$ENGINEOS" assets path quake
  write_command "$BUNDLE_DIR/preflight-scripts.txt" "$ENGINEOS" preflight scripts
fi

mkdir -p "$BUNDLE_DIR/network"
{
  printf 'EngineOS network snapshot\n'
  printf 'created_utc=%s\n' "$STAMP"
  printf 'hostname='
  hostname 2>/dev/null || true
  printf 'XDG_SESSION_TYPE=%s\n' "${XDG_SESSION_TYPE:-unset}"
  printf 'NetworkManager.service='
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active NetworkManager.service 2>/dev/null || true
  else
    printf 'systemctl-unavailable\n'
  fi
  printf 'default_route='
  if command -v ip >/dev/null 2>&1; then
    ip route show default 2>/dev/null | head -n 1 || true
  else
    printf 'ip-unavailable\n'
  fi
} >"$BUNDLE_DIR/network-summary.txt"

if command -v ip >/dev/null 2>&1; then
  write_command "$BUNDLE_DIR/network/ip-address.txt" ip addr show
  write_command "$BUNDLE_DIR/network/ip-route.txt" ip route show
else
  write_unavailable "$BUNDLE_DIR/network/ip-address.txt" "ip addr"
  write_unavailable "$BUNDLE_DIR/network/ip-route.txt" "ip route"
fi

if command -v resolvectl >/dev/null 2>&1; then
  write_command "$BUNDLE_DIR/network/resolvectl-status.txt" resolvectl status
else
  write_unavailable "$BUNDLE_DIR/network/resolvectl-status.txt" "resolvectl status"
fi

if command -v nmcli >/dev/null 2>&1; then
  write_command "$BUNDLE_DIR/network/nmcli-general.txt" nmcli general status
  write_command "$BUNDLE_DIR/network/nmcli-device.txt" nmcli device status
else
  write_unavailable "$BUNDLE_DIR/network/nmcli-general.txt" "nmcli general status"
  write_unavailable "$BUNDLE_DIR/network/nmcli-device.txt" "nmcli device status"
fi

if [[ -r /etc/resolv.conf ]]; then
  cp /etc/resolv.conf "$BUNDLE_DIR/network/resolv.conf" 2>/dev/null || true
fi
if [[ -r /etc/hosts ]]; then
  cp /etc/hosts "$BUNDLE_DIR/network/hosts" 2>/dev/null || true
fi

mkdir -p "$BUNDLE_DIR/config"
for config in \
  /etc/engineos/profile.conf \
  /etc/engineos/runtime.conf \
  /etc/engineos/quake.conf; do
  if [[ -r "$config" ]]; then
    cp "$config" "$BUNDLE_DIR/config/$(basename "$config")" 2>/dev/null || true
  fi
done

if [[ -d "$LOG_DIR" ]]; then
  mkdir -p "$BUNDLE_DIR/logs"
  cp -R "$LOG_DIR"/. "$BUNDLE_DIR/logs/" 2>/dev/null || true
fi

if command -v systemctl >/dev/null 2>&1; then
  for unit in \
    NetworkManager.service \
    engineos-live-setup.service \
    engineos-engine-runner.service \
    engineos-runtime.service \
    engineos-shell.service; do
    write_command "$BUNDLE_DIR/systemctl-$unit.txt" systemctl status "$unit" --no-pager
  done
fi

if command -v journalctl >/dev/null 2>&1; then
  journalctl -b --no-pager >"$BUNDLE_DIR/journal-current-boot.log" 2>/dev/null || true
  journalctl -b -u engineos-shell --no-pager >"$BUNDLE_DIR/journal-engineos-shell.log" 2>/dev/null || true
  journalctl -b -u engineos-engine-runner --no-pager >"$BUNDLE_DIR/journal-engineos-engine-runner.log" 2>/dev/null || true
  journalctl -b -u engineos-runtime --no-pager >"$BUNDLE_DIR/journal-engineos-runtime.log" 2>/dev/null || true
fi

printf '%s\n' "$BUNDLE_DIR"
