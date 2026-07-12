#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
PKGBUILD="$ROOT/packages/engineos-mux/PKGBUILD"
REPEAT=1
TEST_TIMEOUT=45
OSC_TIMEOUT=180
OUTPUT_DIR=""
ARCHIVE=""
PRISTINE_BIN=""
FORK_BIN=""
REGRESS_DIR=""
KEEP_BUILD=false
MAINTENANCE_PATCH="$ROOT/tools/fixtures/tmux-regress-3.6b-maintenance.patch"
REPRODUCIBLE_PAIR=false
declare -a SELECTED_TESTS=()
configure_args=(--prefix=/usr --enable-utempter --enable-systemd --disable-cgroups)

usage() {
  cat <<'HELP'
Usage: tmux_upstream_regress.sh [options]

Build the pinned pristine tmux baseline and the current EngineOS fork with
identical flags, apply the named official upstream maintenance commits to the
regression fixtures, then run every upstream regress/*.sh file unchanged
against both binaries. The fork must pass the complete suite; the pristine
release baseline remains as an explicit comparator. Results and per-test output
remain in the reported evidence directory.

Options:
  --archive PATH          Pinned tmux commit archive (defaults to artifacts)
  --output DIR            Evidence directory (defaults under /tmp)
  --repeat N              Run every selected test N times (default: 1)
  --timeout SECONDS       Per-test timeout (default: 45)
  --osc-timeout SECONDS   Timeout for osc-11colours.sh (default: 180)
  --test NAME             Run one upstream test; repeatable
  --pristine-bin PATH     Use an existing pristine binary
  --fork-bin PATH         Use an existing fork binary
  --regress-dir PATH      Use this upstream regress directory (diagnostic only)
  --keep-build            Retain temporary paired build trees
  --help                  Show this help

The three existing-path options must be supplied together. Existing paths and
selected subsets are diagnostic only and are identified as such in summary.json.
HELP
}

die_usage() {
  printf 'tmux upstream regress: %s\n' "$*" >&2
  usage >&2
  exit 2
}

positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      [[ $# -ge 2 ]] || die_usage "--archive requires a path"
      ARCHIVE="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die_usage "--output requires a directory"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --repeat)
      [[ $# -ge 2 ]] || die_usage "--repeat requires a count"
      positive_integer "$2" || die_usage "--repeat must be a positive integer"
      REPEAT="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die_usage "--timeout requires seconds"
      positive_integer "$2" || die_usage "--timeout must be a positive integer"
      TEST_TIMEOUT="$2"
      shift 2
      ;;
    --osc-timeout)
      [[ $# -ge 2 ]] || die_usage "--osc-timeout requires seconds"
      positive_integer "$2" || die_usage "--osc-timeout must be a positive integer"
      OSC_TIMEOUT="$2"
      shift 2
      ;;
    --test)
      [[ $# -ge 2 ]] || die_usage "--test requires a script name"
      SELECTED_TESTS+=("$2")
      shift 2
      ;;
    --pristine-bin)
      [[ $# -ge 2 ]] || die_usage "--pristine-bin requires a path"
      PRISTINE_BIN="$2"
      shift 2
      ;;
    --fork-bin)
      [[ $# -ge 2 ]] || die_usage "--fork-bin requires a path"
      FORK_BIN="$2"
      shift 2
      ;;
    --regress-dir)
      [[ $# -ge 2 ]] || die_usage "--regress-dir requires a path"
      REGRESS_DIR="$2"
      shift 2
      ;;
    --keep-build)
      KEEP_BUILD=true
      shift
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown option: $1"
      ;;
  esac
done

for command in autoreconf bsdtar git install jq make nproc patch realpath sha256sum timeout; do
  command -v "$command" >/dev/null 2>&1 || die "required command unavailable: $command"
done
[[ -r "$PKGBUILD" ]] || die "engineos-mux PKGBUILD missing: $PKGBUILD"
[[ -r "$MAINTENANCE_PATCH" ]] ||
  die "upstream regression maintenance patch missing: $MAINTENANCE_PATCH"
package_configure='./configure --prefix=/usr --enable-utempter --enable-systemd --disable-cgroups'
grep -F "$package_configure" "$PKGBUILD" >/dev/null ||
  die "paired configure flags do not match engineos-mux PKGBUILD"

commit="$(sed -n 's/^_commit=//p' "$PKGBUILD")"
pkgver="$(sed -n 's/^pkgver=//p' "$PKGBUILD")"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid engineos-mux pinned commit: $commit"
[[ -n "$pkgver" ]] || die "engineos-mux pkgver is unavailable"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${TMPDIR:-/tmp}/engineos-tmux-upstream-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUTPUT_DIR/logs"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
results="$OUTPUT_DIR/results.tsv"
printf 'attempt\ttest\tpristine_rc\tfork_rc\tclassification\n' >"$results"

existing_count=0
[[ -n "$PRISTINE_BIN" ]] && existing_count=$((existing_count + 1))
[[ -n "$FORK_BIN" ]] && existing_count=$((existing_count + 1))
[[ -n "$REGRESS_DIR" ]] && existing_count=$((existing_count + 1))
if [[ "$existing_count" -ne 0 && "$existing_count" -ne 3 ]]; then
  die "--pristine-bin, --fork-bin, and --regress-dir must be supplied together"
fi

build_root=""
runtime_root="$(mktemp -d "${TMPDIR:-/tmp}/eos-tu.XXXXXX")"
cleanup() {
  if [[ -n "$build_root" && -d "$build_root" && "$KEEP_BUILD" != true ]]; then
    rm -rf "$build_root"
  fi
  rm -rf "$runtime_root"
}
trap cleanup EXIT

if [[ "$existing_count" -eq 0 ]]; then
  archive_checksum="$(awk '
    /^sha256sums=\(/ {
      if (!match($0, /[0-9a-f]{64}/)) {
        getline
        match($0, /[0-9a-f]{64}/)
      }
      if (RSTART != 0) print substr($0, RSTART, RLENGTH)
      exit
    }
  ' "$PKGBUILD")"
  [[ "$archive_checksum" =~ ^[0-9a-f]{64}$ ]] ||
    die "could not read pinned archive checksum from $PKGBUILD"
  if [[ -z "$ARCHIVE" ]]; then
    ARCHIVE="$ROOT/artifacts/sources/engineos-mux/tmux-$pkgver-$commit.tar.gz"
  fi
  [[ -r "$ARCHIVE" ]] ||
    die "pinned archive missing: $ARCHIVE (run eos-build repo --package engineos-mux)"
  actual_checksum="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
  [[ "$actual_checksum" == "$archive_checksum" ]] ||
    die "pinned archive checksum mismatch: expected $archive_checksum, got $actual_checksum"

  build_root="$(mktemp -d "${TMPDIR:-/tmp}/engineos-tmux-upstream-build.XXXXXX")"
  source_root="$build_root/source"
  mkdir -p "$source_root"
  bsdtar -xf "$ARCHIVE" -C "$source_root"
  extracted="$source_root/tmux-$commit"
  [[ -d "$extracted/regress" ]] || die "archive does not contain regress/: $ARCHIVE"
  git -C "$extracted" apply --binary --check "$MAINTENANCE_PATCH"
  git -C "$extracted" apply --binary "$MAINTENANCE_PATCH"
  printf 'Applied official upstream fixture maintenance with git apply --binary\n' \
    >"$OUTPUT_DIR/regress-maintenance.log"
  pristine_source="$build_root/pristine"
  fork_source="$build_root/fork"
  cp -a "$extracted" "$pristine_source"
  cp -a "$extracted" "$fork_source"

  for patch_file in \
      0002-engine-mux-in-server-frontend.patch \
      0003-engine-mux-graphical-client.patch \
      0004-engine-pane-presentations.patch \
      0005-upstream-regression-fixes.patch \
      0006-engine-mux-deterministic-shutdown.patch \
      0007-strip-sent-flag-before-pane-input.patch \
      0008-skip-graphical-client-tty-alerts.patch; do
    patch -d "$fork_source" -Np1 -i "$ROOT/packages/engineos-mux/$patch_file" \
      >>"$OUTPUT_DIR/fork-patch.log"
  done
  install -m0644 "$ROOT/packages/engineos-mux/engine-mux-frontend.c" \
    "$fork_source/engine-mux-frontend.c"
  install -m0644 "$ROOT/packages/engineos-mux/engine-mux-frontend.h" \
    "$fork_source/engine-mux-frontend.h"
  install -m0644 "$ROOT/packages/engineos-mux/engine-pane.c" \
    "$fork_source/engine-pane.c"
  install -m0644 "$ROOT/mux/include/engine-mux-protocol.h" \
    "$fork_source/engine-mux-protocol.h"

  build_one() {
    local label="$1"
    local source_dir="$2"
    (
      cd "$source_dir"
      autoreconf -fi
      ./configure "${configure_args[@]}"
      make -j"$(nproc)"
    ) >"$OUTPUT_DIR/$label-build.log" 2>&1
  }
  printf 'Building pristine tmux %s (%s)\n' "$pkgver" "$commit"
  build_one pristine "$pristine_source"
  printf 'Building EngineOS fork from the same baseline\n'
  build_one fork "$fork_source"
  PRISTINE_BIN="$pristine_source/tmux"
  FORK_BIN="$fork_source/tmux"
  REGRESS_DIR="$pristine_source/regress"
  REPRODUCIBLE_PAIR=true
else
  PRISTINE_BIN="$(realpath "$PRISTINE_BIN")"
  FORK_BIN="$(realpath "$FORK_BIN")"
  REGRESS_DIR="$(realpath "$REGRESS_DIR")"
fi

[[ -x "$PRISTINE_BIN" ]] || die "pristine tmux binary is not executable: $PRISTINE_BIN"
[[ -x "$FORK_BIN" ]] || die "fork tmux binary is not executable: $FORK_BIN"
[[ -d "$REGRESS_DIR" ]] || die "upstream regress directory is unavailable: $REGRESS_DIR"
[[ "$($PRISTINE_BIN -V)" == "tmux $pkgver" ]] || die "pristine binary version mismatch"
[[ "$($FORK_BIN -V)" == "tmux $pkgver" ]] || die "fork binary version mismatch"

mapfile -t all_tests < <(find "$REGRESS_DIR" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' | sort)
[[ "${#all_tests[@]}" -gt 0 ]] || die "no upstream regression scripts found"
if [[ "${#SELECTED_TESTS[@]}" -eq 0 ]]; then
  tests=("${all_tests[@]}")
  full_suite=true
else
  tests=()
  for test in "${SELECTED_TESTS[@]}"; do
    [[ "$test" == *.sh ]] || test="$test.sh"
    [[ -f "$REGRESS_DIR/$test" ]] || die "unknown upstream regression test: $test"
    if [[ ! " ${tests[*]-} " =~ " $test " ]]; then
      tests+=("$test")
    fi
  done
  full_suite=false
fi

sha256sum "$PRISTINE_BIN" "$FORK_BIN" >"$OUTPUT_DIR/binaries.sha256"
(cd "$REGRESS_DIR" && sha256sum ./*.sh) >"$OUTPUT_DIR/regress-scripts.sha256"
(cd "$REGRESS_DIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum) \
  >"$OUTPUT_DIR/regress-files.sha256"
sha256sum "$MAINTENANCE_PATCH" >"$OUTPUT_DIR/regress-maintenance.sha256"
{
  printf 'schema=engineos-tmux-upstream-v2\n'
  printf 'commit=%s\n' "$commit"
  printf 'pkgver=%s\n' "$pkgver"
  printf 'repeat=%s\n' "$REPEAT"
  printf 'full_suite=%s\n' "$full_suite"
  printf 'test_count=%s\n' "${#tests[@]}"
  printf 'reproducible_pair=%s\n' "$REPRODUCIBLE_PAIR"
  printf 'regress_maintenance_commits=%s\n' \
    '5c73d3878d4904bce3d61399fb6a222ed39a4dbc,dd62c2f9467f975388f4a2701022752961bdb086,6f588402c34471b0dea0c0894a2caca275f92f17'
  printf 'pristine_version=%s\n' "$($PRISTINE_BIN -V)"
  printf 'fork_version=%s\n' "$($FORK_BIN -V)"
} >"$OUTPUT_DIR/metadata.env"

kill_test_servers() {
  local binary="$1"
  local socket_dir="$2"
  mkdir -p "$socket_dir"
  env TMUX_TMPDIR="$socket_dir" "$binary" -Ltest kill-server >/dev/null 2>&1 || true
  env TMUX_TMPDIR="$socket_dir" "$binary" -Ltest2 kill-server >/dev/null 2>&1 || true
}

run_test() {
  local label="$1"
  local binary="$2"
  local test="$3"
  local attempt="$4"
  local test_index="$5"
  local timeout_seconds="$TEST_TIMEOUT"
  local home_dir="$OUTPUT_DIR/home/$attempt/$test/$label"
  # AF_UNIX paths are limited to roughly 108 bytes on Linux. Keep runtime
  # sockets outside the descriptive evidence path and identify them by index.
  local socket_dir="$runtime_root/${attempt}-${test_index}-${label:0:1}"
  local log="$OUTPUT_DIR/logs/$attempt-$test-$label.log"
  local rc=0

  [[ "$test" == "osc-11colours.sh" ]] && timeout_seconds="$OSC_TIMEOUT"
  mkdir -p "$home_dir" "$socket_dir"
  kill_test_servers "$binary" "$socket_dir"
  set +e
  timeout "${timeout_seconds}s" env -i \
      PATH=/bin:/usr/bin LC_CTYPE=C.UTF-8 \
      HOME="$home_dir" TMUX_TMPDIR="$socket_dir" TEST_TMUX="$binary" \
      sh "./$test" >"$log" 2>&1
  rc=$?
  set -e
  kill_test_servers "$binary" "$socket_dir"
  # Upstream's regress/Makefile deliberately leaves one second after every
  # script. Preserve that scheduling boundary while keeping each script byte
  # for byte unchanged.
  sleep 1
  return "$rc"
}

matched_pass=0
shared_fail=0
fork_only_fail=0
pristine_only_fail=0
printf 'EngineOS paired upstream tmux regression\n'
printf '  commit: %s\n' "$commit"
printf '  tests:  %s x %s attempt(s)\n' "${#tests[@]}" "$REPEAT"
printf '  output: %s\n' "$OUTPUT_DIR"

for ((attempt = 1; attempt <= REPEAT; attempt++)); do
  test_index=0
  for test in "${tests[@]}"; do
    test_index=$((test_index + 1))
    pristine_rc=0
    fork_rc=0
    (
      cd "$REGRESS_DIR"
      run_test pristine "$PRISTINE_BIN" "$test" "$attempt" "$test_index"
    ) || pristine_rc=$?
    (
      cd "$REGRESS_DIR"
      run_test fork "$FORK_BIN" "$test" "$attempt" "$test_index"
    ) || fork_rc=$?

    if [[ "$pristine_rc" -eq 0 && "$fork_rc" -eq 0 ]]; then
      classification=pass
      matched_pass=$((matched_pass + 1))
    elif [[ "$pristine_rc" -ne 0 && "$fork_rc" -ne 0 ]]; then
      classification=shared-failure
      shared_fail=$((shared_fail + 1))
    elif [[ "$pristine_rc" -eq 0 ]]; then
      classification=fork-only-failure
      fork_only_fail=$((fork_only_fail + 1))
    else
      classification=pristine-only-failure
      pristine_only_fail=$((pristine_only_fail + 1))
    fi
    printf '%s %-31s pristine=%s fork=%s %s\n' \
      "$attempt" "$test" "$pristine_rc" "$fork_rc" "$classification"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$attempt" "$test" "$pristine_rc" "$fork_rc" "$classification" >>"$results"
  done
done

jq -n \
  --arg schema engineos-tmux-upstream-v2 \
  --arg commit "$commit" \
  --arg pkgver "$pkgver" \
  --arg output "$OUTPUT_DIR" \
  --argjson full_suite "$full_suite" \
  --argjson reproducible_pair "$REPRODUCIBLE_PAIR" \
  --argjson repeat "$REPEAT" \
  --argjson tests "${#tests[@]}" \
  --argjson matched_pass "$matched_pass" \
  --argjson shared_fail "$shared_fail" \
  --argjson fork_only_fail "$fork_only_fail" \
  --argjson pristine_only_fail "$pristine_only_fail" \
  '{schema:$schema, commit:$commit, pkgver:$pkgver, output:$output,
    full_suite:$full_suite, reproducible_pair:$reproducible_pair,
    repeat:$repeat, tests:$tests,
    results:{matched_pass:$matched_pass, shared_fail:$shared_fail,
      fork_only_fail:$fork_only_fail,
      pristine_only_fail:$pristine_only_fail},
    accepted:($full_suite and $reproducible_pair and
      $shared_fail == 0 and $fork_only_fail == 0)}' \
  >"$OUTPUT_DIR/summary.json"

printf 'Summary: pass=%s shared_fail=%s fork_only=%s pristine_only=%s\n' \
  "$matched_pass" "$shared_fail" "$fork_only_fail" "$pristine_only_fail"
printf 'Evidence: %s\n' "$OUTPUT_DIR"
if [[ "$full_suite" != true || "$REPRODUCIBLE_PAIR" != true ]]; then
  printf 'FAIL selected subset or existing binaries are diagnostic only\n' >&2
  exit 1
fi
if [[ "$shared_fail" -ne 0 || "$fork_only_fail" -ne 0 ]]; then
  printf 'FAIL EngineOS fork does not pass the maintained upstream tmux suite\n' >&2
  exit 1
fi
printf 'PASS EngineOS fork passes the maintained upstream tmux suite (%s pristine-only fixes)\n' \
  "$pristine_only_fail"
