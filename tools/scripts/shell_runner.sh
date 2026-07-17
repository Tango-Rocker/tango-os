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
TMUX_CMD="${ENGINEOS_TMUX_CMD:-tmux}"
USER_HOME="${ENGINEOS_USER_HOME:-${HOME:-}}"
PAYLOAD_DIR="${ENGINEOS_POST_INSTALL_PAYLOAD:-}"
if [[ -z "$PAYLOAD_DIR" ]]; then
  if engineos_is_source_root "$ROOT"; then
    PAYLOAD_DIR="$ROOT/tools/post-install-payload"
  else
    PAYLOAD_DIR="/usr/share/engineos/post-install-payload"
  fi
fi
if [[ -n "${ENGINEOS_TERMINAL_THEME_DIR:-}" ]]; then
  TERMINAL_THEME_DIR="$ENGINEOS_TERMINAL_THEME_DIR"
elif engineos_is_source_root "$ROOT"; then
  TERMINAL_THEME_DIR="$ROOT/shell/themes"
else
  TERMINAL_THEME_DIR="/usr/share/engineos-shell/themes"
fi
terminal_theme_state_dir() {
  local runtime_dir
  local live_state_dir

  if [[ -n "$CALLER_ENGINEOS_STATE_DIR" ]]; then
    printf '%s\n' "$STATE_DIR"
    return
  fi

  runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  live_state_dir="$runtime_dir/engineos"
  if [[ -r "$live_state_dir/shell-state.json" || -S "$live_state_dir/preview.sock" ]]; then
    printf '%s\n' "$live_state_dir"
    return
  fi

  printf '%s\n' "$STATE_DIR"
}

usage() {
  cat <<'HELP'
Usage: shell_runner.sh --headless
       shell_runner.sh --nested
       shell_runner.sh --tty
       shell_runner.sh restart-live [--dry-run] [--timeout SECONDS] [--allow-partial]
       shell_runner.sh refresh-user [--dry-run] [--force-config]
       shell_runner.sh theme list|current|apply NAME
       shell_runner.sh theme apply --file PATH

Run the native EngineOS mux compositor. Headless and nested can smoke locally;
TTY is the direct DRM graphical entry point.

restart-live restarts engineos-dev-shell.service and verifies that a new
engineos-shell PID appears. refresh-user installs and sources the managed tmux
configuration in the authoritative server. theme applies a terminal palette to
the running shell without restarting tmux or the compositor.
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
  local refresh_result="refreshed"
  local refresh_reason="none"
  local tmux_conf
  local tmux_force_config=false
  local zsh_conf
  local zsh_force_config=false

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

  zsh_conf="$USER_HOME/.zshrc"
  if [[ "$force_config" == true ]]; then
    zsh_force_config=true
  elif [[ -e "$zsh_conf" ]] &&
      grep -F '# EngineOS managed zsh defaults for the live dev instance.' \
        "$zsh_conf" >/dev/null 2>&1 &&
      ! cmp -s "$PAYLOAD_DIR/assets/zshrc" "$zsh_conf"; then
    zsh_force_config=true
    printf '  managed_update: %s\n' "$zsh_conf"
  fi
  if ! install_user_file "$PAYLOAD_DIR/assets/zshrc" "$zsh_conf" 0644 \
      "$dry_run" "$zsh_force_config"; then
    printf '  result:     failed reason=install-zsh-config-failed\n'
    return 1
  fi
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

run_terminal_theme() {
  local action="${1:-current}"
  local theme_state_dir
  local theme_preview_socket
  [[ $# -eq 0 ]] || shift

  theme_state_dir="$(terminal_theme_state_dir)"
  theme_preview_socket="${ENGINEOS_PREVIEW_SOCKET:-$theme_state_dir/preview.sock}"

  case "$action" in
    list)
      [[ -d "$TERMINAL_THEME_DIR" ]] ||
        die "terminal theme directory is unavailable: $TERMINAL_THEME_DIR"
      local theme_file
      for theme_file in "$TERMINAL_THEME_DIR"/*.json; do
        [[ -f "$theme_file" ]] || continue
        basename "$theme_file" .json
      done | sort
      ;;
    current)
      local state_file="$theme_state_dir/shell-state.json"
      [[ -r "$state_file" ]] ||
        die "shell state is unavailable: $state_file"
      jq -er \
        '.terminal_theme | select(type == "object") |
         "\(.name) generation=\(.generation) foreground=\(.foreground) background=\(.background)"' \
        "$state_file"
      ;;
    apply)
      local theme_file
      if [[ "${1:-}" == "--file" ]]; then
        shift
        theme_file="${1:-}"
        [[ -n "$theme_file" ]] || die "theme apply --file requires a path"
        shift
      else
        local theme_name="${1:-}"
        [[ "$theme_name" =~ ^[A-Za-z0-9_-]+$ ]] ||
          die "theme name must contain only letters, numbers, - or _"
        theme_file="$TERMINAL_THEME_DIR/$theme_name.json"
        shift || true
      fi
      [[ $# -eq 0 ]] || die "theme apply received unexpected arguments"
      [[ -r "$theme_file" ]] ||
        die "terminal theme is unavailable: $theme_file"
      python - "$theme_preview_socket" "$theme_file" <<'PY'
import json
import socket
import sys

socket_path, theme_path = sys.argv[1:]
try:
    with open(theme_path, encoding="utf-8") as handle:
        theme = json.load(handle)
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"terminal theme cannot be read: {exc}")

payload = json.dumps(
    {"version": 1, "op": "terminal-theme", "theme": theme},
    separators=(",", ":"),
).encode("utf-8") + b"\n"
try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5.0)
        client.connect(socket_path)
        client.sendall(payload)
        response = b""
        while b"\n" not in response:
            chunk = client.recv(4096)
            if not chunk:
                break
            response += chunk
except OSError as exc:
    raise SystemExit(f"shell theme IPC unavailable at {socket_path}: {exc}")

try:
    result = json.loads(response.split(b"\n", 1)[0].decode("utf-8"))
except (UnicodeDecodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"shell theme IPC returned invalid JSON: {exc}")
if result.get("status") != "ok":
    raise SystemExit(str(result.get("error") or "shell rejected terminal theme"))
print(
    f"terminal theme applied: {theme.get('name', 'unnamed')} "
    f"socket={socket_path}"
)
PY
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      die "unknown terminal theme action: $action"
      ;;
  esac
}

run_real_shell_if_available() {
  local mode="$1"
  local smoke_args=()
  if [[ "${ENGINEOS_SHELL_SMOKE:-false}" == "true" ]]; then
    smoke_args+=(--smoke)
  fi

  if command -v "$SHELL_BIN" >/dev/null 2>&1; then
    log_line "shell binary found: $SHELL_BIN mode=$mode"
    tee_shell_output
    case "$mode" in
      headless)
        WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS="${WLR_HEADLESS_OUTPUTS:-1}" exec "$SHELL_BIN" --headless "${smoke_args[@]}"
        ;;
      nested)
        exec "$SHELL_BIN" --nested "${smoke_args[@]}"
        ;;
      tty)
        exec "$SHELL_BIN" --tty "${smoke_args[@]}"
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
  theme)
    run_terminal_theme "$@"
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
    die "shell runner expected --headless, --nested, --tty, restart-live, refresh-user, or theme"
    ;;
esac
