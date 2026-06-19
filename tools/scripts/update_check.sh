#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
INIT_MODE=false
DRY_RUN=false
YES=false
NO_FETCH=false
SKIP_POST_INSTALL=false
ONLY_COMPONENT=""
STAMP_INTERVAL_SECONDS="${ENGINEOS_UPDATE_CHECK_INTERVAL_SECONDS:-86400}"
STAMP_FILE="${ENGINEOS_UPDATE_CHECK_STAMP:-}"
TARGET_USER="${ENGINEOS_DEV_USER:-${USER:-dev}}"

usage() {
  cat <<'HELP'
Usage: update_check.sh [check] [options]

Check semver Git tags for installed EngineOS/Tang-OS components and prompt
before moving a clean checkout to a newer tag.

Options:
  --init                  Login/init mode; skip non-interactive sessions and
                          throttle checks with a per-user stamp file
  --component name        Check one component: tango-os or engine-os
  --yes                   Accept upgrades without prompting
  --dry-run               Print planned upgrades without changing checkouts
  --no-fetch              Do not fetch remote tags before comparing
  --skip-post-install     Do not rerun Tang-OS post-install payload after update
  -h, --help              Show this help

Environment:
  ENGINEOS_TANGO_OS_ROOT  Tang-OS checkout path (default: /srv/engineos)
  ENGINEOS_ENGINE_OS_ROOT Engine-OS checkout path (default: /srv/engine-os)
  ENGINEOS_UPDATE_CHECK_STAMP
  ENGINEOS_UPDATE_CHECK_INTERVAL_SECONDS
HELP
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN %s\n' "$*" >&2
}

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

default_stamp_file() {
  local cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
  printf '%s\n' "$cache_home/engineos/update-check.stamp"
}

stamp_is_fresh() {
  local stamp="$1"
  local now last

  [[ -f "$stamp" ]] || return 1
  now="$(date +%s)"
  last="$(cat "$stamp" 2>/dev/null || printf '0')"
  [[ "$last" =~ ^[0-9]+$ ]] || return 1
  (( now - last < STAMP_INTERVAL_SECONDS ))
}

write_stamp() {
  local stamp="$1"
  mkdir -p "$(dirname "$stamp")"
  date +%s >"$stamp"
}

semver_key() {
  local tag="$1"
  tag="${tag#refs/tags/}"
  tag="${tag#v}"
  [[ "$tag" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]
}

latest_semver_tag() {
  local repo="$1"

  git -C "$repo" tag --list |
    while IFS= read -r tag; do
      semver_key "$tag" && printf '%s\n' "$tag"
    done |
    sort -V |
    tail -n 1
}

current_tag_or_commit() {
  local repo="$1"
  local tag

  tag="$(git -C "$repo" describe --tags --exact-match 2>/dev/null || true)"
  if [[ -n "$tag" ]]; then
    printf '%s\n' "$tag"
    return
  fi

  tag="$(git -C "$repo" describe --tags --abbrev=0 2>/dev/null || true)"
  if [[ -n "$tag" ]]; then
    printf '%s+%s\n' "$tag" "$(git -C "$repo" rev-parse --short HEAD)"
    return
  fi

  printf 'untagged-%s\n' "$(git -C "$repo" rev-parse --short HEAD)"
}

current_semver_base() {
  local version="$1"
  version="${version%%+*}"
  if semver_key "$version"; then
    printf '%s\n' "$version"
  fi
}

semver_is_newer() {
  local current="$1"
  local latest="$2"
  local current_base
  local best

  current_base="$(current_semver_base "$current" || true)"
  [[ -n "$current_base" ]] || return 0
  [[ "$current_base" != "$latest" ]] || return 1

  best="$(printf '%s\n%s\n' "$current_base" "$latest" | sort -V | tail -n 1)"
  [[ "$best" == "$latest" ]]
}

repo_is_clean() {
  local repo="$1"
  [[ -z "$(git -C "$repo" status --porcelain)" ]]
}

fetch_tags() {
  local repo="$1"
  local remote="$2"

  "$NO_FETCH" && return
  git -C "$repo" fetch --tags --prune "$remote" ||
    warn "could not fetch tags from $remote for $repo; using local tags"
}

prompt_upgrade() {
  local component="$1"
  local current="$2"
  local latest="$3"
  local reply

  "$YES" && return 0
  is_interactive || return 1

  printf 'Upgrade %s from %s to %s? [y/N] ' "$component" "$current" "$latest"
  read -r reply
  case "$reply" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

checkout_tag() {
  local repo="$1"
  local tag="$2"

  if "$DRY_RUN"; then
    log "dry-run: git -C $repo checkout $tag"
    return
  fi
  git -C "$repo" checkout --quiet "$tag"
}

post_install_payload() {
  local tango_root="$1"

  if [[ -x "$tango_root/tools/post-install-payload/scripts/setup_dev_environment.sh" ]]; then
    printf '%s\n' "$tango_root/tools/post-install-payload"
    return
  fi
  if [[ -x /usr/share/engineos/post-install-payload/scripts/setup_dev_environment.sh ]]; then
    printf '%s\n' /usr/share/engineos/post-install-payload
  fi
}

run_post_install_payload() {
  local tango_root="$1"
  local payload script

  "$SKIP_POST_INSTALL" && return
  payload="$(post_install_payload "$tango_root" || true)"
  [[ -n "$payload" ]] || {
    warn "post-install payload not found; skipping post-install refresh"
    return
  }

  script="$payload/scripts/setup_dev_environment.sh"
  if "$DRY_RUN"; then
    log "dry-run: $script --payload $payload --user $TARGET_USER"
    return
  fi
  "$script" --payload "$payload" --user "$TARGET_USER"
}

check_component() {
  local component="$1"
  local repo="$2"
  local remote="$3"
  local latest current updated=false

  if [[ ! -d "$repo/.git" ]]; then
    log "$component: skipped; Git checkout not found at $repo"
    return 0
  fi

  fetch_tags "$repo" "$remote"
  latest="$(latest_semver_tag "$repo" || true)"
  if [[ -z "$latest" ]]; then
    log "$component: no semver tags found"
    return 0
  fi

  current="$(current_tag_or_commit "$repo")"
  if ! semver_is_newer "$current" "$latest"; then
    log "$component: current ($current); latest ($latest); no upgrade"
    return 0
  fi

  log "$component: newer semver tag available: $current -> $latest"
  if ! repo_is_clean "$repo"; then
    warn "$component checkout has local changes; skipping upgrade: $repo"
    return 0
  fi

  if prompt_upgrade "$component" "$current" "$latest"; then
    checkout_tag "$repo" "$latest"
    updated=true
  else
    log "$component: upgrade skipped by user"
  fi

  if [[ "$component" == "tango-os" && "$updated" == true ]]; then
    run_post_install_payload "$repo"
  fi
}

check_updates() {
  local tango_root="${ENGINEOS_TANGO_OS_ROOT:-/srv/engineos}"
  local engine_root="${ENGINEOS_ENGINE_OS_ROOT:-/srv/engine-os}"

  if [[ "$tango_root" == "/srv/engineos" && "$ROOT" != /usr && -d "$ROOT/.git" ]]; then
    tango_root="$ROOT"
  fi

  case "$ONLY_COMPONENT" in
    "")
      check_component "tango-os" "$tango_root" "origin"
      check_component "engine-os" "$engine_root" "origin"
      ;;
    tango-os)
      check_component "tango-os" "$tango_root" "origin"
      ;;
    engine-os)
      check_component "engine-os" "$engine_root" "origin"
      ;;
    *)
      die "unknown update component: $ONLY_COMPONENT"
      ;;
  esac
}

if [[ "${1:-}" == "check" ]]; then
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init)
      INIT_MODE=true
      shift
      ;;
    --component)
      ONLY_COMPONENT="${2:-}"
      [[ -n "$ONLY_COMPONENT" ]] || die "--component requires a value"
      shift 2
      ;;
    --yes)
      YES=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --no-fetch)
      NO_FETCH=true
      shift
      ;;
    --skip-post-install)
      SKIP_POST_INSTALL=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown update option: $1"
      ;;
  esac
done

if "$INIT_MODE"; then
  [[ "${ENGINEOS_UPDATE_CHECK_DISABLE:-0}" != "1" ]] || exit 0
  is_interactive || exit 0
  STAMP_FILE="${STAMP_FILE:-$(default_stamp_file)}"
  stamp_is_fresh "$STAMP_FILE" && exit 0
  check_updates
  write_stamp "$STAMP_FILE"
else
  check_updates
fi
