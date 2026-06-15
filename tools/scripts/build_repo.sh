#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
DRY_RUN=false
ONLY_PACKAGE=""
REPO_ARCH="${ENGINEOS_REPO_ARCH:-x86_64}"
REPO_DIR="${ENGINEOS_REPO_DIR:-$ROOT/repo/$REPO_ARCH}"
REPO_NAME="${ENGINEOS_REPO_NAME:-engineos}"

mapfile -t PACKAGES < <(engineos_packages)

usage() {
  cat <<'HELP'
Usage: build_repo.sh [--dry-run] [--package <name>]

Build local EngineOS Arch packages and update the local pacman repository.
Real builds must run on the Arch builder VM.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --package)
      shift
      ONLY_PACKAGE="${1:-}"
      [[ -n "$ONLY_PACKAGE" ]] || die "--package requires a package name"
      ;;
    --help|-h|help)
      usage
      exit 0
      ;;
    *)
      die "unknown build_repo option: $1"
      ;;
  esac
  shift
done

selected_packages=()
for pkg in "${PACKAGES[@]}"; do
  if [[ -z "$ONLY_PACKAGE" || "$pkg" == "$ONLY_PACKAGE" ]]; then
    selected_packages+=("$pkg")
  fi
done

[[ ${#selected_packages[@]} -gt 0 ]] || die "no package matched: $ONLY_PACKAGE"

package_artifacts() {
  local pkg="$1"
  find "$REPO_DIR" -maxdepth 1 -type f \
    \( -name "$pkg-*.pkg.tar.zst" -o -name "$pkg-*.pkg.tar.xz" -o -name "$pkg-*.pkg.tar.gz" \) \
    -print 2>/dev/null
}

package_artifact_exists() {
  local pkg="$1"
  package_artifacts "$pkg" | grep -q .
}

pkgbuild_runtime_dependencies() {
  local pkg="$1"
  local pkg_dir="$ROOT/packages/$pkg"

  (
    set +u
    cd "$pkg_dir"
    # shellcheck disable=SC1091
    source PKGBUILD
    printf '%s\n' "${depends[@]:-}"
  )
}

check_local_runtime_deps_ready() {
  local pkg="$1"
  local dep
  local dep_name

  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    dep_name="${dep%%[<>=]*}"
    [[ "$dep_name" == engineos-* ]] || continue
    if ! package_artifact_exists "$dep_name"; then
      die "$pkg needs local package $dep_name; build all packages first or build $dep_name into $REPO_DIR"
    fi
  done < <(pkgbuild_runtime_dependencies "$pkg")
}

repo_add_current_artifacts() {
  local artifact
  local name
  local version
  local current_version
  local artifacts=()
  declare -A latest_artifact=()
  declare -A latest_version=()

  while IFS= read -r artifact; do
    read -r name version < <(pacman -Qp "$artifact" 2>/dev/null || true)
    [[ -n "${name:-}" && -n "${version:-}" ]] || continue

    current_version="${latest_version[$name]:-}"
    if [[ -z "$current_version" ]] || [[ "$(vercmp "$version" "$current_version")" -gt 0 ]]; then
      latest_artifact[$name]="$artifact"
      latest_version[$name]="$version"
    fi
  done < <(find "$REPO_DIR" -maxdepth 1 -type f \
    \( -name '*.pkg.tar.zst' -o -name '*.pkg.tar.xz' -o -name '*.pkg.tar.gz' \) \
    -print | sort)

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    artifacts+=("${latest_artifact[$name]}")
  done < <(printf '%s\n' "${!latest_artifact[@]}" | sort)

  [[ ${#artifacts[@]} -gt 0 ]] || die "no package artifacts found in $REPO_DIR"
  repo-add "$REPO_DIR/$REPO_NAME.db.tar.gz" "${artifacts[@]}"
}

create_local_dep_pacman_wrapper() {
  local wrapper_dir="$1"
  local wrapper="$wrapper_dir/pacman"

  mkdir -p "$wrapper_dir"
  cat >"$wrapper" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

real_pacman="${ENGINEOS_REAL_PACMAN:?}"
repo_dir="${ENGINEOS_REPO_DIR:?}"
is_deptest=false

local_artifact_exists() {
  local pkg="$1"
  find "$repo_dir" -maxdepth 1 -type f \
    \( -name "$pkg-*.pkg.tar.zst" -o -name "$pkg-*.pkg.tar.xz" -o -name "$pkg-*.pkg.tar.gz" \) \
    -print -quit 2>/dev/null | grep -q .
}

for arg in "$@"; do
  case "$arg" in
    -T|--deptest)
      is_deptest=true
      ;;
  esac
done

if [[ "$is_deptest" != true ]]; then
  exec "$real_pacman" "$@"
fi

filtered=()
has_target=false
for arg in "$@"; do
  if [[ "$arg" == engineos-* ]]; then
    dep_name="${arg%%[<>=]*}"
    if local_artifact_exists "$dep_name"; then
      continue
    fi
  fi
  filtered+=("$arg")
  [[ "$arg" == -* ]] || has_target=true
done

if [[ "$has_target" != true ]]; then
  exit 0
fi

exec "$real_pacman" "${filtered[@]}"
WRAPPER
  chmod +x "$wrapper"
  printf '%s\n' "$wrapper"
}

preflight_args=(repo)
if [[ -n "$ONLY_PACKAGE" ]]; then
  preflight_args+=(--package "$ONLY_PACKAGE")
fi
"$SCRIPT_DIR/preflight.sh" "${preflight_args[@]}"

if [[ "$DRY_RUN" == true ]]; then
  printf 'EngineOS repo dry-run\n'
  printf '  root: %s\n' "$ROOT"
  printf '  repo: %s\n' "$REPO_DIR"
  printf '  packages:\n'
  for pkg in "${selected_packages[@]}"; do
    printf '    - %s/packages/%s\n' "$ROOT" "$pkg"
  done
  printf '  makepkg: rebuild existing package artifacts with -f\n'
  printf '  repo-add: after each package, refresh %s/%s.db.tar.gz from latest package artifacts in %s\n' "$REPO_DIR" "$REPO_NAME" "$REPO_DIR"
  printf '  local deps: already-built engineos-* runtime dependencies are satisfied from %s\n' "$REPO_DIR"
  exit 0
fi

is_arch_linux || die "real package builds must run on Arch Linux"
have_cmd makepkg || die "makepkg is missing; install base-devel"
have_cmd repo-add || die "repo-add is missing; install pacman"
have_cmd pacman || die "pacman is missing"
have_cmd vercmp || die "vercmp is missing; install pacman"

mkdir -p "$REPO_DIR"
REAL_PACMAN="$(command -v pacman)"
PACMAN_WRAPPER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/engineos-pacman-wrapper.XXXXXX")"
PACMAN_WRAPPER="$(create_local_dep_pacman_wrapper "$PACMAN_WRAPPER_DIR")"
cleanup_pacman_wrapper() {
  rm -rf "$PACMAN_WRAPPER_DIR"
}
trap cleanup_pacman_wrapper EXIT

for pkg in "${selected_packages[@]}"; do
  pkg_dir="$ROOT/packages/$pkg"
  [[ -f "$pkg_dir/PKGBUILD" ]] || die "missing PKGBUILD: $pkg_dir"
  check_local_runtime_deps_ready "$pkg"
  (
    cd "$pkg_dir"
    ENGINEOS_ROOT="$ROOT" \
      ENGINEOS_REAL_PACMAN="$REAL_PACMAN" \
      ENGINEOS_REPO_DIR="$REPO_DIR" \
      PACMAN="$PACMAN_WRAPPER" \
      makepkg -f -s --needed --noconfirm
    cp -f ./*.pkg.tar.* "$REPO_DIR/"
  )
  repo_add_current_artifacts
done
