#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
ACTION="${1:-help}"
shift || true

DEFAULT_REPO_URL="${ENGINEOS_OFFICIAL_REPO_URL:-https://github.com/Tango-Rocker/tango-os.git}"

usage() {
  cat <<'HELP'
Usage: install_dev.sh dev --dry-run --device <block-device> [options]
       install_dev.sh dev --device <block-device> --yes-i-understand-this-wipes-device [options]

Plan an EngineDev bare-metal autoinstall.

Options:
  --device path            Target whole-disk block device, for example /dev/nvme0n1
  --target path            Temporary install mountpoint (default: /mnt/engineos)
  --repo-url url           Tang-OS Git repo to clone into /srv/engineos
  --repo-token-file path   Optional file containing a GitHub token for private repo clone
  --repo-seed path         Optional local repo/checkout copied into target /tmp for VM proof
  --package-cache path     Host/ISO package cache for pacstrap (default: /opt/engineos/install-cache/pkg)
  --no-package-cache       Ignore any ISO package cache and use pacman defaults
  --branch name            Optional Git branch to check out after clone
  --hostname name          Installed hostname (default: enginedev)
  --root-size size         Root partition size for sfdisk (default: 16G)
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
  if [[ "$device" == /dev/nvme* || "$device" == /dev/mmcblk* ]]; then
    printf '%s\n' "${device}p1" "${device}p2" "${device}p3"
  else
    printf '%s\n' "${device}1" "${device}2" "${device}3"
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
  local srv_part="$3"
  local _i

  if [[ "${ENGINEOS_INSTALL_ALLOW_FAKE_DEVICE:-}" == "true" ]]; then
    return
  fi

  for _i in 1 2 3 4 5; do
    [[ -b "$boot_part" && -b "$root_part" && -b "$srv_part" ]] && return
    sleep 1
  done

  die "partition devices did not appear: $boot_part $root_part $srv_part"
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
  cat <<EOF
label: gpt
,1G,U
,$root_size,L
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

Run: engineos doctor --bare-metal
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

  run_step "create dev user" arch-chroot "$target" useradd -m -G wheel,input,audio,video,render,docker -s /usr/bin/zsh "$user"
  printf '%s:%s\n' "$user" "$user" | run_step "set dev validation password" arch-chroot "$target" chpasswd
  printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' | sudo tee "$target/etc/sudoers.d/10-engineos-wheel" >/dev/null
  sudo chmod 0440 "$target/etc/sudoers.d/10-engineos-wheel"
}

clone_repo_into_target() {
  local target="$1"
  local repo_url="$2"
  local repo_token_file="$3"
  local askpass="/tmp/engineos-git-askpass"
  local target_askpass="$target$askpass"
  local target_token="$target/run/engineos/repo-token"
  local rc=0

  if [[ -z "$repo_token_file" ]]; then
    run_step "clone official Tang-OS repo" \
      arch-chroot "$target" env GIT_TERMINAL_PROMPT=0 git clone "$repo_url" /srv/engineos
    return
  fi

  [[ "$repo_token_file" == /* ]] || die "--repo-token-file must be absolute"
  [[ -r "$repo_token_file" ]] || die "--repo-token-file is not readable: $repo_token_file"

  sudo install -d -m 0700 "$target/run/engineos"
  sudo install -d -m 1777 "$target/tmp"
  sudo install -m 0600 "$repo_token_file" "$target_token"
  cat <<'EOF' | sudo tee "$target_askpass" >/dev/null
#!/usr/bin/env sh
case "$1" in
  *sername*) printf '%s\n' x-access-token ;;
  *assword*) cat /run/engineos/repo-token ;;
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
  local skip_codex="$8"
  local repo_seed="$9"
  local package_cache="${10}"
  local use_package_cache="${11}"
  local repo_token_file="${12:-}"
  local chroot_repo_url="$repo_url"
  local pacstrap_conf=""
  local boot_part root_part srv_part
  local packages=()
  local post_install_args=()

  mapfile -t packages < <(engineos_install_packages)
  read -r boot_part root_part srv_part <<<"$(partition_paths "$device" | paste -sd ' ' -)"

  for cmd in lsblk wipefs sfdisk mkfs.fat mkfs.ext4 mount pacstrap genfstab arch-chroot blkid git sudo; do
    require_command "$cmd"
  done

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

  printf 'EngineOS EngineDev autoinstall\n'
  printf '  device:   %s\n' "$device"
  printf '  target:   %s\n' "$target"
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
  write_sfdisk_layout "$root_size" | run_step "partition target disk" sudo sfdisk "$device"
  sudo udevadm settle || true
  wait_for_partitions "$boot_part" "$root_part" "$srv_part"

  run_sudo "format EFI partition" mkfs.fat -F32 -n ENGOS_EFI "$boot_part"
  run_sudo "format root partition" mkfs.ext4 -F -L ENGINEOS_ROOT "$root_part"
  run_sudo "format persistent /srv partition" mkfs.ext4 -F -L ENGINEOS_DEV_SRV "$srv_part"

  run_sudo "create install target" mkdir -p "$target"
  run_sudo "mount root partition" mount "$root_part" "$target"
  run_sudo "create target mountpoints" mkdir -p "$target/boot" "$target/srv"
  run_sudo "mount EFI partition" mount "$boot_part" "$target/boot"
  run_sudo "mount persistent /srv partition" mount "$srv_part" "$target/srv"

  ensure_host_pacman_servers
  ensure_host_pacman_keyring
  if [[ "$use_package_cache" == true ]]; then
    pacstrap_conf="${TMPDIR:-/tmp}/engineos-install-pacman-$$.conf"
    write_pacstrap_pacman_conf "$package_cache" "$pacstrap_conf"
    run_step "install Arch base and dev packages from ISO cache" sudo pacstrap -c -C "$pacstrap_conf" "$target" "${packages[@]}"
  else
    run_step "install Arch base and dev packages" sudo pacstrap -c "$target" "${packages[@]}"
  fi
  run_step "write fstab" bash -c "genfstab -U '$target' | sudo tee -a '$target/etc/fstab' >/dev/null"
  write_installed_identity "$target" "$hostname"
  write_pacman_engineos_repo "$target"
  write_bootloader_entry "$target" "$root_part"
  run_step "install systemd-boot" arch-chroot "$target" bootctl install
  configure_installed_user "$target" "$user"

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
  run_step "build installed local package repo" arch-chroot "$target" /srv/engineos/tools/engineos/engineos build repo

  post_install_args=(--payload /srv/engineos/tools/post-install-payload --user "$user" --force-config)
  if [[ "$skip_codex" == true ]]; then
    post_install_args+=(--skip-codex)
  fi
  run_step "run installed post-install payload" arch-chroot "$target" /srv/engineos/tools/post-install-payload/scripts/setup_dev_environment.sh "${post_install_args[@]}"
  run_step "validate installed builder shape" arch-chroot "$target" /srv/engineos/tools/engineos/engineos validate builder --mock
  run_step "validate installed local repo" arch-chroot "$target" /srv/engineos/tools/engineos/engineos validate repo

  cat <<EOF | sudo tee "$target/srv/ENGINEOS_INSTALL_HANDOFF.txt" >/dev/null
EngineDev autoinstall completed at $(date -u +%Y-%m-%dT%H:%M:%SZ)

First boot:
  login: $user / $user
  cd /srv/engineos
  ./tools/engineos/engineos doctor --bare-metal
  ./tools/engineos/engineos proof booted-iso --bare-metal
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
  local repo_seed="$8"
  local package_cache="$9"
  local use_package_cache="${10}"
  local repo_token_file="${11:-}"
  local boot_part="${device}1"
  local root_part="${device}2"
  local srv_part="${device}3"

  if [[ "$device" == /dev/nvme* || "$device" == /dev/mmcblk* ]]; then
    boot_part="${device}p1"
    root_part="${device}p2"
    srv_part="${device}p3"
  fi

  printf 'EngineOS EngineDev autoinstall plan\n'
  printf '  root:     %s\n' "$ROOT"
  printf '  device:   %s\n' "$device"
  printf '  target:   %s\n' "$target"
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
  printf '  - keep /srv on a separate persistent partition for repo and package artifacts\n'

  printf '\nPlanned destructive disk layout:\n'
  printf '  %s  EFI system partition, 1 GiB, FAT32\n' "$boot_part"
  printf '  %s  EngineDev root, %s, ext4\n' "$root_part" "$root_size"
  printf '  %s  persistent /srv workspace, remaining space, ext4 label ENGINEOS_DEV_SRV\n' "$srv_part"

  printf '\nPlanned commands:\n'
  quote_line lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "$device"
  quote_line wipefs --all "$device"
  quote_line sfdisk "$device" "< engineos generated GPT layout: 1G EFI, $root_size root, rest /srv"
  quote_line mkfs.fat -F32 -n ENGOS_EFI "$boot_part"
  quote_line mkfs.ext4 -F -L ENGINEOS_ROOT "$root_part"
  quote_line mkfs.ext4 -F -L ENGINEOS_DEV_SRV "$srv_part"
  quote_line mount "$root_part" "$target"
  quote_line mkdir -p "$target/boot" "$target/srv"
  quote_line mount "$boot_part" "$target/boot"
  quote_line mount "$srv_part" "$target/srv"
  if [[ "$use_package_cache" == true ]]; then
    quote_line pacstrap -c -C "<generated pacman.conf with CacheDir=$package_cache>" "$target" base linux linux-firmware "plus EngineOS builder/dev package set"
  else
    quote_line pacstrap -c "$target" base linux linux-firmware "plus EngineOS builder/dev package set"
  fi
  quote_line genfstab -U "$target" ">> $target/etc/fstab"
  quote_line arch-chroot "$target" bootctl install
  quote_line arch-chroot "$target" useradd -m -G wheel,input,audio,video,render,docker -s /usr/bin/zsh "$user"
  quote_line arch-chroot "$target" systemctl enable NetworkManager.service sshd.service docker.service
  if [[ -n "$repo_seed" ]]; then
    quote_line cp -a "$repo_seed/." "$target/tmp/tang-os-seed/"
    quote_line arch-chroot "$target" env GIT_TERMINAL_PROMPT=0 git clone file:///tmp/tang-os-seed /srv/engineos
  elif [[ -n "$repo_token_file" ]]; then
    quote_line install -m 0600 "<repo token file>" "$target/run/engineos/repo-token"
    quote_line arch-chroot "$target" env GIT_ASKPASS=/tmp/engineos-git-askpass GIT_TERMINAL_PROMPT=0 git clone "$repo_url" /srv/engineos
    quote_line rm -f "$target/tmp/engineos-git-askpass" "$target/run/engineos/repo-token"
  else
    quote_line arch-chroot "$target" env GIT_TERMINAL_PROMPT=0 git clone "$repo_url" /srv/engineos
  fi
  if [[ -n "$branch" ]]; then
    quote_line arch-chroot "$target" git -C /srv/engineos checkout "$branch"
  fi
  quote_line arch-chroot "$target" /srv/engineos/tools/engineos/engineos build repo
  quote_line arch-chroot "$target" /srv/engineos/tools/post-install-payload/scripts/setup_dev_environment.sh --payload /srv/engineos/tools/post-install-payload --user "$user"
  quote_line arch-chroot "$target" /srv/engineos/tools/engineos/engineos validate builder --mock
  quote_line arch-chroot "$target" /srv/engineos/tools/engineos/engineos validate repo

  printf '\nFirst boot handoff:\n'
  printf '  Login as %s, authenticate Codex manually, then run:\n' "$user"
  printf '    cd /srv/engineos\n'
  printf '    ./tools/engineos/engineos proof booted-iso --bare-metal\n'
  printf '    ./tools/engineos/engineos build repo\n'
  printf '\nDry-run only: no disks were changed.\n'
}

install_dev() {
  local device=""
  local target="/mnt/engineos"
  local repo_url="$DEFAULT_REPO_URL"
  local repo_token_file="${ENGINEOS_REPO_TOKEN_FILE:-}"
  local repo_seed=""
  local package_cache="${ENGINEOS_INSTALL_PACKAGE_CACHE:-/opt/engineos/install-cache/pkg}"
  local use_package_cache=true
  local branch=""
  local hostname="enginedev"
  local root_size="16G"
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
    print_dev_plan "$device" "$target" "$repo_url" "$branch" "$hostname" "$user" "$root_size" "$repo_seed" "$package_cache" "$use_package_cache" "$repo_token_file"
    return
  fi

  "$acknowledged" || die "real install mode will require --yes-i-understand-this-wipes-device"
  run_installer "$device" "$target" "$repo_url" "$branch" "$hostname" "$user" "$root_size" "$skip_codex" "$repo_seed" "$package_cache" "$use_package_cache" "$repo_token_file"
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
