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

DEFAULT_REPO_URL="${ENGINEOS_OFFICIAL_REPO_URL:-https://github.com/Tango-Rocker/tango-os.git}"
DEFAULT_SYSTEM_DEVICE="${ENGINEOS_INSTALL_DEFAULT_DEVICE:-/dev/disk/by-id/ata-WDC_WD10EZEX-00WN4A0_WD-WCC6Y1ZP5EAX}"
DEFAULT_HOME_NTFS_SOURCE="${ENGINEOS_INSTALL_HOME_NTFS_SOURCE:-LABEL=Tango}"
DEFAULT_HOME_NTFS_OPTIONS="${ENGINEOS_INSTALL_HOME_NTFS_OPTIONS:-uid=1000,gid=1000,umask=022,fmask=133,dmask=022,windows_names,nofail,x-systemd.device-timeout=10s}"
PACKAGED_POST_INSTALL_PAYLOAD="/usr/share/engineos/post-install-payload"
SOURCE_POST_INSTALL_PAYLOAD="/srv/engineos/tools/post-install-payload"

usage() {
  cat <<'HELP'
Usage: install_dev.sh dev --dry-run [--device <block-device>] [options]
       install_dev.sh dev [--device <block-device>] --yes-i-understand-this-wipes-device [options]

Plan an EngineDev bare-metal autoinstall.

Options:
  --device path            Target whole-disk block device
                           (default: current Windows F: disk by-id path)
  --target path            Temporary install mountpoint (default: /mnt/engineos)
  --home-ntfs-source spec  Existing NTFS volume to mount at /home
                           (default: LABEL=Tango, current Windows E:)
  --home-ntfs-options opts Mount options for the NTFS /home volume
  --no-home-ntfs           Keep /home on the installed root filesystem
  --repo-url url           Tang-OS Git repo to clone into /srv/engineos
  --repo-token-file path   Optional file containing a GitHub token for private repo clone
  --repo-seed path         Optional local repo/checkout copied into target /tmp for VM proof
  --package-cache path     Host/ISO package cache for pacstrap (default: /opt/engineos/install-cache/pkg)
  --no-package-cache       Ignore any ISO package cache and use pacman defaults
  --branch name            Optional Git branch to check out after clone
  --hostname name          Installed hostname (default: enginedev)
  --root-size size         Root partition size for sfdisk (default: 64G)
  --var-size size          /var partition size for sfdisk (default: 128G)
  --user name              Installed dev user (default: dev)
  --skip-codex             Do not install Codex during post-install
  --dry-run                Print the install plan only
  --yes-i-understand-this-wipes-device
                            Required for destructive install mode
  -h, --help               Show this help

Real mode is destructive. Prove the plan in a VM before using it on hardware.
HELP
}

quote_line() {
  printf '  '
  quote_cmd "$@"
}

require_whole_disk_shape() {
  local device="$1"

  [[ -n "$device" ]] || die "--device is required"
  [[ "$device" == /dev/* ]] || die "target device must be under /dev: $device"

  if [[ "${ENGINEOS_INSTALL_ALLOW_FAKE_DEVICE:-}" == "true" ]]; then
    return
  fi

  if [[ -e "$device" && ! -b "$device" ]]; then
    die "target exists but is not a block device: $device"
  fi
}

partition_paths() {
  local device="$1"
  if [[ "$device" == /dev/disk/by-id/* || "$device" == /dev/disk/by-path/* ]]; then
    printf '%s\n' "${device}-part1" "${device}-part2" "${device}-part3" "${device}-part4"
  elif [[ "$device" == /dev/nvme* || "$device" == /dev/mmcblk* ]]; then
    printf '%s\n' "${device}p1" "${device}p2" "${device}p3" "${device}p4"
  else
    printf '%s\n' "${device}1" "${device}2" "${device}3" "${device}4"
  fi
}

run_step() {
  local label="$1"
  shift

  printf '\n==> %s\n' "$label"
  printf '    '
  quote_cmd "$@"
  "$@"
}

run_sudo() {
  run_step "$1" sudo "${@:2}"
}

require_command() {
  local cmd="$1"
  have_cmd "$cmd" || die "$cmd is required for EngineDev install"
}

installed_post_install_payload() {
  local target="$1"
  local packaged_script="$target$PACKAGED_POST_INSTALL_PAYLOAD/scripts/setup_dev_environment.sh"

  if [[ -x "$packaged_script" ]]; then
    printf '%s\n' "$PACKAGED_POST_INSTALL_PAYLOAD"
  else
    printf '%s\n' "$SOURCE_POST_INSTALL_PAYLOAD"
  fi
}

ensure_host_pacman_servers() {
  local mirrorlist="/etc/pacman.d/mirrorlist"

  [[ "${ENGINEOS_INSTALL_ALLOW_FAKE_DEVICE:-}" == "true" ]] && return
  [[ -r "$mirrorlist" ]] || return
  if grep -Eq '^[[:space:]]*Server[[:space:]]*=' "$mirrorlist" 2>/dev/null; then
    return
  fi
  if ! grep -Eq '^#Server[[:space:]]*=' "$mirrorlist" 2>/dev/null; then
    printf 'WARN pacman mirrorlist has no candidate servers; pacstrap may fail\n'
    return
  fi

  run_sudo "enable first packaged pacman mirror" cp "$mirrorlist" "$mirrorlist.engineos-install.bak"
  run_sudo "activate first packaged pacman mirror" sed -i '0,/^#Server[[:space:]]*=/{s/^#Server[[:space:]]*=/Server =/}' "$mirrorlist"
}

ensure_host_pacman_keyring() {
  local keyring_dir="/etc/pacman.d/gnupg"

  [[ "${ENGINEOS_INSTALL_ALLOW_FAKE_DEVICE:-}" == "true" ]] && return
  have_cmd pacman-key || return
  if [[ -r "$keyring_dir/pubring.gpg" ]]; then
    return
  fi

  run_sudo "initialize live pacman keyring" pacman-key --init
  run_sudo "populate live pacman keyring" pacman-key --populate archlinux
}

target_has_mounts() {
  local device="$1"
  lsblk -nr -o MOUNTPOINTS "$device" 2>/dev/null | grep -q .
}

wait_for_partitions() {
  local boot_part="$1"
  local root_part="$2"
  local var_part="$3"
  local srv_part="$4"
  local _i

  if [[ "${ENGINEOS_INSTALL_ALLOW_FAKE_DEVICE:-}" == "true" ]]; then
    return
  fi

  for _i in 1 2 3 4 5; do
    [[ -b "$boot_part" && -b "$root_part" && -b "$var_part" && -b "$srv_part" ]] && return
    sleep 1
  done

  die "partition devices did not appear: $boot_part $root_part $var_part $srv_part"
}

resolve_home_ntfs_source() {
  local source="$1"
  local resolved=""

  [[ -n "$source" ]] || return 0

  if [[ "$source" == /dev/* ]]; then
    if [[ "${ENGINEOS_INSTALL_ALLOW_FAKE_DEVICE:-}" == "true" ]]; then
      printf '%s\n' "$source"
      return
    fi
    [[ -b "$source" ]] || die "NTFS /home source is not a block device: $source"
    printf '%s\n' "$source"
    return
  fi

  case "$source" in
    LABEL=*|UUID=*|PARTUUID=*)
      if [[ "${ENGINEOS_INSTALL_ALLOW_FAKE_DEVICE:-}" == "true" ]]; then
        printf '%s\n' "$source"
        return
      fi
      resolved="$(findfs "$source" 2>/dev/null || true)"
      [[ -n "$resolved" ]] || die "could not resolve NTFS /home source: $source"
      [[ -b "$resolved" ]] || die "resolved NTFS /home source is not a block device: $resolved"
      printf '%s\n' "$source"
      ;;
    none|"")
      ;;
    *)
      die "NTFS /home source must be /dev/..., LABEL=..., UUID=..., PARTUUID=..., or none: $source"
      ;;
  esac
}

package_cache_has_packages() {
  local cache_dir="$1"
  [[ -n "$cache_dir" && -d "$cache_dir" ]] || return 1
  find "$cache_dir" -maxdepth 1 -type f -name '*.pkg.tar*' -print -quit 2>/dev/null | grep -q .
}

package_name_from_artifact() {
  local artifact="$1"
  local filename stem without_arch without_pkgrel

  filename="${artifact##*/}"
  stem="${filename%%.pkg.tar*}"
  without_arch="${stem%-*}"
  without_pkgrel="${without_arch%-*}"
  printf '%s\n' "${without_pkgrel%-*}"
}

package_cache_artifact_count() {
  local cache_dir="$1"
  find "$cache_dir" -maxdepth 1 -type f -name '*.pkg.tar*' 2>/dev/null | wc -l | tr -d '[:space:]'
}

validate_package_cache() {
  local cache_dir="$1"
  shift
  local package artifact name missing=()
  declare -A cached_packages=()

  package_cache_has_packages "$cache_dir" || return 1

  while IFS= read -r -d '' artifact; do
    name="$(package_name_from_artifact "$artifact")"
    [[ -n "$name" ]] && cached_packages["$name"]=1
  done < <(find "$cache_dir" -maxdepth 1 -type f -name '*.pkg.tar*' -print0 2>/dev/null)

  for package in "$@"; do
    if [[ -z "${cached_packages[$package]:-}" ]]; then
      missing+=("$package")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'EngineDev install package cache is incomplete: %s\n' "$cache_dir" >&2
    printf 'Missing requested package artifacts:\n' >&2
    printf '  - %s\n' "${missing[@]}" >&2
    printf 'Rebuild EngineDev with install-cache enabled, or pass --no-package-cache to use mirrors.\n' >&2
    return 2
  fi
}

write_pacstrap_pacman_conf() {
  local cache_dir="$1"
  local out="$2"
  local source_conf="${ENGINEOS_INSTALL_PACMAN_CONF:-/etc/pacman.conf}"

  [[ -r "$source_conf" ]] || die "host pacman.conf is not readable: $source_conf"
  awk -v cache_dir="$cache_dir" '
    /^\[options\][[:space:]]*$/ {
      print
      print "CacheDir = " cache_dir
      print "CacheDir = /var/cache/pacman/pkg"
      next
    }
    { print }
  ' "$source_conf" >"$out"
}

write_sfdisk_layout() {
  local root_size="$1"
  local var_size="$2"
  cat <<EOF
label: gpt
,1G,U
,$root_size,L
,$var_size,L
,,L
EOF
}

write_pacman_engineos_repo() {
  local target="$1"
  local conf="$target/etc/pacman.conf"
  local tmp_conf="$target/etc/pacman.conf.engineos"

  [[ -f "$conf" ]] || die "target pacman.conf missing: $conf"
  if grep -Fx '[engineos]' "$conf" >/dev/null 2>&1; then
    return
  fi

  {
    printf '[engineos]\n'
    printf 'SigLevel = Optional TrustAll\n'
    printf 'Server = file:///srv/engineos/repo/$arch\n\n'
    cat "$conf"
  } >"$tmp_conf"
  sudo install -Dm0644 "$tmp_conf" "$conf"
}

write_installed_identity() {
  local target="$1"
  local hostname="$2"

  sudo install -d -m 0755 "$target/etc/engineos"
  printf '%s\n' "$hostname" | sudo tee "$target/etc/hostname" >/dev/null
  cat <<EOF | sudo tee "$target/etc/engineos/version" >/dev/null
ENGINEOS_NAME=EngineDev OS
ENGINEOS_PROFILE=enginedev
ENGINEOS_BUILD_ID=$(date -u +%Y.%m.%d)
ENGINEOS_BUILD_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENGINEOS_INSTALL_MODE=autoinstall
EOF
  cat <<'EOF' | sudo tee "$target/etc/engineos/profile.conf" >/dev/null
ENGINEOS_PROFILE=enginedev
ENGINEOS_LOG_DIR=/var/log/engineos
EOF
  cat <<EOF | sudo tee "$target/etc/issue" >/dev/null
EngineDev OS installed \r (\l)
Profile: enginedev

Run: eos-doctor --bare-metal
Repo: /srv/engineos
EOF
  printf 'LANG=C.UTF-8\n' | sudo tee "$target/etc/locale.conf" >/dev/null
  printf 'KEYMAP=us\n' | sudo tee "$target/etc/vconsole.conf" >/dev/null
  sudo ln -sf /usr/share/zoneinfo/UTC "$target/etc/localtime"
}

write_bootloader_entry() {
  local target="$1"
  local root_part="$2"
  local root_uuid

  root_uuid="$(blkid -s UUID -o value "$root_part")"
  [[ -n "$root_uuid" ]] || die "could not read UUID for $root_part"

  sudo install -d -m 0755 "$target/boot/loader/entries"
  cat <<EOF | sudo tee "$target/boot/loader/loader.conf" >/dev/null
default enginedev.conf
timeout 3
console-mode max
editor no
EOF
  cat <<EOF | sudo tee "$target/boot/loader/entries/enginedev.conf" >/dev/null
title EngineDev OS
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=UUID=$root_uuid rw
EOF
}

configure_installed_user() {
  local target="$1"
  local user="$2"
  local home_on_ntfs="${3:-false}"

  if [[ "$home_on_ntfs" == true ]]; then
    run_step "create dev user" arch-chroot "$target" useradd -M -d "/home/$user" -G wheel,input,audio,video,render,docker -s /usr/bin/zsh "$user"
    run_step "create NTFS-backed dev home" arch-chroot "$target" mkdir -p "/home/$user"
    run_step "seed dev home from skeleton" arch-chroot "$target" cp -a /etc/skel/. "/home/$user/"
  else
    run_step "create dev user" arch-chroot "$target" useradd -m -G wheel,input,audio,video,render,docker -s /usr/bin/zsh "$user"
  fi
  printf '%s:%s\n' "$user" "$user" | run_step "set dev validation password" arch-chroot "$target" chpasswd
  printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' | sudo tee "$target/etc/sudoers.d/10-engineos-wheel" >/dev/null
  sudo chmod 0440 "$target/etc/sudoers.d/10-engineos-wheel"
}

clone_repo_into_target() {
  local target="$1"
  local repo_url="$2"
  local repo_token_file="$3"
  local askpass="/usr/local/bin/engineos-git-askpass"
  local target_askpass="$target$askpass"
  local target_token="$target/root/.engineos/repo-token"
  local rc=0

  if [[ -z "$repo_token_file" ]]; then
    run_step "clone official Tang-OS repo" \
      arch-chroot "$target" env GIT_TERMINAL_PROMPT=0 git clone "$repo_url" /srv/engineos
    return
  fi

  [[ "$repo_token_file" == /* ]] || die "--repo-token-file must be absolute"
  [[ -r "$repo_token_file" ]] || die "--repo-token-file is not readable: $repo_token_file"

  sudo install -d -m 0700 "$target/root/.engineos"
  sudo install -d -m 0755 "$target/usr/local/bin"
  sudo install -m 0600 "$repo_token_file" "$target_token"
  cat <<'EOF' | sudo tee "$target_askpass" >/dev/null
#!/bin/sh
case "$1" in
  *sername*) printf '%s\n' x-access-token ;;
  *assword*) cat /root/.engineos/repo-token ;;
  *) printf '\n' ;;
esac
EOF
  sudo chmod 0700 "$target_askpass"

  if run_step "clone official Tang-OS repo" \
      arch-chroot "$target" env GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 git clone "$repo_url" /srv/engineos; then
    rc=0
  else
    rc=$?
  fi
  sudo rm -f "$target_askpass" "$target_token"
  return "$rc"
}

run_installer() {
  local device="$1"
  local target="$2"
  local repo_url="$3"
  local branch="$4"
  local hostname="$5"
  local user="$6"
  local root_size="$7"
  local var_size="$8"
  local home_ntfs_source="$9"
  local home_ntfs_options="${10}"
  local skip_codex="${11}"
  local repo_seed="${12}"
  local package_cache="${13}"
  local use_package_cache="${14}"
  local repo_token_file="${15:-}"
  local chroot_repo_url="$repo_url"
  local pacstrap_conf=""
  local boot_part root_part var_part srv_part resolved_home_ntfs_source=""
  local packages=()
  local post_install_payload=""
  local post_install_script=""
  local post_install_args=()

  mapfile -t packages < <(engineos_install_packages)
  read -r boot_part root_part var_part srv_part <<<"$(partition_paths "$device" | paste -sd ' ' -)"

  for cmd in lsblk wipefs sfdisk mkfs.fat mkfs.ext4 mount pacstrap genfstab arch-chroot blkid git sudo; do
    require_command "$cmd"
  done
  if [[ -n "$home_ntfs_source" ]]; then
    require_command findfs
  fi

  [[ "$(id -u)" -eq 0 ]] || require_command sudo
  [[ "$target" == /* ]] || die "--target must be absolute"
  [[ "$target" != "/" ]] || die "refusing to use / as install target"
  [[ "$target" != *"'"* ]] || die "--target cannot contain single quotes"

  if [[ "${ENGINEOS_INSTALL_ALLOW_FAKE_DEVICE:-}" != "true" ]]; then
    [[ -b "$device" ]] || die "target is not a block device: $device"
  fi
  if target_has_mounts "$device"; then
    die "target device has mounted filesystems; unmount them before installing: $device"
  fi
  if findmnt "$target" >/dev/null 2>&1; then
    die "target mountpoint is already mounted: $target"
  fi
  resolved_home_ntfs_source="$(resolve_home_ntfs_source "$home_ntfs_source")"

  printf 'EngineOS EngineDev autoinstall\n'
  printf '  device:   %s\n' "$device"
  printf '  target:   %s\n' "$target"
  if [[ -n "$resolved_home_ntfs_source" ]]; then
    printf '  home:     %s mounted at /home as NTFS\n' "$home_ntfs_source"
  else
    printf '  home:     installed root filesystem\n'
  fi
  printf '  repo:     %s\n' "$repo_url"
  if [[ -n "$repo_token_file" && -z "$repo_seed" ]]; then
    printf '  repo auth: token file supplied (redacted)\n'
  elif [[ -n "$repo_token_file" ]]; then
    printf '  repo auth: token file supplied but unused for local seed clone\n'
  else
    printf '  repo auth: none; clone will fail fast if the repo is private\n'
  fi
  [[ -n "$repo_seed" ]] && printf '  seed:     %s\n' "$repo_seed"
  printf '  branch:   %s\n' "${branch:-default}"
  printf '  hostname: %s\n' "$hostname"
  printf '  user:     %s\n' "$user"
  if [[ "$use_package_cache" == true && -n "$package_cache" ]]; then
    if package_cache_has_packages "$package_cache"; then
      validate_package_cache "$package_cache" "${packages[@]}"
      printf '  cache:    %s (%s package artifacts)\n' "$package_cache" "$(package_cache_artifact_count "$package_cache")"
    else
      printf '  cache:    %s (not found or empty; using pacman defaults)\n' "$package_cache"
      use_package_cache=false
    fi
  else
    printf '  cache:    disabled\n'
  fi

  run_sudo "wipe target signatures" wipefs --all "$device"
  write_sfdisk_layout "$root_size" "$var_size" | run_step "partition target disk" sudo sfdisk "$device"
  sudo udevadm settle || true
  wait_for_partitions "$boot_part" "$root_part" "$var_part" "$srv_part"

  run_sudo "format EFI partition" mkfs.fat -F32 -n ENGOS_EFI "$boot_part"
  run_sudo "format root partition" mkfs.ext4 -F -L ENGINEOS_ROOT "$root_part"
  run_sudo "format /var partition" mkfs.ext4 -F -L ENGINEOS_VAR "$var_part"
  run_sudo "format persistent /srv partition" mkfs.ext4 -F -L ENGINEOS_DEV_SRV "$srv_part"

  run_sudo "create install target" mkdir -p "$target"
  run_sudo "mount root partition" mount "$root_part" "$target"
  run_sudo "create target mountpoints" mkdir -p "$target/boot" "$target/var" "$target/srv" "$target/home"
  run_sudo "mount EFI partition" mount "$boot_part" "$target/boot"
  run_sudo "mount /var partition" mount "$var_part" "$target/var"
  run_sudo "mount persistent /srv partition" mount "$srv_part" "$target/srv"
  if [[ -n "$resolved_home_ntfs_source" ]]; then
    run_sudo "mount NTFS /home volume" mount -t ntfs-3g -o "$home_ntfs_options" "$home_ntfs_source" "$target/home"
  fi

  ensure_host_pacman_servers
  ensure_host_pacman_keyring
  if [[ "$use_package_cache" == true ]]; then
    pacstrap_conf="${TMPDIR:-/tmp}/engineos-install-pacman-$$.conf"
    write_pacstrap_pacman_conf "$package_cache" "$pacstrap_conf"
    run_step "install Arch base and dev packages from ISO cache" sudo pacstrap -c -C "$pacstrap_conf" "$target" "${packages[@]}"
  else
    run_step "install Arch base and dev packages" sudo pacstrap -c "$target" "${packages[@]}"
  fi
  run_step "write fstab" bash -c "sudo genfstab -U '$target' | sudo tee '$target/etc/fstab' >/dev/null"
  write_installed_identity "$target" "$hostname"
  write_pacman_engineos_repo "$target"
  write_bootloader_entry "$target" "$root_part"
  run_step "install systemd-boot" arch-chroot "$target" bootctl install
  if [[ -n "$resolved_home_ntfs_source" ]]; then
    configure_installed_user "$target" "$user" true
  else
    configure_installed_user "$target" "$user" false
  fi

  run_step "enable installed services" arch-chroot "$target" systemctl enable NetworkManager.service sshd.service docker.service
  if [[ -n "$repo_seed" ]]; then
    [[ -d "$repo_seed" ]] || die "repo seed directory not found: $repo_seed"
    run_sudo "stage repo seed in target" mkdir -p "$target/tmp/tang-os-seed"
    run_step "copy repo seed into target" sudo cp -a "$repo_seed/." "$target/tmp/tang-os-seed/"
    chroot_repo_url="file:///tmp/tang-os-seed"
  fi
  if [[ -n "$repo_seed" ]]; then
    clone_repo_into_target "$target" "$chroot_repo_url" ""
  else
    clone_repo_into_target "$target" "$chroot_repo_url" "$repo_token_file"
  fi
  if [[ -n "$branch" ]]; then
    run_step "checkout Tang-OS branch" arch-chroot "$target" git -C /srv/engineos checkout "$branch"
  fi
  run_step "assign Tang-OS workspace to dev user" arch-chroot "$target" chown -R "$user:$user" /srv/engineos
  run_step "build installed local package repo" arch-chroot "$target" runuser -u "$user" -- env -u ENGINEOS_ROOT -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_LOG_DIR /srv/engineos/tools/engineos/eos-build repo

  post_install_payload="$(installed_post_install_payload "$target")"
  post_install_script="$post_install_payload/scripts/setup_dev_environment.sh"
  post_install_args=(--payload "$post_install_payload" --user "$user" --force-config)
  if [[ "$skip_codex" == true ]]; then
    post_install_args+=(--skip-codex)
  fi
  run_step "run installed post-install payload" arch-chroot "$target" "$post_install_script" "${post_install_args[@]}"
  run_step "validate installed builder shape" arch-chroot "$target" env -u ENGINEOS_ROOT -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_LOG_DIR /srv/engineos/tools/engineos/eos-validate builder --mock
  run_step "validate installed local repo" arch-chroot "$target" env -u ENGINEOS_ROOT -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_LOG_DIR /srv/engineos/tools/engineos/eos-validate repo

  cat <<EOF | sudo tee "$target/srv/ENGINEOS_INSTALL_HANDOFF.txt" >/dev/null
EngineDev autoinstall completed at $(date -u +%Y-%m-%dT%H:%M:%SZ)

First boot:
  login: $user / $user
  cd /srv/engineos
  ./tools/engineos/eos-doctor --bare-metal
  ./tools/engineos/eos-proof booted-iso --bare-metal
  codex
EOF

  sync
  printf '\nEngineDev autoinstall completed.\n'
  printf 'Next: boot from %s and log in as %s / %s.\n' "$device" "$user" "$user"
}

print_dev_plan() {
  local device="$1"
  local target="$2"
  local repo_url="$3"
  local branch="$4"
  local hostname="$5"
  local user="$6"
  local root_size="$7"
  local var_size="$8"
  local home_ntfs_source="$9"
  local home_ntfs_options="${10}"
  local repo_seed="${11}"
  local package_cache="${12}"
  local use_package_cache="${13}"
  local repo_token_file="${14:-}"
  local boot_part="${device}1"
  local root_part="${device}2"
  local var_part="${device}3"
  local srv_part="${device}4"

  if [[ "$device" == /dev/disk/by-id/* || "$device" == /dev/disk/by-path/* ]]; then
    boot_part="${device}-part1"
    root_part="${device}-part2"
    var_part="${device}-part3"
    srv_part="${device}-part4"
  elif [[ "$device" == /dev/nvme* || "$device" == /dev/mmcblk* ]]; then
    boot_part="${device}p1"
    root_part="${device}p2"
    var_part="${device}p3"
    srv_part="${device}p4"
  fi

  printf 'EngineOS EngineDev autoinstall plan\n'
  printf '  root:     %s\n' "$ROOT"
  printf '  device:   %s\n' "$device"
  printf '  target:   %s\n' "$target"
  if [[ -n "$home_ntfs_source" ]]; then
    printf '  home:     %s mounted at /home as NTFS\n' "$home_ntfs_source"
    printf '  home opts:%s\n' " $home_ntfs_options"
  else
    printf '  home:     installed root filesystem\n'
  fi
  printf '  repo:     %s\n' "$repo_url"
  if [[ -n "$repo_token_file" && -z "$repo_seed" ]]; then
    printf '  repo auth: token file supplied (redacted)\n'
  elif [[ -n "$repo_token_file" ]]; then
    printf '  repo auth: token file supplied but unused for local seed clone\n'
  else
    printf '  repo auth: none; clone runs non-interactively\n'
  fi
  [[ -n "$repo_seed" ]] && printf '  seed:     %s\n' "$repo_seed"
  printf '  branch:   %s\n' "${branch:-default}"
  printf '  hostname: %s\n' "$hostname"
  printf '  user:     %s\n' "$user"
  if [[ "$use_package_cache" == true ]]; then
    printf '  cache:    %s (used when present in the booted ISO)\n' "$package_cache"
  else
    printf '  cache:    disabled\n'
  fi
  printf '\nSafety gates:\n'
  printf '  - run only from a booted EngineDev ISO\n'
  printf '  - refuse mounted target devices\n'
  printf '  - require explicit wipe acknowledgement for real mode\n'
  printf '  - keep /var separate for logs, package caches, and Docker data\n'
  printf '  - keep /srv separate for repo and package artifacts\n'
  printf '  - mount the existing NTFS home volume without formatting it\n'

  printf '\nPlanned destructive disk layout:\n'
  printf '  %s  EFI system partition, 1 GiB, FAT32\n' "$boot_part"
  printf '  %s  EngineDev root, %s, ext4\n' "$root_part" "$root_size"
  printf '  %s  EngineDev /var, %s, ext4 label ENGINEOS_VAR\n' "$var_part" "$var_size"
  printf '  %s  persistent /srv workspace, remaining space, ext4 label ENGINEOS_DEV_SRV\n' "$srv_part"
  if [[ -n "$home_ntfs_source" ]]; then
    printf '  %s  existing NTFS volume mounted at /home, not formatted\n' "$home_ntfs_source"
  fi

  printf '\nPlanned commands:\n'
  quote_line lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "$device"
  quote_line wipefs --all "$device"
  quote_line sfdisk "$device" "< engineos generated GPT layout: 1G EFI, $root_size root, $var_size /var, rest /srv"
  quote_line mkfs.fat -F32 -n ENGOS_EFI "$boot_part"
  quote_line mkfs.ext4 -F -L ENGINEOS_ROOT "$root_part"
  quote_line mkfs.ext4 -F -L ENGINEOS_VAR "$var_part"
  quote_line mkfs.ext4 -F -L ENGINEOS_DEV_SRV "$srv_part"
  quote_line mount "$root_part" "$target"
  quote_line mkdir -p "$target/boot" "$target/var" "$target/srv" "$target/home"
  quote_line mount "$boot_part" "$target/boot"
  quote_line mount "$var_part" "$target/var"
  quote_line mount "$srv_part" "$target/srv"
  if [[ -n "$home_ntfs_source" ]]; then
    quote_line mount -t ntfs-3g -o "$home_ntfs_options" "$home_ntfs_source" "$target/home"
  fi
  if [[ "$use_package_cache" == true ]]; then
    quote_line pacstrap -c -C "<generated pacman.conf with CacheDir=$package_cache>" "$target" base linux linux-firmware "plus EngineOS builder/dev package set"
  else
    quote_line pacstrap -c "$target" base linux linux-firmware "plus EngineOS builder/dev package set"
  fi
  quote_line genfstab -U "$target" ">> $target/etc/fstab"
  quote_line arch-chroot "$target" bootctl install
  if [[ -n "$home_ntfs_source" ]]; then
    quote_line arch-chroot "$target" useradd -M -d "/home/$user" -G wheel,input,audio,video,render,docker -s /usr/bin/zsh "$user"
    quote_line arch-chroot "$target" mkdir -p "/home/$user"
    quote_line arch-chroot "$target" cp -a /etc/skel/. "/home/$user/"
  else
    quote_line arch-chroot "$target" useradd -m -G wheel,input,audio,video,render,docker -s /usr/bin/zsh "$user"
  fi
  quote_line arch-chroot "$target" systemctl enable NetworkManager.service sshd.service docker.service
  if [[ -n "$repo_seed" ]]; then
    quote_line cp -a "$repo_seed/." "$target/tmp/tang-os-seed/"
    quote_line arch-chroot "$target" env GIT_TERMINAL_PROMPT=0 git clone file:///tmp/tang-os-seed /srv/engineos
  elif [[ -n "$repo_token_file" ]]; then
    quote_line install -m 0600 "<repo token file>" "$target/root/.engineos/repo-token"
    quote_line arch-chroot "$target" env GIT_ASKPASS=/usr/local/bin/engineos-git-askpass GIT_TERMINAL_PROMPT=0 git clone "$repo_url" /srv/engineos
    quote_line rm -f "$target/usr/local/bin/engineos-git-askpass" "$target/root/.engineos/repo-token"
  else
    quote_line arch-chroot "$target" env GIT_TERMINAL_PROMPT=0 git clone "$repo_url" /srv/engineos
  fi
  if [[ -n "$branch" ]]; then
    quote_line arch-chroot "$target" git -C /srv/engineos checkout "$branch"
  fi
  quote_line arch-chroot "$target" chown -R "$user:$user" /srv/engineos
  quote_line arch-chroot "$target" runuser -u "$user" -- env -u ENGINEOS_ROOT -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_LOG_DIR /srv/engineos/tools/engineos/eos-build repo
  quote_line arch-chroot "$target" "$PACKAGED_POST_INSTALL_PAYLOAD/scripts/setup_dev_environment.sh" --payload "$PACKAGED_POST_INSTALL_PAYLOAD" --user "$user"
  quote_line arch-chroot "$target" env -u ENGINEOS_ROOT -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_LOG_DIR /srv/engineos/tools/engineos/eos-validate builder --mock
  quote_line arch-chroot "$target" env -u ENGINEOS_ROOT -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_LOG_DIR /srv/engineos/tools/engineos/eos-validate repo

  printf '\nFirst boot handoff:\n'
  printf '  Login as %s, authenticate Codex manually, then run:\n' "$user"
  printf '    cd /srv/engineos\n'
  printf '    ./tools/engineos/eos-proof booted-iso --bare-metal\n'
  printf '    ./tools/engineos/eos-build repo\n'
  printf '\nDry-run only: no disks were changed.\n'
}

install_dev() {
  local device="$DEFAULT_SYSTEM_DEVICE"
  local target="/mnt/engineos"
  local repo_url="$DEFAULT_REPO_URL"
  local repo_token_file="${ENGINEOS_REPO_TOKEN_FILE:-}"
  local repo_seed=""
  local package_cache="${ENGINEOS_INSTALL_PACKAGE_CACHE:-/opt/engineos/install-cache/pkg}"
  local use_package_cache=true
  local branch=""
  local hostname="enginedev"
  local root_size="64G"
  local var_size="128G"
  local home_ntfs_source="$DEFAULT_HOME_NTFS_SOURCE"
  local home_ntfs_options="$DEFAULT_HOME_NTFS_OPTIONS"
  local user="dev"
  local skip_codex=false
  local dry_run=false
  local acknowledged=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device)
        shift
        device="${1:-}"
        [[ -n "$device" ]] || die "--device requires a path"
        ;;
      --target)
        shift
        target="${1:-}"
        [[ -n "$target" && "$target" == /* ]] || die "--target requires an absolute path"
        ;;
      --home-ntfs-source)
        shift
        home_ntfs_source="${1:-}"
        [[ -n "$home_ntfs_source" ]] || die "--home-ntfs-source requires /dev/..., LABEL=..., UUID=..., PARTUUID=..., or none"
        [[ "$home_ntfs_source" != "none" ]] || home_ntfs_source=""
        ;;
      --home-ntfs-options)
        shift
        home_ntfs_options="${1:-}"
        [[ -n "$home_ntfs_options" ]] || die "--home-ntfs-options requires mount options"
        ;;
      --no-home-ntfs)
        home_ntfs_source=""
        ;;
      --repo-url)
        shift
        repo_url="${1:-}"
        [[ -n "$repo_url" ]] || die "--repo-url requires a URL"
        ;;
      --repo-token-file)
        shift
        repo_token_file="${1:-}"
        [[ -n "$repo_token_file" && "$repo_token_file" == /* ]] || die "--repo-token-file requires an absolute path"
        ;;
      --repo-seed)
        shift
        repo_seed="${1:-}"
        [[ -n "$repo_seed" ]] || die "--repo-seed requires a path"
        ;;
      --package-cache)
        shift
        package_cache="${1:-}"
        [[ -n "$package_cache" && "$package_cache" == /* ]] || die "--package-cache requires an absolute path"
        use_package_cache=true
        ;;
      --no-package-cache)
        use_package_cache=false
        ;;
      --branch)
        shift
        branch="${1:-}"
        [[ -n "$branch" ]] || die "--branch requires a name"
        ;;
      --hostname)
        shift
        hostname="${1:-}"
        [[ -n "$hostname" ]] || die "--hostname requires a name"
        ;;
      --root-size)
        shift
        root_size="${1:-}"
        [[ -n "$root_size" ]] || die "--root-size requires a size"
        ;;
      --var-size)
        shift
        var_size="${1:-}"
        [[ -n "$var_size" ]] || die "--var-size requires a size"
        ;;
      --user)
        shift
        user="${1:-}"
        [[ -n "$user" ]] || die "--user requires a name"
        ;;
      --skip-codex)
        skip_codex=true
        ;;
      --dry-run)
        dry_run=true
        ;;
      --yes-i-understand-this-wipes-device)
        acknowledged=true
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown install dev option: $1"
        ;;
    esac
    shift
  done

  require_whole_disk_shape "$device"

  if [[ "$dry_run" == true ]]; then
    print_dev_plan "$device" "$target" "$repo_url" "$branch" "$hostname" "$user" "$root_size" "$var_size" "$home_ntfs_source" "$home_ntfs_options" "$repo_seed" "$package_cache" "$use_package_cache" "$repo_token_file"
    return
  fi

  "$acknowledged" || die "real install mode will require --yes-i-understand-this-wipes-device"
  run_installer "$device" "$target" "$repo_url" "$branch" "$hostname" "$user" "$root_size" "$var_size" "$home_ntfs_source" "$home_ntfs_options" "$skip_codex" "$repo_seed" "$package_cache" "$use_package_cache" "$repo_token_file"
}

case "$ACTION" in
  dev)
    install_dev "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown install action: $ACTION"
    ;;
esac
