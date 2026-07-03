#!/usr/bin/env bash
set -euo pipefail

engineos_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  local source_root
  source_root="$(cd "$script_dir/../.." && pwd -P)"

  if [[ -n "${ENGINEOS_ROOT:-}" ]]; then
    if [[ "$script_dir" != /usr/lib/engineos/scripts && "$script_dir" != /usr/lib/engineos/scripts/* &&
        "$ENGINEOS_ROOT" == /usr* && -d "$source_root/tools/scripts" ]]; then
      printf '%s\n' "$source_root"
      return
    fi
    cd "$ENGINEOS_ROOT"
    pwd -P
    return
  fi

  case "$script_dir" in
    /usr/lib/engineos/scripts|/usr/lib/engineos/scripts/*)
      printf '%s\n' /usr
      return
      ;;
  esac

  printf '%s\n' "$source_root"
}

engineos_is_source_root() {
  local root="$1"
  [[ -d "$root/tools" && -x "$root/tools/engineos/engineos" ]]
}

engineos_default_log_dir() {
  local root="$1"
  if engineos_is_source_root "$root"; then
    printf '%s\n' "$root/artifacts/logs"
  else
    printf '%s\n' "/var/log/engineos"
  fi
}

engineos_default_state_dir() {
  local root="$1"
  if engineos_is_source_root "$root"; then
    printf '%s\n' "$root/artifacts/run"
  else
    printf '%s\n' "${XDG_RUNTIME_DIR:-/tmp}/engineos"
  fi
}

engineos_default_capture_dir() {
  local root="$1"
  if engineos_is_source_root "$root"; then
    printf '%s\n' "$root/artifacts/captures"
  else
    printf '%s\n' "${ENGINEOS_STATE_BASE:-/var/lib/engineos}/captures"
  fi
}

engineos_default_apps_manifest() {
  local root="$1"
  if engineos_is_source_root "$root"; then
    printf '%s\n' "$root/packages/engineos-config/files/etc/engineos/apps.toml"
  else
    printf '%s\n' "/etc/engineos/apps.toml"
  fi
}

engineos_apps_manifest() {
  local root="$1"
  if [[ -n "${ENGINEOS_APPS_MANIFEST:-}" ]]; then
    printf '%s\n' "$ENGINEOS_APPS_MANIFEST"
  else
    engineos_default_apps_manifest "$root"
  fi
}

engineos_app_manifest_section() {
  local manifest="$1"
  local app="$2"
  [[ -r "$manifest" ]] || return 1

  awk -v target="[apps.$app]" '
    /^[[:space:]]*\[/ {
      in_section = ($0 == target)
      next
    }
    in_section { print }
  ' "$manifest"
}

engineos_app_manifest_value() {
  local manifest="$1"
  local app="$2"
  local key="$3"

  engineos_app_manifest_section "$manifest" "$app" | awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "", $0)
      sub(/[[:space:]]*#.*$/, "", $0)
      sub(/^[[:space:]]*"/, "", $0)
      sub(/"[[:space:]]*$/, "", $0)
      print
      exit
    }
  '
}

engineos_app_manifest_array_contains() {
  local manifest="$1"
  local app="$2"
  local key="$3"
  local needle="$4"
  local line

  line="$(engineos_app_manifest_section "$manifest" "$app" | awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      print
      exit
    }
  ')"
  [[ "$line" == *"\"$needle\""* ]]
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

engineos_packages() {
  printf '%s\n' \
    engineos-tools \
    engineos-config \
    engineos-engine-runner \
    engineos-oh-my-zsh \
    engineos-tmux-plugins \
    engineos-cube \
    engineos-shell \
    engineos-quakespasm \
    engineos-quake-template
}

engineos_eos_commands() {
  printf '%s\n' \
    eos-agent \
    eos-app \
    eos-artifacts \
    eos-assets \
    eos-build \
    eos-builder \
    eos-capture \
    eos-ci \
    eos-crash-bundle \
    eos-deploy \
    eos-doctor \
    eos-input \
    eos-install \
    eos-lint \
    eos-logs \
    eos-observe \
    eos-outputs \
    eos-package \
    eos-preflight \
    eos-proof \
    eos-release \
    eos-runtime \
    eos-secureboot \
    eos-terminal \
    eos-test \
    eos-update \
    eos-usb \
    eos-validate \
    eos-vm
}

engineos_profiles() {
  printf '%s\n' \
    enginedev \
    engineruntime
}

engineos_builder_packages() {
  printf '%s\n' \
    base-devel \
    git \
    archiso \
    sudo \
    openssh \
    networkmanager \
    ca-certificates \
    curl \
    qemu-desktop \
    edk2-ovmf \
    vim \
    neovim \
    foot \
    zsh \
    tmux \
    fzf \
    zoxide \
    wl-clipboard \
    bash-completion \
    python \
    jq \
    ripgrep \
    fd \
    just \
    rsync \
    github-cli \
    git-lfs \
    sbsigntools \
    libisoburn \
    mtools \
    efitools \
    lazygit \
    btop \
    bat \
    eza \
    tealdeer \
    man-db \
    man-pages \
    docker \
    docker-compose \
    docker-buildx \
    llvm \
    openmp \
    libc++ \
    ccache \
    sccache \
    mold \
    bear \
    cmake \
    meson \
    ninja \
    pkgconf \
    go \
    clang \
    lld \
    gcc \
    gdb \
    lldb \
    cppcheck \
    doxygen \
    graphviz \
    strace \
    ltrace \
    valgrind \
    perf \
    elfutils \
    debuginfod \
    libunwind \
    mesa \
    mesa-utils \
    renderdoc \
    apitrace \
    vulkan-headers \
    vulkan-icd-loader \
    vulkan-validation-layers \
    vulkan-extra-layers \
    vulkan-extra-tools \
    vulkan-utility-libraries \
    vulkan-profiles \
    spirv-headers \
    spirv-tools \
    glslang \
    shaderc \
    volk \
    directx-shader-compiler \
    vulkan-tools \
    vulkan-radeon \
    libdrm \
    wayland \
    wayland-protocols \
    wlroots0.19 \
    xorg-xwayland \
    libinput \
    libxkbcommon \
    pipewire \
    pipewire-alsa \
    pipewire-pulse \
    wireplumber \
    alsa-utils \
    sdl2-compat \
    sdl2_image \
    sdl2_mixer \
    sdl2_ttf \
    sdl2_net \
    openal \
    glew \
    glfw \
    glu \
    freetype2 \
    libpng \
    libjpeg-turbo \
    libogg \
    libvorbis \
    mpg123 \
    glm \
    assimp \
    bullet \
    box2d \
    lua \
    luajit \
    luarocks \
    fmt \
    spdlog \
    enet \
    imagemagick \
    ffmpeg \
    sox \
    pacman-contrib \
    namcap \
    devtools
}

engineos_install_packages() {
  printf '%s\n' \
    base \
    linux \
    linux-firmware \
    linux-firmware-whence \
    efibootmgr \
    dosfstools \
    e2fsprogs \
    ntfs-3g
  engineos_builder_packages
}

die() {
  printf 'engineos: %s\n' "$*" >&2
  exit 1
}

is_arch_linux() {
  [[ -r /etc/arch-release ]]
}

quote_cmd() {
  local arg
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\n'
}
