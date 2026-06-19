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
ACTION="${1:-help}"
shift || true

usage() {
  cat <<'HELP'
Usage: vm.sh boot [enginedev|engineruntime] [options]

Boot a generated EngineOS ISO in a local QEMU test VM.

Options:
  --dry-run             Print the QEMU command without running it
  --iso <path>          Use a specific ISO instead of discovering one under out/
  --out-dir <path>      Directory to search for ISO artifacts (default: out/)
  --memory <MiB>        Guest memory in MiB (default: 4096)
  --cpus <N>            Guest CPU count (default: 2)
  --display <backend>   QEMU display backend: auto, gtk, sdl, egl-headless, or none (default: auto)
  --gl                  Enable QEMU virgl with virtio-vga-gl and a GL display backend
  --audio <mode>        QEMU audio device mode: none or hda (default: none)
  --background          Start QEMU in the background and write logs under artifacts/logs
  --ssh-port <port>     Forward host port to guest ssh port 22 (default: 2222)
  --no-kvm              Do not add -enable-kvm even when /dev/kvm exists
  --no-uefi             Do not add OVMF firmware arguments
  --qemu <path>         QEMU binary name or path (default: qemu-system-x86_64)

After the ISO boots, run:
  eos-proof booted-iso --vm        # EngineDev
  eos-proof booted-iso --runtime   # EngineRuntime
HELP
}

profile_iso_prefix() {
  case "$1" in
    enginedev)
      printf 'EngineDevOS'
      ;;
    engineruntime)
      printf 'EngineRuntimeOS'
      ;;
    *)
      die "unknown VM profile: $1"
      ;;
  esac
}

profile_proof_mode() {
  case "$1" in
    enginedev)
      printf 'vm'
      ;;
    engineruntime)
      printf 'runtime'
      ;;
    *)
      die "unknown VM profile: $1"
      ;;
  esac
}

latest_iso_for_profile() {
  local profile="$1"
  local out_dir="$2"
  local prefix

  prefix="$(profile_iso_prefix "$profile")"
  [[ -d "$out_dir" ]] || return 1
  find "$out_dir" -maxdepth 1 -type f -name "$prefix-*.iso" -printf '%T@ %p\n' 2>/dev/null |
    sort -n |
    tail -n 1 |
    cut -d' ' -f2-
}

find_ovmf_bios() {
  local candidate
  for candidate in \
    /usr/share/edk2/x64/OVMF.4m.fd \
    /usr/share/edk2/x64/OVMF.fd \
    /usr/share/edk2-ovmf/x64/OVMF.4m.fd \
    /usr/share/edk2-ovmf/x64/OVMF.fd \
    /usr/share/OVMF/OVMF.4m.fd \
    /usr/share/OVMF/OVMF.fd \
    /usr/share/ovmf/x64/OVMF.4m.fd \
    /usr/share/ovmf/x64/OVMF.fd; do
    if [[ -r "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

boot_vm() {
  local profile="enginedev"
  local dry_run=false
  local iso_path=""
  local out_dir="${ENGINEOS_OUT_DIR:-$ROOT/out}"
  local memory="4096"
  local cpus="2"
  local display="${ENGINEOS_VM_DISPLAY:-auto}"
  local gl=false
  local audio="${ENGINEOS_VM_AUDIO:-none}"
  local background=false
  local ssh_port="${ENGINEOS_VM_SSH_PORT:-2222}"
  local qemu_bin="${ENGINEOS_QEMU_BIN:-qemu-system-x86_64}"
  local use_kvm=true
  local use_uefi=true
  local proof_mode=""
  local ovmf_bios=""
  local log_dir="${ENGINEOS_LOG_DIR:-$(engineos_default_log_dir "$ROOT")}"
  local state_dir="${ENGINEOS_STATE_DIR:-$(engineos_default_state_dir "$ROOT")}"
  local qemu_log=""
  local serial_log=""
  local pid_file=""
  local cmd=()

  if [[ $# -gt 0 && "${1:-}" != --* ]]; then
    profile="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --iso)
        shift
        iso_path="${1:-}"
        [[ -n "$iso_path" ]] || die "--iso requires a path"
        ;;
      --out-dir)
        shift
        out_dir="${1:-}"
        [[ -n "$out_dir" ]] || die "--out-dir requires a path"
        ;;
      --memory)
        shift
        memory="${1:-}"
        [[ -n "$memory" ]] || die "--memory requires a value"
        ;;
      --cpus)
        shift
        cpus="${1:-}"
        [[ -n "$cpus" ]] || die "--cpus requires a value"
        ;;
      --display)
        shift
        display="${1:-}"
        [[ -n "$display" ]] || die "--display requires a backend"
        ;;
      --gl)
        gl=true
        ;;
      --audio)
        shift
        audio="${1:-}"
        [[ -n "$audio" ]] || die "--audio requires a mode"
        ;;
      --background)
        background=true
        ;;
      --ssh-port)
        shift
        ssh_port="${1:-}"
        [[ -n "$ssh_port" ]] || die "--ssh-port requires a port"
        ;;
      --qemu)
        shift
        qemu_bin="${1:-}"
        [[ -n "$qemu_bin" ]] || die "--qemu requires a binary"
        ;;
      --no-kvm)
        use_kvm=false
        ;;
      --no-uefi)
        use_uefi=false
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown vm boot option: $1"
        ;;
    esac
    shift
  done

  profile_iso_prefix "$profile" >/dev/null
  proof_mode="$(profile_proof_mode "$profile")"
  if [[ -z "$iso_path" ]]; then
    iso_path="$(latest_iso_for_profile "$profile" "$out_dir" || true)"
  fi
  [[ -n "$iso_path" ]] || die "no $profile ISO found in $out_dir; pass --iso <path>"
  [[ -f "$iso_path" ]] || die "ISO not found: $iso_path"

  if [[ "$display" == auto ]]; then
    if [[ "$gl" == true && -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
      display="egl-headless"
    elif [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]]; then
      display="gtk"
    else
      display="none"
    fi
  fi

  if [[ "$gl" == true && "$display" == "none" ]]; then
    die "--gl requires a GL-capable display backend such as egl-headless, gtk, or sdl"
  fi

  if [[ "$gl" == true && "$display" != *,* ]]; then
    display="${display},gl=on"
  elif [[ "$gl" == true && "$display" != *"gl="* ]]; then
    display="${display},gl=on"
  fi

  case "$audio" in
    none|hda)
      ;;
    *)
      die "unknown VM audio mode: $audio"
      ;;
  esac

  if [[ "$dry_run" == false ]]; then
    have_cmd "$qemu_bin" || die "$qemu_bin is missing; install QEMU or use a manual VM"
    if [[ "$background" == true ]]; then
      mkdir -p "$log_dir" "$state_dir"
      qemu_log="$log_dir/qemu-$profile.log"
      serial_log="$log_dir/qemu-$profile-serial.log"
      pid_file="$state_dir/qemu-$profile.pid"
      if [[ -s "$pid_file" ]] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1; then
        die "$profile VM already appears to be running with pid $(cat "$pid_file"); stop it before starting another"
      fi
    fi
  else
    qemu_log="$log_dir/qemu-$profile.log"
    serial_log="$log_dir/qemu-$profile-serial.log"
    pid_file="$state_dir/qemu-$profile.pid"
  fi

  cmd=(
    "$qemu_bin"
    -machine q35
    -m "$memory"
    -smp "$cpus"
    -boot d
    -cdrom "$iso_path"
    -netdev "user,id=net0,hostfwd=tcp::${ssh_port}-:22"
    -device virtio-net-pci,netdev=net0
  )

  if [[ "$gl" == true ]]; then
    cmd+=(-vga none -device virtio-vga-gl)
  fi

  cmd+=(-display "$display")

  if [[ "$audio" == hda ]]; then
    cmd+=(
      -audiodev none,id=audio0
      -device ich9-intel-hda
      -device hda-duplex,audiodev=audio0
    )
  fi

  if [[ "$background" == true ]]; then
    cmd+=(-serial "file:$serial_log" -daemonize -pidfile "$pid_file")
  else
    cmd+=(-serial mon:stdio)
  fi

  if [[ "$use_kvm" == true && -e /dev/kvm ]]; then
    cmd+=(-enable-kvm -cpu host)
  fi

  if [[ "$use_uefi" == true ]]; then
    if ovmf_bios="$(find_ovmf_bios)"; then
      cmd+=(-bios "$ovmf_bios")
    elif [[ "$dry_run" == true ]]; then
      cmd+=(-bios "<OVMF.fd>")
    else
      die "OVMF firmware not found; install OVMF firmware or pass --no-uefi"
    fi
  fi

  printf 'EngineOS VM boot\n'
  printf '  profile:  %s\n' "$profile"
  printf '  iso:      %s\n' "$iso_path"
  printf '  display:  %s\n' "$display"
  printf '  gl:       %s\n' "$gl"
  printf '  audio:    %s\n' "$audio"
  printf '  ssh:      host port %s -> guest port 22\n' "$ssh_port"
  if [[ "$background" == true ]]; then
    printf '  pidfile:  %s\n' "$pid_file"
    printf '  serial:   %s\n' "$serial_log"
    printf '  log:      %s\n' "$qemu_log"
  fi
  printf '  command:  '
  quote_cmd "${cmd[@]}"

  if [[ "$dry_run" == true ]]; then
    printf '\nAfter boot, run inside the guest:\n'
    printf '  eos-proof booted-iso --%s\n' "$proof_mode"
    exit 0
  fi

  if [[ "$background" == true ]]; then
    "${cmd[@]}" >"$qemu_log" 2>&1
    printf '\nStarted %s VM in background.\n' "$profile"
    printf 'Use ssh on host port %s after boot, then run:\n' "$ssh_port"
    printf '  eos-proof booted-iso --%s\n' "$proof_mode"
    return 0
  fi

  exec "${cmd[@]}"
}

case "$ACTION" in
  boot)
    boot_vm "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown vm action: $ACTION"
    ;;
esac
