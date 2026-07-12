#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
DOMAIN="${1:-help}"
ACTION="${2:-help}"
shift 2 2>/dev/null || true
RUNTIME_DIR="${ENGINEOS_GAME_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp}/engineos}"
STATE_DIR="${ENGINEOS_GAME_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/engineos}"
LAUNCH_REQUEST="${ENGINEOS_QUAKE_LAUNCH_REQUEST:-$RUNTIME_DIR/quake-launch.json}"

usage() {
  cat <<'HELP'
Usage:
  eos game quake setup [--force]
  eos game quake create PROMPT [--wait] [--inline]
  eos game quake build PROMPT [--wait] [--inline]
  eos game quake edit [JOB_ID]
  eos game quake play [--map NAME] [--game MOD] [--smoke] [--foreground]
  eos game quake reload [--job JOB_ID|--bsp PATH --map NAME]
  eos game quake status [JOB_ID]
  eos game quake proof
  eos game quake stop
HELP
}

[[ "$DOMAIN" == quake ]] || { usage >&2; exit 2; }

level_agent() {
  if [[ -x "$ROOT/tools/level-agent/engineos-level-agent" ]]; then
    "$ROOT/tools/level-agent/engineos-level-agent" "$@"
  else
    engineos-level-agent "$@"
  fi
}

eos_command() {
  local name="$1"
  if [[ -x "$ROOT/tools/engineos/$name" ]]; then
    printf '%s\n' "$ROOT/tools/engineos/$name"
  else
    printf '%s\n' "$name"
  fi
}

resolve_id1() {
  if [[ -n "${ENGINEOS_QUAKE_ID1:-}" ]]; then
    printf '%s\n' "$ENGINEOS_QUAKE_ID1"
  else
    "$(eos_command eos-assets)" path quake
  fi
}

quake_runner() {
  local source_runner="$ROOT/engines/quakespasm/engineos/run.sh"
  if [[ -x "$source_runner" ]]; then
    printf '%s\n' "$source_runner"
  elif [[ -x /usr/share/engineos/quake/run.sh ]]; then
    printf '%s\n' /usr/share/engineos/quake/run.sh
  else
    die "Quake runner is missing"
  fi
}

play_quake() {
	local map="" game="id1" smoke=false window=false fullscreen=false
	local foreground=false id1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --map) shift; map="${1:-}" ;;
      --game) shift; game="${1:-}" ;;
			--smoke) smoke=true ;;
			--window) window=true ;;
			--fullscreen) fullscreen=true ;;
			--foreground) foreground=true ;;
      *) die "unknown quake play option: $1" ;;
    esac
    shift
  done
  [[ -z "$map" || "$map" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid Quake map name: $map"
  [[ "$game" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid Quake game name: $game"
  id1="$(resolve_id1)" || die "Quake assets are not ready; run eos-assets prepare/check quake"
	[[ "$window" != true || "$fullscreen" != true ]] ||
		die "quake play cannot combine --window and --fullscreen"
	if [[ "$foreground" == false ]]; then
		local app_args=(launch quake)
		[[ -z "$map" ]] || app_args+=(--map "$map")
		[[ "$game" == id1 ]] || app_args+=(--game "$game")
		[[ "$smoke" == false ]] || app_args+=(--smoke)
		[[ "$window" == false ]] || app_args+=(--window)
		[[ "$fullscreen" == false ]] || app_args+=(--fullscreen)
		exec "$(eos_command eos-app)" "${app_args[@]}"
	fi
	if [[ "$foreground" == true ]]; then
		local runner_args=(--game "$game")
		[[ -z "$map" ]] || runner_args+=(--map "$map")
		[[ "$smoke" == false ]] || runner_args+=(--smoke)
		[[ "$window" == false ]] || runner_args+=(--window)
		[[ "$fullscreen" == false ]] || runner_args+=(--fullscreen)
		export ENGINEOS_QUAKE_ID1="$id1"
		exec "$(quake_runner)" "${runner_args[@]}"
	fi
}

reload_quake() {
  local job="" bsp="" map="" game="id1" manifest id1 target tmp
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --job) shift; job="${1:-}" ;;
      --bsp) shift; bsp="${1:-}" ;;
      --map) shift; map="${1:-}" ;;
      --game) shift; game="${1:-}" ;;
      *) die "unknown quake reload option: $1" ;;
    esac
    shift
  done
  if [[ -n "$job" ]]; then
    manifest="${ENGINEOS_LEVEL_AGENT_STATE_DIR:-$STATE_DIR/level-agent}/jobs/$job/job.json"
    [[ -r "$manifest" ]] || die "unknown level job: $job"
    mapfile -t job_values < <(python - "$manifest" <<'PY'
import json, sys
job=json.load(open(sys.argv[1], encoding="utf-8"))
if job.get("state") not in {"accepted", "loaded"}: raise SystemExit(f"job is not accepted: {job.get('state')}")
print(job["bsp_path"]); print(job["map_name"])
PY
)
    bsp="${job_values[0]}"
    map="${job_values[1]}"
  fi
  [[ -n "$bsp" && -f "$bsp" ]] || die "reload requires an existing --bsp or accepted --job"
  [[ -n "$map" && "$map" =~ ^[A-Za-z0-9_.-]+$ ]] || die "reload requires a valid --map"
  id1="$(resolve_id1)" || die "Quake assets are not ready"
  mkdir -p "$id1/maps"
  target="$id1/maps/$map.bsp"
  tmp="$target.$$.tmp"
  install -m0644 "$bsp" "$tmp"
  mv -f "$tmp" "$target"
  play_quake --map "$map" --game "$game"
  printf 'Quake reload interrupted the previous game state and selected %s\n' "$map"
}

case "$ACTION" in
  setup) level_agent trenchbroom-setup "$@" ;;
  create|build)
    prompt="${1:-}"
    [[ -n "$prompt" ]] || die "$ACTION requires a level prompt"
    shift
		if command -v systemctl >/dev/null 2>&1; then
			systemctl --user start engineos-level-agent.service
		fi
    level_agent build "$prompt" "$@"
    ;;
  edit)
    job="${1:-}"
    [[ -n "$job" ]] || die "edit requires a job id"
    manifest="${ENGINEOS_LEVEL_AGENT_STATE_DIR:-$STATE_DIR/level-agent}/jobs/$job/job.json"
    map_path="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["map_path"])' "$manifest")"
    exec engineos-trenchbroom "$map_path"
    ;;
  play) play_quake "$@" ;;
  reload) reload_quake "$@" ;;
  status)
		"$(eos_command eos-app)" pane list --json
    level_agent status "${1:-}"
    ;;
  proof)
    "$(eos_command eos-assets)" check quake
		"$(eos_command eos-app)" manifest validate
    ;;
  stop) "$(eos_command eos-app)" pane signal TERM ;;
  help|--help|-h) usage ;;
  *) die "unknown quake action: $ACTION" ;;
esac
