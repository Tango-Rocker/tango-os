#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/../.." && pwd -P)"
# shellcheck source=../scripts/common.sh
source "$root/tools/scripts/common.sh"

for cmd in $(engineos_eos_commands); do
  install -Dm755 "$script_dir/eos-wrapper" "$script_dir/$cmd"
done
