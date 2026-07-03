#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
if [[ -r /etc/engineos/profile.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/engineos/profile.conf
fi
MODE="host"
virt=""
lspci_output=""
glx_output=""
egl_output=""
vk_output=""

usage() {
  cat <<'HELP'
Usage: doctor.sh [--vm|--bare-metal]

Collect EngineOS diagnostics for the builder VM, test VM, or bare-metal host.
HELP
}

print_kv() {
  printf '%-24s %s\n' "$1:" "$2"
}

section() {
  printf '\n## %s\n' "$1"
}

cmd_version() {
  local tool="$1"
  if have_cmd "$tool"; then
    local first_line
    first_line="$("$tool" --version 2>/dev/null | head -n 1 || true)"
    if [[ -n "$first_line" ]]; then
      print_kv "$tool" "$first_line"
    else
      print_kv "$tool" "$(command -v "$tool")"
    fi
  else
    print_kv "$tool" "missing"
  fi
}

run_optional() {
  local label="$1"
  shift
  if have_cmd "$1"; then
    printf '\n# %s\n' "$label"
    "$@" 2>&1 || true
  else
    print_kv "$label" "unavailable"
  fi
}

detect_renderer_warning() {
  local text="$1"
  if printf '%s\n' "$text" | grep -Eiq 'llvmpipe|softpipe|software rasterizer'; then
    printf 'WARNING: software renderer detected; this is acceptable for some VM smoke tests but not AMD bare-metal validation.\n'
  fi
}

has_graphical_display() {
  [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]]
}

has_drm_render_node() {
  [[ -d /dev/dri ]] && find /dev/dri -maxdepth 1 -name 'renderD*' -print -quit 2>/dev/null | grep -q .
}

run_glx_probe() {
  if has_graphical_display; then
    if have_cmd glxinfo; then
      glx_output="$(glxinfo -B 2>&1 || true)"
      printf '\n# glxinfo -B\n%s\n' "$glx_output"
      detect_renderer_warning "$glx_output"
    else
      print_kv "glxinfo" "unavailable"
    fi
  elif have_cmd xvfb-run && have_cmd glxinfo; then
    glx_output="$(xvfb-run -a glxinfo -B 2>&1 || true)"
    printf '\n# xvfb-run glxinfo -B\n%s\n' "$glx_output"
    detect_renderer_warning "$glx_output"
  else
    print_kv "glxinfo -B" "skipped; no display and xvfb-run unavailable"
  fi
}

run_egl_probe() {
  if have_cmd eglinfo; then
    egl_output="$(eglinfo -B 2>&1 || true)"
    printf '\n# eglinfo -B\n%s\n' "$egl_output"
    detect_renderer_warning "$egl_output"
  else
    print_kv "eglinfo" "unavailable"
  fi
}

bare_metal_summary() {
  section "Bare-Metal AMD Readiness"

  if [[ -n "$virt" && "$virt" != "none" ]]; then
    print_kv "virtualization" "detected: $virt"
    printf 'WARNING: bare-metal validation should run on the target AMD machine, not inside a VM/container.\n'
  elif [[ "$virt" == "none" ]]; then
    print_kv "virtualization" "none detected"
  else
    print_kv "virtualization" "unknown"
  fi

  if have_cmd tty; then
    local tty_output
    if tty_output="$(tty 2>/dev/null)" && [[ -n "$tty_output" ]]; then
      print_kv "controlling tty" "$tty_output"
    else
      print_kv "controlling tty" "not-a-tty"
    fi
  else
    print_kv "controlling tty" "unavailable"
  fi
  print_kv "XDG_SESSION_ID" "${XDG_SESSION_ID:-unset}"
  print_kv "XDG_SESSION_TYPE" "${XDG_SESSION_TYPE:-unset}"
  print_kv "XDG_VTNR" "${XDG_VTNR:-unset}"

  if have_cmd loginctl && [[ -n "${XDG_SESSION_ID:-}" ]]; then
    printf '\n# loginctl session\n'
    loginctl show-session "$XDG_SESSION_ID" -p Type -p Active -p Remote -p State -p Class -p Seat 2>&1 || true
  else
    print_kv "loginctl session" "unavailable"
  fi

  if have_cmd systemctl; then
    printf '\n# systemd-logind\n'
    systemctl status systemd-logind --no-pager 2>&1 || true
  else
    print_kv "systemd-logind" "unavailable"
  fi

  if [[ -d /dev/dri ]]; then
    print_kv "/dev/dri" "present"
    if find /dev/dri -maxdepth 1 -name 'card*' -print -quit 2>/dev/null | grep -q .; then
      print_kv "DRM cards" "$(find /dev/dri -maxdepth 1 -name 'card*' -printf '%f ' 2>/dev/null)"
    else
      print_kv "DRM cards" "missing"
      printf 'WARNING: no DRM card nodes found; wlroots TTY/KMS startup will fail.\n'
    fi
    if find /dev/dri -maxdepth 1 -name 'renderD*' -print -quit 2>/dev/null | grep -q .; then
      print_kv "render nodes" "$(find /dev/dri -maxdepth 1 -name 'renderD*' -printf '%f ' 2>/dev/null)"
    else
      print_kv "render nodes" "missing"
    fi
  else
    print_kv "/dev/dri" "missing"
    printf 'WARNING: /dev/dri is required for bare-metal graphics validation.\n'
  fi

  if [[ -d /sys/class/drm ]] && find /sys/class/drm -maxdepth 1 -name 'card*' -print -quit 2>/dev/null | grep -q .; then
    print_kv "sysfs DRM cards" "$(find /sys/class/drm -maxdepth 1 -name 'card*' -printf '%f ' 2>/dev/null)"
  else
    print_kv "sysfs DRM cards" "missing"
  fi

  if [[ -n "$lspci_output" ]]; then
    if printf '%s\n' "$lspci_output" | grep -Ei 'VGA|Display|3D' | grep -Eiq 'Advanced Micro Devices|AMD|ATI'; then
      print_kv "AMD display device" "visible"
    else
      print_kv "AMD display device" "not found in lspci display devices"
      printf 'WARNING: target MVP hardware expects an AMD GPU/display device.\n'
    fi
  else
    print_kv "AMD display device" "unavailable"
  fi

  if printf '%s\n%s\n%s\n' "$glx_output" "$egl_output" "$vk_output" | grep -Eiq 'llvmpipe|softpipe|software rasterizer'; then
    print_kv "software renderer" "detected"
    printf 'WARNING: software rendering is not acceptable for bare-metal MVP validation.\n'
  elif [[ -n "$glx_output$egl_output$vk_output" ]]; then
    print_kv "software renderer" "not detected in collected renderer output"
  else
    print_kv "software renderer" "unknown; OpenGL/Vulkan probes unavailable"
  fi

  if [[ -n "$vk_output" ]]; then
    if printf '%s\n' "$vk_output" | grep -Eiq 'AMD|RADV|Radeon|Advanced Micro Devices'; then
      print_kv "Vulkan AMD device" "visible"
    else
      print_kv "Vulkan AMD device" "not obvious in vulkaninfo summary"
    fi
  else
    print_kv "Vulkan AMD device" "unavailable"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)
      MODE="vm"
      ;;
    --bare-metal)
      MODE="bare-metal"
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown doctor option: $1"
      ;;
  esac
  shift
done

printf 'EngineOS doctor\n'
print_kv "root" "$ROOT"
print_kv "mode" "$MODE"
print_kv "timestamp_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

section "Host and Virtualization"
if have_cmd systemd-detect-virt; then
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  [[ -n "$virt" ]] || virt="none"
  print_kv "systemd-detect-virt" "$virt"
else
  print_kv "systemd-detect-virt" "unavailable"
fi

if [[ -r /sys/class/dmi/id/sys_vendor ]]; then
  print_kv "dmi vendor" "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
fi
if [[ -r /sys/class/dmi/id/product_name ]]; then
  print_kv "dmi product" "$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
fi

section "Kernel"
uname -a 2>/dev/null || true
if have_cmd cat && [[ -r /etc/os-release ]]; then
  grep -E '^(NAME|VERSION|ID)=' /etc/os-release 2>/dev/null || true
fi

section "GPU"
if have_cmd lspci; then
  lspci_output="$(lspci -nnk 2>&1 || true)"
  printf '\n# lspci display devices\n%s\n' "$lspci_output"
else
  print_kv "lspci display devices" "unavailable"
fi

run_glx_probe
run_egl_probe

if ! has_drm_render_node; then
  print_kv "vulkaninfo --summary" "skipped; no DRM render node available"
elif have_cmd vulkaninfo; then
  vk_output="$(vulkaninfo --summary 2>&1 || true)"
  printf '\n# vulkaninfo --summary\n%s\n' "$vk_output"
  detect_renderer_warning "$vk_output"
else
  print_kv "vulkaninfo" "unavailable"
fi

section "Display"
print_kv "XDG_SESSION_TYPE" "${XDG_SESSION_TYPE:-unset}"
print_kv "WAYLAND_DISPLAY" "${WAYLAND_DISPLAY:-unset}"
print_kv "DISPLAY" "${DISPLAY:-unset}"
if [[ -d /dev/dri ]]; then
  ls -la /dev/dri 2>/dev/null || true
else
  print_kv "/dev/dri" "unavailable"
fi
if [[ -d /sys/class/drm ]]; then
  find /sys/class/drm -maxdepth 1 -type l -printf '%f\n' 2>/dev/null || true
else
  print_kv "/sys/class/drm" "unavailable"
fi
if [[ -x "$SCRIPT_DIR/outputs.sh" ]]; then
  printf '\n# eos-outputs\n'
  "$SCRIPT_DIR/outputs.sh" list 2>&1 || true
fi

if [[ "$MODE" == "bare-metal" ]]; then
  bare_metal_summary
fi

section "Network"
if have_cmd hostname; then
  print_kv "hostname" "$(hostname 2>/dev/null || printf 'unavailable')"
else
  print_kv "hostname" "$(uname -n 2>/dev/null || printf 'unavailable')"
fi
if [[ -r /etc/resolv.conf ]]; then
  printf '\n# /etc/resolv.conf\n'
  sed -n '1,80p' /etc/resolv.conf 2>/dev/null || true
else
  print_kv "/etc/resolv.conf" "unavailable"
fi
run_optional "ip address" ip addr show
run_optional "ip route" ip route show
run_optional "resolvectl status" resolvectl status
run_optional "nmcli general status" nmcli general status
run_optional "nmcli device status" nmcli device status
if have_cmd systemctl; then
  printf '\n# NetworkManager.service\n'
  systemctl status NetworkManager.service --no-pager 2>&1 || true
else
  print_kv "NetworkManager.service" "unavailable"
fi

section "Audio"
if have_cmd systemctl; then
  systemctl --user status pipewire.socket pipewire.service pipewire-pulse.socket pipewire-pulse.service wireplumber.service --no-pager 2>&1 || true
else
  print_kv "systemctl" "unavailable"
fi
if [[ -d /dev/snd ]]; then
  printf '\n# /dev/snd\n'
  ls -la /dev/snd 2>&1 || true
else
  print_kv "/dev/snd" "missing"
fi
if [[ -r /proc/asound/cards ]]; then
  printf '\n# /proc/asound/cards\n'
  cat /proc/asound/cards 2>&1 || true
else
  print_kv "/proc/asound/cards" "unavailable"
fi
run_optional "aplay -l" aplay -l
run_optional "pactl info" pactl info
run_optional "pactl list short sinks" pactl list short sinks
run_optional "pactl list short sources" pactl list short sources

section "Build Tools"
for tool in mkarchiso gcc clang meson ninja cmake makepkg repo-add pkgconf git jq rg fd; do
  cmd_version "$tool"
done

section "EngineOS"
if have_cmd git && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  print_kv "git commit" "$(git -C "$ROOT" rev-parse --short HEAD)"
  print_kv "git branch" "$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"
else
  print_kv "git commit" "not a git repository"
fi
print_kv "profile" "${ENGINEOS_PROFILE:-unknown}"

if have_cmd pacman; then
  printf '\n# package versions\n'
  pacman -Q 2>/dev/null | awk '$1 ~ /^(archiso|mesa|wlroots|wayland|pipewire|wireplumber)$/ || $1 ~ /^engineos-/ {print}' || true
else
  print_kv "pacman" "unavailable"
fi

section "Command Surface"
if [[ -x "$ROOT/tools/engineos/eos" ]]; then
  "$ROOT/tools/engineos/eos" --help || true
elif have_cmd eos; then
  eos --help || true
else
  print_kv "eos" "unavailable"
fi
