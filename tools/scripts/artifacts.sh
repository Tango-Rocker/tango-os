#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
ACTION="${1:-help}"
shift || true
OUT_DIR="${ENGINEOS_OUT_DIR:-$ROOT/out}"

usage() {
  cat <<'HELP'
Usage: artifacts.sh list [out-dir]
       artifacts.sh checksum [out-dir]
       artifacts.sh export <dest-dir> [out-dir]

List, checksum, or export built EngineOS ISO artifacts.
HELP
}

iso_files() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f -name '*.iso' -print 2>/dev/null | sort
}

require_iso_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || die "artifact directory missing: $dir"
  if ! iso_files "$dir" | grep -q .; then
    die "no ISO artifacts found in: $dir"
  fi
}

list_artifacts() {
  local dir="${1:-$OUT_DIR}"
  require_iso_dir "$dir"
  iso_files "$dir"
  find "$dir" -maxdepth 1 -type f -name '*.iso.sha256' -print 2>/dev/null | sort
}

checksum_artifacts() {
  local dir="${1:-$OUT_DIR}"
  local iso
  require_iso_dir "$dir"
  have_cmd sha256sum || die "sha256sum is required for artifact checksums"

  while IFS= read -r iso; do
    (cd "$(dirname "$iso")" && sha256sum "$(basename "$iso")" >"$(basename "$iso").sha256")
    printf 'checksum: %s.sha256\n' "$iso"
  done < <(iso_files "$dir")
}

export_artifacts() {
  local dest="${1:-}"
  local dir="${2:-$OUT_DIR}"
  local artifact
  [[ -n "$dest" ]] || die "artifact export requires a destination directory"
  require_iso_dir "$dir"
  mkdir -p "$dest"

  checksum_artifacts "$dir" >/dev/null
  while IFS= read -r artifact; do
    cp -f "$artifact" "$dest/"
    printf 'exported: %s\n' "$dest/$(basename "$artifact")"
  done < <(
    {
      iso_files "$dir"
      find "$dir" -maxdepth 1 -type f -name '*.iso.sha256' -print 2>/dev/null
    } | sort
  )
}

case "$ACTION" in
  list)
    list_artifacts "$@"
    ;;
  checksum)
    checksum_artifacts "$@"
    ;;
  export)
    export_artifacts "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown artifacts action: $ACTION"
    ;;
esac
