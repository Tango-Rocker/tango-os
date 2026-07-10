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

add_package() {
  engineos_add_package_request PACKAGES "$1"
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
      tools/game/*)
        add_package engineos-quakespasm
        ;;
      engines/quakespasm/*|packages/engineos-quakespasm/*)
        add_package engineos-quakespasm
        ;;
      tools/level-agent/*|packages/engineos-level-agent/*)
        add_package engineos-level-agent
        ;;
      packages/engineos-ericw-tools/*)
        add_package engineos-ericw-tools
        ;;
      packages/engineos-trenchbroom/*)
        add_package engineos-trenchbroom
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
        engineos_package_known "$pkg" && add_package "$pkg"
        ;;
    esac
  done < <(git -C "$ROOT" diff --name-only HEAD -- . && git -C "$ROOT" ls-files --others --exclude-standard)
}

latest_package_artifact() {
  local pkg="$1"
  local artifact
  local name
  local version
  local best_artifact=""
  local best_version=""

  have_cmd pacman || die "pacman is missing"
  have_cmd vercmp || die "vercmp is missing; install pacman"

  while IFS= read -r artifact; do
    read -r name version < <(pacman -Qp "$artifact" 2>/dev/null || true)
    [[ "$name" == "$pkg" && -n "${version:-}" ]] || continue
    if [[ -z "$best_version" ]] || [[ "$(vercmp "$version" "$best_version")" -gt 0 ]]; then
      best_artifact="$artifact"
      best_version="$version"
    fi
  done < <(find "$REPO_DIR" -maxdepth 1 -type f \
    \( -name "$pkg-*.pkg.tar.zst" -o -name "$pkg-*.pkg.tar.xz" -o -name "$pkg-*.pkg.tar.gz" \) \
    -print 2>/dev/null | sort)

  [[ -n "$best_artifact" ]] && printf '%s\n' "$best_artifact"
}

pkgbuild_expected_version() {
  local pkg="$1"
  (
    set +u
    cd "$ROOT/packages/$pkg"
    # shellcheck disable=SC1091
    source PKGBUILD
    if [[ -n "${epoch:-}" ]]; then
      printf '%s:%s-%s\n' "$epoch" "$pkgver" "$pkgrel"
    else
      printf '%s-%s\n' "$pkgver" "$pkgrel"
    fi
  )
}

verify_package_artifact() {
  local pkg="$1"
  local artifact="$2"
  local artifact_name artifact_version expected_version
  local unit unit_text command archive_path

  read -r artifact_name artifact_version < <(pacman -Qp "$artifact")
  expected_version="$(pkgbuild_expected_version "$pkg")"
  [[ "$artifact_name" == "$pkg" ]] ||
    die "artifact package mismatch: expected=$pkg actual=$artifact_name artifact=$artifact"
  [[ "$artifact_version" == "$expected_version" ]] ||
    die "artifact version mismatch: $pkg expected=$expected_version actual=$artifact_version"

  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    unit_text="$(bsdtar -xOf "$artifact" "$unit")"
    while IFS= read -r command; do
      command="${command#-}"
      case "$command" in
        /usr/lib/engineos/*|/usr/bin/eos|/usr/bin/eos-*|/usr/bin/engineos|/usr/bin/engineos-*)
          archive_path="${command#/}"
          bsdtar -tf "$artifact" | grep -Fx "$archive_path" >/dev/null ||
            die "$pkg unit ${unit##*/} references command missing from artifact: $command"
          ;;
      esac
    done < <(printf '%s\n' "$unit_text" | sed -nE 's/^ExecStart(Pre)?=-?([^[:space:]]+).*/\2/p')
  done < <(bsdtar -tf "$artifact" | grep -E '^usr/lib/systemd/(system|user)/.+\.(service|socket)$' || true)
}

verify_installed_package() {
  local pkg="$1"
  local artifact="$2"
  local installed_name installed_version artifact_name artifact_version
  local unit unit_text command

  read -r artifact_name artifact_version < <(pacman -Qp "$artifact")
  read -r installed_name installed_version < <(pacman -Q "$pkg")
  [[ "$installed_name" == "$artifact_name" && "$installed_version" == "$artifact_version" ]] ||
    die "installed package mismatch: $pkg artifact=$artifact_version installed=${installed_version:-missing}"

  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    unit_text="$(bsdtar -xOf "$artifact" "$unit")"
    while IFS= read -r command; do
      command="${command#-}"
      case "$command" in
        /usr/lib/engineos/*|/usr/bin/eos|/usr/bin/eos-*|/usr/bin/engineos|/usr/bin/engineos-*)
          [[ -x "$command" ]] ||
            die "$pkg installed unit ${unit##*/} references missing executable: $command"
          ;;
      esac
    done < <(printf '%s\n' "$unit_text" | sed -nE 's/^ExecStart(Pre)?=-?([^[:space:]]+).*/\2/p')
  done < <(bsdtar -tf "$artifact" | grep -E '^usr/lib/systemd/(system|user)/.+\.(service|socket)$' || true)
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
    verify_package_artifact "$pkg" "$artifact"
    artifacts+=("$artifact")
  done

  [[ ${#artifacts[@]} -gt 0 ]] || return 0
  run_or_print sudo -n pacman -U --noconfirm "${artifacts[@]}"
  if [[ "$DRY_RUN" != true ]]; then
    for artifact in "${artifacts[@]}"; do
      pkg="$(pacman -Qp "$artifact" | awk '{print $1}')"
      verify_installed_package "$pkg" "$artifact"
    done
  fi
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

selected_package_args() {
  engineos_package_cli_args PACKAGES
}

run_pipeline() {
  local package_arg
  local pkg
  local test_scope
  local package_args=()

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

  while IFS= read -r package_arg; do
    package_args+=("$package_arg")
  done < <(selected_package_args)

  if [[ "$RUN_PREFLIGHT" == true ]]; then
    log_step "preflight"
    run_or_print "$SCRIPT_DIR/preflight.sh" repo "${package_args[@]}"
  fi

  for test_scope in "${TEST_SCOPES[@]}"; do
    log_step "test $test_scope"
    run_or_print "$ROOT/tools/engineos/eos-test" "$test_scope"
  done

  log_step "package rebuild"
  run_or_print "$ROOT/tools/engineos/eos-build" repo "${package_args[@]}"

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
