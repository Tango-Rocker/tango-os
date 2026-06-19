#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
ONLY_PACKAGE=""
FAILURES=0

usage() {
  cat <<'HELP'
Usage: package_lint.sh [--package <name>]

Validate local EngineOS PKGBUILD metadata without running makepkg.
HELP
}

fail() {
  printf 'FAIL %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

ok() {
  printf 'OK   %s\n' "$*"
}

package_exists_in_list() {
  local needle="$1"
  local item
  while IFS= read -r item; do
    [[ "$item" == "$needle" ]] && return 0
  done < <(engineos_packages)
  return 1
}

pkgbuild_install_targets() {
  local pkg="$1"
  local pkgbuild="$ROOT/packages/$pkg/PKGBUILD"
  local target

  while IFS= read -r target; do
    target="${target//\$\{pkgname\}/$pkg}"
    target="${target//\$pkgname/$pkg}"
    printf '%s\n' "$target"
  done < <(sed -n 's/.*"\$pkgdir\([^"]*\)".*/\1/p' "$pkgbuild") | sort -u
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
      if ! package_exists_in_list "$dep_name"; then
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
      if ! grep -q 'agent_metadata.sh.*write' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: generated agent metadata is not installed"
        return
      fi
      if ! grep -q 'engineos-agent-dispatcher@.service' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: agent dispatcher service template is not installed"
        return
      fi
      if ! grep -q 'engineos-observe-exporter.service' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: observability exporter service is not installed"
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
    engineos-engine-runner)
      if grep -q 'engine_runner_daemon.py' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: Python engine runner daemon must not be packaged"
        return
      fi
      if ! grep -q 'engine-runner-daemon' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: Go engine runner daemon is not installed"
        return
      fi
      if ! grep -q 'engineos-engine-runner.service' "$pkg_dir/PKGBUILD"; then
        fail "$pkg: systemd service is not installed"
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
  esac

  ok "$pkg: PKGBUILD metadata"
  check_local_dependencies "$pkg"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package)
      shift
      ONLY_PACKAGE="${1:-}"
      [[ -n "$ONLY_PACKAGE" ]] || die "--package requires a package"
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
if [[ -n "$ONLY_PACKAGE" ]]; then
  package_exists_in_list "$ONLY_PACKAGE" || die "unknown package: $ONLY_PACKAGE"
  packages=("$ONLY_PACKAGE")
else
  mapfile -t packages < <(engineos_packages)
fi

printf 'EngineOS package lint\n'
printf '  root: %s\n' "$ROOT"

for pkg in "${packages[@]}"; do
  lint_pkgbuild "$pkg"
done

check_package_ownership

printf 'Package lint summary: %s failure(s)\n' "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
