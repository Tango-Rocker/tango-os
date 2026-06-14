#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
TARGET="${1:-}"
shift || true

usage() {
  cat <<'HELP'
Usage: build_engine.sh quake [--dry-run] [--fetch]

Build an EngineOS engine target.
HELP
}

quake_build_script() {
  if [[ -x "$ROOT/engines/quakespasm/engineos/build.sh" ]]; then
    printf '%s\n' "$ROOT/engines/quakespasm/engineos/build.sh"
  else
    printf '%s\n' "/usr/share/engineos/quake/build.sh"
  fi
}

case "$TARGET" in
  quake)
    script="$(quake_build_script)"
    [[ -x "$script" ]] || die "Quake build script missing or not executable: $script"
    exec "$script" "$@"
    ;;
  help|--help|-h|"")
    usage
    ;;
  *)
    die "unknown engine build target: $TARGET"
    ;;
esac
