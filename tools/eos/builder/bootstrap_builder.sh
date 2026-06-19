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

DRY_RUN=false
PRINT_PACKAGES=false

usage() {
  cat <<'HELP'
Usage: bootstrap_builder.sh [--dry-run|--print-packages]

Install the baseline Arch packages expected by the EngineOS builder VM.
Real installs must run on the Arch builder VM.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --print-packages)
      PRINT_PACKAGES=true
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown bootstrap_builder option: $1"
      ;;
  esac
  shift
done

mapfile -t packages < <(engineos_builder_packages)

if [[ "$PRINT_PACKAGES" == true ]]; then
  printf '%s\n' "${packages[@]}"
  exit 0
fi

printf 'EngineOS builder bootstrap\n'
printf '  packages: %s\n' "${#packages[@]}"

if [[ "$DRY_RUN" == true ]]; then
  printf '  update:   sudo pacman --noconfirm -Syu\n'
  printf '  install:  sudo pacman --noconfirm -S --needed'
  printf ' %q' "${packages[@]}"
  printf '\n'
  exit 0
fi

is_arch_linux || die "builder bootstrap must run on Arch Linux"
have_cmd sudo || die "sudo is missing"
have_cmd pacman || die "pacman is missing"

sudo pacman --noconfirm -Syu
sudo pacman --noconfirm -S --needed "${packages[@]}"
