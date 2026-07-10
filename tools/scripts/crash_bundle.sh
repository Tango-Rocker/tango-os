#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
APPS_MANIFEST="$(engineos_apps_manifest "$ROOT")"
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
STATE_DIR="${ENGINEOS_STATE_DIR:-$(engineos_default_state_dir "$ROOT")}"
SHELL_STATE_FILE="$STATE_DIR/shell-state.json"

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
  printf 'state_dir=%s\n' "$STATE_DIR"
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
  write_command "$BUNDLE_DIR/pacman-engineos.txt" bash -lc "pacman -Q | awk '\$1 ~ /^(archiso|mesa|wlroots|wayland|pipewire|wireplumber)$/ || \$1 ~ /^engineos-/ {print}'"
  write_command "$BUNDLE_DIR/pacman-local-repo.txt" pacman -Sl engineos
fi

eos_tool_path() {
  local tool="$1"
  if [[ -x "$ROOT/tools/engineos/$tool" ]]; then
    printf '%s\n' "$ROOT/tools/engineos/$tool"
    return 0
  fi
  command -v "$tool" 2>/dev/null
}

EOS_APP="$(eos_tool_path eos-app || true)"
EOS_RUNTIME="$(eos_tool_path eos-runtime || true)"
EOS_OUTPUTS="$(eos_tool_path eos-outputs || true)"
EOS_ASSETS="$(eos_tool_path eos-assets || true)"
EOS_PREFLIGHT="$(eos_tool_path eos-preflight || true)"

if [[ -n "$EOS_APP" ]]; then
  write_command "$BUNDLE_DIR/app-status.json" "$EOS_APP" status --json
  write_command "$BUNDLE_DIR/app-manifest-validate.txt" "$EOS_APP" manifest validate
fi
if [[ -n "$EOS_RUNTIME" ]]; then
  write_command "$BUNDLE_DIR/engine-status.txt" "$EOS_RUNTIME" engine status
fi
if [[ -n "$EOS_OUTPUTS" ]]; then
  write_command "$BUNDLE_DIR/outputs.txt" "$EOS_OUTPUTS" list
fi
if [[ -n "$EOS_ASSETS" ]]; then
  write_command "$BUNDLE_DIR/assets-quake.txt" "$EOS_ASSETS" check quake
  write_command "$BUNDLE_DIR/assets-quake-explain.txt" "$EOS_ASSETS" explain quake
  write_command "$BUNDLE_DIR/assets-quake-path.txt" "$EOS_ASSETS" path quake
fi
if [[ -n "$EOS_PREFLIGHT" ]]; then
  write_command "$BUNDLE_DIR/preflight-scripts.txt" "$EOS_PREFLIGHT" scripts
fi

mkdir -p "$BUNDLE_DIR/state"
if [[ -r "$SHELL_STATE_FILE" ]]; then
  cp "$SHELL_STATE_FILE" "$BUNDLE_DIR/state/shell-state.json" 2>/dev/null || true
else
  printf 'shell state unavailable: %s\n' "$SHELL_STATE_FILE" >"$BUNDLE_DIR/state/shell-state.json"
fi
if [[ -d "$STATE_DIR/apps" ]]; then
  mkdir -p "$BUNDLE_DIR/state/apps"
  cp -R "$STATE_DIR/apps"/. "$BUNDLE_DIR/state/apps/" 2>/dev/null || true
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
if [[ -r "$APPS_MANIFEST" ]]; then
  cp "$APPS_MANIFEST" "$BUNDLE_DIR/config/apps.toml" 2>/dev/null || true
fi

if [[ -d "$LOG_DIR" ]]; then
  mkdir -p "$BUNDLE_DIR/logs"
  cp -R "$LOG_DIR"/. "$BUNDLE_DIR/logs/" 2>/dev/null || true
fi

if command -v systemctl >/dev/null 2>&1; then
	for unit in \
		NetworkManager.service \
		engineos-live-setup.service \
		engineos-runtime.service \
		engineos-shell.service; do
		write_command "$BUNDLE_DIR/systemctl-$unit.txt" systemctl status "$unit" --no-pager
	done
	write_command "$BUNDLE_DIR/systemctl-user-engineos-quake.service.txt" \
		systemctl --user status engineos-quake.service --no-pager
	write_command "$BUNDLE_DIR/systemctl-user-engineos-level-agent.service.txt" \
		systemctl --user status engineos-level-agent.service --no-pager
fi

if command -v journalctl >/dev/null 2>&1; then
  journalctl -b --no-pager >"$BUNDLE_DIR/journal-current-boot.log" 2>/dev/null || true
  journalctl -b -u engineos-shell --no-pager >"$BUNDLE_DIR/journal-engineos-shell.log" 2>/dev/null || true
	journalctl --user -b -u engineos-quake --no-pager >"$BUNDLE_DIR/journal-engineos-quake.log" 2>/dev/null || true
	journalctl --user -b -u engineos-level-agent --no-pager >"$BUNDLE_DIR/journal-engineos-level-agent.log" 2>/dev/null || true
  journalctl -b -u engineos-runtime --no-pager >"$BUNDLE_DIR/journal-engineos-runtime.log" 2>/dev/null || true
fi

printf '%s\n' "$BUNDLE_DIR"
