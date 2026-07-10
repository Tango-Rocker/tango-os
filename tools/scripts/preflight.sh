#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
SCOPE="all"
PROFILE="enginedev"
REQUESTED_PACKAGES=()
FAILURES=0
WARNINGS=0
INSTALLED_BIN_DIR="${ENGINEOS_INSTALLED_BIN_DIR:-/usr/bin}"
INSTALLED_SCRIPT_DIR="${ENGINEOS_INSTALLED_SCRIPT_DIR:-/usr/lib/engineos/scripts}"
INSTALLED_ENGINEOS_BIN_DIR="${ENGINEOS_INSTALLED_LIB_BIN_DIR:-/usr/lib/engineos/bin}"
INSTALLED_EOS_DIR="${ENGINEOS_INSTALLED_EOS_DIR:-/usr/lib/engineos/eos}"

usage() {
  cat <<'HELP'
Usage: preflight.sh [all|repo|iso|scripts] [--profile <name>] [--package <name>]...

Validate EngineOS scaffold structure before package or ISO builds.
--package is repeatable for repo checks. Unknown package names fail before work
starts, and duplicate package names are ignored after the first occurrence.
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
      engineos_package_known "$pkg" || fail "$profile_dir package has no local package definition: $pkg"
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
        ok "eos app manifest validates"
      else
        fail "eos app manifest validation failed"
      fi
      ;;
    engineos-tools)
      require_file "tools/engineos/eos"
      require_file "tools/engineos/engineos"
      require_file "tools/engineos/eos-wrapper"
      require_file "tools/engineos/generate-wrappers.sh"
      require_file "tools/scripts/common.sh"
      require_file "tools/scripts/package_lint.sh"
      require_file "tools/scripts/preflight.sh"
      require_file "tools/scripts/build_iso.sh"
      require_file "tools/scripts/build_engine.sh"
      require_file "tools/scripts/build_shell.sh"
      require_file "tools/scripts/build_repo.sh"
      require_file "tools/scripts/installation_guide.sh"
      require_file "tools/scripts/update_check.sh"
      require_file "tools/scripts/release.sh"
      require_file "tools/scripts/artifacts.sh"
      require_file "tools/scripts/doctor.sh"
      require_file "tools/scripts/logs.sh"
      require_file "tools/scripts/crash_bundle.sh"
      require_file "tools/scripts/validate_builder.sh"
      require_file "tools/scripts/validate_repo.sh"
      require_file "tools/scripts/validate_engine.sh"
      require_file "tools/scripts/validate_shell.sh"
      require_file "tools/scripts/app.sh"
      require_file "tools/scripts/terminal_launcher.sh"
      require_file "tools/scripts/outputs.sh"
      require_file "tools/scripts/shell_runner.sh"
      require_file "tools/scripts/assets.sh"
      require_file "tools/scripts/capture_frame.sh"
      require_file "tools/scripts/input_trace.sh"
      require_file "tools/scripts/observability.sh"
		require_file "tools/scripts/agent_router.py"
		require_file "tools/scripts/agent_hygiene.py"
      require_file "tools/eos/builder/builder_handoff.sh"
      require_file "tools/eos/builder/builder_doctor_proof.sh"
      require_file "tools/eos/builder/bootstrap_builder.sh"
      require_file "tools/eos/vm/vm.sh"
      require_file "tools/eos/os-dev/post_first_deploy.sh"
      require_file "tools/eos/bare-metal/install_dev.sh"
      require_file "tools/eos/bare-metal/usb.sh"
      require_file "tools/eos/bare-metal/secure_boot.sh"
      require_file "tools/eos/proof/proof.sh"
      require_file "tools/eos/proof/validate_boot.sh"
      require_file "tools/eos/test/test_runner.sh"
      require_file "tools/eos/test/smoke_test.sh"
      require_file "packages/engineos-tools/PKGBUILD"
      require_file "AGENTS.md"
      require_file "agentd.md"
      require_file "BACKLOG.md"
      require_file "CURRENT_STATUS.md"
      require_file "ROADMAP.md"
      require_file ".codex/config.toml"
      require_file "docs/agent-harness.md"
      require_file "docs/dev-instance.md"
      require_file "docs/agent-lsp.md"
      require_file "docs/agent-roles.md"
      require_file "docs/agent-workflow.md"
      require_file "docs/engineos-agent-pack.md"
      require_file ".agents/index.toml"
      require_file ".agents/skills/engineos/SKILL.md"
      require_file ".agents/skills/archiso-build/SKILL.md"
      require_file ".agents/skills/code-navigation/SKILL.md"
      require_file ".agents/skills/crash-forensics/SKILL.md"
      require_file ".agents/skills/input-routing/SKILL.md"
      require_file ".agents/skills/quake-port/SKILL.md"
      require_file ".agents/skills/render-gl/SKILL.md"
      require_file ".agents/skills/wlroots-compositor/SKILL.md"
		check_abs_python_syntax "$ROOT/tools/scripts/agent_router.py"
		check_abs_python_syntax "$ROOT/tools/scripts/agent_hygiene.py"
      ;;
    engineos-oh-my-zsh)
      require_file "packages/engineos-oh-my-zsh/PKGBUILD"
      ;;
    engineos-tmux-plugins)
      require_file "packages/engineos-tmux-plugins/PKGBUILD"
      ;;
	engineos-mux)
		require_file "mux/meson.build"
		require_file "mux/include/engine-mux-protocol.h"
		require_file "mux/src/engine-muxd.c"
		require_file "mux/src/engine-muxctl.c"
		require_file "packages/engineos-mux/PKGBUILD"
		require_file "packages/engineos-mux/0001-engine-mux-default-socket.patch"
		require_file "packages/engineos-mux/files/usr/lib/systemd/user/engine-muxd.service"
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
	  require_file "shell/src/engineos-mux-client.c"
      ;;
	engineos-dgen)
		require_file "packages/engineos-dgen/PKGBUILD"
		if grep -Eq '^_commit=[0-9a-f]{40}$' "$ROOT/packages/engineos-dgen/PKGBUILD"; then
			ok "engineos-dgen pins an exact source commit"
		else
			fail "engineos-dgen source is not pinned to an exact commit"
		fi
		;;
	engineos-quakespasm)
      require_file "engines/quakespasm/engineos/build.sh"
      require_file "engines/quakespasm/engineos/fetch.sh"
		require_file "engines/quakespasm/engineos/patches/0001-engineos-level-agent-console-commands.patch"
		require_file "tools/game/engineos_quake_service.py"
		require_file "packages/engineos-quakespasm/files/usr/lib/systemd/user/engineos-quake.service"
      ;;
    engineos-quake-template)
      require_file "packages/engineos-quake-template/assets.toml"
      require_file "engines/quakespasm/engineos/build.sh"
      require_file "engines/quakespasm/engineos/fetch.sh"
      require_file "engines/quakespasm/engineos/run.sh"
      require_file "engines/quakespasm/engineos/smoke-test.sh"
      ;;
    engineos-ericw-tools)
      require_file "packages/engineos-ericw-tools/PKGBUILD"
      ;;
    engineos-trenchbroom)
      require_file "packages/engineos-trenchbroom/PKGBUILD"
      require_file "packages/engineos-trenchbroom/engineos-entity-browser-click-create.patch"
      require_file "packages/engineos-trenchbroom/engineos-trenchbroom-wrapper"
      require_file "packages/engineos-trenchbroom/engineos-trenchbroom.desktop"
      ;;
	engineos-level-agent)
		require_file "tools/level-agent/engineos-level-agent"
		require_file "packages/engineos-level-agent/files/usr/lib/systemd/user/engineos-level-agent.service"
      require_file "tools/level-agent/engineos_level_agent.py"
      require_file "tools/scripts/generate_dgen_wad.py"
      require_file "packages/engineos-level-agent/PKGBUILD"
      ;;
    *)
      fail "unknown package in preflight input map: $pkg"
      ;;
  esac
}

check_installed_scripts() {
  require_abs_file "$INSTALLED_BIN_DIR/eos"
  require_abs_file "$INSTALLED_BIN_DIR/eos-doctor"
  require_abs_file "$INSTALLED_BIN_DIR/eos-build"
  require_abs_file "$INSTALLED_BIN_DIR/eos-agent"
  require_abs_file "$INSTALLED_BIN_DIR/eos-observe"
  require_abs_file "$INSTALLED_BIN_DIR/eos-source-test"
  require_abs_file "$INSTALLED_BIN_DIR/eos-test"
  require_abs_file "$INSTALLED_BIN_DIR/engineos"
  require_abs_file "$INSTALLED_SCRIPT_DIR/common.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/preflight.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/app.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/assets.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/doctor.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/logs.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/outputs.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/installation_guide.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/update_check.sh"
  require_abs_file "$INSTALLED_SCRIPT_DIR/observability.sh"
	require_abs_file "$INSTALLED_SCRIPT_DIR/agent_router.py"
	require_abs_file "$INSTALLED_SCRIPT_DIR/agent_hygiene.py"
  require_abs_file "$INSTALLED_SCRIPT_DIR/crash_bundle.sh"
  require_abs_file "$INSTALLED_EOS_DIR/builder/bootstrap_builder.sh"
  require_abs_file "$INSTALLED_EOS_DIR/builder/builder_handoff.sh"
  require_abs_file "$INSTALLED_EOS_DIR/builder/builder_doctor_proof.sh"
  require_abs_file "$INSTALLED_EOS_DIR/vm/vm.sh"
  require_abs_file "$INSTALLED_EOS_DIR/os-dev/post_first_deploy.sh"
  require_abs_file "$INSTALLED_EOS_DIR/bare-metal/install_dev.sh"
  require_abs_file "$INSTALLED_EOS_DIR/bare-metal/usb.sh"
  require_abs_file "$INSTALLED_EOS_DIR/bare-metal/secure_boot.sh"
  require_abs_file "$INSTALLED_EOS_DIR/proof/proof.sh"
  require_abs_file "$INSTALLED_EOS_DIR/proof/validate_boot.sh"
  require_abs_file "$INSTALLED_EOS_DIR/test/test_runner.sh"
  require_abs_file "$INSTALLED_EOS_DIR/test/smoke_test.sh"

  check_abs_bash_syntax "$INSTALLED_BIN_DIR/eos"
  check_abs_bash_syntax "$INSTALLED_BIN_DIR/eos-doctor"
  check_abs_bash_syntax "$INSTALLED_BIN_DIR/eos-build"
  check_abs_bash_syntax "$INSTALLED_BIN_DIR/eos-agent"
  check_abs_bash_syntax "$INSTALLED_BIN_DIR/eos-observe"
  check_abs_bash_syntax "$INSTALLED_BIN_DIR/eos-source-test"
  check_abs_bash_syntax "$INSTALLED_BIN_DIR/eos-test"
  check_abs_bash_syntax "$INSTALLED_BIN_DIR/engineos"
  for script in "$INSTALLED_SCRIPT_DIR"/*.sh; do
    [[ -e "$script" ]] || {
      fail "missing installed scripts in $INSTALLED_SCRIPT_DIR"
      break
    }
    check_abs_bash_syntax "$script"
  done
  for module in "$INSTALLED_EOS_DIR"/*/*.sh; do
    [[ -e "$module" ]] || {
      fail "missing installed eos modules in $INSTALLED_EOS_DIR"
      break
    }
    check_abs_bash_syntax "$module"
  done

}

check_scripts() {
  if installed_image_context && [[ ! -f "$ROOT/tools/engineos/engineos" ]]; then
    check_installed_scripts
    return
  fi

  require_file "tools/engineos/engineos"
  require_file "tools/engineos/eos"
  require_file "tools/engineos/eos-source-test"
  require_file "tools/engineos/eos-wrapper"
  require_file "tools/engineos/generate-wrappers.sh"
  require_file "tools/eos/README.md"
  require_file "tools/eos/builder/bootstrap_builder.sh"
  require_file "tools/eos/builder/builder_handoff.sh"
  require_file "tools/eos/builder/builder_doctor_proof.sh"
  require_file "tools/eos/builder/create_builder_vm_hyperv.ps1"
  require_file "tools/eos/builder/tune_builder_vm_hyperv.ps1"
  require_file "tools/eos/vm/vm.sh"
  require_file "tools/eos/vm/create_iso_test_vm_hyperv.ps1"
  require_file "tools/eos/os-dev/post_first_deploy.sh"
  require_file "tools/eos/bare-metal/install_dev.sh"
  require_file "tools/eos/bare-metal/usb.sh"
  require_file "tools/eos/bare-metal/secure_boot.sh"
  require_file "tools/eos/bare-metal/deploy_real_install_from_windows.ps1"
  require_file "tools/eos/bare-metal/write_signed_iso_usb_windows.ps1"
  require_file "tools/eos/proof/proof.sh"
  require_file "tools/eos/proof/validate_boot.sh"
  require_file "tools/eos/test/test_runner.sh"
  require_file "tools/eos/test/smoke_test.sh"
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
  require_file "tools/scripts/installation_guide.sh"
  require_file "tools/scripts/terminal_launcher.sh"
  require_file "tools/scripts/capture_frame.sh"
  require_file "tools/scripts/doctor.sh"
	require_file "tools/scripts/game.sh"
	require_file "tools/scripts/change_plan.py"
	require_file "tools/scripts/dev_workflow.sh"
  require_file "tools/scripts/input_trace.sh"
  require_file "tools/scripts/logs.sh"
  require_file "tools/scripts/package_lint.sh"
  require_file "tools/scripts/outputs.sh"
  require_file "tools/scripts/shell_runner.sh"
  require_file "tools/scripts/update_check.sh"
  require_file "tools/scripts/observability.sh"
	require_file "tools/scripts/agent_router.py"
	require_file "tools/scripts/agent_hygiene.py"
  require_file "tools/scripts/validate_builder.sh"
  require_file "tools/scripts/validate_repo.sh"
  require_file "tools/scripts/validate_engine.sh"
  require_file "tools/scripts/validate_shell.sh"
  require_file "tools/scripts/crash_bundle.sh"
	  require_file "tools/post-install-payload/scripts/setup_dev_environment.sh"
	  require_file "tools/post-install-payload/scripts/engineos-dev-shell-start"
	require_file "tools/post-install-payload/scripts/engineos-tmux-pane-bridge"
	require_file "tools/post-install-payload/scripts/engineos-tmux-window-move"
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
  check_bash_syntax "tools/engineos/eos"
  check_bash_syntax "tools/engineos/eos-wrapper"
  for eos_command in "$ROOT"/tools/engineos/eos-*; do
    [[ -f "$eos_command" ]] || continue
    check_abs_bash_syntax "$eos_command"
  done
  for eos_module in "$ROOT"/tools/eos/*/*.sh; do
    [[ -f "$eos_module" ]] || continue
    check_abs_bash_syntax "$eos_module"
  done
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
  check_bash_syntax "tools/scripts/installation_guide.sh"
  check_bash_syntax "tools/scripts/terminal_launcher.sh"
  check_bash_syntax "tools/scripts/capture_frame.sh"
  check_bash_syntax "tools/scripts/doctor.sh"
	check_bash_syntax "tools/scripts/game.sh"
	check_bash_syntax "tools/scripts/dev_workflow.sh"
  check_bash_syntax "tools/scripts/input_trace.sh"
  check_bash_syntax "tools/scripts/logs.sh"
  check_bash_syntax "tools/scripts/package_lint.sh"
  check_bash_syntax "tools/scripts/outputs.sh"
  check_bash_syntax "tools/scripts/shell_runner.sh"
  check_bash_syntax "tools/scripts/update_check.sh"
  check_bash_syntax "tools/scripts/observability.sh"
	check_abs_python_syntax "$ROOT/tools/scripts/agent_router.py"
	check_abs_python_syntax "$ROOT/tools/scripts/agent_hygiene.py"
  check_bash_syntax "tools/scripts/validate_builder.sh"
  check_bash_syntax "tools/scripts/validate_repo.sh"
  check_bash_syntax "tools/scripts/validate_engine.sh"
  check_bash_syntax "tools/scripts/validate_shell.sh"
  check_bash_syntax "tools/scripts/crash_bundle.sh"
	  check_bash_syntax "tools/post-install-payload/scripts/setup_dev_environment.sh"
	  check_bash_syntax "tools/post-install-payload/scripts/engineos-dev-shell-start"
	  check_bash_syntax "tools/post-install-payload/scripts/engineos-tmux-pane-bridge"
	  check_bash_syntax "tools/post-install-payload/scripts/engineos-tmux-pane-sync"
	  check_bash_syntax "tools/post-install-payload/scripts/engineos-tmux-window-sync"
	  check_bash_syntax "tools/post-install-payload/scripts/engineos-tmux-window-focus"
	  check_bash_syntax "tools/post-install-payload/scripts/engineos-tmux-window-proxy"
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
  local credential_file
  local packages=()
  local package_lint_args=()

  shopt -s nullglob
  for credential_file in "$ROOT"/pat_token*; do
    fail "plaintext repository credential must be removed and revoked: ${credential_file#$ROOT/}"
  done
  shopt -u nullglob

  engineos_select_packages REQUESTED_PACKAGES packages
  while IFS= read -r arg; do
    package_lint_args+=("$arg")
  done < <(engineos_package_cli_args REQUESTED_PACKAGES)

  require_dir "packages"
  if [[ "${#package_lint_args[@]}" -gt 0 ]]; then
    "$SCRIPT_DIR/package_lint.sh" "${package_lint_args[@]}" ||
      fail "package lint failed: ${REQUESTED_PACKAGES[*]}"
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
  if [[ "$PROFILE" == "enginedev" ]]; then
    if grep -F 'console=tty0' "$ROOT/$profile_dir/efiboot/loader/entries/01-$PROFILE-linux.conf" >/dev/null &&
        ! grep -F 'console=ttyS0' "$ROOT/$profile_dir/efiboot/loader/entries/01-$PROFILE-linux.conf" >/dev/null &&
        ! grep -F 'serial-getty@ttyS0.service' "$ROOT/$profile_dir/efiboot/loader/entries/01-$PROFILE-linux.conf" >/dev/null; then
      ok "$profile_dir keeps bare-metal boot output on tty0"
    else
      fail "$profile_dir boot entry should avoid serial console redirection for bare-metal installs"
    fi
  elif grep -F 'systemd.mask=serial-getty@ttyS0.service' "$ROOT/$profile_dir/efiboot/loader/entries/01-$PROFILE-linux.conf" >/dev/null; then
    ok "$profile_dir masks serial getty while keeping serial console output"
  else
    fail "$profile_dir does not mask serial-getty@ttyS0.service"
  fi

  if [[ "$PROFILE" == "enginedev" ]]; then
    require_profile_package "$profile_dir" "foot"
    require_profile_package "$profile_dir" "ttf-dejavu"
    require_profile_package "$profile_dir" "engineos-cube"
    require_profile_package "$profile_dir" "engineos-shell"
		require_profile_package "$profile_dir" "engineos-dgen"
    require_profile_package "$profile_dir" "engineos-quakespasm"
    require_profile_package "$profile_dir" "engineos-quake-template"
    require_profile_package "$profile_dir" "engineos-ericw-tools"
    require_profile_package "$profile_dir" "engineos-trenchbroom"
    require_profile_package "$profile_dir" "engineos-level-agent"
    require_file "$profile_dir/airootfs/etc/issue"
    require_file "$profile_dir/airootfs/etc/udev/rules.d/70-engineos-device-access.rules"
    require_file "$profile_dir/airootfs/etc/skel/.bash_profile"
    require_file "$profile_dir/airootfs/root/customize_airootfs.sh"
    require_file "$profile_dir/airootfs/etc/systemd/system/engineos-live-setup.service"
    require_file "$profile_dir/airootfs/etc/systemd/system/engineos-live-codex-setup.service"
    require_file "$profile_dir/airootfs/etc/systemd/system/engineos-dev-shell.service"
    require_file "$profile_dir/airootfs/usr/local/bin/engineos-firstboot"
    require_file "$profile_dir/airootfs/usr/local/bin/engineos-live-setup"
    require_file "$profile_dir/airootfs/usr/local/bin/engineos-live-codex-setup"
    require_file "$profile_dir/airootfs/usr/local/bin/codex"
    require_file "$profile_dir/airootfs/usr/local/bin/engineos-dev-shell-start"
    check_bash_syntax "$profile_dir/airootfs/root/customize_airootfs.sh"
    check_bash_syntax "$profile_dir/airootfs/usr/local/bin/engineos-live-setup"
    check_bash_syntax "$profile_dir/airootfs/usr/local/bin/engineos-live-codex-setup"
    check_bash_syntax "$profile_dir/airootfs/usr/local/bin/codex"
    check_bash_syntax "$profile_dir/airootfs/usr/local/bin/engineos-dev-shell-start"
    if grep -F 'best_effort()' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null ||
        grep -F 'WARN best-effort failed' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null ||
        grep -F 'best_effort()' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-codex-setup" >/dev/null ||
        grep -F 'WARN best-effort failed' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-codex-setup" >/dev/null; then
      fail "$profile_dir live setup scripts still hide required setup failures"
    else
      ok "$profile_dir live setup scripts fail closed for required setup"
    fi
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
    if grep -F ': >/var/lib/systemd/linger/dev' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      ok "$profile_dir enables user linger in the image"
    else
      fail "$profile_dir does not enable user linger in the image"
    fi
    if grep -F 'best_effort()' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null ||
        grep -F 'WARN best-effort failed' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      fail "$profile_dir customize_airootfs still hides required setup failures"
    else
      ok "$profile_dir customize_airootfs fails closed for required setup"
    fi
    if grep -F 'systemctl enable engineos-dev-shell.service' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'ENGINEOS_TERMINAL_REQUIRE_WAYLAND=true' "$ROOT/$profile_dir/airootfs/etc/systemd/system/engineos-dev-shell.service" >/dev/null &&
        grep -F 'ENGINEOS_TERMINAL_SESSION_CMD=engineos-tmux-attach-primary' "$ROOT/$profile_dir/airootfs/etc/systemd/system/engineos-dev-shell.service" >/dev/null; then
      ok "$profile_dir dev shell autostarts tmux on shell-owned Wayland"
    else
      fail "$profile_dir dev shell autostart is not configured for shell-owned tmux"
    fi
    if grep -F 'systemctl enable engineos-live-codex-setup.service' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'https://chatgpt.com/codex/install.sh' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-codex-setup" >/dev/null &&
        grep -F 'chmod 0755 "$EMBEDDED_CODEX"' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-codex-setup" >/dev/null &&
        grep -F '/home/dev/.codex/packages/standalone/releases/0.140.0-x86_64-unknown-linux-musl/bin/codex"]="1000:1000:755' "$ROOT/$profile_dir/profiledef.sh" >/dev/null &&
        grep -F 'CODEX_BIN="$TARGET_HOME/.local/bin/codex"' "$ROOT/$profile_dir/airootfs/usr/local/bin/codex" >/dev/null &&
        grep -F 'SYSTEM_CODEX_BIN="${ENGINEOS_SYSTEM_CODEX_BIN:-/usr/bin/codex}"' "$ROOT/$profile_dir/airootfs/usr/local/bin/codex" >/dev/null; then
      ok "$profile_dir live ISO has Codex on-demand setup"
    else
      fail "$profile_dir live ISO does not provide Codex on-demand setup"
    fi
    if grep -F "sed -i 's/^#\\(en_US\\.UTF-8 UTF-8\\)/\\1/' /etc/locale.gen" "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'locale-gen' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F "printf 'LANG=en_US.UTF-8\\n' >/etc/locale.conf" "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F "printf 'KEYMAP=us\\n' >/etc/vconsole.conf" "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'ln -sf /usr/share/zoneinfo/America/Argentina/Buenos_Aires /etc/localtime' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
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
        grep -F 'chmod 2775 /var/log/engineos /var/lib/engineos' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null &&
				grep -F '/var/log/engineos/engine.log' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null &&
        grep -F 'chmod 0664' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null; then
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
    if grep -F 'best_effort()' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null ||
        grep -F 'WARN best-effort failed' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null; then
      fail "$profile_dir live setup script still hides required setup failures"
    else
      ok "$profile_dir live setup script fails closed for required setup"
    fi
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
    if grep -F ': >/var/lib/systemd/linger/engineos' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      ok "$profile_dir enables user linger in the image"
    else
      fail "$profile_dir does not enable user linger in the image"
    fi
    if grep -F 'best_effort()' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null ||
        grep -F 'WARN best-effort failed' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      fail "$profile_dir customize_airootfs still hides required setup failures"
    else
      ok "$profile_dir customize_airootfs fails closed for required setup"
    fi
    if grep -F "printf 'engineos:engineos\\n' | chpasswd" "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'systemctl enable sshd.service' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'PasswordAuthentication yes' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'PermitEmptyPasswords no' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null; then
      ok "$profile_dir live SSH password auth is configured for engineos"
    else
      fail "$profile_dir live SSH password auth is not configured for engineos"
    fi
    if grep -F "sed -i 's/^#\\(en_US\\.UTF-8 UTF-8\\)/\\1/' /etc/locale.gen" "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'locale-gen' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F "printf 'LANG=en_US.UTF-8\\n' >/etc/locale.conf" "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F "printf 'KEYMAP=us\\n' >/etc/vconsole.conf" "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
        grep -F 'ln -sf /usr/share/zoneinfo/America/Argentina/Buenos_Aires /etc/localtime' "$ROOT/$profile_dir/airootfs/root/customize_airootfs.sh" >/dev/null &&
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
        grep -F 'chmod 2775 /var/log/engineos /var/lib/engineos' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null &&
				grep -F '/var/log/engineos/engine.log' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null &&
        grep -F 'chmod 0664' "$ROOT/$profile_dir/airootfs/usr/local/bin/engineos-live-setup" >/dev/null; then
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
		if grep -Fx 'Before=engineos-runtime.service' "$ROOT/$profile_dir/airootfs/etc/systemd/system/engineos-live-setup.service" >/dev/null; then
      ok "$profile_dir live setup runs before runtime services"
    else
      fail "$profile_dir live setup ordering can block runtime services"
    fi
		if ! grep -F 'ENGINEOS_STATE_DIR=/run/engineos' "$ROOT/$profile_dir/airootfs/etc/systemd/system/engineos-runtime.service" >/dev/null &&
				! grep -F 'ENGINEOS_ENGINE_SOCKET=' "$ROOT/$profile_dir/airootfs/etc/systemd/system/engineos-runtime.service" >/dev/null; then
			ok "$profile_dir runtime service has no root engine-runner coupling"
		else
			fail "$profile_dir runtime service still couples app state to the removed engine runner"
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
    if grep -F 'eos-logs runtime --last 200' "$ROOT/$profile_dir/airootfs/etc/issue" >/dev/null; then
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
      engineos_add_package_request REQUESTED_PACKAGES "${1:-}"
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
if [[ "${#REQUESTED_PACKAGES[@]}" -gt 0 ]]; then
  selected_for_print=()
  engineos_select_packages REQUESTED_PACKAGES selected_for_print
  printf '  packages:\n'
  for pkg in "${selected_for_print[@]}"; do
    printf '    - %s\n' "$pkg"
  done
fi

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
