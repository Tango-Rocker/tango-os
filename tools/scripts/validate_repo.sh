#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
REPO_ARCH="${ENGINEOS_REPO_ARCH:-x86_64}"
REPO_DIR="${ENGINEOS_REPO_DIR:-$ROOT/repo/$REPO_ARCH}"
REPO_NAME="${ENGINEOS_REPO_NAME:-engineos}"
DRY_RUN=false
FAILURES=0
WARNINGS=0

usage() {
  cat <<'HELP'
Usage: validate_repo.sh [--dry-run]

Validate the local EngineOS pacman repository after `eos-build repo`.
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

repo_db_exists() {
  [[ -e "$REPO_DIR/$REPO_NAME.db" || -e "$REPO_DIR/$REPO_NAME.db.tar.gz" || -e "$REPO_DIR/$REPO_NAME.db.tar.zst" ]]
}

repo_db_file() {
  local candidate
  for candidate in "$REPO_DIR/$REPO_NAME.db" "$REPO_DIR/$REPO_NAME.db.tar.gz" "$REPO_DIR/$REPO_NAME.db.tar.zst"; do
    if [[ -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

package_artifact_exists() {
  local pkg="$1"
  local artifact
  local name
  local version

  if ! have_cmd pacman; then
    find "$REPO_DIR" -maxdepth 1 -type f \
      \( -name "$pkg-*.pkg.tar.zst" -o -name "$pkg-*.pkg.tar.xz" -o -name "$pkg-*.pkg.tar.gz" \) \
      -print -quit 2>/dev/null | grep -q .
    return
  fi

  while IFS= read -r artifact; do
    read -r name version < <(pacman -Qp "$artifact" 2>/dev/null || true)
    if [[ "$name" == "$pkg" && -n "${version:-}" ]]; then
      return 0
    fi
  done < <(find "$REPO_DIR" -maxdepth 1 -type f \
    \( -name "$pkg-*.pkg.tar.zst" -o -name "$pkg-*.pkg.tar.xz" -o -name "$pkg-*.pkg.tar.gz" \) \
    -print 2>/dev/null)

  return 1
}

latest_artifact_version() {
  local pkg="$1"
  local artifact
  local name
  local version
  local latest=""

  while IFS= read -r artifact; do
    read -r name version < <(pacman -Qp "$artifact" 2>/dev/null || true)
    [[ "$name" == "$pkg" && -n "${version:-}" ]] || continue
    if [[ -z "$latest" ]] || [[ "$(vercmp "$version" "$latest")" -gt 0 ]]; then
      latest="$version"
    fi
  done < <(find "$REPO_DIR" -maxdepth 1 -type f \
    \( -name "$pkg-*.pkg.tar.zst" -o -name "$pkg-*.pkg.tar.xz" -o -name "$pkg-*.pkg.tar.gz" \) \
    -print 2>/dev/null)

  [[ -n "$latest" ]] || return 1
  printf '%s\n' "$latest"
}

pkgbuild_expected_version() {
  local pkg="$1"
  local pkg_dir="$ROOT/packages/$pkg"

  (
    set +u
    cd "$pkg_dir"
    # shellcheck disable=SC1091
    source PKGBUILD
    printf '%s-%s\n' "$pkgver" "$pkgrel"
  )
}

repo_db_package_version() {
  local pkg="$1"
  local db="$2"

  bsdtar -xOf "$db" '*/desc' 2>/dev/null | awk -v target="$pkg" '
    $0 == "%NAME%" {
      getline name
      next
    }
    $0 == "%VERSION%" {
      getline version
      if (name == target) {
        print version
        exit
      }
    }
  '
}

profile_uses_engineos_repo() {
  local profile="$1"
  local pacman_conf="$ROOT/archiso/$profile/pacman.conf"

  if [[ ! -r "$pacman_conf" ]]; then
    fail "$profile pacman.conf missing"
    return
  fi

  if grep -Fx '[engineos]' "$pacman_conf" >/dev/null && grep -F 'Server = file:///srv/engineos/repo/$arch' "$pacman_conf" >/dev/null; then
    ok "$profile pacman.conf has engineos file repo"
  else
    fail "$profile pacman.conf does not point at the local engineos repo"
  fi
}

check_repo_dir_matches_profiles() {
  local expected="/srv/engineos/repo/$REPO_ARCH"

  if [[ "$REPO_DIR" == "$expected" ]]; then
    ok "repo directory matches archiso pacman.conf: $REPO_DIR"
  else
    fail "repo directory mismatch: archiso expects $expected but build uses $REPO_DIR"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown validate_repo option: $1"
      ;;
  esac
  shift
done

printf 'EngineOS repo validation\n'
printf '  root: %s\n' "$ROOT"
printf '  repo: %s\n' "$REPO_DIR"
printf '  name: %s\n' "$REPO_NAME"

if [[ "$DRY_RUN" == true ]]; then
  printf 'Expected repo database: %s/%s.db\n' "$REPO_DIR" "$REPO_NAME"
  printf 'Expected package artifacts:\n'
  while IFS= read -r pkg; do
    printf '  %s/%s-*.pkg.tar.*\n' "$REPO_DIR" "$pkg"
  done < <(engineos_packages)
  if [[ "$REPO_DIR" != "/srv/engineos/repo/$REPO_ARCH" ]]; then
    warn "dry-run repo directory differs from archiso pacman.conf expectation: /srv/engineos/repo/$REPO_ARCH"
  fi
  profile_uses_engineos_repo enginedev
  profile_uses_engineos_repo engineruntime
  printf 'Repo validation dry-run completed.\n'
  [[ "$FAILURES" -eq 0 ]]
  exit
fi

check_repo_dir_matches_profiles

if [[ -d "$REPO_DIR" ]]; then
  ok "repo directory exists"
else
  fail "repo directory missing: $REPO_DIR"
fi

if repo_db_exists; then
  ok "repo database exists: $REPO_NAME"
else
  fail "repo database missing: $REPO_NAME.db"
fi

while IFS= read -r pkg; do
  if package_artifact_exists "$pkg"; then
    ok "package artifact exists: $pkg"
  else
    fail "package artifact missing: $pkg"
  fi
done < <(engineos_packages)

if repo_db_exists && have_cmd pacman && have_cmd vercmp && have_cmd bsdtar; then
  db_file="$(repo_db_file)"
  while IFS= read -r pkg; do
    artifact_version="$(latest_artifact_version "$pkg" || true)"
    db_version="$(repo_db_package_version "$pkg" "$db_file" || true)"
    if [[ -z "$artifact_version" ]]; then
      continue
    fi
    expected_version="$(pkgbuild_expected_version "$pkg" || true)"
    if [[ -n "$expected_version" && "$artifact_version" == "$expected_version" ]]; then
      ok "package artifact matches PKGBUILD: $pkg $artifact_version"
    elif [[ -n "$expected_version" ]]; then
      fail "package artifact is stale versus PKGBUILD: $pkg artifact=$artifact_version expected=$expected_version"
    fi
    if [[ -z "$db_version" ]]; then
      fail "repo database missing package entry: $pkg"
    elif [[ "$db_version" == "$artifact_version" ]]; then
      ok "repo database uses latest artifact: $pkg $db_version"
    else
      fail "repo database has stale package entry: $pkg db=$db_version latest=$artifact_version"
    fi
  done < <(engineos_packages)
else
  warn "cannot compare repo database versions; pacman/vercmp/bsdtar unavailable"
fi

profile_uses_engineos_repo enginedev
profile_uses_engineos_repo engineruntime

if have_cmd pacman; then
  ok "pacman available for repo consumers"
else
  warn "pacman unavailable; cannot query local repo from this environment"
fi

printf 'Repo validation summary: %s failure(s), %s warning(s)\n' "$FAILURES" "$WARNINGS"
[[ "$FAILURES" -eq 0 ]]
