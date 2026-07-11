#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
CALLER_ENGINEOS_LOG_DIR="${ENGINEOS_LOG_DIR-}"
CALLER_ENGINEOS_STATE_DIR="${ENGINEOS_STATE_DIR-}"
CALLER_ENGINEOS_PROFILE="${ENGINEOS_PROFILE-}"

if [[ -r /etc/engineos/profile.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/engineos/profile.conf
fi
if [[ -n "$CALLER_ENGINEOS_LOG_DIR" ]]; then
  ENGINEOS_LOG_DIR="$CALLER_ENGINEOS_LOG_DIR"
fi
if [[ -n "$CALLER_ENGINEOS_STATE_DIR" ]]; then
  ENGINEOS_STATE_DIR="$CALLER_ENGINEOS_STATE_DIR"
fi
if [[ -n "$CALLER_ENGINEOS_PROFILE" ]]; then
  ENGINEOS_PROFILE="$CALLER_ENGINEOS_PROFILE"
fi

if engineos_is_source_root "$ROOT"; then
  LOG_DIR="${ENGINEOS_LOG_DIR:-$(engineos_default_log_dir "$ROOT")}"
  STATE_DIR="${ENGINEOS_STATE_DIR:-$(engineos_default_state_dir "$ROOT")}"
else
  LOG_DIR="${ENGINEOS_LOG_DIR:-$(engineos_default_log_dir "$ROOT")}"
  STATE_DIR="${ENGINEOS_STATE_DIR:-$(engineos_default_state_dir "$ROOT")}"
fi

MODE="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi
if [[ -n "${ENGINEOS_SHELL_BIN:-}" ]]; then
  SHELL_BIN="$ENGINEOS_SHELL_BIN"
elif engineos_is_source_root "$ROOT" && [[ -x "$ROOT/build/shell/engineos-shell" ]]; then
  SHELL_BIN="$ROOT/build/shell/engineos-shell"
else
  SHELL_BIN="engineos-shell"
fi
LOG_FILE="$LOG_DIR/shell.log"
export ENGINEOS_STATE_DIR="$STATE_DIR"
DEV_SHELL_UNIT="${ENGINEOS_DEV_SHELL_UNIT:-engineos-dev-shell.service}"
DEV_SHELL_START="${ENGINEOS_DEV_SHELL_START:-engineos-dev-shell-start}"
PROC_DIR="${ENGINEOS_PROC_DIR:-/proc}"
KILL_CMD="${ENGINEOS_KILL_CMD:-kill}"
TMUX_CMD="${ENGINEOS_TMUX_CMD:-engine-mux}"
TMUX_HELPER_DIR="${ENGINEOS_TMUX_HELPER_DIR:-/usr/local/bin}"
USER_HOME="${ENGINEOS_USER_HOME:-${HOME:-}}"
PAYLOAD_DIR="${ENGINEOS_POST_INSTALL_PAYLOAD:-}"
if [[ -z "$PAYLOAD_DIR" ]]; then
  if engineos_is_source_root "$ROOT"; then
    PAYLOAD_DIR="$ROOT/tools/post-install-payload"
  else
    PAYLOAD_DIR="/usr/share/engineos/post-install-payload"
  fi
fi

eos_app_cmd_string() {
  if [[ -x "$ROOT/tools/engineos/eos-app" ]]; then
    printf '%q' "$ROOT/tools/engineos/eos-app"
  else
    printf 'eos-app'
  fi
}

EOS_APP_CMD_STRING="$(eos_app_cmd_string)"
APPS_MANIFEST="$(engineos_apps_manifest "$ROOT")"

manifest_command_or_default() {
  local app="$1"
  local fallback="$2"
  local command=""

  command="$(engineos_app_manifest_value "$APPS_MANIFEST" "$app" command || true)"
  if [[ -z "$command" ]]; then
    printf '%s\n' "$fallback"
    return
  fi
  if [[ "$command" == engineos\ app* ]]; then
    printf '%s%s\n' "$EOS_APP_CMD_STRING" "${command#engineos app}"
  else
    printf '%s\n' "$command"
  fi
}

DEFAULT_TERMINAL="${ENGINEOS_TERMINAL_SLOT_CMD:-$(manifest_command_or_default terminal "$EOS_APP_CMD_STRING launch terminal")}"
DEFAULT_TERMINAL_SECONDARY="${ENGINEOS_TERMINAL_SECONDARY_SLOT_CMD:-$(manifest_command_or_default terminal-secondary "$EOS_APP_CMD_STRING launch terminal-secondary")}"
DEFAULT_CUBE="${ENGINEOS_CUBE_CMD:-$(manifest_command_or_default cube "$EOS_APP_CMD_STRING launch cube")}"
DEFAULT_ENGINE="${ENGINEOS_ENGINE_CMD:-$(manifest_command_or_default quake "$EOS_APP_CMD_STRING launch quake")}"

usage() {
  cat <<'HELP'
Usage: shell_runner.sh --headless
       shell_runner.sh --nested
       shell_runner.sh --tty
       shell_runner.sh restart-live [--dry-run] [--timeout SECONDS] [--allow-partial]
       shell_runner.sh refresh-user [--dry-run] [--force-config]

Run the EngineOS shell path. Headless and nested can smoke locally. TTY is
the Runtime graphical entry point and bootstraps the launchpad slots by
default when the real shell binary is installed.

restart-live restarts engineos-dev-shell.service and verifies that a new
engineos-shell PID appears. refresh-user removes retired bridge helpers and
sources the managed configuration in the native mux server.
HELP
}

log_line() {
  mkdir -p "$LOG_DIR"
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE"
}

tee_shell_output() {
  mkdir -p "$LOG_DIR"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

have_executable() {
  local cmd="$1"
  if [[ "$cmd" == */* ]]; then
    [[ -x "$cmd" ]]
  else
    command -v "$cmd" >/dev/null 2>&1
  fi
}

same_user_pids_by_name() {
  local name="$1"
  local argv=()
  local pid
  local proc_path

  [[ -d "$PROC_DIR" ]] || return 0
  for proc_path in "$PROC_DIR"/[0-9]*; do
    [[ -d "$proc_path" ]] || continue
    pid="${proc_path##*/}"
    [[ "$pid" != "$$" ]] || continue
    proc_uid_matches "$pid" || continue
    [[ -r "$PROC_DIR/$pid/cmdline" ]] || continue
    argv=()
    mapfile -d '' -t argv <"$PROC_DIR/$pid/cmdline" || true
    [[ "${#argv[@]}" -gt 0 ]] || continue
    [[ "${argv[0]##*/}" == "$name" ]] || continue
    printf '%s\n' "$pid"
  done
}

pid_discovery_available() {
  [[ -d "$PROC_DIR" && -r "$PROC_DIR" ]]
}

contains_pid() {
  local needle="$1"
  shift || true
  local pid
  for pid in "$@"; do
    [[ "$pid" == "$needle" ]] && return 0
  done
  return 1
}

restart_command() {
  if [[ -n "${ENGINEOS_RESTART_DEV_SHELL_CMD:-}" ]]; then
    printf '%s\n' "$ENGINEOS_RESTART_DEV_SHELL_CMD"
    return
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    printf 'systemctl restart %q\n' "$DEV_SHELL_UNIT"
  else
    printf 'sudo -n systemctl restart %q\n' "$DEV_SHELL_UNIT"
  fi
}

run_restart_command() {
  if [[ -n "${ENGINEOS_RESTART_DEV_SHELL_CMD:-}" ]]; then
    bash -c "$ENGINEOS_RESTART_DEV_SHELL_CMD"
    return
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    systemctl restart "$DEV_SHELL_UNIT"
  else
    sudo -n systemctl restart "$DEV_SHELL_UNIT"
  fi
}

run_restart_live() {
  local dry_run=false
  local allow_partial=false
  local timeout=10
  local old_pids=()
  local new_pids=()
  local pid
  local elapsed
  local restart_cmd
  local restart_rc

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --allow-partial)
        allow_partial=true
        ;;
      --timeout)
        shift
        timeout="${1:-}"
        [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -gt 0 ]] || die "--timeout requires a positive number"
        ;;
      help|--help|-h)
        usage
        return 0
        ;;
      *)
        die "unknown restart-live option: $1"
        ;;
    esac
    shift
  done

  mapfile -t old_pids < <(same_user_pids_by_name engineos-shell)
  restart_cmd="$(restart_command)"

  printf 'EngineOS live shell restart\n'
  printf '  unit:       %s\n' "$DEV_SHELL_UNIT"
  printf '  entrypoint: %s\n' "$DEV_SHELL_START"
  printf '  root:       %s\n' "$ROOT"
  printf '  state:      %s\n' "$STATE_DIR"
  printf '  shell_log:  %s\n' "$LOG_FILE"
  printf '  start_log:  %s\n' "$LOG_DIR/dev-shell-start.log"
  printf '  dry_run:    %s\n' "$dry_run"
  printf '  allow_partial: %s\n' "$allow_partial"
  printf '  old_pids:   %s\n' "${old_pids[*]:-none}"

  if [[ "$dry_run" == true ]]; then
    printf '  would_run:  %s\n' "$restart_cmd"
    printf '  would_verify: new same-user engineos-shell pid within %ss\n' "$timeout"
    printf '  result:     preview\n'
    return 0
  fi

  printf '  run:        %s\n' "$restart_cmd"
  set +e
  run_restart_command
  restart_rc="$?"
  set -e
  if [[ "$restart_rc" -ne 0 ]]; then
    printf '  result:     failed reason=restart-command-failed rc=%s\n' "$restart_rc"
    return "$restart_rc"
  fi

  if ! pid_discovery_available; then
    printf '  result:     partial reason=pid-discovery-unavailable\n'
    [[ "$allow_partial" == true ]] && return 0
    return 1
  fi

  for ((elapsed = 0; elapsed < timeout * 5; elapsed++)); do
    new_pids=()
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      if [[ "${#old_pids[@]}" -eq 0 ]] || ! contains_pid "$pid" "${old_pids[@]}"; then
        new_pids+=("$pid")
      fi
    done < <(same_user_pids_by_name engineos-shell)
    [[ "${#new_pids[@]}" -gt 0 ]] && break
    sleep 0.2
  done

  if [[ "${#new_pids[@]}" -eq 0 ]]; then
    printf '  result:     failed reason=no-new-shell-pid timeout=%ss\n' "$timeout"
    return 1
  fi

  printf '  new_pids:   %s\n' "${new_pids[*]}"
  printf '  result:     restarted\n'
}

install_user_file() {
  local src="$1"
  local dest="$2"
  local mode="$3"
  local dry_run="$4"
  local force="$5"

  if [[ ! -r "$src" ]]; then
    printf '  error:      payload file missing: %s\n' "$src"
    return 1
  fi
  if [[ -e "$dest" && "$force" != true ]]; then
    printf '  keep:       %s\n' "$dest"
    return 0
  fi
  if [[ "$dry_run" == true ]]; then
    printf '  would_install: %s -> %s\n' "$src" "$dest"
    return 0
  fi
  if ! install -Dm"$mode" "$src" "$dest"; then
    printf '  error:      install failed: %s\n' "$dest"
    return 1
  fi
  printf '  installed:  %s\n' "$dest"
}

install_helper_file() {
  local src="$1"
  local dest="$2"
  local dry_run="$3"

  if [[ ! -r "$src" ]]; then
    printf '  error:      payload helper missing: %s\n' "$src"
    return 1
  fi
  if [[ "$dry_run" == true ]]; then
    printf '  would_install: %s -> %s\n' "$src" "$dest"
    return 0
  fi
  if [[ -w "$(dirname "$dest")" || ! -e "$(dirname "$dest")" ]]; then
    if ! install -Dm0755 "$src" "$dest"; then
      printf '  error:      install failed: %s\n' "$dest"
      return 1
    fi
  elif [[ "$(id -u)" -eq 0 ]]; then
    if ! install -Dm0755 "$src" "$dest"; then
      printf '  error:      install failed: %s\n' "$dest"
      return 1
    fi
  elif have_executable sudo; then
    if ! sudo -n install -Dm0755 "$src" "$dest"; then
      printf '  error:      sudo install failed: %s\n' "$dest"
      return 1
    fi
  else
    printf '  error:      cannot install helper without writable target or sudo: %s\n' "$dest"
    return 1
  fi
  printf '  installed:  %s\n' "$dest"
}

proc_uid_matches() {
  local pid="$1"
  local status_file="$PROC_DIR/$pid/status"
  local uid
  [[ -r "$status_file" ]] || return 1
  uid="$(awk '/^Uid:/ { print $2; exit }' "$status_file" 2>/dev/null || true)"
  [[ -n "$uid" ]] || return 1
  [[ "$uid" == "$(id -u)" ]]
}

run_refresh_user() {
  local dry_run=false
  local force_config=false
  local helper
  local refresh_result="refreshed"
  local refresh_reason="none"
  local tmux_conf
  local tmux_force_config=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --force-config)
        force_config=true
        ;;
      help|--help|-h)
        usage
        return 0
        ;;
      *)
        die "unknown refresh-user option: $1"
        ;;
    esac
    shift
  done

  printf 'EngineOS user runtime refresh\n'
  printf '  root:       %s\n' "$ROOT"
  printf '  payload:    %s\n' "$PAYLOAD_DIR"
  printf '  home:       %s\n' "$USER_HOME"
  printf '  helper_dir: %s\n' "$TMUX_HELPER_DIR"
  printf '  dry_run:    %s\n' "$dry_run"

  if [[ -z "$USER_HOME" ]]; then
    printf '  result:     failed reason=user-home-unresolved\n'
    return 1
  fi
  if [[ ! -d "$PAYLOAD_DIR/assets" || ! -d "$PAYLOAD_DIR/scripts" ]]; then
    printf '  result:     failed reason=post-install-payload-missing\n'
    return 1
  fi

  tmux_conf="$USER_HOME/.tmux.conf"
  if [[ "$force_config" == true ]]; then
    tmux_force_config=true
  elif [[ -e "$tmux_conf" ]] &&
      grep -F '@engineos-plugins' "$tmux_conf" >/dev/null 2>&1 &&
      ! cmp -s "$PAYLOAD_DIR/assets/tmux.conf" "$tmux_conf"; then
    tmux_force_config=true
    printf '  managed_update: %s\n' "$tmux_conf"
  fi
  if ! install_user_file "$PAYLOAD_DIR/assets/tmux.conf" "$tmux_conf" 0644 "$dry_run" "$tmux_force_config"; then
    printf '  result:     failed reason=install-tmux-config-failed\n'
    return 1
  fi
  for helper in engineos-tmux-attach-primary engineos-tmux-pane-bridge \
      engineos-tmux-pane-sync engineos-tmux-window-move \
      engineos-tmux-window-sync engineos-tmux-window-focus \
      engineos-tmux-window-proxy; do
		if [[ "$dry_run" == true ]]; then
			printf '  would_remove: %s\n' "$TMUX_HELPER_DIR/$helper"
		else
			rm -f "$TMUX_HELPER_DIR/$helper" 2>/dev/null ||
				sudo -n rm -f "$TMUX_HELPER_DIR/$helper"
		fi
  done

  if ! have_executable "$TMUX_CMD"; then
    printf '  mux:        unavailable; native config source skipped\n'
    printf '  result:     partial reason=tmux-unavailable\n'
    return 0
  fi

  if [[ "$dry_run" == true ]]; then
    printf '  would_run:  %s source-file %q\n' "$TMUX_CMD" "$tmux_conf"
    refresh_result="preview"
  elif "$TMUX_CMD" source-file "$tmux_conf" >/dev/null 2>&1; then
    printf '  tmux:       sourced %s\n' "$tmux_conf"
  else
    printf '  tmux:       source skipped reason=no-server-or-source-failed\n'
    refresh_result="partial"
    refresh_reason="tmux-source-failed"
  fi

  if [[ "$refresh_result" == "partial" ]]; then
    printf '  result:     partial reason=%s\n' "$refresh_reason"
  else
    printf '  result:     %s\n' "$refresh_result"
  fi
}

run_real_shell_if_available() {
  local mode="$1"
  local smoke_args=()
  local startup_args=()
  local launch_args=()
  local bootstrap_args=()
  if [[ "${ENGINEOS_SHELL_SMOKE:-false}" == "true" ]]; then
    smoke_args+=(--smoke)
  fi
  launch_args+=(--terminal "$DEFAULT_TERMINAL")
  launch_args+=(--terminal-secondary "$DEFAULT_TERMINAL_SECONDARY")
  launch_args+=(--cube "$DEFAULT_CUBE")
  launch_args+=(--engine "$DEFAULT_ENGINE")
  if [[ -n "${ENGINEOS_SHELL_STARTUP:-}" ]]; then
    startup_args+=(--startup "$ENGINEOS_SHELL_STARTUP")
  elif [[ -z "${ENGINEOS_SHELL_BOOTSTRAP:-}" && "$mode" == "nested" && "${ENGINEOS_SHELL_AUTO_STARTUP:-true}" == "true" ]]; then
    startup_args+=(--startup "$DEFAULT_TERMINAL")
  fi
  if [[ -n "${ENGINEOS_SHELL_BOOTSTRAP:-}" ]]; then
    bootstrap_args+=(--bootstrap "$ENGINEOS_SHELL_BOOTSTRAP")
  elif [[ "$mode" == "tty" ]]; then
    bootstrap_args+=(--bootstrap launchpad)
  fi

  if command -v "$SHELL_BIN" >/dev/null 2>&1; then
    log_line "shell binary found: $SHELL_BIN mode=$mode"
    tee_shell_output
    case "$mode" in
      headless)
        WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS="${WLR_HEADLESS_OUTPUTS:-1}" exec "$SHELL_BIN" --headless "${smoke_args[@]}" "${startup_args[@]}" "${launch_args[@]}" "${bootstrap_args[@]}"
        ;;
      nested)
        exec "$SHELL_BIN" --nested "${smoke_args[@]}" "${startup_args[@]}" "${launch_args[@]}" "${bootstrap_args[@]}"
        ;;
      tty)
        exec "$SHELL_BIN" --tty "${smoke_args[@]}" "${startup_args[@]}" "${launch_args[@]}" "${bootstrap_args[@]}"
        ;;
    esac
  fi
  return 1
}

case "$MODE" in
  restart-live)
    run_restart_live "$@"
    ;;
  refresh-user)
    run_refresh_user "$@"
    ;;
  --headless)
    if run_real_shell_if_available headless; then
      exit 0
    fi
    log_line "engineos-shell headless backend=headless result=missing-shell shell=$SHELL_BIN"
    printf 'engineos-shell binary is unavailable for --headless: %s\n' "$SHELL_BIN" >&2
    exit 1
    ;;
  --nested)
    if run_real_shell_if_available nested; then
      exit 0
    fi
    if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
      log_line "engineos-shell nested backend=nested display=missing result=missing-shell shell=$SHELL_BIN"
    else
      log_line "engineos-shell nested backend=nested display=available result=missing-shell shell=$SHELL_BIN"
    fi
    printf 'engineos-shell binary is unavailable for --nested: %s\n' "$SHELL_BIN" >&2
    exit 1
    ;;
  --tty)
    if run_real_shell_if_available tty; then
      exit 0
    fi
    log_line "engineos-shell tty backend=drm result=missing-shell shell=$SHELL_BIN"
    printf 'engineos-shell binary is unavailable for --tty: %s\n' "$SHELL_BIN" >&2
    exit 1
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "shell runner expected --headless, --nested, --tty, restart-live, or refresh-user"
    ;;
esac
