#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
FAILURES=0
WARNINGS=0
MOCK=false

usage() {
  cat <<'HELP'
Usage: validate_builder.sh [--mock]

Validate that the current machine is ready to run the Arch builder side of
PoC 0: shell build, local package repo build, and mkarchiso ISO build.
HELP
}

fail() {
  printf 'FAIL %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

warn() {
  printf 'WARN %s\n' "$*" >&2
  WARNINGS=$((WARNINGS + 1))
}

ok() {
  printf 'OK   %s\n' "$*"
}

require_cmd() {
  local tool="$1"
  if have_cmd "$tool"; then
    ok "command available: $tool"
  else
    fail "command missing: $tool"
  fi
}

optional_cmd() {
  local tool="$1"
  local reason="$2"
  if have_cmd "$tool"; then
    ok "optional command available: $tool"
  else
    warn "optional command missing: $tool ($reason)"
  fi
}

check_pkg_config_module() {
  local module="$1"
  if ! have_cmd pkg-config; then
    fail "pkg-config missing; cannot check $module"
    return
  fi
  if pkg-config --exists "$module"; then
    ok "pkg-config module available: $module"
  else
    fail "pkg-config module missing: $module"
  fi
}

check_builder_filesystem() {
  local fstype=""

  if have_cmd findmnt; then
    fstype="$(findmnt -no FSTYPE -T "$ROOT" 2>/dev/null || true)"
    if [[ -z "$fstype" ]]; then
      warn "could not determine filesystem type for $ROOT"
      return
    fi
    case "$fstype" in
      ext2|ext3|ext4|btrfs|xfs|f2fs|zfs)
        ok "builder filesystem looks Linux-native: $fstype"
        ;;
      drvfs|fuseblk|ntfs|cifs|smb3|vboxsf|9p|virtiofs)
        fail "builder repo is on $fstype; move it to a Linux filesystem such as /srv/engineos"
        ;;
      *)
        warn "builder filesystem is unrecognized: $fstype"
        ;;
    esac
  else
    warn "findmnt unavailable; cannot verify builder filesystem"
  fi
}

check_repo_location() {
  if [[ "$ROOT" == "/srv/engineos" ]]; then
    ok "repo root matches archiso local repo path: /srv/engineos"
  else
    fail "repo root must be /srv/engineos because archiso pacman.conf uses file:///srv/engineos/repo/\$arch; current root: $ROOT"
  fi
}

check_ovmf() {
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
      ok "OVMF firmware available: $candidate"
      return
    fi
  done
  warn "OVMF firmware not found; QEMU UEFI test boots need it"
}

kb_to_gib_label() {
  local kb="$1"
  awk -v kb="$kb" 'BEGIN { printf "%.1f GiB", kb / 1024 / 1024 }'
}

check_builder_resources() {
  local mem_kb=0
  local swap_kb=0
  local cpus=0
  local tmp_size=""

  if [[ -r /proc/meminfo ]]; then
    mem_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
    swap_kb="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)"
    if [[ "$mem_kb" -ge 4194304 ]]; then
      ok "builder RAM: $(kb_to_gib_label "$mem_kb")"
    else
      warn "builder RAM is low: $(kb_to_gib_label "$mem_kb"); prefer 4-8 GiB for mkarchiso"
    fi
    if [[ "$swap_kb" -ge 3900000 ]]; then
      ok "builder swap: $(kb_to_gib_label "$swap_kb")"
    else
      warn "builder swap is low: $(kb_to_gib_label "$swap_kb"); use at least 4 GiB swap"
    fi
  else
    warn "/proc/meminfo unavailable; cannot check RAM/swap"
  fi

  if have_cmd nproc; then
    cpus="$(nproc)"
    if [[ "$cpus" -ge 4 ]]; then
      ok "builder CPU count: $cpus"
    else
      warn "builder CPU count is low: $cpus; prefer 4+ CPUs for package and ISO builds"
    fi
  fi

  if have_cmd findmnt; then
    tmp_size="$(findmnt -bno SIZE -T /tmp 2>/dev/null || true)"
    if [[ -n "$tmp_size" && "$tmp_size" -ge 8589934592 ]]; then
      ok "/tmp build space: at least 8 GiB"
    elif [[ -n "$tmp_size" ]]; then
      warn "/tmp build space is below 8 GiB; engineos build iso will try sudo remount,size=8G"
    else
      warn "could not determine /tmp size"
    fi
  fi

  if grep -E '"-processors"[[:space:]]+"[1-4]"' "$ROOT/archiso/enginedev/profiledef.sh" >/dev/null 2>&1; then
    ok "EngineDev SquashFS processor limit is capped for low-memory builds"
  else
    warn "EngineDev SquashFS processor limit is not capped at 1-4; low-memory builders may fail"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mock)
      MOCK=true
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown validate_builder option: $1"
      ;;
  esac
  shift
done

printf 'EngineOS builder validation\n'
printf '  root: %s\n' "$ROOT"
printf '  timestamp_utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ "$MOCK" == true ]]; then
  ok "mock Arch builder"
  ok "mock repo root /srv/engineos"
  ok "mock Linux-native filesystem"
  ok "mock build commands"
  ok "mock wlroots pkg-config modules"
  printf 'Builder validation summary: 0 failure(s), 0 warning(s)\n'
  exit 0
fi

if is_arch_linux; then
  ok "host is Arch Linux"
else
  fail "real builder validation must run on Arch Linux"
fi

check_repo_location
check_builder_filesystem
check_builder_resources

for tool in bash git sudo makepkg repo-add mkarchiso meson ninja pkg-config gcc python3 sha256sum; do
  require_cmd "$tool"
done

check_pkg_config_module wlroots-0.19
check_pkg_config_module wayland-server
check_pkg_config_module xkbcommon

optional_cmd qemu-system-x86_64 "needed only for engineos vm boot"
check_ovmf

if [[ -x "$ROOT/tools/engineos/engineos" ]]; then
  ok "source-tree engineos command exists"
else
  fail "source-tree engineos command missing"
fi

printf 'Builder validation summary: %s failure(s), %s warning(s)\n' "$FAILURES" "$WARNINGS"
[[ "$FAILURES" -eq 0 ]]
