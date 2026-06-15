#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
SCOPE="${1:-smoke}"
shift || true

usage() {
  cat <<'HELP'
Usage: test_runner.sh [smoke|all]
       test_runner.sh compositor --headless
       test_runner.sh shell-actions
       test_runner.sh engine-runner-env
       test_runner.sh app
       test_runner.sh assets
       test_runner.sh reliability
       test_runner.sh logs
       test_runner.sh artifacts
       test_runner.sh release
       test_runner.sh terminal
       test_runner.sh vm
       test_runner.sh usb
       test_runner.sh install
       test_runner.sh proof
       test_runner.sh installed-preflight
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
  exec "$SCRIPT_DIR/smoke_test.sh"
}

run_all_step() {
  printf '\n==> engineos test'
  printf ' %s' "$@"
  printf '\n'
  "$SCRIPT_DIR/test_runner.sh" "$@"
}

run_all() {
  printf 'EngineOS full local test suite\n'
  run_all_step smoke
  run_all_step compositor --headless
  run_all_step shell-actions
  run_all_step engine-runner-env
  run_all_step app
  run_all_step assets
  run_all_step reliability
  run_all_step logs
  run_all_step artifacts
  run_all_step release
  run_all_step terminal
  run_all_step vm
  run_all_step usb
  run_all_step install
  run_all_step proof
  run_all_step installed-preflight
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

run_installed_preflight() {
  local tmp_dir="/tmp/engineos-installed-preflight-$$"
  local root_dir="$tmp_dir/usr"
  local bin_dir="$tmp_dir/usr/bin"
  local script_dir="$tmp_dir/usr/lib/engineos/scripts"
  local out="$tmp_dir/preflight.txt"

  cleanup_installed_preflight() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_installed_preflight RETURN

  mkdir -p "$bin_dir" "$script_dir"
  cp "$ROOT/tools/engineos/engineos" "$bin_dir/engineos"
  cp "$ROOT/tools/scripts/"*.sh "$script_dir/"
  cp "$ROOT/tools/scripts/engine_runner_daemon.py" "$script_dir/"
  chmod +x "$bin_dir/engineos" "$script_dir/"*.sh

  ENGINEOS_INSTALLED_IMAGE=true \
    ENGINEOS_ROOT="$root_dir" \
    ENGINEOS_INSTALLED_BIN_DIR="$bin_dir" \
    ENGINEOS_INSTALLED_SCRIPT_DIR="$script_dir" \
    "$SCRIPT_DIR/preflight.sh" scripts >"$out"

  grep -F "OK   $bin_dir/engineos" "$out" >/dev/null ||
    die "installed preflight did not check installed engineos"
  grep -F "OK   $script_dir/proof.sh" "$out" >/dev/null ||
    die "installed preflight did not check installed proof script"
  grep -F 'Preflight summary: 0 failure(s)' "$out" >/dev/null ||
    die "installed preflight did not pass"

  printf 'installed preflight test passed\n'
}

run_shell_actions() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-shell-actions-$$"
  local fake_shell="$tmp_dir/engineos-shell"
  local args_file="$tmp_dir/args.txt"

  cleanup_shell_actions() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_shell_actions RETURN

  mkdir -p "$tmp_dir/logs"
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
    ENGINEOS_CUBE_CMD="engineos app launch cube --smoke" \
    ENGINEOS_ENGINE_CMD="engineos app launch quake --smoke" \
    "$SCRIPT_DIR/shell_runner.sh" --nested >/dev/null

  grep -Fx -- "--nested" "$args_file" >/dev/null || die "shell actions test missing --nested"
  grep -Fx -- "--terminal" "$args_file" >/dev/null || die "shell actions test missing --terminal"
  grep -Fx -- "foot --server" "$args_file" >/dev/null || die "shell actions test missing terminal command"
  grep -Fx -- "--cube" "$args_file" >/dev/null || die "shell actions test missing --cube"
  grep -Fx -- "engineos app launch cube --smoke" "$args_file" >/dev/null || die "shell actions test missing cube command"
  grep -Fx -- "--engine" "$args_file" >/dev/null || die "shell actions test missing --engine"
  grep -Fx -- "engineos app launch quake --smoke" "$args_file" >/dev/null || die "shell actions test missing app command"

  ENGINEOS_SHELL_BIN="$fake_shell" \
    ENGINEOS_FAKE_SHELL_ARGS="$args_file" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    "$SCRIPT_DIR/shell_runner.sh" --tty >/dev/null

  grep -Fx -- "--tty" "$args_file" >/dev/null || die "shell actions test missing --tty"
  grep -Fx -- "--terminal" "$args_file" >/dev/null || die "shell actions tty missing --terminal"
  grep -E -- '(^|/)engineos app launch terminal$' "$args_file" >/dev/null || die "shell actions tty missing default terminal app command"
  grep -Fx -- "--cube" "$args_file" >/dev/null || die "shell actions tty missing --cube"
  grep -E -- '(^|/)engineos app launch cube$' "$args_file" >/dev/null || die "shell actions tty missing default cube command"
  grep -Fx -- "--engine" "$args_file" >/dev/null || die "shell actions tty missing --engine"
  grep -E -- '(^|/)engineos app launch quake$' "$args_file" >/dev/null || die "shell actions tty missing default app command"
  grep -Fx -- "--bootstrap" "$args_file" >/dev/null || die "shell actions tty missing --bootstrap"
  grep -Fx -- "launchpad" "$args_file" >/dev/null || die "shell actions tty missing bootstrap launchpad"
  grep -F 'fake shell stdout marker' "$tmp_dir/logs/shell.log" >/dev/null ||
    die "shell actions did not tee real shell output to shell log"

  printf 'shell actions smoke test passed\n'
}

run_engine_runner_env() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-runner-env-$$"
  local out="$tmp_dir/out.txt"

  cleanup_engine_runner_env() {
    ENGINEOS_STATE_DIR="$tmp_dir/run" ENGINEOS_LOG_DIR="$tmp_dir/logs" "$SCRIPT_DIR/engine_runner.sh" daemon-stop >/dev/null 2>&1 || true
    rm -rf "$tmp_dir"
  }
  trap cleanup_engine_runner_env RETURN

  mkdir -p "$tmp_dir/run" "$tmp_dir/logs"

  ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    "$SCRIPT_DIR/engine_runner.sh" status >"$out"
  grep -F 'engine status: stopped' "$out" >/dev/null ||
    die "engine runner initial status was not stopped"

  if ENGINEOS_STATE_DIR="$tmp_dir/run" \
      ENGINEOS_LOG_DIR="$tmp_dir/logs" \
      "$SCRIPT_DIR/engine_runner.sh" restart >"$out" 2>&1; then
    die "engine runner restart without previous target should fail"
  fi
  grep -F 'no previous engine target to restart' "$out" >/dev/null ||
    die "engine runner restart without target did not explain the failure"

  ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/engine_runner.sh" launch quake --smoke >"$out"
  grep -F 'engine launched: quake' "$out" >/dev/null ||
    die "engine runner launch did not report quake launch"

  ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    "$SCRIPT_DIR/engine_runner.sh" status >"$out"
  grep -F 'target: quake' "$out" >/dev/null ||
    die "engine runner status did not retain quake target"

  ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/engine_runner.sh" restart >"$out"
  grep -F 'engine launched: quake' "$out" >/dev/null ||
    die "engine runner restart did not relaunch previous quake target"

  ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_LOG_DIR="$tmp_dir/logs" \
    "$SCRIPT_DIR/engine_runner.sh" quit >"$out"
  grep -E 'engine (already )?stopped|engine stop requested' "$out" >/dev/null ||
    die "engine runner quit did not report a stopped/stopping engine"

  if ! grep -F 'display=engineos-test-wayland' "$tmp_dir/logs/engine.log" >/dev/null; then
    die "engine runner did not forward WAYLAND_DISPLAY to launch log"
  fi
  if [[ "$(grep -c 'socket launch quake --smoke display=engineos-test-wayland' "$tmp_dir/logs/engine.log")" -lt 2 ]]; then
    die "engine runner lifecycle did not log both launch and restart"
  fi

  printf 'engine runner lifecycle smoke test passed\n'
}

run_app() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-app-test-$$"
  local fake_bin="$tmp_dir/bin"
  local log_dir="$tmp_dir/logs"
  local out="$tmp_dir/out.txt"
  local launched="$tmp_dir/launched.txt"

  cleanup_app() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_app RETURN

  mkdir -p "$fake_bin" "$log_dir" "$tmp_dir/run"
  cat >"$fake_bin/engineos" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$ENGINEOS_FAKE_APP_LAUNCHED"
FAKE
  cat >"$fake_bin/engineos-cube" <<'FAKE'
#!/usr/bin/env bash
printf 'fake cube %s\n' "$*"
FAKE
  chmod +x "$fake_bin/engineos" "$fake_bin/engineos-cube"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_CMD="$fake_bin/engineos" \
    ENGINEOS_FAKE_APP_LAUNCHED="$launched" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/app.sh" launch quake --smoke >"$out"
  grep -F 'engine launch quake --smoke' "$launched" >/dev/null ||
    die "app launcher did not dispatch quake through engine runner"
  grep -F 'app launch app=quake owner=engineos-shell display=engineos-test-wayland sdl=wayland args=--smoke' "$log_dir/app.log" >/dev/null ||
    die "app launcher did not log shell-owned quake launch"

  PATH="$fake_bin:$PATH" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/app.sh" launch cube --smoke >"$out"
  grep -F 'app launch app=cube owner=engineos-shell display=engineos-test-wayland sdl=wayland args=--smoke' "$log_dir/app.log" >/dev/null ||
    die "app launcher did not log shell-owned cube launch"
  grep -F 'fake cube --smoke' "$log_dir/cube.log" >/dev/null ||
    die "app launcher did not write cube output to cube log"

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

  printf '[2026-01-01T00:00:00Z] app launch app=terminal owner=engineos-shell display=engineos-test-wayland\n' >>"$log_dir/app.log"
  {
    printf '[2026-01-01T00:00:00Z] bootstrap mode=launchpad\n'
    printf '[2026-01-01T00:00:01Z] launchpad active slot=cube mode=terminal capture=none reason=bootstrap-launchpad\n'
    printf '[2026-01-01T00:00:02Z] view mapped role=cube title=engineos-cube app_id=engineos-cube mapped_total=1\n'
  } >"$log_dir/shell.log"
  ENGINEOS_LOG_DIR="$log_dir" ENGINEOS_STATE_DIR="$tmp_dir/run" \
    "$SCRIPT_DIR/app.sh" status --json >"$out"
  grep -F '"active_slot":"cube"' "$out" >/dev/null ||
    die "app status json did not report active cube slot"
  grep -F '"manifest": "' "$out" >/dev/null ||
    die "app status json did not report manifest path"
  grep -F '"terminal": {"app":"terminal","command":"engineos app launch terminal","launch_state":"launch-requested"' "$out" >/dev/null ||
    die "app status json did not report terminal launch state"
  grep -F '"cube": {"app":"cube","command":"engineos app launch cube","launch_state":"launch-requested","mapped":true' "$out" >/dev/null ||
    die "app status json did not report mapped cube state"
  grep -F '"shell_last_log":"[2026-01-01T00:00:02Z] view mapped role=cube title=engineos-cube app_id=engineos-cube mapped_total=1"' "$out" >/dev/null ||
    die "app status json did not report shell lifecycle evidence"
  [[ -f "$tmp_dir/run/apps/cube.status" ]] ||
    die "app launcher did not write cube state record"

  "$SCRIPT_DIR/app.sh" manifest validate >"$out"
  grep -F 'App manifest validation summary: 0 failure(s)' "$out" >/dev/null ||
    die "app manifest validation did not pass"
  grep -F 'cube.app_ids contains engineos-cube' "$out" >/dev/null ||
    die "app manifest validation did not check cube app id"

  printf 'app launcher smoke test passed\n'
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
  if [[ -e /usr/artifacts ]]; then
    die "quake installed-mode smoke created /usr/artifacts"
  fi

  local installed_root="$tmp_dir/installed-prefix/usr"
  local installed_script_dir="$tmp_dir/installed-scripts"
  local installed_env_out="$tmp_dir/installed-env.txt"
  mkdir -p "$installed_root/bin" "$installed_root/lib/engineos/scripts" "$installed_root/tools/scripts" "$installed_script_dir"
  cp "$ROOT/tools/engineos/engineos" "$installed_root/bin/engineos"
  cat >"$installed_script_dir/terminal_launcher.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$ENGINEOS_LOG_DIR" >"$installed_env_out"
EOF
  chmod +x "$installed_root/bin/engineos" "$installed_script_dir/terminal_launcher.sh"
  env -u ENGINEOS_LOG_DIR \
    ENGINEOS_ROOT="$installed_root" \
    ENGINEOS_SCRIPT_DIR="$installed_script_dir" \
    "$ROOT/tools/engineos/engineos" terminal >/dev/null
  [[ "$(cat "$installed_env_out")" == "/var/log/engineos" ]] ||
    die "engineos installed-prefix default log dir was not /var/log/engineos"
  if [[ -e "$installed_root/artifacts" ]]; then
    die "engineos installed-prefix default created artifacts under installed root"
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
  local engineos_cmd=""
  local runtime_login_profile=""
  local runtime_issue=""

  cleanup_reliability() {
    ENGINEOS_STATE_DIR="$tmp_dir/run" ENGINEOS_LOG_DIR="$log_dir" "$SCRIPT_DIR/engine_runner.sh" daemon-stop >/dev/null 2>&1 || true
    rm -rf "$tmp_dir"
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

  if command -v engineos >/dev/null 2>&1; then
    engineos_cmd="$(command -v engineos)"
  elif [[ -x "$ROOT/tools/engineos/engineos" ]]; then
    engineos_cmd="$ROOT/tools/engineos/engineos"
  fi
  [[ -x "$engineos_cmd" ]] || die "engineos command is not executable"

  "$recovery_help" >"$tmp_dir/recovery-help.txt"
  grep -F 'engineos logs runtime --last 200' "$tmp_dir/recovery-help.txt" >/dev/null ||
    die "runtime recovery helper does not point to runtime logs"
  grep -F 'engineos crash-bundle' "$tmp_dir/recovery-help.txt" >/dev/null ||
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
  grep -F 'engineos logs runtime --last 200' "$runtime_issue" >/dev/null ||
    die "runtime issue does not point to runtime logs"

  printf 'shell failure marker\n' >"$log_dir/shell.log"
  printf 'engine failure marker\n' >"$log_dir/engine.log"
  printf 'ENGINEOS_RUNTIME_AUTOSTART=1\nENGINEOS_RUNTIME_SHELL_MODE=--headless\n' >"$runtime_conf"
  cat >"$fake_bin/engineos" <<'FAKE'
#!/usr/bin/env bash
printf 'fake engineos failure: %s\n' "$*" >&2
exit 77
FAKE
  chmod +x "$fake_bin/engineos"
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
      ENGINEOS_CMD="$fake_bin/engineos" \
      "$runtime_start" >/dev/null 2>&1; then
    die "reliability test expected runtime shell failure"
  fi

  grep -F 'EngineOS shell failed rc=77' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime failure was not logged"
  grep -F 'recovery hint: switch to tty2 and run engineos-recovery-help' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime failure log did not include recovery helper hint"
  grep -F 'recovery logs: engineos logs runtime --last 200' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime failure log did not include runtime logs hint"
  grep -F 'recovery bundle: engineos crash-bundle' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime failure log did not include crash bundle hint"

  printf 'ENGINEOS_RUNTIME_AUTOSTART=0\nENGINEOS_RUNTIME_SHELL_MODE=--headless\n' >"$runtime_conf"
  if ! ENGINEOS_LOG_DIR="$log_dir" \
      ENGINEOS_RUNTIME_CONF="$runtime_conf" \
      ENGINEOS_CMD="$fake_bin/engineos" \
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
      ENGINEOS_CMD="$fake_bin/engineos" \
      "$runtime_start" >/dev/null 2>&1; then
    die "reliability test expected runtime kernel disable to succeed"
  fi
  grep -F 'runtime autostart disabled by kernel command line' "$log_dir/runtime-start.log" >/dev/null ||
    die "runtime kernel disable was not logged"
  grep -F 'recovery logs: engineos logs runtime --last 200' "$log_dir/runtime-start.log" >/dev/null ||
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

  rm -f "$fake_bin/engineos"
  HOME="$tmp_dir/home" \
    ENGINEOS_STATE_DIR="$tmp_dir/run" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_CRASH_BUNDLE_DIR="$bundle_dir" \
    ENGINEOS_DRM_SYSFS="$drm_sysfs" \
    PATH="$fake_bin:$PATH" \
    "$engineos_cmd" crash-bundle --runtime >/dev/null

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
  grep -F 'recovery bundle: engineos crash-bundle' "$bundle_dir/logs/runtime-start.log" >/dev/null ||
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

  ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/engineos" logs shell --last 1 --files >"$out"
  grep -F 'shell newest line' "$out" >/dev/null ||
    die "logs shell did not include newest shell line"
  if grep -F 'shell old line' "$out" >/dev/null; then
    die "logs shell --last 1 included older shell line"
  fi

  ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/engineos" logs runtime --files >"$out"
  grep -F 'runtime marker' "$out" >/dev/null ||
    die "logs runtime did not include runtime-start log"

  ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/engineos" logs all --files >"$out"
  grep -F 'engine marker' "$out" >/dev/null ||
    die "logs all did not include engine log"
  grep -F 'doctor marker' "$out" >/dev/null ||
    die "logs all did not include doctor firstboot log"

  ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/engineos" logs boot --files >"$out"
  grep -F 'No file log target for boot; use --journal.' "$out" >/dev/null ||
    die "logs boot --files did not explain journal usage"

  if ENGINEOS_LOG_DIR="$log_dir" "$ROOT/tools/engineos/engineos" logs nonsense >/dev/null 2>&1; then
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
  grep -F 'engineos outputs validate --single' "$report" >/dev/null ||
    die "release report missing output validation proof item"
  grep -F 'engineos proof launchpad --runtime' "$report" >/dev/null ||
    die "release report missing launchpad proof item"
  grep -F 'engineos app manifest validate' "$report" >/dev/null ||
    die "release report missing app manifest proof item"
  grep -F 'engineos terminal' "$report" >/dev/null ||
    die "release report missing terminal proof item"
  grep -F 'engineos crash-bundle --bare-metal' "$report" >/dev/null ||
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
  chmod +x "$fake_bin/alacritty"

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
    ENGINEOS_TERMINAL_CANDIDATES="alacritty" \
    ENGINEOS_TERMINAL_SESSION_CMD="tmux new -A -s engineos" \
    WAYLAND_DISPLAY="engineos-test-wayland" \
    "$SCRIPT_DIR/terminal_launcher.sh" >/dev/null
  grep -F 'alacritty -- zsh -lc exec tmux new -A -s engineos' "$launched" >/dev/null ||
    die "terminal launcher did not start tmux session through zsh"
  grep -F 'session command=tmux new -A -s engineos' "$log_dir/terminal.log" >/dev/null ||
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
    "$ROOT/tools/engineos/engineos" terminal --dry-run >"$out"
  grep -F 'command: alacritty' "$out" >/dev/null ||
    die "engineos terminal did not route to terminal launcher"

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

  "$SCRIPT_DIR/vm.sh" boot enginedev --dry-run --out-dir "$tmp_dir/out" --memory 1024 --cpus 1 --display none --no-kvm >"$out"
  grep -F 'engineos proof booted-iso --vm' "$out" >/dev/null ||
    die "enginedev VM dry-run did not print VM proof command"
  grep -F 'display:  none' "$out" >/dev/null ||
    die "enginedev VM dry-run did not print selected display backend"
  if grep -F 'OVMF_CODE' "$out" >/dev/null; then
    die "enginedev VM dry-run used pflash OVMF_CODE as a -bios image"
  fi
  env -u WAYLAND_DISPLAY -u DISPLAY "$SCRIPT_DIR/vm.sh" boot enginedev --dry-run --iso "$dev_iso" --memory 1024 --cpus 1 --no-kvm >"$out"
  grep -F 'display:  none' "$out" >/dev/null ||
    die "enginedev VM dry-run did not default to headless display without a graphical session"
  "$SCRIPT_DIR/vm.sh" boot enginedev --dry-run --iso "$dev_iso" --memory 1024 --cpus 1 --display none --background --no-kvm >"$out"
  grep -F -- '-daemonize' "$out" >/dev/null ||
    die "enginedev VM background dry-run did not daemonize QEMU"
  grep -F 'qemu-enginedev-serial.log' "$out" >/dev/null ||
    die "enginedev VM background dry-run did not print serial log path"
  "$SCRIPT_DIR/vm.sh" boot enginedev --dry-run --iso "$dev_iso" --memory 1024 --cpus 1 --display none --no-kvm >"$out"
  grep -F 'profile:  enginedev' "$out" >/dev/null ||
    die "enginedev VM dry-run did not print selected profile"

  "$SCRIPT_DIR/vm.sh" boot engineruntime --dry-run --out-dir "$tmp_dir/out" --memory 1024 --cpus 1 --display none --no-kvm >"$out"
  grep -F 'engineos proof booted-iso --runtime' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not print runtime proof command"
  "$SCRIPT_DIR/vm.sh" boot engineruntime --dry-run --iso "$runtime_iso" --memory 1024 --cpus 1 --display none --no-kvm >"$out"
  grep -F 'profile:  engineruntime' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not print selected profile"
  "$SCRIPT_DIR/vm.sh" boot engineruntime --dry-run --iso "$runtime_iso" --memory 1024 --cpus 1 --display none --audio hda --no-kvm >"$out"
  grep -F 'audio:    hda' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not print selected audio mode"
  grep -F -- '-device ich9-intel-hda' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not include HDA controller"
  grep -F -- '-device hda-duplex\,audiodev=audio0' "$out" >/dev/null ||
    die "engineruntime VM dry-run did not include HDA duplex codec"

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

  "$SCRIPT_DIR/usb.sh" list >/dev/null
  "$SCRIPT_DIR/usb.sh" write --dry-run --iso "$iso" --device /dev/engineos-test-usb >/dev/null
  "$SCRIPT_DIR/usb.sh" write --dry-run --profile engineruntime --out-dir "$tmp_dir/out" --device /dev/engineos-test-usb >/dev/null

  if "$SCRIPT_DIR/usb.sh" write --iso "$iso" --device /dev/engineos-test-usb >/dev/null 2>&1; then
    die "usb write should require explicit destructive acknowledgement outside dry-run"
  fi

  printf 'usb write dry-run test passed\n'
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
  "$SCRIPT_DIR/install_dev.sh" dev \
    --dry-run \
    --device /dev/engineos-test-disk \
    --target "$target" \
    --repo-url https://example.invalid/tang-os.git \
    --branch main >"$out"

  grep -F 'EngineOS EngineDev autoinstall plan' "$out" >/dev/null ||
    die "install dry-run missing plan header"
  grep -F 'device:   /dev/engineos-test-disk' "$out" >/dev/null ||
    die "install dry-run missing target device"
  grep -F 'persistent /srv workspace' "$out" >/dev/null ||
    die "install dry-run missing persistent /srv plan"
  grep -F 'cache:    /opt/engineos/install-cache/pkg' "$out" >/dev/null ||
    die "install dry-run missing ISO package cache plan"
  grep -F 'repo auth: none; clone runs non-interactively' "$out" >/dev/null ||
    die "install dry-run missing repo auth plan"
  grep -F 'env GIT_TERMINAL_PROMPT=0 git clone https://example.invalid/tang-os.git /srv/engineos' "$out" >/dev/null ||
    die "install dry-run missing official repo clone"
  grep -F 'setup_dev_environment.sh --payload /srv/engineos/tools/post-install-payload --user dev' "$out" >/dev/null ||
    die "install dry-run missing post-install payload handoff"
  grep -F 'proof booted-iso --bare-metal' "$out" >/dev/null ||
    die "install dry-run missing bare-metal handoff proof"

  printf 'fake-token\n' >"$token_file"
  "$SCRIPT_DIR/install_dev.sh" dev \
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
mkdir -p "$target/etc/pacman.d" "$target/etc/sudoers.d" "$target/boot" "$target/srv"
printf '[options]\n' >"$target/etc/pacman.conf"
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
    "$SCRIPT_DIR/install_dev.sh" dev \
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
  grep -F 'pacstrap -c -C ' "$log" >/dev/null ||
    die "install executor did not run pacstrap with cached host package mode"
  grep -F "CacheDir = $package_cache" /tmp/engineos-install-pacman-*.conf >/dev/null ||
    die "install executor did not generate cached pacman config"
  grep -F 'cp -a '"$seed"'/. '"$target"'/tmp/tang-os-seed/' "$log" >/dev/null ||
    die "install executor did not stage seed repo"
  grep -F 'arch-chroot '"$target"' env GIT_TERMINAL_PROMPT=0 git clone file:///tmp/tang-os-seed /srv/engineos' "$log" >/dev/null ||
    die "install executor did not clone seed repo in target"
  grep -F 'arch-chroot '"$target"' /srv/engineos/tools/post-install-payload/scripts/setup_dev_environment.sh' "$log" >/dev/null ||
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
    "$SCRIPT_DIR/install_dev.sh" dev \
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
    "$SCRIPT_DIR/install_dev.sh" dev \
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

  if "$SCRIPT_DIR/install_dev.sh" dev --device /dev/engineos-test-disk >/dev/null 2>&1; then
    die "install real mode should require explicit wipe acknowledgement"
  fi

  printf 'EngineDev installer dry-run test passed\n'
}

run_proof() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-proof-test-$$"

  cleanup_proof() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_proof RETURN

  mkdir -p "$tmp_dir/logs"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$SCRIPT_DIR/proof.sh" release-candidate --dry-run --out-dir "$tmp_dir/out" >"$tmp_dir/release-candidate.txt"
  grep -F 'build EngineRuntime ISO dry-run' "$tmp_dir/release-candidate.txt" >/dev/null ||
    die "release-candidate proof did not include EngineRuntime ISO dry-run"
  grep -F 'release checklist' "$tmp_dir/release-candidate.txt" >/dev/null ||
    die "release-candidate proof did not run release checklist"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$SCRIPT_DIR/proof.sh" hardware-ready --dry-run --profile engineruntime --out-dir "$tmp_dir/out" --device /dev/engineos-test-usb >"$tmp_dir/hardware-ready.txt"
  grep -F 'engineos usb write --profile engineruntime' "$tmp_dir/hardware-ready.txt" >/dev/null ||
    die "hardware-ready proof did not include runtime USB write dry-run"
  grep -F 'engineos proof booted-iso --bare-metal' "$tmp_dir/hardware-ready.txt" >/dev/null ||
    die "hardware-ready proof did not point to bare-metal proof"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$SCRIPT_DIR/proof.sh" booted-iso --vm --dry-run >"$tmp_dir/booted-vm.txt"
  grep -F 'Quake smoke dry-run' "$tmp_dir/booted-vm.txt" >/dev/null ||
    die "booted VM proof did not include Quake smoke step"
  grep -F 'engineos logs engine --last 200' "$tmp_dir/booted-vm.txt" >/dev/null ||
    die "booted VM proof did not include engine log step"
  grep -F 'engineos crash-bundle --vm' "$tmp_dir/booted-vm.txt" >/dev/null ||
    die "booted VM proof did not include VM crash bundle mode"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$SCRIPT_DIR/proof.sh" booted-iso --runtime --dry-run >"$tmp_dir/booted-runtime.txt"
  grep -F 'runtime reliability dry-run' "$tmp_dir/booted-runtime.txt" >/dev/null ||
    die "booted runtime proof did not include runtime reliability step"
  grep -F 'engineos logs runtime --last 200' "$tmp_dir/booted-runtime.txt" >/dev/null ||
    die "booted runtime proof did not include runtime log step"
  grep -F 'engineos crash-bundle --runtime' "$tmp_dir/booted-runtime.txt" >/dev/null ||
    die "booted runtime proof did not include runtime crash bundle mode"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$SCRIPT_DIR/proof.sh" booted-iso --bare-metal --dry-run >"$tmp_dir/booted-bare-metal.txt"
  grep -F 'engineos outputs validate --single' "$tmp_dir/booted-bare-metal.txt" >/dev/null ||
    die "booted bare-metal proof did not include explicit output validation"
  grep -F 'engineos crash-bundle --bare-metal' "$tmp_dir/booted-bare-metal.txt" >/dev/null ||
    die "booted bare-metal proof did not include bare-metal crash bundle mode"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$SCRIPT_DIR/proof.sh" shell-launch --runtime --dry-run >"$tmp_dir/shell-launch.txt"
  grep -F 'Shell-launch proof dry-run completed' "$tmp_dir/shell-launch.txt" >/dev/null ||
    die "shell-launch proof dry-run did not complete"
  grep -F 'grep -E' "$tmp_dir/shell-launch.txt" | grep -F 'renderer diagnostics' >/dev/null ||
    die "shell-launch proof did not check renderer diagnostics"
  grep -F 'owner=engineos-shell' "$tmp_dir/shell-launch.txt" >/dev/null ||
    die "shell-launch proof did not check shell-owned launch markers"
  ENGINEOS_LOG_DIR="$tmp_dir/logs" "$SCRIPT_DIR/proof.sh" launchpad --runtime --dry-run >"$tmp_dir/launchpad.txt"
  grep -F 'Launchpad proof dry-run completed' "$tmp_dir/launchpad.txt" >/dev/null ||
    die "launchpad proof dry-run did not complete"
  grep -F 'engineos app status --json' "$tmp_dir/launchpad.txt" >/dev/null ||
    die "launchpad proof did not check structured app status"
  grep -F 'engineos app manifest validate' "$tmp_dir/launchpad.txt" >/dev/null ||
    die "launchpad proof did not validate app manifest"
  grep -F 'app=(terminal|cube|quake)' "$tmp_dir/launchpad.txt" >/dev/null ||
    die "launchpad proof did not check all app ownership markers"

  local launchpad_logs="$tmp_dir/launchpad-logs"
  local launchpad_state="$tmp_dir/launchpad-state"
  mkdir -p "$launchpad_logs" "$launchpad_state"
  {
    printf '[2026-01-01T00:00:00Z] engineos-shell mode=tty backend=drm,libinput wayland_display=wayland-1\n'
    printf '[2026-01-01T00:00:01Z] bootstrap mode=launchpad\n'
    printf '[2026-01-01T00:00:02Z] launchpad active slot=cube mode=terminal capture=none reason=bootstrap-launchpad\n'
    printf '[2026-01-01T00:00:03Z] launch action label=bootstrap-terminal role=terminal pid=100 command=engineos app launch terminal\n'
    printf '[2026-01-01T00:00:04Z] launch action label=bootstrap-cube role=cube pid=101 command=engineos app launch cube\n'
    printf '[2026-01-01T00:00:05Z] launch action label=bootstrap-engine role=engine pid=102 command=engineos app launch quake\n'
    printf '[2026-01-01T00:00:06Z] view mapped role=cube title=engineos-cube app_id=engineos-cube mapped_total=1\n'
    printf '[2026-01-01T00:00:07Z] launch action exit label=bootstrap-engine role=engine pid=102 status=exited code=1 mapped=false command=engineos app launch quake\n'
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
  ENGINEOS_LOG_DIR="$launchpad_logs" ENGINEOS_STATE_DIR="$launchpad_state" \
    "$SCRIPT_DIR/proof.sh" launchpad --runtime >"$tmp_dir/launchpad-real.txt"
  grep -F 'Launchpad proof runner completed' "$tmp_dir/launchpad-real.txt" >/dev/null ||
    die "launchpad proof did not pass with fixture logs"

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
  "$SCRIPT_DIR/validate_builder.sh" --mock >/dev/null
  printf 'builder validation mock test passed\n'
}

run_builder_handoff() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-builder-handoff-$$"
  local out="$tmp_dir/handoff.txt"

  cleanup_builder_handoff() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_builder_handoff RETURN

  mkdir -p "$tmp_dir"

  "$SCRIPT_DIR/builder_handoff.sh" --dry-run --host dev@192.0.2.10 --dest /srv/engineos >"$out"
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
  grep -F './tools/engineos/engineos\ bootstrap\ builder' "$out" >/dev/null ||
    die "builder handoff dry-run did not include bootstrap"
  grep -F './tools/engineos/engineos\ validate\ builder' "$out" >/dev/null ||
    die "builder handoff dry-run did not include builder validation"
  grep -F './tools/engineos/engineos\ build\ repo' "$out" >/dev/null ||
    die "builder handoff dry-run did not include real repo build"
  grep -F './tools/engineos/engineos\ validate\ repo' "$out" >/dev/null ||
    die "builder handoff dry-run did not include repo validation"
  if grep -F -- '--delete' "$out" >/dev/null; then
    die "builder handoff dry-run should not delete remote files by default"
  fi

  "$SCRIPT_DIR/builder_handoff.sh" --dry-run --host dev@192.0.2.10 --skip-bootstrap >"$out"
  if grep -F './tools/engineos/engineos\ bootstrap\ builder' "$out" >/dev/null; then
    die "builder handoff --skip-bootstrap still included bootstrap"
  fi

  "$SCRIPT_DIR/builder_handoff.sh" --dry-run --host dev@192.0.2.10 --run-proof >"$out"
  grep -F './tools/engineos/engineos\ bootstrap\ builder' "$out" >/dev/null ||
    die "builder handoff --run-proof did not include bootstrap"
  grep -F './tools/engineos/engineos\ proof\ build-lab' "$out" >/dev/null ||
    die "builder handoff --run-proof did not include build-lab proof"
  grep -F 'Next real command: ./tools/engineos/engineos builder handoff --host dev@192.0.2.10 --run-proof' "$out" >/dev/null ||
    die "builder handoff --run-proof did not preserve the real command hint"

  if "$SCRIPT_DIR/builder_handoff.sh" --host dev@192.0.2.10 --dest relative/path >/dev/null 2>&1; then
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
  "$SCRIPT_DIR/builder_doctor_proof.sh" --dry-run --host dev@192.0.2.10 --guest-port 2223 >"$out"
  grep -F 'dev@192.0.2.10' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include builder ssh target"
  grep -F './tools/engineos/engineos proof build-lab' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include build-lab proof"
  grep -F -- '-p\ 2223' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include guest ssh port"
  grep -F 'dev@127.0.0.1' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include guest ssh target"
  grep -F 'engineos\\\ doctor\\\ --vm' "$out" >/dev/null ||
    die "builder doctor proof dry-run did not include VM doctor command"

  "$SCRIPT_DIR/builder_doctor_proof.sh" --dry-run --host dev@192.0.2.10 --skip-build >"$out"
  if grep -F 'run builder build proof' "$out" >/dev/null; then
    die "builder doctor proof --skip-build still ran build-lab proof"
  fi
  grep -F 'engineos\\\ doctor\\\ --vm' "$out" >/dev/null ||
    die "builder doctor proof --skip-build did not include VM doctor command"

  printf 'builder doctor proof dry-run test passed\n'
}

run_post_first_deploy() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-post-first-deploy-test-$$"
  local out="$tmp_dir/post-first-deploy.txt"

  cleanup_post_first_deploy() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_post_first_deploy RETURN

  mkdir -p "$tmp_dir"
  "$SCRIPT_DIR/post_first_deploy.sh" --dry-run --host dev@192.0.2.55 --port 2225 >"$out"
  grep -F 'EngineOS post-first-deploy dry-run' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing header"
  grep -F 'dev@192.0.2.55' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing guest host"
  grep -F -- '-P 2225' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing scp port"
  grep -F 'tools/post-install-payload' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing payload path"
  grep -F 'setup_dev_environment.sh' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing remote setup script"
  grep -F -- '--payload' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing setup payload argument"
  grep -F 'Next real command: engineos deploy first --host dev@192.0.2.55 --port 2225' "$out" >/dev/null ||
    die "post-first-deploy dry-run missing real command hint"

  "$SCRIPT_DIR/post_first_deploy.sh" --dry-run --host dev@192.0.2.55 --skip-codex --skip-docker --skip-pacman >"$out"
  grep -F -- '--skip-codex' "$out" >/dev/null ||
    die "post-first-deploy dry-run did not preserve --skip-codex"
  grep -F -- '--skip-docker' "$out" >/dev/null ||
    die "post-first-deploy dry-run did not preserve --skip-docker"
  grep -F -- '--skip-pacman' "$out" >/dev/null ||
    die "post-first-deploy dry-run did not preserve --skip-pacman"

  [[ -f "$ROOT/tools/post-install-payload/assets/tmux.conf" ]] ||
    die "post-first-deploy payload missing tmux config"
  grep -F 'set -g mouse on' "$ROOT/tools/post-install-payload/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not enable mouse support"
  grep -F "@engineos-plugins" "$ROOT/tools/post-install-payload/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not declare packaged plugins"
  grep -F "/usr/share/tmux/plugins/tmux-sensible/sensible.tmux" "$ROOT/tools/post-install-payload/assets/tmux.conf" >/dev/null ||
    die "post-first-deploy tmux config does not source packaged plugins"
  [[ -f "$ROOT/tools/post-install-payload/assets/zshrc" ]] ||
    die "post-first-deploy payload missing zsh config"
  [[ -f "$ROOT/tools/post-install-payload/assets/zprofile" ]] ||
    die "post-first-deploy payload missing zprofile config"
  grep -F '/usr/share/oh-my-zsh' "$ROOT/tools/post-install-payload/assets/zshrc" >/dev/null ||
    die "post-first-deploy zsh config does not use packaged oh-my-zsh"
  grep -F 'zsh-autosuggestions.zsh' "$ROOT/tools/post-install-payload/assets/zshrc" >/dev/null ||
    die "post-first-deploy zsh config does not source packaged plugins"
  grep -F 'tmux new-session -A -s engineos' "$ROOT/tools/post-install-payload/assets/zprofile" >/dev/null ||
    die "post-first-deploy zprofile does not auto-attach tmux"
  [[ -f "$ROOT/tools/post-install-payload/assets/docker/daemon.json" ]] ||
    die "post-first-deploy payload missing Docker config"
  [[ -x "$ROOT/tools/post-install-payload/scripts/setup_dev_environment.sh" ]] ||
    die "post-first-deploy payload setup script is not executable"
  [[ -x "$ROOT/tools/post-install-payload/scripts/engineos-dev-shell-start" ]] ||
    die "post-first-deploy payload dev shell start script is not executable"
  [[ -f "$ROOT/tools/post-install-payload/assets/systemd/engineos-dev-shell.service" ]] ||
    die "post-first-deploy payload missing dev shell service"
  grep -F 'ENGINEOS_TERMINAL_REQUIRE_WAYLAND=true' "$ROOT/tools/post-install-payload/assets/systemd/engineos-dev-shell.service" >/dev/null ||
    die "post-first-deploy dev shell service does not require Wayland terminal ownership"
  grep -F 'ENGINEOS_TERMINAL_SESSION_CMD=tmux new -A -s engineos' "$ROOT/tools/post-install-payload/assets/systemd/engineos-dev-shell.service" >/dev/null ||
    die "post-first-deploy dev shell service does not launch tmux"
  grep -F 'engineos-shell' "$ROOT/tools/post-install-payload/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not request engineos-shell"
  grep -F 'engineos-cube' "$ROOT/tools/post-install-payload/scripts/setup_dev_environment.sh" >/dev/null ||
    die "post-first-deploy setup does not request engineos-cube"

  printf 'post-first-deploy dry-run test passed\n'
}

run_bootstrap() {
  "$SCRIPT_DIR/bootstrap_builder.sh" --dry-run >/dev/null
  "$SCRIPT_DIR/bootstrap_builder.sh" --print-packages | grep -Fx 'archiso' >/dev/null ||
    die "builder bootstrap package list missing archiso"
  "$SCRIPT_DIR/bootstrap_builder.sh" --print-packages | grep -Fx 'wlroots0.19' >/dev/null ||
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
  grep -F 'packages/engineos-quakespasm' "$out" >/dev/null ||
    die "repo dry-run did not include engineos-quakespasm"

  "$SCRIPT_DIR/validate_repo.sh" --mock >/dev/null
  "$SCRIPT_DIR/validate_repo.sh" --dry-run >"$out"
  grep -F 'engineos-quakespasm-*.pkg.tar.*' "$out" >/dev/null ||
    die "repo validation dry-run did not expect engineos-quakespasm artifact"
  printf 'repo validation smoke test passed\n'
}

run_boot() {
  local tmp_dir="${TMPDIR:-/tmp}/engineos-boot-test-$$"
  local fake_bin="$tmp_dir/bin"
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

  mkdir -p "$fake_bin" "$log_dir" "$drm_sysfs/card0-HDMI-A-1" "$dri_dir"
  {
    printf 'ENGINEOS_SHELL_BOOTSTRAP=launchpad\n'
    printf 'ENGINEOS_CUBE_CMD="engineos app launch cube"\n'
    printf 'ENGINEOS_ENGINE_CMD="engineos app launch quake"\n'
    printf 'ENGINEOS_RUNTIME_RECOVERY_TTY=tty2\n'
    printf 'ENGINEOS_TERMINAL_SESSION_CMD="tmux new -A -s engineos"\n'
  } >"$runtime_conf"
  cat >"$apps_manifest" <<'EOF_MANIFEST'
[apps.terminal]
slot = "terminal"
role = "terminal"
command = "engineos app launch terminal"
package = "foot"
app_ids = ["foot"]
log = "terminal.log"
input = "normal"

[apps.cube]
slot = "cube"
role = "cube"
command = "engineos app launch cube"
smoke_command = "engineos app launch cube --smoke"
package = "engineos-cube"
app_ids = ["engineos-cube"]
log = "cube.log"
health = "gl-renderer-and-frames"
input = "normal"

[apps.quake]
slot = "engine"
role = "engine"
command = "engineos app launch quake"
smoke_command = "engineos app launch quake --smoke"
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
[[ "$1" == "-Q" ]] && exit 0
printf 'fake pacman: %s\n' "$*" >&2
exit 2
FAKE
  chmod +x "$fake_bin/pacman"

  cat >"$fake_bin/engineos" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "app" && "$2" == "manifest" && "$3" == "validate" ]]; then
  printf 'EngineOS app manifest validation\n'
  printf '  manifest: %s\n' "${ENGINEOS_APPS_MANIFEST:-missing}"
  printf 'OK   cube.app_ids contains engineos-cube\n'
  printf 'App manifest validation summary: 0 failure(s)\n'
  exit 0
fi
printf 'fake engineos %s\n' "$*"
FAKE
  chmod +x "$fake_bin/engineos"

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
printf 'engineos logs runtime --last 200\n'
printf 'engineos crash-bundle\n'
printf 'engineos.noautostart\n'
FAKE
  chmod +x "$fake_bin/engineos-recovery-help"

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

  PATH="$fake_bin:$PATH" \
    ENGINEOS_RUNTIME_CONF="$runtime_conf" \
    ENGINEOS_APPS_MANIFEST="$apps_manifest" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
    ENGINEOS_FAKE_DOCTOR_ARGS="$doctor_log" \
    "$SCRIPT_DIR/validate_boot.sh" --runtime >"$out"
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

  printf '[2026-01-01T00:00:00Z] starting EngineOS shell mode=--tty recovery=tty2\n' >"$log_dir/runtime-start.log"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_RUNTIME_CONF="$runtime_conf" \
    ENGINEOS_APPS_MANIFEST="$apps_manifest" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
    ENGINEOS_FAKE_DOCTOR_ARGS="$doctor_log" \
    "$SCRIPT_DIR/validate_boot.sh" --runtime >"$out"
  grep -F 'runtime shell service active: engineos-runtime.service' "$out" >/dev/null ||
    die "runtime boot validation did not accept active runtime shell service"
  if grep -F 'runtime autostart appears to still be running' "$out" >/dev/null; then
    die "runtime boot validation warned for active runtime shell service"
  fi

  : >"$doctor_log"
  PATH="$fake_bin:$PATH" \
    ENGINEOS_RUNTIME_CONF="$runtime_conf" \
    ENGINEOS_APPS_MANIFEST="$apps_manifest" \
    ENGINEOS_LOG_DIR="$log_dir" \
    ENGINEOS_DRI_DIR="$dri_dir" \
    ENGINEOS_DRM_SYSFS="$drm_sysfs" \
    ENGINEOS_DOCTOR_CMD="$fake_bin/doctor-ok" \
    ENGINEOS_FAKE_DOCTOR_ARGS="$doctor_log" \
    "$SCRIPT_DIR/validate_boot.sh" --bare-metal >"$out"
  grep -F "$dri_dir exists" "$out" >/dev/null ||
    die "bare-metal boot validation did not use DRI fixture"
  grep -F 'at least one connected DRM output' "$out" >/dev/null ||
    die "bare-metal boot validation did not validate connected DRM output"
  grep -F 'AMD display device visible to lspci' "$out" >/dev/null ||
    die "bare-metal boot validation did not verify AMD display fixture"
  grep -Fx -- '--bare-metal' "$doctor_log" >/dev/null ||
    die "bare-metal boot validation did not call doctor in bare-metal mode"

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
    "$ROOT/tools/engineos/engineos" fetch engine quake --dry-run >"$fetch_out"
  grep -F 'QuakeSpasm fetch dry-run' "$fetch_out" >/dev/null ||
    die "engine fetch dry-run missing marker"
  grep -F 'fetch.sh --status' "$fetch_out" >/dev/null ||
    die "engine fetch dry-run did not point to status"

  QUAKESPASM_UPSTREAM_DIR="$tmp_dir/upstream" \
    "$ROOT/tools/engineos/engineos" fetch engine quake --status >"$fetch_out"
  grep -F 'state:    missing' "$fetch_out" >/dev/null ||
    die "engine fetch status did not report missing checkout"
  mkdir -p "$tmp_dir/upstream"
  QUAKESPASM_UPSTREAM_DIR="$tmp_dir/upstream" \
    "$ROOT/tools/engineos/engineos" fetch engine quake --status >"$fetch_out"
  grep -F 'state:    empty-directory' "$fetch_out" >/dev/null ||
    die "engine fetch status did not report empty checkout directory"

  "$SCRIPT_DIR/build_engine.sh" quake --dry-run >"$fetch_out"
  grep -F 'MP3LIB=mpg123' "$fetch_out" >/dev/null ||
    die "engine build dry-run did not select mpg123"
  grep -F 'VORBISLIB=vorbis' "$fetch_out" >/dev/null ||
    die "engine build dry-run did not select vorbis"

  "$SCRIPT_DIR/validate_engine.sh" quake --mock >/dev/null
  "$SCRIPT_DIR/validate_engine.sh" quake >/dev/null
  printf 'engine validation smoke test passed\n'
}

run_shell() {
  "$SCRIPT_DIR/validate_shell.sh" --mock >/dev/null
  "$SCRIPT_DIR/validate_shell.sh" >/dev/null
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

  printf 'render smoke test passed\n'
}

case "$SCOPE" in
  smoke)
    run_smoke
    ;;
  all)
    run_all
    ;;
  compositor)
    run_compositor "$@"
    ;;
  shell-actions)
    run_shell_actions
    ;;
  engine-runner-env)
    run_engine_runner_env
    ;;
  app)
    run_app
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
  install)
    run_install
    ;;
  proof)
    run_proof
    ;;
  installed-preflight)
    run_installed_preflight
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
