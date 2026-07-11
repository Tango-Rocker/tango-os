#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_SCRIPT_DIR="$(cd "$MODULE_DIR/../../scripts" && pwd -P)"
if [[ -d "$SOURCE_SCRIPT_DIR" && "${ENGINEOS_SCRIPT_DIR:-}" == /usr/lib/engineos/scripts* ]]; then
  SCRIPT_DIR="$SOURCE_SCRIPT_DIR"
elif [[ -n "${ENGINEOS_SCRIPT_DIR:-}" ]]; then
  SCRIPT_DIR="$ENGINEOS_SCRIPT_DIR"
else
  SCRIPT_DIR="$SOURCE_SCRIPT_DIR"
fi
BUILDER_DIR="$(cd "$MODULE_DIR/../builder" && pwd -P)"
BARE_METAL_DIR="$(cd "$MODULE_DIR/../bare-metal" && pwd -P)"
OS_DEV_DIR="$(cd "$MODULE_DIR/../os-dev" && pwd -P)"
PROOF_DIR="$(cd "$MODULE_DIR/../proof" && pwd -P)"
VM_DIR="$(cd "$MODULE_DIR/../vm" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
SCOPE="${1:-smoke}"
shift || true

usage() {
  cat <<'HELP'
Usage: test_runner.sh [smoke|all]
       test_runner.sh agent
       test_runner.sh agent-hygiene
       test_runner.sh observability
	   test_runner.sh agent-route
	   test_runner.sh dev-workflow
       test_runner.sh compositor --headless
       test_runner.sh shell-actions
	   test_runner.sh mux
	   test_runner.sh game-workflow
       test_runner.sh image-preview
       test_runner.sh app
       test_runner.sh level-agent
       test_runner.sh assets
       test_runner.sh reliability
       test_runner.sh logs
       test_runner.sh artifacts
       test_runner.sh release
       test_runner.sh terminal
       test_runner.sh vm
       test_runner.sh usb
       test_runner.sh secure-boot
       test_runner.sh update-check
       test_runner.sh installation-guide
       test_runner.sh install
       test_runner.sh restore-point
       test_runner.sh proof
       test_runner.sh installed-preflight
       test_runner.sh ci
       test_runner.sh source-test
       test_runner.sh builder-handoff
       test_runner.sh builder-doctor
       test_runner.sh post-first-deploy
       test_runner.sh builder
       test_runner.sh bootstrap
       test_runner.sh repo
       test_runner.sh boot
       test_runner.sh engine
       test_runner.sh shell
       test_runner.sh input
       test_runner.sh outputs --single|--dual-static
       test_runner.sh render --smoke
HELP
}

run_smoke() {
  exec "$MODULE_DIR/smoke_test.sh"
}

run_all_step() {
  printf '\n==> eos-test'
  printf ' %s' "$@"
  printf '\n'
  "$MODULE_DIR/test_runner.sh" "$@"
}

run_all() {
  printf 'EngineOS full local test suite\n'
  run_all_step smoke
  run_all_step agent
  run_all_step agent-hygiene
  run_all_step observability
	run_all_step agent-route
	run_all_step dev-workflow
  run_all_step compositor --headless
  run_all_step shell-actions
	run_all_step mux
	run_all_step game-workflow
  run_all_step image-preview
  run_all_step app
  run_all_step level-agent
  run_all_step assets
  run_all_step reliability
  run_all_step logs
  run_all_step artifacts
  run_all_step release
  run_all_step terminal
  run_all_step vm
  run_all_step usb
  run_all_step secure-boot
  run_all_step update-check
  run_all_step installation-guide
  run_all_step install
  run_all_step proof
  run_all_step installed-preflight
  run_all_step ci
  run_all_step source-test
  run_all_step builder-handoff
  run_all_step builder-doctor
  run_all_step post-first-deploy
  run_all_step builder
  run_all_step bootstrap
  run_all_step repo
  run_all_step boot
  run_all_step engine
  run_all_step shell
  run_all_step input
  run_all_step outputs --single
  run_all_step outputs --dual-static
  run_all_step render --smoke
  printf '\nengineos full local test suite passed\n'
}

post_install_payload_dir() {
  if [[ -d "$ROOT/tools/post-install-payload" ]]; then
    printf '%s\n' "$ROOT/tools/post-install-payload"
    return
  fi
  printf '%s\n' "$ROOT/share/engineos/post-install-payload"
}

run_compositor() {
  local mode="${1:---headless}"
  case "$mode" in
    --headless)
      ENGINEOS_SHELL_SMOKE=true exec "$SCRIPT_DIR/shell_runner.sh" --headless
      ;;
    --nested)
      ENGINEOS_SHELL_SMOKE=true exec "$SCRIPT_DIR/shell_runner.sh" --nested
      ;;
    *)
      die "compositor test expects --headless or --nested"
      ;;
  esac
}

run_mux() {
	local build_dir="$ROOT/build/mux"
	local shell_build_dir="$ROOT/build/shell"
	local fixture="${TMPDIR:-/tmp}/engineos-mux-test-$$"
	local mux_bin="${ENGINEOS_MUX_BIN:-}"
	local shell_bin="${ENGINEOS_SHELL_BIN:-$shell_build_dir/engineos-shell}"
	local shell_renderer="${ENGINEOS_MUX_TEST_RENDERER:-pixman}"
	local mux_commit="0623d1e968423ad0c192e0d8debf1258671063d5"
	local first_revision second_revision focus_revision pane_count pane_id
	local grid_revision damage_revision
	local history_rows history_start
	local key_proof=""
	local mouse_proof=""
	local drag_buffer_size="" target_window="" border_pane_id=""
	local border_width="" resized_width=""
	local restore_proof="" shell_pane_id=""
	local view_proof_session="" view_proof_session_id="" view_proof_pane=""
	local shell_pid="" overlay_pid="" prompt_pid="" shell_client_name=""
	local text_client_pid="" sshd_pid="" ssh_port=""
	local initial_native_revision updated_native_revision stable_revision=""
	local stable_count=0
	local pane_scope="" pane_app_pid="" pane_state="" split_pane_id=""
	local split_scope=""
	local pane_shell_pid="" pane_foreground_pid=""
	local wayland_display="" unscoped_pid="" scoped_client_pid=""
	local game_wrapper_command=""
	local preview_png="" preview_large_png=""
	local text_client_driver=""
	local primary_surface_id="" secondary_surface_id=""
	local multi_grid_pid="" first_split_pane="" second_split_pane=""
	local user_runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
	local user_bus="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$user_runtime/bus}"
	local TMUX="" TMUX_PANE=""
	export TMUX TMUX_PANE

	if [[ -z "$mux_bin" ]]; then
		mux_bin="$ROOT/artifacts/build/engineos-mux/engineos-mux/src/tmux-$mux_commit/tmux"
	fi
	if [[ ! -x "$mux_bin" ]]; then
		mux_bin="$(command -v engine-mux || true)"
	fi
	[[ -x "$mux_bin" ]] ||
		die "in-server mux test binary unavailable; build engineos-mux first"
	"$mux_bin" -V | grep -Fx 'tmux 3.6b' >/dev/null ||
		die "mux contract requires the pinned tmux 3.6b baseline"
	rm -rf "$fixture"
	mkdir -p "$fixture/bin"
	chmod 0700 "$fixture"
	preview_png="$fixture/lease-preview.png"
	preview_large_png="$fixture/lease-preview-large.png"
	python - "$preview_png" <<'PY'
import base64
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_bytes(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADAQMAAACOOjyFAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURSJmzP///8VU6LMAAAABYktHRAH/Ai3eAAAAB3RJTUUH6gcCFi0VNn7nGQAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAyNi0wNy0wMlQyMjo0NToyMSswMDowMIBjV7MAAAAldEVYdGRhdGU6bW9kaWZ5ADIwMjYtMDctMDJUMjI6NDU6MjErMDA6MDDxPu8PAAAAKHRFWHRkYXRlOnRpbWVzdGFtcAAyMDI2LTA3LTAyVDIyOjQ1OjIxKzAwOjAwpivO0AAAAAtJREFUCNdjYAABAAAGAAFm9MlsAAAAAElFTkSuQmCC"
))
PY
	python - "$preview_large_png" <<'PY'
import binascii
import pathlib
import struct
import sys
import zlib

width = height = 256
rows = []
for y in range(height):
    row = bytearray([0])
    for x in range(width):
        value = (x * 73 + y * 151) & 0xFF
        row.extend((value, value ^ 0x5A, (value * 37) & 0xFF, 0xFF))
    rows.append(row)

def chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(
        ">I", binascii.crc32(kind + payload) & 0xFFFFFFFF
    )

raw = b"".join(rows)
png = b"\x89PNG\r\n\x1a\n" + chunk(
    b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
) + chunk(b"IDAT", zlib.compress(raw, level=0)) + chunk(b"IEND", b"")
pathlib.Path(sys.argv[1]).write_bytes(png)
if len(png) <= 65536:
    raise SystemExit("large image fixture did not exceed one mux chunk")
PY
	cc -std=c11 -Wall -Wextra -Werror -O2 \
		$(pkg-config --cflags libsystemd) \
		"$ROOT/packages/engineos-mux/engine-pane-host.c" \
		-o "$fixture/bin/engine-pane-host" $(pkg-config --libs libsystemd)
	local wayland_protocols_dir
	wayland_protocols_dir="$(pkg-config wayland-protocols --variable=pkgdatadir)"
	wayland-scanner client-header \
		"$wayland_protocols_dir/stable/xdg-shell/xdg-shell.xml" \
		"$fixture/xdg-shell-client-protocol.h"
	wayland-scanner private-code \
		"$wayland_protocols_dir/stable/xdg-shell/xdg-shell.xml" \
		"$fixture/xdg-shell-protocol.c"
	cc -std=c11 -Wall -Wextra -Werror -O2 -I"$fixture" \
		"$ROOT/tests/wayland-presentation-client.c" \
		"$fixture/xdg-shell-protocol.c" \
		$(pkg-config --cflags --libs wayland-client) \
		-o "$fixture/bin/engineos-wayland-presentation-client"
	local PATH="$fixture/bin:$PATH"
	export PATH DBUS_SESSION_BUS_ADDRESS="$user_bus"
	export ENGINEOS_USER_RUNTIME_DIR="$user_runtime"
	text_client_driver="$ROOT/tests/tmux-text-client.py"
	if [[ ! -f "$text_client_driver" ]]; then
		text_client_driver="$MODULE_DIR/tmux-text-client.py"
	fi
	[[ -f "$text_client_driver" ]] ||
		die "tmux text-client integration driver is not installed"
	cleanup_mux_test() {
		[[ -z "${sshd_pid:-}" ]] || kill "$sshd_pid" >/dev/null 2>&1 || true
		[[ -z "${text_client_pid:-}" ]] || kill "$text_client_pid" >/dev/null 2>&1 || true
		[[ -z "${multi_grid_pid:-}" ]] || kill "$multi_grid_pid" >/dev/null 2>&1 || true
		[[ -z "${unscoped_pid:-}" ]] || kill "$unscoped_pid" >/dev/null 2>&1 || true
		[[ -z "${overlay_pid:-}" ]] || kill "$overlay_pid" >/dev/null 2>&1 || true
		[[ -z "${prompt_pid:-}" ]] || kill "$prompt_pid" >/dev/null 2>&1 || true
		if [[ -n "${shell_pid:-}" ]]; then
			kill "$shell_pid" >/dev/null 2>&1 || true
			wait "$shell_pid" 2>/dev/null || true
		fi
		if [[ -n "${fixture:-}" && -n "${mux_bin:-}" ]]; then
			XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
				kill-server >/dev/null 2>&1 || true
			rm -rf "$fixture"
		fi
	}
	trap cleanup_mux_test EXIT RETURN

	if [[ -f "$build_dir/build.ninja" ]]; then
		meson setup "$build_dir" "$ROOT/mux" --reconfigure >/dev/null
	else
		meson setup "$build_dir" "$ROOT/mux" >/dev/null
	fi
	meson compile -C "$build_dir" >/dev/null
	if [[ -f "$shell_build_dir/build.ninja" ]]; then
		meson setup "$shell_build_dir" "$ROOT/shell" --reconfigure >/dev/null
	else
		meson setup "$shell_build_dir" "$ROOT/shell" >/dev/null
	fi
	meson compile -C "$shell_build_dir" >/dev/null

	mkdir -p "$fixture/custom-runtime"
	chmod 0700 "$fixture/custom-runtime"
	XDG_RUNTIME_DIR="$fixture/custom-runtime" TMUX_TMPDIR="$fixture" \
		"$mux_bin" -L custom -f /dev/null new-session -d -s custom
	[[ ! -e "$fixture/custom-runtime/engineos/mux.sock" ]] ||
		die "custom engine-mux server incorrectly claimed the graphical socket"
	XDG_RUNTIME_DIR="$fixture/custom-runtime" TMUX_TMPDIR="$fixture" \
		"$mux_bin" -L custom kill-server

	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" -f /dev/null \
		new-session -d -s contract '/bin/bash --noprofile --norc'
	for _ in {1..100}; do
		[[ -S "$fixture/engineos/mux.sock" ]] && break
		sleep 0.02
	done
	[[ -S "$fixture/engineos/mux.sock" ]] ||
		die "engine-mux did not create its in-server frontend socket"
	[[ "$(stat -c '%a' "$fixture/engineos")" == 700 &&
		"$(stat -c '%a' "$fixture/engineos/mux.sock")" == 700 ]] ||
		die "engine-mux frontend socket permissions are not private"

	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" hello >"$fixture/hello.json"
	jq -e '.server == "engine-mux" and (.capabilities | index("terminal-grid-v1")) and
		(.capabilities | index("view-snapshot-v1")) and
		(.capabilities | index("pane-input-v1")) and
		(.capabilities | index("graphical-view-v1")) and
		(.capabilities | index("tmux-key-v1")) and
		(.capabilities | index("view-focus-v1")) and
		(.capabilities | index("ui-model-v1")) and
		(.capabilities | index("ui-invalidate-v1")) and
		(.capabilities | index("tmux-mouse-v1")) and
		(.capabilities | index("pane-presentation-v1")) and
		(.capabilities | index("presentation-resolve-v1")) and
		(.capabilities | index("pane-surface-select-v1"))' \
		"$fixture/hello.json" >/dev/null ||
		die "mux protocol was not served by engine-mux"
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" snapshot >"$fixture/first.json"
	first_revision="$(jq -er '.revision' "$fixture/first.json")"
	[[ "$first_revision" -ge 1 ]] || die "initial mux revision was not positive"
	[[ "$(jq -er '.panes | length' "$fixture/first.json")" == 1 ]] ||
		die "initial mux snapshot did not contain one pane"
	jq -e '.panes[0] |
		.left == 0 and .top == 0 and .columns > 0 and .rows > 0' \
		"$fixture/first.json" >/dev/null ||
		die "initial mux snapshot did not expose authoritative pane geometry"
	jq -e '.panes[0].command | contains("/") | not' "$fixture/first.json" >/dev/null ||
		die "mux snapshot did not normalize pane_current_command metadata"
	jq -e '.panes[0].prefix == "C-b" and .panes[0].prefix2 == "None"' \
		"$fixture/first.json" >/dev/null ||
		die "mux snapshot did not expose configured prefix keys"
	pane_id="$(jq -er '.panes[0].pane_id' "$fixture/first.json")"
	local large_grid_pane
	large_grid_pane="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" new-session -d -s large-grid -x 240 -y 67 \
		-P -F '#{pane_id}' /bin/sh)"
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" grid \
		"$large_grid_pane" >"$fixture/large-grid.json"
	jq -e '.columns == 240 and .rows == 67 and .cell_count == 16080' \
		"$fixture/large-grid.json" >/dev/null ||
		die "near-limit terminal grid did not cross the seqpacket transport"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		kill-session -t large-grid
	view_proof_session_id="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" new-session -d -s view-proof -P -F '#{session_id}')"
	view_proof_session="$(jq -er '.panes[0].session_id' "$fixture/first.json")"
	view_proof_pane="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" display-message -p -t view-proof: '#{pane_id}')"
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" \
		view-session-proof "$view_proof_session" "$view_proof_session_id" \
		>"$fixture/view-session-proof.json"
	jq -e --arg first_session "$view_proof_session" \
		--arg second_session "$view_proof_session_id" \
		--arg first_pane "$pane_id" --arg second_pane "$view_proof_pane" \
		'.schema == "engine-mux/view-session-proof-v1" and
		 .first.snapshot_view_id == 1 and .first.snapshot_client_id > 0 and
		 .first.snapshot_output == "view-output-a" and
		 .second.snapshot_view_id == 2 and
		 .second.snapshot_client_id == .first.snapshot_client_id and
		 .second.snapshot_output == "view-output-b" and
		 all(.first.panes[]; .session_id == $first_session) and
		 all(.second.panes[]; .session_id == $second_session) and
		 any(.first.panes[]; .pane_id == $first_pane) and
		 any(.second.panes[]; .pane_id == $second_pane) and
		 ([.first.panes[].pane_id] | unique | length) == (.first.panes | length) and
		 ([.second.panes[].pane_id] | unique | length) == (.second.panes | length) and
		 .invalid_view_error.code == "invalid-view"' \
		"$fixture/view-session-proof.json" >/dev/null ||
		die "view-addressed snapshots did not preserve independent session attachment"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		kill-session -t view-proof
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		list-keys -T prefix v | grep -F 'pane-presentation toggle' >/dev/null ||
		die "engine-mux did not bind prefix+v to the native presentation toggle"
	pane_shell_pid="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" display-message -p -t "$pane_id" '#{pane_pid}')"
	for _ in {1..100}; do
		pane_foreground_pid="$(ps -o tpgid= -p "$pane_shell_pid" | tr -d ' ')"
		[[ "$pane_foreground_pid" == "$pane_shell_pid" ]] && break
		sleep 0.02
	done
	[[ "$pane_foreground_pid" == "$pane_shell_pid" ]] ||
		die "native pane shell did not acquire its PTY foreground process group"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		launch-pane-app -t "$pane_id" -- /bin/sh -c \
		'printf "PRESENTATION-STDOUT\n"; printf "PRESENTATION-STDERR\n" >&2; exec sleep 60'
	for _ in {1..100}; do
		pane_state="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
			"$mux_bin" display-message -p -t "$pane_id" \
			'#{pane_presentation}|#{pane_view_mode}|#{pane_presentation_scope}|#{pane_app_pid}')"
		[[ "$pane_state" =~ ^wayland\|console\|engine-pane-[0-9]+-[0-9]+-[0-9]+\.scope\|[1-9][0-9]*$ ]] && break
		sleep 0.02
	done
	[[ "$pane_state" =~ ^wayland\|console\|engine-pane-[0-9]+-[0-9]+-[0-9]+\.scope\|[1-9][0-9]*$ ]] ||
		die "native pane launch did not become a scoped foreground PTY job: $pane_state"
	pane_scope="$(cut -d'|' -f3 <<<"$pane_state")"
	pane_app_pid="$(cut -d'|' -f4 <<<"$pane_state")"
	[[ "$(ps -o tpgid= -p "$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" display-message -p -t "$pane_id" '#{pane_pid}')" | tr -d ' ')" == "$pane_app_pid" ]] ||
		die "native pane application did not own the PTY foreground process group"
	for _ in {1..100}; do
		grep -F "/$pane_scope" "/proc/$pane_app_pid/cgroup" >/dev/null 2>&1 && break
		sleep 0.02
	done
	grep -F "/$pane_scope" "/proc/$pane_app_pid/cgroup" >/dev/null ||
		die "native pane application was not placed in its registered user scope"
	if XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		pane-presentation -t "$pane_id" app >"$fixture/unmapped-view.out" 2>&1; then
		die "pane presentation switched to an application before a surface mapped"
	fi
	grep -F 'pane has no mapped graphical presentation' "$fixture/unmapped-view.out" >/dev/null ||
		die "unmapped presentation rejection was not explicit"
	if XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" \
		presentation-resolve $$ >"$fixture/wrong-resolve.json" \
		2>"$fixture/wrong-resolve.err"; then
		die "presentation resolver accepted an unrelated process"
	fi
	jq -e '.code == "request-rejected" and
		(.message | contains("outside every pending pane launch scope"))' \
		"$fixture/wrong-resolve.json" >/dev/null ||
		die "wrong-scope presentation resolution was not explicit"
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" \
		presentation-resolve "$pane_app_pid" >"$fixture/resolved-pane.json"
	jq -e --arg pane "$pane_id" '.schema == "engine-mux/presentation-resolve-v1" and
		.pane_id == $pane and .generation == 1 and
		.presentation == "wayland" and .view_mode == "console"' \
		"$fixture/resolved-pane.json" >/dev/null ||
		die "presentation resolver did not return the scoped pane identity"
	if XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" \
		presentation-map "$pane_id" 1 $$ 9001 toplevel \
		>"$fixture/wrong-scope.json" 2>"$fixture/wrong-scope.err"; then
		die "presentation protocol accepted an unrelated process"
	fi
	jq -e '.code == "request-rejected" and
		(.message | contains("outside the pane launch scope"))' \
		"$fixture/wrong-scope.json" >/dev/null ||
		die "wrong-scope surface rejection was not explicit"
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" \
		presentation-map "$pane_id" 1 "$pane_app_pid" 1001 toplevel >/dev/null
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" \
		presentation-map "$pane_id" 1 "$pane_app_pid" 1002 popup >/dev/null
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" \
		presentation-map "$pane_id" 1 "$pane_app_pid" 1003 toplevel >/dev/null
	pane_state="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		display-message -p -t "$pane_id" \
		'#{pane_presentation}|#{pane_view_mode}|#{pane_presentation_mapped}|#{pane_surface_count}|#{pane_active_surface}')"
	[[ "$pane_state" == 'wayland|presentation|1|2|1003' ]] ||
		die "mapped presentation did not expose two pane-local toplevel tabs: $pane_state"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		select-pane-surface -t "$pane_id" previous
	[[ "$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		display-message -p -t "$pane_id" '#{pane_active_surface}')" == 1001 ]] ||
		die "previous pane-local surface tab was not selected"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		select-pane-surface -t "$pane_id" next
	[[ "$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		display-message -p -t "$pane_id" '#{pane_active_surface}')" == 1003 ]] ||
		die "next pane-local surface tab was not selected"
	if XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		select-pane-surface -t "$pane_id" 1002 \
		>"$fixture/non-tab-select.out" 2>&1; then
		die "pane-local tab selection accepted a popup surface"
	fi
	grep -F 'surface tab is not mapped' "$fixture/non-tab-select.out" >/dev/null ||
		die "non-tab surface selection rejection was not explicit"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		pane-presentation -t "$pane_id" toggle
	[[ "$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		display-message -p -t "$pane_id" '#{pane_view_mode}')" == console ]] ||
		die "native presentation toggle did not reveal the backing console"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		pane-presentation -t "$pane_id" toggle
	[[ "$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		display-message -p -t "$pane_id" '#{pane_view_mode}')" == presentation ]] ||
		die "native presentation toggle did not restore the mapped application"
	for _ in {1..100}; do
		XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
			capture-pane -p -t "$pane_id" -S -40 >"$fixture/presentation-console.txt"
		grep -F 'PRESENTATION-STDOUT' "$fixture/presentation-console.txt" >/dev/null &&
			grep -F 'PRESENTATION-STDERR' "$fixture/presentation-console.txt" >/dev/null && break
		sleep 0.02
	done
	grep -F 'PRESENTATION-STDOUT' "$fixture/presentation-console.txt" >/dev/null &&
		grep -F 'PRESENTATION-STDERR' "$fixture/presentation-console.txt" >/dev/null ||
		die "graphical pane stdout and stderr were not retained in its console"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		signal-pane-app -t "$pane_id" TERM
	for _ in {1..100}; do
		pane_state="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
			"$mux_bin" display-message -p -t "$pane_id" \
			'#{pane_presentation}|#{pane_view_mode}|#{pane_app_pid}|#{pane_presentation_scope}|#{pane_surface_count}')"
		[[ "$pane_state" == 'terminal|presentation|||0' ]] && break
		sleep 0.02
	done
	[[ "$pane_state" == 'terminal|presentation|||0' ]] ||
		die "graphical process exit did not restore a clean pane console: $pane_state"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		respawn-pane-app -t "$pane_id"
	for _ in {1..100}; do
		pane_state="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
			"$mux_bin" display-message -p -t "$pane_id" \
			'#{pane_presentation_scope}|#{pane_app_pid}')"
		[[ "$pane_state" =~ ^engine-pane-[0-9]+-[0-9]+-2\.scope\|[1-9][0-9]*$ ]] && break
		sleep 0.02
	done
	[[ "$pane_state" =~ ^engine-pane-[0-9]+-[0-9]+-2\.scope\|[1-9][0-9]*$ ]] ||
		die "graphical pane respawn did not create a new launch scope"
	for _ in {1..850}; do
		pane_state="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
			"$mux_bin" display-message -p -t "$pane_id" \
			'#{pane_presentation}|#{pane_view_mode}|#{pane_app_pid}|#{pane_presentation_scope}')"
		[[ "$pane_state" == 'terminal|presentation||' ]] && break
		sleep 0.02
	done
	[[ "$pane_state" == 'terminal|presentation||' ]] ||
		die "unmapped graphical launch did not time out after 15 seconds"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		capture-pane -p -t "$pane_id" -S -60 >"$fixture/presentation-timeout.txt"
	grep -F 'graphical launch mapped no surface within 15 seconds' \
		"$fixture/presentation-timeout.txt" >/dev/null ||
		die "unmapped graphical launch timeout was not reported in the pane console"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		split-pane-app -g -h -t "$pane_id" -- /bin/sh -c \
		'printf "SPLIT-APP-STDOUT\n"; printf "SPLIT-APP-STDERR\n" >&2; exec sleep 60'
	split_pane_id="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" list-panes -t contract -F '#{pane_id} #{pane_presentation}' |
		awk '$2 == "game" { print $1 }')"
	[[ -n "$split_pane_id" ]] || die "split-pane-app did not create a game pane"
	for _ in {1..100}; do
		pane_state="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
			"$mux_bin" display-message -p -t "$split_pane_id" \
			'#{pane_presentation_scope}|#{pane_app_pid}')"
		[[ "$pane_state" =~ ^engine-pane-split-[0-9]+-[0-9]+\.scope\|[1-9][0-9]*$ ]] && break
		sleep 0.02
	done
	[[ "$pane_state" =~ ^engine-pane-split-[0-9]+-[0-9]+\.scope\|[1-9][0-9]*$ ]] ||
		die "split-pane-app host did not expose its foreground scoped process"
	split_scope="${pane_state%%|*}"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		signal-pane-app -t "$split_pane_id" TERM
	for _ in {1..250}; do
		pane_state="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
			"$mux_bin" display-message -p -t "$split_pane_id" \
			'#{pane_presentation}|#{pane_dead}|#{pane_current_command}')"
		[[ "$pane_state" =~ ^terminal\|0\|.+$ ]] && break
		sleep 0.02
	done
	[[ "$pane_state" =~ ^terminal\|0\|.+$ ]] || {
		XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
			capture-pane -p -t "$split_pane_id" -S -40 >&2 || true
		die "engine-pane-host did not preserve the pane and start a login shell: $pane_state"
	}
	for _ in {1..100}; do
		[[ "$(systemctl --user show "$split_scope" -p ActiveState --value \
			2>/dev/null || true)" != active ]] && break
		sleep 0.02
	done
	[[ "$(systemctl --user show "$split_scope" -p ActiveState --value \
		2>/dev/null || true)" != active ]] ||
		die "engine-pane-host left an empty application scope active: $split_scope"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		kill-pane -t "$split_pane_id"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -g prefix C-a
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		bind-key -T prefix x set-option -g @engineos-key-proof accepted
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" keys "$pane_id" \
		C-a x >"$fixture/keys.json"
	jq -e '.schema == "engine-mux/keys-v1" and .queued == 2' \
		"$fixture/keys.json" >/dev/null ||
		die "graphical key sequence was not queued through the native protocol"
	for _ in {1..100}; do
		key_proof="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
			"$mux_bin" show-option -gv @engineos-key-proof 2>/dev/null || true)"
		[[ "$key_proof" == accepted ]] && break
		sleep 0.02
	done
	[[ "$key_proof" == accepted ]] ||
		die "graphical tmux client did not honor the configured prefix key table"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -g mouse on
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		bind-key -n MouseDown1Pane set-option -g @engineos-mouse-proof accepted
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" mouse "$pane_id" \
		press left 2 2 0 >"$fixture/mouse.json"
	jq -e '.schema == "engine-mux/mouse-v1" and .queued == true' \
		"$fixture/mouse.json" >/dev/null ||
		die "graphical mouse event was not explicitly acknowledged"
	for _ in {1..100}; do
		mouse_proof="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
			"$mux_bin" show-option -gv @engineos-mouse-proof 2>/dev/null || true)"
		[[ "$mouse_proof" == accepted ]] && break
		sleep 0.02
	done
	[[ "$mouse_proof" == accepted ]] ||
		die "graphical mouse did not use tmux pane hit-testing and bindings"
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" mouse "$pane_id" \
		wheel wheel-up 2 2 0 >/dev/null
	for _ in {1..100}; do
		XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" snapshot \
			>"$fixture/mouse-copy-mode.json"
		jq -e --arg pane "$pane_id" \
			'.panes[] | select(.pane_id == $pane) | .copy_mode == true' \
			"$fixture/mouse-copy-mode.json" >/dev/null && break
		sleep 0.02
	done
	jq -e --arg pane "$pane_id" \
		'.panes[] | select(.pane_id == $pane) | .copy_mode == true' \
		"$fixture/mouse-copy-mode.json" >/dev/null ||
		die "graphical mouse wheel did not enter tmux copy mode"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -X -t "$pane_id" cancel
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" mouse-sequence \
		"$pane_id" press left 2 2 0 motion left 10 5 0 \
		release left 10 5 0 >"$fixture/mouse-drag.json"
	jq -e '.schema == "engine-mux/mouse-sequence-v1" and .queued == 3' \
		"$fixture/mouse-drag.json" >/dev/null ||
		die "graphical mouse drag sequence was not kept on one tmux client"
	drag_buffer_size="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" list-buffers -F '#{buffer_size}' 2>/dev/null | head -n 1)"
	[[ "$drag_buffer_size" =~ ^[0-9]+$ && "$drag_buffer_size" -gt 0 ]] ||
		die "graphical mouse drag did not complete a tmux copy-mode selection"
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" snapshot \
		>"$fixture/mouse-drag-snapshot.json"
	jq -e --arg pane "$pane_id" \
		'.panes[] | select(.pane_id == $pane) | .copy_mode == false' \
		"$fixture/mouse-drag-snapshot.json" >/dev/null ||
		die "graphical mouse release did not leave copy mode"
	target_window="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" new-window -d -P -F '#{window_id}' -t contract -n target)"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -g 'status-format[0]' \
		'#[range=window|1]TARGET#[norange default]'
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" mouse "$pane_id" \
		press left 2 23 0 >/dev/null
	[[ "$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		display-message -p '#{window_index}:#{window_name}')" == "1:target" ]] ||
		die "graphical status click did not select tmux's ranged window target"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		select-window -t contract:0
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" mouse-ui "$pane_id" \
		press right 2 23 0 >"$fixture/mouse-menu.json"
	jq -e '.schema == "engine-mux/ui-model-v1" and .menu.active == true and
		(.menu.title | contains("1:target")) and .menu.width > 0 and
		.menu.height > 0' "$fixture/mouse-menu.json" >/dev/null ||
		die "graphical status right-click did not open tmux's window menu"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		bind-key -n MouseDown3Status display-menu -x 10 -y 5 \
		-T CLICK-MENU Pick p \
		'set-option -g @engineos-menu-click accepted'
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" mouse-sequence \
		"$pane_id" press right 2 23 0 press left 12 3 0 \
		release left 12 3 0 >"$fixture/mouse-menu-click.json"
	jq -e '.schema == "engine-mux/mouse-sequence-v1" and .queued == 3' \
		"$fixture/mouse-menu-click.json" >/dev/null ||
		die "graphical menu click sequence was not kept on one tmux client"
	[[ "$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		show-option -gv @engineos-menu-click 2>/dev/null || true)" == accepted ]] ||
		die "graphical menu click did not run tmux's selected menu command"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		kill-window -t "$target_window"
	border_pane_id="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" split-window -h -d -P -F '#{pane_id}' -t "$pane_id")"
	border_width="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" display-message -p -t "$pane_id" '#{pane_width}')"
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" mouse-sequence \
		"$pane_id" press left "$border_width" 5 0 \
		motion left "$((border_width + 5))" 5 0 \
		release left "$((border_width + 5))" 5 0 \
		>"$fixture/mouse-border.json"
	resized_width="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" display-message -p -t "$pane_id" '#{pane_width}')"
	[[ "$resized_width" -gt "$border_width" ]] ||
		die "graphical border drag did not resize the authoritative tmux pane"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		kill-pane -t "$border_pane_id"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -g prefix C-b
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -g status off
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" focus-proof \
		"$pane_id" >"$fixture/focus-proof.json"
	jq -e '.schema == "engine-mux/focus-proof-v1" and
		.focused_view_id == 2 and .columns == 100 and .rows == 30' \
		"$fixture/focus-proof.json" >/dev/null ||
		die "focused graphical view did not take canonical tmux size ownership"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -g status on
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -g 'status-format[0]' 'ENGINE-STATUS #{session_name}'
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" ui "$pane_id" \
		>"$fixture/ui-status.json"
	jq -e '.schema == "engine-mux/ui-model-v1" and
		.columns == 80 and .rows == 24 and
		.status.enabled == true and .status.mode == "status" and
		.status.rendered_line_count == 1 and
		([.status.rows[].text | contains("ENGINE-STATUS contract")] | any) and
		([.status.rows[].spans | length > 0] | all) and
		.prompt.active == false and .message.active == false and
		.menu.active == false' "$fixture/ui-status.json" >/dev/null ||
		die "native UI model did not preserve tmux status text and styles"
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" ui "$pane_id" \
		C-b : >"$fixture/ui-prompt.json"
	jq -e '.schema == "engine-mux/ui-model-v1" and
		.status.mode == "prompt" and .status.rendered_line_count == 1 and
		.prompt.active == true and .prompt.label == ":" and
		.prompt.input == "" and .prompt.cursor == 0 and
		.prompt.screen_cursor_x == 1 and
		.menu.active == false' "$fixture/ui-prompt.json" >/dev/null ||
		die "native UI model did not expose the tmux command prompt"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		bind-key -T prefix m display-menu -T ENGINE-MENU \
		Pick p 'set-option -g @engineos-menu picked'
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" ui "$pane_id" \
		C-b m >"$fixture/ui-menu.json"
	jq -e '.schema == "engine-mux/ui-model-v1" and
		.menu.active == true and .menu.title == "ENGINE-MENU" and
		.menu.height == (.menu.rows | length) and
		([.menu.rows[].text | contains("Pick")] | any) and
		([.menu.items[] | select((.name | startswith("Pick")) and .key == "p" and
			(.command | contains("@engineos-menu")))] | length) == 1' \
		"$fixture/ui-menu.json" >/dev/null ||
		die "native UI model did not expose tmux menu command metadata"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -t "$pane_id" "printf 'A\033[31mR\033[0m界é\n'" Enter
	for _ in {1..100}; do
		XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" grid "$pane_id" \
			>"$fixture/grid.json"
		if jq -e '[.text_rows[] | contains("AR界é")] | any' \
				"$fixture/grid.json" >/dev/null; then
			break
		fi
		sleep 0.02
	done
	jq -e '.schema == "engine-mux/grid-v1" and
		.cell_count == (.columns * .rows) and .coloured_cells >= 1 and
		.wide_cells >= 1 and ([.text_rows[] | contains("AR界é")] | any)' \
		"$fixture/grid.json" >/dev/null || {
		jq '{columns, rows, coloured_cells, wide_cells, text_rows}' \
			"$fixture/grid.json" >&2 || true
		die "binary terminal grid did not preserve text, colour, and wide cells"
	}
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" input "$pane_id" \
		$'printf NATIVE-INPUT-PROOF\r' >"$fixture/input.json"
	jq -e '.schema == "engine-mux/pane-input-v1" and .accepted == true' \
		"$fixture/input.json" >/dev/null ||
		die "native pane input was not explicitly acknowledged"
	for _ in {1..100}; do
		XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" grid "$pane_id" \
			>"$fixture/input-grid.json"
		if jq -e '[.text_rows[] | contains("NATIVE-INPUT-PROOF")] | any' \
				"$fixture/input-grid.json" >/dev/null; then
			break
		fi
		sleep 0.02
	done
	jq -e '[.text_rows[] | contains("NATIVE-INPUT-PROOF")] | any' \
		"$fixture/input-grid.json" >/dev/null ||
		die "native pane input did not reach the authoritative pane PTY"
	grid_revision="$(jq -er '.grid_revision' "$fixture/input-grid.json")"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -t "$pane_id" "printf DAMAGE" Enter
	for _ in {1..100}; do
		XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" damage \
			"$pane_id" "$grid_revision" >"$fixture/damage.json"
		if jq -e '.damage_count > 0' "$fixture/damage.json" >/dev/null; then
			break
		fi
		grid_revision="$(jq -er '.grid_revision' "$fixture/damage.json")"
		sleep 0.02
	done
	damage_revision="$(jq -er '.grid_revision' "$fixture/damage.json")"
	[[ "$damage_revision" -gt 1 ]] ||
		die "grid revision did not advance after terminal cell damage"
	jq -e '.schema == "engine-mux/grid-damage-v1" and .damage_count > 0 and
		(.damage_count < (.columns * .rows))' "$fixture/damage.json" >/dev/null ||
		die "grid damage did not remain sparse"
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" stale-grid \
		"$pane_id" >"$fixture/stale-grid.json"
	jq -e '.code == "grid-resync-required"' "$fixture/stale-grid.json" >/dev/null ||
		die "stale grid revision did not require a complete resynchronization"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -t "$pane_id" \
		"i=1; while [ \$i -le 80 ]; do printf 'HISTORY-%02d\\n' \$i; i=\$((i+1)); done" Enter
	for _ in {1..100}; do
		XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" snapshot \
			>"$fixture/history-snapshot.json"
		history_rows="$(jq -er --arg pane "$pane_id" \
			'.panes[] | select(.pane_id == $pane) | .history_rows' \
			"$fixture/history-snapshot.json")"
		[[ "$history_rows" -ge 5 ]] && break
		sleep 0.02
	done
	[[ "$history_rows" -ge 5 ]] || die "pane history did not reach scrollback"
	history_start=$((history_rows - 5))
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" scrollback \
		"$pane_id" "$history_start" 5 >"$fixture/scrollback.json"
	jq -e '.schema == "engine-mux/scrollback-v1" and .total_rows >= 5 and
		.row_count == 5 and ([.text_rows[] | contains("HISTORY-")] | any)' \
		"$fixture/scrollback.json" >/dev/null ||
		die "paged scrollback did not preserve pane history"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		copy-mode -t "$pane_id"
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" snapshot \
		>"$fixture/copy-mode.json"
	jq -e --arg pane "$pane_id" \
		'.panes[] | select(.pane_id == $pane) | .copy_mode == true' \
		"$fixture/copy-mode.json" >/dev/null ||
		die "mux snapshot did not expose copy-mode state"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -X -t "$pane_id" cancel
	for index in {1..8}; do
		XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" snapshot \
			>"$fixture/concurrent-$index.json" &
	done
	wait
	for index in {1..8}; do
		jq -e '.schema == "engine-mux/snapshot-v1"' \
			"$fixture/concurrent-$index.json" >/dev/null ||
			die "concurrent mux client $index did not receive a snapshot"
	done

	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		split-window -d -t contract:0
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" snapshot >"$fixture/second.json"
	second_revision="$(jq -er '.revision' "$fixture/second.json")"
	pane_count="$(jq -er '.panes | length' "$fixture/second.json")"
	[[ "$second_revision" -gt "$first_revision" && "$pane_count" == 2 ]] ||
		die "mux snapshot was not atomically revised after split"
	jq -e '
		([.panes[].pane_id] | unique | length) == 2 and
		([.panes[].generation] | all(. > 0)) and
		([.panes[] | select(.left < 0 or .top < 0 or
			.columns <= 0 or .rows <= 0)] | length) == 0 and
		(.panes[0] as $a | .panes[1] as $b |
			($a.left + $a.columns <= $b.left) or
			($b.left + $b.columns <= $a.left) or
			($a.top + $a.rows <= $b.top) or
			($b.top + $b.rows <= $a.top))' "$fixture/second.json" >/dev/null ||
		die "split panes did not expose distinct nonoverlapping cell geometry"
	while IFS='|' read -r expected_pane expected_left expected_top \
			expected_columns expected_rows; do
		jq -e --arg pane "$expected_pane" \
			--argjson left "$expected_left" --argjson top "$expected_top" \
			--argjson columns "$expected_columns" --argjson rows "$expected_rows" \
			'.panes[] | select(.pane_id == $pane) |
			 .left == $left and .top == $top and
			 .columns == $columns and .rows == $rows' \
			"$fixture/second.json" >/dev/null ||
			die "mux snapshot geometry diverged from authoritative tmux layout for $expected_pane"
	done < <(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		list-panes -t contract:0 -F \
		'#{pane_id}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}')
	first_split_pane="$(jq -er '.panes[0].pane_id' "$fixture/second.json")"
	second_split_pane="$(jq -er '.panes[1].pane_id' "$fixture/second.json")"
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" multi-grid-proof \
		"$first_split_pane" "$second_split_pane" \
		>"$fixture/multi-grid.json" 2>"$fixture/multi-grid.ready" &
	multi_grid_pid=$!
	for _ in {1..100}; do
		grep -Fx 'multi-grid-ready' "$fixture/multi-grid.ready" >/dev/null 2>&1 && break
		sleep 0.02
	done
	grep -Fx 'multi-grid-ready' "$fixture/multi-grid.ready" >/dev/null ||
		die "multi-pane grid subscriber did not become ready"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -t "$first_split_pane" 'printf MULTI-GRID-FIRST' Enter
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -t "$second_split_pane" 'printf MULTI-GRID-SECOND' Enter
	wait "$multi_grid_pid" || {
		cat "$fixture/multi-grid.ready" >&2
		die "one frontend connection did not retain both pane grid subscriptions"
	}
	multi_grid_pid=""
	jq -e '.schema == "engine-mux/multi-grid-proof-v1" and
		.subscriptions == 2 and .first_invalidated and .second_invalidated' \
		"$fixture/multi-grid.json" >/dev/null ||
		die "multi-pane grid invalidations were not independently delivered"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		select-pane -t contract:0.1
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" snapshot >"$fixture/focus.json"
	focus_revision="$(jq -er '.revision' "$fixture/focus.json")"
	[[ "$focus_revision" -gt "$second_revision" ]] ||
		die "mux revision did not advance after pane focus changed"
	jq -e '[.panes[] | select(.window_active and .active)] | length == 1' \
		"$fixture/focus.json" >/dev/null ||
		die "mux snapshot did not identify the active pane in the active window"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -t contract:0.1 "printf NATIVE-GRID" Enter
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" stale-command >"$fixture/stale.json"
	jq -e '.code == "stale-revision"' "$fixture/stale.json" >/dev/null ||
		die "mux server did not reject a stale revision"
	if pgrep -x engine-muxd >/dev/null 2>&1; then
		die "standalone engine-muxd must not serve the native protocol"
	fi

	local shell_status=0
	if ENGINEOS_MUX_SOCKET="$fixture/missing.sock" \
			"$shell_bin" --headless --smoke --mux native \
			>"$fixture/shell-fail.log" 2>&1; then
		die "engineos-shell native mux mode silently fell back without a server"
	else
		shell_status=$?
	fi
	[[ "$shell_status" == 1 ]] ||
		die "engineos-shell native mux failure exited abnormally: $shell_status"
	grep -F 'native mux handshake failed' "$fixture/shell-fail.log" >/dev/null ||
		die "engineos-shell native mux failure was not explicit"

	XDG_RUNTIME_DIR="$fixture" ENGINEOS_STATE_DIR="$fixture/engineos" \
		ENGINEOS_MUX_SOCKET="$fixture/engineos/mux.sock" \
		WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=2 WLR_RENDERER="$shell_renderer" \
		"$shell_bin" --headless --smoke-ms 90000 \
		--bootstrap none --mux native >"$fixture/shell-native.log" 2>&1 &
	shell_pid=$!
	for _ in {1..100}; do
		[[ -f "$fixture/engineos/shell-state.json" ]] &&
			jq -e '.backend == "headless" and .mux.client_view_id > 0 and
				.mux.grid.rendered == true and .mux.ui.mode == "status" and
				.mux.ui.status_rows == 1 and (.output_views | length) == 2 and
				all(.output_views[]; .frame_commits > 0)' \
				"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	[[ -f "$fixture/engineos/shell-state.json" ]] || {
		tail -80 "$fixture/shell-native.log" >&2 || true
		die "engineos-shell did not publish native grid state"
	}
	jq -e '.mux.session_id | startswith("$")' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "shell state did not identify the attached mux session"
	jq -e '.mux.client_view_id > 0' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '{mux,counts,last_reason}' "$fixture/engineos/shell-state.json" >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		die "shell state did not identify its graphical mux client view"
	}
	jq -e --arg session "$(jq -er '.mux.session_id' \
			"$fixture/engineos/shell-state.json")" \
		'(.output_views | length) == 2 and
		 all(.output_views[]; .model_ready and .model_revision > 0 and
		   .session_id == $session and .pane_count > 0 and
		   .frame_commits > 0 and .frame_failures == 0 and
		   .pane_generation > 0 and .grid_ready_count == .pane_count and
		   .grid_subscribed_count == .pane_count and .grid_revision > 0 and
		   .rendered_pane_count == .pane_count and
		   .selected_renderer_frame > 0 and .selected_renderer != null and
		   (.panes | length) == .pane_count and
		   all(.panes[]; .within_output and .pixel_width > 0 and
		     .pixel_height > 0 and .frame > 0 and .renderer != null) and
		   .ui.ready and .ui.columns > 0 and .ui.rows > 0 and
		   .ui.status_rows > 0 and .ui.status_text != null and
		   .ui.rendered and .ui.renderer != null and .ui.frame > 0) and
		 ((.output_views[] | select(.focused)) as $focused |
		  .input.view_id == $focused.view_id and
		  .input.pane_id == $focused.pane_id and
		  .input.pane_generation == $focused.pane_generation)' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "shell did not retain an authoritative model for every output view"
	jq -e '
		.mux.panes | length == 2 and
		([.[].pane_id] | unique | length) == 2 and
		([.[] | select(.generation <= 0 or .left < 0 or .top < 0 or
			.columns <= 0 or .rows <= 0 or .grid.ready != true or
			.grid.subscribed != true or .grid.revision <= 0 or
			.scene.rendered != true or .scene.pixel_width <= 0 or
			.scene.pixel_height <= 0 or .scene.frame < 1)] | length) == 0 and
		(.[0] as $a | .[1] as $b |
			($a.scene.pixel_x + $a.scene.pixel_width <= $b.scene.pixel_x) or
			($b.scene.pixel_x + $b.scene.pixel_width <= $a.scene.pixel_x) or
			($a.scene.pixel_y + $a.scene.pixel_height <= $b.scene.pixel_y) or
			($b.scene.pixel_y + $b.scene.pixel_height <= $a.scene.pixel_y))' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '.mux.panes' "$fixture/engineos/shell-state.json" >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		die "shell did not render every authoritative mux pane in a distinct scene"
	}
	jq -e --arg pane "$(jq -er '.mux.pane_id' \
			"$fixture/engineos/shell-state.json")" \
		'.mux.panes[] | select(.pane_id == $pane and .window_active and .active)' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "shell all-pane model did not contain its selected active pane"
	shell_pane_id="$(jq -er '.mux.pane_id' \
		"$fixture/engineos/shell-state.json")"
	local other_shell_pane initial_other_revision initial_other_frame
	local updated_other_revision updated_other_frame
	other_shell_pane="$(jq -er --arg pane "$shell_pane_id" \
		'.mux.panes[] | select(.pane_id != $pane) | .pane_id' \
		"$fixture/engineos/shell-state.json")"
	initial_other_revision="$(jq -er --arg pane "$other_shell_pane" \
		'.mux.panes[] | select(.pane_id == $pane) | .grid.revision' \
		"$fixture/engineos/shell-state.json")"
	initial_other_frame="$(jq -er --arg pane "$other_shell_pane" \
		'.mux.panes[] | select(.pane_id == $pane) | .scene.frame' \
		"$fixture/engineos/shell-state.json")"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -t "$other_shell_pane" "printf NONSELECTED-SCENE-DAMAGE" Enter
	for _ in {1..150}; do
		updated_other_revision="$(jq -er --arg pane "$other_shell_pane" \
			'.mux.panes[] | select(.pane_id == $pane) | .grid.revision' \
			"$fixture/engineos/shell-state.json")"
		updated_other_frame="$(jq -er --arg pane "$other_shell_pane" \
			'.mux.panes[] | select(.pane_id == $pane) | .scene.frame' \
			"$fixture/engineos/shell-state.json")"
		[[ "$updated_other_revision" -gt "$initial_other_revision" &&
			"$updated_other_frame" -gt "$initial_other_frame" ]] && break
		sleep 0.02
	done
	[[ "$updated_other_revision" -gt "$initial_other_revision" &&
		"$updated_other_frame" -gt "$initial_other_frame" ]] || {
		jq --arg pane "$other_shell_pane" \
			'.mux.panes[] | select(.pane_id == $pane)' \
			"$fixture/engineos/shell-state.json" >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		die "nonselected mux pane damage did not update its own native scene"
	}
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		select-pane -t "$other_shell_pane"
	for _ in {1..150}; do
		jq -e --arg pane "$other_shell_pane" \
			'.mux.pane_id == $pane and
			 (.mux.panes[] | select(.pane_id == $pane) |
			  .active == true and .visible == true and
			  .grid.columns == .columns and .grid.rows == .rows)' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg pane "$other_shell_pane" \
		'.mux.pane_id == $pane and
		 (.mux.panes[] | select(.pane_id == $pane) |
		  .active == true and .grid.columns == .columns and
		  .grid.rows == .rows)' "$fixture/engineos/shell-state.json" \
		>/dev/null || {
		jq '{mux,last_reason}' "$fixture/engineos/shell-state.json" >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		die "native shell did not adopt the authoritative active pane"
	}
	local initial_resize_rows updated_resize_rows
	initial_resize_rows="$(jq -er --arg pane "$other_shell_pane" \
		'.mux.panes[] | select(.pane_id == $pane) | .rows' \
		"$fixture/engineos/shell-state.json")"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		resize-pane -t "$other_shell_pane" -D 2
	updated_resize_rows="$initial_resize_rows"
	for _ in {1..150}; do
		updated_resize_rows="$(jq -er --arg pane "$other_shell_pane" \
			'.mux.panes[] | select(.pane_id == $pane) | .rows' \
			"$fixture/engineos/shell-state.json")"
		jq -e '.mux.panes | map(select(.visible)) |
			length == 2 and (.[0] as $a | .[1] as $b |
			 ($a.scene.pixel_x + $a.scene.pixel_width <= $b.scene.pixel_x) or
			 ($b.scene.pixel_x + $b.scene.pixel_width <= $a.scene.pixel_x) or
			 ($a.scene.pixel_y + $a.scene.pixel_height <= $b.scene.pixel_y) or
			 ($b.scene.pixel_y + $b.scene.pixel_height <= $a.scene.pixel_y))' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 &&
			[[ "$updated_resize_rows" -ne "$initial_resize_rows" ]] && break
		sleep 0.02
	done
	[[ "$updated_resize_rows" -ne "$initial_resize_rows" ]] ||
		die "native pane scene geometry did not follow authoritative resize"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		resize-pane -Z -t "$other_shell_pane"
	for _ in {1..150}; do
		jq -e --arg pane "$other_shell_pane" \
			'([.mux.panes[] | select(.visible)] | length) == 1 and
			 any(.mux.panes[]; .pane_id == $pane and .visible and
			  .scene.terminal_visible) and
			 all(.mux.panes[]; .visible or
			  (.scene.terminal_visible == false)) and
			 all(.output_views[];
			  ([.panes[] | select(.visible and .terminal_visible)] | length) == 1 and
			  all(.panes[]; .visible or (.terminal_visible == false)))' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg pane "$other_shell_pane" \
		'([.mux.panes[] | select(.visible)] | length) == 1 and
		 any(.mux.panes[]; .pane_id == $pane and .visible) and
		 all(.output_views[];
		  ([.panes[] | select(.visible and .terminal_visible)] | length) == 1 and
		  all(.panes[]; .visible or (.terminal_visible == false)))' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "native mux zoom did not hide nonvisible pane scenes"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		resize-pane -Z -t "$other_shell_pane"
	for _ in {1..150}; do
		jq -e '([.mux.panes[] | select(.visible)] | length) == 2 and
			all(.output_views[];
			 ([.panes[] | select(.visible and .terminal_visible)] | length) == 2)' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '([.mux.panes[] | select(.visible)] | length) == 2 and
		all(.output_views[];
		 ([.panes[] | select(.visible and .terminal_visible)] | length) == 2)' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "native mux unzoom did not restore pane scenes"
	local focus_target
	for index in {1..100}; do
		if (( index % 2 == 0 )); then
			focus_target="$other_shell_pane"
		else
			focus_target="$shell_pane_id"
		fi
		XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
			select-pane -t "$focus_target"
	done
	for _ in {1..250}; do
		jq -e --arg pane "$other_shell_pane" \
			'.mux.pane_id == $pane and
			 ([.mux.panes[] | select(.active and .window_active)] | length) == 1 and
			 ([.mux.panes[] | select(.visible)] | length) == 2 and
			 all(.mux.panes[]; .grid.columns == .columns and
			  .grid.rows == .rows and .scene.rendered)' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg pane "$other_shell_pane" \
		'.mux.pane_id == $pane and
		 ([.mux.panes[] | select(.active and .window_active)] | length) == 1 and
		 all(.mux.panes[]; .grid.columns == .columns and
		  .grid.rows == .rows and .scene.rendered)' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '{mux:{pane_id:.mux.pane_id,panes:.mux.panes},output_views,last_reason}' \
			"$fixture/engineos/shell-state.json" >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		die "one hundred native pane focus transitions left stale scene state"
	}

	local topology_pane topology_generation
	local topology_left topology_top swapped_left swapped_top broken_window
	local destination_session graphical_client
	topology_pane="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" new-window -d -P -F '#{pane_id}' -t contract -n topology)"
	for _ in {1..150}; do
		jq -e '.mux.panes | length == 2' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg pane "$topology_pane" \
		'.mux.panes | length == 2 and
		 all(.[]; .pane_id != $pane and .window_active)' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "inactive tmux window leaked panes into the graphical client view"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		join-pane -h -s "$topology_pane" -t "$other_shell_pane"
	for _ in {1..150}; do
		jq -e --arg pane "$topology_pane" \
			'.mux.panes | length == 3 and
			 ([.[].pane_id] | unique | length) == 3 and
			 any(.[]; .pane_id == $pane and .grid.ready and
			  .grid.subscribed and .scene.rendered)' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg pane "$topology_pane" \
		'.mux.panes | length == 3 and
		 any(.[]; .pane_id == $pane and .grid.ready and .scene.rendered)' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "join-pane did not add its stable pane to the active graphical scene"
	topology_generation="$(jq -er --arg pane "$topology_pane" \
		'.mux.panes[] | select(.pane_id == $pane) | .generation' \
		"$fixture/engineos/shell-state.json")"
	topology_left="$(jq -er --arg pane "$topology_pane" \
		'.mux.panes[] | select(.pane_id == $pane) | .left' \
		"$fixture/engineos/shell-state.json")"
	topology_top="$(jq -er --arg pane "$topology_pane" \
		'.mux.panes[] | select(.pane_id == $pane) | .top' \
		"$fixture/engineos/shell-state.json")"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		swap-pane -d -s "$topology_pane" -t "$shell_pane_id"
	swapped_left="$topology_left"
	swapped_top="$topology_top"
	for _ in {1..150}; do
		swapped_left="$(jq -er --arg pane "$topology_pane" \
			'.mux.panes[] | select(.pane_id == $pane) | .left' \
			"$fixture/engineos/shell-state.json")"
		swapped_top="$(jq -er --arg pane "$topology_pane" \
			'.mux.panes[] | select(.pane_id == $pane) | .top' \
			"$fixture/engineos/shell-state.json")"
		[[ "$swapped_left" != "$topology_left" ||
			"$swapped_top" != "$topology_top" ]] && break
		sleep 0.02
	done
	[[ "$swapped_left" != "$topology_left" ||
		"$swapped_top" != "$topology_top" ]] ||
		die "swap-pane did not transactionally move the retained pane scene"
	jq -e --arg pane "$topology_pane" --argjson generation "$topology_generation" \
		'any(.mux.panes[]; .pane_id == $pane and
		 .generation == $generation and .grid.ready and .scene.rendered)' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "swap-pane changed pane identity or lost its retained grid"
	broken_window="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" break-pane -d -P -F '#{window_id}' -s "$topology_pane")"
	for _ in {1..150}; do
		jq -e --arg pane "$topology_pane" \
			'any(.output_views[]; .focused and .pane_count == 2 and
			   .rendered_pane_count == 2) and
			 all(.mux.panes[]; .pane_id != $pane or
			   .scene.output_scene_count == 0)' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg pane "$topology_pane" \
		'any(.output_views[]; .focused and .pane_count == 2 and
		   .rendered_pane_count == 2) and
		 all(.mux.panes[]; .pane_id != $pane or
		   .scene.output_scene_count == 0)' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '{mux,output_views,last_reason}' \
			"$fixture/engineos/shell-state.json" >&2 || true
		tail -120 "$fixture/shell-native.log" >&2 || true
		die "break-pane did not remove the pane from the active graphical scene"
	}
	destination_session="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" new-session -d -s topology-destination -P -F '#{session_id}')"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		move-window -s "$broken_window" -t topology-destination:
	local graphical_output
	graphical_output="$(jq -er \
		'.output_views[] | select(.focused) | .output' \
		"$fixture/engineos/shell-state.json")"
	graphical_client="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" list-clients -F '#{client_name}|#{client_tty}' | \
		awk -F'|' -v output="$graphical_output" \
			'$1 ~ /^engineos-view-/ && $2 == output { print $1; exit }')"
	[[ -n "$graphical_client" ]] ||
		die "native mux graphical tmux client was not discoverable"
	if ! XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
			switch-client -c "$graphical_client" -t "$topology_pane"; then
		XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
			list-clients -F '#{client_name}|#{client_tty}|#{client_session}' \
			>&2 || true
		jq '{mux,output_views,last_reason}' \
			"$fixture/engineos/shell-state.json" >&2 || true
		tail -120 "$fixture/shell-native.log" >&2 || true
		die "focused graphical client disappeared before session transfer"
	fi
	for _ in {1..200}; do
		jq -e --arg session "$destination_session" --arg pane "$topology_pane" \
			--argjson generation "$topology_generation" \
			'.mux.session_id == $session and .mux.pane_id == $pane and
			 (.mux.panes | length) == 1 and
			 (.mux.panes[0].pane_id == $pane) and
			 (.mux.panes[0].generation == $generation) and
			 .mux.panes[0].grid.ready and .mux.panes[0].scene.rendered' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg session "$destination_session" --arg pane "$topology_pane" \
		--argjson generation "$topology_generation" \
		'.mux.session_id == $session and .mux.pane_id == $pane and
		 (.mux.panes | length) == 1 and
		 (.mux.panes[0].generation == $generation) and
		 .mux.panes[0].scene.rendered' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '{mux,output_views,last_reason}' \
			"$fixture/engineos/shell-state.json" >&2 || true
		tail -120 "$fixture/shell-native.log" >&2 || true
		die "moved window/session did not transfer the graphical client view with stable pane identity"
	}
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		link-window -s contract:0 -t topology-destination:
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" snapshot \
		>"$fixture/linked-global-snapshot.json"
	jq -e '([.panes[].pane_id] | unique | length) == (.panes | length)' \
		"$fixture/linked-global-snapshot.json" >/dev/null ||
		die "unscoped mux snapshot duplicated a linked canonical window"
	if ! XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
			switch-client -c "$graphical_client" -t "$shell_pane_id"; then
		jq '{mux,output_views,last_reason}' \
			"$fixture/engineos/shell-state.json" >&2 || true
		tail -120 "$fixture/shell-native.log" >&2 || true
		die "graphical client disappeared before linked-window return"
	fi
	for _ in {1..200}; do
		jq -e --arg session "$destination_session" --arg pane "$shell_pane_id" \
			'.mux.session_id == $session and .mux.pane_id == $pane and
			 (.mux.panes | length) == 2 and
			 ([.mux.panes[].pane_id] | unique | length) == 2 and
			 all(.mux.panes[]; .grid.ready and .scene.rendered)' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg session "$destination_session" --arg pane "$shell_pane_id" \
		'.mux.session_id == $session and .mux.pane_id == $pane and
		 (.mux.panes | length) == 2 and
		 ([.mux.panes[].pane_id] | unique | length) == 2 and
		 all(.mux.panes[]; .grid.ready and .scene.rendered)' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '{mux: {session_id: .mux.session_id, pane_id: .mux.pane_id,
			panes: .mux.panes}, last_reason}' \
			"$fixture/engineos/shell-state.json" >&2 || true
		tail -120 "$fixture/shell-native.log" >&2 || true
		die "linked window duplicated pane identity or escaped the attached graphical view"
	}

	if ! kill "$shell_pid" 2>/dev/null; then
		tail -120 "$fixture/shell-native.log" >&2 || true
		die "graphical mux client exited before the detach/reattach proof"
	fi
	wait "$shell_pid" 2>/dev/null || true
	rm -f "$fixture/engineos/shell-state.json"
	XDG_RUNTIME_DIR="$fixture" ENGINEOS_STATE_DIR="$fixture/engineos" \
		ENGINEOS_MUX_SOCKET="$fixture/engineos/mux.sock" \
		WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=2 WLR_RENDERER="$shell_renderer" \
		"$shell_bin" --headless --smoke-ms 90000 \
		--bootstrap none --mux native >"$fixture/shell-native.log" 2>&1 &
	shell_pid=$!
	for _ in {1..250}; do
		[[ -f "$fixture/engineos/shell-state.json" ]] &&
			jq -e '(.mux.panes | length) == 2 and .mux.client_view_id > 0 and
			 all(.mux.panes[]; .grid.ready and .grid.subscribed and
			  .scene.rendered)' "$fixture/engineos/shell-state.json" \
			>/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '(.mux.panes | length) == 2 and .mux.client_view_id > 0 and
		 all(.mux.panes[]; .grid.ready and .scene.rendered)' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "graphical mux client did not detach and reattach with retained pane state"
	shell_pane_id="$(jq -er '.mux.pane_id' \
		"$fixture/engineos/shell-state.json")"
	other_shell_pane="$(jq -er --arg pane "$shell_pane_id" \
		'.mux.panes[] | select(.pane_id != $pane) | .pane_id' \
		"$fixture/engineos/shell-state.json")"
	if [[ "$shell_renderer" == gles2 ]]; then
		if [[ "${ENGINEOS_MUX_REQUIRE_RADEONSI:-false}" == true ]]; then
			grep -F 'EGL driver name: radeonsi' "$fixture/shell-native.log" \
				>/dev/null ||
				die "native GLES2 mux proof did not use the AMD radeonsi driver"
		fi
		jq -e '.mux.grid.renderer == "gpu-glyph-atlas-gles2" and
			.mux.grid.atlas_entries > 0 and .mux.grid.nonblank_pixels > 0 and
			.mux.grid.frame >= 1' \
			"$fixture/engineos/shell-state.json" >/dev/null ||
			die "native shell did not initialize its GLES2 glyph atlas"
	elif [[ "$shell_renderer" == pixman ]]; then
		jq -e '.mux.grid.renderer == "cpu-pixman-smoke" and
			.mux.grid.atlas_entries == 0' \
			"$fixture/engineos/shell-state.json" >/dev/null ||
			die "native shell did not identify its pixman smoke renderer"
	fi
	wayland_display="$(jq -er '.wayland_display' \
		"$fixture/engineos/shell-state.json")"
	WAYLAND_DISPLAY="$fixture/$wayland_display" \
		"$fixture/bin/engineos-wayland-presentation-client" \
		>"$fixture/unscoped-wayland.out" 2>"$fixture/unscoped-wayland.err" &
	unscoped_pid=$!
	for _ in {1..100}; do
		grep -F 'native presentation rejected' "$fixture/shell-native.log" \
			>/dev/null 2>&1 && break
		sleep 0.02
	done
	grep -F 'native presentation rejected' "$fixture/shell-native.log" \
		>/dev/null || {
		tail -100 "$fixture/shell-native.log" >&2 || true
		die "native shell did not reject an unscoped Wayland client"
	}
	wait "$unscoped_pid" ||
		die "unscoped Wayland client was not closed through the XDG protocol"
	unscoped_pid=""
	shell_pane_id="$(jq -er '.mux.pane_id' \
		"$fixture/engineos/shell-state.json")"
	pane_shell_pid="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" display-message -p -t "$shell_pane_id" '#{pane_pid}')"
	for _ in {1..100}; do
		pane_foreground_pid="$(ps -o tpgid= -p "$pane_shell_pid" | tr -d ' ')"
		[[ "$pane_foreground_pid" == "$pane_shell_pid" ]] && break
		sleep 0.02
	done
	[[ "$pane_foreground_pid" == "$pane_shell_pid" ]] ||
		die "selected native pane shell did not regain its PTY foreground group"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -t "$shell_pane_id" -l \
		"printf '\\033[2J\\033[HTXT-BACK-CONSOLE\\n'"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -t "$shell_pane_id" Enter
	for _ in {1..100}; do
		XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
			capture-pane -p -S -100 -t "$shell_pane_id" | \
			grep -F 'TXT-BACK-CONSOLE' >/dev/null && break
		sleep 0.02
	done
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		capture-pane -p -S -100 -t "$shell_pane_id" | \
		grep -F 'TXT-BACK-CONSOLE' >/dev/null || {
		XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
			capture-pane -p -S -100 -t "$shell_pane_id" >&2 || true
		die "ordinary-client backing-console marker did not reach the pane grid"
	}
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		launch-pane-app -t "$shell_pane_id" -- env \
		ENGINEOS_WAYLAND_TEST_DELAY_MS=250 \
		ENGINEOS_WAYLAND_TEST_POPUP=1 \
		ENGINEOS_WAYLAND_TEST_TRANSIENT=1 \
		ENGINEOS_WAYLAND_TEST_TAB=1 \
		WAYLAND_DISPLAY="$fixture/$wayland_display" \
		"$fixture/bin/engineos-wayland-presentation-client"
	for _ in {1..150}; do
		jq -e --arg pane "$shell_pane_id" \
			'.mux.grid.pixel_width as $width |
			 .mux.grid.pixel_height as $height |
			 .mux.presentation.type == "wayland" and
			 .mux.presentation.view_mode == "presentation" and
			 .mux.presentation.mapped == true and
			 .mux.presentation.lease_client_id > 0 and
			 .mux.presentation.lease_view_id == .mux.client_view_id and
			 .mux.presentation.lease_owned_by_focused_view == true and
			 ([.output_views[] | select(.owns_selected_presentation)] | length) == 1 and
			 .mux.presentation.surface_tabs == 2 and
			 .mux.presentation.popups == 1 and
			 .mux.presentation.terminal_visible == false and
			 .input.mode == "graphical" and
			 ([.windows[] | select(.bound == true)] | length) == 3 and
			 any(.windows[]; .bound == true and .surface_role == "transient" and
			   .width < $width and .height < $height and .visible == false) and
			 ([.windows[] | select(.bound == true and
			   .surface_role == "toplevel" and .visible == true)] | length) == 1 and
			 any(.windows[]; .bound == true and .pane_id == $pane and
			   .presentation_visible == true and .visible == true)' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg pane "$shell_pane_id" \
		'.mux.presentation.view_mode == "presentation" and
		 .mux.presentation.lease_client_id > 0 and
		 .mux.presentation.lease_view_id == .mux.client_view_id and
		 .mux.presentation.lease_owned_by_focused_view == true and
		 ([.output_views[] | select(.owns_selected_presentation)] | length) == 1 and
		 ([.output_views[].scene_x] | unique | length) == 2 and
		 ([.output_views[] | select(.owns_selected_presentation) |
		   select(.bound_presentation_surface_count == 3 and
		     .presentation_surface_count == 1 and .console_scene_count == 1)] |
		  length) == 1 and
		 ([.output_views[] | select(.owns_selected_presentation == false) |
		   select(.bound_presentation_surface_count == 0 and
		     .presentation_surface_count == 0 and .console_scene_count == 2)] |
		  length) == 1 and
		 all(.mux.panes[]; .scene.output_scene_count == 2) and
		 .mux.presentation.popups == 1 and
		 .mux.presentation.surface_tabs == 2 and
		 ([.windows[] | select(.bound == true and .pane_id == $pane)] | length) == 3 and
		 any(.windows[]; .bound == true and .app_id ==
		   "engineos.presentation-tab-proof" and .visible == true) and
		 all(.windows[]; .bound == false or .surface_role != "transient" or
		   .visible == false)' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '{mux,input,windows}' "$fixture/engineos/shell-state.json" >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		die "scoped Wayland client did not bind to its native mux pane"
	}
	local pane_lease_format
	pane_lease_format="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" display-message -p -t "$shell_pane_id" \
		'#{pane_presentation_lease_client}|#{pane_presentation_lease_view}')"
	[[ "$pane_lease_format" =~ ^[1-9][0-9]*\|[1-9][0-9]*$ ]] ||
		die "tmux formats did not expose the live presentation client-view lease"
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" focus-proof \
		"$shell_pane_id" >"$fixture/presentation-lease-transfer.json"
	jq -e '.schema == "engine-mux/focus-proof-v1" and
		.lease_client_id > 0 and .lease_view_id == 2' \
		"$fixture/presentation-lease-transfer.json" >/dev/null ||
		die "presentation lease did not transfer to the newly focused graphical view"
	for _ in {1..150}; do
		jq -e '.mux.presentation.lease_view_id == .mux.client_view_id and
			.mux.presentation.lease_owned_by_focused_view == true and
			([.output_views[] | select(.owns_selected_presentation)] | length) == 1' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.mux.presentation.lease_view_id == .mux.client_view_id and
		.mux.presentation.lease_owned_by_focused_view == true' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '{mux: .mux.presentation, client_view_id: .mux.client_view_id,
			frontend_client_id: .mux.frontend_client_id,
			output_views}' "$fixture/engineos/shell-state.json" >&2 || true
		XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
			list-clients -F '#{client_name}|#{client_flags}|#{client_termname}' \
			>&2 || true
		XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" snapshot \
			| jq --arg pane "$shell_pane_id" \
			'{focused_client_id, focused_view_id, pane: (.panes[] | select(.pane_id == $pane))}' \
			>&2 || true
			die "presentation lease did not return to the surviving shell output view"
	}
	local text_client_session canonical_size attached_size
	text_client_session="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" display-message -p -t "$shell_pane_id" '#{session_id}')"
	canonical_size="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" display-message -p -t "$shell_pane_id" \
		'#{window_width}x#{window_height}')"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -g 'status-format[0]' \
		'TXT #{pane_presentation}:#{pane_view_mode}:#{pane_surface_count}'
	python "$text_client_driver" \
		--mux "$mux_bin" --runtime "$fixture" --target "=$text_client_session" \
		--output "$fixture/text-client.raw" \
		--ready "$fixture/text-client.ready" \
		--release "$fixture/text-client.release" \
		--initial-marker 'TXT wayland:presentation:2' \
		--toggled-marker 'TXT wayland:console:2' \
		--timeout 12 \
		>"$fixture/text-client.log" 2>&1 &
	text_client_pid=$!
	for _ in {1..650}; do
		[[ -f "$fixture/text-client.ready" ]] && break
		kill -0 "$text_client_pid" >/dev/null 2>&1 || break
		sleep 0.02
	done
	[[ -f "$fixture/text-client.ready" ]] || {
		if kill -0 "$text_client_pid" >/dev/null 2>&1; then
			kill "$text_client_pid" >/dev/null 2>&1 || true
		fi
		wait "$text_client_pid" 2>/dev/null || true
		text_client_pid=""
		cat "$fixture/text-client.log" >&2 || true
		strings "$fixture/text-client.raw" >&2 || true
		die "ordinary tmux tty client did not attach and drive prefix+v"
	}
	jq -e '.schema == "engineos/tmux-text-client-proof-v1" and
		.columns == 50 and .rows == 20' "$fixture/text-client.ready" >/dev/null ||
		die "ordinary tmux tty client did not publish its PTY dimensions"
	grep -aF 'TXT wayland:presentation:2' "$fixture/text-client.raw" >/dev/null &&
		grep -aF 'TXT wayland:console:2' "$fixture/text-client.raw" >/dev/null &&
		grep -aF 'Running as unit:' "$fixture/text-client.raw" >/dev/null ||
		die "ordinary tmux tty client did not render console and presentation metadata"
	[[ "$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		show-option -gv @engineos-text-client 2>/dev/null || true)" == accepted ]] ||
		die "ordinary tmux tty client command prompt did not execute"
	for _ in {1..150}; do
		jq -e '.mux.presentation.view_mode == "console" and
			.mux.presentation.terminal_visible == true and
			.input.mode == "terminal"' "$fixture/engineos/shell-state.json" \
			>/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.mux.presentation.view_mode == "console" and
		.mux.presentation.terminal_visible == true and
		.input.mode == "terminal" and (.output_views | length) == 2 and
		all(.output_views[]; .model_ready and .rendered_pane_count > 0)' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "ordinary-client prefix+v did not update the graphical shell"
	[[ "$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		display-message -p -t "$shell_pane_id" \
		'#{window_width}x#{window_height}')" == "$canonical_size" ]] ||
		die "small ordinary tmux client changed graphical canonical geometry"
	attached_size="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" list-clients -F \
		'#{client_name}|#{client_width}x#{client_height}|#{client_termname}' | \
		awk -F'|' '$1 !~ /^engineos-view-/ {print $2 "|" $3; exit}')"
	[[ "$attached_size" == '50x20|xterm-256color' ]] ||
		die "ordinary tty client was not attached at its independent padded size: $attached_size"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		pane-presentation -t "$shell_pane_id" app
	for _ in {1..150}; do
		jq -e '.mux.presentation.view_mode == "presentation" and
			.mux.presentation.terminal_visible == false and
			.input.mode == "graphical"' "$fixture/engineos/shell-state.json" \
			>/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.mux.presentation.view_mode == "presentation" and
		.mux.presentation.terminal_visible == false and
		.input.mode == "graphical"' "$fixture/engineos/shell-state.json" \
		>/dev/null || die "graphical presentation did not recover after ordinary-client toggle"
	touch "$fixture/text-client.release"
	wait "$text_client_pid" || {
		cat "$fixture/text-client.log" >&2 || true
		die "ordinary tmux tty client did not detach cleanly"
	}
	text_client_pid=""
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -g 'status-format[0]' 'ENGINE-STATUS #{session_name}'
	[[ "$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		display-message -p -t "$shell_pane_id" \
		'#{window_width}x#{window_height}')" == "$canonical_size" ]] ||
		die "ordinary tty client detach changed graphical canonical geometry"
	command -v ssh >/dev/null && command -v sshd >/dev/null &&
		command -v ssh-keygen >/dev/null ||
		die "SSH tmux acceptance requires ssh, sshd, and ssh-keygen"
	mkdir -p "$fixture/ssh"
	ssh-keygen -q -t ed25519 -N '' -f "$fixture/ssh/host-key"
	ssh-keygen -q -t ed25519 -N '' -f "$fixture/ssh/client-key"
	cp "$fixture/ssh/client-key.pub" "$fixture/ssh/authorized-keys"
	chmod 0600 "$fixture/ssh/authorized-keys"
	ssh_port="$(python - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)"
	{
		printf 'Port %s\n' "$ssh_port"
		printf 'AddressFamily inet\n'
		printf 'ListenAddress 127.0.0.1\n'
		printf 'HostKey %s\n' "$fixture/ssh/host-key"
		printf 'PidFile %s\n' "$fixture/ssh/sshd.pid"
		printf 'AuthorizedKeysFile %s\n' "$fixture/ssh/authorized-keys"
		printf 'UsePAM no\nPasswordAuthentication no\n'
		printf 'KbdInteractiveAuthentication no\nPubkeyAuthentication yes\n'
		printf 'PermitRootLogin no\nStrictModes no\nLogLevel VERBOSE\n'
		printf 'AllowUsers %s\n' "$(id -un)"
	} >"$fixture/ssh/sshd-config"
	"$(command -v sshd)" -D -f "$fixture/ssh/sshd-config" \
		-E "$fixture/ssh/sshd.log" &
	sshd_pid=$!
	for _ in {1..150}; do
		ss -ltn | grep -F ":$ssh_port " >/dev/null && break
		kill -0 "$sshd_pid" >/dev/null 2>&1 || break
		sleep 0.02
	done
	ss -ltn | grep -F ":$ssh_port " >/dev/null || {
		cat "$fixture/ssh/sshd.log" >&2 || true
		die "isolated SSH acceptance server did not listen on loopback"
	}
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -gu @engineos-ssh-text-client 2>/dev/null || true
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -g 'status-format[0]' \
		'TXT #{pane_presentation}:#{pane_view_mode}:#{pane_surface_count}'
	python "$text_client_driver" \
		--mux "$mux_bin" --runtime "$fixture" --target "=$text_client_session" \
		--output "$fixture/ssh/text-client.raw" \
		--ready "$fixture/ssh/text-client.ready" \
		--release "$fixture/ssh/text-client.release" \
		--initial-marker 'TXT wayland:presentation:2' \
		--toggled-marker 'TXT wayland:console:2' \
		--proof-option @engineos-ssh-text-client \
		--ssh "$(command -v ssh)" --ssh-port "$ssh_port" \
		--ssh-key "$fixture/ssh/client-key" --ssh-user "$(id -un)" \
		--timeout 15 >"$fixture/ssh/text-client.log" 2>&1 &
	text_client_pid=$!
	for _ in {1..800}; do
		[[ -f "$fixture/ssh/text-client.ready" ]] && break
		kill -0 "$text_client_pid" >/dev/null 2>&1 || break
		sleep 0.02
	done
	[[ -f "$fixture/ssh/text-client.ready" ]] || {
		if kill -0 "$text_client_pid" >/dev/null 2>&1; then
			kill "$text_client_pid" >/dev/null 2>&1 || true
		fi
		wait "$text_client_pid" 2>/dev/null || true
		text_client_pid=""
		cat "$fixture/ssh/text-client.log" >&2 || true
		cat "$fixture/ssh/sshd.log" >&2 || true
		strings "$fixture/ssh/text-client.raw" >&2 || true
		die "SSH tmux tty client did not attach and drive prefix+v"
	}
	jq -e '.schema == "engineos/tmux-text-client-proof-v1" and
		.transport == "ssh" and .columns == 50 and .rows == 20 and
		.proof_option == "@engineos-ssh-text-client"' \
		"$fixture/ssh/text-client.ready" >/dev/null ||
		die "SSH tmux client did not publish its transport and PTY evidence"
	grep -aF 'TXT wayland:presentation:2' "$fixture/ssh/text-client.raw" >/dev/null &&
		grep -aF 'TXT wayland:console:2' "$fixture/ssh/text-client.raw" >/dev/null &&
		grep -aF 'Running as unit:' "$fixture/ssh/text-client.raw" >/dev/null ||
		die "SSH tmux client did not render console and presentation metadata"
	grep -F "Accepted publickey for $(id -un) from 127.0.0.1" \
		"$fixture/ssh/sshd.log" >/dev/null &&
		grep -E "Starting session: command( on pts/[0-9]+)? for $(id -un) from 127\\.0\\.0\\.1" \
			"$fixture/ssh/sshd.log" >/dev/null ||
		{
			cat "$fixture/ssh/sshd.log" >&2 || true
			die "SSH server did not authenticate and start the remote tmux command"
		}
	[[ "$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		show-option -gv @engineos-ssh-text-client 2>/dev/null || true)" == accepted ]] ||
		die "SSH tmux command prompt did not execute"
	for _ in {1..150}; do
		jq -e '.mux.presentation.view_mode == "console" and
			.mux.presentation.terminal_visible == true and
			.input.mode == "terminal"' "$fixture/engineos/shell-state.json" \
			>/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.mux.presentation.view_mode == "console" and
		.mux.presentation.terminal_visible == true and
		.input.mode == "terminal" and (.output_views | length) == 2' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "SSH-client prefix+v did not update the graphical shell"
	[[ "$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		display-message -p -t "$shell_pane_id" \
		'#{window_width}x#{window_height}')" == "$canonical_size" ]] ||
		die "SSH tmux client changed graphical canonical geometry"
	attached_size="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" list-clients -F \
		'#{client_name}|#{client_width}x#{client_height}|#{client_termname}' | \
		awk -F'|' '$1 !~ /^engineos-view-/ {print $2 "|" $3; exit}')"
	[[ "$attached_size" == '50x20|xterm-256color' ]] ||
		die "SSH tty did not retain its independent padded size: $attached_size"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		pane-presentation -t "$shell_pane_id" app
	for _ in {1..150}; do
		jq -e '.mux.presentation.view_mode == "presentation" and
			.input.mode == "graphical"' "$fixture/engineos/shell-state.json" \
			>/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.mux.presentation.view_mode == "presentation" and
		.input.mode == "graphical"' "$fixture/engineos/shell-state.json" \
		>/dev/null || die "presentation did not recover after SSH-client toggle"
	touch "$fixture/ssh/text-client.release"
	wait "$text_client_pid" || {
		cat "$fixture/ssh/text-client.log" >&2 || true
		die "SSH tmux client did not detach cleanly"
	}
	text_client_pid=""
	kill "$sshd_pid" >/dev/null 2>&1 || true
	wait "$sshd_pid" 2>/dev/null || true
	sshd_pid=""
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -g 'status-format[0]' 'ENGINE-STATUS #{session_name}'
	python - "$fixture/engineos/preview.sock" "$preview_png" \
		"$shell_pane_id" <<'PY'
import json
import socket
import sys
request = {
    "op": "show",
    "path": sys.argv[2],
    "owner": "forbidden-shell-image-authority",
    "pane": {"pane_id": sys.argv[3]},
}
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(3.0)
    client.connect(sys.argv[1])
    client.sendall((json.dumps(request) + "\n").encode())
    response = json.loads(client.recv(4096))
if response.get("status") != "error" or "owned by engine-mux" not in response.get("error", ""):
    raise SystemExit(f"native shell accepted direct pane image authority: {response}")
PY
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		ENGINEOS_MUX_MODE=native ENGINEOS_MUX_BIN="$mux_bin" \
		ENGINEOS_PREVIEW_OWNER="native-mux-lease-proof" \
		TMUX_PANE="$shell_pane_id" \
		"$ROOT/tools/engineos/engine-image-preview" --view "$preview_large_png"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		pane-image -t "$other_shell_pane" show "$preview_png" \
		"native-mux-second-pane-proof"
	for _ in {1..100}; do
		jq -e --arg first "$shell_pane_id" --arg second "$other_shell_pane" \
			'(.previews | length) == 2 and all(.previews[]; .mux_owned and
			  .mux_image_id > 0 and (.path | startswith("mux://pane/"))) and
			 ([.previews[].pane_id] | unique | sort) == ([$first, $second] | sort) and
			 all(.previews[] as $preview;
			   any(.mux.panes[]; .pane_id == $preview.pane_id and
			     .generation == $preview.generation and
			     .image.id == $preview.mux_image_id and
			     (($preview.pane_id != $first) or .image.bytes > 65536) and
			     .image.owner == $preview.owner and
			     .image.lease_client_id == $preview.lease_client_id and
			     .image.lease_view_id == $preview.lease_view_id) and
			   $preview.lease_client_id == .mux.frontend_client_id and
			   $preview.lease_view_id == .mux.client_view_id) and
			 any(.previews[]; .pane_id == $first and .visible == false) and
			 any(.previews[]; .pane_id == $second and .visible == true) and
			 ([.output_views[] | select(.preview_count == 1)] | length) == 1 and
			 ([.output_views[].preview_count] | add) == 1' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg first "$shell_pane_id" --arg second "$other_shell_pane" \
		'(.previews | length) == 2 and all(.previews[]; .mux_owned and
		 (.mux_image_id > 0)) and
		 ([.previews[].pane_id] | unique | sort) == ([$first, $second] | sort) and
		 any(.previews[]; .pane_id == $first and .visible == false) and
		 any(.previews[]; .pane_id == $second and .visible == true) and
		 ([.output_views[] | select(.preview_count == 1)] | length) == 1 and
		 ([.output_views[].preview_count] | add) == 1' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '{previews,output_views,mux:{frontend_client_id:.mux.frontend_client_id,
			client_view_id:.mux.client_view_id,panes:.mux.panes}}' \
			"$fixture/engineos/shell-state.json" >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		die "simultaneous pane previews were not keyed to their panes and output lease"
	}
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		pane-presentation -t "$shell_pane_id" console
	for _ in {1..100}; do
		jq -e --arg pane "$shell_pane_id" \
			'([.output_views[].preview_count] | add) == 2 and
			 any(.previews[]; .pane_id == $pane and .mux_owned and .visible)' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg pane "$shell_pane_id" \
		'([.output_views[].preview_count] | add) == 2 and
		 any(.previews[]; .pane_id == $pane and .mux_owned and .visible)' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "mux terminal image did not appear with its backing console"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		pane-presentation -t "$shell_pane_id" app
	for _ in {1..100}; do
		jq -e --arg pane "$shell_pane_id" \
			'([.output_views[].preview_count] | add) == 1 and
			 any(.previews[]; .pane_id == $pane and .mux_owned and
			   (.visible | not))' "$fixture/engineos/shell-state.json" \
			>/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg pane "$shell_pane_id" \
		'([.output_views[].preview_count] | add) == 1 and
		 any(.previews[]; .pane_id == $pane and .mux_owned and
		   (.visible | not))' "$fixture/engineos/shell-state.json" >/dev/null ||
		die "mux terminal image leaked above its graphical presentation"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		ENGINEOS_MUX_MODE=native ENGINEOS_MUX_BIN="$mux_bin" \
		TMUX_PANE="$shell_pane_id" \
		"$ROOT/tools/engineos/engine-image-preview" --hide \
		--owner "native-mux-lease-proof"
	for _ in {1..100}; do
		jq -e --arg pane "$other_shell_pane" \
			'(.previews | length) == 1 and .previews[0].mux_owned and
			 .previews[0].mux_image_id > 0 and .previews[0].pane_id == $pane and
			 .previews[0].owner == "native-mux-second-pane-proof" and
			 ([.output_views[].preview_count] | add) == 1' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg pane "$other_shell_pane" \
		'(.previews | length) == 1 and .previews[0].mux_owned and
		 .previews[0].mux_image_id > 0 and .previews[0].pane_id == $pane and
		 .previews[0].owner == "native-mux-second-pane-proof"' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "hiding one pane preview removed or mutated its sibling"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		pane-image -t "$other_shell_pane" hide "native-mux-second-pane-proof"
	primary_surface_id="$(jq -er '.windows[] | select(.bound == true and
		.app_id == "engineos.presentation-proof") | .surface_id' \
		"$fixture/engineos/shell-state.json")"
	secondary_surface_id="$(jq -er '.windows[] | select(.bound == true and
		.app_id == "engineos.presentation-tab-proof") | .surface_id' \
		"$fixture/engineos/shell-state.json")"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		select-pane-surface -t "$shell_pane_id" previous
	for _ in {1..100}; do
		jq -e --argjson surface "$primary_surface_id" \
			'.mux.presentation.active_surface_id == $surface and
			 any(.windows[]; .bound == true and .app_id ==
			   "engineos.presentation-proof" and .visible == true) and
			 any(.windows[]; .bound == true and .surface_role == "transient" and
			   .visible == true) and
			 all(.windows[]; .bound == false or .app_id !=
			   "engineos.presentation-tab-proof" or .visible == false)' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --argjson surface "$primary_surface_id" \
		'.mux.presentation.active_surface_id == $surface and
		 any(.windows[]; .bound == true and .surface_role == "transient" and
		   .visible == true)' "$fixture/engineos/shell-state.json" >/dev/null ||
		die "authoritative previous-tab selection did not activate its surface group"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		select-pane-surface -t "$shell_pane_id" next
	for _ in {1..100}; do
		jq -e --argjson surface "$secondary_surface_id" \
			'.mux.presentation.active_surface_id == $surface and
			 any(.windows[]; .bound == true and .app_id ==
			   "engineos.presentation-tab-proof" and .visible == true) and
			 all(.windows[]; .bound == false or .surface_role != "transient" or
			   .visible == false)' "$fixture/engineos/shell-state.json" \
			>/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --argjson surface "$secondary_surface_id" \
		'.mux.presentation.active_surface_id == $surface and
		 any(.windows[]; .bound == true and .app_id ==
		   "engineos.presentation-tab-proof" and .visible == true)' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "authoritative next-tab selection did not activate its surface group"
	scoped_client_pid="$(jq -er '.windows[] | select(.bound == true and
		.app_id == "engineos.presentation-tab-proof") | .client_pid' \
		"$fixture/engineos/shell-state.json")"
	[[ "$scoped_client_pid" =~ ^[1-9][0-9]*$ ]] ||
		die "native shell did not expose the scoped Wayland client PID"
	kill -USR1 "$scoped_client_pid"
	for _ in {1..100}; do
		jq -e '.mux.presentation.surface_tabs == 1 and
			([.windows[] | select(.bound == true)] | length) == 2 and
			any(.windows[]; .bound == true and .surface_role == "toplevel" and
			  .app_id == "engineos.presentation-proof" and .visible == true) and
			any(.windows[]; .bound == true and .surface_role == "transient" and
			  .visible == true)' "$fixture/engineos/shell-state.json" \
			>/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.mux.presentation.surface_tabs == 1 and
		([.windows[] | select(.bound == true)] | length) == 2 and
		all(.windows[]; .bound == false or .visible == true)' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '{mux,input,windows}' "$fixture/engineos/shell-state.json" >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		die "closing the active pane-local tab did not promote its sibling"
	}
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		pane-presentation -t "$shell_pane_id" console
	for _ in {1..100}; do
		jq -e '.mux.presentation.view_mode == "console" and
			.mux.presentation.terminal_visible == true and
			.input.mode == "terminal" and
			all(.windows[]; .bound == false or .visible == false)' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.mux.presentation.view_mode == "console" and
		.mux.presentation.terminal_visible == true and .input.mode == "terminal"' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '{mux,input,windows}' "$fixture/engineos/shell-state.json" >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		die "native console toggle did not hide the scoped Wayland surface"
	}
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		pane-presentation -t "$shell_pane_id" app
	for _ in {1..100}; do
		jq -e '.mux.presentation.view_mode == "presentation" and
			.mux.presentation.terminal_visible == false and
			.input.mode == "graphical"' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.mux.presentation.view_mode == "presentation" and
		.mux.presentation.terminal_visible == false and .input.mode == "graphical"' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "native application toggle did not restore the scoped Wayland surface"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		signal-pane-app -t "$shell_pane_id" TERM
	for _ in {1..150}; do
		pane_state="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
			"$mux_bin" display-message -p -t "$shell_pane_id" \
			'#{pane_presentation}|#{pane_view_mode}|#{pane_surface_count}')"
		jq -e '.mux.presentation.type == "terminal" and
			.mux.presentation.terminal_visible == true and
			.mux.presentation.popups == 0 and
			.input.mode == "terminal" and
			all(.windows[]; .bound == false)' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 &&
			[[ "$pane_state" == 'terminal|presentation|0' ]] && break
		sleep 0.02
	done
	[[ "$pane_state" == 'terminal|presentation|0' ]] ||
		die "scoped Wayland application exit did not restore the pane console"
	printf -v game_wrapper_command \
		'ENGINEOS_MUX_MODE=native ENGINEOS_MUX_BIN=%q ENGINEOS_LOG_DIR=%q %q pane launch --game -- env WAYLAND_DISPLAY=%q %q' \
		"$mux_bin" "$fixture" "$SCRIPT_DIR/app.sh" \
		"$fixture/$wayland_display" \
		"$fixture/bin/engineos-wayland-presentation-client"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -t "$shell_pane_id" -l "$game_wrapper_command"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -t "$shell_pane_id" Enter
	for _ in {1..150}; do
		jq -e '.mux.presentation.type == "game" and
			.mux.presentation.view_mode == "presentation" and
			.mux.presentation.mapped == true and .input.mode == "game" and
			.input.capture == true and .cursor.locked == true and
			([.output_views[] | select(.owns_selected_presentation)] | length) == 1' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.mux.presentation.type == "game" and .input.mode == "game" and
		.input.capture == true and .cursor.locked == true' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '{mux: .mux.presentation,input,cursor,windows}' \
			"$fixture/engineos/shell-state.json" >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		die "native game launch did not acquire direct presentation input and capture"
	}
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		ENGINEOS_MUX_MODE=native ENGINEOS_MUX_BIN="$mux_bin" \
		"$SCRIPT_DIR/app.sh" pane view --pane "$shell_pane_id" console
	for _ in {1..100}; do
		jq -e '.mux.presentation.type == "game" and
			.mux.presentation.view_mode == "console" and
			.input.mode == "terminal" and .input.capture == false and
			.cursor.locked == false' "$fixture/engineos/shell-state.json" \
			>/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.mux.presentation.view_mode == "console" and
		.input.mode == "terminal" and .input.capture == false' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "native game console toggle did not release capture"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		ENGINEOS_MUX_MODE=native ENGINEOS_MUX_BIN="$mux_bin" \
		"$SCRIPT_DIR/app.sh" pane view --pane "$shell_pane_id" app
	for _ in {1..100}; do
		jq -e '.mux.presentation.type == "game" and
			.mux.presentation.view_mode == "presentation" and
			.input.mode == "game" and .input.capture == true and
			.cursor.locked == true' "$fixture/engineos/shell-state.json" \
			>/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.input.mode == "game" and .input.capture == true and
		.cursor.locked == true' "$fixture/engineos/shell-state.json" >/dev/null ||
		die "native game presentation toggle did not restore capture"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		ENGINEOS_MUX_MODE=native ENGINEOS_MUX_BIN="$mux_bin" \
		"$SCRIPT_DIR/app.sh" pane signal --pane "$shell_pane_id" TERM
	for _ in {1..150}; do
		pane_state="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
			"$mux_bin" display-message -p -t "$shell_pane_id" \
			'#{pane_presentation}|#{pane_view_mode}|#{pane_surface_count}')"
		[[ "$pane_state" == 'terminal|presentation|0' ]] && break
		sleep 0.02
	done
	[[ "$pane_state" == 'terminal|presentation|0' ]] ||
		die "native game exit did not restore the pane console"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		ENGINEOS_MUX_MODE=native ENGINEOS_MUX_BIN="$mux_bin" \
		"$SCRIPT_DIR/app.sh" pane respawn --pane "$shell_pane_id"
	for _ in {1..150}; do
		jq -e '.mux.presentation.type == "game" and
			.mux.presentation.mapped == true and .input.mode == "game" and
			.input.capture == true' "$fixture/engineos/shell-state.json" \
			>/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.mux.presentation.type == "game" and .input.mode == "game" and
		.input.capture == true' "$fixture/engineos/shell-state.json" >/dev/null ||
		die "native game respawn did not preserve its presentation type"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		ENGINEOS_MUX_MODE=native ENGINEOS_MUX_BIN="$mux_bin" \
		"$SCRIPT_DIR/app.sh" pane signal --pane "$shell_pane_id" TERM
	for _ in {1..150}; do
		jq -e '.mux.presentation.type == "terminal" and
			.input.mode == "terminal" and .input.capture == false' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.mux.presentation.type == "terminal" and
		.input.mode == "terminal" and .input.capture == false' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "native game respawn exit did not restore terminal input"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		list-clients -F '#{client_name} #{client_flags}' \
		>"$fixture/graphical-clients.txt"
	[[ "$(grep -Ec '^engineos-view-[0-9]+ .*focused' \
		"$fixture/graphical-clients.txt")" == 1 ]] &&
		[[ "$(grep -Ec '^engineos-view-[0-9]+ .*ignore-size' \
			"$fixture/graphical-clients.txt")" == 1 ]] &&
		[[ "$(cut -d' ' -f1 "$fixture/graphical-clients.txt" | \
			sort -u | wc -l)" == 2 ]] &&
		[[ "$(wc -l <"$fixture/graphical-clients.txt")" == 2 ]] ||
		die "native shell output clients did not preserve focused size ownership"
	shell_client_name="$(awk '$0 ~ /focused/ {print $1; exit}' \
		"$fixture/graphical-clients.txt")"
	[[ -n "$shell_client_name" ]] ||
		die "native shell focused graphical client name was unavailable"
	for _ in {1..500}; do
		updated_native_revision="$(jq -er '.mux.grid.revision' \
			"$fixture/engineos/shell-state.json")"
		if [[ "$updated_native_revision" == "$stable_revision" ]]; then
			stable_count=$((stable_count + 1))
		else
			stable_revision="$updated_native_revision"
			stable_count=0
		fi
		[[ "$stable_count" -ge 5 ]] && break
		sleep 0.02
	done
	[[ "$stable_count" -ge 5 ]] ||
		die "native shell grid did not settle before UI overlay proof"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		display-menu -c "$shell_client_name" -T SHELL-MENU \
		Pick p 'set-option -g @engineos-shell-menu picked' \
		>"$fixture/menu.log" 2>&1 &
	overlay_pid=$!
	for _ in {1..100}; do
		jq -e '.mux.ui.rendered == true and .mux.ui.menu_active == true and
			.mux.ui.menu_width > 0 and .mux.ui.menu_height > 0' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.mux.ui.menu_active == true and .mux.ui.menu_width > 0 and
		.mux.ui.menu_height > 0' "$fixture/engineos/shell-state.json" >/dev/null || {
		jq '{mux:{ui:.mux.ui,client_view_id:.mux.client_view_id,
			ui_invalidation_count:.mux.ui_invalidation_count,
			last_ui_invalidated_view_id:.mux.last_ui_invalidated_view_id},
			output_views,last_reason}' \
			"$fixture/engineos/shell-state.json" >&2 || true
		sed -n '1,80p' "$fixture/menu.log" >&2 || true
		XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
			list-clients -F '#{client_name}|#{client_tty}|#{client_flags}' >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		die "native shell did not consume and render menu UI invalidation"
	}
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		command-prompt -t "$shell_client_name" \
		>"$fixture/prompt.log" 2>&1 &
	prompt_pid=$!
	for _ in {1..100}; do
		jq -e '.mux.ui.rendered == true and .mux.ui.mode == "prompt" and
			.mux.ui.prompt_active == true and .mux.ui.menu_active == false' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '.mux.ui.mode == "prompt" and .mux.ui.prompt_active == true and
		.mux.ui.menu_active == false' "$fixture/engineos/shell-state.json" \
		>/dev/null || {
		jq '.mux.ui' "$fixture/engineos/shell-state.json" >&2 || true
		sed -n '1,80p' "$fixture/prompt.log" >&2 || true
		tail -80 "$fixture/shell-native.log" >&2 || true
		die "native shell did not consume and render prompt UI invalidation"
	}
	shell_pane_id="$(jq -er '.mux.pane_id' \
		"$fixture/engineos/shell-state.json")"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -g prefix C-a
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		bind-key -T prefix y set-option -g @engineos-focus-restore accepted
	XDG_RUNTIME_DIR="$fixture" "$build_dir/engine-muxctl" keys \
		"$shell_pane_id" C-a y >"$fixture/focus-restore-keys.json"
	for _ in {1..100}; do
		restore_proof="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
			"$mux_bin" show-option -gv @engineos-focus-restore 2>/dev/null || true)"
		XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
			list-clients -F '#{client_flags}' >"$fixture/restored-client-flags.txt"
		if [[ "$restore_proof" == accepted &&
				"$(grep -c 'focused' "$fixture/restored-client-flags.txt")" == 1 &&
				"$(grep -c 'ignore-size' "$fixture/restored-client-flags.txt")" == 1 ]]; then
			break
		fi
		sleep 0.02
	done
	[[ "$restore_proof" == accepted &&
		"$(grep -c 'focused' "$fixture/restored-client-flags.txt")" == 1 &&
		"$(grep -c 'ignore-size' "$fixture/restored-client-flags.txt")" == 1 ]] ||
		{
		cat "$fixture/restored-client-flags.txt" >&2
		XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
			list-clients -F '#{client_name} #{client_flags}' >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		die "temporary graphical client did not restore focused size ownership"
	}
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -g prefix C-b
	initial_native_revision="$(jq -er '.mux.grid.revision' \
		"$fixture/engineos/shell-state.json")"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -t "$shell_pane_id" "printf EVENT-DRIVEN-DAMAGE" Enter
	updated_native_revision="$initial_native_revision"
	for _ in {1..100}; do
		updated_native_revision="$(jq -er '.mux.grid.revision' \
			"$fixture/engineos/shell-state.json")"
		[[ "$updated_native_revision" -gt "$initial_native_revision" ]] && break
		sleep 0.02
	done
	[[ "$updated_native_revision" -gt "$initial_native_revision" ]] || {
		jq '{mux,last_reason}' "$fixture/engineos/shell-state.json" >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		die "native shell did not consume event-driven grid damage"
	}
	if [[ "$shell_renderer" == gles2 ]]; then
		jq -e '.mux.grid.damaged_cells > 0 and
			.mux.grid.damaged_cells < (.mux.grid.columns * .mux.grid.rows) and
			.mux.grid.atlas_entries > 0 and .mux.grid.frame > 1' \
			"$fixture/engineos/shell-state.json" >/dev/null ||
			die "GLES2 terminal renderer did not retain sparse cell damage"
	fi
	local focused_session nonfocused_output nonfocused_client
	local output_session_id output_session_pane output_grid_revision
	local updated_output_grid_revision output_renderer_frame
	local updated_output_renderer_frame output_ui_frame updated_output_ui_frame
	focused_session="$(jq -er '.mux.session_id' \
		"$fixture/engineos/shell-state.json")"
	nonfocused_output="$(jq -er \
		'.output_views[] | select(.focused == false) | .output' \
		"$fixture/engineos/shell-state.json")"
	nonfocused_client="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" list-clients -F '#{client_name}|#{client_tty}' | \
		awk -F '|' -v output="$nonfocused_output" '$2 == output { print $1; exit }')"
	[[ "$nonfocused_client" == engineos-view-* ]] ||
		die "shell output did not retain an addressable synthetic tmux client"
	output_session_id="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" new-session -d -s shell-output-model -P -F '#{session_id}')"
	output_session_pane="$(XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" \
		"$mux_bin" display-message -p -t shell-output-model: '#{pane_id}')"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		switch-client -c "$nonfocused_client" -t "$output_session_id"
	for _ in {1..150}; do
		jq -e --arg output "$nonfocused_output" \
			--arg session "$output_session_id" --arg pane "$output_session_pane" \
			--arg focused_session "$focused_session" \
			'.mux.session_id == $focused_session and
			 (.output_views | map(.session_id) | unique | length) == 2 and
			 any(.output_views[]; .output == $output and .model_ready and
			   .session_id == $session and .pane_id == $pane and .pane_count == 1 and
			   .grid_ready_count == 1 and .grid_subscribed_count == 1 and
			   .grid_revision > 0 and .rendered_pane_count == 1 and
			   .console_scene_count == 1 and .selected_renderer_frame > 0) and
			 any(.output_views[]; .focused and .session_id == $focused_session)' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg output "$nonfocused_output" \
		--arg session "$output_session_id" --arg pane "$output_session_pane" \
		--arg focused_session "$focused_session" \
		'.mux.session_id == $focused_session and
		 (.output_views | map(.session_id) | unique | length) == 2 and
		 any(.output_views[]; .output == $output and .model_ready and
		   .session_id == $session and .pane_id == $pane and .pane_count == 1 and
		   .grid_ready_count == 1 and .grid_subscribed_count == 1 and
		   .grid_revision > 0 and .rendered_pane_count == 1 and
		   .console_scene_count == 1 and .selected_renderer_frame > 0 and
		   .ui.ready and .ui.rendered and .ui.frame > 0) and
		 any(.output_views[]; .focused and .session_id == $focused_session and
		   .ui.ready and .ui.rendered and .ui.frame > 0) and
		 ((.output_views[] | select(.focused)) as $focused |
		  .input.view_id == $focused.view_id and
		  .input.pane_id == $focused.pane_id and
		  .input.pane_generation == $focused.pane_generation)' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '{mux:{session_id:.mux.session_id,client_view_id:.mux.client_view_id},output_views}' \
			"$fixture/engineos/shell-state.json" >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		 die "shell did not retain independent authoritative output models"
	}
	output_ui_frame="$(jq -er --arg output "$nonfocused_output" \
		'.output_views[] | select(.output == $output) | .ui.frame' \
		"$fixture/engineos/shell-state.json")"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		set-option -t shell-output-model status-left 'OUTPUT-LOCAL-UI '
	updated_output_ui_frame="$output_ui_frame"
	for _ in {1..150}; do
		updated_output_ui_frame="$(jq -er --arg output "$nonfocused_output" \
			'.output_views[] | select(.output == $output) | .ui.frame' \
			"$fixture/engineos/shell-state.json")"
		jq -e --arg output "$nonfocused_output" \
			'any(.output_views[]; .output == $output and
			  (.ui.status_text | contains("OUTPUT-LOCAL-UI"))) and
			 all(.output_views[]; .output == $output or
			  (.ui.status_text | contains("OUTPUT-LOCAL-UI") | not))' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 &&
			[[ "$updated_output_ui_frame" -gt "$output_ui_frame" ]] && break
		sleep 0.02
	done
	if ! [[ "$updated_output_ui_frame" -gt "$output_ui_frame" ]] || !
		jq -e --arg output "$nonfocused_output" \
			'any(.output_views[]; .output == $output and
			  (.ui.status_text | contains("OUTPUT-LOCAL-UI"))) and
			 all(.output_views[]; .output == $output or
			  (.ui.status_text | contains("OUTPUT-LOCAL-UI") | not))' \
			"$fixture/engineos/shell-state.json" >/dev/null; then
		jq '{output_views,last_reason}' "$fixture/engineos/shell-state.json" >&2 || true
		tail -100 "$fixture/shell-native.log" >&2 || true
		 die "nonfocused output UI did not retain and render its own status model"
	fi
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		launch-pane-app -t "$output_session_pane" -- env \
		WAYLAND_DISPLAY="$fixture/$wayland_display" \
		"$fixture/bin/engineos-wayland-presentation-client"
	for _ in {1..150}; do
		jq -e --arg output "$nonfocused_output" --arg pane "$output_session_pane" \
			'any(.output_views[]; .output == $output and
			  .pane_id == $pane and .owns_selected_presentation and
			  .bound_presentation_surface_count == 1 and
			  .presentation_surface_count == 1) and
			 all(.output_views[]; .output == $output or
			  .presentation_surface_count == 0) and
			 ((.output_views[] | select(.focused)) as $focused |
			  .input.mode == "terminal" and .input.view_id == $focused.view_id and
			  .input.pane_id == $focused.pane_id and
			  .input.view_id != (.output_views[] | select(.output == $output) | .view_id))' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg output "$nonfocused_output" --arg pane "$output_session_pane" \
		'any(.output_views[]; .output == $output and .pane_id == $pane and
		  .owns_selected_presentation and .presentation_surface_count == 1) and
		 all(.output_views[]; .output == $output or
		  .presentation_surface_count == 0) and
		 .input.mode == "terminal" and
		 .input.view_id != (.output_views[] | select(.output == $output) | .view_id)' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '{input,output_views,windows,last_reason}' \
			"$fixture/engineos/shell-state.json" >&2 || true
		tail -120 "$fixture/shell-native.log" >&2 || true
		die "nonfocused presentation was not routed to its retained output model"
	}
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		signal-pane-app -t "$output_session_pane" TERM
	for _ in {1..150}; do
		jq -e '[.output_views[].presentation_surface_count] | add == 0' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e '[.output_views[].presentation_surface_count] | add == 0' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "nonfocused presentation exit did not restore its output console"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		pane-image -t "$output_session_pane" show "$preview_png" \
		"nonfocused-output-preview"
	for _ in {1..100}; do
		jq -e --arg output "$nonfocused_output" --arg pane "$output_session_pane" \
			'(.previews | length) == 1 and .previews[0].mux_owned and
			 .previews[0].mux_image_id > 0 and .previews[0].pane_id == $pane and
			 (.previews[0] as $preview |
			  any(.output_views[]; .output == $output and .preview_count == 1 and
			   .view_id == $preview.lease_view_id) and
			  all(.output_views[]; .output == $output or .preview_count == 0))' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg output "$nonfocused_output" --arg pane "$output_session_pane" \
		'(.previews | length) == 1 and .previews[0].mux_owned and
		 .previews[0].mux_image_id > 0 and .previews[0].pane_id == $pane and
		 (.previews[0] as $preview |
		  any(.output_views[]; .output == $output and .preview_count == 1 and
		   .view_id == $preview.lease_view_id) and
		  all(.output_views[]; .output == $output or .preview_count == 0))' \
		"$fixture/engineos/shell-state.json" >/dev/null ||
		die "nonfocused preview did not use its retained output lease"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		pane-image -t "$output_session_pane" hide "nonfocused-output-preview"
	output_grid_revision="$(jq -er --arg output "$nonfocused_output" \
		'.output_views[] | select(.output == $output) | .grid_revision' \
		"$fixture/engineos/shell-state.json")"
	output_renderer_frame="$(jq -er --arg output "$nonfocused_output" \
		'.output_views[] | select(.output == $output) | .selected_renderer_frame' \
		"$fixture/engineos/shell-state.json")"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		send-keys -t "$output_session_pane" \
		"printf NONFOCUSED-OUTPUT-GRID-DAMAGE" Enter
	updated_output_grid_revision="$output_grid_revision"
	updated_output_renderer_frame="$output_renderer_frame"
	for _ in {1..150}; do
		updated_output_grid_revision="$(jq -er --arg output "$nonfocused_output" \
			'.output_views[] | select(.output == $output) | .grid_revision' \
			"$fixture/engineos/shell-state.json")"
		updated_output_renderer_frame="$(jq -er --arg output "$nonfocused_output" \
			'.output_views[] | select(.output == $output) | .selected_renderer_frame' \
			"$fixture/engineos/shell-state.json")"
		[[ "$updated_output_grid_revision" -gt "$output_grid_revision" &&
			"$updated_output_renderer_frame" -gt "$output_renderer_frame" ]] && break
		sleep 0.02
	done
	[[ "$updated_output_grid_revision" -gt "$output_grid_revision" &&
		"$updated_output_renderer_frame" -gt "$output_renderer_frame" ]] ||
		die "nonfocused output grid damage did not advance its retained renderer"
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		switch-client -c "$nonfocused_client" -t "$focused_session"
	for _ in {1..150}; do
		jq -e --arg session "$focused_session" \
			'all(.output_views[]; .session_id == $session)' \
			"$fixture/engineos/shell-state.json" >/dev/null 2>&1 && break
		sleep 0.02
	done
	jq -e --arg session "$focused_session" \
		'all(.output_views[]; .session_id == $session)' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq --arg session "$focused_session" \
			'{expected_session:$session,mux_session:.mux.session_id,
			  output_views:[.output_views[] | {view_id,output,session_id,focused}],
			  input,last_reason}' "$fixture/engineos/shell-state.json" >&2 || true
		XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
			list-clients -F '#{client_name}|#{client_tty}|#{session_id}|#{client_flags}' \
			>&2 || true
		die "shell output model did not follow its synthetic client reattachment"
	}
	XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
		kill-session -t "$output_session_id"
	wait "$shell_pid" || die "engineos-shell native damage run failed"
	shell_pid=""
	if XDG_RUNTIME_DIR="$fixture" TMUX_TMPDIR="$fixture" "$mux_bin" \
			list-clients -F '#{client_name}' | grep -F 'engineos-view-' >/dev/null; then
		die "graphical tmux clients survived shell output teardown"
	fi
	jq -e '.mux.mode == "native" and .mux.connected == true and
		(.mux.session_id | startswith("$")) and .mux.client_view_id > 0 and
		.mux.revision >= 1 and .mux.generation == 1 and
		.mux.grid.revision >= 1 and .mux.grid.columns > 0 and
		.mux.grid.rows > 0 and .mux.grid.nonblank_cells > 0 and
		.mux.grid.rendered == true and .mux.grid.pixel_width > 0 and
		.mux.grid.pixel_height > 0 and .mux.grid.glyph_cells > 0 and
		.mux.ui.columns > 0 and .mux.ui.rows > .mux.grid.rows and
		.mux.ui.status_y == (.mux.ui.rows - 1) and .mux.ui.status_rows == 1 and
		.mux.ui.rendered == true and .mux.ui.mode == "prompt" and
		.mux.ui.prompt_active == true and .mux.ui.message_active == false and
		.mux.ui.menu_active == false' \
		"$fixture/engineos/shell-state.json" >/dev/null || {
		jq '.mux' "$fixture/engineos/shell-state.json" >&2 || true
		die "shell state did not expose native mux revision evidence"
	}

	cleanup_mux_test
	trap - EXIT RETURN
	printf 'engine-mux protocol contract test passed\n'
}

run_dev_workflow() {
	local fixture="${TMPDIR:-/tmp}/engineos-change-plan-test-$$"
	local base head out
	trap 'rm -rf "$fixture"' RETURN
	mkdir -p "$fixture/packages/engineos-base" "$fixture/packages/engineos-app" \
		"$fixture/tools/scripts" "$fixture/tools/hooks" "$fixture/tools/engineos"
	git init -q "$fixture"
	git -C "$fixture" config user.name EngineOS-Test
	git -C "$fixture" config user.email engineos-test@example.invalid
	cat >"$fixture/packages/engineos-base/PKGBUILD" <<'EOF'
pkgname=engineos-base
pkgver=1
pkgrel=1
depends=()
EOF
	cat >"$fixture/packages/engineos-app/PKGBUILD" <<'EOF'
pkgname=engineos-app
pkgver=1
pkgrel=1
depends=('engineos-base')
EOF
	git -C "$fixture" add packages
	git -C "$fixture" commit -qm base
	base="$(git -C "$fixture" rev-parse HEAD)"
	printf '\n# committed app change\n' >>"$fixture/packages/engineos-app/PKGBUILD"
	git -C "$fixture" add packages/engineos-app/PKGBUILD
	git -C "$fixture" commit -qm app-change
	head="$(git -C "$fixture" rev-parse HEAD)"
	out="$(python "$ROOT/tools/scripts/change_plan.py" --root "$fixture" --range "$base..$head")"
	python - "$out" <<'PY'
import json, sys
plan = json.loads(sys.argv[1])
assert plan["direct_packages"] == ["engineos-app"]
assert plan["packages"] == ["engineos-base", "engineos-app"]
assert plan["files"] == ["packages/engineos-app/PKGBUILD"]
PY
	printf '# dirty\n' >>"$fixture/packages/engineos-app/PKGBUILD"
	if python "$ROOT/tools/scripts/change_plan.py" --root "$fixture" \
			--range "$base..$head" --check-dirty >/dev/null 2>&1; then
		die "committed-range planner accepted relevant dirty files"
	fi
	git -C "$fixture" restore packages/engineos-app/PKGBUILD
	printf 'untracked\n' >"$fixture/packages/engineos-app/local note.txt"
	if python "$ROOT/tools/scripts/change_plan.py" --root "$fixture" \
			--range "$base..$head" --check-dirty >/dev/null 2>&1; then
		die "committed-range planner accepted a relevant untracked path with spaces"
	fi
	rm -f "$fixture/packages/engineos-app/local note.txt"

	cp "$ROOT/tools/hooks/git_pre_push_deploy.sh" "$fixture/tools/hooks/"
	cat >"$fixture/tools/engineos/eos" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$ENGINEOS_FAKE_DEPLOY_ARGS"
EOF
	chmod +x "$fixture/tools/hooks/git_pre_push_deploy.sh" "$fixture/tools/engineos/eos"
	ENGINEOS_FAKE_DEPLOY_ARGS="$fixture/deploy.args" \
		bash -c 'cd "$1" && tools/hooks/git_pre_push_deploy.sh origin test-url' bash "$fixture" <<EOF
refs/heads/main $head refs/heads/main $base
EOF
	grep -F "dev apply --ref-update refs/heads/main $head refs/heads/main $base" "$fixture/deploy.args" >/dev/null ||
		die "pre-push hook did not preserve the pushed commit range"
	printf 'committed-range deploy workflow test passed\n'
}

run_agent() {
	"$SCRIPT_DIR/preflight.sh" repo --package engineos-tools >/dev/null
	"$SCRIPT_DIR/package_lint.sh" --package engineos-tools >/dev/null
	python -m py_compile "$SCRIPT_DIR/agent_router.py" "$SCRIPT_DIR/agent_hygiene.py"
	"$ROOT/tools/engineos/eos-agent" hygiene check >/dev/null
	"$ROOT/tools/engineos/eos-agent" list | grep -Fx oracle >/dev/null ||
		die "structured agent router did not list oracle"
	"$ROOT/tools/engineos/eos-agent" show pergame-quake | grep -F '"proof": "eos-game quake proof"' >/dev/null ||
		die "structured agent router did not expose Quake proof metadata"
	for role in oracle overseer compiler admin-shell engine-builder pergame-quake cleaner; do
		[[ -f "$ROOT/.agents/roles/$role/AGENTS.md" ]] || die "missing role doc: $role"
		[[ -f "$ROOT/.agents/skills/$role/SKILL.md" ]] || die "missing role skill: $role"
	done
	printf 'agent harness smoke test passed\n'
}

run_agent_hygiene() {
	local out
	out="$("$ROOT/tools/engineos/eos-agent" hygiene check --json)"
	grep -F '"status":"pass"' <<<"$out" >/dev/null ||
		die "lean agent hygiene check did not pass"
	printf 'agent hygiene smoke test passed\n'
}

run_observability() {
	local tmp_dir="${TMPDIR:-/tmp}/engineos-observability-lean-$$"
	local out="$tmp_dir/out.txt"
	trap 'rm -rf "$tmp_dir"' RETURN
	mkdir -p "$tmp_dir"
	ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir" "$SCRIPT_DIR/observability.sh" enable >/dev/null
	ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir" "$SCRIPT_DIR/observability.sh" record \
		--kind agent-route --source router --role admin-shell --risk medium \
		--request "private request text" >/dev/null
	ENGINEOS_OBSERVABILITY_STATE_DIR="$tmp_dir" "$SCRIPT_DIR/observability.sh" metrics --format json >"$out"
	grep -F '"schema":"engineos-observability-metrics-v1"' "$out" >/dev/null ||
		die "observability did not emit the lean v1 metrics schema"
	grep -F '"kind":"agent-route"' "$out" >/dev/null ||
		die "observability metrics did not count route metadata"
	if grep -F 'private request text' "$tmp_dir/events.jsonl" >/dev/null; then
		die "observability stored raw request text"
	fi
	printf 'observability smoke test passed\n'
}

run_agent_route() {
	local out="${TMPDIR:-/tmp}/engineos-agent-route-$$.txt"
	trap 'rm -f "$out"' RETURN
	"$ROOT/tools/engineos/eos-agent" route "compile a C++ repo from source" >"$out"
	grep -F 'role=compiler' "$out" >/dev/null || die "router did not select compiler"
	"$ROOT/tools/engineos/eos-agent" route "quake generator package and wayland focus" >"$out"
	grep -F 'role=pergame-quake' "$out" >/dev/null || die "router specificity did not select Quake"
	"$ROOT/tools/engineos/eos-agent" route "manage wayland windows and focus" >"$out"
	grep -F 'role=admin-shell' "$out" >/dev/null || die "router did not select admin-shell"
	"$ROOT/tools/engineos/eos-agent" route "clean up stale role docs" >"$out"
	grep -F 'role=cleaner' "$out" >/dev/null || die "router did not select cleaner"
	printf 'agent route smoke test passed\n'
}

run_installed_preflight() {
  local tmp_dir="/tmp/engineos-installed-preflight-$$"
  local root_dir="$tmp_dir/usr"
  local bin_dir="$tmp_dir/usr/bin"
  local script_dir="$tmp_dir/usr/lib/engineos/scripts"
  local eos_dir="$tmp_dir/usr/lib/engineos/eos"
  local out="$tmp_dir/preflight.txt"

  cleanup_installed_preflight() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_installed_preflight RETURN

	mkdir -p "$bin_dir" "$script_dir" "$eos_dir"
  cp "$ROOT/tools/engineos/eos" "$bin_dir/eos"
  for cmd in eos-doctor eos-build eos-agent eos-observe eos-source-test eos-test; do
    cp "$ROOT/tools/engineos/eos-wrapper" "$bin_dir/$cmd"
  done
  cp "$ROOT/tools/engineos/engineos" "$bin_dir/engineos"
  cp "$ROOT/tools/scripts/"*.sh "$script_dir/"
  cp "$ROOT/tools/scripts/agent_router.py" "$ROOT/tools/scripts/agent_hygiene.py" "$script_dir/"
  cp -R "$ROOT/tools/eos"/. "$eos_dir/"
	install -Dm755 "$ROOT/tests/tmux-text-client.py" \
		"$eos_dir/test/tmux-text-client.py"
	chmod +x "$bin_dir/"* "$script_dir/"*.sh "$script_dir/"*.py "$eos_dir"/*/*.sh

  ENGINEOS_INSTALLED_IMAGE=true \
    ENGINEOS_ROOT="$root_dir" \
    ENGINEOS_INSTALLED_BIN_DIR="$bin_dir" \
    ENGINEOS_INSTALLED_SCRIPT_DIR="$script_dir" \
    ENGINEOS_INSTALLED_EOS_DIR="$eos_dir" \
		"$SCRIPT_DIR/preflight.sh" scripts >"$out"

  grep -F "OK   $bin_dir/eos" "$out" >/dev/null ||
    die "installed preflight did not check installed eos dispatcher"
  grep -F "OK   $bin_dir/eos-doctor" "$out" >/dev/null ||
    die "installed preflight did not check installed eos-doctor"
  grep -F "OK   $bin_dir/eos-source-test" "$out" >/dev/null ||
    die "installed preflight did not check installed eos-source-test"
  grep -F "OK   $eos_dir/proof/proof.sh" "$out" >/dev/null ||
    die "installed preflight did not check installed proof module"
  grep -F 'Preflight summary: 0 failure(s)' "$out" >/dev/null ||
    die "installed preflight did not pass"

  printf 'installed preflight test passed\n'
}

run_ci() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-ci-test-$$"
  local out="$tmp_dir/ci.txt"

  cleanup_ci() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_ci RETURN
  mkdir -p "$tmp_dir"

  "$ROOT/tools/engineos/eos-ci" local --dry-run \
    --package engineos-tools \
    --package engineos-shell \
    --package engineos-tools \
    --test agent \
    --install \
    --clean-generated >"$out"
  grep -F 'EngineOS local CI pipeline' "$out" >/dev/null ||
    die "ci dry-run did not print pipeline header"
  grep -F 'DRY-RUN ' "$out" >/dev/null ||
    die "ci dry-run did not print commands"
  grep -F 'eos-test agent' "$out" >/dev/null ||
    die "ci dry-run did not include requested test scope"
  grep -F 'preflight.sh repo --package engineos-tools --package engineos-shell' "$out" >/dev/null ||
    die "ci dry-run did not include selected packages in preflight command"
  grep -F 'eos-build repo --package engineos-tools --package engineos-shell' "$out" >/dev/null ||
    die "ci dry-run did not include repeatable package rebuild command"
  [[ "$(grep -c '^    - engineos-tools$' "$out")" -eq 1 ]] ||
    die "ci dry-run did not ignore duplicate package selection"
  grep -F 'sudo -n pacman -U --noconfirm' "$out" >/dev/null ||
    die "ci dry-run did not include reinstall command"
  grep -F 'sudo -n systemctl disable --now engineos-engine-runner.service' "$out" >/dev/null ||
    die "ci dry-run did not stop the retired engine runner before reinstall"
  grep -F 'sudo -n pacman -R --noconfirm engineos-engine-runner engineos-engine-runner-debug' "$out" >/dev/null ||
    die "ci dry-run did not remove retired engine runner packages"
  grep -F 'sudo -n systemctl reset-failed engineos-engine-runner.service' "$out" >/dev/null ||
    die "ci dry-run did not clear the retired engine runner failure state"
  grep -F 'eos-validate repo' "$out" >/dev/null ||
    die "ci dry-run did not include real repo validation command"

  if "$ROOT/tools/engineos/eos-ci" local --package not-a-package >"$out" 2>&1; then
    die "ci accepted an unknown package"
  fi
  grep -F 'unknown EngineOS package: not-a-package' "$out" >/dev/null ||
    die "ci unknown package error was not clear"

  if "$ROOT/tools/engineos/eos-ci" local --package engineos-tools --test ci >"$out" 2>&1; then
    die "ci real mode should reject repo validation outside /srv/engineos"
  fi
  grep -F 'real repo validation must run from /srv/engineos' "$out" >/dev/null ||
    die "ci repo validation location error was not clear"

  printf 'ci loop smoke test passed\n'
}

run_source_test() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-source-test-$$"
  local out="$tmp_dir/source-test.txt"

  cleanup_source_test() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_source_test RETURN
  mkdir -p "$tmp_dir"

  ENGINEOS_ROOT=/usr \
    ENGINEOS_SCRIPT_DIR=/usr/lib/engineos/scripts \
    ENGINEOS_EOS_DIR=/usr/lib/engineos/eos \
    ENGINEOS_LOG_DIR=/var/log/engineos \
    ENGINEOS_STATE_DIR=/run/engineos \
    ENGINEOS_CAPTURE_DIR=/run/engineos/captures \
    ENGINEOS_SHELL_BOOTSTRAP=installed-session \
    ENGINEOS_TERMINAL_SESSION_CMD=installed-tmux \
    ENGINEOS_TERMINAL_REQUIRE_WAYLAND=1 \
    ENGINEOS_TERMINAL_SLOT_CMD=installed-terminal \
    ENGINEOS_CUBE_CMD=installed-cube \
    ENGINEOS_ENGINE_CMD=installed-engine \
    ENGINEOS_RUNTIME_CMD=installed-runtime \
    ENGINEOS_SHELL_BIN=/usr/bin/engineos-shell \
    WAYLAND_DISPLAY=installed-wayland \
    DISPLAY=:99 \
    XDG_SESSION_TYPE=wayland \
    WLR_BACKENDS=wayland \
    WLR_RENDERER=vulkan \
    WLR_RENDERER_ALLOW_SOFTWARE=1 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    "$ROOT/tools/engineos/eos-source-test" source-env >"$out"

  grep -F 'EngineOS source test' "$out" >/dev/null ||
    die "eos-source-test did not print its header"
  grep -F "root:       $ROOT" "$out" >/dev/null ||
    die "eos-source-test did not resolve the checkout root"
  grep -F "script_dir: $ROOT/tools/scripts" "$out" >/dev/null ||
    die "eos-source-test did not resolve the checkout script dir"
  if grep -F 'root:       /usr' "$out" >/dev/null; then
    die "eos-source-test used installed ENGINEOS_ROOT"
  fi
  grep -F "source env root: $ROOT" "$out" >/dev/null ||
    die "repo-local eos-test did not see the checkout root"
  grep -F "source env script_dir: $ROOT/tools/scripts" "$out" >/dev/null ||
    die "repo-local eos-test did not see the checkout script dir"
  grep -F 'source env contamination cleared' "$out" >/dev/null ||
    die "eos-source-test did not clear installed-session environment"

  printf 'source test facade smoke test passed\n'
}

run_source_env() {
  local source_root
  source_root="$(cd "$MODULE_DIR/../../.." && pwd -P)"

  printf 'source env root: %s\n' "$ROOT"
  printf 'source env script_dir: %s\n' "$SCRIPT_DIR"

  [[ "$ROOT" == "$source_root" ]] ||
    die "source-env root is not the checkout: $ROOT"
  [[ "$SCRIPT_DIR" == "$source_root/tools/scripts" ]] ||
    die "source-env script dir is not the checkout: $SCRIPT_DIR"
  [[ "${ENGINEOS_ROOT:-}" == "$source_root" ]] ||
    die "source-env ENGINEOS_ROOT is not the checkout: ${ENGINEOS_ROOT:-unset}"
  [[ "${ENGINEOS_SCRIPT_DIR:-}" == "$source_root/tools/scripts" ]] ||
    die "source-env ENGINEOS_SCRIPT_DIR is not the checkout: ${ENGINEOS_SCRIPT_DIR:-unset}"
  [[ "${ENGINEOS_EOS_DIR:-}" == "$source_root/tools/eos" ]] ||
    die "source-env ENGINEOS_EOS_DIR is not the checkout: ${ENGINEOS_EOS_DIR:-unset}"
  [[ "${ENGINEOS_LOG_DIR:-}" == "$source_root/artifacts/logs" ]] ||
    die "source-env ENGINEOS_LOG_DIR is not the checkout log dir: ${ENGINEOS_LOG_DIR:-unset}"
  [[ -z "${ENGINEOS_SOURCE_TEST_MODE:-}" ]] ||
    die "source-env leaked internal source-test marker"

  if [[ "$(printenv SCRIPT_DIR 2>/dev/null || true)" == /usr/lib/engineos/scripts* ]]; then
    die "source-env inherited installed SCRIPT_DIR: $(printenv SCRIPT_DIR)"
  fi
  [[ -z "${ENGINEOS_STATE_DIR:-}" ]] ||
    die "source-env inherited ENGINEOS_STATE_DIR: $ENGINEOS_STATE_DIR"
  [[ -z "${ENGINEOS_CAPTURE_DIR:-}" ]] ||
    die "source-env inherited ENGINEOS_CAPTURE_DIR: $ENGINEOS_CAPTURE_DIR"
  [[ -z "${ENGINEOS_SHELL_BOOTSTRAP:-}" ]] ||
    die "source-env inherited ENGINEOS_SHELL_BOOTSTRAP: $ENGINEOS_SHELL_BOOTSTRAP"
  [[ -z "${ENGINEOS_TERMINAL_SESSION_CMD:-}" ]] ||
    die "source-env inherited ENGINEOS_TERMINAL_SESSION_CMD: $ENGINEOS_TERMINAL_SESSION_CMD"
  [[ -z "${ENGINEOS_TERMINAL_REQUIRE_WAYLAND:-}" ]] ||
    die "source-env inherited ENGINEOS_TERMINAL_REQUIRE_WAYLAND: $ENGINEOS_TERMINAL_REQUIRE_WAYLAND"
  [[ -z "${ENGINEOS_TERMINAL_SLOT_CMD:-}" ]] ||
    die "source-env inherited ENGINEOS_TERMINAL_SLOT_CMD: $ENGINEOS_TERMINAL_SLOT_CMD"
  [[ -z "${ENGINEOS_CUBE_CMD:-}" ]] ||
    die "source-env inherited ENGINEOS_CUBE_CMD: $ENGINEOS_CUBE_CMD"
  [[ -z "${ENGINEOS_ENGINE_CMD:-}" ]] ||
    die "source-env inherited ENGINEOS_ENGINE_CMD: $ENGINEOS_ENGINE_CMD"
  [[ -z "${ENGINEOS_RUNTIME_CMD:-}" ]] ||
    die "source-env inherited ENGINEOS_RUNTIME_CMD: $ENGINEOS_RUNTIME_CMD"
  [[ -z "${ENGINEOS_SHELL_BIN:-}" ]] ||
    die "source-env inherited ENGINEOS_SHELL_BIN: $ENGINEOS_SHELL_BIN"
  [[ -z "${WAYLAND_DISPLAY:-}" ]] ||
    die "source-env inherited WAYLAND_DISPLAY: $WAYLAND_DISPLAY"
  [[ -z "${DISPLAY:-}" ]] ||
    die "source-env inherited DISPLAY: $DISPLAY"
  [[ -z "${XDG_SESSION_TYPE:-}" ]] ||
    die "source-env inherited XDG_SESSION_TYPE: $XDG_SESSION_TYPE"
  [[ -z "${WLR_BACKENDS:-}" ]] ||
    die "source-env inherited WLR_BACKENDS: $WLR_BACKENDS"
  [[ -z "${WLR_RENDERER:-}" ]] ||
    die "source-env inherited WLR_RENDERER: $WLR_RENDERER"
  [[ -z "${WLR_RENDERER_ALLOW_SOFTWARE:-}" ]] ||
    die "source-env inherited WLR_RENDERER_ALLOW_SOFTWARE: $WLR_RENDERER_ALLOW_SOFTWARE"
  [[ -z "${LIBGL_ALWAYS_SOFTWARE:-}" ]] ||
    die "source-env inherited LIBGL_ALWAYS_SOFTWARE: $LIBGL_ALWAYS_SOFTWARE"

  printf 'source env contamination cleared\n'
}

run_shell_actions() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-shell-actions-$$"
  local fake_bin="$tmp_dir/bin"
  local fake_shell="$tmp_dir/engineos-shell"
  local args_file="$tmp_dir/args.txt"

  cleanup_shell_actions() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_shell_actions RETURN

  mkdir -p "$fake_bin" "$tmp_dir/logs"
  cat >"$fake_shell" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ENGINEOS_FAKE_SHELL_ARGS"
printf 'fake shell stdout marker\n'
FAKE
  chmod +x "$fake_shell"

  ENGINEOS_SHELL_BIN="$fake_shell" \
    ENGINEOS_FAKE_SHELL_ARGS="$args_file" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    ENGINEOS_TERMINAL_SLOT_CMD="foot --server" \
    ENGINEOS_CUBE_CMD="eos-app launch cube --smoke" \
    ENGINEOS_ENGINE_CMD="eos-app launch quake --smoke" \
    "$SCRIPT_DIR/shell_runner.sh" --nested >/dev/null

  grep -Fx -- "--nested" "$args_file" >/dev/null || die "shell actions test missing --nested"
  grep -Fx -- "--terminal" "$args_file" >/dev/null || die "shell actions test missing --terminal"
  grep -Fx -- "foot --server" "$args_file" >/dev/null || die "shell actions test missing terminal command"
  grep -Fx -- "--terminal-secondary" "$args_file" >/dev/null || die "shell actions test missing --terminal-secondary"
  grep -E -- '(^|/)eos-app launch terminal-secondary$' "$args_file" >/dev/null || die "shell actions test missing secondary terminal app command"
  grep -Fx -- "--cube" "$args_file" >/dev/null || die "shell actions test missing --cube"
  grep -Fx -- "eos-app launch cube --smoke" "$args_file" >/dev/null || die "shell actions test missing cube command"
  grep -Fx -- "--engine" "$args_file" >/dev/null || die "shell actions test missing --engine"
  grep -Fx -- "eos-app launch quake --smoke" "$args_file" >/dev/null || die "shell actions test missing app command"

  ENGINEOS_SHELL_BIN="$fake_shell" \
    ENGINEOS_FAKE_SHELL_ARGS="$args_file" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    ENGINEOS_SHELL_BOOTSTRAP= \
    "$SCRIPT_DIR/shell_runner.sh" --tty >/dev/null

  grep -Fx -- "--tty" "$args_file" >/dev/null || die "shell actions test missing --tty"
  grep -Fx -- "--terminal" "$args_file" >/dev/null || die "shell actions tty missing --terminal"
  grep -E -- '(^|/)eos-app launch terminal$' "$args_file" >/dev/null || die "shell actions tty missing default terminal app command"
  grep -Fx -- "--terminal-secondary" "$args_file" >/dev/null || die "shell actions tty missing --terminal-secondary"
  grep -E -- '(^|/)eos-app launch terminal-secondary$' "$args_file" >/dev/null || die "shell actions tty missing default secondary terminal app command"
  grep -Fx -- "--cube" "$args_file" >/dev/null || die "shell actions tty missing --cube"
  grep -E -- '(^|/)eos-app launch cube$' "$args_file" >/dev/null || die "shell actions tty missing default cube command"
  grep -Fx -- "--engine" "$args_file" >/dev/null || die "shell actions tty missing --engine"
  grep -E -- '(^|/)eos-app launch quake$' "$args_file" >/dev/null || die "shell actions tty missing default app command"
  grep -Fx -- "--bootstrap" "$args_file" >/dev/null || die "shell actions tty missing --bootstrap"
  grep -Fx -- "launchpad" "$args_file" >/dev/null || die "shell actions tty missing bootstrap launchpad"
  grep -F 'fake shell stdout marker' "$tmp_dir/logs/shell.log" >/dev/null ||
    die "shell actions did not tee real shell output to shell log"

  local restart_proc_dir="$tmp_dir/restart-proc"
  local restart_out="$tmp_dir/restart-live.txt"
  local uid
  uid="$(id -u)"
  mkdir -p "$restart_proc_dir/100" "$restart_proc_dir/101"
  printf 'Uid:\t%s\t%s\t%s\t%s\n' "$uid" "$uid" "$uid" "$uid" >"$restart_proc_dir/100/status"
  printf 'engineos-shell\0--tty\0' >"$restart_proc_dir/100/cmdline"
  printf 'Uid:\t%s\t%s\t%s\t%s\n' "$uid" "$uid" "$uid" "$uid" >"$restart_proc_dir/101/status"
  printf 'bash\0-c\0engineos-shell --tty\0' >"$restart_proc_dir/101/cmdline"
  cat >"$fake_bin/fake-dev-shell-restart" <<'FAKE'
#!/usr/bin/env bash
mkdir -p "$ENGINEOS_FAKE_RESTART_PROC_DIR/200"
printf 'Uid:\t%s\t%s\t%s\t%s\n' "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" >"$ENGINEOS_FAKE_RESTART_PROC_DIR/200/status"
printf 'engineos-shell\0--tty\0' >"$ENGINEOS_FAKE_RESTART_PROC_DIR/200/cmdline"
FAKE
  chmod +x "$fake_bin/fake-dev-shell-restart"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_PROC_DIR="$restart_proc_dir" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    "$SCRIPT_DIR/shell_runner.sh" restart-live --dry-run >"$restart_out"
  grep -F 'old_pids:   100' "$restart_out" >/dev/null ||
    die "restart-live dry-run did not report old shell pid"
  if grep -E '^  old_pids:.*(^|[[:space:]])101($|[[:space:]])' "$restart_out" >/dev/null; then
    die "restart-live dry-run matched shell text instead of the engineos-shell process"
  fi
  grep -F 'would_verify: new same-user engineos-shell pid' "$restart_out" >/dev/null ||
    die "restart-live dry-run did not report pid verification"
  grep -F 'result:     preview' "$restart_out" >/dev/null ||
    die "restart-live dry-run did not report preview result"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_PROC_DIR="$restart_proc_dir" \
    ENGINEOS_RESTART_DEV_SHELL_CMD="$fake_bin/fake-dev-shell-restart" \
    ENGINEOS_FAKE_RESTART_PROC_DIR="$restart_proc_dir" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    "$SCRIPT_DIR/shell_runner.sh" restart-live --timeout 1 >"$restart_out"
  grep -F 'new_pids:   200' "$restart_out" >/dev/null ||
    die "restart-live did not verify new shell pid"
  grep -F 'result:     restarted' "$restart_out" >/dev/null ||
    die "restart-live did not report restarted result"

  if PATH="$fake_bin:$PATH" \
      ENGINEOS_PROC_DIR="$restart_proc_dir" \
      ENGINEOS_RESTART_DEV_SHELL_CMD=false \
      ENGINEOS_LOG_DIR="$tmp_dir/logs" \
      ENGINEOS_STATE_DIR="$tmp_dir/run" \
      "$SCRIPT_DIR/shell_runner.sh" restart-live --timeout 1 >"$restart_out" 2>&1; then
    die "restart-live succeeded after restart command failure"
  fi
  grep -F 'result:     failed reason=restart-command-failed' "$restart_out" >/dev/null ||
    die "restart-live did not expose restart command failure"

  if PATH="$fake_bin:$PATH" \
      ENGINEOS_PROC_DIR="$tmp_dir/missing-proc" \
      ENGINEOS_RESTART_DEV_SHELL_CMD=true \
      ENGINEOS_LOG_DIR="$tmp_dir/logs" \
      ENGINEOS_STATE_DIR="$tmp_dir/run" \
      "$SCRIPT_DIR/shell_runner.sh" restart-live --timeout 1 >"$restart_out" 2>&1; then
    die "restart-live succeeded without pid discovery"
  fi
  grep -F 'result:     partial reason=pid-discovery-unavailable' "$restart_out" >/dev/null ||
    die "restart-live did not report partial result when pid discovery is unavailable"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_PROC_DIR="$tmp_dir/missing-proc" \
    ENGINEOS_RESTART_DEV_SHELL_CMD=true \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    "$SCRIPT_DIR/shell_runner.sh" restart-live --timeout 1 --allow-partial >"$restart_out"
  grep -F 'result:     partial reason=pid-discovery-unavailable' "$restart_out" >/dev/null ||
    die "restart-live allow-partial did not report partial result"

  local proc_dir="$tmp_dir/proc"
  local kill_log="$tmp_dir/kill.log"
  local tmux_log="$tmp_dir/tmux.log"
  local refresh_home="$tmp_dir/home"
  local helper_dir="$tmp_dir/helpers"
  local refresh_out="$tmp_dir/refresh-user.txt"
  mkdir -p "$proc_dir/111" "$proc_dir/222" "$proc_dir/333" "$proc_dir/444" "$refresh_home" "$helper_dir"
  printf 'Uid:\t%s\t%s\t%s\t%s\n' "$uid" "$uid" "$uid" "$uid" >"$proc_dir/111/status"
  printf 'bash\0%s\0refresh-user\0engineos-tmux-window-sync\0--daemon\0' "$SCRIPT_DIR/shell_runner.sh" >"$proc_dir/111/cmdline"
  printf 'Uid:\t%s\t%s\t%s\t%s\n' "$uid" "$uid" "$uid" "$uid" >"$proc_dir/222/status"
  printf 'engineos-tmux-window-sync\0--daemon\0' >"$proc_dir/222/cmdline"
  printf 'Uid:\t99999\t99999\t99999\t99999\n' >"$proc_dir/333/status"
  printf 'engineos-tmux-window-sync\0--daemon\0' >"$proc_dir/333/cmdline"
  printf 'Uid:\t%s\t%s\t%s\t%s\n' "$uid" "$uid" "$uid" "$uid" >"$proc_dir/444/status"
  printf 'engineos-tmux-window-sync\0--daemonized\0' >"$proc_dir/444/cmdline"
  cat >"$fake_bin/fake-kill" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ENGINEOS_FAKE_KILL_LOG"
for arg in "$@"; do
  case "$arg" in
    ''|-*) ;;
    *) rm -rf "$ENGINEOS_FAKE_PROC_DIR/$arg" ;;
  esac
done
FAKE
  cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  source-file)
    printf 'source-file %s\n' "$2" >>"$ENGINEOS_FAKE_TMUX_LOG"
    exit 0
    ;;
  has-session)
    exit 0
    ;;
  run-shell)
    printf 'run-shell %s\n' "${*: -1}" >>"$ENGINEOS_FAKE_TMUX_LOG"
    exit 0
    ;;
esac
exit 1
FAKE
  chmod +x "$fake_bin/fake-kill" "$fake_bin/tmux"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_USER_HOME="$refresh_home" \
    ENGINEOS_TMUX_HELPER_DIR="$helper_dir" \
    ENGINEOS_PROC_DIR="$proc_dir" \
    ENGINEOS_KILL_CMD="$fake_bin/fake-kill" \
    ENGINEOS_FAKE_KILL_LOG="$kill_log" \
    ENGINEOS_FAKE_PROC_DIR="$proc_dir" \
    ENGINEOS_TMUX_CMD="$fake_bin/tmux" \
    ENGINEOS_FAKE_TMUX_LOG="$tmux_log" \
  "$SCRIPT_DIR/shell_runner.sh" refresh-user --force-config >"$refresh_out"
  [[ -f "$refresh_home/.tmux.conf" ]] ||
    die "refresh-user did not install tmux config"
  for helper in engineos-tmux-pane-bridge engineos-tmux-pane-sync engineos-tmux-window-move engineos-tmux-window-sync engineos-tmux-window-focus engineos-tmux-window-proxy; do
    [[ -x "$helper_dir/$helper" ]] ||
      die "refresh-user did not install helper: $helper"
  done
  grep -F -- '-TERM 222' "$kill_log" >/dev/null ||
    die "refresh-user did not terminate the existing tmux sync daemon"
  if grep -F '111' "$kill_log" >/dev/null || grep -F '333' "$kill_log" >/dev/null || grep -F '444' "$kill_log" >/dev/null; then
    die "refresh-user killed a non-target tmux sync process"
  fi
  grep -F 'source-file '"$refresh_home/.tmux.conf" "$tmux_log" >/dev/null ||
    die "refresh-user did not source tmux config"
  grep -F 'run-shell engineos-tmux-pane-bridge sync' "$tmux_log" >/dev/null ||
    die "refresh-user did not sync tmux pane bridge through tmux"
  grep -F 'result:     refreshed' "$refresh_out" >/dev/null ||
    die "refresh-user did not report full refresh result"

  printf "set -g @engineos-plugins 'stale-managed-config'\n" >"$refresh_home/.tmux.conf"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_USER_HOME="$refresh_home" \
    ENGINEOS_TMUX_HELPER_DIR="$helper_dir" \
    ENGINEOS_PROC_DIR="$proc_dir" \
    ENGINEOS_KILL_CMD="$fake_bin/fake-kill" \
    ENGINEOS_FAKE_KILL_LOG="$kill_log" \
    ENGINEOS_FAKE_PROC_DIR="$proc_dir" \
    ENGINEOS_TMUX_CMD="$fake_bin/tmux" \
    ENGINEOS_FAKE_TMUX_LOG="$tmux_log" \
    "$SCRIPT_DIR/shell_runner.sh" refresh-user >"$refresh_out"
  grep -F 'Move to Session...' "$refresh_home/.tmux.conf" >/dev/null ||
    die "refresh-user did not update a stale EngineOS-managed tmux config"
  grep -F 'managed_update:' "$refresh_out" >/dev/null ||
    die "refresh-user did not report the managed tmux config update"

  printf '# user-owned tmux config\n' >"$refresh_home/.tmux.conf"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_USER_HOME="$refresh_home" \
    ENGINEOS_TMUX_HELPER_DIR="$helper_dir" \
    ENGINEOS_PROC_DIR="$proc_dir" \
    ENGINEOS_KILL_CMD="$fake_bin/fake-kill" \
    ENGINEOS_FAKE_KILL_LOG="$kill_log" \
    ENGINEOS_FAKE_PROC_DIR="$proc_dir" \
    ENGINEOS_TMUX_CMD="$fake_bin/tmux" \
    ENGINEOS_FAKE_TMUX_LOG="$tmux_log" \
    "$SCRIPT_DIR/shell_runner.sh" refresh-user >"$refresh_out"
  grep -F '# user-owned tmux config' "$refresh_home/.tmux.conf" >/dev/null ||
    die "refresh-user replaced an unmanaged tmux config"
  grep -F 'keep:' "$refresh_out" >/dev/null ||
    die "refresh-user did not report preserving an unmanaged tmux config"

  local bridge_log="$tmp_dir/bridge-eos-app.log"
  : >"$bridge_log"
  cat >"$fake_bin/eos-app" <<'FAKE'
#!/usr/bin/env bash
printf 'TMUX_PANE=%s args=%s\n' "${TMUX_PANE:-}" "$*" >>"$ENGINEOS_FAKE_BRIDGE_LOG"
FAKE
  cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  list-panes)
    printf '%%7\t1\n%%8\t1\n%%9\t0\n'
    exit 0
    ;;
  display-message)
    printf '%%7\n'
    exit 0
    ;;
esac
exit 1
FAKE
  chmod +x "$fake_bin/eos-app" "$fake_bin/tmux"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_FAKE_BRIDGE_LOG="$bridge_log" \
    TMUX="/tmp/engineos-tmux,1,0" \
    TMUX_PANE="%7" \
    "$ROOT/tools/post-install-payload/scripts/engineos-tmux-pane-bridge" focus
  grep -F 'TMUX_PANE=%7 args=pane focus --pane %7' "$bridge_log" >/dev/null ||
    die "tmux pane bridge focus did not send active pane to eos-app"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_FAKE_BRIDGE_LOG="$bridge_log" \
    TMUX="/tmp/engineos-tmux,1,0" \
    "$ROOT/tools/post-install-payload/scripts/engineos-tmux-pane-bridge" geometry --all-visible
  grep -F 'TMUX_PANE=%7 args=pane geometry --pane %7' "$bridge_log" >/dev/null ||
    die "tmux pane bridge geometry did not sync visible pane %7"
  grep -F 'TMUX_PANE=%8 args=pane geometry --pane %8' "$bridge_log" >/dev/null ||
    die "tmux pane bridge geometry did not sync visible pane %8"
  if grep -F 'TMUX_PANE=%9 args=pane geometry --pane %9' "$bridge_log" >/dev/null; then
    die "tmux pane bridge geometry synced invisible pane"
  fi

  ENGINEOS_USER_HOME="$refresh_home" \
    ENGINEOS_TMUX_HELPER_DIR="$helper_dir" \
    ENGINEOS_TMUX_CMD="$tmp_dir/missing-tmux" \
    "$SCRIPT_DIR/shell_runner.sh" refresh-user >"$refresh_out"
  grep -F 'tmux:       unavailable; tmux config source and pane bridge sync skipped' "$refresh_out" >/dev/null ||
    die "refresh-user missing tmux condition was not clear and non-fatal"
  grep -F 'result:     partial reason=tmux-unavailable' "$refresh_out" >/dev/null ||
    die "refresh-user missing tmux condition did not report a partial result"

  if ENGINEOS_USER_HOME="$refresh_home" \
      ENGINEOS_TMUX_HELPER_DIR="$helper_dir" \
      ENGINEOS_POST_INSTALL_PAYLOAD="$tmp_dir/missing-payload" \
      "$SCRIPT_DIR/shell_runner.sh" refresh-user >"$refresh_out" 2>&1; then
    die "refresh-user succeeded with missing payload"
  fi
  grep -F 'result:     failed reason=post-install-payload-missing' "$refresh_out" >/dev/null ||
    die "refresh-user missing payload did not report failed result"

  printf 'shell actions smoke test passed\n'
}

run_game_workflow() {
	local tmp_dir="${TMPDIR:-/tmp}/engineos-game-workflow-$$"
	local out="$tmp_dir/out.txt"
	local err="$tmp_dir/err.txt"
	local systemctl_log="$tmp_dir/systemctl.log"
	local request="$tmp_dir/run/quake-launch.json"
	local service_adapter="$ROOT/tools/game/engineos_quake_service.py"
	if [[ ! -r "$service_adapter" ]]; then
		service_adapter="/usr/lib/engineos/game/engineos-quake-service"
	fi
	[[ -r "$service_adapter" ]] ||
		die "Quake service adapter is unavailable"
	trap 'rm -rf "$tmp_dir"' RETURN
	mkdir -p "$tmp_dir/run" "$tmp_dir/state" "$tmp_dir/id1"
	cat >"$tmp_dir/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ENGINEOS_FAKE_SYSTEMCTL_LOG"
FAKE
	chmod +x "$tmp_dir/systemctl"

	if ENGINEOS_GAME_RUNTIME_DIR="$tmp_dir/run" \
			ENGINEOS_GAME_STATE_DIR="$tmp_dir/state" \
			ENGINEOS_QUAKE_ID1="$tmp_dir/id1" \
			ENGINEOS_SYSTEMCTL_CMD=true \
			"$SCRIPT_DIR/game.sh" quake play --map '../bad' >"$out" 2>"$err"; then
		die "game workflow accepted an unsafe map name"
	fi
	grep -F 'invalid Quake map name' "$err" >/dev/null ||
		die "game workflow did not report invalid map input"

	ENGINEOS_GAME_RUNTIME_DIR="$tmp_dir/run" \
		ENGINEOS_GAME_STATE_DIR="$tmp_dir/state" \
		ENGINEOS_QUAKE_LAUNCH_REQUEST="$request" \
		ENGINEOS_QUAKE_ID1="$tmp_dir/id1" \
		ENGINEOS_SYSTEMCTL_CMD="$tmp_dir/systemctl" \
		ENGINEOS_FAKE_SYSTEMCTL_LOG="$systemctl_log" \
		WAYLAND_DISPLAY=engineos-test-wayland \
		"$SCRIPT_DIR/game.sh" quake play --map dgen_smoke --game id1 --smoke >"$out"
	grep -F 'Quake started by engineos-quake.service map=dgen_smoke' "$out" >/dev/null ||
		die "game workflow did not report the user-service launch"
	python - "$request" "$tmp_dir/id1" <<'PY'
import json, pathlib, stat, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
assert data == {"schema": "engineos-quake-launch/v1", "map": "dgen_smoke",
				"game": "id1", "smoke": True, "window": False,
				"fullscreen": False, "id1": sys.argv[2]}
assert stat.S_IMODE(path.stat().st_mode) == 0o600
PY
	grep -F -- '--user import-environment WAYLAND_DISPLAY' "$systemctl_log" >/dev/null ||
		die "game workflow did not import the Wayland environment"
	grep -F -- '--user restart engineos-quake.service' "$systemctl_log" >/dev/null ||
		die "game workflow did not restart the per-user Quake unit"

	mkdir -p "$tmp_dir/engines/quakespasm/engineos"
	cat >"$tmp_dir/engines/quakespasm/engineos/run.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${ENGINEOS_FAKE_QUAKE_ARGS:-$HOME/quake-service-args.txt}"
printf 'id1=%s\n' "${ENGINEOS_QUAKE_ID1:-missing}" >>"${ENGINEOS_FAKE_QUAKE_ARGS:-$HOME/quake-service-args.txt}"
FAKE
	chmod +x "$tmp_dir/engines/quakespasm/engineos/run.sh"
	local systemctl_lines
	systemctl_lines="$(wc -l <"$systemctl_log")"
	HOME="$tmp_dir" ENGINEOS_ROOT="$tmp_dir" \
		ENGINEOS_GAME_RUNTIME_DIR="$tmp_dir/run" \
		ENGINEOS_GAME_STATE_DIR="$tmp_dir/state" \
		ENGINEOS_QUAKE_ID1="$tmp_dir/id1" \
		ENGINEOS_SYSTEMCTL_CMD="$tmp_dir/systemctl" \
		ENGINEOS_FAKE_SYSTEMCTL_LOG="$systemctl_log" \
		ENGINEOS_FAKE_QUAKE_ARGS="$tmp_dir/quake-foreground-args.txt" \
		"$SCRIPT_DIR/game.sh" quake play --foreground --map pane_proof \
			--game id1 --window
	grep -F -- '--game id1 --map pane_proof --window' \
		"$tmp_dir/quake-foreground-args.txt" >/dev/null ||
		die "foreground Quake workflow did not exec the pane-owned runner"
	grep -F "id1=$tmp_dir/id1" "$tmp_dir/quake-foreground-args.txt" >/dev/null ||
		die "foreground Quake workflow did not preserve the validated asset path"
	[[ "$(wc -l <"$systemctl_log")" == "$systemctl_lines" ]] ||
		die "foreground Quake workflow escaped into the user service"
	HOME="$tmp_dir" ENGINEOS_ROOT="$tmp_dir" \
		ENGINEOS_QUAKE_LAUNCH_REQUEST="$request" \
		python "$service_adapter"
	grep -F -- '--map dgen_smoke --game id1 --smoke' "$tmp_dir/quake-service-args.txt" >/dev/null ||
		die "Quake user-service adapter did not exec the validated launch request"
	python - "$request" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["window"] = True
data["fullscreen"] = True
path.write_text(json.dumps(data), encoding="utf-8")
PY
	if HOME="$tmp_dir" ENGINEOS_ROOT="$tmp_dir" \
			ENGINEOS_QUAKE_LAUNCH_REQUEST="$request" \
			python "$service_adapter" >"$out" 2>"$err"; then
		die "Quake user-service adapter accepted conflicting display modes"
	fi
	grep -F 'window and fullscreen modes are mutually exclusive' "$err" >/dev/null ||
		die "Quake user-service adapter did not explain conflicting display modes"

	printf 'game workflow contract test passed\n'
}

run_image_preview() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-image-preview-test-$$"
  local fake_bin="$tmp_dir/bin"
  local tool_bin="$tmp_dir/tool-bin"
  local out="$tmp_dir/out.txt"
  local err="$tmp_dir/err.txt"
  local png="$tmp_dir/sample.png"
  local jpg="$tmp_dir/sample.jpg"
  local sock="$tmp_dir/preview.sock"
  local preview_bin="$ROOT/tools/engineos/engine-image-preview"
  local shell_bin="${ENGINEOS_TEST_SHELL_BIN:-}"
  local shell_pid=""
  local gui_pid=""
  local pending_pid=""

  cleanup_image_preview() {
    if [[ -n "$shell_pid" ]]; then
      kill "$shell_pid" >/dev/null 2>&1 || true
      wait "$shell_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$gui_pid" ]]; then
      kill "$gui_pid" >/dev/null 2>&1 || true
      wait "$gui_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$pending_pid" ]]; then
      kill "$pending_pid" >/dev/null 2>&1 || true
      wait "$pending_pid" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp_dir"
  }
  trap cleanup_image_preview RETURN

  mkdir -p "$fake_bin" "$tmp_dir/dir"
  if [[ ! -x "$preview_bin" ]]; then
    preview_bin="${ENGINEOS_INSTALLED_BIN_DIR:-/usr/bin}/engine-image-preview"
  fi
  [[ -x "$preview_bin" ]] || die "engine-image-preview helper is not executable"
  if [[ -z "$shell_bin" ]]; then
    if [[ -d "$ROOT/shell" ]]; then
      meson setup "$tmp_dir/shell-build" "$ROOT/shell" >/dev/null
      meson compile -C "$tmp_dir/shell-build" >/dev/null
      shell_bin="$tmp_dir/shell-build/engineos-shell"
    else
      shell_bin="${ENGINEOS_INSTALLED_SHELL_BIN:-/usr/bin/engineos-shell}"
    fi
  fi
  [[ -x "$shell_bin" ]] || die "current engineos-shell test binary is not executable"

  python - "$png" "$jpg" <<'PY'
import base64
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_bytes(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADAQMAAACOOjyFAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURSJmzP///8VU6LMAAAABYktHRAH/Ai3eAAAAB3RJTUUH6gcCFi0VNn7nGQAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAyNi0wNy0wMlQyMjo0NToyMSswMDowMIBjV7MAAAAldEVYdGRhdGU6bW9kaWZ5ADIwMjYtMDctMDJUMjI6NDU6MjErMDA6MDDxPu8PAAAAKHRFWHRkYXRlOnRpbWVzdGFtcAAyMDI2LTA3LTAyVDIyOjQ1OjIxKzAwOjAwpivO0AAAAAtJREFUCNdjYAABAAAGAAFm9MlsAAAAAElFTkSuQmCC"
))
pathlib.Path(sys.argv[2]).write_bytes(base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAADAAQDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAAB//EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAVAQEBAAAAAAAAAAAAAAAAAAAHCP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/ACJUoPf/2Q=="
))
PY

  PATH="$fake_bin:$PATH" \
    ENGINEOS_PREVIEW_SLOT=terminal-secondary \
    "$preview_bin" --view "$png" --dry-run >"$out"
  grep -F '"op":"show"' "$out" >/dev/null ||
    die "image preview dry-run did not emit show op"
  grep -F '"anchor":"active-pane"' "$out" >/dev/null ||
    die "image preview dry-run did not request active pane anchor"
  grep -F '"slot":"terminal-secondary"' "$out" >/dev/null ||
    die "image preview dry-run did not include terminal slot"
  grep -F '"owner":' "$out" >/dev/null ||
    die "image preview dry-run did not include owner token"
  grep -F "\"path\":\"$png\"" "$out" >/dev/null ||
    die "image preview dry-run did not include resolved path"
	ENGINEOS_MUX_MODE=native TMUX_PANE=%99 \
		ENGINEOS_PREVIEW_OWNER="native-contract-owner" \
		"$preview_bin" --view "$png" --dry-run >"$out"
	grep -F '"transport":"engine-mux/pane-image-v1"' "$out" >/dev/null ||
		die "native image preview dry-run did not select mux pane image transport"

  cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "display-message" ]]; then
	format="${!#}"
	case "$format" in
		*'#{socket_path}'*'#{session_name}'*)
			printf '/tmp/engineos-tmux\twork\t@3\t2\t%s\n' "${TMUX_PANE:-%1}"
			;;
		'#{socket_path}')
			printf '/tmp/engineos-tmux\n'
			;;
		*'#{session_name}'*)
			printf 'work @3 2 %s\n' "${TMUX_PANE:-%1}"
			;;
		'#{client_tty}')
			printf '/dev/pts/11\n'
			;;
		*'#{client_cell_width}'*)
			printf '9 18\n'
			;;
		*)
			printf '10 5 80 24 160 48\n'
			;;
	esac
  exit 0
fi
exit 1
FAKE
  chmod +x "$fake_bin/tmux"

  PATH="$fake_bin:$PATH" \
    TMUX_PANE="%1" \
    "$preview_bin" --open "$png" --dry-run >"$out"
  for field in '"x":10' '"y":5' '"width":80' '"height":24' '"window_width":160' '"window_height":48'; do
    grep -F "$field" "$out" >/dev/null ||
      die "image preview dry-run did not include tmux bounds field $field"
  done

  "$preview_bin" --wallpaper "$png" --opacity 65 --dry-run >"$out"
  grep -F '"op":"wallpaper"' "$out" >/dev/null ||
    die "image preview wallpaper dry-run did not emit wallpaper op"
  grep -F '"mode":"output"' "$out" >/dev/null ||
    die "image preview wallpaper dry-run did not default to output mode"
  grep -F '"fit":"cover"' "$out" >/dev/null ||
    die "image preview wallpaper dry-run did not request cover fit"
  grep -F '"opacity":65' "$out" >/dev/null ||
    die "image preview wallpaper dry-run did not include opacity"

  PATH="$fake_bin:$PATH" \
    TMUX_PANE="%1" \
    "$preview_bin" --wallpaper "$png" --target pane --opacity 42 --dry-run >"$out"
  grep -F '"mode":"pane"' "$out" >/dev/null ||
    die "image preview wallpaper pane dry-run did not request pane mode"
  grep -F '"opacity":42' "$out" >/dev/null ||
    die "image preview wallpaper pane dry-run did not include opacity"
  for field in '"x":10' '"y":5' '"width":80' '"height":24' '"window_width":160' '"window_height":48'; do
    grep -F "$field" "$out" >/dev/null ||
      die "image preview wallpaper pane dry-run did not include bounds field $field"
  done

  if "$preview_bin" --wallpaper "$png" --opacity 101 --dry-run >"$out" 2>"$err"; then
    die "image preview accepted invalid wallpaper opacity"
  fi
  grep -F -- '--opacity must be between 0 and 100' "$err" >/dev/null ||
    die "image preview invalid wallpaper opacity error was not visible"

  PATH="$fake_bin:$PATH" \
    TMUX_PANE="%1" \
    "$preview_bin" --quick-view "$png" --panel right --dry-run >"$out"
  grep -F '"anchor":"mc-preview-panel"' "$out" >/dev/null ||
    die "image preview quick-view did not request preview panel anchor"
  for field in '"x":50' '"y":5' '"width":40' '"height":24' '"window_width":160' '"window_height":48'; do
    grep -F "$field" "$out" >/dev/null ||
      die "image preview quick-view right panel did not include bounds field $field"
  done
  grep -F '"owner":"mc-quick-view:' "$out" >/dev/null ||
    die "image preview quick-view did not use a stable MC owner token"

	PATH="$fake_bin:$PATH" \
		TMUX_PANE="%1" \
		"$preview_bin" --quick-view "$png" --panel right --dry-run >"$out"
	grep -F '"client_tty":"/dev/pts/11"' "$out" >/dev/null ||
		die "image preview quick-view did not include the owning tmux client tty"
	grep -F '"pane":{"pane_id":"%1","session":"work","socket":"/tmp/engineos-tmux"' "$out" >/dev/null ||
		die "image preview quick-view did not include pane identity"

	PATH="$fake_bin:$PATH" \
		ENGINEOS_TERMINAL_ROLE=terminal-secondary \
		TMUX_PANE="%2" \
		"$preview_bin" --quick-view "$png" --panel right --dry-run >"$out"
	if grep -F '"slot":' "$out" >/dev/null; then
		die "image preview quick-view forwarded stale terminal role from tmux server environment"
	fi
	grep -F '"pane_id":"%2"' "$out" >/dev/null ||
		die "image preview quick-view did not preserve the invoking pane identity"

  PATH="$fake_bin:$PATH" \
    TMUX_PANE="%1" \
    "$preview_bin" --quick-view "$png" --panel left --dry-run >"$out"
  for field in '"x":10' '"y":5' '"width":40' '"height":24'; do
    grep -F "$field" "$out" >/dev/null ||
      die "image preview quick-view left panel did not include bounds field $field"
  done

  PATH="$fake_bin:$PATH" \
    TMUX_PANE="%1" \
    "$preview_bin" --quick-view "$png" --panel active --dry-run >"$out"
  for field in '"x":10' '"y":5' '"width":80' '"height":24'; do
    grep -F "$field" "$out" >/dev/null ||
      die "image preview quick-view active panel did not include bounds field $field"
  done

  if "$preview_bin" --view "$tmp_dir/missing.png" --dry-run >"$out" 2>"$err"; then
    die "image preview accepted missing path"
  fi
  grep -F 'cannot read image path' "$err" >/dev/null ||
    die "image preview missing path error was not visible"

  if "$preview_bin" --view "$tmp_dir/dir" --dry-run >"$out" 2>"$err"; then
    die "image preview accepted directory"
  fi
  grep -F 'image path is a directory' "$err" >/dev/null ||
    die "image preview directory error was not visible"

  printf 'not an image\n' >"$tmp_dir/not-image.txt"
  if "$preview_bin" --view "$tmp_dir/not-image.txt" --dry-run >"$out" 2>"$err"; then
    die "image preview accepted unsupported image"
  fi
  grep -F 'unsupported image type' "$err" >/dev/null ||
    die "image preview unsupported type error was not visible"

  if ENGINEOS_PREVIEW_SOCKET="$sock" "$preview_bin" --ping >"$out" 2>"$err"; then
    die "image preview ping should fail when IPC socket is missing"
  fi
  grep -F 'shell preview IPC unavailable' "$err" >/dev/null ||
    die "image preview missing IPC error was not visible"

  python - "$sock" <<'PY' &
import os
import socket
import sys
path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(1)
client, _ = server.accept()
client.recv(4096)
client.sendall(b'{"version":1,"status":"ok","capabilities":["ping"]}\n')
client.close()
server.close()
PY
  local server_pid=$!
  for _ in {1..50}; do
    [[ -S "$sock" ]] && break
    sleep 0.02
  done
  ENGINEOS_PREVIEW_SOCKET="$sock" "$preview_bin" --ping >"$out" 2>"$err"
  wait "$server_pid"
  grep -F 'shell preview IPC ready' "$err" >/dev/null ||
    die "image preview ping success did not report readiness"

  if [[ -x "$shell_bin" ]]; then
    local shell_state="$tmp_dir/shell-state"
    local shell_log="$tmp_dir/shell.log"
    local shell_runtime="$tmp_dir/runtime"
    install -d -m0700 "$shell_runtime"
    ENGINEOS_STATE_DIR="$shell_state" \
      XDG_RUNTIME_DIR="$shell_runtime" \
      WLR_BACKENDS=headless \
      WLR_HEADLESS_OUTPUTS=1 \
      WLR_RENDERER_ALLOW_SOFTWARE=1 \
      "$shell_bin" --headless --smoke-ms 10000 \
        --terminal-secondary true >"$shell_log" 2>&1 &
    shell_pid=$!
    for _ in {1..100}; do
      [[ -S "$shell_state/preview.sock" ]] && break
      sleep 0.03
    done
    [[ -S "$shell_state/preview.sock" ]] ||
      die "compiled shell did not create preview IPC socket"

    ENGINEOS_PREVIEW_SOCKET="$shell_state/preview.sock" "$preview_bin" --ping >"$out" 2>"$err"
    ENGINEOS_SHELL_IPC_SOCKET="$shell_state/preview.sock" \
      ENGINEOS_LOG_DIR="$tmp_dir/logs" \
      "$SCRIPT_DIR/app.sh" terminal register \
        --slot terminal-secondary --tty /dev/pts/11 >"$out"

    command -v foot >/dev/null 2>&1 || die "foot is required for exact pane-token mapping proof"
    PATH="$fake_bin:$PATH" \
      ENGINEOS_LOG_DIR="$tmp_dir/logs" \
      ENGINEOS_STATE_DIR="$shell_state" \
      ENGINEOS_SHELL_IPC_SOCKET="$shell_state/preview.sock" \
      ENGINEOS_FAKE_TMUX_IDENTITY="work @3 2 %1" \
      ENGINEOS_FAKE_TMUX_SOCKET="/tmp/engineos-tmux" \
      ENGINEOS_FAKE_TMUX_GEOMETRY="10 5 80 24 160 48" \
      XDG_RUNTIME_DIR="$shell_runtime" WAYLAND_DISPLAY=wayland-0 \
      TMUX="/tmp/engineos-tmux,1,0" TMUX_PANE="%1" \
      "$SCRIPT_DIR/app.sh" pane launch -- \
        foot --app-id=pane-token-test --title=PaneTokenTest \
          sh -c 'sleep 5' >"$tmp_dir/pane-foot.log" 2>&1 &
    gui_pid=$!
    for _ in {1..100}; do
      grep -Eq '"layout": "tmux-pane-gui".*"pane_key": "tmux:/tmp/engineos-tmux:work:%1"' \
        "$shell_state/shell-state.json" 2>/dev/null && break
      sleep 0.03
    done
    if ! grep -Eq '"layout": "tmux-pane-gui".*"pane_key": "tmux:/tmp/engineos-tmux:work:%1"' \
        "$shell_state/shell-state.json"; then
      cat "$tmp_dir/pane-foot.log" >&2 || true
      tail -n 80 "$shell_log" >&2 || true
      die "compiled shell did not bind the exact-token Wayland client to its pane"
    fi
    grep -F '"terminal_slot": "terminal-secondary"' "$shell_state/shell-state.json" >/dev/null ||
      die "compiled shell did not retain the pane's registered terminal owner"
    if grep -F '"token"' "$shell_state/shell-state.json" >/dev/null; then
      die "compiled shell leaked a pane launch token into shell state"
    fi
    kill "$gui_pid" >/dev/null 2>&1 || true
    wait "$gui_pid" >/dev/null 2>&1 || true
    gui_pid=""

    PATH="$fake_bin:$PATH" \
      ENGINEOS_LOG_DIR="$tmp_dir/logs" \
      ENGINEOS_STATE_DIR="$shell_state" \
      ENGINEOS_SHELL_IPC_SOCKET="$shell_state/preview.sock" \
      ENGINEOS_FAKE_TMUX_IDENTITY="work @3 2 %1" \
      ENGINEOS_FAKE_TMUX_SOCKET="/tmp/engineos-tmux" \
      ENGINEOS_FAKE_TMUX_GEOMETRY="10 5 80 24 160 48" \
      XDG_RUNTIME_DIR="$shell_runtime" WAYLAND_DISPLAY=wayland-0 \
      TMUX="/tmp/engineos-tmux,1,0" TMUX_PANE="%1" \
      "$SCRIPT_DIR/app.sh" pane launch -- sleep 5 >"$tmp_dir/pending.log" 2>&1 &
    pending_pid=$!
    for _ in {1..50}; do
      grep -F '"pending": true' "$shell_state/shell-state.json" >/dev/null 2>&1 && break
      sleep 0.03
    done
    XDG_RUNTIME_DIR="$shell_runtime" WAYLAND_DISPLAY=wayland-0 \
      foot --app-id=pane-missing-token --title=MissingPaneToken \
        sh -c 'sleep 1' >"$tmp_dir/missing-token-foot.log" 2>&1 &
    gui_pid=$!
    wait "$gui_pid" >/dev/null 2>&1 || true
    gui_pid=""
    grep -F 'reason=missing-launch-token' "$shell_log" >/dev/null ||
      die "compiled shell did not reject an un-tokened client during pane launch"
    kill "$pending_pid" >/dev/null 2>&1 || true
    wait "$pending_pid" >/dev/null 2>&1 || true
    pending_pid=""

    XDG_RUNTIME_DIR="$shell_runtime" WAYLAND_DISPLAY=wayland-0 \
      ENGINEOS_PANE_LAUNCH_TOKEN=stale-pane-token \
      foot --app-id=pane-stale-token --title=StalePaneToken \
        sh -c 'sleep 1' >"$tmp_dir/stale-token-foot.log" 2>&1 &
    gui_pid=$!
    wait "$gui_pid" >/dev/null 2>&1 || true
    gui_pid=""
    grep -F 'reason=unknown-or-stale-token' "$shell_log" >/dev/null ||
      die "compiled shell did not reject a stale pane launch token"

    PATH="$fake_bin:$PATH" TMUX_PANE="%1" \
      ENGINEOS_PREVIEW_SOCKET="$shell_state/preview.sock" \
      "$preview_bin" --view "$png" >"$out" 2>"$err"
    PATH="$fake_bin:$PATH" TMUX_PANE="%1" \
      ENGINEOS_PREVIEW_SOCKET="$shell_state/preview.sock" \
      "$preview_bin" --view "$jpg" >"$out" 2>"$err"
    PATH="$fake_bin:$PATH" TMUX_PANE="%1" \
      ENGINEOS_PREVIEW_SOCKET="$shell_state/preview.sock" \
      "$preview_bin" --wallpaper "$png" --opacity 55 >"$out" 2>"$err"
    ENGINEOS_PREVIEW_SOCKET="$shell_state/preview.sock" "$preview_bin" --hide-wallpaper >"$out" 2>"$err"
    ENGINEOS_PREVIEW_SOCKET="$shell_state/preview.sock" "$preview_bin" --hide >"$out" 2>"$err"
    python - "$shell_state/preview.sock" <<'PY'
import socket
import sys
path = sys.argv[1]
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(2.0)
    client.connect(path)
    client.sendall(b'{"version":1,"op":"launch","slot":"terminal-secondary"}\n')
    response = client.recv(4096)
if b'"status":"ok"' not in response:
    raise SystemExit(f"unexpected shell IPC response: {response!r}")
PY
    wait "$shell_pid"
    shell_pid=""

    grep -F "image preview shown path=$png" "$shell_log" | grep -F "image=4x3" >/dev/null ||
      die "compiled shell did not decode and show PNG preview"
    grep -F "image preview shown path=$png" "$shell_log" | grep -F "slot=terminal-secondary" >/dev/null ||
      die "compiled shell did not route the owned preview to the registered terminal"
    grep -F "image preview shown path=$jpg" "$shell_log" | grep -F "image=4x3" >/dev/null ||
      die "compiled shell did not decode and show JPEG preview"
    grep -F "wallpaper shown path=$png" "$shell_log" | grep -F "opacity=55" >/dev/null ||
      die "compiled shell did not decode and show wallpaper"
    grep -F "wallpaper hidden reason=ipc-hide-wallpaper" "$shell_log" >/dev/null ||
      die "compiled shell did not hide wallpaper"
    grep -E "image previews hidden count=1 .*reason=ipc-hide" "$shell_log" >/dev/null ||
      die "compiled shell did not hide image preview"
    grep -F 'launchpad slot unavailable role=terminal-secondary action=launch-requested trigger=ipc-launch' "$shell_log" >/dev/null ||
      die "compiled shell did not accept IPC slot launch"
  fi

  printf 'image preview contract test passed\n'
}

run_app() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-app-test-$$"
  local fake_bin="$tmp_dir/bin"
	  local log_dir="$tmp_dir/logs"
	  local out="$tmp_dir/out.txt"
	  local err="$tmp_dir/err.txt"
	  local launched="$tmp_dir/launched.txt"

  cleanup_app() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_app RETURN

  mkdir -p "$fake_bin" "$log_dir" "$tmp_dir/run"
  cat >"$fake_bin/eos-runtime" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$ENGINEOS_FAKE_APP_LAUNCHED"
FAKE
  cat >"$fake_bin/engineos-cube" <<'FAKE'
#!/usr/bin/env bash
printf 'fake cube %s\n' "$*"
printf 'libdecor=%s\n' "${SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR:-unset}"
FAKE
	cat >"$fake_bin/engine-mux" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ENGINEOS_FAKE_MUX_CALLS"
FAKE
	cat >"$fake_bin/engine-muxctl" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == snapshot ]] || exit 64
printf '%s\n' '{"schema":"engine-mux/snapshot-v1","revision":42,"panes":[{"pane_id":"%9","active":true,"presentation":"game","view_mode":"presentation","mapped":true,"surface_tabs":1,"process_scope":"engine-pane-proof.scope","app_command":"quake"}]}'
FAKE
	  cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "display-message" ]]; then
  format="${*: -1}"
  if [[ "$format" == *session_name* ]]; then
    printf '%s\n' "${ENGINEOS_FAKE_TMUX_IDENTITY:-engineos @1 1 %1}"
    exit 0
  fi
  if [[ "$format" == *socket_path* ]]; then
    printf '%s\n' "${ENGINEOS_FAKE_TMUX_SOCKET:-/tmp/engineos-tmux}"
    exit 0
  fi
  if [[ "$format" == *client_cell_width* ]]; then
    printf '%s\n' "${ENGINEOS_FAKE_TMUX_CELL_SIZE:-9 18}"
    exit 0
  fi
	if [[ "$format" == *client_tty* ]]; then
		printf '%s\n' "${ENGINEOS_FAKE_TMUX_CLIENT_TTY:-/dev/pts/11}"
		exit 0
	fi
  printf '%s\n' "${ENGINEOS_FAKE_TMUX_GEOMETRY:-10 5 80 24 160 48}"
  exit 0
fi
exit 1
FAKE
	chmod +x "$fake_bin/engine-mux" "$fake_bin/engine-muxctl"
  cat >"$fake_bin/pkill" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
  cat >"$fake_bin/pgrep" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
  chmod +x "$fake_bin/eos-runtime" "$fake_bin/engineos-cube" "$fake_bin/tmux" "$fake_bin/pkill" "$fake_bin/pgrep"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
		ENGINEOS_GAME_CMD="$fake_bin/eos-runtime" \
    ENGINEOS_FAKE_APP_LAUNCHED="$launched" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/app.sh" launch quake --smoke >"$out"
	grep -F 'quake play --smoke' "$launched" >/dev/null ||
		die "app launcher did not dispatch quake through the game workflow"
  grep -F 'app launch app=quake owner=engineos-shell display=engineos-test-wayland sdl=wayland args=--smoke' "$log_dir/app.log" >/dev/null ||
    die "app launcher did not log shell-owned quake launch"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
		ENGINEOS_GAME_CMD="$fake_bin/eos-runtime" \
    ENGINEOS_FAKE_APP_LAUNCHED="$launched" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/app.sh" launch quake --map dgen_smoke --game id1 --output >"$out"
	grep -F 'quake play --map dgen_smoke --game id1' "$launched" >/dev/null ||
    die "app launcher did not pass quake map/game arguments"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
		ENGINEOS_GAME_CMD="$fake_bin/eos-runtime" \
    ENGINEOS_FAKE_APP_LAUNCHED="$launched" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    TMUX="$tmp_dir/tmux-socket,1,0" \
    TMUX_PANE="%1" \
    "$SCRIPT_DIR/app.sh" launch quake >"$out"
	grep -F 'quake play --window' "$launched" >/dev/null ||
    die "app launcher did not force pane-bounded quake into windowed mode"
  grep -F 'mode=pane' "$tmp_dir/run/launch-bounds/engine.env" >/dev/null ||
    die "app launcher did not write pane bounds request"
  grep -F 'pane_left=10' "$tmp_dir/run/launch-bounds/engine.env" >/dev/null ||
    die "app launcher pane bounds missing tmux pane left"
  grep -F 'window_height=48' "$tmp_dir/run/launch-bounds/engine.env" >/dev/null ||
    die "app launcher pane bounds missing tmux window height"
  grep -F 'app layout app=quake mode=pane source=tmux bounds=10 5 80 24 160 48' "$log_dir/app.log" >/dev/null ||
    die "app launcher did not log tmux pane bounds"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
		ENGINEOS_GAME_CMD="$fake_bin/eos-runtime" \
    ENGINEOS_FAKE_APP_LAUNCHED="$launched" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    TMUX="$tmp_dir/tmux-socket,1,0" \
    TMUX_PANE="%1" \
    "$SCRIPT_DIR/app.sh" launch quake --fullscreen >"$out"
	grep -F 'quake play --fullscreen' "$launched" >/dev/null ||
    die "app launcher did not pass quake fullscreen flag"
  grep -F 'mode=output' "$tmp_dir/run/launch-bounds/engine.env" >/dev/null ||
    die "app launcher did not clear pane bounds for fullscreen launch"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    TMUX="$tmp_dir/tmux-socket,1,0" \
    TMUX_PANE="%1" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/app.sh" launch cube --smoke >"$out"
  grep -F 'app launch app=cube owner=engineos-shell display=engineos-test-wayland sdl=wayland libdecor=0 args=--smoke' "$log_dir/app.log" >/dev/null ||
    die "app launcher did not log shell-owned cube launch"
  grep -F 'mode=pane' "$tmp_dir/run/launch-bounds/cube.env" >/dev/null ||
    die "app launcher did not write pane bounds request for cube"
  grep -F 'pane_left=10' "$tmp_dir/run/launch-bounds/cube.env" >/dev/null ||
    die "app launcher cube pane bounds missing tmux pane left"
  grep -F 'app layout app=cube mode=pane source=tmux bounds=10 5 80 24 160 48' "$log_dir/app.log" >/dev/null ||
    die "app launcher did not log tmux pane bounds for cube"
  grep -F 'fake cube --smoke' "$log_dir/cube.log" >/dev/null ||
    die "app launcher did not write cube output to cube log"
  grep -F 'libdecor=0' "$log_dir/cube.log" >/dev/null ||
    die "app launcher did not disable libdecor for cube"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_APP_NOTIFY_SHELL=false \
    ENGINEOS_FAKE_TMUX_GEOMETRY="20 6 70 20 160 48" \
    TMUX="$tmp_dir/tmux-socket,1,0" \
    TMUX_PANE="%1" \
    "$SCRIPT_DIR/app.sh" pane sync cube >"$out"
  grep -F 'pane_left=20' "$tmp_dir/run/launch-bounds/cube.env" >/dev/null ||
    die "app pane sync did not refresh cube pane left"
  grep -F 'pane_height=20' "$tmp_dir/run/launch-bounds/cube.env" >/dev/null ||
    die "app pane sync did not refresh cube pane height"
  grep -F 'synced cube pane %1 bounds 20 6 70 20 160 48' "$out" >/dev/null ||
    die "app pane sync did not report refreshed cube bounds"
  grep -F 'app pane sync role=cube source=tmux pane=%1 bounds=20 6 70 20 160 48' "$log_dir/app.log" >/dev/null ||
    die "app pane sync did not log refreshed cube bounds"

  if PATH="$fake_bin:$PATH" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_STATE_DIR="$tmp_dir/run" \
      ENGINEOS_FAKE_TMUX_GEOMETRY="25 8 66 19 160 48" \
      TMUX="$tmp_dir/tmux-socket,1,0" \
      TMUX_PANE="%1" \
      "$SCRIPT_DIR/app.sh" pane sync cube >"$out" 2>&1; then
    die "app pane sync succeeded when shell notification could not be delivered"
  fi
  grep -F 'pane_left=25' "$tmp_dir/run/launch-bounds/cube.env" >/dev/null ||
    die "app pane sync failure path did not refresh cube pane bounds before notifying"
  grep -F 'pane sync notify=failed reason=shell-not-running' "$log_dir/app.log" >/dev/null ||
    die "app pane sync did not log failed shell notification"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_APP_NOTIFY_SHELL=false \
    ENGINEOS_FAKE_TMUX_GEOMETRY="30 7 60 18 160 48" \
    TMUX="$tmp_dir/tmux-socket,1,0" \
    "$SCRIPT_DIR/app.sh" pane sync --all >"$out"
  grep -F 'pane_left=30' "$tmp_dir/run/launch-bounds/cube.env" >/dev/null ||
    die "app pane sync --all did not refresh stored cube pane"
  grep -F 'synced cube pane %1 bounds 30 7 60 18 160 48' "$out" >/dev/null ||
    die "app pane sync --all did not use stored pane id"

  if env -u WAYLAND_DISPLAY -u DISPLAY \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_STATE_DIR="$tmp_dir/run" \
      "$SCRIPT_DIR/app.sh" launch quake --smoke >/dev/null 2>&1; then
    die "app launcher should require WAYLAND_DISPLAY by default"
  fi
  grep -F 'reason=missing-wayland-display app=quake' "$log_dir/app.log" >/dev/null ||
    die "app launcher did not log missing Wayland display"

  ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_STATE_DIR="$tmp_dir/run" \
    "$SCRIPT_DIR/app.sh" --dry-run launch terminal --class EngineOS >"$out"
  grep -F 'EngineOS app launch dry-run' "$out" >/dev/null ||
    die "app launcher dry-run missing header"
  grep -F 'app:      terminal' "$out" >/dev/null ||
    die "app launcher dry-run missing app id"

  cat >"$fake_bin/pkill" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "-HUP" && "$2" == "-x" && "$3" == "engineos-shell" ]]; then
  exit 0
fi
exit 1
FAKE
  chmod +x "$fake_bin/pkill"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    "$SCRIPT_DIR/app.sh" recover preview >"$out"
  grep -F 'requested shell IPC refresh' "$out" >/dev/null ||
    die "app recover preview did not report IPC refresh"
  grep -F 'pane sync notify=signal shell=engineos-shell' "$log_dir/app.log" >/dev/null ||
    die "app recover preview did not notify the running shell"

  local recover_sock="$tmp_dir/recover.sock"
  python - "$recover_sock" "$tmp_dir/recover-request.txt" <<'PY' &
import os
import socket
import sys
sock_path = sys.argv[1]
request_path = sys.argv[2]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(1)
client, _ = server.accept()
request = client.recv(4096)
open(request_path, "wb").write(request)
client.sendall(b'{"version":1,"status":"ok","capabilities":["launch"]}\n')
client.close()
server.close()
PY
  local recover_server_pid=$!
  for _ in {1..50}; do
    [[ -S "$recover_sock" ]] && break
    sleep 0.02
  done
  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_SHELL_IPC_SOCKET="$recover_sock" \
    "$SCRIPT_DIR/app.sh" recover terminal-secondary >"$out"
  wait "$recover_server_pid"
  grep -F 'requested terminal-secondary recovery through running shell' "$out" >/dev/null ||
    die "app recover terminal-secondary did not report shell IPC launch"
  grep -F '"op":"launch","slot":"terminal-secondary"' "$tmp_dir/recover-request.txt" >/dev/null ||
    die "app recover terminal-secondary did not send shell IPC launch request"
  grep -F 'app recover target=terminal-secondary role=terminal-secondary method=shell-ipc socket='"$recover_sock" "$log_dir/app.log" >/dev/null ||
    die "app recover terminal-secondary did not log recovery request"

  printf '[2026-01-01T00:00:00Z] app launch app=terminal owner=engineos-shell display=engineos-test-wayland\n' >>"$log_dir/app.log"
  {
    printf '[2026-01-01T00:00:00Z] bootstrap mode=launchpad\n'
    printf '[2026-01-01T00:00:01Z] launchpad active slot=cube mode=terminal capture=none reason=bootstrap-launchpad\n'
    printf '[2026-01-01T00:00:02Z] view mapped role=cube title=engineos-cube app_id=engineos-cube mapped_total=1\n'
  } >"$log_dir/shell.log"
  cat >"$tmp_dir/run/shell-state.json" <<'JSON'
{
  "schema": "engineos-shell-state-v0",
  "active_slot": "terminal",
  "pending_slot": "unknown",
  "slots": {
    "terminal": {"mapped": true, "visible": true, "layout": "output", "fullscreen": false, "x": 0, "y": 0, "width": 1600, "height": 900, "title": "EngineOS", "app_id": "foot"},
    "cube": {"mapped": true, "visible": true, "layout": "tmux-pane", "fullscreen": false, "x": 200, "y": 100, "width": 700, "height": 375, "title": "engineos-cube", "app_id": "engineos-cube"},
    "engine": {"mapped": false, "visible": false, "layout": "", "fullscreen": false, "x": 0, "y": 0, "width": 0, "height": 0, "title": "", "app_id": ""}
  }
}
JSON
  ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_STATE_DIR="$tmp_dir/run" \
    "$SCRIPT_DIR/app.sh" status --json >"$out"
  grep -F '"active_slot":"terminal"' "$out" >/dev/null ||
    die "app status json did not report shell-state active terminal slot"
  grep -F '"manifest": "' "$out" >/dev/null ||
    die "app status json did not report manifest path"
  grep -F '"terminal": {"app":"terminal","command":"eos-app launch terminal","launch_state":"launch-requested"' "$out" >/dev/null ||
    die "app status json did not report terminal launch state"
  grep -F '"terminal-secondary": {"app":"terminal-secondary","command":"eos-app launch terminal-secondary","launch_state":"missing"' "$out" >/dev/null ||
    die "app status json did not report secondary terminal slot"
  grep -F '"cube": {"app":"cube","command":"eos-app launch cube","launch_state":"launch-requested","mapped":true' "$out" >/dev/null ||
    die "app status json did not report mapped cube state"
  grep -F '"visible":true,"layout":"tmux-pane","fullscreen":false,"x":200,"y":100,"width":700,"height":375' "$out" >/dev/null ||
    die "app status json did not report pane visibility and bounds from shell state"
  grep -F '"shell_last_log":"[2026-01-01T00:00:02Z] view mapped role=cube title=engineos-cube app_id=engineos-cube mapped_total=1"' "$out" >/dev/null ||
    die "app status json did not report shell lifecycle evidence"
  [[ -f "$tmp_dir/run/apps/cube.status" ]] ||
    die "app launcher did not write cube state record"

	  cat >"$tmp_dir/run/shell-state.json" <<'JSON'
{
  "schema": "engineos-shell-state-v0",
  "windows": [
    {"id": 7, "role": "unknown", "focused": false, "visible": true, "minimized": false, "maximized": false, "layout": "tmux-pane-gui", "x": 40, "y": 40, "width": 900, "height": 700, "title": "Falkon", "app_id": "org.kde.falkon", "bound": true, "pane_key": "tmux:/tmp/engineos-tmux:work:%9", "pane_id": "%9"},
    {"id": 2, "role": "terminal", "focused": true, "visible": true, "minimized": false, "maximized": false, "layout": "output", "x": 0, "y": 0, "width": 1600, "height": 900, "title": "EngineOS", "app_id": "foot"}
  ],
  "pane_bindings": [
    {"key": "tmux:/tmp/engineos-tmux:work:%9", "socket": "/tmp/engineos-tmux", "session": "work", "window_id": "@3", "window_index": "2", "pane_id": "%9", "command_label": "falkon", "pending": false, "focused": true, "view_id": 7, "geometry": {"pane_left": 12, "pane_top": 4, "pane_width": 90, "pane_height": 26, "window_width": 180, "window_height": 52, "cell_width": 9, "cell_height": 18}}
  ]
}
JSON
	ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_STATE_DIR="$tmp_dir/run" \
		"$SCRIPT_DIR/app.sh" window list --json >"$out"
	  grep -F '"id":7' "$out" >/dev/null ||
	    die "app window list json did not report Falkon window id"
	  grep -F '"app_id":"org.kde.falkon"' "$out" >/dev/null ||
	    die "app window list json did not report Falkon app id"
	  grep -F '"bound":true' "$out" >/dev/null ||
	    die "app window list json did not report shell-owned pane binding"
	local pane_sock="$tmp_dir/pane.sock"
	python - "$pane_sock" "$tmp_dir/run/shell-state.json" <<'PY' &
import json, os, socket, sys
sock_path, state_path = sys.argv[1:]
try: os.unlink(sock_path)
except FileNotFoundError: pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path); server.listen(1)
client, _ = server.accept(); client.recv(4096)
bindings = json.load(open(state_path, encoding="utf-8"))["pane_bindings"]
client.sendall((json.dumps({"version": 1, "status": "ok", "pane_bindings": bindings}) + "\n").encode())
client.close(); server.close()
PY
	local pane_server_pid=$!
	for _ in {1..50}; do [[ -S "$pane_sock" ]] && break; sleep 0.02; done
	ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_STATE_DIR="$tmp_dir/run" \
		ENGINEOS_SHELL_IPC_SOCKET="$pane_sock" \
		"$SCRIPT_DIR/app.sh" pane list --json >"$out"
	wait "$pane_server_pid"
	  grep -F '"pane_bindings":[{"key":"tmux:/tmp/engineos-tmux:work:%9"' "$out" >/dev/null ||
	    die "app pane list json did not report shell-owned pane binding"
	  if ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_STATE_DIR="$tmp_dir/run" \
	      "$SCRIPT_DIR/app.sh" window bind 7 >"$out" 2>"$err"; then
	    die "deprecated app window bind succeeded"
	  fi
	  grep -F 'eos-app window bind is deprecated' "$err" >/dev/null ||
	    die "deprecated app window bind did not point to pane launch"

	  if env -u TMUX -u TMUX_PANE \
	      ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_STATE_DIR="$tmp_dir/run" \
	      WAYLAND_DISPLAY="engineos-test-wayland" \
	      "$SCRIPT_DIR/app.sh" pane launch -- falkon >"$out" 2>"$err"; then
	    die "app pane launch succeeded without tmux context"
	  fi
	  grep -F 'pane launch requires TMUX and TMUX_PANE' "$err" >/dev/null ||
	    die "app pane launch missing tmux error was not visible"

	  cat >"$fake_bin/fake-gui" <<'FAKE'
#!/usr/bin/env bash
printf 'token=%s\n' "${ENGINEOS_PANE_LAUNCH_TOKEN:-missing}" >"$ENGINEOS_FAKE_GUI_ENV"
printf 'display=%s\n' "${WAYLAND_DISPLAY:-missing}" >>"$ENGINEOS_FAKE_GUI_ENV"
FAKE
	  chmod +x "$fake_bin/fake-gui"
	python - "$pane_sock" "$tmp_dir/pane-launch-request.txt" <<'PY' &
import os
import socket
import sys
sock_path = sys.argv[1]
request_path = sys.argv[2]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(1)
client, _ = server.accept()
request = client.recv(4096)
open(request_path, "wb").write(request)
client.sendall(b'{"version":1,"status":"ok","capabilities":["pane-launch"]}\n')
client.close()
server.close()
PY
	pane_server_pid=$!
	  for _ in {1..50}; do
	    [[ -S "$pane_sock" ]] && break
	    sleep 0.02
	  done
	  PATH="$fake_bin:$PATH" \
	    ENGINEOS_LOG_DIR="$log_dir" \
	    ENGINEOS_STATE_DIR="$tmp_dir/run" \
	    ENGINEOS_SHELL_IPC_SOCKET="$pane_sock" \
	    ENGINEOS_FAKE_GUI_ENV="$tmp_dir/fake-gui-env.txt" \
	    ENGINEOS_FAKE_TMUX_IDENTITY="work @3 2 %9" \
	    ENGINEOS_FAKE_TMUX_SOCKET="/tmp/engineos-tmux" \
	    ENGINEOS_FAKE_TMUX_GEOMETRY="12 4 90 26 180 52" \
	    TMUX="/tmp/engineos-tmux,1,0" \
	    TMUX_PANE="%9" \
	    WAYLAND_DISPLAY="engineos-test-wayland" \
	    "$SCRIPT_DIR/app.sh" pane launch -- fake-gui >"$out"
	  wait "$pane_server_pid"
	  grep -F '"op":"pane-launch"' "$tmp_dir/pane-launch-request.txt" >/dev/null ||
	    die "app pane launch did not send pane-launch IPC"
	  grep -F '"session":"work"' "$tmp_dir/pane-launch-request.txt" >/dev/null ||
	    die "app pane launch did not send tmux session"
	  grep -F '"pane_id":"%9"' "$tmp_dir/pane-launch-request.txt" >/dev/null ||
	    die "app pane launch did not send tmux pane id"
	  grep -F '"pane_width":90' "$tmp_dir/pane-launch-request.txt" >/dev/null ||
	    die "app pane launch did not send pane geometry"
	  grep -F '"cell_height":18' "$tmp_dir/pane-launch-request.txt" >/dev/null ||
	    die "app pane launch did not send tmux cell size"
	  grep -F '"command_label":"fake-gui"' "$tmp_dir/pane-launch-request.txt" >/dev/null ||
	    die "app pane launch did not send command label"
	  grep -F 'token=pane-' "$tmp_dir/fake-gui-env.txt" >/dev/null ||
	    die "app pane launch did not expose launch token to command"

	  python - "$pane_sock" "$tmp_dir/pane-focus-request.txt" <<'PY' &
import os
import socket
import sys
sock_path = sys.argv[1]
request_path = sys.argv[2]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(1)
client, _ = server.accept()
request = client.recv(4096)
open(request_path, "wb").write(request)
client.sendall(b'{"version":1,"status":"ok","capabilities":["pane-focus"]}\n')
client.close()
server.close()
PY
	  pane_server_pid=$!
	  for _ in {1..50}; do
	    [[ -S "$pane_sock" ]] && break
	    sleep 0.02
	  done
	  PATH="$fake_bin:$PATH" \
	    ENGINEOS_LOG_DIR="$log_dir" \
	    ENGINEOS_STATE_DIR="$tmp_dir/run" \
	    ENGINEOS_SHELL_IPC_SOCKET="$pane_sock" \
	    ENGINEOS_FAKE_TMUX_IDENTITY="work @3 2 %9" \
	    ENGINEOS_FAKE_TMUX_SOCKET="/tmp/engineos-tmux" \
	    TMUX="/tmp/engineos-tmux,1,0" \
	    TMUX_PANE="%9" \
	    "$SCRIPT_DIR/app.sh" pane focus >"$out"
	  wait "$pane_server_pid"
	  grep -F 'focused pane %9' "$out" >/dev/null ||
	    die "app pane focus did not report focused pane"
	  grep -F '"op":"pane-focus"' "$tmp_dir/pane-focus-request.txt" >/dev/null ||
	    die "app pane focus did not send pane-focus IPC"
	  grep -F '"session":"work"' "$tmp_dir/pane-focus-request.txt" >/dev/null ||
	    die "app pane focus did not preserve non-engineos session"

	  python - "$pane_sock" "$tmp_dir/pane-geometry-request.txt" <<'PY' &
import os
import socket
import sys
sock_path = sys.argv[1]
request_path = sys.argv[2]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(1)
client, _ = server.accept()
request = client.recv(4096)
open(request_path, "wb").write(request)
client.sendall(b'{"version":1,"status":"ok","capabilities":["pane-geometry"]}\n')
client.close()
server.close()
PY
	  pane_server_pid=$!
	  for _ in {1..50}; do
	    [[ -S "$pane_sock" ]] && break
	    sleep 0.02
	  done
	  PATH="$fake_bin:$PATH" \
	    ENGINEOS_LOG_DIR="$log_dir" \
	    ENGINEOS_STATE_DIR="$tmp_dir/run" \
	    ENGINEOS_SHELL_IPC_SOCKET="$pane_sock" \
	    ENGINEOS_FAKE_TMUX_IDENTITY="work @3 2 %9" \
	    ENGINEOS_FAKE_TMUX_GEOMETRY="0 0 240 66 240 66 240 67" \
	    TMUX="/tmp/engineos-tmux,1,0" \
	    TMUX_PANE="%9" \
	    "$SCRIPT_DIR/app.sh" pane geometry >"$out"
	  wait "$pane_server_pid"
	  grep -F '"op":"pane-geometry"' "$tmp_dir/pane-geometry-request.txt" >/dev/null ||
	    die "app pane geometry did not send pane-geometry IPC"
	  grep -F '"window_height":67' "$tmp_dir/pane-geometry-request.txt" >/dev/null ||
	    die "app pane geometry did not use tmux client height"

  local focus_sock="$tmp_dir/focus.sock"
  python - "$focus_sock" "$tmp_dir/focus-request.txt" <<'PY' &
import os
import socket
import sys
sock_path = sys.argv[1]
request_path = sys.argv[2]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(1)
client, _ = server.accept()
request = client.recv(4096)
open(request_path, "wb").write(request)
client.sendall(b'{"version":1,"status":"ok","capabilities":["focus-window"]}\n')
client.close()
server.close()
PY
  local focus_server_pid=$!
  for _ in {1..50}; do
    [[ -S "$focus_sock" ]] && break
    sleep 0.02
  done
  ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_SHELL_IPC_SOCKET="$focus_sock" \
    "$SCRIPT_DIR/app.sh" window focus 7 >"$out"
  wait "$focus_server_pid"
  grep -F 'focused window 7' "$out" >/dev/null ||
    die "app window focus did not report focused window"
  grep -F '"op":"focus-window","window_id":7' "$tmp_dir/focus-request.txt" >/dev/null ||
    die "app window focus did not send shell IPC focus request"

	python - "$tmp_dir/run/shell-state.json" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    state = json.load(handle)
state["mux"] = {"mode": "native", "connected": True}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
PY
	: >"$tmp_dir/native-mux-calls.txt"
	PATH="$fake_bin:$PATH" ENGINEOS_LOG_DIR="$log_dir" \
		ENGINEOS_STATE_DIR="$tmp_dir/run" \
		ENGINEOS_FAKE_MUX_CALLS="$tmp_dir/native-mux-calls.txt" \
		TMUX="/tmp/engine-mux,1,0" TMUX_PANE="%9" \
		"$SCRIPT_DIR/app.sh" pane launch --game -- quake -window >"$out"
	PATH="$fake_bin:$PATH" ENGINEOS_LOG_DIR="$log_dir" \
		ENGINEOS_STATE_DIR="$tmp_dir/run" \
		ENGINEOS_FAKE_MUX_CALLS="$tmp_dir/native-mux-calls.txt" \
		TMUX="/tmp/engine-mux,1,0" TMUX_PANE="%9" \
		"$SCRIPT_DIR/app.sh" pane launch -- falkon about:blank >"$out"
	PATH="$fake_bin:$PATH" ENGINEOS_LOG_DIR="$log_dir" \
		ENGINEOS_STATE_DIR="$tmp_dir/run" \
		ENGINEOS_FAKE_MUX_CALLS="$tmp_dir/native-mux-calls.txt" \
		TMUX="/tmp/engine-mux,1,0" TMUX_PANE="%9" \
		"$SCRIPT_DIR/app.sh" pane split -v -- falkon -r about:blank >"$out"
	PATH="$fake_bin:$PATH" ENGINEOS_LOG_DIR="$log_dir" \
		ENGINEOS_STATE_DIR="$tmp_dir/run" \
		ENGINEOS_FAKE_MUX_CALLS="$tmp_dir/native-mux-calls.txt" \
		TMUX="/tmp/engine-mux,1,0" TMUX_PANE="%9" \
		"$SCRIPT_DIR/app.sh" pane split -h --game -- quake -window >"$out"
	PATH="$fake_bin:$PATH" ENGINEOS_STATE_DIR="$tmp_dir/run" \
		ENGINEOS_FAKE_MUX_CALLS="$tmp_dir/native-mux-calls.txt" \
		TMUX_PANE="%9" "$SCRIPT_DIR/app.sh" pane view console
	PATH="$fake_bin:$PATH" ENGINEOS_STATE_DIR="$tmp_dir/run" \
		ENGINEOS_FAKE_MUX_CALLS="$tmp_dir/native-mux-calls.txt" \
		TMUX_PANE="%9" "$SCRIPT_DIR/app.sh" pane signal TERM
	PATH="$fake_bin:$PATH" ENGINEOS_STATE_DIR="$tmp_dir/run" \
		ENGINEOS_FAKE_MUX_CALLS="$tmp_dir/native-mux-calls.txt" \
		TMUX_PANE="%9" "$SCRIPT_DIR/app.sh" pane respawn
	PATH="$fake_bin:$PATH" ENGINEOS_LOG_DIR="$log_dir" \
		ENGINEOS_STATE_DIR="$tmp_dir/run" \
		ENGINEOS_FAKE_MUX_CALLS="$tmp_dir/native-mux-calls.txt" \
		ENGINEOS_GAME_CMD="$fake_bin/eos-runtime" \
		TMUX="/tmp/engine-mux,1,0" TMUX_PANE="%9" \
		WAYLAND_DISPLAY="engineos-test-wayland" \
		"$SCRIPT_DIR/app.sh" launch quake --map native_proof >"$out"
	PATH="$fake_bin:$PATH" ENGINEOS_STATE_DIR="$tmp_dir/run" \
		"$SCRIPT_DIR/app.sh" pane list --json >"$out"
	grep -Fx 'launch-pane-app -g -t %9 -- quake -window' \
		"$tmp_dir/native-mux-calls.txt" >/dev/null ||
		die "native app pane launch did not select authoritative game presentation"
	grep -Fx 'launch-pane-app -t %9 -- falkon --no-remote about:blank' \
		"$tmp_dir/native-mux-calls.txt" >/dev/null ||
		die "native Falkon launch did not add the dedicated-instance adapter"
	grep -Fx 'split-pane-app -v -t %9 -- falkon -r about:blank' \
		"$tmp_dir/native-mux-calls.txt" >/dev/null ||
		die "native Falkon split duplicated an explicit dedicated-instance flag"
	grep -Fx 'split-pane-app -h -g -t %9 -- quake -window' \
		"$tmp_dir/native-mux-calls.txt" >/dev/null ||
		die "native app pane split did not preserve orientation and game presentation"
	grep -Fx 'pane-presentation -t %9 console' \
		"$tmp_dir/native-mux-calls.txt" >/dev/null ||
		die "native app pane view did not route to engine-mux"
	grep -Fx 'signal-pane-app -t %9 TERM' \
		"$tmp_dir/native-mux-calls.txt" >/dev/null ||
		die "native app pane signal did not route to engine-mux"
	grep -Fx 'respawn-pane-app -t %9' "$tmp_dir/native-mux-calls.txt" >/dev/null ||
		die "native app pane respawn did not route to engine-mux"
	grep -Fx "launch-pane-app -g -t %9 -- $fake_bin/eos-runtime quake play --foreground --map native_proof --window" \
		"$tmp_dir/native-mux-calls.txt" >/dev/null ||
		die "native Quake launch did not route through a game pane"
	grep -F 'launch app=quake owner=native-mux pane=%9' "$log_dir/app.log" >/dev/null ||
		die "native Quake launch did not record mux ownership"
	grep -F '"revision":42' "$out" >/dev/null &&
		grep -F '"presentation":"game"' "$out" >/dev/null ||
		die "native app pane list did not return authoritative mux state"

  "$SCRIPT_DIR/app.sh" manifest validate >"$out"
  grep -F 'App manifest validation summary: 0 failure(s)' "$out" >/dev/null ||
    die "app manifest validation did not pass"
  grep -F 'cube.app_ids contains engineos-cube' "$out" >/dev/null ||
    die "app manifest validation did not check cube app id"
  grep -F 'terminal-secondary.app_ids contains engineos-terminal-secondary' "$out" >/dev/null ||
    die "app manifest validation did not check secondary terminal app id"
  grep -F 'falkon.instance = dedicated' "$out" >/dev/null ||
    die "app manifest validation did not require dedicated Falkon instances"
  grep -F 'falkon.app_ids contains org.kde.falkon' "$out" >/dev/null ||
    die "app manifest validation did not check Falkon app id"

  printf 'app launcher smoke test passed\n'
}

run_level_agent() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-level-agent-test-$$"
  local fake_bin="$tmp_dir/bin"
  local sock="$tmp_dir/run/level-agent.sock"
  local out="$tmp_dir/out.txt"
  local launch_args="$tmp_dir/launch-args.txt"
  local server_pid=""

  cleanup_level_agent() {
    if [[ -n "$server_pid" ]]; then
      kill "$server_pid" >/dev/null 2>&1 || true
      wait "$server_pid" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp_dir"
  }
  trap cleanup_level_agent RETURN

  mkdir -p "$fake_bin" "$tmp_dir/run" "$tmp_dir/state" "$tmp_dir/logs" "$tmp_dir/dgen-root/src" "$tmp_dir/quake/id1"

  cat >"$fake_bin/fake-codex-mcp" <<'PY'
#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path

for line in sys.stdin:
    request = json.loads(line)
    request_id = request.get("id")
    method = request.get("method")
    if method == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": "2024-11-05", "capabilities": {}, "serverInfo": {"name": "fake-codex"}}}), flush=True)
    elif method == "notifications/initialized":
        continue
    elif method == "tools/call":
        args = request["params"]["arguments"]
        prompt = args["prompt"]
        cwd = Path(args.get("cwd", "."))
        match = re.search(r"jobs/[^\s]+/job\.dungeon", prompt)
        rel = match.group(0) if match else "jobs/fallback/job.dungeon"
        path = cwd / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("""dungeon fake_agent_job
version dungeon-spec/v2
seed 77
layout linear
tag dynamic
tag meaning
beat gate role entry count 1 require [entry vertical] meaning [entry combat]
beat flood role hazard_combat count 1 require [water vertical] meaning [hazard combat]
""", encoding="utf-8")
        print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": {"structuredContent": {"threadId": "thread-1", "content": "wrote dungeon"}}}), flush=True)
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": request_id, "error": {"message": "unknown method"}}), flush=True)
PY
  cat >"$fake_bin/dgen" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "build-dungeon" ]] || exit 64
shift
dungeon="$1"
shift
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      shift
      out="$1"
      ;;
  esac
  shift || true
done
[[ -n "$out" ]] || exit 65
grep -F 'version dungeon-spec/v2' "$dungeon" >/dev/null
mkdir -p "$(dirname "$out")"
printf '// fake map\n' >"$out"
printf 'fake bsp\n' >"${out%.map}.bsp"
printf 'wrote: %s\n' "$out"
FAKE
	cat >"$fake_bin/eos-game" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$ENGINEOS_FAKE_LEVEL_AGENT_LAUNCH"
if [[ "$1 $2" == "quake reload" ]]; then
	shift 2
	bsp="" map=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--bsp) shift; bsp="$1" ;;
			--map) shift; map="$1" ;;
		esac
		shift
	done
	mkdir -p "$ENGINEOS_QUAKE_ID1/maps"
	cp "$bsp" "$ENGINEOS_QUAKE_ID1/maps/$map.bsp"
fi
FAKE
	chmod +x "$fake_bin/fake-codex-mcp" "$fake_bin/dgen" "$fake_bin/eos-game"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_CODEX_MCP_COMMAND="$fake_bin/fake-codex-mcp" \
    ENGINEOS_LEVEL_AGENT_DGEN_CMD="$fake_bin/dgen" \
    ENGINEOS_LEVEL_AGENT_STATE_DIR="$tmp_dir/state" \
    ENGINEOS_LEVEL_AGENT_LOG_DIR="$tmp_dir/logs" \
    ENGINEOS_DGEN_ROOT="$tmp_dir/dgen-root" \
    ENGINEOS_QUAKE_ID1="$tmp_dir/quake/id1" \
    ENGINEOS_FAKE_LEVEL_AGENT_LAUNCH="$launch_args" \
		ENGINEOS_LEVEL_AGENT_GAME_CMD="$fake_bin/eos-game" \
    "$ROOT/tools/level-agent/engineos-level-agent" serve --socket "$sock" >"$tmp_dir/server.log" 2>&1 &
  server_pid="$!"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -S "$sock" ]] && break
    sleep 0.1
  done
  [[ -S "$sock" ]] || die "level-agent server did not create socket"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LEVEL_AGENT_STATE_DIR="$tmp_dir/state" \
    ENGINEOS_LEVEL_AGENT_LOG_DIR="$tmp_dir/logs" \
    ENGINEOS_DGEN_ROOT="$tmp_dir/dgen-root" \
    "$ROOT/tools/level-agent/engineos-level-agent" build "make a short flooded gatehouse descent" --wait --socket "$sock" >"$out"
  grep -F 'state=accepted' "$out" >/dev/null ||
    die "level-agent build did not reach accepted state"
  grep -F 'map=make_a_short_flooded_gatehouse' "$out" >/dev/null ||
    die "level-agent build did not derive stable map name"
  local level_job_id
  level_job_id="$(sed -n 's/^job=\([^ ]*\).*/\1/p' "$out")"
  [[ -n "$level_job_id" ]] || die "level-agent build did not report a job id"
  [[ "$(stat -c '%a' "$tmp_dir/state/jobs/$level_job_id/job.json")" == 600 ]] ||
    die "level-agent job state is not private"
  [[ "$(stat -c '%a' "$tmp_dir/state")" == 700 ]] ||
    die "level-agent state directory is not private"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LEVEL_AGENT_STATE_DIR="$tmp_dir/state" \
    "$ROOT/tools/level-agent/engineos-level-agent" status --socket "$sock" >"$out"
  grep -F 'state=accepted' "$out" >/dev/null ||
    die "level-agent status did not report accepted job"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_QUAKE_ID1="$tmp_dir/quake/id1" \
    ENGINEOS_FAKE_LEVEL_AGENT_LAUNCH="$launch_args" \
		ENGINEOS_LEVEL_AGENT_GAME_CMD="$fake_bin/eos-game" \
    ENGINEOS_LEVEL_AGENT_STATE_DIR="$tmp_dir/state" \
    "$ROOT/tools/level-agent/engineos-level-agent" load --socket "$sock" >"$out"
  grep -F 'loaded make_a_short_flooded_gatehouse' "$out" >/dev/null ||
    die "level-agent load did not report loaded map"
	grep -F 'quake reload --bsp ' "$launch_args" | grep -F -- '--map make_a_short_flooded_gatehouse' >/dev/null ||
		die "level-agent load did not reload Quake through eos-game with the accepted map"
  [[ -f "$tmp_dir/quake/id1/maps/make_a_short_flooded_gatehouse.bsp" ]] ||
    die "level-agent load did not deploy BSP into id1/maps"

  python "$ROOT/tools/scripts/generate_dgen_wad.py" --out "$tmp_dir/engineos-dgen.wad"
  python - "$tmp_dir/engineos-dgen.wad" <<'PY'
from pathlib import Path
import sys
data = Path(sys.argv[1]).read_bytes()
assert data[:4] == b"WAD2"
assert b"wizmet1_1" in data
PY

  ENGINEOS_TRENCHBROOM_USER_DIR="$tmp_dir/tb" \
    ENGINEOS_QUAKE_ID1="$tmp_dir/quake/id1" \
    "$ROOT/tools/level-agent/engineos-level-agent" trenchbroom-setup >"$out"
  grep -F 'EngineOS Quake' "$tmp_dir/tb/games/EngineOSQuake/GameConfig.cfg" >/dev/null ||
    die "trenchbroom setup did not write EngineOS game config"
  grep -F '"definitions": [ "Quake.fgd", "Quoth2.fgd", "Rubicon2.def", "Teamfortress.fgd" ]' "$tmp_dir/tb/games/EngineOSQuake/GameConfig.cfg" >/dev/null ||
    die "trenchbroom setup did not write direct EngineOS Quake entity definitions"
  grep -F '"palette": "gfx/palette.lmp"' "$tmp_dir/tb/games/EngineOSQuake/GameConfig.cfg" >/dev/null ||
    die "trenchbroom setup did not write Quake model palette path"
  ! grep -F 'Quake/Quake.fgd' "$tmp_dir/tb/games/EngineOSQuake/GameConfig.cfg" >/dev/null ||
    die "trenchbroom setup wrote stale nested Quake entity definition path"
  [[ -f "$tmp_dir/tb/games/EngineOSQuake/Quake.fgd" ]] ||
    die "trenchbroom setup did not copy Quake.fgd into the EngineOS game profile"
  python - "$tmp_dir/tb/Preferences.json" "$tmp_dir/quake" <<'PY' ||
import json
import sys
from pathlib import Path

prefs = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = sys.argv[2]
assert prefs["Games/EngineOS Quake/Path"] == expected
assert prefs["Games/EngineOSQuake/Path"] == expected
assert prefs["Games/Quake/Path"] == expected
PY
    die "trenchbroom setup did not write EngineOS Quake game path preferences"
  grep -F '"version": 1' "$tmp_dir/tb/games/EngineOSQuake/CompilationProfiles.cfg" >/dev/null ||
    die "trenchbroom setup did not write compilation profile schema version"
  grep -F '/usr/bin/qbsp' "$tmp_dir/tb/games/EngineOSQuake/CompilationProfiles.cfg" >/dev/null ||
    die "trenchbroom setup did not write ericw tool paths"
  grep -F '"version": 1' "$tmp_dir/tb/games/EngineOSQuake/Engines.cfg" >/dev/null ||
    die "trenchbroom setup did not write engine profile schema version"
  grep -F 'launch quake --map ${MAP_BASE_NAME}' "$tmp_dir/tb/games/EngineOSQuake/Engines.cfg" >/dev/null ||
    die "trenchbroom setup did not write EngineOS launch profile"

  kill "$server_pid"
  wait "$server_pid" >/dev/null 2>&1 || true
  server_pid=""
  if PATH="$fake_bin:$PATH" \
      ENGINEOS_LEVEL_AGENT_STATE_DIR="$tmp_dir/state" \
      "$ROOT/tools/level-agent/engineos-level-agent" load \
        --socket "$sock" >"$out" 2>"$tmp_dir/load.err"; then
    die "level-agent load silently fell back when the sidecar was unavailable"
  fi
  grep -F 'use --inline for one-shot loading' "$tmp_dir/load.err" >/dev/null ||
    die "level-agent load did not explain the explicit inline fallback"

  printf 'level-agent socket contract test passed\n'
}

run_assets() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-assets-test-$$"
  local id1="$tmp_dir/home/.local/share/engineos/quake/id1"
  local log_dir="$tmp_dir/logs"
  local fake_bin="$tmp_dir/bin/quakespasm"

  cleanup_assets() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_assets RETURN

  mkdir -p "$tmp_dir/home" "$tmp_dir/bin" "$log_dir"

  if HOME="$tmp_dir/home" "$SCRIPT_DIR/assets.sh" check quake >/dev/null 2>&1; then
    die "assets test expected missing Quake assets to fail"
  fi

  HOME="$tmp_dir/home" "$SCRIPT_DIR/assets.sh" prepare quake >/dev/null
  [[ -d "$id1" ]] || die "assets prepare did not create default id1 directory"
  printf 'test pak placeholder\n' >"$id1/pak0.pak"

  [[ "$(HOME="$tmp_dir/home" "$SCRIPT_DIR/assets.sh" path quake)" == "$id1" ]] ||
    die "assets path did not resolve default id1 directory"

  local config_id1="$tmp_dir/config-id1"
  mkdir -p "$tmp_dir/home/.config/engineos" "$config_id1"
  printf 'ENGINEOS_QUAKE_ID1=%s\n' "$config_id1" >"$tmp_dir/home/.config/engineos/quake.conf"
  printf 'config pak placeholder\n' >"$config_id1/pak0.pak"
  [[ "$(HOME="$tmp_dir/home" "$SCRIPT_DIR/assets.sh" path quake)" == "$config_id1" ]] ||
    die "assets path did not honor user config"

  local env_id1="$tmp_dir/env-id1"
  mkdir -p "$env_id1"
  printf 'env pak placeholder\n' >"$env_id1/pak0.pak"
  [[ "$(HOME="$tmp_dir/home" ENGINEOS_QUAKE_ID1="$env_id1" "$SCRIPT_DIR/assets.sh" path quake)" == "$env_id1" ]] ||
    die "assets path did not prefer environment override"

  cat >"$fake_bin" <<'FAKE'
#!/usr/bin/env bash
printf 'fake quakespasm args: %s\n' "$*"
FAKE
  chmod +x "$fake_bin"

  HOME="$tmp_dir/home" \
    ENGINEOS_QUAKE_ID1="$id1" \
    ENGINEOS_QUAKE_SDL_AUDIODRIVER="pulseaudio" \
    ENGINEOS_QUAKE_ARGS="-window -width 640 -height 480" \
    PATH="$tmp_dir/bin:$PATH" \
    ENGINEOS_ROOT="$ROOT" \
    ENGINEOS_LOG_DIR="$log_dir" \
    QUAKESPASM_BIN="quakespasm" \
    "$ROOT/engines/quakespasm/engineos/run.sh" >/dev/null

  grep -F "QuakeSpasm basedir=$tmp_dir/home/.local/share/engineos/quake" "$log_dir/engine.log" >/dev/null ||
    die "quake run wrapper did not log resolved basedir"
  grep -F "QuakeSpasm audio_driver=pulseaudio" "$log_dir/engine.log" >/dev/null ||
    die "quake run wrapper did not log configured SDL audio driver"
  grep -F "QuakeSpasm configured_args=-window -width 640 -height 480" "$log_dir/engine.log" >/dev/null ||
    die "quake run wrapper did not log configured launch args"
  HOME="$tmp_dir/home" \
    ENGINEOS_QUAKE_ID1="$id1" \
    ENGINEOS_QUAKE_ARGS="" \
    PATH="$tmp_dir/bin:$PATH" \
    ENGINEOS_ROOT="$ROOT" \
    ENGINEOS_LOG_DIR="$log_dir" \
    QUAKESPASM_BIN="quakespasm" \
    "$ROOT/engines/quakespasm/engineos/run.sh" --map dgen_smoke --game id1 >/dev/null
  grep -F "QuakeSpasm configured_args=-game id1 +map dgen_smoke" "$log_dir/engine.log" >/dev/null ||
    die "quake run wrapper did not translate map/game launch args"
  [[ -f "$id1/autoexec.cfg" ]] ||
    die "quake run wrapper did not create default autoexec.cfg"
  grep -F 'bind "w" "+forward"' "$id1/autoexec.cfg" >/dev/null ||
    die "quake default autoexec missing WASD forward binding"
  grep -F 'bind "MOUSE2" "+jump"' "$id1/autoexec.cfg" >/dev/null ||
    die "quake default autoexec missing mouse jump binding"
  grep -F '+mlook' "$id1/autoexec.cfg" >/dev/null ||
    die "quake default autoexec missing mouselook"

  local installed_log_dir="$tmp_dir/installed-logs"
  ENGINEOS_ROOT="/usr" \
    ENGINEOS_LOG_DIR="$installed_log_dir" \
    ENGINEOS_LOG_TEE=false \
    QUAKESPASM_BIN="quakespasm" \
    PATH="$tmp_dir/bin:$PATH" \
    "$ROOT/engines/quakespasm/engineos/run.sh" --smoke >/dev/null
  [[ -f "$installed_log_dir/engine.log" ]] ||
    die "quake installed-mode smoke did not write to configured log dir"
  grep -F 'QuakeSpasm smoke wrapper' "$installed_log_dir/engine.log" >/dev/null ||
    die "quake installed-mode smoke did not log expected marker"
  grep -F 'result=ok' "$installed_log_dir/engine.log" >/dev/null ||
    die "quake installed-mode smoke did not report real binary success"
  if [[ -e /usr/artifacts ]]; then
    die "quake installed-mode smoke created /usr/artifacts"
  fi

  local installed_root="$tmp_dir/installed-prefix/usr"
  local installed_script_dir="$tmp_dir/installed-scripts"
  local installed_env_out="$tmp_dir/installed-env.txt"
  mkdir -p "$installed_root/bin" "$installed_root/lib/engineos/scripts" "$installed_root/tools/scripts" "$installed_script_dir"
  cp "$ROOT/tools/engineos/eos" "$installed_root/bin/eos"
  cp "$ROOT/tools/engineos/eos-wrapper" "$installed_root/bin/eos-terminal"
  cat >"$installed_script_dir/terminal_launcher.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$ENGINEOS_LOG_DIR" >"$installed_env_out"
EOF
  chmod +x "$installed_root/bin/eos" "$installed_root/bin/eos-terminal" "$installed_script_dir/terminal_launcher.sh"
  env -u ENGINEOS_LOG_DIR \
    ENGINEOS_ROOT="$installed_root" \
    ENGINEOS_SCRIPT_DIR="$installed_script_dir" \
    "$installed_root/bin/eos-terminal" >/dev/null
  [[ "$(cat "$installed_env_out")" == "/var/log/engineos" ]] ||
    die "eos-installed-prefix default log dir was not /var/log/engineos"
  if [[ -e "$installed_root/artifacts" ]]; then
    die "eos-installed-prefix default created artifacts under installed root"
  fi

  printf 'assets smoke test passed\n'
}

run_reliability() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-reliability-$$"
  local log_dir="$tmp_dir/logs"
  local bundle_dir="$tmp_dir/bundle"
  local fake_bin="$tmp_dir/bin"
  local drm_sysfs="$tmp_dir/sys/class/drm"
  local runtime_conf="$tmp_dir/runtime.conf"
  local recovery_help=""
  local runtime_start=""
  local runtime_login_profile=""
  local runtime_issue=""

	cleanup_reliability() {
		rm -rf "$tmp_dir" || {
      sleep 0.2
      rm -rf "$tmp_dir"
    }
  }
  trap cleanup_reliability RETURN

  mkdir -p "$log_dir" "$bundle_dir" "$fake_bin" "$tmp_dir/home" "$tmp_dir/run" "$drm_sysfs/card0-HDMI-A-1"
  printf 'connected\n' >"$drm_sysfs/card0-HDMI-A-1/status"
  printf 'enabled\n' >"$drm_sysfs/card0-HDMI-A-1/enabled"
  printf '1920x1080\n1280x720\n' >"$drm_sysfs/card0-HDMI-A-1/modes"

  if command -v engineos-recovery-help >/dev/null 2>&1; then
    recovery_help="$(command -v engineos-recovery-help)"
  elif [[ -x "$ROOT/archiso/engineruntime/airootfs/usr/local/bin/engineos-recovery-help" ]]; then
    recovery_help="$ROOT/archiso/engineruntime/airootfs/usr/local/bin/engineos-recovery-help"
  fi
  [[ -x "$recovery_help" ]] || die "runtime recovery helper is not executable"

  if command -v engineos-runtime-start >/dev/null 2>&1; then
    runtime_start="$(command -v engineos-runtime-start)"
  elif [[ -x "$ROOT/archiso/engineruntime/airootfs/usr/local/bin/engineos-runtime-start" ]]; then
    runtime_start="$ROOT/archiso/engineruntime/airootfs/usr/local/bin/engineos-runtime-start"
  fi
  [[ -x "$runtime_start" ]] || die "runtime start helper is not executable"

  "$recovery_help" >"$tmp_dir/recovery-help.txt"
  grep -F 'eos-logs runtime --last 200' "$tmp_dir/recovery-help.txt" >/dev/null ||
    die "runtime recovery helper does not point to runtime logs"
  grep -F 'eos-crash-bundle' "$tmp_dir/recovery-help.txt" >/dev/null ||
    die "runtime recovery helper does not point to crash bundle"
  grep -F 'engineos.noautostart' "$tmp_dir/recovery-help.txt" >/dev/null ||
    die "runtime recovery helper does not mention autostart disable flag"

  if [[ -r "$ROOT/archiso/engineruntime/airootfs/etc/skel/.bash_profile" ]]; then
    runtime_login_profile="$ROOT/archiso/engineruntime/airootfs/etc/skel/.bash_profile"
  elif [[ -r /etc/skel/.bash_profile ]]; then
    runtime_login_profile="/etc/skel/.bash_profile"
  elif [[ -r "${HOME:-}/.bash_profile" ]]; then
    runtime_login_profile="${HOME}/.bash_profile"
  fi
  [[ -r "$runtime_login_profile" ]] || die "runtime login profile is not readable"
  grep -F 'engineos-recovery-help' "$runtime_login_profile" >/dev/null ||
    die "runtime login profile does not show recovery helper"

  if [[ -r "$ROOT/archiso/engineruntime/airootfs/etc/issue" ]]; then
    runtime_issue="$ROOT/archiso/engineruntime/airootfs/etc/issue"
  elif [[ -r /etc/issue ]]; then
    runtime_issue="/etc/issue"
  fi
  [[ -r "$runtime_issue" ]] || die "runtime issue file is not readable"
  grep -F 'eos-logs runtime --last 200' "$runtime_issue" >/dev/null ||
    die "runtime issue does not point to runtime logs"

  printf 'shell failure marker\n' >"$log_dir/shell.log"
  printf 'engine failure marker\n' >"$log_dir/engine.log"
  printf 'ENGINEOS_RUNTIME_AUTOSTART=1\nENGINEOS_RUNTIME_SHELL_MODE=--headless\n' >"$runtime_conf"
  cat >"$fake_bin/eos-runtime" <<'FAKE'
#!/usr/bin/env bash
printf 'fake eos-runtime failure: %s\n' "$*" >&2
exit 77
FAKE
  chmod +x "$fake_bin/eos-runtime"
  cat >"$fake_bin/ip" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "addr show")
    printf '1: lo: <LOOPBACK,UP> mtu 65536\n'
    printf '2: eth0: <BROADCAST,UP> mtu 1500\n'
    ;;
  "route show"|"route show default")
    printf 'default via 192.0.2.1 dev eth0 proto dhcp\n'
    ;;
  *)
    printf 'fake ip: %s\n' "$*" >&2
    exit 2
    ;;
esac
FAKE
  chmod +x "$fake_bin/ip"
  cat >"$fake_bin/nmcli" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "general status")
    printf 'STATE CONNECTIVITY WIFI-HW WIFI WWAN-HW WWAN\n'
    printf 'connected full enabled enabled enabled enabled\n'
    ;;
  "device status")
    printf 'DEVICE TYPE STATE CONNECTION\n'
    printf 'eth0 ethernet connected EngineOS test\n'
    ;;
  *)
    printf 'fake nmcli: %s\n' "$*" >&2
    exit 2
    ;;
esac
FAKE
  chmod +x "$fake_bin/nmcli"
  cat >"$fake_bin/resolvectl" <<'FAKE'
#!/usr/bin/env bash
[[ "$*" == "status" ]] || exit 2
printf 'Global\n'
printf '       DNS Servers: 192.0.2.53\n'
FAKE
  chmod +x "$fake_bin/resolvectl"

  if ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_RUNTIME_CMD="$fake_bin/eos-runtime" \
      "$runtime_start" >/dev/null 2>&1; then
    die "reliability test expected runtime shell failure"
  fi

  grep -F 'EngineOS shell failed rc=77' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime failure was not logged"
  grep -F 'recovery hint: switch to tty2 and run engineos-recovery-help' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime failure log did not include recovery helper hint"
  grep -F 'recovery logs: eos-logs runtime --last 200' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime failure log did not include runtime logs hint"
  grep -F 'recovery bundle: eos-crash-bundle' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime failure log did not include crash bundle hint"

  printf 'ENGINEOS_RUNTIME_AUTOSTART=0\nENGINEOS_RUNTIME_SHELL_MODE=--headless\n' >"$runtime_conf"
  if ! ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_RUNTIME_CMD="$fake_bin/eos-runtime" \
      "$runtime_start" >/dev/null 2>&1; then
    die "reliability test expected runtime config disable to succeed"
  fi
  grep -F 'runtime autostart disabled by runtime.conf' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime config disable was not logged"
  grep -F 'recovery hint: switch to tty2 and run engineos-recovery-help' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime config disable log did not include recovery helper hint"

  printf 'ENGINEOS_RUNTIME_AUTOSTART=1\nENGINEOS_RUNTIME_SHELL_MODE=--headless\n' >"$runtime_conf"
  printf 'quiet engineos.noautostart\n' >"$tmp_dir/cmdline"
  if ! ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_PROC_CMDLINE="$tmp_dir/cmdline" \
      ENGINEOS_RUNTIME_CMD="$fake_bin/eos-runtime" \
      "$runtime_start" >/dev/null 2>&1; then
    die "reliability test expected runtime kernel disable to succeed"
  fi
  grep -F 'runtime autostart disabled by kernel command line' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime kernel disable was not logged"
  grep -F 'recovery logs: eos-logs runtime --last 200' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime kernel disable log did not include runtime logs hint"

  mkdir -p "$tmp_dir/run"
  cat >"$tmp_dir/run/shell-state.json" <<'JSON'
{
  "schema": "engineos-shell-state-v0",
  "active_slot": "cube",
  "bootstrap": "launchpad",
  "slots": {
    "cube": {"mapped": true, "visible": true}
  }
}
JSON

  rm -f "$fake_bin/eos-runtime"
  HOME="$tmp_dir/home" \
    XDG_CONFIG_HOME="$tmp_dir/home/.config" \
    GOCACHE="$tmp_dir/go-build-cache" \
    GOMODCACHE="$tmp_dir/go-mod-cache" \
    GOTELEMETRY=off \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_CRASH_BUNDLE_DIR="$bundle_dir" \
    ENGINEOS_DRM_SYSFS="$drm_sysfs" \
    PATH="$fake_bin:$PATH" \
    "$SCRIPT_DIR/crash_bundle.sh" --runtime >/dev/null

  [[ -f "$bundle_dir/metadata.txt" ]] || die "crash bundle missing metadata"
  [[ -f "$bundle_dir/doctor.txt" ]] || die "crash bundle missing doctor output"
  [[ -f "$bundle_dir/outputs.txt" ]] || die "crash bundle missing output state"
  [[ -f "$bundle_dir/app-status.json" ]] || die "crash bundle missing app status"
  [[ -f "$bundle_dir/app-manifest-validate.txt" ]] || die "crash bundle missing app manifest validation"
  [[ -f "$bundle_dir/state/shell-state.json" ]] || die "crash bundle missing shell state"
  [[ -f "$bundle_dir/config/apps.toml" ]] || die "crash bundle missing app manifest config"
  [[ -f "$bundle_dir/network-summary.txt" ]] || die "crash bundle missing network summary"
  [[ -f "$bundle_dir/network/ip-address.txt" ]] || die "crash bundle missing ip address output"
  [[ -f "$bundle_dir/network/ip-route.txt" ]] || die "crash bundle missing ip route output"
  [[ -f "$bundle_dir/network/resolvectl-status.txt" ]] || die "crash bundle missing resolvectl output"
  [[ -f "$bundle_dir/network/nmcli-device.txt" ]] || die "crash bundle missing nmcli device output"
  [[ -f "$bundle_dir/assets-quake.txt" ]] || die "crash bundle missing asset check"
  [[ -f "$bundle_dir/assets-quake-explain.txt" ]] || die "crash bundle missing asset explanation"
  [[ -f "$bundle_dir/logs/shell.log" ]] || die "crash bundle missing shell log"
  [[ -f "$bundle_dir/logs/engine.log" ]] || die "crash bundle missing engine log"
  [[ -f "$bundle_dir/logs/runtime-start.log" ]] || die "crash bundle missing runtime log"
  grep -F 'mode=runtime' "$bundle_dir/metadata.txt" >/dev/null ||
    die "crash bundle metadata did not record runtime mode"
  grep -F 'doctor.sh --vm' "$bundle_dir/doctor.txt" >/dev/null ||
    die "runtime crash bundle did not run VM doctor mode"
  grep -F '"slots": {' "$bundle_dir/app-status.json" >/dev/null ||
    die "crash bundle app status did not include slot state"
  grep -F '"schema": "engineos-shell-state-v0"' "$bundle_dir/state/shell-state.json" >/dev/null ||
    die "crash bundle shell state did not preserve schema"
  grep -F 'App manifest validation summary: 0 failure(s)' "$bundle_dir/app-manifest-validate.txt" >/dev/null ||
    die "crash bundle app manifest validation did not pass"
  grep -F '[apps.cube]' "$bundle_dir/config/apps.toml" >/dev/null ||
    die "crash bundle app manifest did not include cube section"
  grep -F 'Quake assets missing' "$bundle_dir/assets-quake.txt" >/dev/null ||
    die "crash bundle asset check did not capture missing asset failure"
  grep -F 'connector: card0-HDMI-A-1 status=connected' "$bundle_dir/outputs.txt" >/dev/null ||
    die "crash bundle did not capture connected DRM output"
  grep -F 'shell failure marker' "$bundle_dir/logs/shell.log" >/dev/null ||
    die "crash bundle did not copy shell log contents"
  grep -F 'EngineOS shell failed rc=77' "$bundle_dir/logs/runtime-start.log" >/dev/null ||
    die "crash bundle did not copy runtime failure log"
  grep -F 'recovery bundle: eos-crash-bundle' "$bundle_dir/logs/runtime-start.log" >/dev/null ||
    die "crash bundle did not copy runtime recovery hint"
  grep -F 'default via 192.0.2.1 dev eth0 proto dhcp' "$bundle_dir/network-summary.txt" >/dev/null ||
    die "crash bundle network summary did not capture default route"
  grep -F 'eth0 ethernet connected EngineOS test' "$bundle_dir/network/nmcli-device.txt" >/dev/null ||
    die "crash bundle did not capture NetworkManager device state"
  grep -F 'DNS Servers: 192.0.2.53' "$bundle_dir/network/resolvectl-status.txt" >/dev/null ||
    die "crash bundle did not capture resolver state"

  printf 'reliability smoke test passed\n'
}

run_logs() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-logs-test-$$"
  local log_dir="$tmp_dir/logs"
  local out="$tmp_dir/out.txt"

  cleanup_logs() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_logs RETURN

  mkdir -p "$log_dir"
  printf 'shell old line\nshell newest line\n' >"$log_dir/shell.log"
  printf 'engine marker\n' >"$log_dir/engine.log"
  printf 'runtime marker\n' >"$log_dir/runtime-start.log"
  printf 'live setup marker\n' >"$log_dir/live-setup.log"
  printf 'doctor marker\n' >"$log_dir/doctor-firstboot.log"

  ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/eos-logs" shell --last 1 --files >"$out"
  grep -F 'shell newest line' "$out" >/dev/null ||
    die "logs shell did not include newest shell line"
  if grep -F 'shell old line' "$out" >/dev/null; then
    die "logs shell --last 1 included older shell line"
  fi

  ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/eos-logs" runtime --files >"$out"
  grep -F 'runtime marker' "$out" >/dev/null ||
    die "logs runtime did not include runtime-start log"

  ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/eos-logs" all --files >"$out"
  grep -F 'engine marker' "$out" >/dev/null ||
    die "logs all did not include engine log"
  grep -F 'doctor marker' "$out" >/dev/null ||
    die "logs all did not include doctor firstboot log"

  ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/eos-logs" boot --files >"$out"
  grep -F 'No file log target for boot; use --journal.' "$out" >/dev/null ||
    die "logs boot --files did not explain journal usage"

  if ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/eos-logs" nonsense >/dev/null 2>&1; then
    die "logs accepted an unknown target"
  fi

  printf 'logs smoke test passed\n'
}

run_artifacts() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-artifacts-$$"
  local out_dir="$tmp_dir/out"
  local export_dir="$tmp_dir/export"
  local iso="$out_dir/EngineOS-test-x86_64.iso"

  cleanup_artifacts() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_artifacts RETURN

  mkdir -p "$out_dir"
  printf 'fake iso payload\n' >"$iso"

  ENGINEOS_OUT_DIR="$out_dir" "$SCRIPT_DIR/artifacts.sh" checksum >/dev/null
  [[ -f "$iso.sha256" ]] || die "artifact checksum was not created"
  grep -F 'EngineOS-test-x86_64.iso' "$iso.sha256" >/dev/null ||
    die "artifact checksum does not reference ISO"

  ENGINEOS_OUT_DIR="$out_dir" "$SCRIPT_DIR/artifacts.sh" list >/dev/null
  ENGINEOS_OUT_DIR="$out_dir" "$SCRIPT_DIR/artifacts.sh" export "$export_dir" >/dev/null
  [[ -f "$export_dir/EngineOS-test-x86_64.iso" ]] || die "artifact export missing ISO"
  [[ -f "$export_dir/EngineOS-test-x86_64.iso.sha256" ]] || die "artifact export missing checksum"

  printf 'artifacts smoke test passed\n'
}

run_release() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-release-test-$$"
  local out_dir="$tmp_dir/out"
  local export_dir="$tmp_dir/export"
  local report="$tmp_dir/release.md"
  local dev_iso="$out_dir/EngineDevOS-test-x86_64.iso"
  local runtime_iso="$out_dir/EngineRuntimeOS-test-x86_64.iso"

  cleanup_release() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_release RETURN

  mkdir -p "$out_dir"
  printf 'fake dev iso payload\n' >"$dev_iso"
  printf 'fake runtime iso payload\n' >"$runtime_iso"

  "$SCRIPT_DIR/release.sh" checklist --dry-run --out-dir "$out_dir" --report "$report.dry-run" >/dev/null
  grep -F 'Expected EngineDev ISO' "$report.dry-run" >/dev/null ||
    die "release dry-run report missing EngineDev expectation"
  grep -F '`engineos-quakespasm`' "$report.dry-run" >/dev/null ||
    die "release dry-run report missing engineos-quakespasm package expectation"
  grep -F '`engineos-cube`' "$report.dry-run" >/dev/null ||
    die "release dry-run report missing engineos-cube package expectation"

  "$SCRIPT_DIR/release.sh" checklist --out-dir "$out_dir" --export-dir "$export_dir" --report "$report" >/dev/null
  [[ -f "$dev_iso.sha256" ]] || die "release checklist missing EngineDev checksum"
  [[ -f "$runtime_iso.sha256" ]] || die "release checklist missing EngineRuntime checksum"
  [[ -f "$export_dir/EngineDevOS-test-x86_64.iso" ]] || die "release export missing EngineDev ISO"
  [[ -f "$export_dir/EngineRuntimeOS-test-x86_64.iso" ]] || die "release export missing EngineRuntime ISO"
  grep -F 'Bare-metal AMD' "$report" >/dev/null ||
    die "release report missing bare-metal proof section"
  grep -F '/usr/bin/quakespasm' "$report" >/dev/null ||
    die "release report missing QuakeSpasm binary proof item"
  grep -F 'eos-outputs validate --single' "$report" >/dev/null ||
    die "release report missing output validation proof item"
  grep -F 'eos-proof launchpad --runtime' "$report" >/dev/null ||
    die "release report missing launchpad proof item"
  grep -F 'eos-app manifest validate' "$report" >/dev/null ||
    die "release report missing app manifest proof item"
  grep -F 'eos-terminal' "$report" >/dev/null ||
    die "release report missing terminal proof item"
  grep -F 'eos-crash-bundle --bare-metal' "$report" >/dev/null ||
    die "release report missing bare-metal crash bundle proof item"
  grep -F 'proof hardware-ready' "$report" >/dev/null ||
    die "release report missing hardware-ready proof item"

  printf 'release checklist smoke test passed\n'
}

run_terminal() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-terminal-test-$$"
  local fake_bin="$tmp_dir/bin"
  local log_dir="$tmp_dir/logs"
  local launched="$tmp_dir/launched.txt"
  local tmux_log="$tmp_dir/tmux.log"
  local out="$tmp_dir/out.txt"

  cleanup_terminal() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_terminal RETURN

  mkdir -p "$fake_bin" "$log_dir"
  cat >"$fake_bin/alacritty" <<'FAKE'
#!/usr/bin/env bash
printf 'alacritty %s\n' "$*" >"$ENGINEOS_FAKE_TERMINAL_LAUNCHED"
FAKE
  cat >"$fake_bin/foot" <<'FAKE'
#!/usr/bin/env bash
printf 'foot %s\n' "$*" >"$ENGINEOS_FAKE_TERMINAL_LAUNCHED"
FAKE
  cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >>"$ENGINEOS_FAKE_TMUX_LOG"
case "$1" in
  has-session)
    exit 1
    ;;
  list-sessions)
    printf 'engineos-side\t1\t200\n'
    printf '2\t1\t100\n'
    ;;
  attach-session|new-session)
    exit 0
    ;;
esac
exit 1
FAKE
  chmod +x "$fake_bin/alacritty"
  chmod +x "$fake_bin/foot"
  chmod +x "$fake_bin/tmux"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_FAKE_TMUX_LOG="$tmux_log" \
    "$ROOT/tools/post-install-payload/scripts/engineos-tmux-attach-primary"
  grep -F 'tmux attach-session -t =2' "$tmux_log" >/dev/null ||
    die "tmux primary attach helper did not skip engineos-side"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_TERMINAL_CANDIDATES="missing-terminal alacritty" \
    "$SCRIPT_DIR/terminal_launcher.sh" --print-command >"$out"
  grep -Fx 'alacritty' "$out" >/dev/null ||
    die "terminal launcher did not select fallback terminal"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_FAKE_TERMINAL_LAUNCHED="$launched" \
    ENGINEOS_TERMINAL_CANDIDATES="missing-terminal alacritty" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/terminal_launcher.sh" -- --class EngineOS >/dev/null
  grep -F 'alacritty --class EngineOS' "$launched" >/dev/null ||
    die "terminal launcher did not exec selected terminal with args"
  grep -F 'launch command=alacritty display=engineos-test-wayland' "$log_dir/terminal.log" >/dev/null ||
    die "terminal launcher did not log selected terminal launch"
  grep -F 'owner=engineos-shell' "$log_dir/terminal.log" >/dev/null ||
    die "terminal launcher did not log EngineOS shell ownership"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_FAKE_TERMINAL_LAUNCHED="$launched" \
    ENGINEOS_TERMINAL_CANDIDATES="foot" \
		ENGINEOS_TERMINAL_APP_ID="engineos-terminal" \
		ENGINEOS_TERMINAL_ROLE="terminal" \
    ENGINEOS_TERMINAL_TITLE="EngineOS Terminal" \
    ENGINEOS_TERMINAL_SESSION_CMD="engineos-tmux-attach-primary" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/terminal_launcher.sh" >/dev/null
	grep -F 'foot --override csd.preferred=none --override csd.size=0 --app-id engineos-terminal --title EngineOS Terminal -- zsh -lc unset TMUX TMUX_PANE; eos-app terminal register --slot terminal; exec engineos-tmux-attach-primary' "$launched" >/dev/null ||
    die "terminal launcher did not disable foot titlebar decorations"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_FAKE_TERMINAL_LAUNCHED="$launched" \
    ENGINEOS_TERMINAL_CANDIDATES="alacritty" \
		ENGINEOS_TERMINAL_APP_ID="engineos-terminal-secondary" \
		ENGINEOS_TERMINAL_ROLE="terminal-secondary" \
    ENGINEOS_TERMINAL_TITLE="EngineOS Side" \
    ENGINEOS_TERMINAL_SESSION_CMD="tmux new -A -s engineos-side" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/terminal_launcher.sh" >/dev/null
	grep -F 'alacritty --class engineos-terminal-secondary --title EngineOS Side -- zsh -lc unset TMUX TMUX_PANE; eos-app terminal register --slot terminal-secondary; exec tmux new -A -s engineos-side' "$launched" >/dev/null ||
    die "terminal launcher did not start named tmux session through zsh"
  grep -F 'session command=tmux new -A -s engineos-side' "$log_dir/terminal.log" >/dev/null ||
    die "terminal launcher did not log tmux session command"

  if env -u WAYLAND_DISPLAY -u DISPLAY \
      PATH="$fake_bin:$PATH" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_TERMINAL_CANDIDATES="alacritty" \
      "$SCRIPT_DIR/terminal_launcher.sh" >/dev/null 2>&1; then
    die "terminal launcher should require WAYLAND_DISPLAY by default"
  fi
  grep -F 'reason=missing-wayland-display' "$log_dir/terminal.log" >/dev/null ||
    die "terminal launcher did not log missing Wayland display"

  ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_TERMINAL_CANDIDATES="missing-terminal" \
    "$SCRIPT_DIR/terminal_launcher.sh" --dry-run >"$out"
  grep -F 'command: missing' "$out" >/dev/null ||
    die "terminal dry-run did not report missing candidates"

  if ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_TERMINAL_CANDIDATES="missing-terminal" \
      "$SCRIPT_DIR/terminal_launcher.sh" >/dev/null 2>&1; then
    die "terminal launcher should fail when no terminal candidate exists"
  fi
  grep -F 'reason=no-terminal-candidate' "$log_dir/terminal.log" >/dev/null ||
    die "terminal launcher did not log missing terminal failure"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_TERMINAL_CANDIDATES="alacritty" \
    "$ROOT/tools/engineos/eos-terminal" --dry-run >"$out"
  grep -F 'command: alacritty' "$out" >/dev/null ||
    die "eos-terminal did not route to terminal launcher"

  cat >"$fake_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >>"$ENGINEOS_FAKE_TMUX_LOG"
case "$1" in
  list-sessions)
    printf 'engineos: 2 windows\n'
    ;;
esac
FAKE
  chmod +x "$fake_bin/tmux"
  mkdir -p "$tmp_dir/tmux-resurrect/scripts"
  cat >"$tmp_dir/tmux-resurrect/scripts/save.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'resurrect-save\n' >>"$ENGINEOS_FAKE_TMUX_LOG"
FAKE
  chmod +x "$tmp_dir/tmux-resurrect/scripts/save.sh"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_FAKE_TMUX_LOG="$tmp_dir/tmux.log" \
    ENGINEOS_TMUX_RESURRECT_SAVE_SCRIPT="$tmp_dir/tmux-resurrect/scripts/save.sh" \
    "$ROOT/tools/engineos/eos-terminal" save-layout --dry-run >"$out"
  grep -F 'tmux sessions: 1' "$out" >/dev/null ||
    die "eos-terminal save-layout dry-run did not count tmux sessions"
  grep -F "$tmp_dir/tmux-resurrect/scripts/save.sh" "$out" >/dev/null ||
    die "eos-terminal save-layout dry-run did not report save script"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_FAKE_TMUX_LOG="$tmp_dir/tmux.log" \
    ENGINEOS_TMUX_RESURRECT_SAVE_SCRIPT="$tmp_dir/tmux-resurrect/scripts/save.sh" \
    "$ROOT/tools/engineos/eos-terminal" save-layout >"$out"
  grep -F 'tmux set-option -gq @continuum-restore on' "$tmp_dir/tmux.log" >/dev/null ||
    die "eos-terminal save-layout did not enable tmux continuum restore"
  grep -F 'tmux set-option -gq @resurrect-capture-pane-contents off' "$tmp_dir/tmux.log" >/dev/null ||
    die "eos-terminal save-layout did not disable pane content capture"
  grep -F "tmux set-option -gq @resurrect-processes :all:" "$tmp_dir/tmux.log" >/dev/null ||
    die "eos-terminal save-layout did not enable process restore"
  grep -F 'resurrect-save' "$tmp_dir/tmux.log" >/dev/null ||
    die "eos-terminal save-layout did not run tmux-resurrect save"
  grep -F 'saved tmux layout sessions=1' "$log_dir/terminal.log" >/dev/null ||
    die "eos-terminal save-layout did not log the saved layout"

  printf 'terminal launcher smoke test passed\n'
}

run_vm() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-vm-test-$$"
  local dev_iso="$tmp_dir/out/EngineDevOS-test-x86_64.iso"
  local runtime_iso="$tmp_dir/out/EngineRuntimeOS-test-x86_64.iso"
  local out="$tmp_dir/vm.txt"

  cleanup_vm() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_vm RETURN

  mkdir -p "$tmp_dir/out"
  printf 'fake dev iso payload\n' >"$dev_iso"
  printf 'fake runtime iso payload\n' >"$runtime_iso"

  "$VM_DIR/vm.sh" boot enginedev --dry-run --out-dir "$tmp_dir/out" --memory 1024 --cpus 1 --display none --no-kvm >"$out"
  grep -F 'eos-proof booted-iso --vm' "$out" >/dev/null ||
    die "enginedev VM dry-run did not print VM proof command"
  grep -F 'display:  none' "$out" >/dev/null ||
    die "enginedev VM dry-run did not print selected display backend"
  if grep -F 'OVMF_CODE' "$out" >/dev/null; then
    die "enginedev VM dry-run used pflash OVMF_CODE as a -bios image"
  fi
  env -u WAYLAND_DISPLAY -u DISPLAY "$VM_DIR/vm.sh" boot enginedev --dry-run --iso "$dev_iso" --memory 1024 --cpus 1 --no-kvm >"$out"
  grep -F 'display:  none' "$out" >/dev/null ||
    die "enginedev VM dry-run did not default to headless display without a graphical session"
  "$VM_DIR/vm.sh" boot enginedev --dry-run --iso "$dev_iso" --memory 1024 --cpus 1 --display none --background --no-kvm >"$out"
  grep -F -- '-daemonize' "$out" >/dev/null ||
    die "enginedev VM background dry-run did not daemonize QEMU"
  grep -F 'qemu-enginedev-serial.log' "$out" >/dev/null ||
    die "enginedev VM background dry-run did not print serial log path"
  "$VM_DIR/vm.sh" boot enginedev --dry-run --iso "$dev_iso" --memory 1024 --cpus 1 --display none --no-kvm >"$out"
  grep -F 'profile:  enginedev' "$out" >/dev/null ||
    die "enginedev VM dry-run did not print selected profile"

  "$VM_DIR/vm.sh" boot engineruntime --dry-run --out-dir "$tmp_dir/out" --memory 1024 --cpus 1 --display none --no-kvm >"$out"
  grep -F 'eos-proof booted-iso --runtime' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not print runtime proof command"
  "$VM_DIR/vm.sh" boot engineruntime --dry-run --iso "$runtime_iso" --memory 1024 --cpus 1 --display none --no-kvm >"$out"
  grep -F 'profile:  engineruntime' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not print selected profile"
  "$VM_DIR/vm.sh" boot engineruntime --dry-run --iso "$runtime_iso" --memory 1024 --cpus 1 --display none --audio hda --no-kvm >"$out"
  grep -F 'audio:    hda' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not print selected audio mode"
  grep -F -- '-device ich9-intel-hda' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not include HDA controller"
  grep -F -- '-device hda-duplex\,audiodev=audio0' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not include HDA duplex codec"
  env -u WAYLAND_DISPLAY -u DISPLAY "$VM_DIR/vm.sh" boot engineruntime --dry-run --iso "$runtime_iso" --memory 1024 --cpus 1 --gl --no-kvm >"$out"
  grep -F 'display:  egl-headless,gl=on' "$out" >/dev/null ||
    die "engineruntime GL VM dry-run did not select egl-headless GL display"
  grep -F 'gl:       true' "$out" >/dev/null ||
    die "engineruntime GL VM dry-run did not print GL mode"
  grep -F -- '-vga none' "$out" >/dev/null ||
    die "engineruntime GL VM dry-run did not disable default VGA"
  grep -F -- '-device virtio-vga-gl' "$out" >/dev/null ||
    die "engineruntime GL VM dry-run did not include virtio-vga-gl"
  if "$VM_DIR/vm.sh" boot engineruntime --dry-run --iso "$runtime_iso" --memory 1024 --cpus 1 --display none --gl --no-kvm >"$out" 2>&1; then
    die "engineruntime GL VM dry-run accepted display none"
  fi
  grep -F -- '--gl requires a GL-capable display backend' "$out" >/dev/null ||
    die "engineruntime GL VM dry-run did not explain display none rejection"

  printf 'vm boot dry-run test passed\n'
}

run_usb() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-usb-test-$$"
  local iso="$tmp_dir/out/EngineRuntimeOS-test-x86_64.iso"

  cleanup_usb() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_usb RETURN

  mkdir -p "$tmp_dir/out"
  printf 'fake iso payload\n' >"$iso"

  "$BARE_METAL_DIR/usb.sh" list >/dev/null
  "$BARE_METAL_DIR/usb.sh" write --dry-run --iso "$iso" --device /dev/engineos-test-usb >/dev/null
  "$BARE_METAL_DIR/usb.sh" write --dry-run --profile engineruntime --out-dir "$tmp_dir/out" --device /dev/engineos-test-usb >/dev/null

  if "$BARE_METAL_DIR/usb.sh" write --iso "$iso" --device /dev/engineos-test-usb >/dev/null 2>&1; then
    die "usb write should require explicit destructive acknowledgement outside dry-run"
  fi

  printf 'usb write dry-run test passed\n'
}

run_secure_boot() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-secure-boot-test-$$"
  local key_dir="$tmp_dir/keys"
  local iso="$tmp_dir/out/EngineRuntimeOS-test-x86_64.iso"
  local out="$tmp_dir/out.txt"

  cleanup_secure_boot() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_secure_boot RETURN

  mkdir -p "$(dirname "$iso")"
  printf 'fake iso payload\n' >"$iso"

  "$BARE_METAL_DIR/secure_boot.sh" keys create --out-dir "$key_dir" --dry-run >"$out"
  grep -F 'EngineOS Secure Boot key creation' "$out" >/dev/null ||
    die "secure-boot key dry-run missing header"
  grep -F 'openssl req' "$out" >/dev/null ||
    die "secure-boot key dry-run missing openssl command"

  mkdir -p "$key_dir"
  printf 'fake key\n' >"$key_dir/db.key"
  printf 'fake cert\n' >"$key_dir/db.crt"
  printf 'fake der cert\n' >"$key_dir/db.cer"

  "$BARE_METAL_DIR/secure_boot.sh" keys status --key-dir "$key_dir" >"$out"
  grep -F 'status: ready' "$out" >/dev/null ||
    die "secure-boot key status did not report ready"

  "$BARE_METAL_DIR/secure_boot.sh" sign-iso --iso "$iso" --key-dir "$key_dir" --dry-run >"$out"
  grep -F '/EFI/BOOT/BOOTx64.EFI' "$out" >/dev/null ||
    die "secure-boot sign dry-run did not mention bootloader signing"
  grep -F '/arch/boot/x86_64/vmlinuz-linux' "$out" >/dev/null ||
    die "secure-boot sign dry-run did not mention kernel signing"

  "$BARE_METAL_DIR/secure_boot.sh" enroll-handoff --key-dir "$key_dir" >"$out"
  grep -F 'Do not clear existing Microsoft keys' "$out" >/dev/null ||
    die "secure-boot enrollment handoff does not protect Windows keys"

  printf 'secure-boot dry-run test passed\n'
}

run_installation_guide() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-installation-guide-test-$$"
  local out="$tmp_dir/guide.txt"

  cleanup_installation_guide() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_installation_guide RETURN

  mkdir -p "$tmp_dir"
  "$SCRIPT_DIR/installation_guide.sh" >"$out"
  grep -F 'EngineDev installation guide' "$out" >/dev/null ||
    die "installation guide missing header"
  grep -F 'codex --version' "$out" >/dev/null ||
    die "installation guide does not tell the live user to validate Codex"
  grep -F -- '--repo-token-file /run/engineos-secrets/tango-os-readonly.token' "$out" >/dev/null ||
    die "installation guide missing private repo token path"
  grep -F 'prompts are disabled' "$out" >/dev/null ||
    die "installation guide does not explain the git prompt failure"
  grep -F 'sudo genfstab -U /mnt/engineos' "$out" >/dev/null ||
    die "installation guide missing fstab recovery command"

  "$ROOT/tools/engineos/eos-install" guide >"$out"
  grep -F 'EngineDev installation guide' "$out" >/dev/null ||
    die "eos-install guide did not dispatch to guide script"

  grep -F '/usr/local/bin/engineos-live-codex-setup' "$ROOT/archiso/enginedev/profiledef.sh" >/dev/null ||
    die "EngineDev profile does not mark live Codex setup executable"
  grep -F 'systemctl enable engineos-live-codex-setup.service' "$ROOT/archiso/enginedev/airootfs/root/customize_airootfs.sh" >/dev/null ||
    die "EngineDev profile does not enable live Codex setup"
  grep -F 'console=ttyS0' "$ROOT/archiso/enginedev/efiboot/loader/entries/01-enginedev-linux.conf" >/dev/null &&
    die "EngineDev boot entry still redirects bare-metal boot to serial"

  printf 'installation guide smoke test passed\n'
}

run_install() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-install-test-$$"
  local fake_bin="$tmp_dir/bin"
  local seed="$tmp_dir/seed"
  local package_cache="$tmp_dir/pkg-cache"
  local pacman_conf="$tmp_dir/pacman.conf"
  local target="$tmp_dir/target"
  local token_file="$tmp_dir/repo-token"
  local out="$tmp_dir/install.txt"
  local log="$tmp_dir/commands.log"

  cleanup_install() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_install RETURN

  mkdir -p "$fake_bin" "$seed/.git" "$seed/tools" "$package_cache"
  printf 'seed\n' >"$seed/README.md"
  while IFS= read -r package; do
    printf 'fake package\n' >"$package_cache/$package-1-1-any.pkg.tar.zst"
  done < <(engineos_install_packages)
  cat >"$pacman_conf" <<'EOF_PACMAN'
[options]
Architecture = auto
SigLevel = Required DatabaseOptional

[core]
Include = /etc/pacman.d/mirrorlist
EOF_PACMAN
  "$BARE_METAL_DIR/install_dev.sh" dev \
    --dry-run \
    --target "$target" \
    --no-home-ntfs >"$tmp_dir/install-default.txt"
  grep -F 'device:   /dev/disk/by-id/ata-WDC_WD10EZEX-00WN4A0_WD-WCC6Y1ZP5EAX' "$tmp_dir/install-default.txt" >/dev/null ||
    die "install dry-run did not default to the configured F: disk by-id path"
  grep -F 'home:     installed root filesystem' "$tmp_dir/install-default.txt" >/dev/null ||
    die "install dry-run did not honor --no-home-ntfs"

  "$BARE_METAL_DIR/install_dev.sh" dev \
    --dry-run \
    --device /dev/engineos-test-disk \
    --target "$target" \
    --repo-url https://example.invalid/tang-os.git \
    --branch main >"$out"

  grep -F 'EngineOS EngineDev autoinstall plan' "$out" >/dev/null ||
    die "install dry-run missing plan header"
  grep -F 'device:   /dev/engineos-test-disk' "$out" >/dev/null ||
    die "install dry-run missing target device"
  grep -F 'home:     LABEL=Tango mounted at /home as NTFS' "$out" >/dev/null ||
    die "install dry-run missing default NTFS home mount"
  grep -F 'EngineDev /var, 128G, ext4 label ENGINEOS_VAR' "$out" >/dev/null ||
    die "install dry-run missing /var partition plan"
  grep -F 'persistent /srv workspace' "$out" >/dev/null ||
    die "install dry-run missing persistent /srv plan"
  grep -F 'cache:    /opt/engineos/install-cache/pkg' "$out" >/dev/null ||
    die "install dry-run missing ISO package cache plan"
  grep -F 'repo auth: none; clone runs non-interactively' "$out" >/dev/null ||
    die "install dry-run missing repo auth plan"
  grep -F 'env GIT_TERMINAL_PROMPT=0 git clone https://example.invalid/tang-os.git /srv/engineos' "$out" >/dev/null ||
    die "install dry-run missing official repo clone"
  grep -F 'setup_dev_environment.sh --payload /usr/share/engineos/post-install-payload --user dev' "$out" >/dev/null ||
    die "install dry-run missing post-install payload handoff"
  grep -F 'chown -R dev:dev /srv/engineos' "$out" >/dev/null ||
    die "install dry-run did not assign source workspace to dev"
  grep -F 'runuser -u dev -- env -u ENGINEOS_ROOT -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_LOG_DIR /srv/engineos/tools/engineos/eos-build repo' "$out" >/dev/null ||
    die "install dry-run did not build source repo as dev with cleared EngineOS wrapper env"
  grep -F 'proof booted-iso --bare-metal' "$out" >/dev/null ||
    die "install dry-run missing bare-metal handoff proof"

  printf 'fake-token\n' >"$token_file"
  "$BARE_METAL_DIR/install_dev.sh" dev \
    --dry-run \
    --device /dev/engineos-test-disk \
    --target "$target" \
    --repo-url https://example.invalid/tang-os.git \
    --repo-token-file "$token_file" \
    --branch main >"$out"
  grep -F 'repo auth: token file supplied (redacted)' "$out" >/dev/null ||
    die "install dry-run did not redact repo token file"
  grep -F 'GIT_ASKPASS=/usr/local/bin/engineos-git-askpass GIT_TERMINAL_PROMPT=0 git clone https://example.invalid/tang-os.git /srv/engineos' "$out" >/dev/null ||
    die "install dry-run missing private repo askpass clone"
  if grep -F 'fake-token' "$out" >/dev/null || grep -F "$token_file" "$out" >/dev/null; then
    die "install dry-run leaked repo token file details"
  fi

  cat >"$fake_bin/sudo" <<'FAKE'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
exec "$@"
FAKE
  cat >"$fake_bin/lsblk" <<'FAKE'
#!/usr/bin/env bash
printf 'lsblk %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
exit 0
FAKE
  cat >"$fake_bin/findmnt" <<'FAKE'
#!/usr/bin/env bash
printf 'findmnt %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
exit 1
FAKE
  cat >"$fake_bin/wipefs" <<'FAKE'
#!/usr/bin/env bash
printf 'wipefs %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
FAKE
  cat >"$fake_bin/sfdisk" <<'FAKE'
#!/usr/bin/env bash
printf 'sfdisk %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
cat >/dev/null
FAKE
  cat >"$fake_bin/udevadm" <<'FAKE'
#!/usr/bin/env bash
printf 'udevadm %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
FAKE
  cat >"$fake_bin/mkfs.fat" <<'FAKE'
#!/usr/bin/env bash
printf 'mkfs.fat %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
FAKE
  cat >"$fake_bin/mkfs.ext4" <<'FAKE'
#!/usr/bin/env bash
printf 'mkfs.ext4 %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
FAKE
  cat >"$fake_bin/mount" <<'FAKE'
#!/usr/bin/env bash
printf 'mount %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
mkdir -p "${@: -1}"
FAKE
  cat >"$fake_bin/findfs" <<'FAKE'
#!/usr/bin/env bash
printf 'findfs %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
printf '/dev/fake-home\n'
FAKE
  cat >"$fake_bin/pacstrap" <<'FAKE'
#!/usr/bin/env bash
printf 'pacstrap %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
target=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      target="$1"
      break
      ;;
  esac
done
[[ -n "$target" ]] || exit 2
mkdir -p "$target/etc/pacman.d" "$target/etc/sudoers.d" "$target/boot" "$target/var" "$target/srv" "$target/home" "$target/usr/share/engineos/post-install-payload/scripts"
touch "$target/usr/share/engineos/post-install-payload/scripts/setup_dev_environment.sh"
chmod +x "$target/usr/share/engineos/post-install-payload/scripts/setup_dev_environment.sh"
printf '[options]\n' >"$target/etc/pacman.conf"
printf '#en_US.UTF-8 UTF-8\n' >"$target/etc/locale.gen"
FAKE
  cat >"$fake_bin/genfstab" <<'FAKE'
#!/usr/bin/env bash
printf 'genfstab %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
printf 'UUID=fake-root / ext4 rw 0 1\n'
FAKE
  cat >"$fake_bin/arch-chroot" <<'FAKE'
#!/usr/bin/env bash
printf 'arch-chroot %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
cat >/dev/null || true
FAKE
  cat >"$fake_bin/blkid" <<'FAKE'
#!/usr/bin/env bash
printf 'blkid %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
printf '00000000-0000-4000-8000-000000000000\n'
FAKE
  cat >"$fake_bin/git" <<'FAKE'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$ENGINEOS_FAKE_INSTALL_LOG"
FAKE
  chmod +x "$fake_bin"/*

  PATH="$fake_bin:$PATH" \
    ENGINEOS_INSTALL_ALLOW_FAKE_DEVICE=true \
    ENGINEOS_INSTALL_PACMAN_CONF="$pacman_conf" \
    ENGINEOS_FAKE_INSTALL_LOG="$log" \
    "$BARE_METAL_DIR/install_dev.sh" dev \
      --device /dev/engineos-test-disk \
      --target "$target" \
      --repo-url https://example.invalid/tang-os.git \
      --repo-seed "$seed" \
      --package-cache "$package_cache" \
      --branch main \
      --skip-codex \
      --yes-i-understand-this-wipes-device >"$tmp_dir/install-real.txt"

  grep -F 'EngineDev autoinstall completed' "$tmp_dir/install-real.txt" >/dev/null ||
    die "install executor did not complete with fake commands"
  grep -F 'wipefs --all /dev/engineos-test-disk' "$log" >/dev/null ||
    die "install executor did not wipe target"
  grep -F 'sfdisk /dev/engineos-test-disk' "$log" >/dev/null ||
    die "install executor did not partition target"
  grep -F 'mkfs.ext4 -F -L ENGINEOS_VAR /dev/engineos-test-disk3' "$log" >/dev/null ||
    die "install executor did not format /var partition"
  grep -F 'mount /dev/engineos-test-disk3 '"$target"'/var' "$log" >/dev/null ||
    die "install executor did not mount /var partition"
  grep -F 'mount -t ntfs-3g -o uid=1000,gid=1000,umask=022,fmask=133,dmask=022,windows_names,nofail,x-systemd.device-timeout=10s LABEL=Tango '"$target"'/home' "$log" >/dev/null ||
    die "install executor did not mount default NTFS home volume"
  grep -F 'arch-chroot '"$target"' useradd -M -d /home/dev -G wheel,input,audio,video,render,docker -s /usr/bin/zsh dev' "$log" >/dev/null ||
    die "install executor did not create NTFS-home user without useradd -m"
  grep -F 'pacstrap -c -C ' "$log" >/dev/null ||
    die "install executor did not run pacstrap with cached host package mode"
  grep -F "CacheDir = $package_cache" /tmp/engineos-install-pacman-*.conf >/dev/null ||
    die "install executor did not generate cached pacman config"
  grep -F 'cp -a '"$seed"'/. '"$target"'/tmp/tang-os-seed/' "$log" >/dev/null ||
    die "install executor did not stage seed repo"
  grep -F 'arch-chroot '"$target"' env GIT_TERMINAL_PROMPT=0 git clone file:///tmp/tang-os-seed /srv/engineos' "$log" >/dev/null ||
    die "install executor did not clone seed repo in target"
  grep -F 'arch-chroot '"$target"' chown -R dev:dev /srv/engineos' "$log" >/dev/null ||
    die "install executor did not assign source workspace to dev"
  grep -F 'arch-chroot '"$target"' runuser -u dev -- env -u ENGINEOS_ROOT -u ENGINEOS_SCRIPT_DIR -u ENGINEOS_LOG_DIR /srv/engineos/tools/engineos/eos-build repo' "$log" >/dev/null ||
    die "install executor did not build source repo as dev with cleared EngineOS wrapper env"
  grep -F 'arch-chroot '"$target"' /usr/share/engineos/post-install-payload/scripts/setup_dev_environment.sh' "$log" >/dev/null ||
    die "install executor did not run post-install payload"
  grep -F 'Server = file:///srv/engineos/repo/$arch' "$target/etc/pacman.conf" >/dev/null ||
    die "install executor did not configure installed local pacman repo"
  [[ -f "$target/srv/ENGINEOS_INSTALL_HANDOFF.txt" ]] ||
    die "install executor did not write handoff marker"

  rm -rf "$target" "$log"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_INSTALL_ALLOW_FAKE_DEVICE=true \
    ENGINEOS_INSTALL_PACMAN_CONF="$pacman_conf" \
    ENGINEOS_FAKE_INSTALL_LOG="$log" \
    "$BARE_METAL_DIR/install_dev.sh" dev \
      --device /dev/engineos-test-disk \
      --target "$target" \
      --repo-url https://example.invalid/tang-os.git \
      --repo-token-file "$token_file" \
      --package-cache "$package_cache" \
      --branch main \
      --skip-codex \
      --yes-i-understand-this-wipes-device >"$tmp_dir/install-private-repo.txt"

  grep -F 'repo auth: token file supplied (redacted)' "$tmp_dir/install-private-repo.txt" >/dev/null ||
    die "install executor did not report redacted repo token auth"
  grep -F 'arch-chroot '"$target"' env GIT_ASKPASS=/usr/local/bin/engineos-git-askpass GIT_TERMINAL_PROMPT=0 git clone https://example.invalid/tang-os.git /srv/engineos' "$log" >/dev/null ||
    die "install executor did not clone private repo with askpass"
  if grep -F 'fake-token' "$tmp_dir/install-private-repo.txt" >/dev/null || grep -F 'fake-token' "$log" >/dev/null; then
    die "install executor leaked repo token"
  fi
  [[ ! -e "$target/root/.engineos/repo-token" ]] ||
    die "install executor left repo token in target"
  [[ ! -e "$target/usr/local/bin/engineos-git-askpass" ]] ||
    die "install executor left git askpass helper in target"

  rm -rf "$target" "$log" "$package_cache"
  mkdir -p "$package_cache"
  printf 'fake package\n' >"$package_cache/base-1-1-any.pkg.tar.zst"
  if PATH="$fake_bin:$PATH" \
    ENGINEOS_INSTALL_ALLOW_FAKE_DEVICE=true \
    ENGINEOS_INSTALL_PACMAN_CONF="$pacman_conf" \
    ENGINEOS_FAKE_INSTALL_LOG="$log" \
    "$BARE_METAL_DIR/install_dev.sh" dev \
      --device /dev/engineos-test-disk \
      --target "$target" \
      --repo-url https://example.invalid/tang-os.git \
      --repo-seed "$seed" \
      --package-cache "$package_cache" \
      --branch main \
      --skip-codex \
      --yes-i-understand-this-wipes-device >"$tmp_dir/install-partial-cache.txt" 2>"$tmp_dir/install-partial-cache.err"; then
    die "install executor should reject an incomplete package cache"
  fi
  grep -F 'EngineDev install package cache is incomplete' "$tmp_dir/install-partial-cache.err" >/dev/null ||
    die "install executor did not explain incomplete package cache"

  if "$BARE_METAL_DIR/install_dev.sh" dev --device /dev/engineos-test-disk >/dev/null 2>&1; then
    die "install real mode should require explicit wipe acknowledgement"
  fi

  printf 'EngineDev installer dry-run test passed\n'
}

run_restore_point() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-restore-point-test-$$"
  local boot_dir="$tmp_dir/boot"
  local fake_bin="$tmp_dir/bin"
  local out="$tmp_dir/restore.txt"
  local log="$tmp_dir/commands.log"

  cleanup_restore_point() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_restore_point RETURN

  mkdir -p "$boot_dir/loader/entries" "$fake_bin"
  printf 'kernel\n' >"$boot_dir/vmlinuz-linux"
  printf 'initramfs\n' >"$boot_dir/initramfs-linux.img"
  cat >"$boot_dir/loader/loader.conf" <<'EOF_LOADER'
default enginedev.conf
timeout 8
console-mode max
editor no
EOF_LOADER
  cat >"$boot_dir/loader/entries/enginedev.conf" <<'EOF_ENTRY'
title EngineDev OS
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=UUID=00000000-0000-4000-8000-000000000000 rw
EOF_ENTRY
  cat >"$fake_bin/sudo" <<'FAKE'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$ENGINEOS_FAKE_RESTORE_LOG"
exec "$@"
FAKE
  chmod +x "$fake_bin/sudo"

  ENGINEOS_BOOT_DIR="$boot_dir" \
    "$BARE_METAL_DIR/create_restore_point.sh" --label "Before Shell Update" --dry-run >"$out"
  grep -F 'DRY-RUN sudo install -m 0644' "$out" >/dev/null ||
    die "restore-point dry-run did not show kernel copy"
  grep -F 'title EngineDev OS restore before-shell-update' "$out" >/dev/null ||
    die "restore-point dry-run did not sanitize label in title"
  grep -F 'options root=UUID=00000000-0000-4000-8000-000000000000 rw' "$out" >/dev/null ||
    die "restore-point dry-run did not preserve root options"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_BOOT_DIR="$boot_dir" \
    ENGINEOS_FAKE_RESTORE_LOG="$log" \
    "$BARE_METAL_DIR/create_restore_point.sh" --label "Before Shell Update" --default >"$out"

  [[ -f "$boot_dir/vmlinuz-linux-restore-before-shell-update" ]] ||
    die "restore-point did not copy kernel"
  [[ -f "$boot_dir/initramfs-linux-restore-before-shell-update.img" ]] ||
    die "restore-point did not copy initramfs"
  grep -F 'linux /vmlinuz-linux-restore-before-shell-update' "$boot_dir/loader/entries/enginedev-restore-before-shell-update.conf" >/dev/null ||
    die "restore-point entry does not point at restore kernel"
  grep -F 'initrd /initramfs-linux-restore-before-shell-update.img' "$boot_dir/loader/entries/enginedev-restore-before-shell-update.conf" >/dev/null ||
    die "restore-point entry does not point at restore initramfs"
  grep -F 'default enginedev-restore-before-shell-update.conf' "$boot_dir/loader/loader.conf" >/dev/null ||
    die "restore-point --default did not update loader default"

  if PATH="$fake_bin:$PATH" \
    ENGINEOS_BOOT_DIR="$boot_dir" \
    ENGINEOS_FAKE_RESTORE_LOG="$log" \
    "$BARE_METAL_DIR/create_restore_point.sh" --label "Before Shell Update" >"$tmp_dir/duplicate.txt" 2>"$tmp_dir/duplicate.err"; then
    die "restore-point should reject duplicate labels"
  fi
  grep -F 'restore point already exists for label: before-shell-update' "$tmp_dir/duplicate.err" >/dev/null ||
    die "restore-point duplicate error was not clear"

  "$ROOT/tools/engineos/eos-install" restore-point --help >"$out"
  grep -F 'Create a systemd-boot restore entry' "$out" >/dev/null ||
    die "eos-install restore-point did not dispatch to restore helper"

  printf 'EngineDev restore-point test passed\n'
}

run_proof() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-proof-test-$$"
  local shell_pid_before shell_pid_after

  cleanup_proof() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_proof RETURN

  mkdir -p "$tmp_dir/logs"
  "$PROOF_DIR/proof.sh" --help >"$tmp_dir/help.txt"
  grep -F 'proof.sh native-kms' "$tmp_dir/help.txt" >/dev/null ||
    die "proof help does not expose native KMS acceptance"
  shell_pid_before="$(pgrep -n -x engineos-shell 2>/dev/null || true)"
  if "$PROOF_DIR/proof.sh" native-kms --dry-run \
      >"$tmp_dir/native-kms-invalid.txt" 2>&1; then
    die "native KMS proof accepted a dry-run substitute"
  fi
  grep -F 'native-kms proof takes no options' \
    "$tmp_dir/native-kms-invalid.txt" >/dev/null ||
    die "native KMS proof did not reject non-acceptance options explicitly"
  shell_pid_after="$(pgrep -n -x engineos-shell 2>/dev/null || true)"
  [[ "$shell_pid_after" == "$shell_pid_before" ]] ||
    die "rejected native KMS proof mutated the live shell"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" release-candidate --dry-run --out-dir "$tmp_dir/out" >"$tmp_dir/release-candidate.txt"
  grep -F 'build EngineRuntime ISO dry-run' "$tmp_dir/release-candidate.txt" >/dev/null ||
    die "release-candidate proof did not include EngineRuntime ISO dry-run"
  grep -F 'release checklist' "$tmp_dir/release-candidate.txt" >/dev/null ||
    die "release-candidate proof did not run release checklist"
  grep -F 'Release-candidate proof preview completed; no release-candidate proof was executed.' "$tmp_dir/release-candidate.txt" >/dev/null ||
    die "release-candidate dry-run did not clearly identify itself as a preview"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" hardware-ready --dry-run --profile engineruntime --out-dir "$tmp_dir/out" --device /dev/engineos-test-usb >"$tmp_dir/hardware-ready.txt"
  grep -F 'eos-usb write --profile engineruntime' "$tmp_dir/hardware-ready.txt" >/dev/null ||
    die "hardware-ready proof did not include runtime USB write dry-run"
  grep -F 'eos-proof booted-iso --bare-metal' "$tmp_dir/hardware-ready.txt" >/dev/null ||
    die "hardware-ready proof did not point to bare-metal proof"
  grep -F 'Hardware-ready proof preview completed; no hardware-ready proof was executed.' "$tmp_dir/hardware-ready.txt" >/dev/null ||
    die "hardware-ready dry-run did not clearly identify itself as a preview"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" booted-iso --vm --dry-run >"$tmp_dir/booted-vm.txt"
  grep -F 'Quake smoke dry-run' "$tmp_dir/booted-vm.txt" >/dev/null ||
    die "booted VM proof did not include Quake smoke step"
  grep -F 'eos-logs engine --last 200' "$tmp_dir/booted-vm.txt" >/dev/null ||
    die "booted VM proof did not include engine log step"
  grep -F 'eos-crash-bundle --vm' "$tmp_dir/booted-vm.txt" >/dev/null ||
    die "booted VM proof did not include VM crash bundle mode"
  grep -F 'Booted-ISO proof preview completed; no booted-ISO proof was executed.' "$tmp_dir/booted-vm.txt" >/dev/null ||
    die "booted VM dry-run did not clearly identify itself as a preview"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" booted-iso --runtime --dry-run >"$tmp_dir/booted-runtime.txt"
  grep -F 'runtime reliability dry-run' "$tmp_dir/booted-runtime.txt" >/dev/null ||
    die "booted runtime proof did not include runtime reliability step"
  grep -F 'eos-logs runtime --last 200' "$tmp_dir/booted-runtime.txt" >/dev/null ||
    die "booted runtime proof did not include runtime log step"
  grep -F 'eos-crash-bundle --runtime' "$tmp_dir/booted-runtime.txt" >/dev/null ||
    die "booted runtime proof did not include runtime crash bundle mode"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" booted-iso --bare-metal --dry-run >"$tmp_dir/booted-bare-metal.txt"
  grep -F 'eos-outputs validate --single' "$tmp_dir/booted-bare-metal.txt" >/dev/null ||
    die "booted bare-metal proof did not include explicit output validation"
  grep -F 'eos-crash-bundle --bare-metal' "$tmp_dir/booted-bare-metal.txt" >/dev/null ||
    die "booted bare-metal proof did not include bare-metal crash bundle mode"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" shell-launch --runtime --dry-run >"$tmp_dir/shell-launch.txt"
  grep -F 'Shell-launch proof preview completed; no shell-launch proof was executed.' "$tmp_dir/shell-launch.txt" >/dev/null ||
    die "shell-launch dry-run did not clearly identify itself as a preview"
  grep -F 'grep -E' "$tmp_dir/shell-launch.txt" | grep -F 'renderer diagnostics' >/dev/null ||
    die "shell-launch proof did not check renderer diagnostics"
  grep -F 'app launch app=terminal owner=engineos-shell' "$tmp_dir/shell-launch.txt" >/dev/null ||
    die "shell-launch proof did not check terminal launch ownership"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" shell-launch --bare-metal --dry-run >"$tmp_dir/shell-launch-bare-metal.txt"
  grep -F 'bare-metal shell renderer dry-run' "$tmp_dir/shell-launch-bare-metal.txt" >/dev/null ||
    die "bare-metal shell-launch proof did not include shell renderer gate"
  grep -F 'wlr_renderer=(gles2|vulkan)' "$tmp_dir/shell-launch-bare-metal.txt" >/dev/null ||
    die "bare-metal shell-launch proof did not require GL-capable renderer evidence"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" launchpad --runtime --dry-run >"$tmp_dir/launchpad.txt"
  grep -F 'Launchpad proof preview completed; no launchpad proof was executed.' "$tmp_dir/launchpad.txt" >/dev/null ||
    die "launchpad dry-run did not clearly identify itself as a preview"
  grep -F 'eos-app status --json' "$tmp_dir/launchpad.txt" >/dev/null ||
    die "launchpad proof did not check structured app status"
  grep -F 'eos-app manifest validate' "$tmp_dir/launchpad.txt" >/dev/null ||
    die "launchpad proof did not validate app manifest"
  grep -F 'app=(terminal|cube|quake)' "$tmp_dir/launchpad.txt" >/dev/null ||
    die "launchpad proof did not check all app ownership markers"
  grep -F "grep -F 'view mapped role=engine'" "$tmp_dir/launchpad.txt" >/dev/null ||
    die "launchpad proof did not require a mapped engine slot"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" visual --dry-run >"$tmp_dir/visual.txt"
  grep -F 'eos-capture frame --target shell' "$tmp_dir/visual.txt" >/dev/null ||
    die "visual proof dry-run did not include frame capture"
  grep -F 'result=image' "$tmp_dir/visual.txt" >/dev/null ||
    die "visual proof dry-run did not require image capture evidence"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$PROOF_DIR/proof.sh" mc-preview --dry-run >"$tmp_dir/mc-preview.txt"
  grep -F 'eos-test image-preview' "$tmp_dir/mc-preview.txt" >/dev/null ||
    die "mc-preview proof dry-run did not include image-preview acceptance"
  grep -F 'engine-image-preview --quick-view' "$tmp_dir/mc-preview.txt" >/dev/null ||
    die "mc-preview proof dry-run did not include quick-view dry-run checks"
  grep -F 'engine-image-preview --ping' "$tmp_dir/mc-preview.txt" >/dev/null ||
    die "mc-preview proof dry-run did not include live preview IPC check"
  grep -F 'owner=mc-quick-view:' "$tmp_dir/mc-preview.txt" >/dev/null ||
    die "mc-preview proof dry-run did not require MC preview shell log ownership evidence"
  if ENGINEOS_LOG_DIR="$tmp_dir/logs" \
      ENGINEOS_CAPTURE_DIR="$tmp_dir/captures" \
      ENGINEOS_CAPTURE_TOOL=metadata \
      "$PROOF_DIR/proof.sh" visual >"$tmp_dir/visual-metadata.txt" 2>&1; then
    die "visual proof accepted metadata-only capture as visual proof"
  fi
  grep -F 'metadata-only capture is not visual proof' "$tmp_dir/visual-metadata.txt" >/dev/null ||
    die "visual proof metadata-only failure was not explicit"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    ENGINEOS_CAPTURE_DIR="$tmp_dir/captures" \
    ENGINEOS_CAPTURE_TOOL=metadata \
    "$PROOF_DIR/proof.sh" visual --allow-metadata >"$tmp_dir/visual-allow-metadata.txt"
  grep -F 'Metadata-only capture accepted by explicit request' "$tmp_dir/visual-allow-metadata.txt" >/dev/null ||
    die "visual proof did not document explicit metadata acceptance"
  if grep -En 'warn ".*missing|WARN .*missing' "$PROOF_DIR/proof.sh" "$PROOF_DIR/validate_boot.sh" >"$tmp_dir/proof-lint.txt"; then
    die "proof code contains a required-evidence missing warning instead of failing"
  fi

  local mc_preview_logs="$tmp_dir/mc-preview-logs"
  local fake_preview_cmd="$tmp_dir/fake-engine-image-preview"
  mkdir -p "$mc_preview_logs"
  cat >"$fake_preview_cmd" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  chmod +x "$fake_preview_cmd"
  if ENGINEOS_LOG_DIR="$mc_preview_logs" \
      ENGINEOS_IMAGE_PREVIEW_CMD="$fake_preview_cmd" \
      "$PROOF_DIR/proof.sh" mc-preview >"$tmp_dir/mc-preview-missing-shell-log.txt" 2>&1; then
    die "mc-preview proof accepted missing shell log evidence"
  fi
  grep -F "shell log missing: $mc_preview_logs/shell.log" "$tmp_dir/mc-preview-missing-shell-log.txt" >/dev/null ||
    die "mc-preview missing shell log failure was not explicit"

  cat >"$fake_preview_cmd" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "--ping" ]]; then
  exit 0
fi
if [[ "$1" == "--quick-view" ]]; then
  image="$2"
  printf '[2026-01-01T00:00:00Z] image preview shown path=%s owner=mc-quick-view:fixture:no-pane:terminal:right slot=terminal image=4x3 x=0 y=0 size=4x3 bounds=80x24\n' "$image" >>"$ENGINEOS_FAKE_SHELL_LOG"
  exit 0
fi
exit 2
FAKE
  chmod +x "$fake_preview_cmd"
  ENGINEOS_LOG_DIR="$mc_preview_logs" \
    ENGINEOS_IMAGE_PREVIEW_CMD="$fake_preview_cmd" \
    ENGINEOS_FAKE_SHELL_LOG="$mc_preview_logs/shell.log" \
    "$PROOF_DIR/proof.sh" mc-preview >"$tmp_dir/mc-preview-real.txt"
  grep -F 'MC preview proof runner completed' "$tmp_dir/mc-preview-real.txt" >/dev/null ||
    die "mc-preview proof did not pass with live preview shell log evidence"

  local shell_launch_logs="$tmp_dir/shell-launch-logs"
  local shell_launch_state="$tmp_dir/shell-launch-state"
  local fake_bin="$tmp_dir/fake-bin"
  mkdir -p "$shell_launch_logs" "$shell_launch_state" "$fake_bin"
  cat >"$fake_bin/engineos-shell" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  cat >"$fake_bin/pgrep" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "-a" && "$2" == "engineos-shell" ]]; then
  printf '123 engineos-shell --tty\n'
  exit 0
fi
exit 1
FAKE
  chmod +x "$fake_bin/engineos-shell" "$fake_bin/pgrep"
  {
    printf '[2026-01-01T00:00:00Z] engineos-shell mode=tty backend=drm wayland_display=wayland-1\n'
    printf '[2026-01-01T00:00:01Z] client launch environment WAYLAND_DISPLAY=wayland-1\n'
    printf '[2026-01-01T00:00:02Z] renderer diagnostics EGL GLES2 wlr_renderer=gles2\n'
  } >"$shell_launch_logs/shell.log"
  {
    printf '[2026-01-01T00:00:03Z] terminal launch owner=engineos-shell display=wayland-1\n'
    printf '[2026-01-01T00:00:04Z] session command=engineos-tmux-attach-primary\n'
  } >"$shell_launch_logs/terminal.log"
  if PATH="$fake_bin:$PATH" \
      ENGINEOS_LOG_DIR="$shell_launch_logs" \
      ENGINEOS_STATE_DIR="$shell_launch_state" \
      "$PROOF_DIR/proof.sh" shell-launch --runtime >"$tmp_dir/shell-launch-missing-app-log.txt" 2>&1; then
    die "shell-launch proof accepted missing app.log"
  fi
  grep -F "app log missing: $shell_launch_logs/app.log" "$tmp_dir/shell-launch-missing-app-log.txt" >/dev/null ||
    die "shell-launch missing app.log failure was not explicit"

  local launchpad_logs="$tmp_dir/launchpad-logs"
  local launchpad_state="$tmp_dir/launchpad-state"
  mkdir -p "$launchpad_logs" "$launchpad_state"
  {
    printf '[2026-01-01T00:00:00Z] engineos-shell mode=tty backend=drm,libinput wayland_display=wayland-1\n'
    printf '[2026-01-01T00:00:01Z] bootstrap mode=launchpad\n'
    printf '[2026-01-01T00:00:02Z] launchpad active slot=cube mode=terminal capture=none reason=bootstrap-launchpad\n'
    printf '[2026-01-01T00:00:03Z] launch action label=bootstrap-terminal role=terminal pid=100 command=eos-app launch terminal\n'
    printf '[2026-01-01T00:00:04Z] launch action label=bootstrap-cube role=cube pid=101 command=eos-app launch cube\n'
    printf '[2026-01-01T00:00:05Z] launch action label=bootstrap-engine role=engine pid=102 command=eos-app launch quake\n'
    printf '[2026-01-01T00:00:06Z] view mapped role=cube title=engineos-cube app_id=engineos-cube mapped_total=1\n'
    printf '[2026-01-01T00:00:07Z] launch action exit label=bootstrap-engine role=engine pid=102 status=exited code=1 mapped=false command=eos-app launch quake\n'
    printf '[2026-01-01T00:00:08Z] launchpad slot unavailable role=engine reason=process-exited-before-map status=exited code=1\n'
  } >"$launchpad_logs/shell.log"
  cat >"$launchpad_state/shell-state.json" <<'JSON'
{
  "schema": "engineos-shell-state-v0",
  "pid": 999,
  "mode": "tty",
  "wayland_display": "wayland-1",
  "bootstrap": "launchpad",
  "active_slot": "cube",
  "pending_slot": "unknown",
  "input": {"mode": "terminal", "capture": false},
  "counts": {"outputs": 1, "keyboards": 1, "pointers": 1, "views": 1},
  "last_reason": "launch-exit",
  "slots": {
    "terminal": {"mapped": false, "visible": false, "title": "", "app_id": ""},
    "cube": {"mapped": true, "visible": true, "title": "engineos-cube", "app_id": "engineos-cube"},
    "engine": {"mapped": false, "visible": false, "title": "", "app_id": ""}
  },
  "launches": []
}
JSON
  {
    printf '[2026-01-01T00:00:03Z] app launch app=terminal owner=engineos-shell display=wayland-1\n'
    printf '[2026-01-01T00:00:04Z] app launch app=cube owner=engineos-shell display=wayland-1 sdl=wayland args= log=%s/cube.log\n' "$launchpad_logs"
    printf '[2026-01-01T00:00:05Z] app launch app=quake owner=engineos-shell display=wayland-1 sdl=wayland args=\n'
  } >"$launchpad_logs/app.log"
  {
    printf 'EngineOS cube app\n'
    printf 'gl_renderer=llvmpipe test renderer\n'
    printf 'frames=8\n'
    printf 'result=smoke-ok\n'
  } >"$launchpad_logs/cube.log"
  printf 'Quake assets missing: id1/pak0.pak was not found.\n' >"$launchpad_logs/engine.log"
  if ENGINEOS_LOG_DIR="$launchpad_logs" ENGINEOS_STATE_DIR="$launchpad_state" \
      "$PROOF_DIR/proof.sh" launchpad --runtime >"$tmp_dir/launchpad-real-missing-engine.txt" 2>&1; then
    die "launchpad proof accepted missing Quake assets as engine proof"
  fi
  grep -F 'Quake asset/runtime guidance is not launchpad proof' "$tmp_dir/launchpad-real-missing-engine.txt" >/dev/null ||
    die "launchpad proof failure did not explain missing engine mapping"

  printf '[2026-01-01T00:00:09Z] view mapped role=engine title=QuakeSpasm app_id=quakespasm mapped_total=2\n' >>"$launchpad_logs/shell.log"
  printf 'QuakeSpasm basedir=%s\n' "$tmp_dir/home/.local/share/engineos/quake" >"$launchpad_logs/engine.log"
  ENGINEOS_LOG_DIR="$launchpad_logs" ENGINEOS_STATE_DIR="$launchpad_state" \
    "$PROOF_DIR/proof.sh" launchpad --runtime >"$tmp_dir/launchpad-real.txt"
  grep -F 'Launchpad proof runner completed' "$tmp_dir/launchpad-real.txt" >/dev/null ||
    die "launchpad proof did not pass with mapped engine fixture logs"

  if ! find "$tmp_dir/logs" -maxdepth 1 -type f -name 'proof-booted-iso-*.log' -size +0c -print -quit | grep -q .; then
    die "proof dry-run did not create non-empty proof logs"
  fi
  if ! find "$tmp_dir/logs" -maxdepth 1 -type f -name 'proof-release-candidate-*.log' -size +0c -print -quit | grep -q .; then
    die "release-candidate proof dry-run did not create non-empty proof log"
  fi
  if ! find "$tmp_dir/logs" -maxdepth 1 -type f -name 'proof-hardware-ready-*.log' -size +0c -print -quit | grep -q .; then
    die "hardware-ready proof dry-run did not create non-empty proof log"
  fi

  printf 'proof dry-run test passed\n'
}

run_builder() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-builder-test-$$"
  local out="$tmp_dir/builder.txt"

  cleanup_builder() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_builder RETURN
  mkdir -p "$tmp_dir"

  if is_arch_linux && [[ "$ROOT" == "/srv/engineos" ]]; then
    "$SCRIPT_DIR/validate_builder.sh" >"$out"
    grep -F 'Builder validation summary: 0 failure(s)' "$out" >/dev/null ||
      die "real builder validation did not report clean summary"
  else
    if "$SCRIPT_DIR/validate_builder.sh" >"$out" 2>&1; then
      die "builder validation passed outside the real builder context"
    fi
    grep -E 'real builder validation must run on Arch Linux|repo root must be /srv/engineos' "$out" >/dev/null ||
      die "builder validation failure did not explain the real builder requirement"
  fi

  printf 'builder validation contract test passed\n'
}

run_builder_handoff() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-builder-handoff-$$"
  local out="$tmp_dir/handoff.txt"

  cleanup_builder_handoff() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_builder_handoff RETURN

  mkdir -p "$tmp_dir"

  "$BUILDER_DIR/builder_handoff.sh" --dry-run --host dev@192.0.2.10 --dest /srv/engineos >"$out"
  grep -F 'dev@192.0.2.10' "$out" >/dev/null ||
    die "builder handoff dry-run did not include ssh target"
  grep -F -- '-o BatchMode=yes' "$out" >/dev/null ||
    die "builder handoff dry-run did not use non-interactive ssh"
  grep -F -- '-o ConnectTimeout=' "$out" >/dev/null ||
    die "builder handoff dry-run did not use ssh connect timeout"
  grep -F 'rsync -a' "$out" >/dev/null ||
    die "builder handoff dry-run did not include rsync"
  grep -F -- '-e ssh\' "$out" >/dev/null ||
    die "builder handoff dry-run did not route rsync through configured ssh"
  grep -F '/srv/engineos' "$out" >/dev/null ||
    die "builder handoff dry-run did not target /srv/engineos"
  grep -F './tools/engineos/eos-builder\ bootstrap' "$out" >/dev/null ||
    die "builder handoff dry-run did not include bootstrap"
  grep -F './tools/engineos/eos-validate\ builder' "$out" >/dev/null ||
    die "builder handoff dry-run did not include builder validation"
  grep -F './tools/engineos/eos-build\ repo' "$out" >/dev/null ||
    die "builder handoff dry-run did not include real repo build"
  grep -F './tools/engineos/eos-validate\ repo' "$out" >/dev/null ||
    die "builder handoff dry-run did not include repo validation"
  if grep -F -- '--delete' "$out" >/dev/null; then
    die "builder handoff dry-run should not delete remote files by default"
  fi

  "$BUILDER_DIR/builder_handoff.sh" --dry-run --host dev@192.0.2.10 --skip-bootstrap >"$out"
  if grep -F './tools/engineos/eos-builder\ bootstrap' "$out" >/dev/null; then
    die "builder handoff --skip-bootstrap still included bootstrap"
  fi

  "$BUILDER_DIR/builder_handoff.sh" --dry-run --host dev@192.0.2.10 --run-proof >"$out"
  grep -F './tools/engineos/eos-builder\ bootstrap' "$out" >/dev/null ||
    die "builder handoff --run-proof did not include bootstrap"
  grep -F './tools/engineos/eos-proof\ build-lab' "$out" >/dev/null ||
    die "builder handoff --run-proof did not include build-lab proof"
  grep -F 'Next real command: ./tools/engineos/eos-builder handoff --host dev@192.0.2.10 --run-proof' "$out" >/dev/null ||
    die "builder handoff --run-proof did not preserve the real command hint"

  if "$BUILDER_DIR/builder_handoff.sh" --host dev@192.0.2.10 --dest relative/path >/dev/null 2>&1; then
    die "builder handoff accepted a relative destination"
  fi

  printf 'builder handoff dry-run test passed\n'
}

run_builder_doctor() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-builder-doctor-$$"
  local out="$tmp_dir/doctor-proof.txt"

  cleanup_builder_doctor() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_builder_doctor RETURN

  mkdir -p "$tmp_dir"
  "$BUILDER_DIR/builder_doctor_proof.sh" --dry-run --host dev@192.0.2.10 --guest-port 2223 >"$out"
  grep -F 'dev@192.0.2.10' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include builder ssh target"
  grep -F './tools/engineos/eos-proof build-lab' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include build-lab proof"
  grep -F -- '-p\ 2223' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include guest ssh port"
  grep -F 'dev@127.0.0.1' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include guest ssh target"
  grep -F 'eos-doctor\\\ --vm' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include VM doctor command"

  "$BUILDER_DIR/builder_doctor_proof.sh" --dry-run --host dev@192.0.2.10 --skip-build >"$out"
  if grep -F 'run builder build proof' "$out" >/dev/null; then
    die "builder doctor proof --skip-build still ran build-lab proof"
  fi
  grep -F 'eos-doctor\\\ --vm' "$out" >/dev/null ||
    die "builder doctor proof --skip-build did not include VM doctor command"

  printf 'builder doctor proof dry-run test passed\n'
}

run_post_first_deploy() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-post-first-deploy-test-$$"
  local out="$tmp_dir/post-first-deploy.txt"
  local move_socket="engineos-window-move-test-$$"
  local payload_dir
  payload_dir="$(post_install_payload_dir)"

  cleanup_post_first_deploy() {
    if command -v tmux >/dev/null 2>&1; then
      tmux -L "$move_socket" kill-server 2>/dev/null || true
    fi
    rm -rf "$tmp_dir"
  }
  trap cleanup_post_first_deploy RETURN

  mkdir -p "$tmp_dir"
  "$OS_DEV_DIR/post_first_deploy.sh" --dry-run --host dev@192.0.2.55 --port 2225 >"$out"
  grep -F 'EngineOS post-first-deploy dry-run' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing header"
  grep -F 'dev@192.0.2.55' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing guest host"
  grep -F -- '-P 2225' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing scp port"
  grep -F "$payload_dir" "$out" >/dev/null ||
    die "post-first-deploy dry-run missing payload path"
  grep -F 'setup_dev_environment.sh' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing remote setup script"
  grep -F -- '--payload' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing setup payload argument"
  grep -F 'Next real command: eos-deploy first --host dev@192.0.2.55 --port 2225' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing real command hint"

  "$OS_DEV_DIR/post_first_deploy.sh" --dry-run --host dev@192.0.2.55 --skip-codex --skip-docker --skip-pacman --skip-dev-repos >"$out"
  grep -F -- '--skip-codex' "$out" >/dev/null ||
    die "post-first-deploy dry-run did not preserve --skip-codex"
  grep -F -- '--skip-docker' "$out" >/dev/null ||
    die "post-first-deploy dry-run did not preserve --skip-docker"
  grep -F -- '--skip-pacman' "$out" >/dev/null ||
    die "post-first-deploy dry-run did not preserve --skip-pacman"
  grep -F -- '--skip-dev-repos' "$out" >/dev/null ||
    die "post-first-deploy dry-run did not preserve --skip-dev-repos"

  [[ -f "$payload_dir/assets/tmux.conf" ]] ||
    die "post-first-deploy payload missing tmux config"
  grep -F 'set -g mouse on' "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not enable mouse support"
  grep -F "@engineos-plugins" "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not declare packaged plugins"
  grep -F "/usr/share/tmux/plugins/tmux-sensible/sensible.tmux" "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not source packaged plugins"
  grep -F 'set -g status-style bg=colour235,fg=colour250' "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not set the EngineOS color status style"
  grep -F '#{pane_current_path}' "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config status line does not show pane path"
  grep -F 'engineos-tmux-pane-bridge sync' "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not wire EngineOS pane bridge sync"
  grep -F 'engineos-tmux-pane-bridge focus --pane #{pane_id}' "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not wire pane focus hooks"
  grep -F 'engineos-tmux-pane-bridge geometry --all-visible' "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not wire pane geometry hooks"
  grep -F '"Move to Session..."' "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux window menu does not offer session moves"
  grep -F 'engineos-tmux-window-move choose' "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux window menu does not invoke the move helper"
  grep -F 'engineos-tmux-window-move session-create "#{client_name}"' \
      "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux session menu does not preserve the invoking client"
  if grep -F '"New Session" s { new-session }' "$payload_dir/assets/tmux.conf" >/dev/null; then
    die "post-first-deploy tmux session menu still uses client-terminating new-session"
  fi
  if grep -F 'engineos-tmux-window-sync --daemon' "$payload_dir/assets/tmux.conf" >/dev/null ||
      grep -F 'engineos-tmux-window-focus' "$payload_dir/assets/tmux.conf" >/dev/null; then
    die "post-first-deploy tmux config still wires legacy GUI proxy helpers"
  fi
  grep -F 'after-select-pane' "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not sync after pane selection"
  grep -F "set -g @continuum-restore 'on'" "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not auto-restore saved layouts"
  grep -F "set -g @resurrect-capture-pane-contents 'off'" "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config should avoid brittle pane content capture"
  grep -F "set -g @resurrect-processes ':all:'" "$payload_dir/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not persist pane commands"
  if grep -F 'eos-app pane sync --all >/dev/null 2>&1 || true' "$payload_dir/assets/tmux.conf" >/dev/null ||
      grep -F 'eos-app pane sync >/dev/null 2>&1 || true' "$payload_dir/assets/tmux.conf" >/dev/null; then
    die "post-first-deploy tmux config silently ignores pane sync failures"
  fi
  [[ -x "$payload_dir/scripts/engineos-tmux-pane-bridge" ]] ||
    die "post-first-deploy payload missing tmux pane bridge helper"
  grep -F 'pane-bridge' "$payload_dir/scripts/engineos-tmux-pane-bridge" >/dev/null ||
    die "post-first-deploy tmux pane bridge helper does not log failures"
  [[ -x "$payload_dir/scripts/engineos-tmux-window-move" ]] ||
    die "post-first-deploy payload missing tmux window move helper"
  grep -F 'move-window -s "$source_window_id" -t "$destination_session_id:"' \
      "$payload_dir/scripts/engineos-tmux-window-move" >/dev/null ||
    die "tmux window move helper does not move by stable window and session ids"
  grep -F '"$TMUX_BIN" choose-tree -N -s' \
      "$payload_dir/scripts/engineos-tmux-window-move" >/dev/null ||
    die "tmux window move helper does not use the native multi-session chooser"
  grep -F '"$TMUX_BIN" new-session -d -P -F' \
      "$payload_dir/scripts/engineos-tmux-window-move" >/dev/null ||
    die "tmux window move helper does not create sessions detached"
  grep -F '"$TMUX_BIN" switch-client -c "$client" -t "$session_id"' \
      "$payload_dir/scripts/engineos-tmux-window-move" >/dev/null ||
    die "tmux window move helper does not switch the invoking client by stable session id"
  grep -F '"$BRIDGE_BIN" sync' "$payload_dir/scripts/engineos-tmux-window-move" >/dev/null ||
    die "tmux window move helper does not resync EngineOS pane state"
  if command -v tmux >/dev/null 2>&1; then
    local move_tmux="$tmp_dir/tmux-move"
    local source_window_id destination_session_id
    cat >"$move_tmux" <<EOF
#!/usr/bin/env bash
exec tmux -L "$move_socket" "\$@"
EOF
    chmod +x "$move_tmux"
    tmux -L "$move_socket" -f /dev/null new-session -d -s source -n moving
    tmux -L "$move_socket" new-window -d -t source: -n keep
    tmux -L "$move_socket" new-session -d -s destination -n existing
    source_window_id="$(tmux -L "$move_socket" list-windows -t source \
      -F '#{window_id} #{window_name}' | awk '$2 == "moving" { print $1 }')"
    destination_session_id="$(tmux -L "$move_socket" display-message \
      -p -t destination '#{session_id}')"
    ENGINEOS_TMUX_CMD="$move_tmux" ENGINEOS_TMUX_PANE_BRIDGE=true \
      "$payload_dir/scripts/engineos-tmux-window-move" \
      apply "$source_window_id" "$destination_session_id"
    [[ "$(tmux -L "$move_socket" display-message -p -t "$source_window_id" \
      '#{session_name}')" == destination ]] ||
      die "tmux window move helper did not move the selected window"
    tmux -L "$move_socket" new-window -d -t source: -n automatic
    source_window_id="$(tmux -L "$move_socket" list-windows -t source \
      -F '#{window_id} #{window_name}' | awk '$2 == "automatic" { print $1 }')"
    ENGINEOS_TMUX_CMD="$move_tmux" ENGINEOS_TMUX_PANE_BRIDGE=true \
      "$payload_dir/scripts/engineos-tmux-window-move" \
      choose "$source_window_id" ""
    [[ "$(tmux -L "$move_socket" display-message -p -t "$source_window_id" \
      '#{session_name}')" == destination ]] ||
      die "tmux window move helper did not directly use the sole destination"
  fi
  for helper in engineos-tmux-pane-sync engineos-tmux-window-sync engineos-tmux-window-focus engineos-tmux-window-proxy; do
    [[ -x "$payload_dir/scripts/$helper" ]] ||
      die "post-first-deploy payload missing executable deprecated tmux GUI helper: $helper"
  done
  grep -F 'engineos-tmux-pane-bridge sync' "$payload_dir/scripts/engineos-tmux-window-sync" >/dev/null ||
    die "deprecated tmux window sync helper does not delegate to pane bridge"
  grep -F 'engineos-tmux-pane-bridge focus' "$payload_dir/scripts/engineos-tmux-window-focus" >/dev/null ||
    die "deprecated tmux focus helper does not delegate to pane bridge"
  [[ -f "$payload_dir/assets/zshrc" ]] ||
    die "post-first-deploy payload missing zsh config"
  [[ -f "$payload_dir/assets/zprofile" ]] ||
    die "post-first-deploy payload missing zprofile config"
  grep -F '/usr/share/oh-my-zsh' "$payload_dir/assets/zshrc" >/dev/null ||
    die "post-first-deploy zsh config does not use packaged oh-my-zsh"
  grep -F 'zsh-autosuggestions.zsh' "$payload_dir/assets/zshrc" >/dev/null ||
    die "post-first-deploy zsh config does not source packaged plugins"
  grep -F 'engineos-tmux-attach-primary' "$payload_dir/assets/zprofile" >/dev/null ||
    die "post-first-deploy zprofile does not auto-attach tmux"
  grep -F 'tools/scripts/update_check.sh" --init' "$payload_dir/assets/zprofile" >/dev/null ||
    die "post-first-deploy zprofile does not run source update init check"
  grep -F 'eos-update check --init' "$payload_dir/assets/zprofile" >/dev/null ||
    die "post-first-deploy zprofile does not run update init check"
  grep -F 'engineos_profile_run()' "$payload_dir/assets/zprofile" >/dev/null ||
    die "post-first-deploy zprofile does not expose login hook failures"
  grep -F 'profile-warning' "$payload_dir/assets/zprofile" >/dev/null ||
    die "post-first-deploy zprofile does not log login hook warnings"
  if grep -F 'eos-observe prompt-login --shell zsh || true' "$payload_dir/assets/zprofile" >/dev/null ||
      grep -F 'update_check.sh" --init || true' "$payload_dir/assets/zprofile" >/dev/null ||
      grep -F 'eos-update check --init || true' "$payload_dir/assets/zprofile" >/dev/null; then
    die "post-first-deploy zprofile silently ignores login hook failures"
  fi
  [[ -f "$payload_dir/assets/docker/daemon.json" ]] ||
    die "post-first-deploy payload missing Docker config"
  [[ -x "$payload_dir/scripts/setup_dev_environment.sh" ]] ||
    die "post-first-deploy payload setup script is not executable"
  [[ -x "$payload_dir/scripts/engineos-dev-shell-start" ]] ||
    die "post-first-deploy payload dev shell start script is not executable"
  grep -F 'refresh_wayland_session' "$payload_dir/scripts/engineos-dev-shell-start" >/dev/null ||
    die "post-first-deploy dev shell start does not refresh stale Wayland state"
  grep -F 'pgrep -u "$(id -u)" -x engineos-shell' "$payload_dir/scripts/engineos-dev-shell-start" >/dev/null ||
    die "post-first-deploy dev shell start does not terminate same-user stale shells"
  grep -F 'wayland-*' "$payload_dir/scripts/engineos-dev-shell-start" >/dev/null ||
    die "post-first-deploy dev shell start does not clear stale Wayland sockets"
  grep -F 'engineos-tmux-pane-bridge' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not install tmux pane bridge helper"
  grep -F 'engineos-tmux-attach-primary' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not install tmux primary attach helper"
  grep -F 'engineos-tmux-window-move' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not install tmux window move helper"
  grep -F 'engineos-tmux-window-sync' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not install deprecated tmux GUI helper wrappers"
  [[ -f "$payload_dir/assets/systemd/engineos-dev-shell.service" ]] ||
    die "post-first-deploy payload missing dev shell service"
  grep -F 'ENGINEOS_TERMINAL_REQUIRE_WAYLAND=true' "$payload_dir/assets/systemd/engineos-dev-shell.service" >/dev/null ||
    die "post-first-deploy dev shell service does not require Wayland terminal ownership"
  grep -F 'ENGINEOS_TERMINAL_SESSION_CMD=engineos-tmux-attach-primary' "$payload_dir/assets/systemd/engineos-dev-shell.service" >/dev/null ||
    die "post-first-deploy dev shell service does not launch tmux"
  grep -F 'engineos-shell' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not request engineos-shell"
  grep -F 'engineos-tools' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not request engineos-tools"
  grep -F 'engineos-cube' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not request engineos-cube"
  grep -F 'engineos-level-agent' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not request the Quake level workflow"
  grep -F 'engineos-trenchbroom' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not request the Quake editor workflow"
  grep -F 'npm install -g @openai/codex@latest' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not upgrade npm-managed Codex"
  if grep -F 'best_effort()' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
      grep -F 'WARN best-effort failed' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null; then
    die "post-first-deploy setup still contains best-effort service handling"
  fi
  if grep -F 'systemctl enable docker.service >/dev/null 2>&1 || true' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
      grep -F 'systemctl daemon-reload || true' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
      grep -F 'chsh -s /usr/bin/zsh "$TARGET_USER" || true' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null; then
    die "post-first-deploy setup silently ignores service or shell setup failures"
  fi
  grep -F 'codex-extractor' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not fetch codex-extractor"
  grep -F 'session-extrator' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not fetch session-extrator"
  grep -F 'session-extrator.git@v$version' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not install the pinned codex-insights release"
  grep -F 'opencode-autonomy' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not fetch opencode-autonomy"
  grep -F 'agent' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not fetch agent"
  grep -F 'quake-generator:quake-os-integration' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not fetch the pinned dgen source repository"
  grep -F 'skills' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not fetch skills"
  grep -F 'Tango-Rocker' "$payload_dir/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not fetch from Tango-Rocker"

  printf 'post-first-deploy dry-run test passed\n'
}

run_update_check() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-update-check-test-$$"
  local repo="$tmp_dir/tango-os"
  local out="$tmp_dir/update-check.txt"

  cleanup_update_check() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_update_check RETURN

  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email engineos@example.invalid
  git -C "$repo" config user.name "EngineOS Test"
  printf 'one\n' >"$repo/VERSION"
  git -C "$repo" add VERSION
  git -C "$repo" commit -q -m 'v0.1.0'
  git -C "$repo" tag v0.1.0
  printf 'two\n' >"$repo/VERSION"
  git -C "$repo" commit -q -am 'v0.2.0'
  git -C "$repo" tag v0.2.0
  git -C "$repo" checkout -q v0.1.0

  ENGINEOS_TANGO_OS_ROOT="$repo" \
    ENGINEOS_ENGINE_OS_ROOT="$tmp_dir/missing-engine" \
    "$SCRIPT_DIR/update_check.sh" --no-fetch --dry-run --yes --skip-post-install >"$out"

  grep -F 'tango-os: newer semver tag available: v0.1.0 -> v0.2.0' "$out" >/dev/null ||
    die "update check did not report semver tag upgrade"
  grep -F 'dry-run: git -C '"$repo"' checkout v0.2.0' "$out" >/dev/null ||
    die "update check dry-run did not print planned checkout"
  grep -F 'engine-os: skipped; Git checkout not found' "$out" >/dev/null ||
    die "update check did not skip missing engine-os checkout"

  if ENGINEOS_ENGINE_OS_ROOT="$tmp_dir/missing-engine" \
      "$SCRIPT_DIR/update_check.sh" --component engine-os --no-fetch --dry-run --yes --skip-post-install >"$out" 2>&1; then
    die "update check accepted an explicitly requested missing engine-os checkout"
  fi
  grep -F 'engine-os checkout not found at' "$out" >/dev/null ||
    die "update check did not fail explicit missing engine-os checkout clearly"

  if ENGINEOS_TANGO_OS_ROOT="$repo" \
      "$SCRIPT_DIR/update_check.sh" --component tango-os --dry-run --yes --skip-post-install >"$out" 2>&1; then
    die "update check succeeded when tag fetch failed"
  fi
  grep -F 'could not fetch tags from origin' "$out" >/dev/null ||
    die "update check fetch failure was not explicit"

  ENGINEOS_TANGO_OS_ROOT="$repo" \
    "$SCRIPT_DIR/update_check.sh" --component tango-os --no-fetch --yes --skip-post-install >"$out"
  [[ "$(git -C "$repo" describe --tags --exact-match)" == "v0.2.0" ]] ||
    die "update check did not checkout accepted semver tag"

  printf 'update check test passed\n'
}

run_bootstrap() {
  "$BUILDER_DIR/bootstrap_builder.sh" --dry-run >/dev/null
  "$BUILDER_DIR/bootstrap_builder.sh" --print-packages | grep -Fx 'archiso' >/dev/null ||
    die "builder bootstrap package list missing archiso"
  "$BUILDER_DIR/bootstrap_builder.sh" --print-packages | grep -Fx 'wlroots0.19' >/dev/null ||
    die "builder bootstrap package list missing wlroots0.19"
  printf 'builder bootstrap dry-run test passed\n'
}

run_repo() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-repo-test-$$"
  local out="$tmp_dir/build-repo.txt"

  cleanup_repo() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_repo RETURN

  mkdir -p "$tmp_dir"
  "$SCRIPT_DIR/build_repo.sh" --dry-run >"$out"
  grep -F 'makepkg: rebuild existing package artifacts with -f' "$out" >/dev/null ||
    die "repo dry-run did not document forced package rebuilds"
  grep -F 'repo-add: after each package' "$out" >/dev/null ||
    die "repo dry-run did not document incremental repo-add"
  grep -F 'latest package artifacts' "$out" >/dev/null ||
    die "repo dry-run did not document latest-artifact selection"
  grep -F 'local deps: already-built engineos-* runtime dependencies' "$out" >/dev/null ||
    die "repo dry-run did not document local dependency handling"
  grep -F 'package logs:' "$out" >/dev/null ||
    die "repo dry-run did not document package log directory"
  grep -F 'package sources:' "$out" >/dev/null ||
    die "repo dry-run did not document package source directory"
  grep -F 'package build dir:' "$out" >/dev/null ||
    die "repo dry-run did not document package build directory"
  grep -F 'packages/engineos-quakespasm' "$out" >/dev/null ||
    die "repo dry-run did not include engineos-quakespasm"

  "$SCRIPT_DIR/build_repo.sh" --dry-run \
    --package engineos-shell \
    --package engineos-tools \
    --package engineos-tools >"$out"
  grep -F "    - $ROOT/packages/engineos-tools" "$out" >/dev/null ||
    die "repo dry-run did not include repeated --package engineos-tools"
  grep -F "    - $ROOT/packages/engineos-shell" "$out" >/dev/null ||
    die "repo dry-run did not include repeated --package engineos-shell"
  [[ "$(grep -Fc "    - $ROOT/packages/engineos-tools" "$out")" -eq 1 ]] ||
    die "repo dry-run did not ignore duplicate package selection"

  if "$SCRIPT_DIR/build_repo.sh" --dry-run --package not-a-package >"$out" 2>&1; then
    die "repo dry-run accepted an unknown package"
  fi
  grep -F 'unknown EngineOS package: not-a-package' "$out" >/dev/null ||
    die "repo dry-run unknown package error was not clear"

  if "$SCRIPT_DIR/package_lint.sh" --package not-a-package >"$out" 2>&1; then
    die "package lint accepted an unknown package"
  fi
  grep -F 'unknown EngineOS package: not-a-package' "$out" >/dev/null ||
    die "package lint unknown package error was not clear"

  "$SCRIPT_DIR/package_lint.sh" --package engineos-shell --package engineos-tools >"$out"
  grep -F 'engineos-tools: PKGBUILD metadata' "$out" >/dev/null ||
    die "package lint did not check engineos-tools from repeated package selection"
  grep -F 'engineos-shell: PKGBUILD metadata' "$out" >/dev/null ||
    die "package lint did not check engineos-shell from repeated package selection"

  if "$SCRIPT_DIR/preflight.sh" repo --package not-a-package >"$out" 2>&1; then
    die "preflight accepted an unknown package"
  fi
  grep -F 'unknown EngineOS package: not-a-package' "$out" >/dev/null ||
    die "preflight unknown package error was not clear"

  "$SCRIPT_DIR/preflight.sh" repo --package engineos-shell --package engineos-tools >"$out"
  grep -F 'packages/engineos-tools/PKGBUILD' "$out" >/dev/null ||
    die "preflight did not check engineos-tools from repeated package selection"
  grep -F 'packages/engineos-shell/PKGBUILD' "$out" >/dev/null ||
    die "preflight did not check engineos-shell from repeated package selection"

  "$SCRIPT_DIR/validate_repo.sh" --dry-run >"$out"
  grep -F 'engineos-quakespasm-*.pkg.tar.*' "$out" >/dev/null ||
    die "repo validation dry-run did not expect engineos-quakespasm artifact"
  if [[ "$ROOT" != "/srv/engineos" ]]; then
    if "$SCRIPT_DIR/validate_repo.sh" >"$out" 2>&1; then
      die "repo validation passed outside /srv/engineos"
    fi
    grep -F 'repo directory mismatch: archiso expects /srv/engineos/repo' "$out" >/dev/null ||
      die "repo validation did not explain /srv/engineos requirement"
  fi
  printf 'repo validation smoke test passed\n'
}

run_boot() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-boot-test-$$"
  local fake_bin="$tmp_dir/bin"
  local tool_bin="$tmp_dir/tool-bin"
  local log_dir="$tmp_dir/logs"
  local runtime_conf="$tmp_dir/runtime.conf"
  local apps_manifest="$tmp_dir/apps.toml"
  local drm_sysfs="$tmp_dir/sys/class/drm"
  local dri_dir="$tmp_dir/dev/dri"
  local out="$tmp_dir/out.txt"
  local doctor_log="$tmp_dir/doctor-args.txt"

  cleanup_boot() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_boot RETURN

  mkdir -p "$fake_bin" "$tool_bin" "$log_dir" "$drm_sysfs/card0-HDMI-A-1" "$dri_dir"
  for tool in bash date dirname grep; do
    ln -s "$(command -v "$tool")" "$tool_bin/$tool"
  done
  {
    printf 'ENGINEOS_SHELL_BOOTSTRAP=launchpad\n'
    printf 'ENGINEOS_CUBE_CMD="eos-app launch cube"\n'
    printf 'ENGINEOS_ENGINE_CMD="eos-app launch quake"\n'
    printf 'ENGINEOS_RUNTIME_RECOVERY_TTY=tty2\n'
    printf 'ENGINEOS_TERMINAL_SESSION_CMD="engineos-tmux-attach-primary"\n'
  } >"$runtime_conf"
  cat >"$apps_manifest" <<'EOF_MANIFEST'
[apps.terminal]
slot = "terminal"
role = "terminal"
command = "eos-app launch terminal"
package = "foot"
app_ids = ["foot"]
log = "terminal.log"
input = "normal"

[apps.terminal-secondary]
slot = "terminal-secondary"
role = "terminal-secondary"
command = "eos-app launch terminal-secondary"
package = "foot"
app_ids = ["engineos-terminal-secondary"]
log = "terminal.log"
input = "normal"

[apps.cube]
slot = "cube"
role = "cube"
command = "eos-app launch cube"
smoke_command = "eos-app launch cube --smoke"
package = "engineos-cube"
app_ids = ["engineos-cube"]
log = "cube.log"
health = "gl-renderer-and-frames"
input = "normal"

[apps.quake]
slot = "engine"
role = "engine"
command = "eos-app launch quake"
smoke_command = "eos-app launch quake --smoke"
package = "engineos-quakespasm"
app_ids = ["quakespasm"]
log = "engine.log"
assets = "quake"
input = "game"
EOF_MANIFEST
  {
    printf '[2026-01-01T00:00:00Z] starting EngineOS shell mode=--tty recovery=tty2\n'
    printf '[2026-01-01T00:00:01Z] EngineOS shell failed rc=77; recovery TTY should remain available\n'
  } >"$log_dir/runtime-start.log"
  printf 'connected\n' >"$drm_sysfs/card0-HDMI-A-1/status"
  printf 'enabled\n' >"$drm_sysfs/card0-HDMI-A-1/enabled"
  printf '1920x1080\n' >"$drm_sysfs/card0-HDMI-A-1/modes"
  : >"$dri_dir/card0"
  : >"$dri_dir/renderD128"

  cat >"$fake_bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  is-enabled|is-active|status)
    exit 0
    ;;
  *)
    printf 'fake systemctl: %s\n' "$*" >&2
    exit 2
    ;;
esac
FAKE
  chmod +x "$fake_bin/systemctl"

  cat >"$fake_bin/pacman" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "-Q" ]]; then
  if [[ -n "${ENGINEOS_FAKE_MISSING_PACKAGE:-}" && "${2:-}" == "$ENGINEOS_FAKE_MISSING_PACKAGE" ]]; then
    exit 1
  fi
  exit 0
fi
printf 'fake pacman: %s\n' "$*" >&2
exit 2
FAKE
  chmod +x "$fake_bin/pacman"

  cat >"$fake_bin/eos-app" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "manifest" && "$2" == "validate" ]]; then
  printf 'EngineOS app manifest validation\n'
  printf '  manifest: %s\n' "${ENGINEOS_APPS_MANIFEST:-missing}"
  printf 'OK   cube.app_ids contains engineos-cube\n'
  printf 'App manifest validation summary: 0 failure(s)\n'
  exit 0
fi
printf 'fake eos-app %s\n' "$*"
FAKE
  chmod +x "$fake_bin/eos-app"

  cat >"$fake_bin/quakespasm" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  cat >"$fake_bin/engineos-cube" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  chmod +x "$fake_bin/quakespasm" "$fake_bin/engineos-cube"

  cat >"$fake_bin/engineos-recovery-help" <<'FAKE'
#!/usr/bin/env bash
printf 'eos-logs runtime --last 200\n'
printf 'eos-crash-bundle\n'
printf 'engineos.noautostart\n'
FAKE
  chmod +x "$fake_bin/engineos-recovery-help"
  cat >"$fake_bin/engineos-recovery-help-fail" <<'FAKE'
#!/usr/bin/env bash
printf 'eos-logs runtime --last 200\n'
printf 'eos-crash-bundle\n'
printf 'engineos.noautostart\n'
exit 8
FAKE
  chmod +x "$fake_bin/engineos-recovery-help-fail"

  cat >"$fake_bin/lspci" <<'FAKE'
#!/usr/bin/env bash
printf '03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi test GPU\n'
FAKE
  chmod +x "$fake_bin/lspci"

  cat >"$fake_bin/doctor-ok" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ENGINEOS_FAKE_DOCTOR_ARGS"
printf 'EngineOS doctor fixture\n'
printf 'OpenGL core profile renderer: AMD RADV\n'
FAKE
  chmod +x "$fake_bin/doctor-ok"
  if PATH="$fake_bin:$PATH" "$PROOF_DIR/validate_boot.sh" >"$out" 2>&1; then
    die "boot validation accepted an implicit default mode"
  fi
  grep -F 'validate_boot requires an explicit mode' "$out" >/dev/null ||
    die "boot validation did not explain explicit mode requirement"

  cat >"$fake_bin/doctor-fail" <<'FAKE'
#!/usr/bin/env bash
printf 'doctor fixture failed\n' >&2
exit 9
FAKE
  chmod +x "$fake_bin/doctor-fail"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_RUNTIME_CONF="$runtime_conf" \
    ENGINEOS_APPS_MANIFEST="$apps_manifest" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
    ENGINEOS_FAKE_DOCTOR_ARGS="$doctor_log" \
    "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1
  grep -F "app manifest exists: $apps_manifest" "$out" >/dev/null ||
    die "runtime boot validation did not require app manifest"
  grep -F 'app manifest validates' "$out" >/dev/null ||
    die "runtime boot validation did not validate app manifest"
  grep -F 'runtime recovery TTY configured: tty2' "$out" >/dev/null ||
    die "runtime boot validation did not read runtime recovery TTY fixture"
  grep -F 'package installed: engineos-shell' "$out" >/dev/null ||
    die "runtime boot validation did not require engineos-shell"
  grep -F 'package installed: ttf-dejavu' "$out" >/dev/null ||
    die "runtime boot validation did not require terminal fonts"
  grep -F 'command available: quakespasm' "$out" >/dev/null ||
    die "runtime boot validation did not check quakespasm command"
  grep -F 'command available: engineos-cube' "$out" >/dev/null ||
    die "runtime boot validation did not check engineos-cube command"
  grep -F 'runtime shell bootstrap starts launchpad' "$out" >/dev/null ||
    die "runtime boot validation did not check launchpad bootstrap"
  grep -F 'runtime autostart log records startup decision' "$out" >/dev/null ||
    die "runtime boot validation did not check autostart startup log"
  grep -F 'runtime autostart log records outcome' "$out" >/dev/null ||
    die "runtime boot validation did not check autostart outcome log"
  grep -Fx -- '--vm' "$doctor_log" >/dev/null ||
    die "runtime boot validation did not call doctor in VM mode"

  if PATH="$fake_bin:$PATH" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$tmp_dir/missing-logs" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
      "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1; then
    die "runtime boot validation accepted missing EngineOS log directory"
  fi
  grep -F "$tmp_dir/missing-logs missing" "$out" >/dev/null ||
    die "runtime boot validation did not expose missing EngineOS log directory"

  if PATH="$fake_bin:$PATH" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
      ENGINEOS_FAKE_MISSING_PACKAGE="engineos-cube" \
      "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1; then
    die "runtime boot validation accepted missing required package"
  fi
  grep -F 'package missing: engineos-cube' "$out" >/dev/null ||
    die "runtime boot validation did not expose missing required package"

  mv "$fake_bin/engineos-cube" "$fake_bin/engineos-cube-ok"
  if PATH="$fake_bin:$tool_bin" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
      bash "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1; then
    die "runtime boot validation accepted missing package command"
  fi
  grep -F 'command unavailable: engineos-cube' "$out" >/dev/null ||
    die "runtime boot validation did not expose missing package command"
  mv "$fake_bin/engineos-cube-ok" "$fake_bin/engineos-cube"

  if PATH="$fake_bin:$PATH" \
      ENGINEOS_RUNTIME_CONF="$tmp_dir/missing-runtime.conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
      "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1; then
    die "runtime boot validation accepted missing runtime config"
  fi
  grep -F 'missing-runtime.conf missing' "$out" >/dev/null ||
    die "runtime boot validation did not expose missing runtime config"

  if PATH="$fake_bin:$PATH" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-fail" \
      ENGINEOS_VALIDATE_DOCTOR_OUT="$tmp_dir/runtime-doctor-fail.out" \
      "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1; then
    die "runtime boot validation accepted failing doctor"
  fi
  grep -F 'doctor failed' "$out" >/dev/null ||
    die "runtime boot validation did not expose failing doctor"

  mv "$fake_bin/engineos-recovery-help" "$fake_bin/engineos-recovery-help-ok"
  cp "$fake_bin/engineos-recovery-help-fail" "$fake_bin/engineos-recovery-help"
  chmod +x "$fake_bin/engineos-recovery-help"
  if PATH="$fake_bin:$PATH" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
      ENGINEOS_FAKE_DOCTOR_ARGS="$doctor_log" \
      "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1; then
    die "runtime boot validation accepted failing recovery help"
  fi
  grep -F 'recovery help command failed' "$out" >/dev/null ||
    die "runtime boot validation did not expose failing recovery help"
  mv "$fake_bin/engineos-recovery-help-ok" "$fake_bin/engineos-recovery-help"

  printf '[2026-01-01T00:00:00Z] starting EngineOS shell mode=--tty recovery=tty2\n' >"$log_dir/runtime-start.log"
  printf '[2026-01-01T00:00:00Z] renderer diagnostics backend=drm,libinput wlr_renderer=pixman\n' >"$log_dir/shell.log"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_RUNTIME_CONF="$runtime_conf" \
    ENGINEOS_APPS_MANIFEST="$apps_manifest" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
    ENGINEOS_FAKE_DOCTOR_ARGS="$doctor_log" \
    "$PROOF_DIR/validate_boot.sh" --runtime >"$out" 2>&1
  grep -F 'runtime shell service active: engineos-runtime.service' "$out" >/dev/null ||
    die "runtime boot validation did not accept active runtime shell service"
  if grep -F 'runtime autostart appears to still be running' "$out" >/dev/null; then
    die "runtime boot validation warned for active runtime shell service"
  fi
  grep -F 'shell renderer log shows software rendering; acceptable only for VM smoke paths' "$out" >/dev/null ||
    die "runtime boot validation did not keep pixman shell evidence as a VM warning"

  : >"$doctor_log"
  printf '[2026-01-01T00:00:00Z] renderer diagnostics backend=drm,libinput wlr_renderer=gles2 EGL platform=gbm\n' >"$log_dir/shell.log"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_RUNTIME_CONF="$runtime_conf" \
    ENGINEOS_APPS_MANIFEST="$apps_manifest" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_DRI_DIR="$dri_dir" \
    ENGINEOS_DRM_SYSFS="$drm_sysfs" \
    ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
    ENGINEOS_FAKE_DOCTOR_ARGS="$doctor_log" \
    "$PROOF_DIR/validate_boot.sh" --bare-metal >"$out"
  grep -F "$dri_dir exists" "$out" >/dev/null ||
    die "bare-metal boot validation did not use DRI fixture"
  grep -F 'at least one connected DRM output' "$out" >/dev/null ||
    die "bare-metal boot validation did not validate connected DRM output"
  grep -F 'AMD display device visible to lspci' "$out" >/dev/null ||
    die "bare-metal boot validation did not verify AMD display fixture"
  grep -F 'shell renderer log exists' "$out" >/dev/null ||
    die "bare-metal boot validation did not check shell renderer log"
  grep -F 'bare-metal shell renderer has GL-capable evidence' "$out" >/dev/null ||
    die "bare-metal boot validation did not require GL-capable shell evidence"
  grep -Fx -- '--bare-metal' "$doctor_log" >/dev/null ||
    die "bare-metal boot validation did not call doctor in bare-metal mode"
  grep -F 'bare-metal doctor completed' "$out" >/dev/null ||
    die "bare-metal boot validation did not require doctor success"

  if PATH="$fake_bin:$PATH" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_DRI_DIR="$dri_dir" \
      ENGINEOS_DRM_SYSFS="$drm_sysfs" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-fail" \
      ENGINEOS_VALIDATE_DOCTOR_OUT="$tmp_dir/doctor-fail.out" \
      "$PROOF_DIR/validate_boot.sh" --bare-metal >"$out" 2>&1; then
    die "bare-metal boot validation accepted failing doctor"
  fi
  grep -F 'bare-metal doctor failed' "$out" >/dev/null ||
    die "bare-metal boot validation did not expose failing doctor"

  printf '[2026-01-01T00:00:00Z] renderer diagnostics backend=drm,libinput wlr_renderer=pixman\n' >"$log_dir/shell.log"
  if PATH="$fake_bin:$PATH" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_APPS_MANIFEST="$apps_manifest" \
      ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_DRI_DIR="$dri_dir" \
      ENGINEOS_DRM_SYSFS="$drm_sysfs" \
      ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
      ENGINEOS_FAKE_DOCTOR_ARGS="$doctor_log" \
      "$PROOF_DIR/validate_boot.sh" --bare-metal >"$out" 2>&1; then
    die "bare-metal boot validation accepted pixman shell renderer evidence"
  fi
  grep -F 'shell renderer log shows software rendering' "$out" >/dev/null ||
    die "bare-metal boot validation did not reject pixman shell renderer evidence"

  printf 'boot validation fixture test passed\n'
}

run_engine() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-engine-test-$$"
  local fetch_out="$tmp_dir/fetch.txt"

  cleanup_engine() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_engine RETURN

  mkdir -p "$tmp_dir"
  QUAKESPASM_UPSTREAM_DIR="$tmp_dir/upstream" \
    "$ROOT/tools/engineos/eos-build" fetch engine quake --dry-run >"$fetch_out"
  grep -F 'QuakeSpasm fetch dry-run' "$fetch_out" >/dev/null ||
    die "engine fetch dry-run missing marker"
  grep -F 'fetch.sh --status' "$fetch_out" >/dev/null ||
    die "engine fetch dry-run did not point to status"

  QUAKESPASM_UPSTREAM_DIR="$tmp_dir/upstream" \
    "$ROOT/tools/engineos/eos-build" fetch engine quake --status >"$fetch_out"
  grep -F 'state:    missing' "$fetch_out" >/dev/null ||
    die "engine fetch status did not report missing checkout"
  mkdir -p "$tmp_dir/upstream"
  QUAKESPASM_UPSTREAM_DIR="$tmp_dir/upstream" \
    "$ROOT/tools/engineos/eos-build" fetch engine quake --status >"$fetch_out"
  grep -F 'state:    empty-directory' "$fetch_out" >/dev/null ||
    die "engine fetch status did not report empty checkout directory"

  "$SCRIPT_DIR/build_engine.sh" quake --dry-run >"$fetch_out"
  grep -F 'MP3LIB=mpg123' "$fetch_out" >/dev/null ||
    die "engine build dry-run did not select mpg123"
  grep -F 'VORBISLIB=vorbis' "$fetch_out" >/dev/null ||
    die "engine build dry-run did not select vorbis"

  if QUAKESPASM_UPSTREAM_DIR="$tmp_dir/upstream" \
      "$SCRIPT_DIR/validate_engine.sh" quake >"$fetch_out" 2>&1; then
    die "engine validation accepted missing QuakeSpasm upstream checkout"
  fi
  grep -F 'upstream directory exists but is not a git checkout' "$fetch_out" >/dev/null ||
    die "engine validation did not fail missing upstream checkout explicitly"

  "$SCRIPT_DIR/validate_engine.sh" quake >/dev/null
  printf 'engine validation smoke test passed\n'
}

run_shell() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-shell-test-$$"
  local fake_bin="$tmp_dir/bin"
  local out="$tmp_dir/out.txt"

  cleanup_shell() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_shell RETURN
  mkdir -p "$fake_bin"

  cat >"$fake_bin/pkg-config" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
  chmod +x "$fake_bin/pkg-config"
  if PATH="$fake_bin:$PATH" "$SCRIPT_DIR/validate_shell.sh" >"$out" 2>&1; then
    die "shell validation accepted missing wlroots pkg-config modules"
  fi
  grep -F 'wlroots pkg-config modules unavailable' "$out" >/dev/null ||
    die "shell validation did not fail missing wlroots modules explicitly"

  "$SCRIPT_DIR/validate_shell.sh" >/dev/null
  ENGINEOS_ROOT=/usr "$SCRIPT_DIR/validate_shell.sh" >/dev/null
  printf 'shell validation smoke test passed\n'
}

run_input() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-input-test-$$"
  local trace="$tmp_dir/input.json"
  local old_trace="$tmp_dir/old-input.json"

  cleanup_input() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_input RETURN

  mkdir -p "$tmp_dir"
  "$SCRIPT_DIR/input_trace.sh" record "$trace" >/dev/null
  "$SCRIPT_DIR/input_trace.sh" replay "$trace" >/dev/null

  grep -F '"type": "pointer", "event": "motion"' "$trace" >/dev/null ||
    die "input trace test missing pointer motion event"
  grep -F '"type": "pointer", "event": "button"' "$trace" >/dev/null ||
    die "input trace test missing pointer button event"
  grep -F '"type": "pointer", "event": "axis"' "$trace" >/dev/null ||
    die "input trace test missing pointer axis event"
  grep -F '"type": "pointer", "event": "frame"' "$trace" >/dev/null ||
    die "input trace test missing pointer frame event"
  grep -F '"capture": true' "$trace" >/dev/null ||
    die "input trace test missing captured pointer context"
  grep -F '"focus": "game"' "$trace" >/dev/null ||
    die "input trace test missing game focus pointer context"

  cat >"$old_trace" <<'JSON'
{
  "format": "engineos-input-trace-v0",
  "events": [
    {"type": "focus", "mode": "shell"},
    {"type": "focus", "mode": "terminal"},
    {"type": "focus", "mode": "game"},
    {"type": "capture", "mode": "game", "enabled": true},
    {"type": "capture", "mode": "game", "enabled": false},
    {"type": "emergency-release"}
  ]
}
JSON
  if "$SCRIPT_DIR/input_trace.sh" replay "$old_trace" >/dev/null 2>&1; then
    die "input replay accepted a trace without pointer events"
  fi

  printf 'input smoke test passed\n'
}

run_outputs() {
  local mode="${1:---single}"
  local tmp_dir="${TMPDIR:-/tmp}/engineos-outputs-test-$$"
  local sysfs="$tmp_dir/sys/class/drm"
  local out="$tmp_dir/outputs.txt"

  cleanup_outputs() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_outputs RETURN

  mkdir -p "$sysfs/card0-HDMI-A-1" "$sysfs/card0-DP-1" "$sysfs/card0-DP-2"
  printf 'connected\n' >"$sysfs/card0-HDMI-A-1/status"
  printf 'enabled\n' >"$sysfs/card0-HDMI-A-1/enabled"
  printf '1920x1080\n1280x720\n' >"$sysfs/card0-HDMI-A-1/modes"
  printf 'connected\n' >"$sysfs/card0-DP-1/status"
  printf 'enabled\n' >"$sysfs/card0-DP-1/enabled"
  printf '2560x1440\n1920x1080\n' >"$sysfs/card0-DP-1/modes"
  printf 'disconnected\n' >"$sysfs/card0-DP-2/status"
  printf 'disabled\n' >"$sysfs/card0-DP-2/enabled"
  : >"$sysfs/card0-DP-2/modes"

  case "$mode" in
    --single)
      "$SCRIPT_DIR/outputs.sh" validate --single --sysfs "$sysfs" >"$out"
      grep -F 'connector: card0-HDMI-A-1 status=connected' "$out" >/dev/null ||
        die "outputs single test did not list connected HDMI"
      grep -F 'connector: card0-DP-2 status=disconnected enabled=disabled preferred_mode=none' "$out" >/dev/null ||
        die "outputs single test did not report empty mode files as none"
      grep -F 'Output validation passed for --single' "$out" >/dev/null ||
        die "outputs single test did not validate"
      ;;
    --dual-static)
      "$SCRIPT_DIR/outputs.sh" validate --dual-static --sysfs "$sysfs" >"$out"
      grep -F 'connector: card0-DP-1 status=connected' "$out" >/dev/null ||
        die "outputs dual test did not list connected DP"
      grep -F 'Output validation passed for --dual-static' "$out" >/dev/null ||
        die "outputs dual test did not validate"
      ;;
    *)
      die "outputs test expects --single or --dual-static"
      ;;
  esac

  printf 'outputs smoke %s passed\n' "$mode"
}

run_render() {
  local mode="${1:---smoke}"
  local tmp_dir="${TMPDIR:-/tmp}/engineos-render-test-$$"
  local captured=""
  local fallback=""
  local failed_capture=""
  [[ "$mode" == "--smoke" ]] || die "render test currently supports only --smoke"

  cleanup_render() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_render RETURN

  mkdir -p "$tmp_dir/bin" "$tmp_dir/captures"
  cat >"$tmp_dir/bin/grim" <<'FAKE'
#!/usr/bin/env bash
printf 'fake png payload\n' >"$1"
FAKE
  chmod +x "$tmp_dir/bin/grim"

  captured="$(PATH="$tmp_dir/bin:$PATH" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    ENGINEOS_CAPTURE_DIR="$tmp_dir/captures" \
    "$SCRIPT_DIR/capture_frame.sh" --target shell)"

  [[ -f "$captured" ]] || die "render capture did not create image artifact"
  [[ "$captured" == *.png ]] || die "render capture did not return a png artifact"
  grep -F 'result=image' "${captured%.png}.txt" >/dev/null ||
    die "render capture metadata did not record image result"
  grep -F 'tool=grim' "${captured%.png}.txt" >/dev/null ||
    die "render capture metadata did not record grim tool"

  fallback="$(ENGINEOS_CAPTURE_DIR="$tmp_dir/captures" \
    ENGINEOS_CAPTURE_TOOL=metadata \
    "$SCRIPT_DIR/capture_frame.sh" --target shell)"
  [[ -f "$fallback" ]] || die "render fallback did not create metadata artifact"
  grep -F 'result=metadata' "$fallback" >/dev/null ||
    die "render fallback metadata did not record metadata result"

  cat >"$tmp_dir/bin/grim" <<'FAKE'
#!/usr/bin/env bash
exit 12
FAKE
  chmod +x "$tmp_dir/bin/grim"
  if PATH="$tmp_dir/bin:$PATH" \
      WAYLAND_DISPLAY="engineos-test-wayland" \
      ENGINEOS_CAPTURE_DIR="$tmp_dir/captures" \
      "$SCRIPT_DIR/capture_frame.sh" --target shell >"$tmp_dir/failed-capture.out" 2>&1; then
    die "render capture auto mode succeeded when grim failed"
  fi
  failed_capture="$(sed -n 's/^frame capture failed; metadata: //p' "$tmp_dir/failed-capture.out" | tail -n 1)"
  [[ -f "$failed_capture" ]] || die "render capture failure did not create metadata artifact"
  grep -F 'result=failed' "$failed_capture" >/dev/null ||
    die "render capture failure metadata did not record failed result"

  printf 'render smoke test passed\n'
}

case "$SCOPE" in
  smoke)
    run_smoke
    ;;
  all)
    run_all
    ;;
  agent)
    run_agent
    ;;
  agent-hygiene)
    run_agent_hygiene
    ;;
  observability)
    run_observability
    ;;
	agent-route)
		run_agent_route
		;;
	dev-workflow)
		run_dev_workflow
		;;
  compositor)
    run_compositor "$@"
    ;;
  shell-actions)
    run_shell_actions
    ;;
	mux)
		run_mux
		;;
	game-workflow)
		run_game_workflow
    ;;
  image-preview)
    run_image_preview
    ;;
  app)
    run_app
    ;;
  level-agent)
    run_level_agent
    ;;
  assets)
    run_assets
    ;;
  reliability)
    run_reliability
    ;;
  logs)
    run_logs
    ;;
  artifacts)
    run_artifacts
    ;;
  release)
    run_release
    ;;
  terminal)
    run_terminal
    ;;
  vm)
    run_vm
    ;;
  usb)
    run_usb
    ;;
  secure-boot)
    run_secure_boot
    ;;
  update-check)
    run_update_check
    ;;
  installation-guide)
    run_installation_guide
    ;;
  install)
    run_install
    ;;
  restore-point)
    run_restore_point
    ;;
  proof)
    run_proof
    ;;
  installed-preflight)
    run_installed_preflight
    ;;
  ci)
    run_ci
    ;;
  source-test)
    run_source_test
    ;;
  source-env)
    run_source_env
    ;;
  builder-handoff)
    run_builder_handoff
    ;;
  builder-doctor)
    run_builder_doctor
    ;;
  post-first-deploy)
    run_post_first_deploy
    ;;
  builder)
    run_builder
    ;;
  bootstrap)
    run_bootstrap
    ;;
  repo)
    run_repo
    ;;
  boot)
    run_boot
    ;;
  engine)
    run_engine
    ;;
  shell)
    run_shell
    ;;
  input)
    run_input
    ;;
  outputs)
    run_outputs "$@"
    ;;
  render)
    run_render "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown test scope: $SCOPE"
    ;;
esac
