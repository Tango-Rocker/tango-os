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
HELP
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
    run_step "validate boot" "$MODULE_DIR/validate_boot.sh" "${validate_args[@]}"
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
    run_step "shell binary dry-run" printf '%s\n' "command -v engineos-shell"
    run_step "shell process dry-run" printf '%s\n' "pgrep -a engineos-shell"
    run_step "shell log ownership dry-run" printf '%s\n' "grep -E 'engineos-shell mode=|client launch environment|renderer diagnostics' $shell_log"
    run_step "terminal/tmux ownership dry-run" printf '%s\n' "grep -E 'owner=engineos-shell|session command=tmux new -A -s engineos' $terminal_log"
    run_step "app launch ownership dry-run" printf '%s\n' "grep -F 'app launch app=terminal owner=engineos-shell' $app_log"
    run_step "renderer doctor dry-run" printf '%s\n' "eos-doctor --vm"
    if [[ "$mode" == "bare-metal" ]]; then
      run_step "bare-metal shell renderer dry-run" printf '%s\n' "grep -E 'renderer diagnostics|GLES2|EGL|wlr_renderer=(gles2|vulkan)' $shell_log && ! grep -Ei 'pixman|llvmpipe|softpipe|software renderer' $shell_log"
      run_step "bare-metal renderer rejection dry-run" printf '%s\n' "eos-validate boot --bare-metal"
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
  grep -F 'session command=tmux new -A -s engineos' "$terminal_log" >/dev/null ||
    die "terminal log does not show tmux session startup"

  if [[ -r "$app_log" ]]; then
    grep -F 'owner=engineos-shell' "$app_log" >/dev/null ||
      die "app log exists but does not show shell ownership"
    grep -F 'app launch app=terminal owner=engineos-shell' "$app_log" >/dev/null ||
      die "app log does not show terminal launch ownership"
  else
    printf 'WARN app log missing: %s\n' "$app_log"
  fi

  run_step "doctor renderer evidence" "$doctor_cmd" --vm
  if [[ "$mode" == "bare-metal" ]]; then
    run_step "bare-metal renderer validation" "$validate_cmd" boot --bare-metal
  fi

  printf '\nShell-launch proof runner completed.\n'
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
    run_step "engine slot outcome dry-run" printf '%s\n' "grep -E 'view mapped role=engine|role=engine.*process-exited-before-map|Quake assets missing|QuakeSpasm basedir=' $shell_log $engine_log"
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

  if grep -F 'view mapped role=engine' "$shell_log" >/dev/null; then
    printf 'Engine slot mapped in shell log.\n'
  elif grep -E 'role=engine.*process-exited-before-map|role=engine.*mapped=false' "$shell_log" >/dev/null; then
    printf 'Engine slot did not map; shell log has launch lifecycle failure evidence.\n'
    grep -F 'launchpad active slot=cube' "$shell_log" >/dev/null ||
      die "cube did not remain the active slot while engine was unavailable"
  elif [[ -r "$engine_log" ]] && grep -E 'Quake assets missing|QuakeSpasm basedir=' "$engine_log" >/dev/null; then
    printf 'Engine slot did not map; engine log has Quake asset/runtime outcome evidence.\n'
    grep -F 'launchpad active slot=cube' "$shell_log" >/dev/null ||
      die "cube did not remain the active slot while engine was unavailable"
  else
    die "engine slot outcome is inconclusive: no mapped engine view and no Quake asset/runtime evidence"
  fi

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
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown proof action: $ACTION"
    ;;
esac
