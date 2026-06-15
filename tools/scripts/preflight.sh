#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
SCOPE="all"
PROFILE="enginedev"
ONLY_PACKAGE=""
FAILURES=0
WARNINGS=0
INSTALLED_BIN_DIR="${ENGINEOS_INSTALLED_BIN_DIR:-/usr/bin}"
INSTALLED_SCRIPT_DIR="${ENGINEOS_INSTALLED_SCRIPT_DIR:-/usr/lib/engineos/scripts}"

usage() {
  cat <<'HELP'
Usage: preflight.sh [all|repo|iso|scripts] [--profile <name>] [--package <name>]

Validate EngineOS scaffold structure before package or ISO builds.
This is safe to run outside Arch; Arch-only tools are reported as warnings.
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

require_file() {
  local path="$1"
  if [[ -f "$ROOT/$path" ]]; then
    ok "$path"
  else
    fail "missing file: $path"
  fi
}

require_dir() {
  local path="$1"
  if [[ -d "$ROOT/$path" ]]; then
    ok "$path/"
  else
    fail "missing directory: $path"
  fi
}

require_abs_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    ok "$path"
  else
    fail "missing file: $path"
  fi
}

check_abs_bash_syntax() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    fail "missing script for syntax check: $path"
    return
  fi

  if bash -n "$path"; then
    ok "bash syntax: $path"
  else
    fail "bash syntax failed: $path"
  fi
}

check_abs_python_syntax() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    fail "missing python file for syntax check: $path"
    return
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 unavailable; syntax not checked: $path"
    return
  fi

  if python3 - "$path" <<'PY' 2>/dev/null
import ast
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
ast.parse(path.read_text(), filename=str(path))
PY
  then
    ok "python syntax: $path"
  else
    fail "python syntax failed: $path"
  fi
}

installed_image_context() {
  [[ "${ENGINEOS_INSTALLED_IMAGE:-}" == "true" ]] && return 0
  [[ "$SCRIPT_DIR" == /usr/lib/engineos/scripts ]] && return 0
  [[ "$ROOT" == /usr || "$ROOT" == /usr/* ]] && return 0
  return 1
}

require_profile_package() {
  local profile_dir="$1"
  local pkg="$2"
  if grep -qx "$pkg" "$ROOT/$profile_dir/packages.x86_64"; then
    ok "$profile_dir package: $pkg"
  else
    fail "$profile_dir missing package: $pkg"
  fi
}

check_profile_repo_config() {
  local profile_dir="$1"
  local pacman_conf="$ROOT/$profile_dir/pacman.conf"

  if grep -Fx '[engineos]' "$pacman_conf" >/dev/null &&
      grep -F 'Server = file:///srv/engineos/repo/$arch' "$pacman_conf" >/dev/null; then
    ok "$profile_dir pacman.conf uses local engineos repo"
  else
    fail "$profile_dir pacman.conf does not use file:///srv/engineos/repo/\$arch"
  fi
}

check_profile_package_list() {
  local profile_dir="$1"
  local packages_file="$ROOT/$profile_dir/packages.x86_64"
  local pkg
  local seen_file="${TMPDIR:-/tmp}/engineos-profile-packages-$$"
  local failures_before="$FAILURES"

  : >"$seen_file"
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    [[ "$pkg" == \#* ]] && continue
    if grep -Fqx "$pkg" "$seen_file"; then
      fail "$profile_dir duplicate package entry: $pkg"
    else
      printf '%s\n' "$pkg" >>"$seen_file"
    fi

    if [[ "$pkg" == engineos-* ]]; then
      package_exists_in_list "$pkg" || fail "$profile_dir package has no local package definition: $pkg"
    fi
  done <"$packages_file"
  rm -f "$seen_file"

  if [[ "$FAILURES" -eq "$failures_before" ]]; then
    ok "$profile_dir package list"
  fi
}

check_bash_syntax() {
  local path="$1"
  if [[ ! -f "$ROOT/$path" ]]; then
    fail "missing script for syntax check: $path"
    return
  fi

  if bash -n "$ROOT/$path"; then
    ok "bash syntax: $path"
  else
    fail "bash syntax failed: $path"
  fi
}

package_exists_in_list() {
  local needle="$1"
  local item
  while IFS= read -r item; do
    [[ "$item" == "$needle" ]] && return 0
  done < <(engineos_packages)
  return 1
}

check_package_inputs() {
  local pkg="$1"

  case "$pkg" in
    engineos-config)
      require_file "packages/engineos-config/files/etc/engineos/profile.conf"
      require_file "packages/engineos-config/files/etc/engineos/runtime.conf"
      require_file "packages/engineos-config/files/etc/engineos/quake.conf"
      require_file "packages/engineos-config/files/etc/engineos/apps.toml"
      if ENGINEOS_APPS_MANIFEST="$ROOT/packages/engineos-config/files/etc/engineos/apps.toml" \
          "$ROOT/tools/scripts/app.sh" manifest validate >/dev/null; then
        ok "engineos app manifest validates"
      else
        fail "engineos app manifest validation failed"
      fi
      ;;
    engineos-cli)
      require_file "tools/engineos/engineos"
      require_file "tools/scripts/builder_handoff.sh"
      require_file "tools/scripts/builder_doctor_proof.sh"
      require_file "tools/scripts/post_first_deploy.sh"
      require_file "tools/scripts/bootstrap_builder.sh"
      require_file "tools/scripts/common.sh"
      require_file "tools/scripts/build_iso.sh"
      require_file "tools/scripts/build_engine.sh"
      require_file "tools/scripts/build_shell.sh"
      require_file "tools/scripts/build_repo.sh"
      require_file "tools/scripts/preflight.sh"
      require_file "tools/scripts/assets.sh"
      require_file "tools/scripts/app.sh"
      require_file "tools/scripts/artifacts.sh"
      require_file "tools/scripts/release.sh"
      require_file "tools/scripts/install_dev.sh"
      require_file "tools/scripts/terminal_launcher.sh"
      require_file "tools/scripts/capture_frame.sh"
      require_file "tools/scripts/doctor.sh"
      require_file "tools/scripts/input_trace.sh"
      require_file "tools/scripts/logs.sh"
      require_file "tools/scripts/package_lint.sh"
      require_file "tools/scripts/outputs.sh"
      require_file "tools/scripts/shell_runner.sh"
      require_file "tools/scripts/proof.sh"
      require_file "tools/scripts/vm.sh"
      require_file "tools/scripts/usb.sh"
      require_file "tools/scripts/test_runner.sh"
      require_file "tools/scripts/validate_builder.sh"
      require_file "tools/scripts/validate_repo.sh"
      require_file "tools/scripts/validate_engine.sh"
      require_file "tools/scripts/validate_shell.sh"
      require_file "tools/scripts/validate_boot.sh"
      require_file "tools/scripts/crash_bundle.sh"
      require_file "tools/scripts/smoke_test.sh"
      require_file "tools/post-install-payload/scripts/setup_dev_environment.sh"
      require_file "tools/post-install-payload/scripts/engineos-dev-shell-start"
      require_file "tools/post-install-payload/assets/systemd/engineos-dev-shell.service"
      require_file "tools/post-install-payload/assets/tmux.conf"
      require_file "tools/post-install-payload/assets/zprofile"
      require_file "tools/post-install-payload/assets/zshrc"
      require_file "tools/post-install-payload/assets/docker/daemon.json"
      require_file "tools/post-install-payload/assets/codex/engineos-dev-directives.md"
      ;;
    engineos-oh-my-zsh)
      require_file "packages/engineos-oh-my-zsh/PKGBUILD"
      ;;
    engineos-tmux-plugins)
      require_file "packages/engineos-tmux-plugins/PKGBUILD"
      ;;
    engineos-agent-tools)
      require_file "AGENTS.md"
      require_file "BACKLOG.md"
      require_file "CURRENT_STATUS.md"
      require_file "ROADMAP.md"
      require_file "docs/agent-harness.md"
      require_file "docs/dev-instance.md"
      require_file "docs/agent-lsp.md"
      require_file "docs/agent-workflow.md"
      require_file ".agents/skills/code-navigation/SKILL.md"
      ;;
    engineos-cube)
      require_file "apps/cube/README.md"
      require_file "apps/cube/meson.build"
      require_file "apps/cube/src/engineos-cube.c"
      ;;
    engineos-shell)
      require_file "shell/README.md"
      require_file "shell/meson.build"
      require_file "shell/src/engineos-shell.c"
      ;;
    engineos-engine-runner)
      require_file "tools/scripts/engine_runner.sh"
      require_file "tools/scripts/engine_runner_daemon.py"
      require_file "packages/engineos-engine-runner/files/usr/lib/systemd/system/engineos-engine-runner.service"
      require_file "engine-runner/README.md"
      if grep -F 'LogsDirectory=engineos' "$ROOT/packages/engineos-engine-runner/files/usr/lib/systemd/system/engineos-engine-runner.service" >/dev/null; then
        fail "engineos-engine-runner service lets systemd reset /var/log/engineos permissions"
      elif grep -F 'RuntimeDirectory=engineos' "$ROOT/packages/engineos-engine-runner/files/usr/lib/systemd/system/engineos-engine-runner.service" >/dev/null; then
        fail "engineos-engine-runner service lets systemd reset /run/engineos permissions"
      elif grep -F 'UMask=0002' "$ROOT/packages/engineos-engine-runner/files/usr/lib/systemd/system/engineos-engine-runner.service" >/dev/null &&
          grep -F 'ExecStartPre=/usr/bin/install -d -m 2775 -o root -g wheel /run/engineos /var/log/engineos /var/lib/engineos' \
          "$ROOT/packages/engineos-engine-runner/files/usr/lib/systemd/system/engineos-engine-runner.service" >/dev/null &&
          grep -F 'ExecStartPre=/usr/bin/chown root:wheel /run/engineos /var/log/engineos /var/lib/engineos' \
          "$ROOT/packages/engineos-engine-runner/files/usr/lib/systemd/system/engineos-engine-runner.service" >/dev/null &&
          grep -F 'ExecStartPre=/usr/bin/chmod 2775 /run/engineos /var/log/engineos /var/lib/engineos' \
          "$ROOT/packages/engineos-engine-runner/files/usr/lib/systemd/system/engineos-engine-runner.service" >/dev/null; then
        ok "engineos-engine-runner service preserves EngineOS log/state permissions"
      else
        fail "engineos-engine-runner service does not prepare writable EngineOS log/state dirs"
      fi
      ;;
    engineos-quakespasm)
      require_file "engines/quakespasm/engineos/build.sh"
      require_file "engines/quakespasm/engineos/fetch.sh"
      ;;
    engineos-quake-template)
      require_file "packages/engineos-quake-template/assets.toml"
      require_file "engines/quakespasm/engineos/build.sh"
      require_file "engines/quakespasm/engineos/fetch.sh"
      require_file "engines/quakespasm/engineos/run.sh"
      require_file "engines/quakespasm/engineos/smoke-test.sh"
      ;;
    *)
      fail "unknown package in preflight input map: $pkg"
      ;;
  esac
}

check_installed_scripts() {
  require_abs_file "$INSTALLED_BIN_DIR/engineos"
  require_abs_file "$INSTALLED_SCRIPT_DIR/common.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/preflight.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/app.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/assets.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/doctor.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/logs.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/outputs.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/proof.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/install_dev.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/test_runner.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/validate_boot.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/crash_bundle.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/smoke_test.sh"

  check_abs_bash_syntax "$INSTALLED_BIN_DIR/engineos"
  for script in "$INSTALLED_SCRIPT_DIR"/*.sh; do
    [[ -e "$script" ]] || {
      fail "missing installed scripts in $INSTALLED_SCRIPT_DIR"
      break
    }
    check_abs_bash_syntax "$script"
  done

  if [[ -f "$INSTALLED_SCRIPT_DIR/engine_runner_daemon.py" ]]; then
    check_abs_python_syntax "$INSTALLED_SCRIPT_DIR/engine_runner_daemon.py"
  else
    warn "$INSTALLED_SCRIPT_DIR/engine_runner_daemon.py missing; engine runner package may be absent"
  fi
}

check_scripts() {
  if installed_image_context && [[ ! -f "$ROOT/tools/engineos/engineos" ]]; then
    check_installed_scripts
    return
  fi

  require_file "tools/engineos/engineos"
  require_file "tools/scripts/builder_handoff.sh"
  require_file "tools/scripts/builder_doctor_proof.sh"
  require_file "tools/scripts/post_first_deploy.sh"
  require_file "tools/scripts/bootstrap_builder.sh"
  require_file "tools/scripts/common.sh"
  require_file "tools/scripts/build_iso.sh"
  require_file "tools/scripts/build_engine.sh"
  require_file "tools/scripts/build_shell.sh"
  require_file "tools/scripts/build_repo.sh"
  require_file "tools/scripts/preflight.sh"
  require_file "tools/scripts/assets.sh"
  require_file "tools/scripts/app.sh"
  require_file "tools/scripts/artifacts.sh"
  require_file "tools/scripts/release.sh"
  require_file "tools/scripts/install_dev.sh"
  require_file "tools/scripts/terminal_launcher.sh"
  require_file "tools/scripts/capture_frame.sh"
  require_file "tools/scripts/doctor.sh"
  require_file "tools/scripts/engine_runner.sh"
  require_file "tools/scripts/engine_runner_daemon.py"
  require_file "tools/scripts/input_trace.sh"
  require_file "tools/scripts/logs.sh"
  require_file "tools/scripts/package_lint.sh"
  require_file "tools/scripts/outputs.sh"
  require_file "tools/scripts/shell_runner.sh"
  require_file "tools/scripts/proof.sh"
  require_file "tools/scripts/vm.sh"
  require_file "tools/scripts/usb.sh"
  require_file "tools/scripts/test_runner.sh"
  require_file "tools/scripts/validate_builder.sh"
  require_file "tools/scripts/validate_repo.sh"
  require_file "tools/scripts/validate_engine.sh"
  require_file "tools/scripts/validate_shell.sh"
  require_file "tools/scripts/validate_boot.sh"
  require_file "tools/scripts/crash_bundle.sh"
  require_file "tools/scripts/smoke_test.sh"
  require_file "tools/post-install-payload/scripts/setup_dev_environment.sh"
  require_file "tools/post-install-payload/scripts/engineos-dev-shell-start"
  require_file "tools/post-install-payload/assets/systemd/engineos-dev-shell.service"
  require_file "tools/post-install-payload/assets/tmux.conf"
  require_file "tools/post-install-payload/assets/zprofile"
  require_file "tools/post-install-payload/assets/docker/daemon.json"
  require_file "tools/post-install-payload/assets/codex/engineos-dev-directives.md"
  require_file "engines/quakespasm/engineos/build.sh"
  require_file "engines/quakespasm/engineos/fetch.sh"
  require_file "engines/quakespasm/engineos/run.sh"
  require_file "engines/quakespasm/engineos/smoke-test.sh"
  require_file "tests/smoke.sh"

  check_bash_syntax "tools/engineos/engineos"
  check_bash_syntax "tools/scripts/builder_handoff.sh"
  check_bash_syntax "tools/scripts/builder_doctor_proof.sh"
  check_bash_syntax "tools/scripts/post_first_deploy.sh"
  check_bash_syntax "tools/scripts/bootstrap_builder.sh"
  check_bash_syntax "tools/scripts/common.sh"
  check_bash_syntax "tools/scripts/build_iso.sh"
  check_bash_syntax "tools/scripts/build_engine.sh"
  check_bash_syntax "tools/scripts/build_shell.sh"
  check_bash_syntax "tools/scripts/build_repo.sh"
  check_bash_syntax "tools/scripts/preflight.sh"
  check_bash_syntax "tools/scripts/assets.sh"
  check_bash_syntax "tools/scripts/app.sh"
  check_bash_syntax "tools/scripts/artifacts.sh"
  check_bash_syntax "tools/scripts/release.sh"
  check_bash_syntax "tools/scripts/install_dev.sh"
  check_bash_syntax "tools/scripts/terminal_launcher.sh"
  check_bash_syntax "tools/scripts/capture_frame.sh"
  check_bash_syntax "tools/scripts/doctor.sh"
  check_bash_syntax "tools/scripts/engine_runner.sh"
  check_abs_python_syntax "$ROOT/tools/scripts/engine_runner_daemon.py"
  check_bash_syntax "tools/scripts/input_trace.sh"
  check_bash_syntax "tools/scripts/logs.sh"
  check_bash_syntax "tools/scripts/package_lint.sh"
  check_bash_syntax "tools/scripts/outputs.sh"
  check_bash_syntax "tools/scripts/shell_runner.sh"
  check_bash_syntax "tools/scripts/proof.sh"
  check_bash_syntax "tools/scripts/vm.sh"
  check_bash_syntax "tools/scripts/usb.sh"
  check_bash_syntax "tools/scripts/test_runner.sh"
  check_bash_syntax "tools/scripts/validate_builder.sh"
  check_bash_syntax "tools/scripts/validate_repo.sh"
  check_bash_syntax "tools/scripts/validate_engine.sh"
  check_bash_syntax "tools/scripts/validate_shell.sh"
  check_bash_syntax "tools/scripts/validate_boot.sh"
  check_bash_syntax "tools/scripts/crash_bundle.sh"
  check_bash_syntax "tools/scripts/smoke_test.sh"
  check_bash_syntax "tools/post-install-payload/scripts/setup_dev_environment.sh"
  check_bash_syntax "tools/post-install-payload/scripts/engineos-dev-shell-start"
  check_bash_syntax "engines/quakespasm/engineos/build.sh"
  check_bash_syntax "engines/quakespasm/engineos/fetch.sh"
  check_bash_syntax "engines/quakespasm/engineos/run.sh"
  check_bash_syntax "engines/quakespasm/engineos/smoke-test.sh"
  check_bash_syntax "tests/smoke.sh"
  check_bash_syntax "archiso/enginedev/profiledef.sh"
  check_bash_syntax "archiso/engineruntime/profiledef.sh"
}

check_repo() {
  local pkg
  local packages=()

  if [[ -n "$ONLY_PACKAGE" ]]; then
    package_exists_in_list "$ONLY_PACKAGE" || fail "package is not in engineos package list: $ONLY_PACKAGE"
    packages=("$ONLY_PACKAGE")
  else
    mapfile -t packages < <(engineos_packages)
  fi

  require_dir "packages"
  if [[ -n "$ONLY_PACKAGE" ]]; then
    "$SCRIPT_DIR/package_lint.sh" --package "$ONLY_PACKAGE" || fail "package lint failed: $ONLY_PACKAGE"
  else
    "$SCRIPT_DIR/package_lint.sh" || fail "package lint failed"
  fi

  for pkg in "${packages[@]}"; do
    require_dir "packages/$pkg"
    require_file "packages/$pkg/PKGBUILD"
    check_bash_syntax "packages/$pkg/PKGBUILD"
    check_package_inputs "$pkg"
  done

  if is_arch_linux; then
    have_cmd makepkg || fail "makepkg missing; install base-devel"
    have_cmd repo-add || fail "repo-add missing; install pacman"
  else
    warn "not Arch Linux; real package build intentionally not checked"
  fi
}

check_iso() {
  local profile_dir="archiso/$PROFILE"
  local pkg

  require_dir "$profile_dir"
  require_file "$profile_dir/profiledef.sh"
  require_file "$profile_dir/packages.x86_64"
  require_file "$profile_dir/pacman.conf"
  check_bash_syntax "$profile_dir/profiledef.sh"
  check_profile_repo_config "$profile_dir"
  check_profile_package_list "$profile_dir"
  require_file "$profile_dir/efiboot/loader/entries/01-$PROFILE-linux.conf"
  if grep -F 'cow_spacesize=50%' "$ROOT/$profile_dir/efiboot/loader/entries/01-$PROFILE-linux.conf" >/dev/null; then
    ok "$profile_dir live cowspace is sized for writable VM sessions"
  else
    fail "$profile_dir live boot entry does not set cow_spacesize=50%"
  fi
  if grep -F 'systemd.mask=serial-getty@ttyS0.service' "$ROOT/$profile_dir/efiboot/loader/entries/01-$PROFILE-linux.conf" >/dev/null; then
    ok "$profile_dir masks serial getty while keeping serial console output"
  else
    fail "$profile_dir does not mask serial-getty@ttyS0.service"
  fi

  if [[ "$PROFILE" == "enginedev" ]]; then
    require_profile_package "$profile_dir" "foot"
    require_profile_package "$profile_dir" "ttf-dejavu"
    require_profile_package "$profile_dir" "engineos-cube"
    require_profile_package "$profile_dir" "engineos-shell"
    require_profile_package "$profile_dir" "engineos-engine-runner"
    require_profile_package "$profile_dir" "engineos-quakespasm"
    require_profile_package "$profile_dir" "engineos-quake-template"
    require_file "$profile_dir/airootfs/etc/issue"
    require_file "$profile_dir/airootfs/etc/udev/rules.d/70-engineos-device-access.rules"
    require_file "$profile_dir/airootfs/etc/skel/.bash_profile"
    require_file "$profile_dir/airootfs/root/customize_airootfs.sh"
    require_file "$profile_dir/airootfs/etc/systemd/system/engineos-live-setup.service"
    require_file "$profile_dir/airootfs/etc/systemd/system/engineos-dev-shell.service"
    require_file "$profile_dir/airootfs/usr/local/bin/engineos-firstboot"
    require_file "$profile_dir/airootfs/usr/local/bin/engineos-live-setup"
    require_file "$profile_dir/airootfs/usr/local/bin/engineos-dev-shell-start"
    check_bash_syntax "$profile_dir/airootfs/root/customize_airootfs.sh"
    check_bash_syntax "$profile_dir/airootfs/usr/local/bin/engineos-live-setup"
    check_bash_syntax "$profile_dir/airootfs/usr/local/bin/engineos-dev-shell-start"
    if grep -F 'wheel,input,audio,video,render' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      ok "$profile_dir live user gets input/audio/video/render groups"
    else
      fail "$profile_dir live user is missing device fallback groups"
    fi
    if grep -F 'usermod -aG wheel,input,audio,video,render dev' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null &&
        grep -F 'udevadm trigger --subsystem-match=input' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null; then
      ok "$profile_dir live setup repairs device groups and input udev state"
    else
      fail "$profile_dir live setup does not repair device group/input udev state"
    fi
    if grep -F "printf 'dev:dev\\n' | chpasswd" "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F "printf 'dev:dev\\n' | chpasswd" "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null &&
        grep -F 'PasswordAuthentication yes' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      ok "$profile_dir live SSH password auth is configured for dev"
    else
      fail "$profile_dir live SSH password auth is not configured for dev"
    fi
    if grep -F 'systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      ok "$profile_dir enables PipeWire user units globally"
    else
      fail "$profile_dir does not enable PipeWire user units globally"
    fi
    if grep -F 'systemctl enable engineos-dev-shell.service' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'ENGINEOS_TERMINAL_REQUIRE_WAYLAND=true' "$ROOT/$profile_dir/airootfs/etc/systemd/system/engineos-dev-shell.service" >/dev/null &&
        grep -F 'ENGINEOS_TERMINAL_SESSION_CMD=tmux new -A -s engineos' "$ROOT/$profile_dir/airootfs/etc/systemd/system/engineos-dev-shell.service" >/dev/null; then
      ok "$profile_dir dev shell autostarts tmux on shell-owned Wayland"
    else
      fail "$profile_dir dev shell autostart is not configured for shell-owned tmux"
    fi
    if grep -F "printf 'LANG=C.UTF-8\\n' >/etc/locale.conf" "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F "printf 'KEYMAP=us\\n' >/etc/vconsole.conf" "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'ln -sf /usr/share/zoneinfo/UTC /etc/localtime' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'systemctl mask systemd-firstboot.service' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      ok "$profile_dir live boot skips interactive systemd-firstboot"
    else
      fail "$profile_dir live boot may prompt for interactive systemd-firstboot"
    fi
    if grep -F 'cat >/etc/engineos/version' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'cat >/etc/engineos/profile.conf' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'ENGINEOS_BUILD_ID=$(date -u +%Y.%m.%d)' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'EngineDev OS $(date -u +%Y.%m.%d)' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      ok "$profile_dir writes EngineOS version/profile and login banner"
    else
      fail "$profile_dir does not write EngineOS version/profile/login banner"
    fi
    if grep -F 'chown root:wheel /var/log/engineos /var/lib/engineos' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null &&
        grep -F 'chmod 2775 /var/log/engineos /var/lib/engineos' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null; then
      ok "$profile_dir live setup repairs EngineOS state/log permissions"
    else
      fail "$profile_dir live setup does not repair EngineOS state/log permissions"
    fi
    if grep -F 'KERNEL=="event*", SUBSYSTEM=="input", GROUP="input", MODE="0666", TAG+="uaccess"' "$ROOT/$profile_dir/airootfs/etc/udev/rules.d/70-engineos-device-access.rules" >/dev/null &&
        grep -F 'SUBSYSTEM=="sound", GROUP="audio", MODE="0660", TAG+="uaccess"' "$ROOT/$profile_dir/airootfs/etc/udev/rules.d/70-engineos-device-access.rules" >/dev/null; then
      ok "$profile_dir device udev rules cover input and audio"
    else
      fail "$profile_dir device udev rules do not cover input and audio"
    fi
  elif [[ "$PROFILE" == "engineruntime" ]]; then
    require_profile_package "$profile_dir" "foot"
    require_profile_package "$profile_dir" "ttf-dejavu"
    require_profile_package "$profile_dir" "engineos-cube"
    require_profile_package "$profile_dir" "engineos-shell"
    require_profile_package "$profile_dir" "engineos-engine-runner"
    require_profile_package "$profile_dir" "engineos-quakespasm"
    require_profile_package "$profile_dir" "engineos-quake-template"
    require_file "$profile_dir/airootfs/etc/issue"
    require_file "$profile_dir/airootfs/etc/udev/rules.d/70-engineos-device-access.rules"
    require_file "$profile_dir/airootfs/etc/skel/.bash_profile"
    require_file "$profile_dir/airootfs/root/customize_airootfs.sh"
    require_file "$profile_dir/airootfs/etc/systemd/system/engineos-live-setup.service"
    require_file "$profile_dir/airootfs/etc/systemd/system/engineos-runtime.service"
    require_file "$profile_dir/airootfs/usr/local/bin/engineos-live-setup"
    require_file "$profile_dir/airootfs/usr/local/bin/engineos-recovery-help"
    require_file "$profile_dir/airootfs/usr/local/bin/engineos-runtime-start"
    check_bash_syntax "$profile_dir/airootfs/root/customize_airootfs.sh"
    check_bash_syntax "$profile_dir/airootfs/usr/local/bin/engineos-live-setup"
    check_bash_syntax "$profile_dir/airootfs/usr/local/bin/engineos-recovery-help"
    check_bash_syntax "$profile_dir/airootfs/usr/local/bin/engineos-runtime-start"
    if grep -F 'wheel,input,audio,video,render' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      ok "$profile_dir live user gets input/audio/video/render groups"
    else
      fail "$profile_dir live user is missing device fallback groups"
    fi
    if grep -F 'usermod -aG wheel,input,audio,video,render engineos' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null &&
        grep -F 'udevadm trigger --subsystem-match=input' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null; then
      ok "$profile_dir live setup repairs device groups and input udev state"
    else
      fail "$profile_dir live setup does not repair device group/input udev state"
    fi
    if grep -F 'systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      ok "$profile_dir enables PipeWire user units globally"
    else
      fail "$profile_dir does not enable PipeWire user units globally"
    fi
    if grep -F "printf 'engineos:engineos\\n' | chpasswd" "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'systemctl enable sshd.service' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'PasswordAuthentication yes' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'PermitEmptyPasswords no' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      ok "$profile_dir live SSH password auth is configured for engineos"
    else
      fail "$profile_dir live SSH password auth is not configured for engineos"
    fi
    if grep -F "printf 'LANG=C.UTF-8\\n' >/etc/locale.conf" "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F "printf 'KEYMAP=us\\n' >/etc/vconsole.conf" "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'ln -sf /usr/share/zoneinfo/UTC /etc/localtime' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'systemctl mask systemd-firstboot.service' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      ok "$profile_dir live boot skips interactive systemd-firstboot"
    else
      fail "$profile_dir live boot may prompt for interactive systemd-firstboot"
    fi
    if grep -F 'cat >/etc/engineos/version' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'cat >/etc/engineos/profile.conf' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'ENGINEOS_BUILD_ID=$(date -u +%Y.%m.%d)' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'EngineRuntime OS $(date -u +%Y.%m.%d)' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      ok "$profile_dir writes EngineOS version/profile and login banner"
    else
      fail "$profile_dir does not write EngineOS version/profile/login banner"
    fi
    if grep -F 'chown root:wheel /var/log/engineos /var/lib/engineos' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null &&
        grep -F 'chmod 2775 /var/log/engineos /var/lib/engineos' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null; then
      ok "$profile_dir live setup repairs EngineOS state/log permissions"
    else
      fail "$profile_dir live setup does not repair EngineOS state/log permissions"
    fi
    if grep -F 'KERNEL=="event*", SUBSYSTEM=="input", GROUP="input", MODE="0666", TAG+="uaccess"' "$ROOT/$profile_dir/airootfs/etc/udev/rules.d/70-engineos-device-access.rules" >/dev/null &&
        grep -F 'SUBSYSTEM=="sound", GROUP="audio", MODE="0660", TAG+="uaccess"' "$ROOT/$profile_dir/airootfs/etc/udev/rules.d/70-engineos-device-access.rules" >/dev/null; then
      ok "$profile_dir device udev rules cover input and audio"
    else
      fail "$profile_dir device udev rules do not cover input and audio"
    fi
    if grep -Fx 'User=engineos' "$ROOT/$profile_dir/airootfs/etc/systemd/system/engineos-runtime.service" >/dev/null &&
        grep -Fx 'PAMName=login' "$ROOT/$profile_dir/airootfs/etc/systemd/system/engineos-runtime.service" >/dev/null &&
        grep -Fx 'SupplementaryGroups=wheel input audio video render' "$ROOT/$profile_dir/airootfs/etc/systemd/system/engineos-runtime.service" >/dev/null; then
      ok "$profile_dir runtime service runs in engineos login session with device groups"
    else
      fail "$profile_dir runtime service is not configured for the engineos user seat"
    fi
    if grep -Fx 'Before=engineos-engine-runner.service engineos-runtime.service' "$ROOT/$profile_dir/airootfs/etc/systemd/system/engineos-live-setup.service" >/dev/null; then
      ok "$profile_dir live setup runs before runtime services"
    else
      fail "$profile_dir live setup ordering can block runtime services"
    fi
    if ! grep -F 'ENGINEOS_STATE_DIR=/run/engineos' "$ROOT/$profile_dir/airootfs/etc/systemd/system/engineos-runtime.service" >/dev/null &&
        grep -F 'ENGINEOS_ENGINE_SOCKET=/run/engineos/engine-runner.sock' "$ROOT/$profile_dir/airootfs/etc/systemd/system/engineos-runtime.service" >/dev/null; then
      ok "$profile_dir runtime service separates app state from shared engine runner socket"
    else
      fail "$profile_dir runtime service couples app state to the shared engine runner socket"
    fi
    if grep -F 'systemctl enable getty@tty2.service' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      ok "$profile_dir enables recovery getty@tty2.service"
    else
      fail "$profile_dir does not enable recovery getty@tty2.service"
    fi
    if grep -F 'engineos-recovery-help' "$ROOT/$profile_dir/profiledef.sh" >/dev/null; then
      ok "$profile_dir marks engineos-recovery-help executable"
    else
      fail "$profile_dir does not mark engineos-recovery-help executable"
    fi
    if grep -F 'engineos-recovery-help' "$ROOT/$profile_dir/airootfs/etc/skel/.bash_profile" >/dev/null; then
      ok "$profile_dir login shows recovery help"
    else
      fail "$profile_dir login does not show recovery help"
    fi
    if grep -F 'engineos logs runtime --last 200' "$ROOT/$profile_dir/airootfs/etc/issue" >/dev/null; then
      ok "$profile_dir issue points to runtime logs"
    else
      fail "$profile_dir issue does not point to runtime logs"
    fi
  fi

  if is_arch_linux; then
    have_cmd mkarchiso || fail "mkarchiso missing; install archiso"
    have_cmd sudo || fail "sudo missing"
  else
    warn "not Arch Linux; real ISO build intentionally not checked"
  fi
}

if [[ "${1:-}" == "help" || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 && "${1:-}" != --* ]]; then
  SCOPE="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      shift
      PROFILE="${1:-}"
      [[ -n "$PROFILE" ]] || die "--profile requires a profile"
      ;;
    --package)
      shift
      ONLY_PACKAGE="${1:-}"
      [[ -n "$ONLY_PACKAGE" ]] || die "--package requires a package"
      ;;
    *)
      die "unknown preflight option: $1"
      ;;
  esac
  shift
done

printf 'EngineOS preflight\n'
printf '  root:    %s\n' "$ROOT"
printf '  scope:   %s\n' "$SCOPE"
printf '  profile: %s\n' "$PROFILE"
[[ -n "$ONLY_PACKAGE" ]] && printf '  package: %s\n' "$ONLY_PACKAGE"

case "$SCOPE" in
  all)
    check_scripts
    check_repo
    PROFILE="enginedev"
    check_iso
    PROFILE="engineruntime"
    check_iso
    ;;
  repo)
    check_scripts
    check_repo
    ;;
  iso)
    check_scripts
    check_iso
    ;;
  scripts)
    check_scripts
    ;;
  *)
    die "unknown preflight scope: $SCOPE"
    ;;
esac

printf 'Preflight summary: %s failure(s), %s warning(s)\n' "$FAILURES" "$WARNINGS"

if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi
