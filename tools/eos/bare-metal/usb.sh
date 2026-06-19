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
ACTION="${1:-help}"
shift || true

usage() {
  cat <<'HELP'
Usage: usb.sh list
       usb.sh write --iso <path> --device <block-device> [--dry-run]
       usb.sh write --profile enginedev|engineruntime --device <block-device> [--out-dir <dir>] [--dry-run]

Prepare a bootable USB device from a built EngineOS ISO.

Real writes are destructive and require:
  --yes-i-understand-this-wipes-device

Prefer --dry-run first. It prints the exact write command without touching the
target device.
HELP
}

profile_iso_prefix() {
  case "$1" in
    enginedev)
      printf 'EngineDevOS'
      ;;
    engineruntime)
      printf 'EngineRuntimeOS'
      ;;
    *)
      die "unknown USB profile: $1"
      ;;
  esac
}

latest_iso_for_profile() {
  local profile="$1"
  local out_dir="$2"
  local prefix

  prefix="$(profile_iso_prefix "$profile")"
  [[ -d "$out_dir" ]] || return 1
  find "$out_dir" -maxdepth 1 -type f -name "$prefix-*.iso" -printf '%T@ %p\n' 2>/dev/null |
    sort -n |
    tail -n 1 |
    cut -d' ' -f2-
}

list_usb_devices() {
  printf 'EngineOS USB device candidates\n'
  if have_cmd lsblk; then
    lsblk -dpo NAME,SIZE,MODEL,TRAN,RM,TYPE 2>/dev/null || true
  else
    printf 'lsblk unavailable; inspect removable devices manually.\n'
  fi
}

device_has_mounts() {
  local device="$1"
  if have_cmd lsblk; then
    lsblk -nr -o MOUNTPOINT "$device" 2>/dev/null | grep -q .
  else
    return 1
  fi
}

write_usb() {
  local iso_path=""
  local device=""
  local profile=""
  local out_dir="${ENGINEOS_OUT_DIR:-$ROOT/out}"
  local dry_run=false
  local acknowledged=false
  local sudo_cmd=(sudo)
  local dd_cmd=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iso)
        shift
        iso_path="${1:-}"
        [[ -n "$iso_path" ]] || die "--iso requires a path"
        ;;
      --device)
        shift
        device="${1:-}"
        [[ -n "$device" ]] || die "--device requires a block device"
        ;;
      --profile)
        shift
        profile="${1:-}"
        [[ -n "$profile" ]] || die "--profile requires a value"
        ;;
      --out-dir)
        shift
        out_dir="${1:-}"
        [[ -n "$out_dir" ]] || die "--out-dir requires a directory"
        ;;
      --dry-run)
        dry_run=true
        ;;
      --yes-i-understand-this-wipes-device)
        acknowledged=true
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown usb write option: $1"
        ;;
    esac
    shift
  done

  if [[ -n "$profile" ]]; then
    [[ -z "$iso_path" ]] || die "use either --iso or --profile, not both"
    iso_path="$(latest_iso_for_profile "$profile" "$out_dir" || true)"
    [[ -n "$iso_path" ]] || die "no $profile ISO found in $out_dir; pass --iso <path>"
  fi

  [[ -n "$iso_path" ]] || die "usb write requires --iso <path> or --profile <name>"
  [[ -n "$device" ]] || die "usb write requires --device <block-device>"
  [[ -f "$iso_path" ]] || die "ISO not found: $iso_path"
  [[ "$iso_path" == *.iso ]] || die "USB source must be an .iso file: $iso_path"

  dd_cmd=(dd "if=$iso_path" "of=$device" bs=4M status=progress conv=fsync)

  printf 'EngineOS USB write\n'
  printf '  iso:     %s\n' "$iso_path"
  printf '  device:  %s\n' "$device"
  printf '  dry_run: %s\n' "$dry_run"

  if [[ "$dry_run" == true ]]; then
    printf '  command: '
    quote_cmd "${sudo_cmd[@]}" "${dd_cmd[@]}"
    printf '  sync:    sync\n'
    printf '\nNo data was written. Re-run without --dry-run and with --yes-i-understand-this-wipes-device after verifying the device.\n'
    return
  fi

  [[ "$acknowledged" == true ]] || die "real USB writes require --yes-i-understand-this-wipes-device"
  [[ "$device" == /dev/* ]] || die "refusing non-/dev target: $device"
  [[ -b "$device" ]] || die "target is not a block device: $device"
  have_cmd dd || die "dd is required"
  have_cmd sync || die "sync is required"
  have_cmd sudo || die "sudo is required for USB writes"

  if device_has_mounts "$device"; then
    die "target device has mounted filesystems; unmount them before writing: $device"
  fi

  printf 'About to overwrite %s with %s\n' "$device" "$iso_path"
  "${sudo_cmd[@]}" "${dd_cmd[@]}"
  sync
  printf 'USB write complete. You can now boot the target machine from %s.\n' "$device"
}

case "$ACTION" in
  list)
    list_usb_devices "$@"
    ;;
  write)
    write_usb "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown usb action: $ACTION"
    ;;
esac
