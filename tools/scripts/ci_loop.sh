#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
MODE="${1:-local}"
DRY_RUN=false
INSTALL=false
CLEAN_GENERATED=false
VALIDATE_REPO=true
RUN_PREFLIGHT=true
TEST_SCOPES=()
PACKAGES=()
REPO_ARCH="${ENGINEOS_REPO_ARCH:-x86_64}"
REPO_DIR="${ENGINEOS_REPO_DIR:-$ROOT/repo/$REPO_ARCH}"

usage() {
  cat <<'HELP'
Usage: ci_loop.sh local [options]

Run the local EngineOS post-change pipeline:
  preflight -> tests -> package rebuild -> optional reinstall -> repo validation -> optional cleanup

Options:
  --dry-run             Print the real commands that would run, then exit.
  --package <name>      Limit rebuild/reinstall to a package. Repeatable.
  --all-packages        Rebuild all EngineOS packages.
  --test <scope>        Run an eos-test scope. Repeatable. Default: smoke.
  --install             Reinstall rebuilt packages with sudo pacman -U.
  --clean-generated     Remove packages/<name>/{pkg,src} after a successful run.
  --no-preflight        Skip preflight.
  --no-validate-repo    Skip repo validation.

Real rebuilds must run on Arch Linux. Reinstall and cleanup only run when their
flags are explicit. This command does not fall back to dry-run validation.
HELP
}

log_step() {
  printf '\n==> %s\n' "$*"
}

quote_command() {
  local arg
  printf '%q' "$1"
  shift || true
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

run_or_print() {
  if [[ "$DRY_RUN" == true ]]; then
    printf 'DRY-RUN '
    quote_command "$@"
    return 0
  fi
  quote_command "$@"
  "$@"
}

package_known() {
  local needle="$1"
  local pkg
  while IFS= read -r pkg; do
    [[ "$pkg" == "$needle" ]] && return 0
  done < <(engineos_packages)
  return 1
}

add_package() {
  local pkg="$1"
  local existing
  package_known "$pkg" || die "unknown EngineOS package: $pkg"
  for existing in "${PACKAGES[@]}"; do
    [[ "$existing" == "$pkg" ]] && return 0
  done
  PACKAGES+=("$pkg")
}

infer_changed_packages() {
  local file pkg
  if ! have_cmd git || ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    case "$file" in
      tools/engineos/*|tools/scripts/*|tools/eos/*|tools/hooks/*|AGENTS.md|agentd.md|docs/*|.agents/*|.codex/*)
        add_package engineos-tools
        ;;
      shell/*)
        add_package engineos-shell
        ;;
      tools/go/*|packages/engineos-engine-runner/*)
        add_package engineos-engine-runner
        ;;
      engines/quakespasm/*|packages/engineos-quakespasm/*)
        add_package engineos-quakespasm
        ;;
      packages/engineos-config/*|archiso/*)
        add_package engineos-config
        ;;
      packages/engineos-cube/*)
        add_package engineos-cube
        ;;
      packages/engineos-oh-my-zsh/*)
        add_package engineos-oh-my-zsh
        ;;
      packages/engineos-tmux-plugins/*)
        add_package engineos-tmux-plugins
        ;;
      packages/engineos-quake-template/*)
        add_package engineos-quake-template
        ;;
      packages/*/*)
        pkg="${file#packages/}"
        pkg="${pkg%%/*}"
        package_known "$pkg" && add_package "$pkg"
        ;;
    esac
  done < <(git -C "$ROOT" diff --name-only HEAD -- . && git -C "$ROOT" ls-files --others --exclude-standard)
}

latest_package_artifact() {
  local pkg="$1"
  find "$REPO_DIR" -maxdepth 1 -type f \
    \( -name "$pkg-*.pkg.tar.zst" -o -name "$pkg-*.pkg.tar.xz" -o -name "$pkg-*.pkg.tar.gz" \) \
    -printf '%T@ %p\n' 2>/dev/null |
    sort -n |
    awk 'END { if (NF >= 2) { $1=""; sub(/^ /, ""); print } }'
}

install_rebuilt_packages() {
  local pkg artifact
  local artifacts=()

  for pkg in "${PACKAGES[@]}"; do
    if [[ "$DRY_RUN" == true ]]; then
      artifacts+=("$REPO_DIR/$pkg-*.pkg.tar.*")
      continue
    fi
    artifact="$(latest_package_artifact "$pkg")"
    [[ -n "$artifact" ]] || die "no rebuilt artifact found for reinstall: $pkg in $REPO_DIR"
    artifacts+=("$artifact")
  done

  [[ ${#artifacts[@]} -gt 0 ]] || return 0
  run_or_print sudo -n pacman -U --noconfirm "${artifacts[@]}"
}

clean_generated_package_dirs() {
  local pkg dir
  for pkg in "${PACKAGES[@]}"; do
    for dir in "$ROOT/packages/$pkg/pkg" "$ROOT/packages/$pkg/src"; do
      [[ -e "$dir" ]] || continue
      case "$dir" in
        "$ROOT"/packages/*/pkg|"$ROOT"/packages/*/src)
          run_or_print rm -rf "$dir"
          ;;
        *)
          die "refusing to clean unexpected path: $dir"
          ;;
      esac
    done
  done
}

run_pipeline() {
  local pkg test_scope

  [[ "$MODE" == "local" ]] || die "unknown ci mode: $MODE"
  [[ ${#TEST_SCOPES[@]} -gt 0 ]] || TEST_SCOPES=(smoke)
  [[ ${#PACKAGES[@]} -gt 0 ]] || infer_changed_packages
  [[ ${#PACKAGES[@]} -gt 0 ]] || PACKAGES=(engineos-tools)
  if [[ "$DRY_RUN" != true && "$VALIDATE_REPO" == true && "$ROOT" != "/srv/engineos" ]]; then
    die "real repo validation must run from /srv/engineos; rerun there or pass --no-validate-repo for a package-only local loop"
  fi

  printf 'EngineOS local CI pipeline\n'
  printf '  root:     %s\n' "$ROOT"
  printf '  repo:     %s\n' "$REPO_DIR"
  printf '  dry-run:  %s\n' "$DRY_RUN"
  printf '  install:  %s\n' "$INSTALL"
  printf '  cleanup:  %s\n' "$CLEAN_GENERATED"
  printf '  packages:\n'
  for pkg in "${PACKAGES[@]}"; do
    printf '    - %s\n' "$pkg"
  done
  printf '  tests:\n'
  for test_scope in "${TEST_SCOPES[@]}"; do
    printf '    - %s\n' "$test_scope"
  done

  if [[ "$RUN_PREFLIGHT" == true ]]; then
    log_step "preflight"
    run_or_print "$SCRIPT_DIR/preflight.sh" repo
  fi

  for test_scope in "${TEST_SCOPES[@]}"; do
    log_step "test $test_scope"
    run_or_print "$ROOT/tools/engineos/eos-test" "$test_scope"
  done

  log_step "package rebuild"
  for pkg in "${PACKAGES[@]}"; do
    run_or_print "$ROOT/tools/engineos/eos-build" repo --package "$pkg"
  done

  if [[ "$INSTALL" == true ]]; then
    log_step "reinstall"
    install_rebuilt_packages
  fi

  if [[ "$VALIDATE_REPO" == true ]]; then
    log_step "repo validation"
    run_or_print "$ROOT/tools/engineos/eos-validate" repo
  fi

  if [[ "$CLEAN_GENERATED" == true ]]; then
    log_step "cleanup generated package dirs"
    clean_generated_package_dirs
  fi

  printf '\nEngineOS local CI pipeline complete\n'
}

if [[ "${1:-}" == "help" || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 && "${1:-}" != --* ]]; then
  MODE="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --package)
      shift
      add_package "${1:-}"
      ;;
    --all-packages)
      PACKAGES=()
      while IFS= read -r pkg; do
        PACKAGES+=("$pkg")
      done < <(engineos_packages)
      ;;
    --test)
      shift
      [[ -n "${1:-}" ]] || die "--test requires a scope"
      TEST_SCOPES+=("$1")
      ;;
    --install)
      INSTALL=true
      ;;
    --clean-generated)
      CLEAN_GENERATED=true
      ;;
    --no-preflight)
      RUN_PREFLIGHT=false
      ;;
    --no-validate-repo)
      VALIDATE_REPO=false
      ;;
    help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown ci option: $1"
      ;;
  esac
  shift
done

run_pipeline
