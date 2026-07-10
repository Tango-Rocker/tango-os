#!/usr/bin/env bash
set -euo pipefail

PAYLOAD=""
RUN_CODEX=true
RUN_DOCKER=true
RUN_PACMAN=true
RUN_DEV_REPOS=true
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
  --skip-dev-repos     Do not clone/update EngineDev helper repos
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
    if grep -F 'engineos-tmux-attach-primary' "$dest" >/dev/null 2>&1; then
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
    die "pacman not available; cannot install required packages without --skip-pacman"
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
    engineos-level-agent
    engineos-trenchbroom
    engineos-quake-template
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
  if [[ -f "$PAYLOAD/scripts/engineos-tmux-pane-bridge" ]]; then
    as_root install -Dm0755 "$PAYLOAD/scripts/engineos-tmux-pane-bridge" /usr/local/bin/engineos-tmux-pane-bridge
    log "installed: /usr/local/bin/engineos-tmux-pane-bridge"
  else
    die "tmux pane bridge helper payload missing"
  fi
  for helper in engineos-tmux-attach-primary engineos-tmux-pane-sync engineos-tmux-window-sync engineos-tmux-window-focus engineos-tmux-window-proxy; do
    if [[ -f "$PAYLOAD/scripts/$helper" ]]; then
      as_root install -Dm0755 "$PAYLOAD/scripts/$helper" "/usr/local/bin/$helper"
      log "installed: /usr/local/bin/$helper"
    else
      die "tmux window helper payload missing: $helper"
    fi
  done
}

configure_zsh() {
  local home
  home="$(user_home "$TARGET_USER")"
  [[ -n "$home" ]] || die "cannot find home for user: $TARGET_USER"

  install_if_absent "$home/.zshrc" "$PAYLOAD/assets/zshrc" 0644 "$TARGET_USER:$TARGET_USER"
  install_managed_zprofile "$home/.zprofile" "$PAYLOAD/assets/zprofile" 0644 "$TARGET_USER:$TARGET_USER"
  if have_cmd chsh && [[ "$(getent passwd "$TARGET_USER" | cut -d: -f7)" != "/usr/bin/zsh" ]]; then
    as_root chsh -s /usr/bin/zsh "$TARGET_USER"
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
    die "docker command unavailable after package step"
  fi

  as_root mkdir -p /etc/docker
  install_if_absent /etc/docker/daemon.json "$PAYLOAD/assets/docker/daemon.json" 0644 root:root

  if getent group docker >/dev/null; then
    as_root usermod -aG docker "$TARGET_USER"
  fi

  if ! have_cmd systemctl; then
    die "systemctl unavailable; cannot enable Docker"
  fi

  as_root systemctl enable docker.service
  if [[ -d /run/systemd/system ]]; then
    as_root systemctl restart docker.service
  else
    log "systemd is not running; Docker is enabled for next boot"
  fi
}

configure_dev_shell_autostart() {
  if [[ ! -f "$PAYLOAD/assets/systemd/engineos-dev-shell.service" ||
      ! -f "$PAYLOAD/scripts/engineos-dev-shell-start" ]]; then
    die "dev shell autostart payload assets missing"
  fi

  as_root install -Dm0755 "$PAYLOAD/scripts/engineos-dev-shell-start" /usr/local/bin/engineos-dev-shell-start
  as_root install -Dm0644 "$PAYLOAD/assets/systemd/engineos-dev-shell.service" /etc/systemd/system/engineos-dev-shell.service
  log "installed dev shell autostart unit"

  if ! have_cmd systemctl; then
    die "systemctl unavailable; cannot enable dev shell autostart"
  fi

  as_root systemctl daemon-reload

  if ! have_cmd engineos-shell; then
    die "engineos-shell unavailable; dev shell autostart installed but not enabled"
  fi

  as_root systemctl enable engineos-dev-shell.service
}

install_codex() {
  "$RUN_CODEX" || {
    log "skip Codex CLI install/upgrade"
    return
  }

  local home
  home="$(user_home "$TARGET_USER")"
  [[ -n "$home" ]] || die "cannot find home for user: $TARGET_USER"

  if have_cmd codex; then
    log "codex before update: $(codex --version 2>&1 | tail -n 1)"
  else
    log "codex not installed"
  fi

  if have_cmd npm && npm list -g @openai/codex --depth=0 >/dev/null 2>&1; then
    log "update Codex CLI with npm"
    as_root npm install -g @openai/codex@latest
  else
    have_cmd curl || die "curl is required to install Codex CLI"
    log "install/update Codex CLI with official standalone installer"
    run_as_user "$TARGET_USER" env HOME="$home" CODEX_NON_INTERACTIVE=1 sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'
  fi

  have_cmd codex || die "codex command unavailable after install/update"
  log "codex after update: $(codex --version 2>&1 | tail -n 1)"
}

install_dev_repos() {
  "$RUN_DEV_REPOS" || {
    log "skip EngineDev helper repo fetch"
    return
  }

  have_cmd git || die "git is required to fetch EngineDev helper repos"

  local home repo_dir owner
  home="$(user_home "$TARGET_USER")"
  [[ -n "$home" ]] || die "cannot find home for user: $TARGET_USER"
  repo_dir="${ENGINEOS_DEV_REPO_DIR:-$home/dev}"
  owner="${ENGINEOS_DEV_REPO_OWNER:-Tango-Rocker}"

  as_root install -d -m0755 -o "$TARGET_USER" -g "$TARGET_USER" "$repo_dir"

  local repos=(
    codex-extractor:session-extrator
    opencode-autonomy:agent
    skills:skills
  )
  local entry repo remote_repo dest url upstream
  for entry in "${repos[@]}"; do
    repo="${entry%%:*}"
    remote_repo="${entry#*:}"
    dest="$repo_dir/$repo"
    url="https://github.com/$owner/$remote_repo.git"
    if [[ -d "$dest/.git" ]]; then
      log "fetch repo: $dest"
      run_as_user "$TARGET_USER" env HOME="$home" GIT_TERMINAL_PROMPT=0 git -C "$dest" fetch --prune
      if [[ -z "$(run_as_user "$TARGET_USER" git -C "$dest" status --porcelain)" ]]; then
        upstream="$(run_as_user "$TARGET_USER" git -C "$dest" \
          rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
        if [[ -n "$upstream" ]]; then
          log "fast-forward repo: $dest from $upstream"
          run_as_user "$TARGET_USER" env HOME="$home" GIT_TERMINAL_PROMPT=0 \
            git -C "$dest" pull --ff-only
        else
          log "repo has no upstream; fetched only: $dest"
        fi
      else
        log "preserve dirty repo after fetch: $dest"
      fi
    else
      log "clone repo: $url -> $dest"
      run_as_user "$TARGET_USER" env HOME="$home" GIT_TERMINAL_PROMPT=0 git clone "$url" "$dest"
    fi
  done
}

install_codex_insights() {
  "$RUN_DEV_REPOS" || return 0
  have_cmd python || die "python is required to install codex-insights"

  local home venv source_url version actual
  home="$(user_home "$TARGET_USER")"
  [[ -n "$home" ]] || die "cannot find home for user: $TARGET_USER"
  version="0.2.0"
  venv="$home/.local/share/codex-insights/venv"
  source_url="git+https://github.com/${ENGINEOS_DEV_REPO_OWNER:-Tango-Rocker}/session-extrator.git@v$version"

  log "install codex-insights $version in isolated user environment"
  run_as_user "$TARGET_USER" env HOME="$home" python -m venv "$venv"
  run_as_user "$TARGET_USER" env HOME="$home" \
    "$venv/bin/python" -m pip install --upgrade "$source_url"
  run_as_user "$TARGET_USER" install -d -m0755 "$home/.local/bin"
  run_as_user "$TARGET_USER" ln -sfn \
    "$venv/bin/codex-insights" "$home/.local/bin/codex-insights"
  actual="$(run_as_user "$TARGET_USER" "$venv/bin/codex-insights" --version)"
  [[ "$actual" == "codex-insights $version" ]] ||
    die "unexpected codex-insights version after install: $actual"
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

  if "$RUN_DEV_REPOS"; then
    local home repo insight_version
    home="$(user_home "$TARGET_USER")"
    for repo in codex-extractor opencode-autonomy skills; do
      if [[ -d "${ENGINEOS_DEV_REPO_DIR:-$home/dev}/$repo/.git" ]]; then
        log "OK repo: ${ENGINEOS_DEV_REPO_DIR:-$home/dev}/$repo"
      else
        log "FAIL repo missing: ${ENGINEOS_DEV_REPO_DIR:-$home/dev}/$repo"
        failures=$((failures + 1))
      fi
    done
    insight_version="$(run_as_user "$TARGET_USER" \
      "$home/.local/share/codex-insights/venv/bin/codex-insights" --version 2>/dev/null || true)"
    if [[ "$insight_version" == "codex-insights 0.2.0" ]]; then
      log "OK command: codex-insights 0.2.0"
    else
      log "FAIL codex-insights version: ${insight_version:-missing}"
      failures=$((failures + 1))
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
    --skip-dev-repos)
      RUN_DEV_REPOS=false
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
log "  repos:   $RUN_DEV_REPOS"

install_packages
configure_tmux
configure_zsh
configure_docker
configure_dev_shell_autostart
install_codex
install_dev_repos
install_codex_insights
validate_setup

log "post-first-deploy setup completed"
