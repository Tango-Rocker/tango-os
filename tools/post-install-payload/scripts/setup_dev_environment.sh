#!/usr/bin/env bash
set -euo pipefail

PAYLOAD=""
RUN_CODEX=true
RUN_DOCKER=true
RUN_PACMAN=true
FORCE_CONFIG=false
TARGET_USER="${ENGINEOS_DEV_USER:-${USER:-dev}}"
LOG_DIR="${ENGINEOS_LOG_DIR:-/var/log/engineos}"
LOG_FILE="$LOG_DIR/post-first-deploy.log"

usage() {
  cat <<'HELP'
Usage: setup_dev_environment.sh --payload <dir> [options]

Options:
  --payload path       Staged payload directory
  --user name          User to configure (default: current user)
  --skip-codex         Do not install/upgrade Codex CLI
  --skip-docker        Do not install/start Docker
  --skip-pacman        Do not install Arch packages
  --force-config       Replace managed tmux/Docker config files
  -h, --help           Show this help
HELP
}

die() {
  printf 'post-first-deploy: %s\n' "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return
  fi
  if have_cmd sudo; then
    sudo -n "$@"
    return
  fi
  die "root privileges required for: $*"
}

run_as_user() {
  local user="$1"
  shift

  if [[ "$(id -un)" == "$user" ]]; then
    "$@"
    return
  fi
  if have_cmd sudo; then
    sudo -n -u "$user" "$@"
    return
  fi
  die "sudo is required to run as user: $user"
}

log() {
  printf '%s\n' "$*"
}

install_if_absent() {
  local dest="$1"
  local src="$2"
  local mode="${3:-0644}"
  local owner="${4:-}"

  if [[ -e "$dest" && "$FORCE_CONFIG" != true ]]; then
    log "keep existing: $dest"
    return
  fi

  if [[ -n "$owner" ]]; then
    as_root install -Dm"$mode" -o "${owner%%:*}" -g "${owner#*:}" "$src" "$dest"
  else
    install -Dm"$mode" "$src" "$dest"
  fi
  log "installed: $dest"
}

install_managed_tmux_config() {
  local dest="$1"
  local src="$2"
  local mode="${3:-0644}"
  local owner="${4:-}"

  if [[ -e "$dest" && "$FORCE_CONFIG" != true ]]; then
    if grep -F '@engineos-plugins' "$dest" >/dev/null 2>&1; then
      log "keep existing current tmux config: $dest"
      return
    fi
    if grep -F 'TMUX_PLUGIN_MANAGER_PATH' "$dest" >/dev/null 2>&1 ||
        grep -F "set -g @plugin 'tmux-plugins/" "$dest" >/dev/null 2>&1 ||
        grep -F '/usr/share/tmux/plugins/tpm/tpm' "$dest" >/dev/null 2>&1; then
      as_root cp "$dest" "$dest.engineos-legacy.bak"
      log "backup legacy tmux config: $dest.engineos-legacy.bak"
    else
      log "keep existing unmanaged tmux config: $dest"
      return
    fi
  fi

  if [[ -n "$owner" ]]; then
    as_root install -Dm"$mode" -o "${owner%%:*}" -g "${owner#*:}" "$src" "$dest"
  else
    install -Dm"$mode" "$src" "$dest"
  fi
  log "installed: $dest"
}

install_managed_zprofile() {
  local dest="$1"
  local src="$2"
  local mode="${3:-0644}"
  local owner="${4:-}"

  if [[ -e "$dest" && "$FORCE_CONFIG" != true ]]; then
    if grep -F 'tmux new-session -A -s engineos' "$dest" >/dev/null 2>&1; then
      log "keep existing current zprofile: $dest"
      return
    fi
    if grep -F 'EngineDev OS' "$dest" >/dev/null 2>&1 ||
        grep -F 'Try: eos-doctor --vm' "$dest" >/dev/null 2>&1; then
      as_root cp "$dest" "$dest.engineos-legacy.bak"
      log "backup legacy zprofile: $dest.engineos-legacy.bak"
    else
      log "keep existing unmanaged zprofile: $dest"
      return
    fi
  fi

  if [[ -n "$owner" ]]; then
    as_root install -Dm"$mode" -o "${owner%%:*}" -g "${owner#*:}" "$src" "$dest"
  else
    install -Dm"$mode" "$src" "$dest"
  fi
  log "installed: $dest"
}

user_home() {
  local user="$1"
  getent passwd "$user" | cut -d: -f6
}

install_packages() {
  "$RUN_PACMAN" || {
    log "skip pacman package install"
    return
  }

  if ! have_cmd pacman; then
    log "pacman not available; skipping package install"
    return
  fi

  local packages=(
    ca-certificates
    curl
    git
    openssh
    vim
    neovim
    tmux
    zsh
    zsh-autosuggestions
    zsh-completions
    zsh-history-substring-search
    zsh-syntax-highlighting
    fzf
    zoxide
    wl-clipboard
    bash-completion
    jq
    ripgrep
    fd
    just
    github-cli
    git-lfs
    lazygit
    btop
    bat
    eza
    tealdeer
    man-db
    man-pages
    base-devel
    engineos-tools
    engineos-oh-my-zsh
    engineos-tmux-plugins
    engineos-cube
    engineos-shell
  )

  if "$RUN_DOCKER"; then
    packages+=(docker docker-compose docker-buildx)
  fi

  local missing=()
  local package
  for package in "${packages[@]}"; do
    if ! pacman -Q "$package" >/dev/null 2>&1; then
      missing+=("$package")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    log "package set already installed"
    return
  fi

  ensure_pacman_servers
  ensure_pacman_keyring

  log "install missing packages: ${missing[*]}"
  as_root pacman -Sy --needed --noconfirm "${missing[@]}"
}

ensure_pacman_keyring() {
  local pubring="/etc/pacman.d/gnupg/pubring.gpg"

  if [[ -s "$pubring" ]]; then
    return
  fi

  log "initialize pacman keyring"
  as_root pacman-key --init
  as_root pacman-key --populate archlinux
}

ensure_pacman_servers() {
  local mirrorlist="/etc/pacman.d/mirrorlist"

  if grep -Eq '^[[:space:]]*Server[[:space:]]*=' "$mirrorlist" 2>/dev/null; then
    return
  fi

  if ! grep -Eq '^#Server[[:space:]]*=' "$mirrorlist" 2>/dev/null; then
    log "pacman mirrorlist has no candidate servers; package install may fail"
    return
  fi

  log "enable first packaged pacman mirror"
  as_root cp "$mirrorlist" "$mirrorlist.engineos-first-deploy.bak"
  as_root sed -i '0,/^#Server[[:space:]]*=/{s/^#Server[[:space:]]*=/Server =/}' "$mirrorlist"
}

configure_tmux() {
  local home
  home="$(user_home "$TARGET_USER")"
  [[ -n "$home" ]] || die "cannot find home for user: $TARGET_USER"

  install_managed_tmux_config "$home/.tmux.conf" "$PAYLOAD/assets/tmux.conf" 0644 "$TARGET_USER:$TARGET_USER"
}

configure_zsh() {
  local home
  home="$(user_home "$TARGET_USER")"
  [[ -n "$home" ]] || die "cannot find home for user: $TARGET_USER"

  install_if_absent "$home/.zshrc" "$PAYLOAD/assets/zshrc" 0644 "$TARGET_USER:$TARGET_USER"
  install_managed_zprofile "$home/.zprofile" "$PAYLOAD/assets/zprofile" 0644 "$TARGET_USER:$TARGET_USER"
  if have_cmd chsh && [[ "$(getent passwd "$TARGET_USER" | cut -d: -f7)" != "/usr/bin/zsh" ]]; then
    as_root chsh -s /usr/bin/zsh "$TARGET_USER" || true
  fi
  as_root mkdir -p "$home/.config/engineos"
  as_root chown "$TARGET_USER:$TARGET_USER" "$home/.config" "$home/.config/engineos"
  install_if_absent "$home/.config/engineos/dev-environment.md" "$PAYLOAD/assets/codex/engineos-dev-directives.md" 0644 "$TARGET_USER:$TARGET_USER"
}

configure_docker() {
  "$RUN_DOCKER" || {
    log "skip Docker setup"
    return
  }

  if ! have_cmd docker; then
    log "docker command unavailable after package step"
    return
  fi

  as_root mkdir -p /etc/docker
  install_if_absent /etc/docker/daemon.json "$PAYLOAD/assets/docker/daemon.json" 0644 root:root

  if getent group docker >/dev/null; then
    as_root usermod -aG docker "$TARGET_USER"
  fi

  if have_cmd systemctl; then
    as_root systemctl enable docker.service >/dev/null 2>&1 || true
    as_root systemctl enable engineos-observe-exporter.service >/dev/null 2>&1 || true
    if [[ -d /run/systemd/system ]]; then
      as_root systemctl restart docker.service
      as_root systemctl restart engineos-observe-exporter.service >/dev/null 2>&1 || true
    else
      log "systemd is not running; docker and observability services enabled for next boot"
    fi
  fi
}

configure_dev_shell_autostart() {
  if [[ ! -f "$PAYLOAD/assets/systemd/engineos-dev-shell.service" ||
      ! -f "$PAYLOAD/scripts/engineos-dev-shell-start" ]]; then
    log "WARN dev shell autostart payload assets missing"
    return
  fi

  as_root install -Dm0755 "$PAYLOAD/scripts/engineos-dev-shell-start" /usr/local/bin/engineos-dev-shell-start
  as_root install -Dm0644 "$PAYLOAD/assets/systemd/engineos-dev-shell.service" /etc/systemd/system/engineos-dev-shell.service
  log "installed dev shell autostart unit"

  if ! have_cmd systemctl; then
    log "WARN systemctl unavailable; cannot enable dev shell autostart"
    return
  fi

  as_root systemctl daemon-reload || true

  if ! have_cmd engineos-shell; then
    log "WARN engineos-shell unavailable; dev shell autostart installed but not enabled"
    log "WARN rebuild EngineDev ISO or install engineos-shell from the local repo, then run: sudo systemctl enable --now engineos-dev-shell.service"
    return
  fi

  as_root systemctl enable engineos-dev-shell.service >/dev/null 2>&1 || true
  log "enabled engineos-dev-shell.service"
}

install_codex() {
  "$RUN_CODEX" || {
    log "skip Codex CLI install"
    return
  }

  if have_cmd codex; then
    log "codex already available: $(command -v codex)"
    return
  fi

  have_cmd curl || die "curl is required to install Codex CLI"

  local home
  home="$(user_home "$TARGET_USER")"
  [[ -n "$home" ]] || die "cannot find home for user: $TARGET_USER"

  log "install Codex CLI with official standalone installer"
  run_as_user "$TARGET_USER" env HOME="$home" CODEX_NON_INTERACTIVE=1 sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'
}

validate_setup() {
  local failures=0

  for cmd in git tmux zsh jq rg fd just; do
    if have_cmd "$cmd"; then
      log "OK command: $cmd"
    else
      log "FAIL command missing: $cmd"
      failures=$((failures + 1))
    fi
  done

  for cmd in nvim fzf zoxide wl-copy gh git-lfs lazygit btop bat eza tldr man; do
    if have_cmd "$cmd"; then
      log "OK dev convenience command: $cmd"
    else
      log "WARN dev convenience command missing: $cmd"
    fi
  done

  if "$RUN_CODEX"; then
    if have_cmd codex; then
      log "OK command: codex"
    else
      log "WARN codex command not on PATH yet; restart shell or inspect installer output"
    fi
  fi

  if "$RUN_DOCKER"; then
    if have_cmd docker; then
      log "OK command: docker"
    else
      log "FAIL command missing: docker"
      failures=$((failures + 1))
    fi
    if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -Fx docker >/dev/null; then
      log "OK user in docker group: $TARGET_USER"
    else
      log "FAIL user is not in docker group: $TARGET_USER"
      failures=$((failures + 1))
    fi
    if have_cmd systemctl && systemctl is-active docker.service >/dev/null 2>&1; then
      log "OK docker.service active"
    else
      log "WARN docker.service is not active"
    fi
  fi

  if [[ "$failures" -gt 0 ]]; then
    die "dev environment setup completed with $failures failure(s)"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --payload)
      PAYLOAD="${2:-}"
      [[ -n "$PAYLOAD" ]] || die "--payload requires a value"
      shift 2
      ;;
    --user)
      TARGET_USER="${2:-}"
      [[ -n "$TARGET_USER" ]] || die "--user requires a value"
      shift 2
      ;;
    --skip-codex)
      RUN_CODEX=false
      shift
      ;;
    --skip-docker)
      RUN_DOCKER=false
      shift
      ;;
    --skip-pacman)
      RUN_PACMAN=false
      shift
      ;;
    --force-config)
      FORCE_CONFIG=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown setup option: $1"
      ;;
  esac
done

[[ -n "$PAYLOAD" ]] || die "--payload is required"
[[ -d "$PAYLOAD/assets" ]] || die "payload assets not found: $PAYLOAD/assets"

as_root mkdir -p "$LOG_DIR"
if [[ "$(id -u)" -eq 0 ]]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
else
  exec > >(sudo -n tee -a "$LOG_FILE") 2>&1
fi

log "EngineOS post-first-deploy setup"
log "  user:    $TARGET_USER"
log "  payload: $PAYLOAD"
log "  codex:   $RUN_CODEX"
log "  docker:  $RUN_DOCKER"
log "  pacman:  $RUN_PACMAN"

install_packages
configure_tmux
configure_zsh
configure_docker
configure_dev_shell_autostart
install_codex
validate_setup

log "post-first-deploy setup completed"
