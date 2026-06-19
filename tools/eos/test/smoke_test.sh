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

ROOT="$(engineos_root)"
TMP_DIR="${TMPDIR:-/tmp}/engineos-smoke-$$"
EOS_DIR=""
if [[ -x "$ROOT/tools/engineos/eos-doctor" ]]; then
  EOS_DIR="$ROOT/tools/engineos"
fi

run_eos() {
  local tool="$1"
  shift || true
  if [[ -n "$EOS_DIR" ]]; then
    "$EOS_DIR/$tool" "$@"
    return
  fi
  "$tool" "$@"
}

cleanup() {
  ENGINEOS_STATE_DIR="$TMP_DIR/run" ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-runtime engine daemon-stop >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
mkdir -p "$TMP_DIR"

run_eos eos-doctor --mock >/dev/null

if [[ ! -d "$ROOT/tools/scripts" ]]; then
  ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-runtime quake --smoke >/dev/null
  run_eos eos-assets explain quake >/dev/null
  run_eos eos-outputs list >/dev/null
  ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-logs all --last 5 >/dev/null
  printf 'eos-installed-image smoke test passed\n'
  exit 0
fi

run_eos eos-doctor --bare-metal >/dev/null
run_eos eos-builder bootstrap --dry-run >/dev/null
run_eos eos-validate builder --mock >/dev/null
run_eos eos-validate repo --mock >/dev/null
run_eos eos-validate engine quake --mock >/dev/null
run_eos eos-validate shell --mock >/dev/null
run_eos eos-preflight scripts >/dev/null
run_eos eos-lint packages >/dev/null
run_eos eos-build shell --dry-run >/dev/null
run_eos eos-validate shell >/dev/null
QUAKESPASM_UPSTREAM_DIR="$TMP_DIR/quakespasm-upstream" run_eos eos-build fetch engine quake --dry-run >/dev/null
QUAKESPASM_UPSTREAM_DIR="$TMP_DIR/quakespasm-upstream" run_eos eos-build fetch engine quake --status >/dev/null
run_eos eos-build engine quake --dry-run >/dev/null
run_eos eos-validate engine quake >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-proof build-lab --dry-run >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-proof release-candidate --dry-run --out-dir "$TMP_DIR/out" >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-proof hardware-ready --dry-run --profile engineruntime --out-dir "$TMP_DIR/out" --device /dev/engineos-test-usb >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-proof booted-iso --vm --dry-run >/dev/null
printf 'fake iso payload\n' >"$TMP_DIR/EngineDevOS-test-x86_64.iso"
run_eos eos-vm boot enginedev --dry-run --iso "$TMP_DIR/EngineDevOS-test-x86_64.iso" --memory 1024 --cpus 1 --display none --no-kvm >/dev/null
run_eos eos-test usb >/dev/null
ENGINEOS_STATE_DIR="$TMP_DIR/run" ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-runtime engine status >/dev/null
run_eos eos-assets explain quake >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-test assets >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-test reliability >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-test logs >/dev/null
ENGINEOS_OUT_DIR="$TMP_DIR/out" run_eos eos-test artifacts >/dev/null
ENGINEOS_OUT_DIR="$TMP_DIR/out" run_eos eos-test release >/dev/null
ENGINEOS_TERMINAL_CANDIDATES="missing-terminal" run_eos eos-terminal --dry-run >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" ENGINEOS_SHELL_SMOKE=true run_eos eos-runtime shell --headless >/dev/null
ENGINEOS_CAPTURE_DIR="$TMP_DIR/captures" run_eos eos-capture frame --target shell >/dev/null
run_eos eos-input record "$TMP_DIR/input.json" >/dev/null
run_eos eos-input replay "$TMP_DIR/input.json" >/dev/null
ENGINEOS_DRM_SYSFS="$TMP_DIR/sys/class/drm" run_eos eos-outputs list >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-test compositor --headless >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-test shell-actions >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-test terminal >/dev/null
ENGINEOS_LOG_DIR="$TMP_DIR/logs" run_eos eos-test engine-runner-env >/dev/null
run_eos eos-test input >/dev/null
run_eos eos-test outputs --single >/dev/null
run_eos eos-test outputs --dual-static >/dev/null
ENGINEOS_CAPTURE_DIR="$TMP_DIR/captures" run_eos eos-test render --smoke >/dev/null
run_eos eos-build iso --dry-run >/dev/null
run_eos eos-build iso enginedev --fast --dry-run >/dev/null
run_eos eos-build repo --dry-run >/dev/null

printf 'eos smoke test passed\n'
