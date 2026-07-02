#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
TARGET="shell"
OUT_DIR="${ENGINEOS_CAPTURE_DIR:-$(engineos_default_capture_dir "$ROOT")}"
CAPTURE_TOOL="${ENGINEOS_CAPTURE_TOOL:-auto}"

usage() {
  cat <<'HELP'
Usage: capture_frame.sh --target shell [--tool auto|grim|import|metadata]

Capture a shell frame with grim on Wayland or ImageMagick import on X11.
Explicit --tool metadata records environment metadata without claiming a frame
capture succeeded.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      shift
      TARGET="${1:-}"
      [[ -n "$TARGET" ]] || die "--target requires a value"
      ;;
    --tool)
      shift
      CAPTURE_TOOL="${1:-}"
      [[ -n "$CAPTURE_TOOL" ]] || die "--tool requires a value"
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown capture option: $1"
      ;;
  esac
  shift
done

case "$TARGET" in
  shell)
    ;;
  *)
    die "capture currently supports only --target shell"
    ;;
esac

case "$CAPTURE_TOOL" in
  auto|grim|import|metadata)
    ;;
  *)
    die "capture tool must be auto, grim, import, or metadata"
    ;;
esac

mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
IMAGE_FILE="$OUT_DIR/${TARGET}-${STAMP}.png"
META_FILE="$OUT_DIR/${TARGET}-${STAMP}.txt"
RESULT="metadata"
TOOL_USED="metadata"
ERROR_TEXT=""

write_metadata() {
  {
    printf 'EngineOS frame capture\n'
    printf 'target=%s\n' "$TARGET"
    printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'result=%s\n' "$RESULT"
    printf 'tool=%s\n' "$TOOL_USED"
    printf 'image=%s\n' "$IMAGE_FILE"
    printf 'metadata=%s\n' "$META_FILE"
    printf 'WAYLAND_DISPLAY=%s\n' "${WAYLAND_DISPLAY:-unset}"
    printf 'DISPLAY=%s\n' "${DISPLAY:-unset}"
    if [[ -n "$ERROR_TEXT" ]]; then
      printf 'error=%s\n' "$ERROR_TEXT"
    fi
    if [[ "$RESULT" == "metadata" ]]; then
      printf 'note=metadata-only capture was explicitly requested\n'
    elif [[ "$RESULT" == "failed" ]]; then
      printf 'note=frame capture failed; no image artifact was produced\n'
    fi
  } >"$META_FILE"
}

capture_grim() {
  have_cmd grim || {
    ERROR_TEXT="grim command unavailable"
    return 1
  }
  grim "$IMAGE_FILE"
}

capture_import() {
  have_cmd import || {
    ERROR_TEXT="import command unavailable"
    return 1
  }
  import -window root "$IMAGE_FILE"
}

case "$CAPTURE_TOOL" in
  metadata)
    RESULT="metadata"
    TOOL_USED="metadata"
    ;;
  grim)
    TOOL_USED="grim"
    if capture_grim; then
      RESULT="image"
    else
      RESULT="failed"
      write_metadata
      printf 'frame capture failed with grim; metadata: %s\n' "$META_FILE" >&2
      exit 1
    fi
    ;;
  import)
    TOOL_USED="import"
    if capture_import; then
      RESULT="image"
    else
      RESULT="failed"
      write_metadata
      printf 'frame capture failed with import; metadata: %s\n' "$META_FILE" >&2
      exit 1
    fi
    ;;
  auto)
    if [[ -n "${WAYLAND_DISPLAY:-}" ]] && have_cmd grim; then
      TOOL_USED="grim"
      if capture_grim; then
        RESULT="image"
      else
        RESULT="failed"
        ERROR_TEXT="grim capture failed"
      fi
    elif [[ -n "${DISPLAY:-}" ]] && have_cmd import; then
      TOOL_USED="import"
      if capture_import; then
        RESULT="image"
      else
        RESULT="failed"
        ERROR_TEXT="import capture failed"
      fi
    else
      RESULT="failed"
      TOOL_USED="metadata"
      ERROR_TEXT="no compositor screenshot tool available"
    fi
    ;;
esac

write_metadata

if [[ "$RESULT" == "image" ]]; then
  printf '%s\n' "$IMAGE_FILE"
elif [[ "$RESULT" == "metadata" ]]; then
  printf '%s\n' "$META_FILE"
else
  printf 'frame capture failed; metadata: %s\n' "$META_FILE" >&2
  exit 1
fi
