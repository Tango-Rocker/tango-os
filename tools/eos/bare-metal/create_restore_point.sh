#!/usr/bin/env bash
set -euo pipefail

BOOT_DIR="${ENGINEOS_BOOT_DIR:-/boot}"
LABEL=""
DRY_RUN=false
MAKE_DEFAULT=false

usage() {
  cat <<'HELP'
Usage: create_restore_point.sh [--label <name>] [--default] [--dry-run]

Create a systemd-boot restore entry from the currently installed kernel and
initramfs. This is a boot fallback, not a full root filesystem snapshot.
HELP
}

die() {
  printf 'create_restore_point.sh: %s\n' "$*" >&2
  exit 1
}

say() {
  printf '%s\n' "$*"
}

run_or_print() {
  if "$DRY_RUN"; then
    printf 'DRY-RUN'
    printf ' %q' "$@"
    printf '\n'
    return
  fi
  "$@"
}

sanitize_label() {
  local value="$1"
  value="${value,,}"
  value="${value// /-}"
  value="${value//_/-}"
  value="$(printf '%s' "$value" | tr -cd 'a-z0-9.-')"
  value="${value##[-.]}"
  value="${value%%[-.]}"
  printf '%s\n' "$value"
}

current_root_options() {
  local entry="$BOOT_DIR/loader/entries/enginedev.conf"
  if [[ -r "$entry" ]]; then
    awk '
      $1 == "options" {
        sub(/^[[:space:]]*options[[:space:]]+/, "", $0)
        print
        exit
      }
    ' "$entry"
    return
  fi

  if command -v findmnt >/dev/null 2>&1; then
    local uuid=""
    uuid="$(findmnt -no UUID / 2>/dev/null || true)"
    if [[ -n "$uuid" ]]; then
      printf 'root=UUID=%s rw\n' "$uuid"
      return
    fi
  fi

  die "could not determine root options from $entry or findmnt"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      LABEL="${2:-}"
      [[ -n "$LABEL" ]] || die "--label requires a value"
      shift 2
      ;;
    --default)
      MAKE_DEFAULT=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

timestamp="$(date -u +%Y%m%d-%H%M%S)"
if [[ -n "$LABEL" ]]; then
  safe_label="$(sanitize_label "$LABEL")"
else
  safe_label="$timestamp"
fi
[[ -n "$safe_label" ]] || die "label has no usable characters"

kernel_src="$BOOT_DIR/vmlinuz-linux"
initramfs_src="$BOOT_DIR/initramfs-linux.img"
entry_dir="$BOOT_DIR/loader/entries"
loader_conf="$BOOT_DIR/loader/loader.conf"

[[ -r "$kernel_src" ]] || die "kernel not readable: $kernel_src"
[[ -r "$initramfs_src" ]] || die "initramfs not readable: $initramfs_src"
[[ -d "$entry_dir" ]] || die "systemd-boot entries directory missing: $entry_dir"

kernel_name="vmlinuz-linux-restore-$safe_label"
initramfs_name="initramfs-linux-restore-$safe_label.img"
entry_name="enginedev-restore-$safe_label.conf"
entry_path="$entry_dir/$entry_name"
root_options="$(current_root_options)"

if [[ -e "$BOOT_DIR/$kernel_name" || -e "$BOOT_DIR/$initramfs_name" || -e "$entry_path" ]]; then
  die "restore point already exists for label: $safe_label"
fi

run_or_print sudo install -m 0644 "$kernel_src" "$BOOT_DIR/$kernel_name"
run_or_print sudo install -m 0644 "$initramfs_src" "$BOOT_DIR/$initramfs_name"

entry_content="$(cat <<EOF
title EngineDev OS restore $safe_label
linux /$kernel_name
initrd /$initramfs_name
options $root_options
EOF
)"

if "$DRY_RUN"; then
  say "DRY-RUN write $entry_path"
  printf '%s\n' "$entry_content"
else
  printf '%s\n' "$entry_content" | sudo tee "$entry_path" >/dev/null
fi

if "$MAKE_DEFAULT"; then
  if "$DRY_RUN"; then
    say "DRY-RUN set default $entry_name in $loader_conf"
  else
    if [[ -r "$loader_conf" ]] && grep -Eq '^[[:space:]]*default[[:space:]]+' "$loader_conf"; then
      sudo sed -i "s|^[[:space:]]*default[[:space:]].*|default $entry_name|" "$loader_conf"
    else
      printf 'default %s\n' "$entry_name" | sudo tee -a "$loader_conf" >/dev/null
    fi
  fi
fi

say "restore point entry: $entry_path"
say "bootloader title: EngineDev OS restore $safe_label"
