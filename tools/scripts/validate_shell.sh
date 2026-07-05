#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
FAILURES=0
WARNINGS=0

usage() {
  cat <<'HELP'
Usage: validate_shell.sh

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

  if ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_SHELL_BIN="$tmp_dir/missing-shell" "$SCRIPT_DIR/shell_runner.sh" --headless >/dev/null 2>&1; then
    fail "headless missing shell should fail"
  else
    ok "headless missing shell fails closed"
  fi

  if grep -F 'engineos-shell headless backend=headless result=missing-shell' "$log_dir/shell.log" >/dev/null 2>&1; then
    ok "headless missing shell logged"
  else
    fail "headless missing shell log marker missing"
  fi

  if ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_SHELL_BIN="$tmp_dir/missing-shell" WAYLAND_DISPLAY="engineos-test" "$SCRIPT_DIR/shell_runner.sh" --nested >/dev/null 2>&1; then
    fail "nested missing shell should fail"
  else
    ok "nested missing shell fails closed"
  fi

  if grep -F 'engineos-shell nested backend=nested display=available result=missing-shell' "$log_dir/shell.log" >/dev/null 2>&1; then
    ok "nested missing shell logged display availability"
  else
    fail "nested missing shell display log marker missing"
  fi

  if ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_SHELL_BIN="$tmp_dir/missing-shell" "$SCRIPT_DIR/shell_runner.sh" --tty >/dev/null 2>&1; then
    fail "tty missing shell should fail"
  else
    ok "tty missing shell fails closed"
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

  env -u WLR_BACKENDS -u WLR_HEADLESS_OUTPUTS \
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

  WLR_BACKENDS=drm,libinput \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_SHELL_BIN="$fake_shell" \
    ENGINEOS_FAKE_SHELL_ARGS="$args_file" \
    ENGINEOS_FAKE_SHELL_ENV="$env_file" \
    ENGINEOS_SHELL_SMOKE=true \
    "$SCRIPT_DIR/shell_runner.sh" --headless >/dev/null

  grep -Fx -- "--headless" "$args_file" >/dev/null || fail "inherited-backend headless pass-through missing --headless"
  grep -Fx -- "WLR_BACKENDS=headless" "$env_file" >/dev/null || fail "headless pass-through should force WLR_BACKENDS"

	  env -u ENGINEOS_SHELL_BOOTSTRAP \
	    -u ENGINEOS_SHELL_STARTUP \
	    -u ENGINEOS_SHELL_AUTO_STARTUP \
	    ENGINEOS_LOG_DIR="$log_dir" \
	    ENGINEOS_SHELL_BIN="$fake_shell" \
	    ENGINEOS_FAKE_SHELL_ARGS="$args_file" \
	    ENGINEOS_FAKE_SHELL_ENV="$env_file" \
	    "$SCRIPT_DIR/shell_runner.sh" --nested >/dev/null

  grep -Fx -- "--nested" "$args_file" >/dev/null || fail "real shell pass-through missing --nested"
  grep -Fx -- "--startup" "$args_file" >/dev/null || fail "nested pass-through missing --startup"
  grep -F -- "app launch terminal" "$args_file" >/dev/null || fail "nested pass-through missing default terminal app command"
  grep -Fx -- "--terminal" "$args_file" >/dev/null || fail "nested pass-through missing --terminal"
  grep -Fx -- "--terminal-secondary" "$args_file" >/dev/null || fail "nested pass-through missing --terminal-secondary"
  grep -F -- "app launch terminal-secondary" "$args_file" >/dev/null || fail "nested pass-through missing default secondary terminal app command"
  grep -Fx -- "--cube" "$args_file" >/dev/null || fail "nested pass-through missing --cube"
  grep -F -- "app launch cube" "$args_file" >/dev/null || fail "nested pass-through missing default cube app command"
  grep -Fx -- "--engine" "$args_file" >/dev/null || fail "nested pass-through missing --engine"
  grep -F -- "app launch quake" "$args_file" >/dev/null || fail "nested pass-through missing default app command"
  if grep -Fx -- "--bootstrap" "$args_file" >/dev/null; then
    fail "nested pass-through should not bootstrap by default"
  fi

	  env -u ENGINEOS_SHELL_BOOTSTRAP \
	    -u ENGINEOS_SHELL_STARTUP \
	    -u ENGINEOS_SHELL_AUTO_STARTUP \
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
check_contains "$ROOT/shell/src/engineos-shell.c" '{"terminal-secondary", required_argument' "shell binary supports --terminal-secondary"
check_contains "$ROOT/shell/src/engineos-shell.c" 'WLR_BACKENDS", "drm,libinput' "shell tty selects drm/libinput backend"
check_contains "$ROOT/shell/src/engineos-shell.c" 'keybinding ctrl+alt+backspace: emergency release' "shell emergency release binding"
check_contains "$ROOT/shell/src/engineos-shell.c" 'keybinding alt+return: launch terminal' "shell terminal launch binding"
check_contains "$ROOT/shell/src/engineos-shell.c" 'keybinding alt+4: secondary terminal slot' "shell secondary terminal launch binding"
check_contains "$ROOT/shell/src/engineos-shell.c" 'keybinding alt+2: cube slot' "shell cube slot binding"
check_contains "$ROOT/shell/src/engineos-shell.c" 'keybinding alt+tab: cycle managed windows' "shell all-window cycle binding"
check_contains "$ROOT/shell/src/engineos-shell.c" 'keybinding alt+g: launch engine' "shell engine launch binding"
check_contains "$ROOT/shell/src/engineos-shell.c" 'spawn_command(&server, "bootstrap-terminal",' "shell bootstrap terminal launch"
check_contains "$ROOT/shell/src/engineos-shell.c" 'spawn_command(&server, "bootstrap-terminal-secondary",' "shell bootstrap secondary terminal launch"
check_contains "$ROOT/shell/src/engineos-shell.c" 'spawn_command(&server, "bootstrap-cube",' "shell bootstrap cube launch"
check_contains "$ROOT/shell/src/engineos-shell.c" 'spawn_command(&server, "bootstrap-engine",' "shell bootstrap engine launch"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wl_event_loop_add_signal(event_loop, SIGCHLD, reap_child_processes, &server)' "shell reaps launched app children"
check_contains "$ROOT/shell/src/engineos-shell.c" 'launch action exit label=%s role=%s' "shell logs launch process exits"
check_contains "$ROOT/shell/src/engineos-shell.c" 'reason=process-exited-before-map' "shell logs launchpad slot failure before map"
check_contains "$ROOT/shell/src/engineos-shell.c" 'shell-state.json' "shell writes structured state artifact"
check_contains "$ROOT/shell/src/engineos-shell.c" 'launch-bounds/%s.env' "shell reads per-role launch bounds"
check_contains "$ROOT/shell/src/engineos-shell.c" 'layout = "tmux-pane"' "shell supports tmux pane engine layout"
check_contains "$ROOT/shell/src/engineos-shell.c" 'is_persistent_panel_geometry' "shell treats tmux pane cube/engine views as persistent panels"
check_contains "$ROOT/shell/src/engineos-shell.c" 'pane-layout-mapped-inactive' "shell maps pane layout requests without stealing active slot"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wl_event_loop_add_signal(event_loop, SIGHUP, relayout_from_signal, &server)' "shell relayouts pane bounds on SIGHUP"
check_contains "$ROOT/shell/src/engineos-shell.c" 'events.request_fullscreen' "shell listens for xdg fullscreen requests"
check_contains "$ROOT/shell/src/engineos-shell.c" 'events.request_maximize' "shell listens for xdg maximize requests"
check_contains "$ROOT/shell/src/engineos-shell.c" 'events.request_minimize' "shell listens for xdg minimize requests"
check_contains "$ROOT/shell/src/engineos-shell.c" 'events.request_move' "shell listens for xdg move requests"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_xdg_toplevel_set_fullscreen' "shell applies engine fullscreen state"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_xdg_toplevel_set_maximized' "shell applies xdg maximize state"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_xdg_toplevel_set_wm_capabilities' "shell advertises window manager capabilities"
check_contains "$ROOT/shell/src/engineos-shell.c" 'xdg_toplevel_supports_wm_capabilities' "shell guards xdg wm capabilities by protocol version"
check_contains "$ROOT/shell/src/engineos-shell.c" 'xdg_toplevel_supports_suspended' "shell guards xdg suspended state by protocol version"
check_contains "$ROOT/shell/src/engineos-shell.c" 'input mode request ignored requested=game' "shell keeps active slot when engine is unavailable"
check_contains "$ROOT/shell/src/engineos-shell.c" 'capture-toggle-ignored' "shell refuses capture without mapped engine slot"
check_contains "$ROOT/shell/src/engineos-shell.c" 'cursor image=hidden' "shell hides cursor for game capture"
check_contains "$ROOT/shell/src/engineos-shell.c" 'cursor confined role=%s' "shell confines cursor to game view"
check_contains "$ROOT/shell/src/engineos-shell.c" 'cursor image request ignored reason=game-capture' "shell ignores client cursor images during game capture"
check_contains "$ROOT/shell/src/engineos-shell.c" 'relative pointer requested seat=%s' "shell logs client relative pointer requests"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_relative_pointer_manager_v1_send_relative_motion' "shell forwards relative pointer motion during game capture"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_pointer_constraint_v1_send_activated' "shell activates client pointer constraints during game capture"
check_contains "$ROOT/shell/src/engineos-shell.c" 'pointer constraint deactivated type=%s' "shell releases pointer constraints on capture exit"
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
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_data_device_manager_create' "shell creates Wayland data device manager"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_data_control_manager_v1_create' "shell creates Wayland data control manager"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_primary_selection_v1_device_manager_create' "shell creates primary selection manager"
check_contains "$ROOT/shell/src/engineos-shell.c" 'events.request_set_selection' "shell listens for clipboard selection requests"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_seat_set_selection(server->seat' "shell accepts clipboard selections"
check_contains "$ROOT/shell/src/engineos-shell.c" 'events.request_set_primary_selection' "shell listens for primary selection requests"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_seat_set_primary_selection(server->seat' "shell accepts primary selections"
check_contains "$ROOT/shell/src/engineos-shell.c" 'events.request_start_drag' "shell listens for Wayland drag start requests"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_seat_validate_pointer_grab_serial' "shell validates pointer drag serials"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_seat_start_pointer_drag' "shell starts pointer drag grabs"
check_contains "$ROOT/shell/src/engineos-shell.c" 'events.start_drag' "shell tracks active Wayland drags"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_scene_drag_icon_create' "shell renders Wayland drag icons"
check_contains "$ROOT/shell/src/engineos-shell.c" 'drag request accepted type=pointer' "shell logs accepted pointer drags"
check_contains "$ROOT/shell/src/engineos-shell.c" 'XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION' "shell xdg-shell version supports configure bounds"
check_contains "$ROOT/shell/src/engineos-shell.c" 'xdg_toplevel_supports_configure_bounds' "shell guards xdg configure bounds"
check_contains "$ROOT/shell/src/engineos-shell.c" 'events.new_toplevel' "shell wlroots 0.19 toplevel event"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_scene_xdg_surface_create' "shell xdg scene helper"
check_contains "$ROOT/shell/src/engineos-shell.c" 'events.new_popup' "shell listens for xdg popup events"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_scene_xdg_surface_create(parent_tree' "shell parents xdg popups into the scene graph"
check_contains "$ROOT/shell/src/engineos-shell.c" 'wlr_xdg_surface_schedule_configure(popup->xdg_popup->base)' "shell configures xdg popups"
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
    fail "wlroots pkg-config modules unavailable; shell validation requires compositor build prerequisites"
  fi
else
  fail "pkg-config unavailable; cannot check wlroots modules"
fi

printf 'Shell validation summary: %s failure(s), %s warning(s)\n' "$FAILURES" "$WARNINGS"
[[ "$FAILURES" -eq 0 ]]
