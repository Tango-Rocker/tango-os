#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
FAILURES=0
WARNINGS=0
MOCK=false

usage() {
  cat <<'HELP'
Usage: validate_shell.sh [--mock]

Validate the EngineOS shell scaffold, runner wiring, and local smoke behavior.
This does not prove wlroots runtime behavior; real headless/nested/TTY checks
belong on the Arch builder VM or target AMD hardware after engineos-shell builds.
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

require_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    ok "file: $path"
  else
    fail "missing file: $path"
  fi
}

require_executable() {
  local path="$1"
  if [[ -x "$path" ]]; then
    ok "executable: $path"
  else
    fail "missing executable: $path"
  fi
}

check_contains() {
  local path="$1"
  local pattern="$2"
  local label="$3"

  if grep -F "$pattern" "$path" >/dev/null 2>&1; then
    ok "$label"
  else
    fail "$label missing"
  fi
}

validate_runner_smoke() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-validate-shell-$$"
  local log_dir="$tmp_dir/logs"
  local fake_shell="$tmp_dir/bin/engineos-shell"
  local args_file="$tmp_dir/args.txt"
  local env_file="$tmp_dir/env.txt"

  cleanup_validate_shell() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_validate_shell RETURN

  mkdir -p "$tmp_dir/bin" "$log_dir"

  if ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_SHELL_BIN="$tmp_dir/missing-shell" "$SCRIPT_DIR/shell_runner.sh" --headless >/dev/null; then
    ok "headless fallback smoke"
  else
    fail "headless fallback smoke failed"
  fi

  if grep -F 'engineos-shell headless smoke backend=headless result=stub-ok' "$log_dir/shell.log" >/dev/null 2>&1; then
    ok "headless fallback logged"
  else
    fail "headless fallback log marker missing"
  fi

  if ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_SHELL_BIN="$tmp_dir/missing-shell" WAYLAND_DISPLAY="engineos-test" "$SCRIPT_DIR/shell_runner.sh" --nested >/dev/null; then
    ok "nested fallback smoke"
  else
    fail "nested fallback smoke failed"
  fi

  if grep -F 'engineos-shell nested smoke backend=nested display=available result=stub-ok' "$log_dir/shell.log" >/dev/null 2>&1; then
    ok "nested fallback logged display availability"
  else
    fail "nested fallback display log marker missing"
  fi

  if ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_SHELL_BIN="$tmp_dir/missing-shell" "$SCRIPT_DIR/shell_runner.sh" --tty >/dev/null 2>&1; then
    fail "tty fallback should fail without ENGINEOS_ALLOW_TTY_STUB"
  else
    ok "tty fallback fails closed without hardware shell"
  fi

  if ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_SHELL_BIN="$tmp_dir/missing-shell" ENGINEOS_ALLOW_TTY_STUB=true "$SCRIPT_DIR/shell_runner.sh" --tty >/dev/null; then
    ok "tty explicit stub smoke"
  else
    fail "tty explicit stub smoke failed"
  fi

  cat >"$fake_shell" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ENGINEOS_FAKE_SHELL_ARGS"
{
  printf 'WLR_BACKENDS=%s\n' "${WLR_BACKENDS:-unset}"
  printf 'WLR_HEADLESS_OUTPUTS=%s\n' "${WLR_HEADLESS_OUTPUTS:-unset}"
} >"$ENGINEOS_FAKE_SHELL_ENV"
FAKE
  chmod +x "$fake_shell"

  ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_SHELL_BIN="$fake_shell" \
    ENGINEOS_FAKE_SHELL_ARGS="$args_file" \
    ENGINEOS_FAKE_SHELL_ENV="$env_file" \
    ENGINEOS_SHELL_SMOKE=true \
    "$SCRIPT_DIR/shell_runner.sh" --headless >/dev/null

  grep -Fx -- "--headless" "$args_file" >/dev/null || fail "real shell pass-through missing --headless"
  grep -Fx -- "--smoke" "$args_file" >/dev/null || fail "real shell pass-through missing --smoke"
  grep -Fx -- "WLR_BACKENDS=headless" "$env_file" >/dev/null || fail "headless pass-through missing WLR_BACKENDS"
  grep -Fx -- "WLR_HEADLESS_OUTPUTS=1" "$env_file" >/dev/null || fail "headless pass-through missing WLR_HEADLESS_OUTPUTS"

  ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_SHELL_BIN="$fake_shell" \
    ENGINEOS_FAKE_SHELL_ARGS="$args_file" \
    ENGINEOS_FAKE_SHELL_ENV="$env_file" \
    "$SCRIPT_DIR/shell_runner.sh" --nested >/dev/null

  grep -Fx -- "--nested" "$args_file" >/dev/null || fail "real shell pass-through missing --nested"
  grep -Fx -- "--startup" "$args_file" >/dev/null || fail "nested pass-through missing --startup"
  grep -F -- "app launch terminal" "$args_file" >/dev/null || fail "nested pass-through missing default terminal app command"
  grep -Fx -- "--terminal" "$args_file" >/dev/null || fail "nested pass-through missing --terminal"
  grep -Fx -- "--cube" "$args_file" >/dev/null || fail "nested pass-through missing --cube"
  grep -F -- "app launch cube" "$args_file" >/dev/null || fail "nested pass-through missing default cube app command"
  grep -Fx -- "--engine" "$args_file" >/dev/null || fail "nested pass-through missing --engine"
  grep -F -- "app launch quake" "$args_file" >/dev/null || fail "nested pass-through missing default app command"
  if grep -Fx -- "--bootstrap" "$args_file" >/dev/null; then
    fail "nested pass-through should not bootstrap by default"
  fi

  ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_SHELL_BIN="$fake_shell" \
    ENGINEOS_FAKE_SHELL_ARGS="$args_file" \
    ENGINEOS_FAKE_SHELL_ENV="$env_file" \
    "$SCRIPT_DIR/shell_runner.sh" --tty >/dev/null

  grep -Fx -- "--tty" "$args_file" >/dev/null || fail "real shell pass-through missing --tty"
  grep -Fx -- "--bootstrap" "$args_file" >/dev/null || fail "tty pass-through missing --bootstrap"
  grep -Fx -- "launchpad" "$args_file" >/dev/null || fail "tty pass-through missing bootstrap launchpad"

  if [[ "$FAILURES" -eq 0 ]]; then
    ok "real shell command pass-through"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mock)
      MOCK=true
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown validate_shell option: $1"
      ;;
  esac
  shift
done

printf 'EngineOS shell validation\n'
printf '  root: %s\n' "$ROOT"

if [[ "$MOCK" == true ]]; then
  ok "mock shell source"
  ok "mock shell runner"
  printf 'Shell validation summary: 0 failure(s), 0 warning(s)\n'
  exit 0
fi

require_file "$ROOT/shell/meson.build"
require_file "$ROOT/shell/src/engineos-shell.c"
require_executable "$ROOT/tools/scripts/shell_runner.sh"
require_executable "$ROOT/tools/scripts/terminal_launcher.sh"
require_executable "$ROOT/tools/scripts/build_shell.sh"
require_file "$ROOT/packages/engineos-shell/PKGBUILD"

if bash -n "$ROOT/tools/scripts/shell_runner.sh" "$ROOT/tools/scripts/terminal_launcher.sh"; then
  ok "shell runner syntax"
else
  fail "shell runner syntax failed"
fi

if "$ROOT/tools/scripts/build_shell.sh" --dry-run >/dev/null; then
  ok "shell build dry-run"
else
  fail "shell build dry-run failed"
fi

check_contains "$ROOT/shell/src/engineos-shell.c" '{"headless", no_argument' "shell binary supports --headless"
check_contains "$ROOT/shell/src/engineos-shell.c" '{"nested", no_argument' "shell binary supports --nested"
check_contains "$ROOT/shell/src/engineos-shell.c" '{"tty", no_argument' "shell binary supports --tty"
check_contains "$ROOT/shell/src/engineos-shell.c" '{"bootstrap", required_argument' "shell binary supports --bootstrap"
check_contains "$ROOT/shell/src/engineos-shell.c" '{"cube", required_argument' "shell binary supports --cube"
check_contains "$ROOT/shell/src/engineos-shell.c" 'WLR_BACKENDS", "drm,libinput' "shell tty selects drm/libinput backend"
check_contains "$ROOT/shell/src/engineos-shell.c" 'keybinding ctrl+alt+backspace: emergency release' "shell emergency release binding"
check_contains "$ROOT/shell/src/engineos-shell.c" 'keybinding alt+return: launch terminal' "shell terminal launch binding"
check_contains "$ROOT/shell/src/engineos-shell.c" 'keybinding alt+2: cube slot' "shell cube slot binding"
check_contains "$ROOT/shell/src/engineos-shell.c" 'keybinding alt+tab: cycle launchpad slot' "shell launchpad cycle binding"
check_contains "$ROOT/shell/src/engineos-shell.c" 'keybinding alt+g: launch engine' "shell engine launch binding"
check_contains "$ROOT/shell/src/engineos-shell.c" 'spawn_command(&server, "bootstrap-terminal",' "shell bootstrap terminal launch"
check_contains "$ROOT/shell/src/engineos-shell.c" 'spawn_command(&server, "bootstrap-cube",' "shell bootstrap cube launch"
check_contains "$ROOT/shell/src/engineos-shell.c" 'spawn_command(&server, "bootstrap-engine",' "shell bootstrap engine launch"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wl_event_loop_add_signal(event_loop, SIGCHLD, reap_child_processes, &server)' "shell reaps launched app children"
check_contains "$ROOT/shell/src/engineos-shell.c" 'launch action exit label=%s role=%s' "shell logs launch process exits"
check_contains "$ROOT/shell/src/engineos-shell.c" 'reason=process-exited-before-map' "shell logs launchpad slot failure before map"
check_contains "$ROOT/shell/src/engineos-shell.c" 'shell-state.json' "shell writes structured state artifact"
check_contains "$ROOT/shell/src/engineos-shell.c" 'input mode request ignored requested=game' "shell keeps active slot when engine is unavailable"
check_contains "$ROOT/shell/src/engineos-shell.c" 'capture-toggle-ignored' "shell refuses capture without mapped engine slot"
check_contains "$ROOT/shell/src/engineos-shell.c" 'ENGINEOS_BOOTSTRAP_LAUNCHPAD' "shell launchpad bootstrap mode"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_renderer_autocreate' "shell wlroots 0.19 renderer autocreate"
check_contains "$ROOT/shell/src/engineos-shell.c" 'setenv("XDG_SESSION_TYPE", "wayland", 1)' "shell launches clients as Wayland session"
check_contains "$ROOT/shell/src/engineos-shell.c" 'unsetenv("DISPLAY")' "shell prevents X11 display fallback for launched clients"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_allocator_autocreate' "shell wlroots 0.19 allocator autocreate"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_output_init_render' "shell wlroots 0.19 output render init"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_output_commit_state' "shell wlroots 0.19 output state commit"
check_contains "$ROOT/shell/src/engineos-shell.c" 'output selected connector=%s mode=%dx%d refresh_mhz=%d backend=%s' "shell selected output mode logging"
check_contains "$ROOT/shell/src/engineos-shell.c" 'output selected connector=%s mode=custom-or-unknown refresh_mhz=0 backend=%s' "shell unknown output mode logging"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_compositor_create(server->display, 5' "shell wlroots 0.19 compositor version"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_xdg_shell_create(server->display, 3' "shell wlroots 0.19 xdg-shell version"
check_contains "$ROOT/shell/src/engineos-shell.c" 'events.new_toplevel' "shell wlroots 0.19 toplevel event"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_scene_xdg_surface_create' "shell xdg scene helper"
check_contains "$ROOT/shell/src/engineos-shell.c" 'xdg_surface->initial_commit' "shell initial xdg configure"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_scene_output_send_frame_done' "shell scene frame done"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_keyboard_from_input_device' "shell wlroots 0.19 keyboard accessor"
check_contains "$ROOT/shell/src/engineos-shell.c" 'struct engineos_shell_pointer' "shell pointer state"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_pointer_from_input_device' "shell wlroots 0.19 pointer accessor"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_cursor_create' "shell cursor creation"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_cursor_attach_output_layout' "shell cursor output layout"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_xcursor_manager_create' "shell xcursor manager creation"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_xcursor_manager_load' "shell xcursor manager loading"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_cursor_set_xcursor' "shell default cursor image"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_cursor_set_surface' "shell client cursor image"
check_contains "$ROOT/shell/src/engineos-shell.c" 'events.request_set_cursor' "shell cursor request listener"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_scene_node_at' "shell cursor scene hit-test"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_seat_pointer_notify_button' "shell pointer button forwarding"
check_contains "$ROOT/shell/src/engineos-shell.c" 'pointer click-focus role=%s' "shell pointer click focus"
check_contains "$ROOT/shell/src/engineos-shell.c" 'pointer %s mode=%s capture=%s focus=%s x=%.1f y=%.1f' "shell pointer event logging"
check_contains "$ROOT/shell/src/engineos-shell.c" 'pointer configured name=%s' "shell pointer device configuration"
check_contains "$ROOT/shell/src/engineos-shell.c" 'server->cursor->events.button' "shell cursor button listener"
check_contains "$ROOT/shell/src/engineos-shell.c" 'server->cursor->events.axis' "shell cursor axis listener"

validate_runner_smoke

if have_cmd pkg-config; then
  if pkg-config --exists wlroots-0.19 wayland-server xkbcommon 2>/dev/null; then
    ok "wlroots pkg-config modules available"
  else
    warn "wlroots pkg-config modules unavailable here; real compile belongs on Arch builder VM"
  fi
else
  warn "pkg-config unavailable; cannot check wlroots modules"
fi

printf 'Shell validation summary: %s failure(s), %s warning(s)\n' "$FAILURES" "$WARNINGS"
[[ "$FAILURES" -eq 0 ]]
