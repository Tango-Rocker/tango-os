#!/usr/bin/env bash
set -euo pipefail

ROOT="${ENGINEOS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)}"
UPSTREAM="${QUAKESPASM_UPSTREAM_DIR:-$ROOT/engines/quakespasm/upstream}"
BUILD_DIR="$UPSTREAM/Quake"
if [[ "$ROOT" == /usr || "$ROOT" == /usr/* || ! -d "$ROOT/tools" ]]; then
  LOG_DIR="${ENGINEOS_LOG_DIR:-/var/log/engineos}"
else
  LOG_DIR="${ENGINEOS_LOG_DIR:-$ROOT/artifacts/logs}"
fi
JOBS="${ENGINEOS_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')}"
CC_BIN="${CC:-cc}"
MP3LIB="${QUAKESPASM_MP3LIB:-mpg123}"
VORBISLIB="${QUAKESPASM_VORBISLIB:-vorbis}"
DRY_RUN=false
FETCH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --fetch)
      FETCH=true
      ;;
    --help|-h)
      cat <<'HELP'
Usage: build.sh [--dry-run] [--fetch]

Build QuakeSpasm from engines/quakespasm/upstream.
The upstream project builds from the Quake subdirectory.
HELP
      exit 0
      ;;
    *)
      printf 'quakespasm build: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$DRY_RUN" == true ]]; then
  printf 'QuakeSpasm build dry-run\n'
  printf '  upstream: %s\n' "$UPSTREAM"
  printf '  build:    %s\n' "$BUILD_DIR"
  if [[ "$FETCH" == true ]]; then
    printf '  fetch:    %s/engines/quakespasm/engineos/fetch.sh\n' "$ROOT"
  fi
  printf '  command:  make -C %s USE_SDL2=1 MP3LIB=%s VORBISLIB=%s -j%s\n' "$BUILD_DIR" "$MP3LIB" "$VORBISLIB" "$JOBS"
  exit 0
fi

mkdir -p "$LOG_DIR"

command -v make >/dev/null 2>&1 || {
  printf 'make is required to build QuakeSpasm\n' >&2
  exit 1
}
command -v "$CC_BIN" >/dev/null 2>&1 || {
  printf 'C compiler is required to build QuakeSpasm: %s\n' "$CC_BIN" >&2
  exit 1
}
command -v sdl2-config >/dev/null 2>&1 || {
  printf 'sdl2-config is required to build QuakeSpasm with USE_SDL2=1\n' >&2
  printf 'On the Arch builder VM, run: ./tools/engineos/engineos bootstrap builder\n' >&2
  exit 1
}

if [[ "$FETCH" == true ]]; then
  if [[ -x "$ROOT/engines/quakespasm/engineos/fetch.sh" ]]; then
    "$ROOT/engines/quakespasm/engineos/fetch.sh"
  elif [[ -x "/usr/share/engineos/quake/fetch.sh" ]]; then
    "/usr/share/engineos/quake/fetch.sh"
  else
    printf 'QuakeSpasm fetch script is missing\n' >&2
    exit 1
  fi
fi

[[ -d "$UPSTREAM" ]] || {
  printf 'QuakeSpasm upstream source is missing: %s\n' "$UPSTREAM" >&2
  printf 'Run: engineos build engine quake --fetch\n' >&2
  exit 1
}

[[ -d "$BUILD_DIR" ]] || {
  printf 'QuakeSpasm build directory is missing: %s\n' "$BUILD_DIR" >&2
  exit 1
}

{
  printf '[%s] build quakespasm\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'upstream=%s\n' "$UPSTREAM"
  printf 'build_dir=%s\n' "$BUILD_DIR"
  printf 'mp3lib=%s\n' "$MP3LIB"
  printf 'vorbislib=%s\n' "$VORBISLIB"
  make -C "$BUILD_DIR" USE_SDL2=1 MP3LIB="$MP3LIB" VORBISLIB="$VORBISLIB" -j"$JOBS"
} 2>&1 | tee -a "$LOG_DIR/engine-build.log"

if [[ -x "$BUILD_DIR/quakespasm" ]]; then
  printf 'QuakeSpasm binary built: %s\n' "$BUILD_DIR/quakespasm" | tee -a "$LOG_DIR/engine-build.log"
else
  printf 'QuakeSpasm build finished, but binary was not found at %s\n' "$BUILD_DIR/quakespasm" | tee -a "$LOG_DIR/engine-build.log" >&2
  exit 1
fi
