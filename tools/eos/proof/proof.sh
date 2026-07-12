#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -n "${ENGINEOS_SCRIPT_DIR:-}" ]]; then
  SCRIPT_DIR="$ENGINEOS_SCRIPT_DIR"
else
  SCRIPT_DIR="$(cd "$MODULE_DIR/../../scripts" && pwd -P)"
fi
BARE_METAL_DIR="$(cd "$MODULE_DIR/../bare-metal" && pwd -P)"
TEST_DIR="$(cd "$MODULE_DIR/../test" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
ACTION="${1:-help}"
shift || true

usage() {
  cat <<'HELP'
Usage: proof.sh build-lab [--dry-run] [--profile enginedev]
       proof.sh release-candidate [--dry-run] [--out-dir <dir>] [--export-dir <dir>]
       proof.sh hardware-ready [--dry-run] [--profile enginedev|engineruntime] [--out-dir <dir>] [--device <block-device>]
       proof.sh booted-iso [--vm|--runtime|--bare-metal] [--dry-run]
       proof.sh shell-launch [--vm|--runtime|--bare-metal] [--dry-run]
       proof.sh native-kms
       proof.sh native-falkon
       proof.sh native-quake
       proof.sh visual [--dry-run] [--allow-metadata]
       proof.sh mc-preview [--dry-run] [--visual]

Run focused proof sequences for EngineOS milestones.

The build-lab proof is the builder-side half of PoC 0. Real builds must run on
the Arch builder VM from the repository on a Linux filesystem.

The release-candidate proof is the builder-side artifact path for the MVP: build
the local package repo, build EngineDev and EngineRuntime ISOs, then write the
release checklist.

The hardware-ready proof is the non-destructive handoff path for bare-metal
testing: confirm local structure, list USB candidates, print or run the USB
write dry-run, then name the in-guest bare-metal proof.

The booted-iso proof runs inside a generated ISO after it boots.
The shell-launch proof verifies that engineos-shell is the graphical launch
point for terminal/tmux and OpenGL app clients.
The native-kms proof temporarily runs the live tty1 shell against an isolated
two-pane native mux session, proves real DRM/GBM/radeonsi output commits through
split, resize, and zoom, then restores the prior shell mode.
The native-falkon proof temporarily runs the live tty1 shell against an isolated
native mux pane, launches a dedicated Falkon instance through eos-app, proves
scope ownership and console toggling, closes it, proves prompt restoration, and
then restores the prior shell mode.
The native-quake proof does the same with real user-provided Quake assets and
also proves radeonsi rendering, live audio, game capture, the native prefix
toggle, a real uinput emergency-release chord, and console recovery.
The visual proof requires a real frame image by default; metadata-only capture
is diagnostic unless --allow-metadata is explicitly passed.
The mc-preview proof runs the Quick View/image-preview acceptance path and can
optionally include a visual frame capture.
HELP
}

NATIVE_LIVE_CLEANED=true
NATIVE_LIVE_MANAGER_CHANGED=false
NATIVE_LIVE_SHELL_SWITCHED=false
NATIVE_LIVE_FIXTURE=""
NATIVE_LIVE_RUNTIME=""
NATIVE_LIVE_MUX_BIN=""
NATIVE_LIVE_OLD_SOCKET=""
NATIVE_LIVE_RUNTIME_CMD=""
NATIVE_LIVE_SYSTEMCTL=()

native_live_begin() {
  NATIVE_LIVE_CLEANED=false
  NATIVE_LIVE_MANAGER_CHANGED=false
  NATIVE_LIVE_SHELL_SWITCHED=false
  NATIVE_LIVE_FIXTURE="$1"
  NATIVE_LIVE_RUNTIME="$2"
  NATIVE_LIVE_MUX_BIN="$3"
  NATIVE_LIVE_RUNTIME_CMD="$4"
  if [[ "$(id -u)" -eq 0 ]]; then
    NATIVE_LIVE_SYSTEMCTL=(systemctl)
  else
    NATIVE_LIVE_SYSTEMCTL=(sudo -n systemctl)
  fi
  NATIVE_LIVE_OLD_SOCKET="$(systemctl show-environment |
    sed -n '/^ENGINEOS_MUX_SOCKET=/{p;q;}')"
  trap native_live_cleanup EXIT
  trap 'exit 130' INT TERM
}

native_live_restore_environment() {
  local assignment
  for assignment in "$NATIVE_LIVE_OLD_SOCKET"; do
    if [[ -n "$assignment" ]]; then
      "${NATIVE_LIVE_SYSTEMCTL[@]}" set-environment "$assignment"
    fi
  done
  [[ -n "$NATIVE_LIVE_OLD_SOCKET" ]] ||
    "${NATIVE_LIVE_SYSTEMCTL[@]}" unset-environment ENGINEOS_MUX_SOCKET
}

native_live_restart_shell() {
  "${NATIVE_LIVE_SYSTEMCTL[@]}" reset-failed engineos-dev-shell.service
  "$NATIVE_LIVE_RUNTIME_CMD" shell restart-live --timeout 20
}

native_live_cleanup() {
  local incoming_rc=$?
  local cleanup_rc=0
  [[ "$NATIVE_LIVE_CLEANED" == false ]] || return "$incoming_rc"
  NATIVE_LIVE_CLEANED=true
  set +e
  if [[ "$NATIVE_LIVE_MANAGER_CHANGED" == true ]]; then
    native_live_restore_environment || cleanup_rc=$?
  fi
  if [[ "$NATIVE_LIVE_SHELL_SWITCHED" == true ]]; then
    native_live_restart_shell || cleanup_rc=$?
  fi
  if [[ -n "$NATIVE_LIVE_MUX_BIN" && -n "$NATIVE_LIVE_RUNTIME" ]]; then
    XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
      "$NATIVE_LIVE_MUX_BIN" kill-server >/dev/null 2>&1 || true
  fi
  [[ -z "$NATIVE_LIVE_FIXTURE" ]] || rm -rf "$NATIVE_LIVE_FIXTURE"
  set -e
  if (( incoming_rc != 0 )); then
    return "$incoming_rc"
  fi
  return "$cleanup_rc"
}

wait_for_native_state() {
  local state_file="$1"
  local filter="$2"
  local description="$3"
  local attempts="${4:-200}"
  if (( $# >= 4 )); then
    shift 4
  else
    shift 3
  fi
  local jq_args=("$@")
  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if jq -e "${jq_args[@]}" "$filter" "$state_file" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done
  jq "${jq_args[@]}" "$filter" "$state_file" >/dev/null 2>&1 || true
  die "native shell state did not reach $description"
}

emit_emergency_release_chord() {
  local python_bin="$(command -v python || command -v python3 || true)"
  local command=("$python_bin")
  [[ -n "$python_bin" ]] || die "native game proof requires Python"
  [[ -c /dev/uinput ]] || die "native game proof requires /dev/uinput"
  if [[ "$(id -u)" -ne 0 ]]; then
    command=(sudo -n "$python_bin")
  fi
  "${command[@]}" - <<'PY'
import fcntl
import os
import struct
import time

IOC_NRBITS = 8
IOC_TYPEBITS = 8
IOC_SIZEBITS = 14
IOC_NRSHIFT = 0
IOC_TYPESHIFT = IOC_NRSHIFT + IOC_NRBITS
IOC_SIZESHIFT = IOC_TYPESHIFT + IOC_TYPEBITS
IOC_DIRSHIFT = IOC_SIZESHIFT + IOC_SIZEBITS
IOC_WRITE = 1

def ioc(direction: int, kind: int, number: int, size: int) -> int:
    return ((direction << IOC_DIRSHIFT) | (kind << IOC_TYPESHIFT) |
            (number << IOC_NRSHIFT) | (size << IOC_SIZESHIFT))

kind = ord("U")
ui_set_evbit = ioc(IOC_WRITE, kind, 100, 4)
ui_set_keybit = ioc(IOC_WRITE, kind, 101, 4)
ui_dev_setup = ioc(IOC_WRITE, kind, 3, 92)
ui_dev_create = ioc(0, kind, 1, 0)
ui_dev_destroy = ioc(0, kind, 2, 0)
ev_syn = 0
ev_key = 1
syn_report = 0
key_backspace = 14
key_leftctrl = 29
key_leftalt = 56

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
try:
    fcntl.ioctl(fd, ui_set_evbit, ev_key)
    for key in (key_backspace, key_leftctrl, key_leftalt):
        fcntl.ioctl(fd, ui_set_keybit, key)
    name = b"EngineOS emergency release proof"
    setup = struct.pack("HHHH80sI", 3, 0x1E05, 0x0001, 1,
                        name.ljust(80, b"\0"), 0)
    fcntl.ioctl(fd, ui_dev_setup, setup)
    fcntl.ioctl(fd, ui_dev_create)
    time.sleep(1.5)

    def event(event_type: int, code: int, value: int) -> None:
        os.write(fd, struct.pack("llHHi", 0, 0, event_type, code, value))

    for key in (key_leftctrl, key_leftalt, key_backspace):
        event(ev_key, key, 1)
    event(ev_syn, syn_report, 0)
    for key in (key_backspace, key_leftalt, key_leftctrl):
        event(ev_key, key, 0)
    event(ev_syn, syn_report, 0)
    time.sleep(0.5)
finally:
    try:
        fcntl.ioctl(fd, ui_dev_destroy)
    finally:
        os.close(fd)
PY
}

validate_native_kms_split_state() {
  local state_file="$1"
  jq -e '
    .mode == "tty" and .backend == "drm,libinput" and
    .mux.mode == "native" and .mux.connected == true and
    (.mux.panes | length) == 2 and
    ([.mux.panes[] | select(.visible)] | length) == 2 and
    ([.output_views[] | select(
      .frame_commits > 0 and .frame_failures == 0 and
      .rendered_pane_count == 2 and
      .selected_renderer == "gpu-fcft-atlas-gles2" and
      (.panes | length) == 2 and
      ([.panes[] | select(
        .visible and .terminal_visible and .within_output and
        .frame > 0 and .nonblank_pixels > 0 and
        .renderer == "gpu-fcft-atlas-gles2"
      )] | length) == 2 and
		(. as $view | (.panes | sort_by(.pixel_x)) as $p |
		  $p[0].pixel_x == 0 and
		  ($p[0].pixel_x + $p[0].pixel_width) <= $p[1].pixel_x and
		  ($p[-1].pixel_x + $p[-1].pixel_width) >=
		    ($view.pixel_width * 9 / 10) and
		  ([.panes[] | .pixel_y + .pixel_height] | max) >=
		    ($view.pixel_height * 4 / 5))
    )] | length) == (.output_views | length) and
    (.output_views | length) > 0
  ' "$state_file" >/dev/null ||
    die "native KMS split state lacks committed, clipped radeonsi pane frames"
}

proof_native_kms() {
  [[ $# -eq 0 ]] || die "native-kms proof takes no options"
  have_cmd jq || die "native-kms proof requires jq"
  have_cmd systemctl || die "native-kms proof requires systemctl"
  have_cmd timeout || die "native-kms proof requires timeout"
  have_cmd sudo || [[ "$(id -u)" -eq 0 ]] ||
    die "native-kms proof requires sudo or root"

  local runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local state_file="$runtime_dir/engineos/shell-state.json"
  local shell_log="${ENGINEOS_SHELL_LOG:-${ENGINEOS_LOG_DIR:-$(default_log_dir)}/dev-shell-start.log}"
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local stamp="$(timestamp_utc)"
  local artifact_dir="$log_dir/proof-native-kms-$stamp"
  local fixture="${TMPDIR:-/tmp}/engineos-native-kms-proof-$$"
  local mux_bin="${ENGINEOS_TMUX_BIN:-$(command -v tmux || true)}"
  local runtime_cmd="$(eos_command eos-runtime)"
  local log_start=0
  local initial_mode=""
  local initial_columns initial_frames resized_frames

  [[ -x "$mux_bin" ]] || die "native-kms proof requires installed tmux"
  [[ -r "$state_file" ]] || die "live shell state missing: $state_file"
  [[ -r "$shell_log" ]] || die "live shell log missing: $shell_log"
  [[ -c /dev/tty1 ]] || die "native-kms proof requires tty1"
  compgen -G '/dev/dri/card*' >/dev/null ||
    die "native-kms proof requires a DRM card"
  systemctl is-active --quiet engineos-dev-shell.service ||
    die "engineos-dev-shell.service is not active"
  jq -e '.mode == "tty"' "$state_file" >/dev/null ||
    die "live shell is not currently attached to tty/DRM"

  mkdir -p "$artifact_dir" "$fixture/runtime"
  chmod 0700 "$fixture" "$fixture/runtime"
  initial_mode="$(jq -r '.mux.mode' "$state_file")"
  cp "$state_file" "$artifact_dir/before.json"
  log_start="$(wc -l <"$shell_log")"

  native_live_begin "$fixture" "$fixture/runtime" "$mux_bin" "$runtime_cmd"

  printf 'EngineOS native KMS proof\n'
  printf '  state:    %s\n' "$state_file"
  printf '  log:      %s\n' "$shell_log"
  printf '  artifacts:%s\n' "$artifact_dir"
  printf '  restore:  %s\n' "$initial_mode"

  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" new-session -d -s engineos-kms-proof -x 120 -y 36 \
      'printf "LEFT-KMS-PROOF\\n"; exec sh'
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" split-window -h -t '=engineos-kms-proof:' \
      'printf "RIGHT-KMS-PROOF\\n"; exec sh'
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" select-layout -t '=engineos-kms-proof:' even-horizontal
  local mux_socket="$NATIVE_LIVE_RUNTIME/engineos/mux.sock"
  [[ -S "$mux_socket" ]] || die "isolated native mux frontend socket missing"

  "${NATIVE_LIVE_SYSTEMCTL[@]}" set-environment \
    ENGINEOS_MUX_SOCKET="$mux_socket"
  NATIVE_LIVE_MANAGER_CHANGED=true
  NATIVE_LIVE_SHELL_SWITCHED=true
  native_live_restart_shell

  wait_for_native_state "$state_file" '
    .mode == "tty" and .backend == "drm,libinput" and
    .mux.mode == "native" and .mux.connected == true and
    (.mux.panes | length) == 2 and
    (.output_views | length) > 0 and
    ([.output_views[] | select(.frame_commits > 0)] | length) ==
      (.output_views | length)
  ' "initial direct-KMS split frames"
  validate_native_kms_split_state "$state_file"
  cp "$state_file" "$artifact_dir/split.json"
  initial_columns="$(jq '.mux.panes[0].columns' "$state_file")"
  initial_frames="$(jq '[.output_views[].panes[].frame] | add' "$state_file")"

  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" resize-pane -t '%0' -R 8
  timeout 10 env XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" \
    TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" send-keys -t '%0' 'printf "LEFT-RESIZED-KMS\\n"' Enter
  timeout 10 env XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" \
    TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" send-keys -t '%1' 'printf "RIGHT-RESIZED-KMS\\n"' Enter
  wait_for_native_state "$state_file" ".mux.panes[0].columns != $initial_columns and
    ([.output_views[].panes[].frame] | add) > $initial_frames" \
    "resized nonblank pane frames"
  validate_native_kms_split_state "$state_file"
  cp "$state_file" "$artifact_dir/resized.json"
  resized_frames="$(jq '[.output_views[].panes[].frame] | add' "$state_file")"

  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" resize-pane -Z -t '%1'
  wait_for_native_state "$state_file" '
    ([.mux.panes[] | select(.visible)] | length) == 1 and
    ([.output_views[] | select(
      ([.panes[] | select(.visible)] | length) == 1 and
      ([.panes[] | select(.visible and .terminal_visible and .within_output and
        .renderer == "gpu-fcft-atlas-gles2" and .frame > 0)] | length) == 1
      and ([.panes[] | select((.visible | not) and
        (.terminal_visible | not))] | length) == 1
    )] | length) == (.output_views | length)
  ' "zoomed single-pane clipping"
  cp "$state_file" "$artifact_dir/zoomed.json"

  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" resize-pane -Z -t '%1'
  wait_for_native_state "$state_file" "
    ([.mux.panes[] | select(.visible)] | length) == 2 and
    ([.output_views[].panes[].frame] | add) > $resized_frames
  " "unzoomed split clipping"
  validate_native_kms_split_state "$state_file"
  cp "$state_file" "$artifact_dir/unzoomed.json"

  sed -n "$((log_start + 1)),\$p" "$shell_log" >"$artifact_dir/kms.log"
  grep -F 'renderer diagnostics backend=drm,libinput' \
    "$artifact_dir/kms.log" >/dev/null ||
    die "native KMS log lacks DRM/libinput backend evidence"
  grep -E 'GL renderer: AMD .*radeonsi' "$artifact_dir/kms.log" >/dev/null ||
    die "native KMS log lacks AMD/radeonsi renderer evidence"
  grep -F 'Created GBM allocator with backend drm' \
    "$artifact_dir/kms.log" >/dev/null ||
    die "native KMS log lacks DRM GBM allocator evidence"
  grep -F 'Modesetting with ' "$artifact_dir/kms.log" >/dev/null ||
    die "native KMS log lacks a real connector modeset"
  if grep -F 'failed to commit scene output' "$artifact_dir/kms.log" >/dev/null; then
    die "native KMS scene output commit failed"
  fi

  native_live_cleanup
  trap - EXIT INT TERM
  wait_for_native_state "$state_file" ".mux.mode == \"$initial_mode\"" \
    "restored $initial_mode shell mode"
  cp "$state_file" "$artifact_dir/restored.json"
  printf 'Native KMS clipping proof passed.\n'
  printf 'Proof artifacts: %s\n' "$artifact_dir"
}

proof_native_falkon() {
  [[ $# -eq 0 ]] || die "native-falkon proof takes no options"
  have_cmd jq || die "native-falkon proof requires jq"
  have_cmd systemctl || die "native-falkon proof requires systemctl"
  have_cmd falkon || die "native-falkon proof requires Falkon"
  have_cmd sudo || [[ "$(id -u)" -eq 0 ]] ||
    die "native-falkon proof requires sudo or root"

  local runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local state_dir="$runtime_dir/engineos"
  local state_file="$state_dir/shell-state.json"
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local stamp="$(timestamp_utc)"
  local artifact_dir="$log_dir/proof-native-falkon-$stamp"
  local fixture="${TMPDIR:-/tmp}/engineos-native-falkon-proof-$$"
  local mux_bin="${ENGINEOS_TMUX_BIN:-$(command -v tmux || true)}"
  local muxctl_bin="${ENGINEOS_MUXCTL_BIN:-$(command -v engine-muxctl || true)}"
  local app_cmd="$(eos_command eos-app)"
  local runtime_cmd="$(eos_command eos-runtime)"
  local initial_mode="" pane_id="" pane_shell_pid=""
  local pane_state="" pane_scope="" pane_app_pid="" pane_launch_command=""
  local foreground_pgrp="" app_pgrp="" shell_command=""

  [[ -x "$mux_bin" ]] || die "native-falkon proof requires installed tmux"
  [[ -x "$muxctl_bin" ]] ||
    die "native-falkon proof requires installed engine-muxctl"
  app_cmd="$(command -v "$app_cmd" || true)"
  [[ -x "$app_cmd" ]] || die "native-falkon proof requires eos-app"
  [[ -r "$state_file" ]] || die "live shell state missing: $state_file"
  [[ -c /dev/tty1 ]] || die "native-falkon proof requires tty1"
  systemctl is-active --quiet engineos-dev-shell.service ||
    die "engineos-dev-shell.service is not active"
  jq -e '.mode == "tty"' "$state_file" >/dev/null ||
    die "live shell is not currently attached to tty/DRM"

  mkdir -p "$artifact_dir" "$fixture/runtime" "$fixture/home" \
    "$fixture/config" "$fixture/cache" "$fixture/data"
  chmod 0700 "$fixture" "$fixture/runtime" "$fixture/home" \
    "$fixture/config" "$fixture/cache" "$fixture/data"
  initial_mode="$(jq -r '.mux.mode' "$state_file")"
  cp "$state_file" "$artifact_dir/before.json"
  native_live_begin "$fixture" "$fixture/runtime" "$mux_bin" "$runtime_cmd"

  printf 'EngineOS native Falkon proof\n'
  printf '  state:     %s\n' "$state_file"
  printf '  artifacts: %s\n' "$artifact_dir"
  printf '  restore:   %s\n' "$initial_mode"

  printf -v shell_command \
    'export XDG_RUNTIME_DIR=%q WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland HOME=%q XDG_CONFIG_HOME=%q XDG_CACHE_HOME=%q XDG_DATA_HOME=%q; printf "FALKON-SHELL-BEFORE\\n"; exec /bin/sh' \
    "$runtime_dir" "$fixture/home" "$fixture/config" "$fixture/cache" \
    "$fixture/data"
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    ENGINEOS_USER_RUNTIME_DIR="$runtime_dir" \
    "$mux_bin" new-session -d -s engineos-falkon-proof -x 120 -y 36 \
      "$shell_command"
  pane_id="$(XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" \
    TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" "$mux_bin" display-message -p \
      -t '=engineos-falkon-proof:' '#{pane_id}')"
  pane_shell_pid="$(XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" \
    TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" "$mux_bin" display-message -p \
      -t "$pane_id" '#{pane_pid}')"
  [[ "$pane_id" == %* && "$pane_shell_pid" =~ ^[1-9][0-9]*$ ]] ||
    die "isolated Falkon pane did not expose stable pane and shell IDs"
  local mux_socket="$NATIVE_LIVE_RUNTIME/engineos/mux.sock"
  [[ -S "$mux_socket" ]] || die "isolated native mux frontend socket missing"

  "${NATIVE_LIVE_SYSTEMCTL[@]}" set-environment \
    ENGINEOS_MUX_SOCKET="$mux_socket"
  NATIVE_LIVE_MANAGER_CHANGED=true
  NATIVE_LIVE_SHELL_SWITCHED=true
  native_live_restart_shell
  wait_for_native_state "$state_file" '
    .mode == "tty" and .backend == "drm,libinput" and
    .wayland_display == "wayland-0" and
    .mux.mode == "native" and .mux.connected == true and
    .mux.pane_id == $pane and .mux.presentation.type == "terminal" and
    .mux.presentation.terminal_visible == true and
    (.output_views | length) > 0
  ' "isolated terminal pane on direct KMS" 200 --arg pane "$pane_id"
  cp "$state_file" "$artifact_dir/terminal.json"

  printf -v pane_launch_command \
    'ENGINEOS_STATE_DIR=%q ENGINEOS_LOG_DIR=%q ENGINEOS_TMUX_BIN=%q %q pane launch -- falkon --profile engineos-proof about:blank' \
    "$state_dir" "$artifact_dir" "$mux_bin" "$app_cmd"
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" send-keys -t "$pane_id" -l "$pane_launch_command"
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" send-keys -t "$pane_id" Enter

  wait_for_native_state "$state_file" '
    .mux.pane_id == $pane and
    .mux.presentation.type == "wayland" and
    .mux.presentation.view_mode == "presentation" and
    .mux.presentation.mapped == true and
    .mux.presentation.surface_tabs >= 1 and
    .mux.presentation.terminal_visible == false and
    .mux.presentation.lease_owned_by_focused_view == true and
    .input.mode == "graphical" and
    any(.windows[]; .bound == true and .pane_id == $pane and
      (.app_id == "org.kde.falkon" or .app_id == "falkon") and
      .client_pid > 0 and .presentation_visible == true)
  ' "scoped Falkon presentation" 400 --arg pane "$pane_id"
  cp "$state_file" "$artifact_dir/presentation.json"
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" "$muxctl_bin" snapshot \
    >"$artifact_dir/mux-presentation.json"
  pane_state="$(XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" \
    TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" "$mux_bin" display-message -p \
      -t "$pane_id" \
      '#{pane_presentation}|#{pane_view_mode}|#{pane_presentation_scope}|#{pane_app_pid}')"
  printf '%s\n' "$pane_state" >"$artifact_dir/pane-state.txt"
  IFS='|' read -r _ _ pane_scope pane_app_pid <<<"$pane_state"
  [[ "$pane_scope" == engine-pane-*.scope ]] ||
    die "Falkon launch lacks a dedicated transient scope"
  [[ "$pane_app_pid" =~ ^[1-9][0-9]*$ ]] ||
    die "Falkon launch lacks an authoritative application PID"
  jq -e --arg pane "$pane_id" '
    any(.panes[]; .pane_id == $pane and
      (.app_command | startswith("falkon --no-remote ")))
  ' "$artifact_dir/mux-presentation.json" >/dev/null ||
    die "Falkon launch adapter did not enforce --no-remote"
  systemctl --user show "$pane_scope" -p Id -p ActiveState -p SubState \
    -p ControlGroup -p MainPID >"$artifact_dir/scope-active.txt"
  grep -F "/$pane_scope" "/proc/$pane_app_pid/cgroup" >/dev/null ||
    die "Falkon PID is outside its authoritative pane scope"
  foreground_pgrp="$(ps -o tpgid= -p "$pane_shell_pid" | tr -d ' ')"
  app_pgrp="$(ps -o pgid= -p "$pane_app_pid" | tr -d ' ')"
  [[ -n "$foreground_pgrp" && "$foreground_pgrp" == "$app_pgrp" ]] ||
    die "Falkon is not the pane PTY foreground process group"
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" capture-pane -p -S -200 -t "$pane_id" \
    >"$artifact_dir/console-during.txt"
  grep -F 'FALKON-SHELL-BEFORE' "$artifact_dir/console-during.txt" >/dev/null ||
    die "Falkon backing console lost its pre-launch output"

  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" pane-presentation -t "$pane_id" console
  wait_for_native_state "$state_file" '
    .mux.presentation.type == "wayland" and
    .mux.presentation.view_mode == "console" and
    .mux.presentation.terminal_visible == true and
    .input.mode == "terminal" and
    all(.windows[]; .bound == false or .visible == false)
  ' "live Falkon backing console"
  cp "$state_file" "$artifact_dir/console.json"
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" pane-presentation -t "$pane_id" app
  wait_for_native_state "$state_file" '
    .mux.presentation.type == "wayland" and
    .mux.presentation.view_mode == "presentation" and
    .mux.presentation.terminal_visible == false and
    .input.mode == "graphical" and
    any(.windows[]; .bound == true and .visible == true)
  ' "restored Falkon presentation"

  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" signal-pane-app -t "$pane_id" TERM
  wait_for_native_state "$state_file" '
    .mux.presentation.type == "terminal" and
    .mux.presentation.terminal_visible == true and
    .input.mode == "terminal" and
    all(.windows[]; .bound == false)
  ' "console after Falkon exit" 400
  for _ in {1..200}; do
    foreground_pgrp="$(ps -o tpgid= -p "$pane_shell_pid" | tr -d ' ')"
    [[ "$foreground_pgrp" == "$pane_shell_pid" ]] && break
    sleep 0.05
  done
  [[ "$foreground_pgrp" == "$pane_shell_pid" ]] ||
    die "pane shell did not regain the PTY foreground process group"
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" send-keys -t "$pane_id" -l 'printf "FALKON-SHELL-AFTER\n"'
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" send-keys -t "$pane_id" Enter
  for _ in {1..100}; do
    XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
      "$mux_bin" capture-pane -p -S -200 -t "$pane_id" \
      >"$artifact_dir/console-after.txt"
    grep -F 'FALKON-SHELL-AFTER' "$artifact_dir/console-after.txt" \
      >/dev/null && break
    sleep 0.05
  done
  grep -F 'FALKON-SHELL-AFTER' "$artifact_dir/console-after.txt" >/dev/null ||
    die "pane shell did not accept input after Falkon exited"
  cp "$state_file" "$artifact_dir/exited.json"

  native_live_cleanup
  trap - EXIT INT TERM
  wait_for_native_state "$state_file" ".mux.mode == \"$initial_mode\"" \
    "restored $initial_mode shell mode"
  cp "$state_file" "$artifact_dir/restored.json"
  printf 'Native Falkon pane proof passed.\n'
  printf 'Proof artifacts: %s\n' "$artifact_dir"
}

proof_native_quake() {
  [[ $# -eq 0 ]] || die "native-quake proof takes no options"
  have_cmd jq || die "native-quake proof requires jq"
  have_cmd pactl || die "native-quake proof requires pactl"
  have_cmd systemctl || die "native-quake proof requires systemctl"
  have_cmd sudo || [[ "$(id -u)" -eq 0 ]] ||
    die "native-quake proof requires sudo or root"

  local runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local state_dir="$runtime_dir/engineos"
  local state_file="$state_dir/shell-state.json"
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local shell_log="${ENGINEOS_SHELL_LOG:-$log_dir/shell.log}"
  local stamp="$(timestamp_utc)"
  local artifact_dir="$log_dir/proof-native-quake-$stamp"
  local fixture="${TMPDIR:-/tmp}/engineos-native-quake-proof-$$"
  local mux_bin="${ENGINEOS_TMUX_BIN:-$(command -v tmux || true)}"
  local muxctl_bin="${ENGINEOS_MUXCTL_BIN:-$(command -v engine-muxctl || true)}"
  local app_cmd="$(eos_command eos-app)"
  local assets_cmd="$(eos_command eos-assets)"
  local runtime_cmd="$(eos_command eos-runtime)"
  local initial_mode="" pane_id="" pane_shell_pid="" pane_state=""
  local pane_scope="" pane_app_pid="" pane_launch_command="" shell_command=""
  local foreground_pgrp="" app_pgrp="" audio_pid="" prefix="" id1=""
  local log_start=0

  [[ -x "$mux_bin" ]] || die "native-quake proof requires installed tmux"
  [[ -x "$muxctl_bin" ]] ||
    die "native-quake proof requires installed engine-muxctl"
  app_cmd="$(command -v "$app_cmd" || true)"
  assets_cmd="$(command -v "$assets_cmd" || true)"
  [[ -x "$app_cmd" ]] || die "native-quake proof requires eos-app"
  [[ -x "$assets_cmd" ]] || die "native-quake proof requires eos-assets"
  [[ -r "$state_file" ]] || die "live shell state missing: $state_file"
  [[ -r "$shell_log" ]] || die "live shell log missing: $shell_log"
  [[ -c /dev/tty1 ]] || die "native-quake proof requires tty1"
  systemctl is-active --quiet engineos-dev-shell.service ||
    die "engineos-dev-shell.service is not active"
  jq -e '.mode == "tty"' "$state_file" >/dev/null ||
    die "live shell is not currently attached to tty/DRM"
  "$assets_cmd" check quake >/dev/null
  id1="$("$assets_cmd" path quake)"
  [[ -d "$id1" ]] || die "resolved Quake id1 directory is missing: $id1"
  pactl info >/dev/null || die "native-quake proof requires a live audio server"

  mkdir -p "$artifact_dir" "$fixture/runtime" "$fixture/home" \
    "$fixture/config" "$fixture/cache" "$fixture/data"
  chmod 0700 "$fixture" "$fixture/runtime" "$fixture/home" \
    "$fixture/config" "$fixture/cache" "$fixture/data"
  initial_mode="$(jq -r '.mux.mode' "$state_file")"
  log_start="$(wc -l <"$shell_log")"
  cp "$state_file" "$artifact_dir/before.json"
  "$assets_cmd" check quake >"$artifact_dir/assets.txt"
  native_live_begin "$fixture" "$fixture/runtime" "$mux_bin" "$runtime_cmd"

  printf 'EngineOS native Quake proof\n'
  printf '  state:     %s\n' "$state_file"
  printf '  assets:    %s\n' "$id1"
  printf '  artifacts: %s\n' "$artifact_dir"
  printf '  restore:   %s\n' "$initial_mode"

  printf -v shell_command \
    'export XDG_RUNTIME_DIR=%q WAYLAND_DISPLAY=wayland-0 XDG_SESSION_TYPE=wayland SDL_VIDEODRIVER=wayland SDL_AUDIODRIVER=pulseaudio HOME=%q XDG_CONFIG_HOME=%q XDG_CACHE_HOME=%q XDG_DATA_HOME=%q ENGINEOS_QUAKE_ID1=%q ENGINEOS_STATE_DIR=%q ENGINEOS_LOG_DIR=%q ENGINEOS_TMUX_BIN=%q; printf "QUAKE-SHELL-BEFORE\\n"; exec /bin/sh' \
    "$runtime_dir" "$fixture/home" "$fixture/config" "$fixture/cache" \
    "$fixture/data" "$id1" "$state_dir" "$artifact_dir" "$mux_bin"
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    ENGINEOS_USER_RUNTIME_DIR="$runtime_dir" \
    "$mux_bin" new-session -d -s engineos-quake-proof -x 120 -y 36 \
      "$shell_command"
  pane_id="$(XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" \
    TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" "$mux_bin" display-message -p \
      -t '=engineos-quake-proof:' '#{pane_id}')"
  pane_shell_pid="$(XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" \
    TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" "$mux_bin" display-message -p \
      -t "$pane_id" '#{pane_pid}')"
  [[ "$pane_id" == %* && "$pane_shell_pid" =~ ^[1-9][0-9]*$ ]] ||
    die "isolated Quake pane did not expose stable pane and shell IDs"
  local mux_socket="$NATIVE_LIVE_RUNTIME/engineos/mux.sock"
  [[ -S "$mux_socket" ]] || die "isolated native mux frontend socket missing"

  "${NATIVE_LIVE_SYSTEMCTL[@]}" set-environment \
    ENGINEOS_MUX_SOCKET="$mux_socket"
  NATIVE_LIVE_MANAGER_CHANGED=true
  NATIVE_LIVE_SHELL_SWITCHED=true
  native_live_restart_shell
  wait_for_native_state "$state_file" '
    .mode == "tty" and .backend == "drm,libinput" and
    .wayland_display == "wayland-0" and
    .mux.mode == "native" and .mux.connected == true and
    .mux.pane_id == $pane and .mux.presentation.type == "terminal" and
    .mux.presentation.terminal_visible == true and
    (.output_views | length) > 0
  ' "isolated Quake terminal pane on direct KMS" 200 --arg pane "$pane_id"
  prefix="$(jq -er '.mux.prefix' "$state_file")"
  cp "$state_file" "$artifact_dir/terminal.json"

  printf -v pane_launch_command '%q launch quake --window' "$app_cmd"
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" send-keys -t "$pane_id" -l "$pane_launch_command"
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" send-keys -t "$pane_id" Enter

  wait_for_native_state "$state_file" '
    .mux.pane_id == $pane and
    .mux.presentation.type == "game" and
    .mux.presentation.view_mode == "presentation" and
    .mux.presentation.mapped == true and
    .mux.presentation.surface_tabs >= 1 and
    .mux.presentation.terminal_visible == false and
    .mux.presentation.lease_owned_by_focused_view == true and
    .input.mode == "game" and .input.capture == true and
    .cursor.locked == true and
    any(.windows[]; .bound == true and .pane_id == $pane and
      .app_id == "quakespasm" and .client_pid > 0 and
      .presentation_visible == true and .visible == true)
  ' "scoped Quake game presentation and capture" 500 --arg pane "$pane_id"
  cp "$state_file" "$artifact_dir/presentation.json"
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" "$muxctl_bin" snapshot \
    >"$artifact_dir/mux-presentation.json"
  pane_state="$(XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" \
    TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" "$mux_bin" display-message -p \
      -t "$pane_id" \
      '#{pane_presentation}|#{pane_view_mode}|#{pane_presentation_scope}|#{pane_app_pid}')"
  printf '%s\n' "$pane_state" >"$artifact_dir/pane-state.txt"
  IFS='|' read -r _ _ pane_scope pane_app_pid <<<"$pane_state"
  [[ "$pane_scope" == engine-pane-*.scope ]] ||
    die "Quake launch lacks a dedicated transient scope"
  [[ "$pane_app_pid" =~ ^[1-9][0-9]*$ ]] ||
    die "Quake launch lacks an authoritative application PID"
  jq -e --arg pane "$pane_id" '
    any(.panes[]; .pane_id == $pane and .presentation == "game" and
      (.app_command | contains("quake play --foreground")))
  ' "$artifact_dir/mux-presentation.json" >/dev/null ||
    die "eos-app did not route Quake through the native game pane adapter"
  systemctl --user show "$pane_scope" -p Id -p ActiveState -p SubState \
    -p ControlGroup -p MainPID >"$artifact_dir/scope-active.txt"
  grep -F "/$pane_scope" "/proc/$pane_app_pid/cgroup" >/dev/null ||
    die "Quake pane process is outside its authoritative scope"
  foreground_pgrp="$(ps -o tpgid= -p "$pane_shell_pid" | tr -d ' ')"
  app_pgrp="$(ps -o pgid= -p "$pane_app_pid" | tr -d ' ')"
  [[ -n "$foreground_pgrp" && "$foreground_pgrp" == "$app_pgrp" ]] ||
    die "Quake is not the pane PTY foreground process group"

  for _ in {1..300}; do
    XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
      "$mux_bin" capture-pane -p -S -2000 -t "$pane_id" \
      >"$artifact_dir/console-during.txt"
    grep -F '========= Quake Initialized =========' \
      "$artifact_dir/console-during.txt" >/dev/null && break
    sleep 0.05
  done
  grep -F 'QUAKE-SHELL-BEFORE' "$artifact_dir/console-during.txt" >/dev/null ||
    die "Quake backing console lost its pre-launch output"
  grep -F 'GL_RENDERER: AMD Radeon RX 5600 XT (radeonsi' \
    "$artifact_dir/console-during.txt" >/dev/null ||
    die "Quake console lacks AMD/radeonsi rendering evidence"
  grep -F 'SDL audio driver: pulseaudio' \
    "$artifact_dir/console-during.txt" >/dev/null ||
    die "Quake console lacks PulseAudio/PipeWire initialization evidence"
  grep -F '========= Quake Initialized =========' \
    "$artifact_dir/console-during.txt" >/dev/null ||
    die "Quake did not finish real engine initialization"

  for _ in {1..200}; do
    pactl -f json list sink-inputs >"$artifact_dir/audio-active.json"
    audio_pid="$(jq -r 'first(.[] | select(
      .properties["application.name"] == "quakespasm" and
      .properties["stream.is-live"] == "true" and
      (.properties["target.object"] | startswith("alsa_output.")) and
      .corked == false)) | .properties["application.process.id"] // empty' \
      "$artifact_dir/audio-active.json")"
    [[ "$audio_pid" =~ ^[1-9][0-9]*$ ]] && break
    sleep 0.05
  done
  [[ "$audio_pid" =~ ^[1-9][0-9]*$ ]] ||
    die "Quake did not expose an uncorked live hardware audio stream"
  grep -F "/$pane_scope" "/proc/$audio_pid/cgroup" >/dev/null ||
    die "Quake audio process is outside its authoritative pane scope"

  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" "$muxctl_bin" keys "$pane_id" \
    "$prefix" v >"$artifact_dir/prefix-console.json"
  wait_for_native_state "$state_file" '
    .mux.presentation.type == "game" and
    .mux.presentation.view_mode == "console" and
    .mux.presentation.terminal_visible == true and
    .input.mode == "terminal" and .input.capture == false and
    .cursor.locked == false and
    all(.windows[]; .bound == false or .visible == false)
  ' "Quake console through the native prefix binding"
  cp "$state_file" "$artifact_dir/console.json"
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" "$muxctl_bin" keys "$pane_id" \
    "$prefix" v >"$artifact_dir/prefix-app.json"
  wait_for_native_state "$state_file" '
    .mux.presentation.type == "game" and
    .mux.presentation.view_mode == "presentation" and
    .input.mode == "game" and .input.capture == true and
    .cursor.locked == true and
    any(.windows[]; .bound == true and .visible == true)
  ' "Quake presentation restored through the native prefix binding"

  emit_emergency_release_chord
  wait_for_native_state "$state_file" '
    .mux.presentation.type == "game" and
    .input.mode == "shell" and .input.capture == false and
    .input.emergency_released == true and
    .cursor.locked == false
  ' "real Ctrl+Alt+Backspace emergency release" 300
  cp "$state_file" "$artifact_dir/emergency-release.json"
  sed -n "$((log_start + 1)),\$p" "$shell_log" \
    >"$artifact_dir/shell-native-quake.log"
  grep -F 'keybinding ctrl+alt+backspace: emergency release' \
    "$artifact_dir/shell-native-quake.log" >/dev/null ||
    die "shell log lacks the physical emergency-release keybinding"
  grep -F 'input emergency-release complete' \
    "$artifact_dir/shell-native-quake.log" >/dev/null ||
    die "shell did not complete emergency release"

  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" "$muxctl_bin" keys "$pane_id" \
    "$prefix" v >/dev/null
  wait_for_native_state "$state_file" '
    .mux.presentation.view_mode == "console" and
    .mux.presentation.terminal_visible == true and
    .input.mode == "terminal" and .input.capture == false
  ' "console after emergency release"
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" "$muxctl_bin" keys "$pane_id" \
    "$prefix" v >/dev/null
  wait_for_native_state "$state_file" '
    .mux.presentation.view_mode == "presentation" and
    .input.mode == "game" and .input.capture == true and
    .cursor.locked == true
  ' "game capture restored after emergency release"

  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" signal-pane-app -t "$pane_id" TERM
  wait_for_native_state "$state_file" '
    .mux.presentation.type == "terminal" and
    .mux.presentation.terminal_visible == true and
    .input.mode == "terminal" and .input.capture == false and
    .cursor.locked == false and all(.windows[]; .bound == false)
  ' "console after Quake exit" 500
  for _ in {1..200}; do
    foreground_pgrp="$(ps -o tpgid= -p "$pane_shell_pid" | tr -d ' ')"
    [[ "$foreground_pgrp" == "$pane_shell_pid" ]] && break
    sleep 0.05
  done
  [[ "$foreground_pgrp" == "$pane_shell_pid" ]] ||
    die "pane shell did not regain the PTY after Quake exited"
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" send-keys -t "$pane_id" -l 'printf "QUAKE-SHELL-AFTER\n"'
  XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
    "$mux_bin" send-keys -t "$pane_id" Enter
  for _ in {1..100}; do
    XDG_RUNTIME_DIR="$NATIVE_LIVE_RUNTIME" TMUX_TMPDIR="$NATIVE_LIVE_RUNTIME" \
      "$mux_bin" capture-pane -p -S -2000 -t "$pane_id" \
      >"$artifact_dir/console-after.txt"
    grep -F 'QUAKE-SHELL-AFTER' "$artifact_dir/console-after.txt" \
      >/dev/null && break
    sleep 0.05
  done
  grep -F 'QUAKE-SHELL-AFTER' "$artifact_dir/console-after.txt" >/dev/null ||
    die "pane shell did not accept input after Quake exited"
  cp "$state_file" "$artifact_dir/exited.json"

  native_live_cleanup
  trap - EXIT INT TERM
  wait_for_native_state "$state_file" ".mux.mode == \"$initial_mode\"" \
    "restored $initial_mode shell mode"
  cp "$state_file" "$artifact_dir/restored.json"
  printf 'Native Quake pane proof passed.\n'
  printf 'Proof artifacts: %s\n' "$artifact_dir"
}

default_log_dir() {
  engineos_default_log_dir "$ROOT"
}

default_state_dir() {
  engineos_default_state_dir "$ROOT"
}

timestamp_utc() {
  date -u +%Y%m%dT%H%M%SZ
}

run_step() {
  local label="$1"
  shift

  printf '\n==> %s\n' "$label"
  printf '    '
  quote_cmd "$@"
  "$@"
}

write_preview_fixture_png() {
  local path="$1"

  have_cmd base64 || die "base64 unavailable; cannot create preview proof fixture"
  printf '%s' \
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAADAQMAAACOOjyFAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURSJmzP///8VU6LMAAAABYktHRAH/Ai3eAAAAB3RJTUUH6gcCFi0VNn7nGQAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAyNi0wNy0wMlQyMjo0NToyMSswMDowMIBjV7MAAAAldEVYdGRhdGU6bW9kaWZ5ADIwMjYtMDctMDJUMjI6NDU6MjErMDA6MDDxPu8PAAAAKHRFWHRkYXRlOnRpbWVzdGFtcAAyMDI2LTA3LTAyVDIyOjQ1OjIxKzAwOjAwpivO0AAAAAtJREFUCNdjYAABAAAGAAFm9MlsAAAAAElFTkSuQmCC' |
    base64 -d >"$path" ||
    die "failed to create preview proof fixture: $path"
  [[ -s "$path" ]] || die "preview proof fixture is empty: $path"
}

eos_command() {
  local name="$1"
  if [[ -x "$ROOT/tools/engineos/$name" ]]; then
    printf '%s\n' "$ROOT/tools/engineos/$name"
  else
    printf '%s\n' "$name"
  fi
}

proof_build_lab() {
  local dry_run=false
  local profile="enginedev"
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local out_dir="${ENGINEOS_OUT_DIR:-$ROOT/out}"
  local log_file

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --profile)
        shift
        profile="${1:-}"
        [[ -n "$profile" ]] || die "--profile requires a profile"
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown build-lab proof option: $1"
        ;;
    esac
    shift
  done

  [[ "$profile" == "enginedev" ]] || die "build-lab proof currently expects the EngineDev profile"

  mkdir -p "$log_dir"
  log_file="$log_dir/proof-build-lab-$(timestamp_utc).log"
  exec > >(tee -a "$log_file") 2>&1

  printf 'EngineOS build-lab proof\n'
  printf '  root:    %s\n' "$ROOT"
  printf '  profile: %s\n' "$profile"
  printf '  dry_run: %s\n' "$dry_run"
  printf '  log:     %s\n' "$log_file"

  if [[ "$dry_run" == true ]]; then
    run_step "validate builder preview" printf '%s\n' "./tools/engineos/eos-validate builder"
  else
    run_step "validate builder" "$SCRIPT_DIR/validate_builder.sh"
  fi
  run_step "preflight all" "$SCRIPT_DIR/preflight.sh" all
  run_step "lint packages" "$SCRIPT_DIR/package_lint.sh"

  if [[ "$dry_run" == true ]]; then
    run_step "build shell dry-run" "$SCRIPT_DIR/build_shell.sh" --dry-run
    run_step "build repo dry-run" "$SCRIPT_DIR/build_repo.sh" --dry-run
    run_step "validate repo dry-run" "$SCRIPT_DIR/validate_repo.sh" --dry-run
    run_step "build EngineDev ISO dry-run" "$SCRIPT_DIR/build_iso.sh" "$profile" --dry-run
  else
    run_step "build shell" "$SCRIPT_DIR/build_shell.sh"
    run_step "build repo" "$SCRIPT_DIR/build_repo.sh"
    run_step "validate repo" "$SCRIPT_DIR/validate_repo.sh"
    run_step "build EngineDev ISO" "$SCRIPT_DIR/build_iso.sh" "$profile" --clean --archive-existing
    run_step "list ISO artifacts" "$SCRIPT_DIR/artifacts.sh" list "$out_dir"
  fi

  if [[ "$dry_run" == true ]]; then
    printf '\nBuild-lab proof preview completed; no build-lab proof was executed.\n'
    printf 'Next Arch builder command: ./tools/engineos/eos-proof build-lab\n'
  else
    printf '\nBuild-lab proof runner completed.\n'
    printf 'Next test VM command: ./tools/engineos/eos-vm boot enginedev\n'
    printf 'Next booted ISO command: eos-proof booted-iso --vm\n'
  fi
}

proof_release_candidate() {
  local dry_run=false
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local out_dir="${ENGINEOS_OUT_DIR:-$ROOT/out}"
  local export_dir=""
  local log_file
  local release_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --out-dir)
        shift
        out_dir="${1:-}"
        [[ -n "$out_dir" ]] || die "--out-dir requires a directory"
        ;;
      --export-dir)
        shift
        export_dir="${1:-}"
        [[ -n "$export_dir" ]] || die "--export-dir requires a directory"
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown release-candidate proof option: $1"
        ;;
    esac
    shift
  done

  mkdir -p "$log_dir"
  log_file="$log_dir/proof-release-candidate-$(timestamp_utc).log"
  exec > >(tee -a "$log_file") 2>&1

  printf 'EngineOS release-candidate proof\n'
  printf '  root:    %s\n' "$ROOT"
  printf '  out:     %s\n' "$out_dir"
  printf '  dry_run: %s\n' "$dry_run"
  printf '  log:     %s\n' "$log_file"
  [[ -n "$export_dir" ]] && printf '  export:  %s\n' "$export_dir"

  if [[ "$dry_run" == true ]]; then
    release_args+=(--dry-run)
    run_step "validate builder preview" printf '%s\n' "./tools/engineos/eos-validate builder"
    run_step "preflight all" "$SCRIPT_DIR/preflight.sh" all
    run_step "lint packages" "$SCRIPT_DIR/package_lint.sh"
    run_step "build shell dry-run" "$SCRIPT_DIR/build_shell.sh" --dry-run
    run_step "build repo dry-run" "$SCRIPT_DIR/build_repo.sh" --dry-run
    run_step "validate repo dry-run" "$SCRIPT_DIR/validate_repo.sh" --dry-run
    run_step "build EngineDev ISO dry-run" env ENGINEOS_OUT_DIR="$out_dir" "$SCRIPT_DIR/build_iso.sh" enginedev --dry-run
    run_step "build EngineRuntime ISO dry-run" env ENGINEOS_OUT_DIR="$out_dir" "$SCRIPT_DIR/build_iso.sh" engineruntime --dry-run
  else
    run_step "validate builder" "$SCRIPT_DIR/validate_builder.sh"
    run_step "preflight all" "$SCRIPT_DIR/preflight.sh" all
    run_step "lint packages" "$SCRIPT_DIR/package_lint.sh"
    run_step "build shell" "$SCRIPT_DIR/build_shell.sh"
    run_step "build repo" "$SCRIPT_DIR/build_repo.sh"
    run_step "validate repo" "$SCRIPT_DIR/validate_repo.sh"
    run_step "build EngineDev ISO" env ENGINEOS_OUT_DIR="$out_dir" "$SCRIPT_DIR/build_iso.sh" enginedev --clean --archive-existing
    run_step "build EngineRuntime ISO" env ENGINEOS_OUT_DIR="$out_dir" "$SCRIPT_DIR/build_iso.sh" engineruntime --clean --archive-existing
  fi

  release_args=(checklist --out-dir "$out_dir")
  if [[ "$dry_run" == true ]]; then
    release_args+=(--dry-run)
  fi
  if [[ -n "$export_dir" ]]; then
    release_args+=(--export-dir "$export_dir")
  fi
  run_step "release checklist" "$SCRIPT_DIR/release.sh" "${release_args[@]}"

  if [[ "$dry_run" == true ]]; then
    printf '\nRelease-candidate proof preview completed; no release-candidate proof was executed.\n'
    printf 'Next Arch builder command: ./tools/engineos/eos-proof release-candidate\n'
  else
    printf '\nRelease-candidate proof runner completed.\n'
    printf 'Next test VM command: ./tools/engineos/eos-vm boot enginedev\n'
    printf 'Next runtime VM command: ./tools/engineos/eos-vm boot engineruntime\n'
    printf 'Next hardware proof: boot EngineRuntime on the AMD machine and run eos-proof booted-iso --bare-metal\n'
  fi
}

proof_hardware_ready() {
  local dry_run=false
  local profile="engineruntime"
  local out_dir="${ENGINEOS_OUT_DIR:-$ROOT/out}"
  local device=""
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local log_file
  local usb_write_cmd=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --profile)
        shift
        profile="${1:-}"
        [[ -n "$profile" ]] || die "--profile requires a profile"
        ;;
      --out-dir)
        shift
        out_dir="${1:-}"
        [[ -n "$out_dir" ]] || die "--out-dir requires a directory"
        ;;
      --device)
        shift
        device="${1:-}"
        [[ -n "$device" ]] || die "--device requires a block device"
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown hardware-ready proof option: $1"
        ;;
    esac
    shift
  done

  case "$profile" in
    enginedev|engineruntime)
      ;;
    *)
      die "unknown hardware-ready profile: $profile"
      ;;
  esac

  mkdir -p "$log_dir"
  log_file="$log_dir/proof-hardware-ready-$(timestamp_utc).log"
  exec > >(tee -a "$log_file") 2>&1

  printf 'EngineOS hardware-ready proof\n'
  printf '  root:    %s\n' "$ROOT"
  printf '  profile: %s\n' "$profile"
  printf '  out:     %s\n' "$out_dir"
  printf '  dry_run: %s\n' "$dry_run"
  printf '  log:     %s\n' "$log_file"
  [[ -n "$device" ]] && printf '  device:  %s\n' "$device"

  usb_write_cmd=("$BARE_METAL_DIR/usb.sh" write --profile "$profile" --out-dir "$out_dir" --device "${device:-/dev/sdX}" --dry-run)

  if [[ "$dry_run" == true ]]; then
    run_step "preflight all dry-run" printf '%s\n' "./tools/engineos/eos-preflight all"
    run_step "release-candidate dry-run" printf '%s\n' "./tools/engineos/eos-proof release-candidate --dry-run --out-dir $out_dir"
    run_step "USB candidate list dry-run" printf '%s\n' "./tools/engineos/eos-usb list"
    run_step "USB write dry-run" printf '%s\n' "./tools/engineos/eos-usb write --profile $profile --out-dir $out_dir --device ${device:-/dev/sdX} --dry-run"
    run_step "booted bare-metal proof dry-run" printf '%s\n' "eos-proof booted-iso --bare-metal"
  else
    run_step "preflight all" "$SCRIPT_DIR/preflight.sh" all
    run_step "release checklist dry-run" "$SCRIPT_DIR/release.sh" checklist --dry-run --out-dir "$out_dir"
    run_step "USB candidate list" "$BARE_METAL_DIR/usb.sh" list
    if [[ -n "$device" ]]; then
      run_step "USB write dry-run" "${usb_write_cmd[@]}"
    else
      printf '\nNo --device provided; inspect the USB candidate list and re-run with --device /dev/sdX.\n'
      printf 'USB write dry-run command: '
      quote_cmd "${usb_write_cmd[@]}"
    fi
  fi

  if [[ "$dry_run" == true ]]; then
    printf '\nHardware-ready proof preview completed; no hardware-ready proof was executed.\n'
  else
    printf '\nHardware-ready proof runner completed.\n'
  fi
  printf 'This proof does not write USB media or prove AMD hardware by itself.\n'
  printf 'After writing the ISO and booting the target AMD machine, run:\n'
  printf '  eos-proof booted-iso --bare-metal\n'
}

proof_booted_iso() {
  local dry_run=false
  local mode="vm"
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local log_file
  local validate_args=(--vm)
  local doctor_args=(--vm)
  local crash_bundle_args=(--vm)
  local assets_cmd
  local logs_cmd
  local outputs_cmd
  local runtime_cmd

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --vm)
        mode="vm"
        validate_args=(--vm)
        doctor_args=(--vm)
        crash_bundle_args=(--vm)
        ;;
      --runtime)
        mode="runtime"
        validate_args=(--runtime)
        doctor_args=(--vm)
        crash_bundle_args=(--runtime)
        ;;
      --bare-metal)
        mode="bare-metal"
        validate_args=(--bare-metal)
        doctor_args=(--bare-metal)
        crash_bundle_args=(--bare-metal)
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown booted-iso proof option: $1"
        ;;
    esac
    shift
  done

  if ! mkdir -p "$log_dir" 2>/dev/null || ! touch "$log_dir/.engineos-write-test" 2>/dev/null; then
    log_dir="${TMPDIR:-/tmp}/engineos-logs"
    mkdir -p "$log_dir"
  else
    rm -f "$log_dir/.engineos-write-test"
  fi
  log_file="$log_dir/proof-booted-iso-$mode-$(timestamp_utc).log"
  exec > >(tee -a "$log_file") 2>&1

  printf 'EngineOS booted-ISO proof\n'
  printf '  root:    %s\n' "$ROOT"
  printf '  mode:    %s\n' "$mode"
  printf '  dry_run: %s\n' "$dry_run"
  printf '  log:     %s\n' "$log_file"

  assets_cmd="$(eos_command eos-assets)"
  logs_cmd="$(eos_command eos-logs)"
  outputs_cmd="$(eos_command eos-outputs)"
  runtime_cmd="$(eos_command eos-runtime)"

  if [[ "$dry_run" == true ]]; then
    run_step "validate boot dry-run" printf '%s\n' "eos-validate boot ${validate_args[*]}"
    run_step "doctor dry-run" printf '%s\n' "eos-doctor ${doctor_args[*]}"
    run_step "smoke test dry-run" printf '%s\n' "eos-test smoke"
    run_step "Quake smoke dry-run" printf '%s\n' "eos-runtime quake --smoke"
    run_step "asset guidance dry-run" printf '%s\n' "eos-assets explain quake"
    run_step "engine logs dry-run" printf '%s\n' "eos-logs engine --last 200"
    if [[ "$mode" == "bare-metal" ]]; then
      run_step "output validation dry-run" printf '%s\n' "eos-outputs validate --single"
    fi
    if [[ "$mode" == "runtime" || "$mode" == "bare-metal" ]]; then
      run_step "runtime reliability dry-run" printf '%s\n' "eos-test reliability"
      run_step "runtime logs dry-run" printf '%s\n' "eos-logs runtime --last 200"
    fi
    run_step "crash bundle dry-run" printf '%s\n' "eos-crash-bundle ${crash_bundle_args[*]}"
  else
    run_step "validate boot" env ENGINEOS_PROOF_STRICT=1 "$MODULE_DIR/validate_boot.sh" "${validate_args[@]}"
    run_step "doctor" "$SCRIPT_DIR/doctor.sh" "${doctor_args[@]}"
    run_step "smoke test" "$TEST_DIR/test_runner.sh" smoke
    run_step "Quake smoke" "$runtime_cmd" quake --smoke
    run_step "asset guidance" "$assets_cmd" explain quake
    run_step "engine logs" "$logs_cmd" engine --last 200
    if [[ "$mode" == "bare-metal" ]]; then
      run_step "output validation" "$outputs_cmd" validate --single
    fi
    if [[ "$mode" == "runtime" || "$mode" == "bare-metal" ]]; then
      run_step "runtime reliability" "$TEST_DIR/test_runner.sh" reliability
      run_step "runtime logs" "$logs_cmd" runtime --last 200
    fi
    run_step "crash bundle" "$SCRIPT_DIR/crash_bundle.sh" "${crash_bundle_args[@]}"
  fi

  if [[ "$dry_run" == true ]]; then
    printf '\nBooted-ISO proof preview completed; no booted-ISO proof was executed.\n'
    printf 'Next booted ISO command: eos-proof booted-iso --%s\n' "$mode"
  else
    printf '\nBooted-ISO proof runner completed.\n'
    printf 'Proof log: %s\n' "$log_file"
  fi
}

proof_shell_launch() {
  local dry_run=false
  local mode="vm"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=true ;;
      --vm) mode="vm" ;;
      --runtime) mode="runtime" ;;
      --bare-metal) mode="bare-metal" ;;
      help|--help|-h) usage; exit 0 ;;
      *) die "unknown shell-launch proof option: $1" ;;
    esac
    shift
  done
  local runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local state="$runtime_dir/engineos/shell-state.json"
  if [[ "$dry_run" == true ]]; then
    printf 'would require: tmux -V; jq -e .mux.connected==true %s; pgrep engineos-shell\n' "$state"
    return
  fi
  command -v tmux >/dev/null || die "system tmux is missing"
  tmux -V | grep -Fx 'tmux 3.6b' >/dev/null || die "system tmux is not the EngineOS 3.6b fork"
  pgrep -x engineos-shell >/dev/null || die "engineos-shell is not running"
  jq -e '.mux.mode == "native" and .mux.connected == true' "$state" >/dev/null ||
    die "shell is not connected to the native mux frontend"
  if pgrep -f 'engineos-tmux-(pane-bridge|pane-sync|window-proxy)' >/dev/null; then
    die "retired tmux bridge process is running"
  fi
  printf 'native shell launch proof passed mode=%s\n' "$mode"
}
proof_visual() {
  local dry_run=false
  local allow_metadata=false
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local log_file
  local capture_cmd
  local artifact
  local metadata
  local result

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --allow-metadata)
        allow_metadata=true
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown visual proof option: $1"
        ;;
    esac
    shift
  done

  mkdir -p "$log_dir"
  log_file="$log_dir/proof-visual-$(timestamp_utc).log"
  exec > >(tee -a "$log_file") 2>&1

  printf 'EngineOS visual proof\n'
  printf '  root:           %s\n' "$ROOT"
  printf '  dry_run:        %s\n' "$dry_run"
  printf '  allow_metadata: %s\n' "$allow_metadata"
  printf '  log:            %s\n' "$log_file"

  capture_cmd="$(eos_command eos-capture)"

  if [[ "$dry_run" == true ]]; then
    run_step "frame capture dry-run" printf '%s\n' "would require: eos-capture frame --target shell"
    run_step "visual artifact dry-run" printf '%s\n' "would require: capture metadata result=image and a readable PNG artifact"
    printf '\nVisual proof preview completed; no visual proof was executed.\n'
    return
  fi

  printf '\n==> frame capture\n'
  printf '    '
  quote_cmd "$capture_cmd" frame --target shell
  artifact="$("$capture_cmd" frame --target shell)"
  printf '%s\n' "$artifact"
  artifact="$(printf '%s\n' "$artifact" | tail -n 1)"
  [[ -n "$artifact" && -f "$artifact" ]] || die "frame capture did not produce an artifact"

  if [[ "$artifact" == *.png ]]; then
    metadata="${artifact%.png}.txt"
  else
    metadata="$artifact"
  fi
  [[ -r "$metadata" ]] || die "frame capture metadata missing: $metadata"
  result="$(awk -F= '$1 == "result" { print $2; exit }' "$metadata")"

  case "$result" in
    image)
      [[ "$artifact" == *.png && -s "$artifact" ]] || die "visual capture did not produce a non-empty PNG image"
      printf 'Visual frame captured: %s\n' "$artifact"
      ;;
    metadata)
      if [[ "$allow_metadata" == true ]]; then
        printf 'Metadata-only capture accepted by explicit request: %s\n' "$metadata"
      else
        die "metadata-only capture is not visual proof: $metadata"
      fi
      ;;
    failed|"")
      die "frame capture failed; metadata: $metadata"
      ;;
    *)
      die "unknown frame capture result '$result' in $metadata"
      ;;
  esac

  printf '\nVisual proof runner completed.\n'
  printf 'Proof log: %s\n' "$log_file"
}

proof_mc_preview() {
  local dry_run=false
  local visual=false
  local log_dir="${ENGINEOS_LOG_DIR:-$(default_log_dir)}"
  local log_file
  local preview_cmd
  local preview_image
  local shell_log

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        ;;
      --visual)
        visual=true
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown mc-preview proof option: $1"
        ;;
    esac
    shift
  done

  mkdir -p "$log_dir"
  log_file="$log_dir/proof-mc-preview-$(timestamp_utc).log"
  exec > >(tee -a "$log_file") 2>&1

  printf 'EngineOS MC preview proof\n'
  printf '  root:    %s\n' "$ROOT"
  printf '  dry_run: %s\n' "$dry_run"
  printf '  visual:  %s\n' "$visual"
  printf '  log:     %s\n' "$log_file"

  preview_cmd="${ENGINEOS_IMAGE_PREVIEW_CMD:-$(eos_command engine-image-preview)}"
  preview_image="$log_dir/proof-mc-preview.png"
  shell_log="$log_dir/shell.log"

  if [[ "$dry_run" == true ]]; then
    run_step "test image setup dry-run" printf '%s\n' "would require: eos-test image-preview fixture images"
    run_step "preview dry-run checks" printf '%s\n' "would require: engine-image-preview --quick-view <image> --panel right --dry-run"
    run_step "preview IPC check dry-run" printf '%s\n' "would require: engine-image-preview --ping"
    run_step "preview live request dry-run" printf '%s\n' "would require: engine-image-preview --quick-view $preview_image --panel right"
    run_step "preview shell log evidence dry-run" printf '%s\n' "would require: grep -F 'image preview shown path=$preview_image' $shell_log | grep -F 'owner=mc-quick-view:' | grep -F 'image=4x3'"
    run_step "preview recovery check" printf '%s\n' "would require: eos-app recover preview"
    if [[ "$visual" == true ]]; then
      run_step "visual capture dry-run" printf '%s\n' "would require: eos-proof visual"
    fi
    printf '\nMC preview proof preview completed; no MC preview proof was executed.\n'
    return
  fi

  run_step "image preview contract" "$TEST_DIR/test_runner.sh" image-preview
  write_preview_fixture_png "$preview_image"
  run_step "preview IPC ping" "$preview_cmd" --ping
  run_step "MC quick-view preview" "$preview_cmd" --quick-view "$preview_image" --panel right
  [[ -r "$shell_log" ]] || die "shell log missing: $shell_log"
  grep -aF "image preview shown path=$preview_image" "$shell_log" |
    grep -F 'owner=mc-quick-view:' |
    grep -F 'image=4x3' >/dev/null ||
    die "shell log does not show MC Quick View preview evidence: $shell_log"
  if [[ "$visual" == true ]]; then
    run_step "visual capture" "$MODULE_DIR/proof.sh" visual
  fi

  printf '\nMC preview proof runner completed.\n'
  printf 'Proof log: %s\n' "$log_file"
}

case "$ACTION" in
  build-lab)
    proof_build_lab "$@"
    ;;
  release-candidate)
    proof_release_candidate "$@"
    ;;
  hardware-ready)
    proof_hardware_ready "$@"
    ;;
  booted-iso)
    proof_booted_iso "$@"
    ;;
  shell-launch)
    proof_shell_launch "$@"
    ;;
  native-kms)
    proof_native_kms "$@"
    ;;
  native-falkon)
    proof_native_falkon "$@"
    ;;
  native-quake)
    proof_native_quake "$@"
    ;;
  visual)
    proof_visual "$@"
    ;;
  mc-preview)
    proof_mc_preview "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown proof action: $ACTION"
    ;;
esac
