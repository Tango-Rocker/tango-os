#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ACTION="${1:-help}"
TARGET="${2:-}"

usage() {
  cat <<'HELP'
Usage: assets.sh check quake
       assets.sh explain quake
       assets.sh path quake
       assets.sh prepare quake

Check or explain user-provided game assets.
HELP
}

load_quake_config() {
  local config
  for config in /etc/engineos/quake.conf "${HOME:-}/.config/engineos/quake.conf"; do
    [[ -r "$config" ]] || continue
    # shellcheck disable=SC1090
    source "$config"
  done
}

quake_asset_candidates() {
  local env_id1="${ENGINEOS_QUAKE_ID1:-}"
  load_quake_config
  if [[ -n "$env_id1" ]]; then
    printf '%s\n' "$env_id1"
  elif [[ -n "${ENGINEOS_QUAKE_ID1:-}" ]]; then
    printf '%s\n' "$ENGINEOS_QUAKE_ID1"
  fi
  if [[ -n "${ENGINEOS_QUAKE_ID1_DEFAULT:-}" ]]; then
    printf '%s\n' "$ENGINEOS_QUAKE_ID1_DEFAULT"
  fi
  if [[ -n "${HOME:-}" ]]; then
    if [[ -n "${XDG_DATA_HOME:-}" ]]; then
      printf '%s\n' "$XDG_DATA_HOME/engineos/quake/id1"
    else
      printf '%s\n' "$HOME/.local/share/engineos/quake/id1"
    fi
    printf '%s\n' "$HOME/.local/share/Quake/id1"
  fi
  printf '%s\n' "/var/lib/engineos/assets/quake/id1"
  printf '%s\n' "/usr/local/share/games/quake/id1"
  printf '%s\n' "/usr/share/games/quake/id1"
}

quake_id1_path() {
  local dir

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    if [[ -f "$dir/pak0.pak" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done < <(quake_asset_candidates)

  return 1
}

check_quake() {
  local dir

  if dir="$(quake_id1_path)"; then
    printf 'Quake assets found: %s\n' "$dir"
    return 0
  fi

  printf 'Quake assets missing: id1/pak0.pak was not found.\n' >&2
  printf 'Copy your legitimate Quake pak files to: %s\n' "$(preferred_quake_id1_path)" >&2
  printf 'Run: eos-assets explain quake\n' >&2
  return 1
}

path_quake() {
  quake_id1_path
}

preferred_quake_id1_path() {
  local env_id1="${ENGINEOS_QUAKE_ID1:-}"
  load_quake_config
  if [[ -n "$env_id1" ]]; then
    printf '%s\n' "$env_id1"
  elif [[ -n "${ENGINEOS_QUAKE_ID1:-}" ]]; then
    printf '%s\n' "$ENGINEOS_QUAKE_ID1"
  elif [[ -n "${HOME:-}" ]]; then
    if [[ -n "${XDG_DATA_HOME:-}" ]]; then
      printf '%s\n' "$XDG_DATA_HOME/engineos/quake/id1"
    else
      printf '%s\n' "$HOME/.local/share/engineos/quake/id1"
    fi
  else
    printf '%s\n' "/var/lib/engineos/assets/quake/id1"
  fi
}

prepare_quake() {
  local dir
  dir="$(preferred_quake_id1_path)"
  mkdir -p "$dir"
  cat <<HELP
Quake asset directory prepared: $dir

Copy your legitimate Quake files here:
  $dir/pak0.pak
  $dir/pak1.pak  optional, registered Quake

Then run:
  eos-assets check quake
HELP
}

explain_quake() {
  cat <<'HELP'
Quake asset policy:
  EngineOS does not ship commercial Quake data.
  Provide your own id1/pak0.pak from a legitimate Quake installation.

Accepted locations:
HELP
  quake_asset_candidates | sed 's/^/  - /'
  cat <<'HELP'

Environment override:
  ENGINEOS_QUAKE_ID1=/path/to/id1 eos-runtime quake

Config files:
  /etc/engineos/quake.conf
  ~/.config/engineos/quake.conf

Supported config variable:
  ENGINEOS_QUAKE_ID1=/path/to/id1

Expected file:
  <id1 path>/pak0.pak

Prepare the default user directory:
  eos-assets prepare quake
HELP
}

case "$ACTION" in
  check)
    [[ "$TARGET" == "quake" ]] || die "assets check currently supports only: quake"
    check_quake
    ;;
  explain)
    [[ "$TARGET" == "quake" ]] || die "assets explain currently supports only: quake"
    explain_quake
    ;;
  path)
    [[ "$TARGET" == "quake" ]] || die "assets path currently supports only: quake"
    path_quake
    ;;
  prepare)
    [[ "$TARGET" == "quake" ]] || die "assets prepare currently supports only: quake"
    prepare_quake
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown assets action: $ACTION"
    ;;
esac
