#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -n "${ENGINEOS_SCRIPT_DIR:-}" ]]; then
  SCRIPT_DIR="$ENGINEOS_SCRIPT_DIR"
else
  SCRIPT_DIR="$(cd "$MODULE_DIR/../../scripts" && pwd -P)"
fi
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

MODE=""
FAILURES=0
WARNINGS=0
RUNTIME_CONF="${ENGINEOS_RUNTIME_CONF:-/etc/engineos/runtime.conf}"
APPS_MANIFEST="${ENGINEOS_APPS_MANIFEST:-$(engineos_apps_manifest "$(engineos_root)")}"
LOG_DIR="${ENGINEOS_LOG_DIR:-/var/log/engineos}"
SHELL_LOG="${ENGINEOS_SHELL_LOG:-$LOG_DIR/shell.log}"
DRI_DIR="${ENGINEOS_DRI_DIR:-/dev/dri}"
DRM_SYSFS="${ENGINEOS_DRM_SYSFS:-/sys/class/drm}"
DOCTOR_CMD="${ENGINEOS_DOCTOR_CMD:-$SCRIPT_DIR/doctor.sh}"
APP_MANIFEST_OUT="${ENGINEOS_APP_MANIFEST_OUT:-/tmp/engineos-app-manifest-validate.txt}"
VALIDATE_DOCTOR_OUT="${ENGINEOS_VALIDATE_DOCTOR_OUT:-/tmp/engineos-validate-doctor.txt}"
VALIDATE_OUTPUTS_OUT="${ENGINEOS_VALIDATE_OUTPUTS_OUT:-/tmp/engineos-validate-outputs.txt}"

usage() {
  cat <<'HELP'
Usage: validate_boot.sh [--vm|--runtime|--bare-metal]

Validate the booted EngineOS environment. This is meant to run inside a
generated ISO, but it also reports useful warnings when run elsewhere.
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

service_check() {
  local unit="$1"
  if ! have_cmd systemctl; then
    fail "systemctl unavailable; cannot check $unit"
    return
  fi
  if systemctl is-enabled "$unit" >/dev/null 2>&1; then
    ok "$unit enabled"
  else
    warn "$unit not enabled"
  fi
}

enabled_service_check() {
  local unit="$1"
  if ! have_cmd systemctl; then
    fail "systemctl unavailable; cannot check $unit"
    return
  fi
  if systemctl is-enabled "$unit" >/dev/null 2>&1; then
    ok "$unit enabled"
  else
    fail "$unit not enabled"
  fi
}

package_check() {
  local pkg="$1"
  if ! have_cmd pacman; then
    fail "pacman unavailable; cannot check package $pkg"
    return
  fi
  if pacman -Q "$pkg" >/dev/null 2>&1; then
    ok "package installed: $pkg"
  else
    fail "package missing: $pkg"
  fi
}

command_check() {
  local cmd="$1"
  if have_cmd "$cmd"; then
    ok "command available: $cmd"
  else
    fail "command unavailable: $cmd"
  fi
}

app_manifest_check() {
  local app_cmd

  if [[ -r "$APPS_MANIFEST" ]]; then
    ok "app manifest exists: $APPS_MANIFEST"
  else
    fail "app manifest missing: $APPS_MANIFEST"
    return
  fi

  if have_cmd eos-app; then
    app_cmd="eos-app"
  elif [[ -x "$(engineos_root)/tools/engineos/eos-app" ]]; then
    app_cmd="$(engineos_root)/tools/engineos/eos-app"
  else
    fail "eos-app command unavailable for app manifest validation"
    return
  fi

  if ENGINEOS_APPS_MANIFEST="$APPS_MANIFEST" "$app_cmd" manifest validate >"$APP_MANIFEST_OUT" 2>&1; then
    ok "app manifest validates"
  else
    fail "app manifest validation failed; see $APP_MANIFEST_OUT"
  fi
}

opengl_check() {
  if grep -Eiq 'OpenGL (core profile )?renderer( string)?:' "$VALIDATE_DOCTOR_OUT"; then
    ok "OpenGL renderer available"
  else
    fail "OpenGL renderer unavailable; see $VALIDATE_DOCTOR_OUT"
  fi
}

runtime_config_check() {
  local bootstrap=""
  local cube_cmd=""
  local engine_cmd=""
  local recovery_tty=""
  local terminal_session=""

  if [[ -r "$RUNTIME_CONF" ]]; then
    ok "$RUNTIME_CONF exists"
    # shellcheck disable=SC1090
    source "$RUNTIME_CONF"
    bootstrap="${ENGINEOS_SHELL_BOOTSTRAP:-}"
    cube_cmd="${ENGINEOS_CUBE_CMD:-}"
    engine_cmd="${ENGINEOS_ENGINE_CMD:-}"
    recovery_tty="${ENGINEOS_RUNTIME_RECOVERY_TTY:-}"
    terminal_session="${ENGINEOS_TERMINAL_SESSION_CMD:-}"
    if [[ -n "$recovery_tty" ]]; then
      ok "runtime recovery TTY configured: $recovery_tty"
    else
      fail "runtime recovery TTY is not configured"
      return
    fi
  else
    fail "$RUNTIME_CONF missing"
    return
  fi

  if [[ "$recovery_tty" == "tty1" ]]; then
    fail "runtime recovery TTY must not use tty1, which is reserved for autostart"
  elif [[ "$recovery_tty" =~ ^tty[0-9]+$ ]]; then
    ok "runtime recovery TTY format is valid"
  else
    fail "runtime recovery TTY has unexpected format: $recovery_tty"
  fi

  if [[ "$terminal_session" == *"tmux new -A -s engineos"* ]]; then
    ok "runtime terminal session starts tmux engineos"
  else
    fail "runtime terminal session must start tmux engineos"
  fi

  if [[ "$bootstrap" == "launchpad" ]]; then
    ok "runtime shell bootstrap starts launchpad"
  else
    fail "runtime shell bootstrap must be launchpad"
  fi

  if [[ "$cube_cmd" == *"eos-app launch cube"* ]]; then
    ok "runtime cube command uses app launcher"
  else
    fail "runtime cube command must use eos-app launch cube"
  fi

  if [[ "$engine_cmd" == *"eos-app launch quake"* ]]; then
    ok "runtime engine command uses app launcher"
  else
    fail "runtime engine command must use eos-app launch quake"
  fi

  enabled_service_check "getty@${recovery_tty}.service"
}

runtime_recovery_help_check() {
  local help_output

  if ! have_cmd engineos-recovery-help; then
    fail "engineos-recovery-help command unavailable"
    return
  fi

  if help_output="$(engineos-recovery-help 2>&1)"; then
    ok "recovery help command completed"
  else
    fail "recovery help command failed"
    return
  fi
  if printf '%s\n' "$help_output" | grep -F 'eos-logs runtime --last 200' >/dev/null; then
    ok "recovery help points to runtime logs"
  else
    fail "recovery help does not point to runtime logs"
  fi
  if printf '%s\n' "$help_output" | grep -F 'eos-crash-bundle' >/dev/null; then
    ok "recovery help points to crash bundle"
  else
    fail "recovery help does not point to crash bundle"
  fi
  if printf '%s\n' "$help_output" | grep -F 'engineos.noautostart' >/dev/null; then
    ok "recovery help mentions autostart disable flag"
  else
    fail "recovery help does not mention autostart disable flag"
  fi
}

runtime_autostart_log_check() {
  local runtime_log="$LOG_DIR/runtime-start.log"

  if [[ ! -r "$runtime_log" ]]; then
    fail "runtime autostart log missing: $runtime_log"
    return
  fi

  ok "runtime autostart log exists"
  if grep -Eq 'starting EngineOS shell|runtime autostart disabled' "$runtime_log"; then
    ok "runtime autostart log records startup decision"
  else
    fail "runtime autostart log does not record startup decision"
  fi

	if grep -Eq 'EngineOS shell (exited cleanly|failed rc=)|runtime autostart disabled' "$runtime_log"; then
		ok "runtime autostart log records outcome"
	elif have_cmd systemctl && systemctl is-active --quiet engineos-runtime.service; then
		ok "runtime shell service active: engineos-runtime.service"
	else
		warn "runtime autostart appears to still be running; no final outcome in $runtime_log"
	fi
}

shell_renderer_check() {
  local shell_log="${1:-$SHELL_LOG}"

  if [[ ! -r "$shell_log" ]]; then
    if [[ "$MODE" == "bare-metal" ]]; then
      fail "shell renderer log missing: $shell_log"
    else
      warn "shell renderer log missing: $shell_log"
    fi
    return
  fi

  ok "shell renderer log exists"
  if grep -Eiq 'pixman|llvmpipe|softpipe|software rasterizer|software renderer|wlr_allow_software=(1|true|yes)|libgl_always_software=(1|true|yes)' "$shell_log"; then
    if [[ "$MODE" == "bare-metal" ]]; then
      fail "shell renderer log shows software rendering; see $shell_log"
    else
      warn "shell renderer log shows software rendering; acceptable only for VM smoke paths"
    fi
    return
  fi

  if grep -Eiq 'renderer diagnostics|GLES2|EGL|wlr_renderer=(gles2|vulkan)' "$shell_log"; then
    ok "shell renderer diagnostics present"
  else
    fail "shell renderer diagnostics missing; see $shell_log"
  fi

  if [[ "$MODE" == "bare-metal" ]]; then
    if grep -Eiq 'GLES2|EGL|wlr_renderer=(gles2|vulkan)' "$shell_log"; then
      ok "bare-metal shell renderer has GL-capable evidence"
    else
      fail "bare-metal shell renderer does not show GL-capable evidence; see $shell_log"
    fi
  fi
}

bare_metal_graphics_check() {
  local doctor_output

  if [[ -d "$DRI_DIR" ]]; then
    ok "$DRI_DIR exists"
  else
    fail "$DRI_DIR missing for bare-metal graphics validation"
  fi

  if [[ -d "$DRM_SYSFS" ]] && find "$DRM_SYSFS" -maxdepth 1 -name 'card*' -print -quit 2>/dev/null | grep -q .; then
    ok "DRM card devices visible under $DRM_SYSFS"
  else
    fail "no DRM card devices visible under $DRM_SYSFS"
  fi

  if "$SCRIPT_DIR/outputs.sh" validate --single --sysfs "$DRM_SYSFS" >"$VALIDATE_OUTPUTS_OUT" 2>&1; then
    ok "at least one connected DRM output"
  else
    fail "no connected DRM output validated; see $VALIDATE_OUTPUTS_OUT"
  fi

  if have_cmd lspci; then
    if lspci -nn 2>/dev/null | grep -Ei 'VGA|Display|3D' | grep -Eiq 'Advanced Micro Devices|AMD|ATI'; then
      ok "AMD display device visible to lspci"
    else
      fail "AMD display device not visible to lspci"
    fi
  else
    fail "lspci unavailable; cannot verify AMD display device"
  fi

  if doctor_output="$("$DOCTOR_CMD" --bare-metal 2>&1)"; then
    ok "bare-metal doctor completed"
  else
    printf '%s\n' "$doctor_output" >"$VALIDATE_DOCTOR_OUT"
    fail "bare-metal doctor failed; see $VALIDATE_DOCTOR_OUT"
    return
  fi
  if printf '%s\n' "$doctor_output" | grep -Eiq 'llvmpipe|softpipe|software rasterizer'; then
    fail "bare-metal validation detected software renderer"
  else
    ok "bare-metal renderer is not obviously software"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)
      MODE="vm"
      ;;
    --runtime)
      MODE="runtime"
      ;;
    --bare-metal)
      MODE="bare-metal"
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown validate_boot option: $1"
      ;;
  esac
  shift
done

[[ -n "$MODE" ]] || die "validate_boot requires an explicit mode: --vm, --runtime, or --bare-metal"

printf 'EngineOS boot validation\n'
printf '  mode: %s\n' "$MODE"
printf '  timestamp_utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if have_cmd eos-doctor; then
  ok "eos command family available"
elif [[ -x "$(engineos_root)/tools/engineos/eos-doctor" ]]; then
  ok "source-tree eos command family available"
else
  fail "eos command family unavailable"
fi

doctor_args=()
if [[ "$MODE" == "vm" || "$MODE" == "runtime" ]]; then
  doctor_args+=(--vm)
elif [[ "$MODE" == "bare-metal" ]]; then
  doctor_args+=(--bare-metal)
fi
if "$DOCTOR_CMD" "${doctor_args[@]}" >"$VALIDATE_DOCTOR_OUT" 2>&1; then
  ok "doctor completed"
else
  fail "doctor failed; see $VALIDATE_DOCTOR_OUT"
fi
opengl_check

service_check NetworkManager.service
if [[ "$MODE" == "vm" ]]; then
  service_check sshd.service
fi
service_check engineos-live-setup.service
if [[ "$MODE" == "runtime" || "$MODE" == "bare-metal" ]]; then
  service_check engineos-engine-runner.service
  service_check engineos-runtime.service
fi

package_check engineos-config
package_check engineos-tools
package_check ttf-dejavu
package_check engineos-cube
package_check engineos-engine-runner
package_check engineos-quakespasm
package_check engineos-quake-template
command_check quakespasm
command_check engineos-cube
if [[ "$MODE" == "runtime" || "$MODE" == "bare-metal" ]]; then
  package_check engineos-shell
fi

if [[ -d "$LOG_DIR" ]]; then
  ok "$LOG_DIR exists"
else
  fail "$LOG_DIR missing"
fi

if [[ "$MODE" == "runtime" || "$MODE" == "bare-metal" ]]; then
  app_manifest_check
  runtime_config_check
  runtime_recovery_help_check
  runtime_autostart_log_check
  shell_renderer_check
fi

if [[ "$MODE" == "bare-metal" ]]; then
  bare_metal_graphics_check
fi

printf 'Boot validation summary: %s failure(s), %s warning(s)\n' "$FAILURES" "$WARNINGS"
[[ "$FAILURES" -eq 0 ]]
