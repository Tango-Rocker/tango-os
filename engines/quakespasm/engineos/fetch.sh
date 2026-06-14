#!/usr/bin/env bash
set -euo pipefail

ROOT="${ENGINEOS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)}"
UPSTREAM="${QUAKESPASM_UPSTREAM_DIR:-$ROOT/engines/quakespasm/upstream}"
REPO_URL="${QUAKESPASM_REPO_URL:-https://github.com/sezero/quakespasm.git}"
GIT_DEPTH="${QUAKESPASM_GIT_DEPTH:-1}"
DRY_RUN=false
STATUS=false

usage() {
  cat <<'HELP'
Usage: fetch.sh [--dry-run] [--status]

Fetch the QuakeSpasm upstream source into engines/quakespasm/upstream.
Default upstream mirror: https://github.com/sezero/quakespasm.git

Environment:
  QUAKESPASM_REPO_URL      upstream Git URL
  QUAKESPASM_UPSTREAM_DIR  checkout path
  QUAKESPASM_GIT_DEPTH     clone/fetch depth, default 1
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --status)
      STATUS=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'quakespasm fetch: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

print_status() {
  printf 'QuakeSpasm fetch status\n'
  printf '  repo:     %s\n' "$REPO_URL"
  printf '  upstream: %s\n' "$UPSTREAM"

  if [[ -d "$UPSTREAM/.git" ]]; then
    printf '  state:    git-checkout\n'
    printf '  remote:   %s\n' "$(git -C "$UPSTREAM" remote get-url origin 2>/dev/null || printf '(unknown)')"
    printf '  branch:   %s\n' "$(git -C "$UPSTREAM" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '(unknown)')"
    printf '  commit:   %s\n' "$(git -C "$UPSTREAM" rev-parse --short HEAD 2>/dev/null || printf '(unknown)')"
  elif [[ -d "$UPSTREAM" ]] && ! find "$UPSTREAM" -mindepth 1 -print -quit | grep -q .; then
    printf '  state:    empty-directory\n'
  elif [[ -e "$UPSTREAM" ]]; then
    printf '  state:    invalid-existing-path\n'
    return 1
  else
    printf '  state:    missing\n'
  fi
}

if [[ "$DRY_RUN" == true ]]; then
  printf 'QuakeSpasm fetch dry-run\n'
  printf '  repo:     %s\n' "$REPO_URL"
  printf '  upstream: %s\n' "$UPSTREAM"
  printf '  command:  git clone --depth %s %s %s\n' "$GIT_DEPTH" "$REPO_URL" "$UPSTREAM"
  printf '  status:   fetch.sh --status\n'
  exit 0
fi

if [[ "$STATUS" == true ]]; then
  print_status
  exit
fi

command -v git >/dev/null 2>&1 || {
  printf 'git is required to fetch QuakeSpasm\n' >&2
  exit 1
}

if [[ -d "$UPSTREAM/.git" ]]; then
  git -C "$UPSTREAM" fetch --depth "$GIT_DEPTH" origin
  git -C "$UPSTREAM" pull --ff-only
elif [[ -d "$UPSTREAM" ]] && ! find "$UPSTREAM" -mindepth 1 -print -quit | grep -q .; then
  git clone --depth "$GIT_DEPTH" "$REPO_URL" "$UPSTREAM"
elif [[ -e "$UPSTREAM" ]]; then
  printf 'QuakeSpasm upstream path exists but is not a git checkout: %s\n' "$UPSTREAM" >&2
  exit 1
else
  mkdir -p "$(dirname "$UPSTREAM")"
  git clone --depth "$GIT_DEPTH" "$REPO_URL" "$UPSTREAM"
fi

printf 'QuakeSpasm upstream ready: %s\n' "$UPSTREAM"
print_status
