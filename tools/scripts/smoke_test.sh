#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
TMP_DIR="${TMPDIR:-/tmp}/engineos-smoke-$$"
if [[ -x "$ROOT/tools/engineos/engineos" ]]; then
  ENGINEOS="$ROOT/tools/engineos/engineos"
elif command -v engineos >/dev/null 2>&1; then
  ENGINEOS="$(command -v engineos)"
else
  printf 'engineos smoke test: cannot find engineos CLI\n' >&2
  exit 1
fi

cleanup() {
  ENGINEOS_STATE_DIR="$TMP_DIR/run" ENGINEOS_LOG_DIR="$TMP_DIR/logs" "$ENGINEOS" engine daemon-stop >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
mkdir -p "$TMP_DIR"

"$ENGINEOS" --help >/dev/null
"$ENGINEOS" doctor --mock >/dev/null

if [[ ! -d "$ROOT/tools/scripts" ]]; then
  ENGINEOS_LOG_DIR="$TMP_DIR/logs" "$ENGINEOS" run quake --smoke >/dev/null
  "$ENGINEOS" assets explain quake >/dev/null
  "$ENGINEOS" outputs list >/dev/null
  "$ENGINEOS" logs all --last 5 >/dev/null
  printf 'engineos installed-image smoke test passed\n'
  exit 0
fi

"$ENGINEOS" doctor --bare-metal >/dev/null
"$ENGINEOS" bootstrap builder --dry-run >/dev/null
"$ENGINEOS" validate builder --mock >/dev/null
"$ENGINEOS" validate repo --mock >/dev/null
"$ENGINEOS" validate engine quake --mock >/dev/null
"$ENGINEOS" validate shell --mock >/dev/null
"$ENGINEOS" preflight scripts >/dev/null
"$ENGINEOS" lint packages >/dev/null
"$ENGINEOS" build shell --dry-run >/dev/null
"$ENGINEOS" validate shell >/dev/null
QUAKESPASM_UPSTREAM_DIR="$TMP_DIR/quakespasm-upstream" "$ENGINEOS" fetch engine quake --dry-run >/dev/null
QUAKESPASM_UPSTREAM_DIR="$TMP_DIR/quakespasm-upstream" "$ENGINEOS" fetch engine quake --status >/dev/null
"$ENGINEOS" build engine quake --dry-run >/dev/null
"$ENGINEOS" validate engine quake >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" "$ENGINEOS" proof build-lab --dry-run >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" "$ENGINEOS" proof release-candidate --dry-run --out-dir "$TMP_DIR/out" >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" "$ENGINEOS" proof hardware-ready --dry-run --profile engineruntime --out-dir "$TMP_DIR/out" --device /dev/engineos-test-usb >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" "$ENGINEOS" proof booted-iso --vm --dry-run >/dev/null
printf 'fake iso payload\n' >"$TMP_DIR/EngineDevOS-test-x86_64.iso"
"$ENGINEOS" vm boot enginedev --dry-run --iso "$TMP_DIR/EngineDevOS-test-x86_64.iso" --memory 1024 --cpus 1 --display none --no-kvm >/dev/null
"$ENGINEOS" test usb >/dev/null
ENGINEOS_STATE_DIR="$TMP_DIR/run" ENGINEOS_LOG_DIR="$TMP_DIR/logs" "$ENGINEOS" engine status >/dev/null
"$ENGINEOS" assets explain quake >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" "$ENGINEOS" test assets >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" "$ENGINEOS" test reliability >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" "$ENGINEOS" test logs >/dev/null
ENGINEOS_OUT_DIR="$TMP_DIR/out" "$ENGINEOS" test artifacts >/dev/null
ENGINEOS_OUT_DIR="$TMP_DIR/out" "$ENGINEOS" test release >/dev/null
ENGINEOS_TERMINAL_CANDIDATES="missing-terminal" "$ENGINEOS" terminal --dry-run >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" ENGINEOS_SHELL_SMOKE=true "$ENGINEOS" run shell --headless >/dev/null
ENGINEOS_CAPTURE_DIR="$TMP_DIR/captures" "$ENGINEOS" capture frame --target shell >/dev/null
"$ENGINEOS" record input "$TMP_DIR/input.json" >/dev/null
"$ENGINEOS" replay input "$TMP_DIR/input.json" >/dev/null
ENGINEOS_DRM_SYSFS="$TMP_DIR/sys/class/drm" "$ENGINEOS" outputs list >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" "$ENGINEOS" test compositor --headless >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" "$ENGINEOS" test shell-actions >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" "$ENGINEOS" test terminal >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" "$ENGINEOS" test engine-runner-env >/dev/null
"$ENGINEOS" test input >/dev/null
"$ENGINEOS" test outputs --single >/dev/null
"$ENGINEOS" test outputs --dual-static >/dev/null
ENGINEOS_CAPTURE_DIR="$TMP_DIR/captures" "$ENGINEOS" test render --smoke >/dev/null
"$ENGINEOS" build iso --dry-run >/dev/null
"$ENGINEOS" build iso enginedev --fast --dry-run >/dev/null
"$ENGINEOS" build repo --dry-run >/dev/null

printf 'engineos smoke test passed\n'
