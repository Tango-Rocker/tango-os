#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -n "${ENGINEOS_SCRIPT_DIR:-}" ]]; then
  SCRIPT_DIR="$ENGINEOS_SCRIPT_DIR"
else
  SCRIPT_DIR="$(cd "$MODULE_DIR/../../scripts" && pwd -P)"
fi
BARE_METAL_DIR="$(cd "$MODULE_DIR/../bare-metal" && pwd -P)"
TEST_DIR="$(cd "$MODULE_DIR/../test" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
ACTION="${1:-help}"
shift || true

usage() {
  cat <<'HELP'
Usage: proof.sh build-lab [--dry-run] [--profile enginedev]
       proof.sh release-candidate [--dry-run] [--out-dir <dir>] [--export-dir <dir>]
       proof.sh hardware-ready [--dry-run] [--profile enginedev|engineruntime] [--out-dir <dir>] [--device <block-device>]
       proof.sh booted-iso [--vm|--runtime|--bare-metal] [--dry-run]
       proof.sh shell-launch [--vm|--runtime|--bare-metal] [--dry-run]
       proof.sh launchpad [--vm|--runtime|--bare-metal] [--dry-run]
       proof.sh native-kms
       proof.sh visual [--dry-run] [--allow-metadata]
       proof.sh mc-preview [--dry-run] [--visual]

Run focused proof sequences for EngineOS milestones.

The build-lab proof is the builder-side half of PoC 0. Real builds must run on
the Arch builder VM from the repository on a Linux filesystem.

The release-candidate proof is the builder-side artifact path for the MVP: build
the local package repo, build EngineDev and EngineRuntime ISOs, then write the
release checklist.

The hardware-ready proof is the non-destructive handoff path for bare-metal
testing: confirm local structure, list USB candidates, print or run the USB
write dry-run, then name the in-guest bare-metal proof.

The booted-iso proof runs inside a generated ISO after it boots.
The shell-launch proof verifies that engineos-shell is the graphical launch
point for terminal/tmux and OpenGL app clients.
The launchpad proof verifies the terminal, cube, and engine slot contract.
The native-kms proof temporarily runs the live tty1 shell against an isolated
two-pane native mux session, proves real DRM/GBM/radeonsi output commits through
split, resize, and zoom, then restores the prior shell mode.
The visual proof requires a real frame image by default; metadata-only capture
is diagnostic unless --allow-metadata is explicitly passed.
The mc-preview proof runs the Quick View/image-preview acceptance path and can
optionally include a visual frame capture.
HELP
}

NATIVE_KMS_CLEANED=true
NATIVE_KMS_MANAGER_CHANGED=false
NATIVE_KMS_SHELL_SWITCHED=false
NATIVE_KMS_FIXTURE=""
NATIVE_KMS_RUNTIME=""
NATIVE_KMS_MUX_BIN=""
NATIVE_KMS_OLD_MODE=""
NATIVE_KMS_OLD_SOCKET=""
NATIVE_KMS_RUNTIME_CMD=""
NATIVE_KMS_SYSTEMCTL=()

native_kms_restore_environment() {
  local assignment
  for assignment in "$NATIVE_KMS_OLD_MODE" "$NATIVE_KMS_OLD_SOCKET"; do
    if [[ -n "$assignment" ]]; then
      "${NATIVE_KMS_SYSTEMCTL[@]}" set-environment "$assignment"
    fi
  done
  [[ -n "$NATIVE_KMS_OLD_MODE" ]] ||
    "${NATIVE_KMS_SYSTEMCTL[@]}" unset-environment ENGINEOS_MUX_MODE
  [[ -n "$NATIVE_KMS_OLD_SOCKET" ]] ||
    "${NATIVE_KMS_SYSTEMCTL[@]}" unset-environment ENGINEOS_MUX_SOCKET
}

native_kms_cleanup() {
  local incoming_rc=$?
  local cleanup_rc=0
  [[ "$NATIVE_KMS_CLEANED" == false ]] || return "$incoming_rc"
  NATIVE_KMS_CLEANED=true
  set +e
  if [[ "$NATIVE_KMS_MANAGER_CHANGED" == true ]]; then
    native_kms_restore_environment || cleanup_rc=$?
  fi
  if [[ "$NATIVE_KMS_SHELL_SWITCHED" == true ]]; then
    "$NATIVE_KMS_RUNTIME_CMD" shell restart-live --timeout 20 || cleanup_rc=$?
  fi
  if [[ -n "$NATIVE_KMS_MUX_BIN" && -n "$NATIVE_KMS_RUNTIME" ]]; then
    XDG_RUNTIME_DIR="$NATIVE_KMS_RUNTIME" TMUX_TMPDIR="$NATIVE_KMS_RUNTIME" \
      "$NATIVE_KMS_MUX_BIN" kill-server >/dev/null 2>&1 || true
  fi
  [[ -z "$NATIVE_KMS_FIXTURE" ]] || rm -rf "$NATIVE_KMS_FIXTURE"
  set -e
  if (( incoming_rc != 0 )); then
    return "$incoming_rc"
  fi
  return "$cleanup_rc"
}

wait_for_native_kms_state() {
  local state_file="$1"
  local filter="$2"
  local description="$3"
  local attempt
  for attempt in {1..200}; do
    if jq -e "$filter" "$state_file" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done
  jq "$filter" "$state_file" >/dev/null 2>&1 || true
  die "native KMS state did not reach $description"
}

validate_native_kms_split_state() {
  local state_file="$1"
  jq -e '
    .mode == "tty" and .backend == "drm,libinput" and
    .mux.mode == "native" and .mux.connected == true and
    (.mux.panes | length) == 2 and
    ([.mux.panes[] | select(.visible)] | length) == 2 and
    ([.output_views[] | select(
      .frame_commits > 0 and .frame_failures == 0 and
      .rendered_pane_count == 2 and
      .selected_renderer == "gpu-glyph-atlas-gles2" and
      (.panes | length) == 2 and
      ([.panes[] | select(
        .visible and .terminal_visible and .within_output and
        .frame > 0 and .nonblank_pixels > 0 and
        .renderer == "gpu-glyph-atlas-gles2"
      )] | length) == 2 and
      ((.panes | sort_by(.pixel_x)) as $p |
        ($p[0].pixel_x + $p[0].pixel_width) <= $p[1].pixel_x)
    )] | length) == (.output_views | length) and
    (.output_views | length) > 0
  ' "$state_file" >/dev/null ||
    die "native KMS split state lacks committed, clipped radeonsi pane frames"
}

proof_native_kms() {
  [[ $# -eq 0 ]] || die "native-kms proof takes no options"
  have_cmd jq || die "native-kms proof requires jq"
  have_cmd systemctl || die "native-kms proof requires systemctl"
  have_cmd sudo || [[ "$(id -u)" -eq 0 ]] ||
    die "native-kms proof requires sudo or root"

  local runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local state_file="$runtime_dir/engineos/shell-state.json"
  local shell_log="${ENGINEOS_SHELL_LOG:-${ENGINEOS_LOG_DIR:-$(default_log_dir)}/dev-shell-start.log}"
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local stamp="$(timestamp_utc)"
  local artifact_dir="$log_dir/proof-native-kms-$stamp"
  local fixture="${TMPDIR:-/tmp}/engineos-native-kms-proof-$$"
  local mux_bin="${ENGINEOS_MUX_BIN:-$(command -v engine-mux || true)}"
  local runtime_cmd="$(eos_command eos-runtime)"
  local log_start=0
  local initial_mode=""
  local initial_columns initial_frames resized_frames

  [[ -x "$mux_bin" ]] || die "native-kms proof requires installed engine-mux"
  [[ -r "$state_file" ]] || die "live shell state missing: $state_file"
  [[ -r "$shell_log" ]] || die "live shell log missing: $shell_log"
  [[ -c /dev/tty1 ]] || die "native-kms proof requires tty1"
  compgen -G '/dev/dri/card*' >/dev/null ||
    die "native-kms proof requires a DRM card"
  systemctl is-active --quiet engineos-dev-shell.service ||
    die "engineos-dev-shell.service is not active"
  jq -e '.mode == "tty"' "$state_file" >/dev/null ||
    die "live shell is not currently attached to tty/DRM"

  mkdir -p "$artifact_dir" "$fixture/runtime"
  chmod 0700 "$fixture" "$fixture/runtime"
  initial_mode="$(jq -r '.mux.mode' "$state_file")"
  cp "$state_file" "$artifact_dir/before.json"
  log_start="$(wc -l <"$shell_log")"

  NATIVE_KMS_CLEANED=false
  NATIVE_KMS_MANAGER_CHANGED=false
  NATIVE_KMS_SHELL_SWITCHED=false
  NATIVE_KMS_FIXTURE="$fixture"
  NATIVE_KMS_RUNTIME="$fixture/runtime"
  NATIVE_KMS_MUX_BIN="$mux_bin"
  NATIVE_KMS_RUNTIME_CMD="$runtime_cmd"
  if [[ "$(id -u)" -eq 0 ]]; then
    NATIVE_KMS_SYSTEMCTL=(systemctl)
  else
    NATIVE_KMS_SYSTEMCTL=(sudo -n systemctl)
  fi
  NATIVE_KMS_OLD_MODE="$(systemctl show-environment | sed -n '/^ENGINEOS_MUX_MODE=/{p;q;}')"
  NATIVE_KMS_OLD_SOCKET="$(systemctl show-environment | sed -n '/^ENGINEOS_MUX_SOCKET=/{p;q;}')"
  trap native_kms_cleanup EXIT
  trap 'exit 130' INT TERM

  printf 'EngineOS native KMS proof\n'
  printf '  state:    %s\n' "$state_file"
  printf '  log:      %s\n' "$shell_log"
  printf '  artifacts:%s\n' "$artifact_dir"
  printf '  restore:  %s\n' "$initial_mode"

  XDG_RUNTIME_DIR="$NATIVE_KMS_RUNTIME" TMUX_TMPDIR="$NATIVE_KMS_RUNTIME" \
    "$mux_bin" new-session -d -s engineos-kms-proof -x 120 -y 36 \
      'printf "LEFT-KMS-PROOF\\n"; exec sh'
  XDG_RUNTIME_DIR="$NATIVE_KMS_RUNTIME" TMUX_TMPDIR="$NATIVE_KMS_RUNTIME" \
    "$mux_bin" split-window -h -t '=engineos-kms-proof:' \
      'printf "RIGHT-KMS-PROOF\\n"; exec sh'
  XDG_RUNTIME_DIR="$NATIVE_KMS_RUNTIME" TMUX_TMPDIR="$NATIVE_KMS_RUNTIME" \
    "$mux_bin" select-layout -t '=engineos-kms-proof:' even-horizontal
  local mux_socket="$NATIVE_KMS_RUNTIME/engineos/mux.sock"
  [[ -S "$mux_socket" ]] || die "isolated native mux frontend socket missing"

  "${NATIVE_KMS_SYSTEMCTL[@]}" set-environment \
    ENGINEOS_MUX_MODE=native ENGINEOS_MUX_SOCKET="$mux_socket"
  NATIVE_KMS_MANAGER_CHANGED=true
  NATIVE_KMS_SHELL_SWITCHED=true
  "$runtime_cmd" shell restart-live --timeout 20

  wait_for_native_kms_state "$state_file" '
    .mode == "tty" and .backend == "drm,libinput" and
    .mux.mode == "native" and .mux.connected == true and
    (.mux.panes | length) == 2 and
    (.output_views | length) > 0 and
    ([.output_views[] | select(.frame_commits > 0)] | length) ==
      (.output_views | length)
  ' "initial direct-KMS split frames"
  validate_native_kms_split_state "$state_file"
  cp "$state_file" "$artifact_dir/split.json"
  initial_columns="$(jq '.mux.panes[0].columns' "$state_file")"
  initial_frames="$(jq '[.output_views[].panes[].frame] | add' "$state_file")"

  XDG_RUNTIME_DIR="$NATIVE_KMS_RUNTIME" TMUX_TMPDIR="$NATIVE_KMS_RUNTIME" \
    "$mux_bin" resize-pane -t '%0' -R 8
  XDG_RUNTIME_DIR="$NATIVE_KMS_RUNTIME" TMUX_TMPDIR="$NATIVE_KMS_RUNTIME" \
    "$mux_bin" send-keys -t '%0' 'printf "LEFT-RESIZED-KMS\\n"' Enter
  XDG_RUNTIME_DIR="$NATIVE_KMS_RUNTIME" TMUX_TMPDIR="$NATIVE_KMS_RUNTIME" \
    "$mux_bin" send-keys -t '%1' 'printf "RIGHT-RESIZED-KMS\\n"' Enter
  wait_for_native_kms_state "$state_file" ".mux.panes[0].columns != $initial_columns and
    ([.output_views[].panes[].frame] | add) > $initial_frames" \
    "resized nonblank pane frames"
  validate_native_kms_split_state "$state_file"
  cp "$state_file" "$artifact_dir/resized.json"
  resized_frames="$(jq '[.output_views[].panes[].frame] | add' "$state_file")"

  XDG_RUNTIME_DIR="$NATIVE_KMS_RUNTIME" TMUX_TMPDIR="$NATIVE_KMS_RUNTIME" \
    "$mux_bin" resize-pane -Z -t '%1'
  wait_for_native_kms_state "$state_file" '
    ([.mux.panes[] | select(.visible)] | length) == 1 and
    ([.output_views[] | select(
      ([.panes[] | select(.visible)] | length) == 1 and
      ([.panes[] | select(.visible and .terminal_visible and .within_output and
        .renderer == "gpu-glyph-atlas-gles2" and .frame > 0)] | length) == 1
      and ([.panes[] | select((.visible | not) and
        (.terminal_visible | not))] | length) == 1
    )] | length) == (.output_views | length)
  ' "zoomed single-pane clipping"
  cp "$state_file" "$artifact_dir/zoomed.json"

  XDG_RUNTIME_DIR="$NATIVE_KMS_RUNTIME" TMUX_TMPDIR="$NATIVE_KMS_RUNTIME" \
    "$mux_bin" resize-pane -Z -t '%1'
  wait_for_native_kms_state "$state_file" "
    ([.mux.panes[] | select(.visible)] | length) == 2 and
    ([.output_views[].panes[].frame] | add) > $resized_frames
  " "unzoomed split clipping"
  validate_native_kms_split_state "$state_file"
  cp "$state_file" "$artifact_dir/unzoomed.json"

  sed -n "$((log_start + 1)),\$p" "$shell_log" >"$artifact_dir/kms.log"
  grep -F 'renderer diagnostics backend=drm,libinput' \
    "$artifact_dir/kms.log" >/dev/null ||
    die "native KMS log lacks DRM/libinput backend evidence"
  grep -E 'GL renderer: AMD .*radeonsi' "$artifact_dir/kms.log" >/dev/null ||
    die "native KMS log lacks AMD/radeonsi renderer evidence"
  grep -F 'Created GBM allocator with backend drm' \
    "$artifact_dir/kms.log" >/dev/null ||
    die "native KMS log lacks DRM GBM allocator evidence"
  grep -F 'Modesetting with ' "$artifact_dir/kms.log" >/dev/null ||
    die "native KMS log lacks a real connector modeset"
  if grep -F 'failed to commit scene output' "$artifact_dir/kms.log" >/dev/null; then
    die "native KMS scene output commit failed"
  fi

  native_kms_cleanup
  trap - EXIT INT TERM
  wait_for_native_kms_state "$state_file" ".mux.mode == \"$initial_mode\"" \
    "restored $initial_mode shell mode"
  cp "$state_file" "$artifact_dir/restored.json"
  printf 'Native KMS clipping proof passed.\n'
  printf 'Proof artifacts: %s\n' "$artifact_dir"
}

default_log_dir() {
  engineos_default_log_dir "$ROOT"
}

default_state_dir() {
  engineos_default_state_dir "$ROOT"
}

timestamp_utc() {
  date -u +%Y%m%dT%H%M%SZ
}

run_step() {
  local label="$1"
  shift

  printf '\n==> %s\n' "$label"
  printf '    '
  quote_cmd "$@"
  "$@"
}

write_preview_fixture_png() {
  local path="$1"

  have_cmd base64 || die "base64 unavailable; cannot create preview proof fixture"
  printf '%s' \
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAADAQMAAACOOjyFAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURSJmzP///8VU6LMAAAABYktHRAH/Ai3eAAAAB3RJTUUH6gcCFi0VNn7nGQAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAyNi0wNy0wMlQyMjo0NToyMSswMDowMIBjV7MAAAAldEVYdGRhdGU6bW9kaWZ5ADIwMjYtMDctMDJUMjI6NDU6MjErMDA6MDDxPu8PAAAAKHRFWHRkYXRlOnRpbWVzdGFtcAAyMDI2LTA3LTAyVDIyOjQ1OjIxKzAwOjAwpivO0AAAAAtJREFUCNdjYAABAAAGAAFm9MlsAAAAAElFTkSuQmCC' |
    base64 -d >"$path" ||
    die "failed to create preview proof fixture: $path"
  [[ -s "$path" ]] || die "preview proof fixture is empty: $path"
}

eos_command() {
  local name="$1"
  if [[ -x "$ROOT/tools/engineos/$name" ]]; then
    printf '%s\n' "$ROOT/tools/engineos/$name"
  else
    printf '%s\n' "$name"
  fi
}

proof_build_lab() {
  local dry_run=false
  local profile="enginedev"
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local out_dir="${ENGINEOS_OUT_DIR:-$ROOT/out}"
  local log_file

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --profile)
        shift
        profile="${1:-}"
        [[ -n "$profile" ]] || die "--profile requires a profile"
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown build-lab proof option: $1"
        ;;
    esac
    shift
  done

  [[ "$profile" == "enginedev" ]] || die "build-lab proof currently expects the EngineDev profile"

  mkdir -p "$log_dir"
  log_file="$log_dir/proof-build-lab-$(timestamp_utc).log"
  exec > >(tee -a "$log_file") 2>&1

  printf 'EngineOS build-lab proof\n'
  printf '  root:    %s\n' "$ROOT"
  printf '  profile: %s\n' "$profile"
  printf '  dry_run: %s\n' "$dry_run"
  printf '  log:     %s\n' "$log_file"

  if [[ "$dry_run" == true ]]; then
    run_step "validate builder preview" printf '%s\n' "./tools/engineos/eos-validate builder"
  else
    run_step "validate builder" "$SCRIPT_DIR/validate_builder.sh"
  fi
  run_step "preflight all" "$SCRIPT_DIR/preflight.sh" all
  run_step "lint packages" "$SCRIPT_DIR/package_lint.sh"

  if [[ "$dry_run" == true ]]; then
    run_step "build shell dry-run" "$SCRIPT_DIR/build_shell.sh" --dry-run
    run_step "build repo dry-run" "$SCRIPT_DIR/build_repo.sh" --dry-run
    run_step "validate repo dry-run" "$SCRIPT_DIR/validate_repo.sh" --dry-run
    run_step "build EngineDev ISO dry-run" "$SCRIPT_DIR/build_iso.sh" "$profile" --dry-run
  else
    run_step "build shell" "$SCRIPT_DIR/build_shell.sh"
    run_step "build repo" "$SCRIPT_DIR/build_repo.sh"
    run_step "validate repo" "$SCRIPT_DIR/validate_repo.sh"
    run_step "build EngineDev ISO" "$SCRIPT_DIR/build_iso.sh" "$profile" --clean --archive-existing
    run_step "list ISO artifacts" "$SCRIPT_DIR/artifacts.sh" list "$out_dir"
  fi

  if [[ "$dry_run" == true ]]; then
    printf '\nBuild-lab proof preview completed; no build-lab proof was executed.\n'
    printf 'Next Arch builder command: ./tools/engineos/eos-proof build-lab\n'
  else
    printf '\nBuild-lab proof runner completed.\n'
    printf 'Next test VM command: ./tools/engineos/eos-vm boot enginedev\n'
    printf 'Next booted ISO command: eos-proof booted-iso --vm\n'
  fi
}

proof_release_candidate() {
  local dry_run=false
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local out_dir="${ENGINEOS_OUT_DIR:-$ROOT/out}"
  local export_dir=""
  local log_file
  local release_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --out-dir)
        shift
        out_dir="${1:-}"
        [[ -n "$out_dir" ]] || die "--out-dir requires a directory"
        ;;
      --export-dir)
        shift
        export_dir="${1:-}"
        [[ -n "$export_dir" ]] || die "--export-dir requires a directory"
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown release-candidate proof option: $1"
        ;;
    esac
    shift
  done

  mkdir -p "$log_dir"
  log_file="$log_dir/proof-release-candidate-$(timestamp_utc).log"
  exec > >(tee -a "$log_file") 2>&1

  printf 'EngineOS release-candidate proof\n'
  printf '  root:    %s\n' "$ROOT"
  printf '  out:     %s\n' "$out_dir"
  printf '  dry_run: %s\n' "$dry_run"
  printf '  log:     %s\n' "$log_file"
  [[ -n "$export_dir" ]] && printf '  export:  %s\n' "$export_dir"

  if [[ "$dry_run" == true ]]; then
    release_args+=(--dry-run)
    run_step "validate builder preview" printf '%s\n' "./tools/engineos/eos-validate builder"
    run_step "preflight all" "$SCRIPT_DIR/preflight.sh" all
    run_step "lint packages" "$SCRIPT_DIR/package_lint.sh"
    run_step "build shell dry-run" "$SCRIPT_DIR/build_shell.sh" --dry-run
    run_step "build repo dry-run" "$SCRIPT_DIR/build_repo.sh" --dry-run
    run_step "validate repo dry-run" "$SCRIPT_DIR/validate_repo.sh" --dry-run
    run_step "build EngineDev ISO dry-run" env ENGINEOS_OUT_DIR="$out_dir" "$SCRIPT_DIR/build_iso.sh" enginedev --dry-run
    run_step "build EngineRuntime ISO dry-run" env ENGINEOS_OUT_DIR="$out_dir" "$SCRIPT_DIR/build_iso.sh" engineruntime --dry-run
  else
    run_step "validate builder" "$SCRIPT_DIR/validate_builder.sh"
    run_step "preflight all" "$SCRIPT_DIR/preflight.sh" all
    run_step "lint packages" "$SCRIPT_DIR/package_lint.sh"
    run_step "build shell" "$SCRIPT_DIR/build_shell.sh"
    run_step "build repo" "$SCRIPT_DIR/build_repo.sh"
    run_step "validate repo" "$SCRIPT_DIR/validate_repo.sh"
    run_step "build EngineDev ISO" env ENGINEOS_OUT_DIR="$out_dir" "$SCRIPT_DIR/build_iso.sh" enginedev --clean --archive-existing
    run_step "build EngineRuntime ISO" env ENGINEOS_OUT_DIR="$out_dir" "$SCRIPT_DIR/build_iso.sh" engineruntime --clean --archive-existing
  fi

  release_args=(checklist --out-dir "$out_dir")
  if [[ "$dry_run" == true ]]; then
    release_args+=(--dry-run)
  fi
  if [[ -n "$export_dir" ]]; then
    release_args+=(--export-dir "$export_dir")
  fi
  run_step "release checklist" "$SCRIPT_DIR/release.sh" "${release_args[@]}"

  if [[ "$dry_run" == true ]]; then
    printf '\nRelease-candidate proof preview completed; no release-candidate proof was executed.\n'
    printf 'Next Arch builder command: ./tools/engineos/eos-proof release-candidate\n'
  else
    printf '\nRelease-candidate proof runner completed.\n'
    printf 'Next test VM command: ./tools/engineos/eos-vm boot enginedev\n'
    printf 'Next runtime VM command: ./tools/engineos/eos-vm boot engineruntime\n'
    printf 'Next hardware proof: boot EngineRuntime on the AMD machine and run eos-proof booted-iso --bare-metal\n'
  fi
}

proof_hardware_ready() {
  local dry_run=false
  local profile="engineruntime"
  local out_dir="${ENGINEOS_OUT_DIR:-$ROOT/out}"
  local device=""
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local log_file
  local usb_write_cmd=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --profile)
        shift
        profile="${1:-}"
        [[ -n "$profile" ]] || die "--profile requires a profile"
        ;;
      --out-dir)
        shift
        out_dir="${1:-}"
        [[ -n "$out_dir" ]] || die "--out-dir requires a directory"
        ;;
      --device)
        shift
        device="${1:-}"
        [[ -n "$device" ]] || die "--device requires a block device"
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown hardware-ready proof option: $1"
        ;;
    esac
    shift
  done

  case "$profile" in
    enginedev|engineruntime)
      ;;
    *)
      die "unknown hardware-ready profile: $profile"
      ;;
  esac

  mkdir -p "$log_dir"
  log_file="$log_dir/proof-hardware-ready-$(timestamp_utc).log"
  exec > >(tee -a "$log_file") 2>&1

  printf 'EngineOS hardware-ready proof\n'
  printf '  root:    %s\n' "$ROOT"
  printf '  profile: %s\n' "$profile"
  printf '  out:     %s\n' "$out_dir"
  printf '  dry_run: %s\n' "$dry_run"
  printf '  log:     %s\n' "$log_file"
  [[ -n "$device" ]] && printf '  device:  %s\n' "$device"

  usb_write_cmd=("$BARE_METAL_DIR/usb.sh" write --profile "$profile" --out-dir "$out_dir" --device "${device:-/dev/sdX}" --dry-run)

  if [[ "$dry_run" == true ]]; then
    run_step "preflight all dry-run" printf '%s\n' "./tools/engineos/eos-preflight all"
    run_step "release-candidate dry-run" printf '%s\n' "./tools/engineos/eos-proof release-candidate --dry-run --out-dir $out_dir"
    run_step "USB candidate list dry-run" printf '%s\n' "./tools/engineos/eos-usb list"
    run_step "USB write dry-run" printf '%s\n' "./tools/engineos/eos-usb write --profile $profile --out-dir $out_dir --device ${device:-/dev/sdX} --dry-run"
    run_step "booted bare-metal proof dry-run" printf '%s\n' "eos-proof booted-iso --bare-metal"
  else
    run_step "preflight all" "$SCRIPT_DIR/preflight.sh" all
    run_step "release checklist dry-run" "$SCRIPT_DIR/release.sh" checklist --dry-run --out-dir "$out_dir"
    run_step "USB candidate list" "$BARE_METAL_DIR/usb.sh" list
    if [[ -n "$device" ]]; then
      run_step "USB write dry-run" "${usb_write_cmd[@]}"
    else
      printf '\nNo --device provided; inspect the USB candidate list and re-run with --device /dev/sdX.\n'
      printf 'USB write dry-run command: '
      quote_cmd "${usb_write_cmd[@]}"
    fi
  fi

  if [[ "$dry_run" == true ]]; then
    printf '\nHardware-ready proof preview completed; no hardware-ready proof was executed.\n'
  else
    printf '\nHardware-ready proof runner completed.\n'
  fi
  printf 'This proof does not write USB media or prove AMD hardware by itself.\n'
  printf 'After writing the ISO and booting the target AMD machine, run:\n'
  printf '  eos-proof booted-iso --bare-metal\n'
}

proof_booted_iso() {
  local dry_run=false
  local mode="vm"
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local log_file
  local validate_args=(--vm)
  local doctor_args=(--vm)
  local crash_bundle_args=(--vm)
  local assets_cmd
  local logs_cmd
  local outputs_cmd
  local runtime_cmd

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --vm)
        mode="vm"
        validate_args=(--vm)
        doctor_args=(--vm)
        crash_bundle_args=(--vm)
        ;;
      --runtime)
        mode="runtime"
        validate_args=(--runtime)
        doctor_args=(--vm)
        crash_bundle_args=(--runtime)
        ;;
      --bare-metal)
        mode="bare-metal"
        validate_args=(--bare-metal)
        doctor_args=(--bare-metal)
        crash_bundle_args=(--bare-metal)
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown booted-iso proof option: $1"
        ;;
    esac
    shift
  done

  if ! mkdir -p "$log_dir" 2>/dev/null || ! touch "$log_dir/.engineos-write-test" 2>/dev/null; then
    log_dir="${TMPDIR:-/tmp}/engineos-logs"
    mkdir -p "$log_dir"
  else
    rm -f "$log_dir/.engineos-write-test"
  fi
  log_file="$log_dir/proof-booted-iso-$mode-$(timestamp_utc).log"
  exec > >(tee -a "$log_file") 2>&1

  printf 'EngineOS booted-ISO proof\n'
  printf '  root:    %s\n' "$ROOT"
  printf '  mode:    %s\n' "$mode"
  printf '  dry_run: %s\n' "$dry_run"
  printf '  log:     %s\n' "$log_file"

  assets_cmd="$(eos_command eos-assets)"
  logs_cmd="$(eos_command eos-logs)"
  outputs_cmd="$(eos_command eos-outputs)"
  runtime_cmd="$(eos_command eos-runtime)"

  if [[ "$dry_run" == true ]]; then
    run_step "validate boot dry-run" printf '%s\n' "eos-validate boot ${validate_args[*]}"
    run_step "doctor dry-run" printf '%s\n' "eos-doctor ${doctor_args[*]}"
    run_step "smoke test dry-run" printf '%s\n' "eos-test smoke"
    run_step "Quake smoke dry-run" printf '%s\n' "eos-runtime quake --smoke"
    run_step "asset guidance dry-run" printf '%s\n' "eos-assets explain quake"
    run_step "engine logs dry-run" printf '%s\n' "eos-logs engine --last 200"
    if [[ "$mode" == "bare-metal" ]]; then
      run_step "output validation dry-run" printf '%s\n' "eos-outputs validate --single"
    fi
    if [[ "$mode" == "runtime" || "$mode" == "bare-metal" ]]; then
      run_step "runtime reliability dry-run" printf '%s\n' "eos-test reliability"
      run_step "runtime logs dry-run" printf '%s\n' "eos-logs runtime --last 200"
    fi
    run_step "crash bundle dry-run" printf '%s\n' "eos-crash-bundle ${crash_bundle_args[*]}"
  else
    run_step "validate boot" env ENGINEOS_PROOF_STRICT=1 "$MODULE_DIR/validate_boot.sh" "${validate_args[@]}"
    run_step "doctor" "$SCRIPT_DIR/doctor.sh" "${doctor_args[@]}"
    run_step "smoke test" "$TEST_DIR/test_runner.sh" smoke
    run_step "Quake smoke" "$runtime_cmd" quake --smoke
    run_step "asset guidance" "$assets_cmd" explain quake
    run_step "engine logs" "$logs_cmd" engine --last 200
    if [[ "$mode" == "bare-metal" ]]; then
      run_step "output validation" "$outputs_cmd" validate --single
    fi
    if [[ "$mode" == "runtime" || "$mode" == "bare-metal" ]]; then
      run_step "runtime reliability" "$TEST_DIR/test_runner.sh" reliability
      run_step "runtime logs" "$logs_cmd" runtime --last 200
    fi
    run_step "crash bundle" "$SCRIPT_DIR/crash_bundle.sh" "${crash_bundle_args[@]}"
  fi

  if [[ "$dry_run" == true ]]; then
    printf '\nBooted-ISO proof preview completed; no booted-ISO proof was executed.\n'
    printf 'Next booted ISO command: eos-proof booted-iso --%s\n' "$mode"
  else
    printf '\nBooted-ISO proof runner completed.\n'
    printf 'Proof log: %s\n' "$log_file"
  fi
}

proof_shell_launch() {
  local dry_run=false
  local mode="vm"
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local log_file
  local app_cmd
  local doctor_cmd
  local logs_cmd
  local validate_cmd
  local shell_log
  local terminal_log
  local app_log

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --vm)
        mode="vm"
        ;;
      --runtime)
        mode="runtime"
        ;;
      --bare-metal)
        mode="bare-metal"
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown shell-launch proof option: $1"
        ;;
    esac
    shift
  done

  if ! mkdir -p "$log_dir" 2>/dev/null || ! touch "$log_dir/.engineos-write-test" 2>/dev/null; then
    log_dir="${TMPDIR:-/tmp}/engineos-logs"
    mkdir -p "$log_dir"
  else
    rm -f "$log_dir/.engineos-write-test"
  fi
  log_file="$log_dir/proof-shell-launch-$mode-$(timestamp_utc).log"
  exec > >(tee -a "$log_file") 2>&1

  printf 'EngineOS shell-launch proof\n'
  printf '  root:    %s\n' "$ROOT"
  printf '  mode:    %s\n' "$mode"
  printf '  dry_run: %s\n' "$dry_run"
  printf '  log:     %s\n' "$log_file"

  app_cmd="$(eos_command eos-app)"
  doctor_cmd="$(eos_command eos-doctor)"
  logs_cmd="$(eos_command eos-logs)"
  validate_cmd="$(eos_command eos-validate)"
  shell_log="$log_dir/shell.log"
  terminal_log="$log_dir/terminal.log"
  app_log="$log_dir/app.log"

  if [[ "$dry_run" == true ]]; then
    run_step "shell binary dry-run" printf '%s\n' "would require: command -v engineos-shell"
    run_step "shell process dry-run" printf '%s\n' "would require: pgrep -a engineos-shell"
    run_step "shell log ownership dry-run" printf '%s\n' "would require: grep -E 'engineos-shell mode=|client launch environment|renderer diagnostics' $shell_log"
    run_step "terminal/tmux ownership dry-run" printf '%s\n' "would require: grep -E 'owner=engineos-shell|session command=engineos-tmux-attach-primary' $terminal_log"
    run_step "app launch ownership dry-run" printf '%s\n' "would require: grep -F 'app launch app=terminal owner=engineos-shell' $app_log"
    run_step "renderer doctor dry-run" printf '%s\n' "would require: eos-doctor --vm"
    if [[ "$mode" == "bare-metal" ]]; then
      run_step "bare-metal shell renderer dry-run" printf '%s\n' "would require: grep -E 'renderer diagnostics|GLES2|EGL|wlr_renderer=(gles2|vulkan)' $shell_log && ! grep -Ei 'pixman|llvmpipe|softpipe|software renderer' $shell_log"
      run_step "bare-metal renderer rejection dry-run" printf '%s\n' "would require: eos-validate boot --bare-metal"
    fi
    printf '\nShell-launch proof preview completed; no shell-launch proof was executed.\n'
    return
  fi

  run_step "shell binary" command -v engineos-shell
  run_step "shell process" pgrep -a engineos-shell
  run_step "app launcher status" "$app_cmd" status
  run_step "shell logs" "$logs_cmd" shell --last 200

  [[ -r "$shell_log" ]] || die "shell log missing: $shell_log"
  grep -E 'engineos-shell mode=' "$shell_log" >/dev/null ||
    die "shell log does not show engineos-shell startup"
  grep -E 'client launch environment' "$shell_log" >/dev/null ||
    die "shell log does not show shell-owned client environment"
  grep -E 'renderer diagnostics' "$shell_log" >/dev/null ||
    die "shell log does not show renderer diagnostics"

  if [[ "$mode" == "bare-metal" ]]; then
    if grep -Eiq 'pixman|llvmpipe|softpipe|software rasterizer|software renderer|wlr_allow_software=(1|true|yes)|libgl_always_software=(1|true|yes)' "$shell_log"; then
      die "bare-metal shell log shows software rendering"
    fi
    grep -Eiq 'GLES2|EGL|wlr_renderer=(gles2|vulkan)' "$shell_log" ||
      die "bare-metal shell log does not show GL-capable renderer evidence"
  fi

  [[ -r "$terminal_log" ]] || die "terminal log missing: $terminal_log"
  grep -F 'owner=engineos-shell' "$terminal_log" >/dev/null ||
    die "terminal log does not show shell ownership"
  grep -F 'session command=engineos-tmux-attach-primary' "$terminal_log" >/dev/null ||
    die "terminal log does not show tmux session startup"

  [[ -r "$app_log" ]] || die "app log missing: $app_log"
  grep -F 'owner=engineos-shell' "$app_log" >/dev/null ||
    die "app log does not show shell ownership"
  grep -F 'app launch app=terminal owner=engineos-shell' "$app_log" >/dev/null ||
    die "app log does not show terminal launch ownership"

  run_step "doctor renderer evidence" "$doctor_cmd" --vm
  if [[ "$mode" == "bare-metal" ]]; then
    run_step "bare-metal renderer validation" "$validate_cmd" boot --bare-metal
  fi

  printf '\nShell-launch proof runner completed.\n'
  printf 'Proof log: %s\n' "$log_file"
}

proof_visual() {
  local dry_run=false
  local allow_metadata=false
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local log_file
  local capture_cmd
  local artifact
  local metadata
  local result

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --allow-metadata)
        allow_metadata=true
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown visual proof option: $1"
        ;;
    esac
    shift
  done

  mkdir -p "$log_dir"
  log_file="$log_dir/proof-visual-$(timestamp_utc).log"
  exec > >(tee -a "$log_file") 2>&1

  printf 'EngineOS visual proof\n'
  printf '  root:           %s\n' "$ROOT"
  printf '  dry_run:        %s\n' "$dry_run"
  printf '  allow_metadata: %s\n' "$allow_metadata"
  printf '  log:            %s\n' "$log_file"

  capture_cmd="$(eos_command eos-capture)"

  if [[ "$dry_run" == true ]]; then
    run_step "frame capture dry-run" printf '%s\n' "would require: eos-capture frame --target shell"
    run_step "visual artifact dry-run" printf '%s\n' "would require: capture metadata result=image and a readable PNG artifact"
    printf '\nVisual proof preview completed; no visual proof was executed.\n'
    return
  fi

  printf '\n==> frame capture\n'
  printf '    '
  quote_cmd "$capture_cmd" frame --target shell
  artifact="$("$capture_cmd" frame --target shell)"
  printf '%s\n' "$artifact"
  artifact="$(printf '%s\n' "$artifact" | tail -n 1)"
  [[ -n "$artifact" && -f "$artifact" ]] || die "frame capture did not produce an artifact"

  if [[ "$artifact" == *.png ]]; then
    metadata="${artifact%.png}.txt"
  else
    metadata="$artifact"
  fi
  [[ -r "$metadata" ]] || die "frame capture metadata missing: $metadata"
  result="$(awk -F= '$1 == "result" { print $2; exit }' "$metadata")"

  case "$result" in
    image)
      [[ "$artifact" == *.png && -s "$artifact" ]] || die "visual capture did not produce a non-empty PNG image"
      printf 'Visual frame captured: %s\n' "$artifact"
      ;;
    metadata)
      if [[ "$allow_metadata" == true ]]; then
        printf 'Metadata-only capture accepted by explicit request: %s\n' "$metadata"
      else
        die "metadata-only capture is not visual proof: $metadata"
      fi
      ;;
    failed|"")
      die "frame capture failed; metadata: $metadata"
      ;;
    *)
      die "unknown frame capture result '$result' in $metadata"
      ;;
  esac

  printf '\nVisual proof runner completed.\n'
  printf 'Proof log: %s\n' "$log_file"
}

proof_mc_preview() {
  local dry_run=false
  local visual=false
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local log_file
  local preview_cmd
  local preview_image
  local shell_log

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --visual)
        visual=true
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown mc-preview proof option: $1"
        ;;
    esac
    shift
  done

  mkdir -p "$log_dir"
  log_file="$log_dir/proof-mc-preview-$(timestamp_utc).log"
  exec > >(tee -a "$log_file") 2>&1

  printf 'EngineOS MC preview proof\n'
  printf '  root:    %s\n' "$ROOT"
  printf '  dry_run: %s\n' "$dry_run"
  printf '  visual:  %s\n' "$visual"
  printf '  log:     %s\n' "$log_file"

  preview_cmd="${ENGINEOS_IMAGE_PREVIEW_CMD:-$(eos_command engine-image-preview)}"
  preview_image="$log_dir/proof-mc-preview.png"
  shell_log="$log_dir/shell.log"

  if [[ "$dry_run" == true ]]; then
    run_step "test image setup dry-run" printf '%s\n' "would require: eos-test image-preview fixture images"
    run_step "preview dry-run checks" printf '%s\n' "would require: engine-image-preview --quick-view <image> --panel right --dry-run"
    run_step "preview IPC check dry-run" printf '%s\n' "would require: engine-image-preview --ping"
    run_step "preview live request dry-run" printf '%s\n' "would require: engine-image-preview --quick-view $preview_image --panel right"
    run_step "preview shell log evidence dry-run" printf '%s\n' "would require: grep -F 'image preview shown path=$preview_image' $shell_log | grep -F 'owner=mc-quick-view:' | grep -F 'image=4x3'"
    run_step "preview recovery check" printf '%s\n' "would require: eos-app recover preview"
    if [[ "$visual" == true ]]; then
      run_step "visual capture dry-run" printf '%s\n' "would require: eos-proof visual"
    fi
    printf '\nMC preview proof preview completed; no MC preview proof was executed.\n'
    return
  fi

  run_step "image preview contract" "$TEST_DIR/test_runner.sh" image-preview
  write_preview_fixture_png "$preview_image"
  run_step "preview IPC ping" "$preview_cmd" --ping
  run_step "MC quick-view preview" "$preview_cmd" --quick-view "$preview_image" --panel right
  [[ -r "$shell_log" ]] || die "shell log missing: $shell_log"
  grep -aF "image preview shown path=$preview_image" "$shell_log" |
    grep -F 'owner=mc-quick-view:' |
    grep -F 'image=4x3' >/dev/null ||
    die "shell log does not show MC Quick View preview evidence: $shell_log"
  if [[ "$visual" == true ]]; then
    run_step "visual capture" "$MODULE_DIR/proof.sh" visual
  fi

  printf '\nMC preview proof runner completed.\n'
  printf 'Proof log: %s\n' "$log_file"
}

proof_launchpad() {
  local dry_run=false
  local mode="runtime"
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local state_dir="${ENGINEOS_STATE_DIR:-$(default_state_dir)}"
  local log_file
  local app_cmd
  local logs_cmd
  local outputs_cmd
  local shell_log
  local shell_state
  local app_log
  local cube_log
  local engine_log

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --vm)
        mode="vm"
        ;;
      --runtime)
        mode="runtime"
        ;;
      --bare-metal)
        mode="bare-metal"
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown launchpad proof option: $1"
        ;;
    esac
    shift
  done

  if ! mkdir -p "$log_dir" 2>/dev/null || ! touch "$log_dir/.engineos-write-test" 2>/dev/null; then
    log_dir="${TMPDIR:-/tmp}/engineos-logs"
    mkdir -p "$log_dir"
  else
    rm -f "$log_dir/.engineos-write-test"
  fi
  log_file="$log_dir/proof-launchpad-$mode-$(timestamp_utc).log"
  exec > >(tee -a "$log_file") 2>&1

  printf 'EngineOS launchpad proof\n'
  printf '  root:    %s\n' "$ROOT"
  printf '  mode:    %s\n' "$mode"
  printf '  dry_run: %s\n' "$dry_run"
  printf '  log:     %s\n' "$log_file"

  app_cmd="$(eos_command eos-app)"
  logs_cmd="$(eos_command eos-logs)"
  outputs_cmd="$(eos_command eos-outputs)"
  shell_log="$log_dir/shell.log"
  shell_state="$state_dir/shell-state.json"
  app_log="$log_dir/app.log"
  cube_log="$log_dir/cube.log"
  engine_log="$log_dir/engine.log"

  if [[ "$dry_run" == true ]]; then
    run_step "app manifest dry-run" printf '%s\n' "eos-app manifest validate"
    run_step "launchpad status dry-run" printf '%s\n' "eos-app status --json"
    run_step "launchpad state dry-run" printf '%s\n' "grep -E 'engineos-shell-state-v0|\"active_slot\": \"cube\"|\"bootstrap\": \"launchpad\"' $shell_state"
    run_step "launchpad bootstrap dry-run" printf '%s\n' "grep -F 'bootstrap mode=launchpad' $shell_log"
    run_step "launchpad active cube dry-run" printf '%s\n' "grep -F 'launchpad active slot=cube' $shell_log"
    run_step "launchpad launch actions dry-run" printf '%s\n' "grep -E 'launch action label=bootstrap-(terminal|cube|engine)' $shell_log"
    run_step "launchpad app ownership dry-run" printf '%s\n' "grep -E 'app launch app=(terminal|cube|quake) owner=engineos-shell' $app_log"
    run_step "cube renderer dry-run" printf '%s\n' "grep -E 'gl_renderer=|frames=' $cube_log"
    run_step "engine slot mapped dry-run" printf '%s\n' "grep -F 'view mapped role=engine' $shell_log"
    if [[ "$mode" == "bare-metal" ]]; then
      run_step "bare-metal output validation dry-run" printf '%s\n' "eos-outputs validate --single"
    fi
    printf '\nLaunchpad proof preview completed; no launchpad proof was executed.\n'
    return
  fi

  run_step "app manifest" "$app_cmd" manifest validate
  run_step "app launcher status json" "$app_cmd" status --json
  run_step "shell logs" "$logs_cmd" shell --last 200
  run_step "app logs" "$logs_cmd" app --last 200
  run_step "engine logs" "$logs_cmd" engine --last 200

  [[ -r "$shell_log" ]] || die "shell log missing: $shell_log"
  [[ -r "$shell_state" ]] || die "shell state missing: $shell_state"
  grep -F '"schema": "engineos-shell-state-v0"' "$shell_state" >/dev/null ||
    die "shell state does not use the expected schema"
  grep -F '"bootstrap": "launchpad"' "$shell_state" >/dev/null ||
    die "shell state does not show launchpad bootstrap"
  grep -F '"active_slot": "cube"' "$shell_state" >/dev/null ||
    die "shell state does not show cube as active launchpad slot"
  grep -E '"cube": \{"mapped": true, "visible": true' "$shell_state" >/dev/null ||
    die "shell state does not show visible mapped cube slot"
  grep -F 'bootstrap mode=launchpad' "$shell_log" >/dev/null ||
    die "shell log does not show launchpad bootstrap"
  grep -F 'launchpad active slot=cube' "$shell_log" >/dev/null ||
    die "shell log does not show cube as active launchpad slot"
  grep -E 'launch action label=bootstrap-terminal' "$shell_log" >/dev/null ||
    die "shell log does not show terminal bootstrap launch action"
  grep -E 'launch action label=bootstrap-cube' "$shell_log" >/dev/null ||
    die "shell log does not show cube bootstrap launch action"
  grep -E 'launch action label=bootstrap-engine' "$shell_log" >/dev/null ||
    die "shell log does not show engine bootstrap launch action"

  [[ -r "$app_log" ]] || die "app log missing: $app_log"
  grep -F 'app launch app=terminal owner=engineos-shell' "$app_log" >/dev/null ||
    die "app log does not show terminal launch ownership"
  grep -F 'app launch app=cube owner=engineos-shell' "$app_log" >/dev/null ||
    die "app log does not show cube launch ownership"
  grep -F 'app launch app=quake owner=engineos-shell' "$app_log" >/dev/null ||
    die "app log does not show Quake launch ownership"

  [[ -r "$cube_log" ]] || die "cube log missing: $cube_log"
  grep -F 'gl_renderer=' "$cube_log" >/dev/null ||
    die "cube log does not show GL renderer evidence"
  grep -F 'frames=' "$cube_log" >/dev/null ||
    die "cube log does not show rendered frame evidence"

  grep -F 'view mapped role=engine' "$shell_log" >/dev/null ||
    die "engine slot did not map; Quake asset/runtime guidance is not launchpad proof"
  printf 'Engine slot mapped in shell log.\n'

  if [[ "$mode" == "bare-metal" ]]; then
    run_step "bare-metal output validation" "$outputs_cmd" validate --single
  fi

  printf '\nLaunchpad proof runner completed.\n'
  printf 'Proof log: %s\n' "$log_file"
}

case "$ACTION" in
  build-lab)
    proof_build_lab "$@"
    ;;
  release-candidate)
    proof_release_candidate "$@"
    ;;
  hardware-ready)
    proof_hardware_ready "$@"
    ;;
  booted-iso)
    proof_booted_iso "$@"
    ;;
  shell-launch)
    proof_shell_launch "$@"
    ;;
  launchpad)
    proof_launchpad "$@"
    ;;
  native-kms)
    proof_native_kms "$@"
    ;;
  visual)
    proof_visual "$@"
    ;;
  mc-preview)
    proof_mc_preview "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown proof action: $ACTION"
    ;;
esac
