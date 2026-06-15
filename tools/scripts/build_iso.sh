#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
PROFILE="enginedev"
DRY_RUN=false
CLEAN=false
ARCHIVE_EXISTING=false
TMPFS_SIZE="${ENGINEOS_BUILD_TMPFS_SIZE:-8G}"
COMPRESSION="${ENGINEOS_ISO_COMPRESSION:-profile}"
INSTALL_CACHE="${ENGINEOS_ISO_INSTALL_CACHE:-auto}"

usage() {
  cat <<'HELP'
Usage: build_iso.sh [profile] [--dry-run] [--clean] [--archive-existing] [--fast|--compression profile|fast] [--install-cache|--no-install-cache]

Build an EngineOS archiso profile.

Examples:
  build_iso.sh --dry-run
  build_iso.sh enginedev --dry-run
  build_iso.sh enginedev --fast --clean --archive-existing
  build_iso.sh enginedev --clean --archive-existing
  build_iso.sh enginedev
HELP
}

if [[ "${1:-}" == "help" || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 && "${1:-}" != --* ]]; then
  PROFILE="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --clean)
      CLEAN=true
      ;;
    --archive-existing)
      ARCHIVE_EXISTING=true
      ;;
    --fast)
      COMPRESSION="fast"
      ;;
    --compression)
      COMPRESSION="${2:-}"
      [[ -n "$COMPRESSION" ]] || die "--compression requires profile or fast"
      shift
      ;;
    --install-cache)
      INSTALL_CACHE="true"
      ;;
    --no-install-cache)
      INSTALL_CACHE="false"
      ;;
    *)
      die "unknown build_iso option: $1"
      ;;
  esac
  shift
done

case "$COMPRESSION" in
  profile|fast)
    ;;
  *)
    die "unknown ISO compression mode: $COMPRESSION"
    ;;
esac

case "$INSTALL_CACHE" in
  auto|true|false)
    ;;
  *)
    die "unknown ISO install cache mode: $INSTALL_CACHE"
    ;;
esac

install_cache_enabled() {
  case "$INSTALL_CACHE" in
    true)
      return 0
      ;;
    false)
      return 1
      ;;
    auto)
      [[ "$PROFILE" == "enginedev" ]]
      ;;
  esac
}

PROFILE_DIR="$ROOT/archiso/$PROFILE"
PROFILE_BUILD_DIR="$PROFILE_DIR"
GENERATED_PROFILE_DIR="$ROOT/work/generated-profiles/$PROFILE-build"
WORK_DIR="${ENGINEOS_WORK_DIR:-$ROOT/work/$PROFILE}"
OUT_DIR="${ENGINEOS_OUT_DIR:-$ROOT/out}"
TMP_DIR="${ENGINEOS_TMP_DIR:-$ROOT/tmp}"
INSTALL_CACHE_DIR="/opt/engineos/install-cache/pkg"

"$SCRIPT_DIR/preflight.sh" iso --profile "$PROFILE"

if [[ "$DRY_RUN" == true ]]; then
  printf 'EngineOS ISO dry-run\n'
  printf '  root:    %s\n' "$ROOT"
  printf '  profile: %s\n' "$PROFILE"
  printf '  work:    %s\n' "$WORK_DIR"
  printf '  out:     %s\n' "$OUT_DIR"
  printf '  tmp:     %s\n' "$TMP_DIR"
  printf '  clean:   %s\n' "$CLEAN"
  printf '  archive: %s\n' "$ARCHIVE_EXISTING"
  printf '  compression: %s\n' "$COMPRESSION"
  if install_cache_enabled; then
    printf '  install cache: enabled at %s inside the live ISO\n' "$INSTALL_CACHE_DIR"
  else
    printf '  install cache: disabled\n'
  fi
  printf '  tmpfs:   remount /tmp to at least %s when /tmp is tmpfs\n' "$TMPFS_SIZE"
  if [[ "$COMPRESSION" == "fast" ]]; then
    printf '  profile copy: %s with SquashFS zstd level 3\n' "$GENERATED_PROFILE_DIR"
    PROFILE_BUILD_DIR="$GENERATED_PROFILE_DIR"
  elif install_cache_enabled; then
    printf '  profile copy: %s with embedded install package cache\n' "$GENERATED_PROFILE_DIR"
    PROFILE_BUILD_DIR="$GENERATED_PROFILE_DIR"
  fi
  if [[ "$ARCHIVE_EXISTING" == true ]]; then
    printf '  archive command: move existing %s ISO artifacts under %s/archive/<stamp>/\n' "$PROFILE" "$OUT_DIR"
  fi
  if [[ "$CLEAN" == true ]]; then
    printf '  clean command: sudo rm -rf %s\n' "$WORK_DIR"
  fi
  printf '  command: '
  quote_cmd sudo env TMPDIR="$TMP_DIR" mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_BUILD_DIR"
  printf '  checksum: %s/artifacts.sh checksum %s\n' "$SCRIPT_DIR" "$OUT_DIR"
  exit 0
fi

is_arch_linux || die "real ISO builds must run on Arch Linux"
have_cmd mkarchiso || die "mkarchiso is missing; install archiso"
have_cmd sudo || die "sudo is required for mkarchiso"

iso_prefix() {
  case "$PROFILE" in
    enginedev) printf '%s\n' EngineDevOS ;;
    engineruntime) printf '%s\n' EngineRuntimeOS ;;
    *) die "unknown ISO profile: $PROFILE" ;;
  esac
}

ensure_tmpfs_capacity() {
  local fstype=""
  if ! have_cmd findmnt; then
    return
  fi
  fstype="$(findmnt -no FSTYPE -T /tmp 2>/dev/null || true)"
  [[ "$fstype" == "tmpfs" ]] || return

  printf 'Ensuring /tmp tmpfs has build room: size=%s\n' "$TMPFS_SIZE"
  sudo -n mount -o "remount,size=$TMPFS_SIZE" /tmp ||
    die "could not remount /tmp to size=$TMPFS_SIZE; run sudo mount -o remount,size=$TMPFS_SIZE /tmp"
}

archive_existing_artifacts() {
  local prefix="$1"
  local stamp archive_dir
  local artifacts=()

  shopt -s nullglob
  artifacts=("$OUT_DIR/$prefix"-*.iso "$OUT_DIR/$prefix"-*.iso.sha256)
  shopt -u nullglob
  [[ "${#artifacts[@]}" -gt 0 ]] || return 0

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  archive_dir="$OUT_DIR/archive/$stamp"
  mkdir -p "$archive_dir"
  printf 'Archiving existing %s artifacts to %s\n' "$prefix" "$archive_dir"
  sudo -n mv "${artifacts[@]}" "$archive_dir/" ||
    die "could not archive existing ISO artifacts"
}

clean_work_dir() {
  local work_parent
  work_parent="$(cd "$ROOT/work" 2>/dev/null && pwd -P || true)"
  if [[ -z "$work_parent" ]]; then
    mkdir -p "$ROOT/work"
    work_parent="$(cd "$ROOT/work" && pwd -P)"
  fi

  case "$WORK_DIR" in
    "$work_parent"/*)
      ;;
    *)
      die "refusing to clean work directory outside $work_parent: $WORK_DIR"
      ;;
  esac

  if [[ -e "$WORK_DIR" ]]; then
    printf 'Cleaning ISO work directory: %s\n' "$WORK_DIR"
    sudo -n rm -rf "$WORK_DIR" ||
      die "could not clean $WORK_DIR"
  fi
}

prepare_profile_build_dir() {
  if [[ "$COMPRESSION" != "fast" ]] && ! install_cache_enabled; then
    return 0
  fi

  local generated_parent generated_profile
  generated_parent="$ROOT/work/generated-profiles"
  generated_profile="$GENERATED_PROFILE_DIR"

  mkdir -p "$generated_parent"
  sudo -n rm -rf "$generated_profile" ||
    die "could not clean generated profile: $generated_profile"
  cp -a "$PROFILE_DIR" "$generated_profile"
  PROFILE_BUILD_DIR="$generated_profile"

  if [[ "$COMPRESSION" == "fast" ]]; then
    have_cmd python3 || die "python3 is required to generate fast ISO profile"

    python3 - "$generated_profile/profiledef.sh" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
replacement = 'airootfs_image_tool_options=("-comp" "zstd" "-Xcompression-level" "3" "-b" "1M" "-processors" "4")'
text, count = re.subn(r'^airootfs_image_tool_options=.*$', replacement, text, flags=re.MULTILINE)
if count != 1:
    raise SystemExit(f"expected exactly one airootfs_image_tool_options line, replaced {count}")
path.write_text(text)
PY

    printf 'Using fast ISO compression profile: %s\n' "$PROFILE_BUILD_DIR"
  fi
}

populate_install_cache() {
  install_cache_enabled || return 0

  local profile_dir="$1"
  local cache_dir="$profile_dir/airootfs$INSTALL_CACHE_DIR"
  local manifest_dir="$profile_dir/airootfs/opt/engineos/install-cache"
  local db_dir="$ROOT/work/install-cache-db/$PROFILE"
  local log_file="$ROOT/work/install-cache-$PROFILE.log"
  local packages=()

  have_cmd pacman || die "pacman is required to populate the EngineDev install cache"
  mapfile -t packages < <(engineos_install_packages)

  printf 'Populating EngineDev install package cache: %s\n' "$cache_dir"
  sudo -n rm -rf "$cache_dir" "$db_dir" ||
    die "could not clean install cache staging directories"
  sudo -n install -d -m 0755 "$cache_dir" "$db_dir" ||
    die "could not create install cache staging directories"
  sudo -n pacman \
    --config "$PROFILE_DIR/pacman.conf" \
    --cachedir "$cache_dir" \
    --dbpath "$db_dir" \
    --logfile "$log_file" \
    -Syw --noconfirm --needed "${packages[@]}" ||
    die "could not populate EngineDev install package cache"

  sudo -n install -d -m 0755 "$manifest_dir" ||
    die "could not create install cache manifest directory"
  printf '%s\n' "${packages[@]}" | sudo -n tee "$manifest_dir/packages.txt" >/dev/null
  find "$cache_dir" -maxdepth 1 -type f -name '*.pkg.tar*' -printf '%f\n' 2>/dev/null |
    sort | sudo -n tee "$manifest_dir/artifacts.txt" >/dev/null
  printf 'EngineDev install package cache staged: %s\n' "$INSTALL_CACHE_DIR"
}

mkdir -p "$OUT_DIR" "$TMP_DIR" "$ROOT/work"
ensure_tmpfs_capacity
if [[ "$ARCHIVE_EXISTING" == true ]]; then
  archive_existing_artifacts "$(iso_prefix)"
fi
if [[ "$CLEAN" == true ]]; then
  clean_work_dir
fi
mkdir -p "$WORK_DIR"
prepare_profile_build_dir
populate_install_cache "$PROFILE_BUILD_DIR"
sudo env TMPDIR="$TMP_DIR" mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_BUILD_DIR"
"$SCRIPT_DIR/artifacts.sh" checksum "$OUT_DIR"
