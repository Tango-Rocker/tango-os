#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(engineos_root)"
ACTION="${1:-help}"
shift || true

usage() {
  cat <<'HELP'
Usage: release.sh checklist [--dry-run] [--out-dir <dir>] [--export-dir <dir>] [--report <path>]

Create an MVP release-candidate checklist/report. In real mode this verifies
EngineDev and EngineRuntime ISO artifacts, creates checksums, and optionally
exports artifacts to a host-visible directory.
HELP
}

timestamp_utc() {
  date -u +%Y%m%dT%H%M%SZ
}

profile_iso_prefix() {
  case "$1" in
    enginedev)
      printf 'EngineDevOS'
      ;;
    engineruntime)
      printf 'EngineRuntimeOS'
      ;;
    *)
      die "unknown release profile: $1"
      ;;
  esac
}

latest_iso_for_profile() {
  local profile="$1"
  local out_dir="$2"
  local prefix

  prefix="$(profile_iso_prefix "$profile")"
  [[ -d "$out_dir" ]] || return 1
  find "$out_dir" -maxdepth 1 -type f -name "$prefix-*.iso" -printf '%T@ %p\n' 2>/dev/null |
    sort -n |
    tail -n 1 |
    cut -d' ' -f2-
}

append_report_header() {
  local report="$1"
  local mode="$2"
  local out_dir="$3"
  local export_dir="$4"

  {
    printf '# EngineOS MVP Release Candidate Checklist\n\n'
    printf -- '- created_utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '- root: `%s`\n' "$ROOT"
    printf -- '- mode: `%s`\n' "$mode"
    printf -- '- out_dir: `%s`\n' "$out_dir"
    if [[ -n "$export_dir" ]]; then
      printf -- '- export_dir: `%s`\n' "$export_dir"
    fi
    printf '\n'
  } >"$report"
}

append_report_artifact() {
  local report="$1"
  local profile="$2"
  local iso="$3"
  local checksum="$4"
  {
    printf -- '- %s ISO: `%s`\n' "$profile" "$iso"
    printf -- '- %s checksum: `%s`\n' "$profile" "$checksum"
  } >>"$report"
}

append_report_package_expectations() {
  local report="$1"
  local pkg

  {
    printf '\n## Package Expectations\n\n'
    printf 'The local `engineos` repository must contain artifacts for:\n\n'
    while IFS= read -r pkg; do
      printf -- '- `%s`\n' "$pkg"
    done < <(engineos_packages)
    printf '\n'
    printf 'Boot validation also expects `engineos-cube` to provide `/usr/bin/engineos-cube` and `engineos-quakespasm` to provide `/usr/bin/quakespasm` inside EngineDev and EngineRuntime.\n'
  } >>"$report"
}

append_report_commands() {
  local report="$1"
  cat >>"$report" <<'REPORT'

## Required Proofs

Builder:

```bash
./tools/engineos/engineos validate builder
./tools/engineos/engineos build repo
./tools/engineos/engineos build iso enginedev
./tools/engineos/engineos build iso engineruntime
./tools/engineos/engineos release checklist --out-dir out
./tools/engineos/engineos proof hardware-ready --profile engineruntime --device /dev/sdX
```

Test VM:

```bash
engineos proof booted-iso --vm
engineos proof booted-iso --runtime
engineos app manifest validate
engineos proof launchpad --runtime
```

Bare-metal AMD:

```bash
engineos doctor --bare-metal
engineos outputs validate --single
engineos run shell --tty
engineos app launch terminal
engineos terminal
engineos assets check quake
engineos run quake
engineos proof booted-iso --bare-metal
engineos crash-bundle --bare-metal
```

## Known Unproven Items

- Real package repo build must pass on the Arch builder VM.
- EngineDev and EngineRuntime ISO builds must pass with `mkarchiso`.
- EngineDev must boot in a test VM.
- EngineRuntime must boot on the target AMD machine.
- The wlroots shell must compile and run headless, nested, and TTY/KMS.
- `engineos-cube` must build through the local package repo and provide `/usr/bin/engineos-cube`.
- `engineos-quakespasm` must build through the local package repo and provide `/usr/bin/quakespasm`.
- App registry validation must pass through `engineos app manifest validate`.
- Launchpad bootstrap must pass through `engineos proof launchpad --runtime`.
- QuakeSpasm must launch with user-provided assets through `engineos run quake`.
- DRM output validation must pass through `engineos outputs validate --single`.
- Terminal launch fallback must be checked through `engineos terminal`.
- Bare-metal crash bundles must be collected with `engineos crash-bundle --bare-metal`.
- Hardware handoff must run through `engineos proof hardware-ready` before USB boot testing.
- Input capture/release and recovery TTY must be manually confirmed on hardware.
REPORT
}

release_checklist() {
  local dry_run=false
  local out_dir="${ENGINEOS_OUT_DIR:-$ROOT/out}"
  local export_dir=""
  local report=""
  local report_dir="${ENGINEOS_RELEASE_DIR:-$ROOT/artifacts/release}"
  local profile
  local iso
  local checksum

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
      --report)
        shift
        report="${1:-}"
        [[ -n "$report" ]] || die "--report requires a path"
        ;;
      help|--help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown release checklist option: $1"
        ;;
    esac
    shift
  done

  if [[ -z "$report" ]]; then
    mkdir -p "$report_dir"
    report="$report_dir/mvp-rc-$(timestamp_utc).md"
  else
    mkdir -p "$(dirname "$report")"
  fi

  printf 'EngineOS release checklist\n'
  printf '  dry_run: %s\n' "$dry_run"
  printf '  out:     %s\n' "$out_dir"
  printf '  report:  %s\n' "$report"
  [[ -n "$export_dir" ]] && printf '  export:  %s\n' "$export_dir"

  append_report_header "$report" "$([[ "$dry_run" == true ]] && printf dry-run || printf real)" "$out_dir" "$export_dir"

  if [[ "$dry_run" == true ]]; then
    {
      printf '## Artifact Expectations\n\n'
      printf -- '- Expected EngineDev ISO: `%s/EngineDevOS-*.iso`\n' "$out_dir"
      printf -- '- Expected EngineRuntime ISO: `%s/EngineRuntimeOS-*.iso`\n' "$out_dir"
      printf -- '- Expected checksums: `*.iso.sha256`\n'
      printf '\n'
    } >>"$report"
    append_report_package_expectations "$report"
    append_report_commands "$report"
    printf 'Dry-run only. Build both ISOs, then re-run without --dry-run.\n'
    return
  fi

  [[ -d "$out_dir" ]] || die "release out directory missing: $out_dir"

  for profile in enginedev engineruntime; do
    iso="$(latest_iso_for_profile "$profile" "$out_dir" || true)"
    [[ -n "$iso" ]] || die "missing $(profile_iso_prefix "$profile") ISO in $out_dir"
    checksum="$iso.sha256"
    have_cmd sha256sum || die "sha256sum is required for release checksums"
    (cd "$(dirname "$iso")" && sha256sum "$(basename "$iso")" >"$(basename "$checksum")")
    [[ -f "$checksum" ]] || die "checksum was not created: $checksum"
    append_report_artifact "$report" "$profile" "$iso" "$checksum"
  done

  if [[ -n "$export_dir" ]]; then
    "$SCRIPT_DIR/artifacts.sh" export "$export_dir" "$out_dir" >>"$report"
  fi

  append_report_package_expectations "$report"
  append_report_commands "$report"
  printf 'Release checklist report: %s\n' "$report"
}

case "$ACTION" in
  checklist)
    release_checklist "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "unknown release action: $ACTION"
    ;;
esac
