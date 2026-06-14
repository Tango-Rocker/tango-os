#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
DRY_RUN=false
BUILD_DIR="${ENGINEOS_SHELL_BUILD_DIR:-$ROOT/build/shell}"

usage() {
  cat <<'HELP'
Usage: build_shell.sh [--dry-run]

Build the local EngineOS wlroots shell source with Meson.
Real builds must run where wlroots and Wayland development files are installed.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown build_shell option: $1"
      ;;
  esac
  shift
done

"$SCRIPT_DIR/preflight.sh" repo --package engineos-shell

if [[ "$DRY_RUN" == true ]]; then
  printf 'EngineOS shell build dry-run\n'
  printf '  root:      %s\n' "$ROOT"
  printf '  source:    %s/shell\n' "$ROOT"
  printf '  build dir: %s\n' "$BUILD_DIR"
  printf '  setup:     meson setup %s %s/shell --prefix=/usr\n' "$BUILD_DIR" "$ROOT"
  printf '  compile:   meson compile -C %s\n' "$BUILD_DIR"
  exit 0
fi

have_cmd meson || die "meson is missing"
have_cmd ninja || die "ninja is missing"
have_cmd pkg-config || die "pkg-config is missing"
pkg-config --exists wlroots-0.19 || die "wlroots0.19 development files are missing"
pkg-config --exists wayland-server || die "wayland-server development files are missing"
pkg-config --exists xkbcommon || die "xkbcommon development files are missing"

if [[ ! -d "$BUILD_DIR" ]]; then
  meson setup "$BUILD_DIR" "$ROOT/shell" --prefix=/usr
fi
meson compile -C "$BUILD_DIR"
