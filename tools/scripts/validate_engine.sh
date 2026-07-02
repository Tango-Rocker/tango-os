#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
TARGET="${1:-}"
shift || true
FAILURES=0
WARNINGS=0

usage() {
  cat <<'HELP'
Usage: validate_engine.sh quake

Validate EngineOS engine wrapper inputs and local smoke behavior.
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

require_executable() {
  local path="$1"
  if [[ -x "$path" ]]; then
    ok "executable: $path"
  else
    fail "missing executable: $path"
  fi
}

validate_quake() {
  local upstream="${QUAKESPASM_UPSTREAM_DIR:-$ROOT/engines/quakespasm/upstream}"
  local build_dir="$upstream/Quake"
  local log_dir="${TMPDIR:-/tmp}/engineos-validate-engine-$$"
  local bash_bin="${BASH:-$(command -v bash)}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown validate_engine quake option: $1"
        ;;
    esac
    shift
  done

  printf 'EngineOS Quake engine validation\n'
  printf '  root:     %s\n' "$ROOT"
  printf '  upstream: %s\n' "$upstream"

  require_executable "$ROOT/engines/quakespasm/engineos/fetch.sh"
  require_executable "$ROOT/engines/quakespasm/engineos/build.sh"
  require_executable "$ROOT/engines/quakespasm/engineos/run.sh"
  require_executable "$ROOT/engines/quakespasm/engineos/smoke-test.sh"

  if "$ROOT/engines/quakespasm/engineos/fetch.sh" --dry-run >/dev/null; then
    ok "fetch dry-run"
  else
    fail "fetch dry-run failed"
  fi

  if "$ROOT/engines/quakespasm/engineos/fetch.sh" --status >/dev/null 2>&1; then
    ok "fetch status"
  else
    warn "fetch status could not read a valid upstream checkout"
  fi

  if "$ROOT/engines/quakespasm/engineos/build.sh" --dry-run >/dev/null; then
    ok "build dry-run"
  else
    fail "build dry-run failed"
  fi

  mkdir -p "$log_dir"
  if ENGINEOS_LOG_DIR="$log_dir/default-smoke" ENGINEOS_LOG_TEE=false "$ROOT/engines/quakespasm/engineos/run.sh" --smoke >/dev/null; then
    ok "run smoke wrapper"
  else
    fail "run smoke wrapper failed"
  fi

  if grep -F 'QuakeSpasm smoke wrapper' "$log_dir/default-smoke/engine.log" >/dev/null 2>&1; then
    ok "smoke wrapper logged"
  else
    fail "smoke wrapper did not log expected marker"
  fi

  if grep -F 'result=ok' "$log_dir/default-smoke/engine.log" >/dev/null 2>&1; then
    ok "smoke wrapper reports real binary success"
  else
    fail "smoke wrapper did not report real binary success"
  fi

  if ENGINEOS_LOG_DIR="$log_dir/missing-smoke" \
      ENGINEOS_LOG_TEE=false \
      QUAKESPASM_BIN="$log_dir/missing-quakespasm" \
      "$ROOT/engines/quakespasm/engineos/run.sh" --smoke >/dev/null 2>&1; then
    fail "smoke wrapper should fail when QuakeSpasm binary is missing"
  else
    ok "smoke wrapper fails when QuakeSpasm binary is missing"
  fi

  if grep -F 'binary_status=missing' "$log_dir/missing-smoke/engine.log" >/dev/null 2>&1 &&
      grep -F 'result=failed' "$log_dir/missing-smoke/engine.log" >/dev/null 2>&1; then
    ok "smoke wrapper logs missing binary failure"
  else
    fail "smoke wrapper did not log missing binary failure"
  fi

  local fake_upstream="$log_dir/fake-upstream"
  local fake_path="$log_dir/fake-path"
  mkdir -p "$fake_upstream/Quake" "$log_dir/upstream-smoke" "$fake_path"
  cat >"$fake_upstream/Quake/quakespasm" <<'FAKE'
#!/usr/bin/env bash
printf 'fake built quakespasm\n'
FAKE
  chmod +x "$fake_upstream/Quake/quakespasm"
  ln -s "$(command -v mkdir)" "$fake_path/mkdir"
  ln -s "$(command -v cat)" "$fake_path/cat"

  if PATH="$fake_path" \
      ENGINEOS_ROOT="$ROOT" \
      ENGINEOS_LOG_DIR="$log_dir/upstream-smoke" \
      ENGINEOS_LOG_TEE=false \
      QUAKESPASM_UPSTREAM_DIR="$fake_upstream" \
      "$bash_bin" "$ROOT/engines/quakespasm/engineos/run.sh" --smoke >/dev/null; then
    ok "run smoke wrapper finds built upstream binary"
  else
    fail "run smoke wrapper failed with built upstream binary"
  fi

  if grep -F 'binary_source=upstream' "$log_dir/upstream-smoke/engine.log" >/dev/null 2>&1; then
    ok "built upstream binary resolution logged"
  else
    fail "smoke wrapper did not resolve built upstream binary"
  fi

  rm -rf "$log_dir"

  if [[ -d "$upstream/.git" ]]; then
    ok "upstream git checkout exists"
  elif [[ -d "$upstream" ]]; then
    fail "upstream directory exists but is not a git checkout: $upstream"
  else
    fail "upstream source missing: run eos-build engine quake --fetch on EngineDev"
  fi

  if [[ -d "$build_dir" ]]; then
    ok "upstream build directory exists: $build_dir"
  else
    fail "upstream build directory missing: $build_dir"
  fi

  printf 'Engine validation summary: %s failure(s), %s warning(s)\n' "$FAILURES" "$WARNINGS"
  [[ "$FAILURES" -eq 0 ]]
}

case "$TARGET" in
  quake)
    validate_quake "$@"
    ;;
  help|--help|-h|"")
    usage
    ;;
  *)
    die "unknown engine validation target: $TARGET"
    ;;
esac
