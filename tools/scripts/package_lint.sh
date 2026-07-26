#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
REQUESTED_PACKAGES=()
FAILURES=0

usage() {
  cat <<'HELP'
Usage: package_lint.sh [--package <name>]...

Validate local EngineOS PKGBUILD metadata without running makepkg.
--package is repeatable. Unknown package names fail before work starts, and
duplicate package names are ignored after the first occurrence.
HELP
}

fail() {
  printf 'FAIL %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

ok() {
  printf 'OK   %s\n' "$*"
}

pkgbuild_install_targets() {
  local pkg="$1"
  local pkgbuild="$ROOT/packages/$pkg/PKGBUILD"
  local target

  while IFS= read -r target; do
    target="${target//\$\{pkgname\}/$pkg}"
    target="${target//\$pkgname/$pkg}"
    printf '%s\n' "$target"
  done < <(sed '/^[[:space:]]*rm[[:space:]]/d; s/.*"\$pkgdir\([^"]*\)".*/\1/p; t; d' "$pkgbuild") | sort -u
}

pkgbuild_dependency_names() {
  local pkg="$1"
  local array_name="$2"
  local pkg_dir="$ROOT/packages/$pkg"

  (
    set +u
    cd "$pkg_dir"
    # shellcheck disable=SC1091
    source PKGBUILD
    case "$array_name" in
      depends)
        printf '%s\n' "${depends[@]:-}"
        ;;
      makedepends)
        printf '%s\n' "${makedepends[@]:-}"
        ;;
      checkdepends)
        printf '%s\n' "${checkdepends[@]:-}"
        ;;
      *)
        exit 2
        ;;
    esac
  )
}

check_local_dependencies() {
  local pkg="$1"
  local dep
  local dep_name
  local failures_before="$FAILURES"

  for dep_kind in depends makedepends checkdepends; do
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      dep_name="${dep%%[<>=]*}"
      [[ "$dep_name" == engineos-* ]] || continue
      if ! engineos_package_known "$dep_name"; then
        fail "$pkg: local dependency has no package definition: $dep_name"
      fi
      if [[ "$dep_kind" != "depends" ]]; then
        fail "$pkg: local dependency $dep_name belongs in depends, not $dep_kind"
      fi
    done < <(pkgbuild_dependency_names "$pkg" "$dep_kind")
  done

  if [[ "$FAILURES" -eq "$failures_before" ]]; then
    ok "$pkg: local dependencies"
  fi
}

check_package_ownership() {
  local pkg
  local target
  local seen_file="${TMPDIR:-/tmp}/engineos-package-owners-$$"
  local failures_before="$FAILURES"

  : >"$seen_file"

  for pkg in "${packages[@]}"; do
    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      if grep -Fqx "$target" "$seen_file"; then
        fail "package file ownership conflict: $target"
      else
        printf '%s\n' "$target" >>"$seen_file"
      fi
    done < <(pkgbuild_install_targets "$pkg")
  done

  rm -f "$seen_file"

  if [[ "$FAILURES" -eq "$failures_before" ]]; then
    ok "package file ownership: no duplicate installed paths"
  fi
}

lint_pkgbuild() {
  local pkg="$1"
  local pkg_dir="$ROOT/packages/$pkg"

  [[ -d "$pkg_dir" ]] || {
    fail "$pkg: missing package directory"
    return
  }
  [[ -f "$pkg_dir/PKGBUILD" ]] || {
    fail "$pkg: missing PKGBUILD"
    return
  }

  if ! bash -n "$pkg_dir/PKGBUILD"; then
    fail "$pkg: PKGBUILD syntax failed"
    return
  fi

  (
    set +u
    cd "$pkg_dir"
    # shellcheck disable=SC1091
    source PKGBUILD

    [[ "${pkgname:-}" == "$pkg" ]] || {
      printf 'pkgname mismatch: expected %s got %s\n' "$pkg" "${pkgname:-unset}" >&2
      exit 10
    }
    [[ -n "${pkgver:-}" ]] || {
      printf 'missing pkgver\n' >&2
      exit 11
    }
    [[ -n "${pkgrel:-}" ]] || {
      printf 'missing pkgrel\n' >&2
      exit 12
    }
    [[ -n "${pkgdesc:-}" ]] || {
      printf 'missing pkgdesc\n' >&2
      exit 13
    }
    [[ "$(type -t package)" == "function" ]] || {
      printf 'missing package() function\n' >&2
      exit 14
    }
    [[ "${#arch[@]}" -gt 0 ]] || {
      printf 'missing arch array\n' >&2
      exit 15
    }
    [[ "${#license[@]}" -gt 0 ]] || {
      printf 'missing license array\n' >&2
      exit 16
    }
    [[ " ${license[*]} " == *" custom:EngineOS-TBD "* ]] || {
      printf 'expected custom:EngineOS-TBD license\n' >&2
      exit 17
    }
  ) || {
    fail "$pkg: metadata lint failed"
    return
  }

  if ! grep -q 'usr/share/licenses/\$pkgname/LICENSE' "$pkg_dir/PKGBUILD"; then
    fail "$pkg: custom license is not installed"
    return
  fi

  case "$pkg" in
    engineos-tools)
      if ! grep -q 'tools/engineos/eos' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: eos dispatcher is not installed"
        return
      fi
      if ! grep -q 'engineos_eos_commands' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: eos wrappers are not generated from the command list"
        return
      fi
		if ! grep -q "name '\*.py'" "$pkg_dir/PKGBUILD"; then
			fail "$pkg: Python router and hygiene scripts are not executable"
			return
		fi
      ;;
    engineos-config)
      if ! grep -q 'runtime.conf' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: runtime.conf is not installed"
        return
      fi
      if ! grep -q 'quake.conf' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: quake.conf is not installed"
        return
      fi
      if ! grep -q 'apps.toml' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: apps.toml is not installed"
        return
      fi
      ;;
    engineos-chatgpt)
      if ! grep -q 'apps/chatgpt-wpe' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: WPE client source tree is not packaged"
        return
      fi
      if ! grep -q 'meson install' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: Meson WPE client binary is not installed"
        return
      fi
      if ! grep -q "wpewebkit" "$pkg_dir/PKGBUILD"; then
        fail "$pkg: expected WPE WebKit dependency"
        return
      fi
      if ! grep -q "libcap" "$pkg_dir/PKGBUILD"; then
        fail "$pkg: expected capability-sanitizing dependency"
        return
      fi
      ;;
    engineos-mc)
      if ! grep -q 'engineos-quick-view-preview.patch' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: EngineOS Quick View patch is not applied"
        return
      fi
      if ! grep -q -- '--mc-pid' \
          "$pkg_dir/engineos-quick-view-preview.patch"; then
        fail "$pkg: Quick View patch does not pass the real MC PID"
        return
      fi
      ;;
	engineos-dgen)
		if ! grep -Eq '^_commit=[0-9a-f]{40}$' "$pkg_dir/PKGBUILD"; then
			fail "$pkg: source is not pinned to an exact commit"
			return
		fi
		if ! grep -Fq 'git -C "$source_dir" archive' "$pkg_dir/PKGBUILD"; then
			fail "$pkg: package does not archive the pinned managed checkout"
			return
		fi
		if grep -Eq '^source=.*git\+' "$pkg_dir/PKGBUILD"; then
			fail "$pkg: package must not perform an unauthenticated private source clone"
			return
		fi
		;;
	engineos-shell)
      if ! grep -q 'meson install' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: Meson shell binary is not installed"
        return
      fi
      if grep -q 'shell_runner.sh' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: shell runner wrapper belongs to engineos-tools"
        return
      fi
      if ! grep -q 'wlroots0.19' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: expected Arch wlroots0.19 dependency"
        return
      fi
      if ! grep -q 'libxkbcommon' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: expected libxkbcommon dependency"
        return
      fi
		;;
	engineos-mux)
		if ! grep -Eq '^_commit=[0-9a-f]{40}$' "$pkg_dir/PKGBUILD"; then
			fail "$pkg: tmux 3.6b fork source must pin an exact commit"
			return
		fi
		if ! grep -q 'meson install' "$pkg_dir/PKGBUILD"; then
			fail "$pkg: Meson mux binaries are not installed"
			return
		fi
		if ! grep -q '0002-engine-mux-in-server-frontend.patch' "$pkg_dir/PKGBUILD" ||
			! grep -q 'engine-mux-frontend.c' "$pkg_dir/PKGBUILD"; then
			fail "$pkg: in-server frontend sources must be packaged"
			return
		fi
		if ! grep -q "provides=('tmux=3.6_b')" "$pkg_dir/PKGBUILD" ||
				! grep -q "replaces=('tmux')" "$pkg_dir/PKGBUILD" ||
				! grep -q 'usr/bin/tmux' "$pkg_dir/PKGBUILD"; then
			fail "$pkg: fork must replace the system tmux package and binary"
			return
		fi
		if grep -q 'usr/bin/engine-mux' "$pkg_dir/PKGBUILD"; then
			fail "$pkg: side-by-side engine-mux binary must not be packaged"
			return
		fi
		if [[ -e "$pkg_dir/files/usr/lib/systemd/user/engine-muxd.service" ]]; then
			fail "$pkg: standalone engine-muxd service must not be packaged"
			return
		fi
		;;
    engineos-cube)
      if ! grep -q 'apps/cube' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: cube app source tree is not packaged"
        return
      fi
      if ! grep -q 'meson install' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: Meson cube binary is not installed"
        return
      fi
      if ! grep -q 'sdl2' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: expected SDL2 dependency"
        return
      fi
      if ! grep -q 'mesa' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: expected Mesa dependency"
        return
      fi
      ;;
	engineos-quakespasm)
		if ! grep -q 'engineos-quake.service' "$pkg_dir/PKGBUILD"; then
			fail "$pkg: per-user Quake service is not installed"
			return
		fi
      if ! grep -q 'build.sh.*--fetch' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: QuakeSpasm build wrapper is not used with fetch"
        return
      fi
      if ! grep -q 'usr/bin/quakespasm' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: quakespasm binary is not installed on PATH"
        return
      fi
      if ! grep -q 'quakespasm.pak' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: quakespasm.pak is not installed"
        return
      fi
      ;;
    engineos-wargus)
      if ! grep -q 'usr/bin/engineos-wargus' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: Wargus launcher adapter is not installed"
        return
      fi
      if ! grep -q 'ENGINEOS_WARGUS_LAUNCHER' "$pkg_dir/engineos-wargus" ||
          ! grep -q '/home/dev/wargus/launch-linux.sh' "$pkg_dir/engineos-wargus"; then
        fail "$pkg: adapter does not expose the repo-owned launcher contract"
        return
      fi
      if ! grep -q '^source=()$' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: integration package must not fetch or bundle game assets"
        return
      fi
      ;;
    engineos-ericw-tools)
      for tool in qbsp vis light bspinfo bsputil; do
        if ! grep -q "$tool" "$pkg_dir/PKGBUILD"; then
          fail "$pkg: expected ericw-tools binary is not packaged: $tool"
          return
        fi
      done
      if ! grep -q 'v0.18.2-rc1' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: expected ericw-tools v0.18.2-rc1 tag"
        return
      fi
      ;;
    engineos-trenchbroom)
      if ! grep -q 'v2026.1' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: expected TrenchBroom v2026.1 tag"
        return
      fi
      if ! grep -q 'cmake --build.*TrenchBroom' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: TrenchBroom source build target is not used"
        return
      fi
      if ! grep -q 'engineos-entity-browser-click-create.patch' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: EngineOS entity browser click patch is not applied"
        return
      fi
      if ! grep -q 'createPointEntity' "$pkg_dir/engineos-entity-browser-click-create.patch"; then
        fail "$pkg: entity browser click patch does not create point entities"
        return
      fi
      if ! grep -q 'engineos-trenchbroom.desktop' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: launch entry is not installed"
        return
      fi
      if ! grep -q 'usr/bin/engineos-trenchbroom' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: EngineOS TrenchBroom wrapper is not installed"
        return
      fi
      if ! grep -q 'usr/lib/engineos-trenchbroom/trenchbroom-bin' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: real TrenchBroom binary is not moved behind EngineOS wrapper"
        return
      fi
      if ! grep -q 'usr/bin/trenchbroom' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: default trenchbroom command is not wrapped"
        return
      fi
      if ! grep -q 'Exec=engineos-trenchbroom' "$pkg_dir/engineos-trenchbroom.desktop"; then
        fail "$pkg: desktop entry does not launch the EngineOS TrenchBroom wrapper"
        return
      fi
      ;;
    engineos-level-agent)
      if ! grep -q 'usr/bin/engineos-level-agent' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: engineos-level-agent command is not installed"
        return
      fi
      if ! grep -q 'usr/bin/eos-level-agent' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: eos-level-agent command alias is not installed"
        return
      fi
      if ! grep -q 'engineos-dgen.wad' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: generated dgen WAD is not installed"
        return
      fi
      if grep -q 'codex-cli' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: Codex CLI must remain user-managed, not a package dependency"
        return
      fi
      if ! grep -q 'codex mcp-server' "$ROOT/tools/level-agent/engineos_level_agent.py"; then
        fail "$pkg: level-agent does not invoke user-managed Codex MCP"
        return
      fi
      ;;
  esac

  ok "$pkg: PKGBUILD metadata"
  check_local_dependencies "$pkg"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package)
      shift
      engineos_add_package_request REQUESTED_PACKAGES "${1:-}"
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown package_lint option: $1"
      ;;
  esac
  shift
done

packages=()
engineos_select_packages REQUESTED_PACKAGES packages

printf 'EngineOS package lint\n'
printf '  root: %s\n' "$ROOT"
if [[ "${#REQUESTED_PACKAGES[@]}" -gt 0 ]]; then
  printf '  packages:\n'
  for pkg in "${packages[@]}"; do
    printf '    - %s\n' "$pkg"
  done
fi

for pkg in "${packages[@]}"; do
  lint_pkgbuild "$pkg"
done

check_package_ownership

printf 'Package lint summary: %s failure(s)\n' "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
