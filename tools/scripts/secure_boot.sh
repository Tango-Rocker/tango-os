#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
ACTION="${1:-help}"
shift || true

usage() {
  cat <<'HELP'
Usage: secure_boot.sh keys create [--out-dir <dir>] [--common-name <name>] [--force] [--dry-run]
       secure_boot.sh keys status [--key-dir <dir>]
       secure_boot.sh sign-iso --iso <path> [--out <path>] [--key-dir <dir>] [--dry-run]
       secure_boot.sh enroll-handoff [--key-dir <dir>]

Create and use an EngineOS-owned Secure Boot db signing key.

The generated private key is local secret material. By default it is written
under artifacts/secure-boot/keys, which is ignored by git.
HELP
}

default_key_dir() {
  printf '%s\n' "${ENGINEOS_SECURE_BOOT_KEY_DIR:-$ROOT/artifacts/secure-boot/keys}"
}

default_common_name() {
  printf '%s\n' "EngineOS Secure Boot"
}

key_path() {
  local key_dir="$1"
  local name="$2"
  printf '%s/%s\n' "$key_dir" "$name"
}

require_key_material() {
  local key_dir="$1"
  [[ -f "$(key_path "$key_dir" db.key)" ]] || die "missing Secure Boot private key: $(key_path "$key_dir" db.key)"
  [[ -f "$(key_path "$key_dir" db.crt)" ]] || die "missing Secure Boot certificate: $(key_path "$key_dir" db.crt)"
}

print_key_summary() {
  local key_dir="$1"
  printf 'EngineOS Secure Boot key material\n'
  printf '  key_dir: %s\n' "$key_dir"
  printf '  private: %s\n' "$(key_path "$key_dir" db.key)"
  printf '  cert:    %s\n' "$(key_path "$key_dir" db.crt)"
  printf '  enroll:  %s\n' "$(key_path "$key_dir" db.cer)"
  if [[ -f "$(key_path "$key_dir" db.esl)" ]]; then
    printf '  esl:     %s\n' "$(key_path "$key_dir" db.esl)"
  fi
}

keys_create() {
  local out_dir common_name force dry_run
  out_dir="$(default_key_dir)"
  common_name="$(default_common_name)"
  force=false
  dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out-dir)
        shift
        out_dir="${1:-}"
        [[ -n "$out_dir" ]] || die "--out-dir requires a directory"
        ;;
      --common-name)
        shift
        common_name="${1:-}"
        [[ -n "$common_name" ]] || die "--common-name requires a value"
        ;;
      --force)
        force=true
        ;;
      --dry-run)
        dry_run=true
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown secure_boot keys create option: $1"
        ;;
    esac
    shift
  done

  printf 'EngineOS Secure Boot key creation\n'
  printf '  out_dir:     %s\n' "$out_dir"
  printf '  common name: %s\n' "$common_name"
  printf '  force:       %s\n' "$force"

  if [[ "$dry_run" == true ]]; then
    printf '  command: '
    quote_cmd openssl req -new -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
      -subj "/CN=$common_name/" \
      -keyout "$(key_path "$out_dir" db.key)" \
      -out "$(key_path "$out_dir" db.crt)"
    printf '  export:  openssl x509 -outform DER -in %q -out %q\n' \
      "$(key_path "$out_dir" db.crt)" "$(key_path "$out_dir" db.cer)"
    printf '\nNo key material was written.\n'
    return
  fi

  have_cmd openssl || die "openssl is required to create Secure Boot keys"

  if [[ -e "$(key_path "$out_dir" db.key)" || -e "$(key_path "$out_dir" db.crt)" || -e "$(key_path "$out_dir" db.cer)" ]]; then
    [[ "$force" == true ]] || die "Secure Boot key material already exists in $out_dir; use --force only if you intend to replace it"
  fi

  install -d -m 0700 "$out_dir"
  openssl req -new -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -subj "/CN=$common_name/" \
    -keyout "$(key_path "$out_dir" db.key)" \
    -out "$(key_path "$out_dir" db.crt)"
  chmod 0600 "$(key_path "$out_dir" db.key)"
  openssl x509 -outform DER -in "$(key_path "$out_dir" db.crt)" -out "$(key_path "$out_dir" db.cer)"

  if have_cmd cert-to-efi-sig-list; then
    local owner_guid
    if have_cmd uuidgen; then
      owner_guid="$(uuidgen)"
    else
      owner_guid="11111111-2222-3333-4444-555555555555"
    fi
    cert-to-efi-sig-list -g "$owner_guid" "$(key_path "$out_dir" db.crt)" "$(key_path "$out_dir" db.esl)" >/dev/null
  fi

  print_key_summary "$out_dir"
  printf '\nKeep db.key private. Enroll db.cer in firmware Secure Boot db as an appended allowed certificate.\n'
}

keys_status() {
  local key_dir
  key_dir="$(default_key_dir)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key-dir)
        shift
        key_dir="${1:-}"
        [[ -n "$key_dir" ]] || die "--key-dir requires a directory"
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown secure_boot keys status option: $1"
        ;;
    esac
    shift
  done

  print_key_summary "$key_dir"
  require_key_material "$key_dir"
  [[ -f "$(key_path "$key_dir" db.cer)" ]] || die "missing enrollment certificate: $(key_path "$key_dir" db.cer)"
  printf 'status: ready\n'
}

iso_default_out() {
  local iso="$1"
  case "$iso" in
    *.iso)
      printf '%s-secureboot.iso\n' "${iso%.iso}"
      ;;
    *)
      printf '%s-secureboot.iso\n' "$iso"
      ;;
  esac
}

sign_efi_file() {
  local key_dir="$1"
  local input="$2"
  local output="$3"
  chmod u+w "$input"
  sbsign --key "$(key_path "$key_dir" db.key)" --cert "$(key_path "$key_dir" db.crt)" --output "$output" "$input" >/dev/null
}

find_uefi_eltorito_image() {
  local tmp_dir="$1"
  local image=""
  image="$(find "$tmp_dir" -maxdepth 1 -type f -iname '*uefi*.img' -print -quit 2>/dev/null || true)"
  if [[ -z "$image" ]]; then
    image="$(find "$tmp_dir" -maxdepth 1 -type f -iname 'eltorito_img*.img' -print | sort | tail -n 1 || true)"
  fi
  [[ -n "$image" ]] || die "could not find extracted UEFI El Torito image under $tmp_dir"
  printf '%s\n' "$image"
}

sign_iso() {
  local iso_path out_path key_dir dry_run tmp_dir boot_file kernel_file uefi_image
  local signed_boot signed_kernel out_dirname
  iso_path=""
  out_path=""
  key_dir="$(default_key_dir)"
  dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iso)
        shift
        iso_path="${1:-}"
        [[ -n "$iso_path" ]] || die "--iso requires a path"
        ;;
      --out)
        shift
        out_path="${1:-}"
        [[ -n "$out_path" ]] || die "--out requires a path"
        ;;
      --key-dir)
        shift
        key_dir="${1:-}"
        [[ -n "$key_dir" ]] || die "--key-dir requires a directory"
        ;;
      --dry-run)
        dry_run=true
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown secure_boot sign-iso option: $1"
        ;;
    esac
    shift
  done

  [[ -n "$iso_path" ]] || die "sign-iso requires --iso <path>"
  [[ -n "$out_path" ]] || out_path="$(iso_default_out "$iso_path")"

  printf 'EngineOS Secure Boot ISO signing\n'
  printf '  iso:     %s\n' "$iso_path"
  printf '  out:     %s\n' "$out_path"
  printf '  key_dir: %s\n' "$key_dir"
  printf '  dry_run: %s\n' "$dry_run"

  if [[ "$dry_run" == true ]]; then
    printf '  requires: openssl sbsign xorriso osirrox mcopy\n'
    printf '  signs:    /EFI/BOOT/BOOTx64.EFI and /arch/boot/x86_64/vmlinuz-linux\n'
    printf '  command:  secure_boot.sh sign-iso --iso %q --out %q --key-dir %q\n' "$iso_path" "$out_path" "$key_dir"
    return
  fi

  [[ -f "$iso_path" ]] || die "ISO not found: $iso_path"
  [[ "$iso_path" == *.iso ]] || die "Secure Boot signing input must be an .iso file: $iso_path"
  [[ "$out_path" != "$iso_path" ]] || die "--out must not overwrite the input ISO"
  out_dirname="$(dirname "$out_path")"
  [[ -d "$out_dirname" ]] || die "output directory does not exist: $out_dirname"
  iso_path="$(cd "$(dirname "$iso_path")" && pwd -P)/$(basename "$iso_path")"
  out_path="$(cd "$out_dirname" && pwd -P)/$(basename "$out_path")"
  require_key_material "$key_dir"
  have_cmd sbsign || die "sbsign is required; install sbsigntools"
  have_cmd osirrox || die "osirrox is required; install libisoburn"
  have_cmd xorriso || die "xorriso is required; install libisoburn"
  have_cmd mcopy || die "mcopy is required; install mtools"

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/engineos-secure-boot-XXXXXX")"
  cleanup_sign_iso() {
    rm -rf "${tmp_dir:-}"
  }
  trap cleanup_sign_iso RETURN

  (
    cd "$tmp_dir"
    osirrox -indev "$iso_path" -extract_boot_images . \
      -extract EFI/BOOT/BOOTx64.EFI BOOTx64.EFI \
      -extract arch/boot/x86_64/vmlinuz-linux vmlinuz-linux >/dev/null
  )

  uefi_image="$(find_uefi_eltorito_image "$tmp_dir")"
  boot_file="$tmp_dir/BOOTx64.EFI"
  kernel_file="$tmp_dir/vmlinuz-linux"
  signed_boot="$tmp_dir/BOOTx64.EFI.signed"
  signed_kernel="$tmp_dir/vmlinuz-linux.signed"

  [[ -f "$boot_file" ]] || die "ISO is missing /EFI/BOOT/BOOTx64.EFI"
  [[ -f "$kernel_file" ]] || die "ISO is missing /arch/boot/x86_64/vmlinuz-linux"

  sign_efi_file "$key_dir" "$boot_file" "$signed_boot"
  sign_efi_file "$key_dir" "$kernel_file" "$signed_kernel"

  mcopy -D oO -i "$uefi_image" "$signed_boot" ::/EFI/BOOT/BOOTx64.EFI >/dev/null

  xorriso \
    -indev "$iso_path" \
    -outdev "$out_path" \
    -boot_image any replay \
    -append_partition 2 0xef "$uefi_image" \
    -map "$signed_boot" /EFI/BOOT/BOOTx64.EFI \
    -map "$signed_kernel" /arch/boot/x86_64/vmlinuz-linux >/dev/null

  (cd "$(dirname "$out_path")" && sha256sum "$(basename "$out_path")" >"$(basename "$out_path").sha256")
  printf 'Signed ISO written: %s\n' "$out_path"
  printf 'Checksum written:   %s.sha256\n' "$out_path"
}

enroll_handoff() {
  local key_dir
  key_dir="$(default_key_dir)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key-dir)
        shift
        key_dir="${1:-}"
        [[ -n "$key_dir" ]] || die "--key-dir requires a directory"
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown secure_boot enroll-handoff option: $1"
        ;;
    esac
    shift
  done

  print_key_summary "$key_dir"
  cat <<HELP

Firmware enrollment handoff:
  1. Copy db.cer to a small FAT-formatted USB stick.
  2. Enter firmware setup.
  3. Open Secure Boot key management.
  4. Append or enroll db.cer into the allowed signature database, usually named db.
  5. Do not clear existing Microsoft keys if this machine still boots Windows.
  6. Boot an ISO produced by: engineos secure-boot sign-iso --iso <EngineOS.iso>

If the firmware only supports replacing keys, stop and use the temporary
Secure Boot disable path instead. Replacing keys can break Windows boot.
HELP
}

case "$ACTION" in
  keys)
    subaction="${1:-help}"
    shift || true
    case "$subaction" in
      create)
        keys_create "$@"
        ;;
      status)
        keys_status "$@"
        ;;
      help|--help|-h)
        usage
        ;;
      *)
        die "unknown secure_boot keys action: $subaction"
        ;;
    esac
    ;;
  sign-iso)
    sign_iso "$@"
    ;;
  enroll-handoff)
    enroll_handoff "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown secure_boot action: $ACTION"
    ;;
esac
