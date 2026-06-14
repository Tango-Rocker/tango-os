#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
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
HELP
}

default_log_dir() {
  engineos_default_log_dir "$ROOT"
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

engineos_command() {
  if [[ -x "$ROOT/tools/engineos/engineos" ]]; then
    printf '%s\n' "$ROOT/tools/engineos/engineos"
  else
    printf '%s\n' engineos
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
    run_step "validate builder mock" "$SCRIPT_DIR/validate_builder.sh" --mock
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

  printf '\nBuild-lab proof runner completed.\n'
  if [[ "$dry_run" == true ]]; then
    printf 'Next Arch builder command: ./tools/engineos/engineos proof build-lab\n'
  else
    printf 'Next test VM command: ./tools/engineos/engineos vm boot enginedev\n'
    printf 'Next booted ISO command: engineos proof booted-iso --vm\n'
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
    run_step "validate builder mock" "$SCRIPT_DIR/validate_builder.sh" --mock
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

  printf '\nRelease-candidate proof runner completed.\n'
  if [[ "$dry_run" == true ]]; then
    printf 'Next Arch builder command: ./tools/engineos/engineos proof release-candidate\n'
  else
    printf 'Next test VM command: ./tools/engineos/engineos vm boot enginedev\n'
    printf 'Next runtime VM command: ./tools/engineos/engineos vm boot engineruntime\n'
    printf 'Next hardware proof: boot EngineRuntime on the AMD machine and run engineos proof booted-iso --bare-metal\n'
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

  usb_write_cmd=("$SCRIPT_DIR/usb.sh" write --profile "$profile" --out-dir "$out_dir" --device "${device:-/dev/sdX}" --dry-run)

  if [[ "$dry_run" == true ]]; then
    run_step "preflight all dry-run" printf '%s\n' "./tools/engineos/engineos preflight all"
    run_step "release-candidate dry-run" printf '%s\n' "./tools/engineos/engineos proof release-candidate --dry-run --out-dir $out_dir"
    run_step "USB candidate list dry-run" printf '%s\n' "./tools/engineos/engineos usb list"
    run_step "USB write dry-run" printf '%s\n' "./tools/engineos/engineos usb write --profile $profile --out-dir $out_dir --device ${device:-/dev/sdX} --dry-run"
    run_step "booted bare-metal proof dry-run" printf '%s\n' "engineos proof booted-iso --bare-metal"
  else
    run_step "preflight all" "$SCRIPT_DIR/preflight.sh" all
    run_step "release checklist dry-run" "$SCRIPT_DIR/release.sh" checklist --dry-run --out-dir "$out_dir"
    run_step "USB candidate list" "$SCRIPT_DIR/usb.sh" list
    if [[ -n "$device" ]]; then
      run_step "USB write dry-run" "${usb_write_cmd[@]}"
    else
      printf '\nNo --device provided; inspect the USB candidate list and re-run with --device /dev/sdX.\n'
      printf 'USB write dry-run command: '
      quote_cmd "${usb_write_cmd[@]}"
    fi
  fi

  printf '\nHardware-ready proof runner completed.\n'
  printf 'This proof does not write USB media or prove AMD hardware by itself.\n'
  printf 'After writing the ISO and booting the target AMD machine, run:\n'
  printf '  engineos proof booted-iso --bare-metal\n'
}

proof_booted_iso() {
  local dry_run=false
  local mode="vm"
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local log_file
  local validate_args=(--vm)
  local doctor_args=(--vm)
  local crash_bundle_args=(--vm)
  local engineos_cmd

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

  engineos_cmd="$(engineos_command)"

  if [[ "$dry_run" == true ]]; then
    run_step "validate boot dry-run" printf '%s\n' "engineos validate boot ${validate_args[*]}"
    run_step "doctor dry-run" printf '%s\n' "engineos doctor ${doctor_args[*]}"
    run_step "smoke test dry-run" printf '%s\n' "engineos test smoke"
    run_step "Quake smoke dry-run" printf '%s\n' "engineos run quake --smoke"
    run_step "asset guidance dry-run" printf '%s\n' "engineos assets explain quake"
    run_step "engine logs dry-run" printf '%s\n' "engineos logs engine --last 200"
    if [[ "$mode" == "bare-metal" ]]; then
      run_step "output validation dry-run" printf '%s\n' "engineos outputs validate --single"
    fi
    if [[ "$mode" == "runtime" || "$mode" == "bare-metal" ]]; then
      run_step "runtime reliability dry-run" printf '%s\n' "engineos test reliability"
      run_step "runtime logs dry-run" printf '%s\n' "engineos logs runtime --last 200"
    fi
    run_step "crash bundle dry-run" printf '%s\n' "engineos crash-bundle ${crash_bundle_args[*]}"
  else
    run_step "validate boot" "$SCRIPT_DIR/validate_boot.sh" "${validate_args[@]}"
    run_step "doctor" "$SCRIPT_DIR/doctor.sh" "${doctor_args[@]}"
    run_step "smoke test" "$SCRIPT_DIR/test_runner.sh" smoke
    run_step "Quake smoke" "$engineos_cmd" run quake --smoke
    run_step "asset guidance" "$engineos_cmd" assets explain quake
    run_step "engine logs" "$engineos_cmd" logs engine --last 200
    if [[ "$mode" == "bare-metal" ]]; then
      run_step "output validation" "$engineos_cmd" outputs validate --single
    fi
    if [[ "$mode" == "runtime" || "$mode" == "bare-metal" ]]; then
      run_step "runtime reliability" "$SCRIPT_DIR/test_runner.sh" reliability
      run_step "runtime logs" "$engineos_cmd" logs runtime --last 200
    fi
    run_step "crash bundle" "$SCRIPT_DIR/crash_bundle.sh" "${crash_bundle_args[@]}"
  fi

  printf '\nBooted-ISO proof runner completed.\n'
  if [[ "$dry_run" == true ]]; then
    printf 'Next booted ISO command: engineos proof booted-iso --%s\n' "$mode"
  else
    printf 'Proof log: %s\n' "$log_file"
  fi
}

proof_shell_launch() {
  local dry_run=false
  local mode="vm"
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local log_file
  local engineos_cmd
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

  engineos_cmd="$(engineos_command)"
  shell_log="$log_dir/shell.log"
  terminal_log="$log_dir/terminal.log"
  app_log="$log_dir/app.log"

  if [[ "$dry_run" == true ]]; then
    run_step "shell binary dry-run" printf '%s\n' "command -v engineos-shell"
    run_step "shell process dry-run" printf '%s\n' "pgrep -a engineos-shell"
    run_step "shell log ownership dry-run" printf '%s\n' "grep -E 'engineos-shell mode=|client launch environment|renderer diagnostics' $shell_log"
    run_step "terminal/tmux ownership dry-run" printf '%s\n' "grep -E 'owner=engineos-shell|session command=tmux new -A -s engineos' $terminal_log"
    run_step "app launch ownership dry-run" printf '%s\n' "grep -E 'app launch app=quake owner=engineos-shell' $app_log"
    run_step "renderer doctor dry-run" printf '%s\n' "engineos doctor --vm"
    if [[ "$mode" == "bare-metal" ]]; then
      run_step "bare-metal renderer rejection dry-run" printf '%s\n' "engineos validate boot --bare-metal"
    fi
    printf '\nShell-launch proof dry-run completed.\n'
    return
  fi

  run_step "shell binary" command -v engineos-shell
  run_step "shell process" pgrep -a engineos-shell
  run_step "app launcher status" "$engineos_cmd" app status
  run_step "shell logs" "$engineos_cmd" logs shell --last 200

  [[ -r "$shell_log" ]] || die "shell log missing: $shell_log"
  grep -E 'engineos-shell mode=' "$shell_log" >/dev/null ||
    die "shell log does not show engineos-shell startup"
  grep -E 'client launch environment' "$shell_log" >/dev/null ||
    die "shell log does not show shell-owned client environment"
  grep -E 'renderer diagnostics' "$shell_log" >/dev/null ||
    die "shell log does not show renderer diagnostics"

  [[ -r "$terminal_log" ]] || die "terminal log missing: $terminal_log"
  grep -F 'owner=engineos-shell' "$terminal_log" >/dev/null ||
    die "terminal log does not show shell ownership"
  grep -F 'session command=tmux new -A -s engineos' "$terminal_log" >/dev/null ||
    die "terminal log does not show tmux session startup"

  if [[ -r "$app_log" ]]; then
    grep -F 'owner=engineos-shell' "$app_log" >/dev/null ||
      die "app log exists but does not show shell ownership"
  else
    printf 'WARN app log missing: %s\n' "$app_log"
  fi

  run_step "doctor renderer evidence" "$engineos_cmd" doctor --vm
  if [[ "$mode" == "bare-metal" ]]; then
    run_step "bare-metal renderer validation" "$engineos_cmd" validate boot --bare-metal
  fi

  printf '\nShell-launch proof runner completed.\n'
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
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown proof action: $ACTION"
    ;;
esac
