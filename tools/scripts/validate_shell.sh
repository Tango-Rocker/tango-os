#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/common.sh"
ROOT="$(engineos_root)"
SHELL_SOURCE="$ROOT/shell/src/engineos-shell.c"

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
ok() { printf 'OK   %s\n' "$*"; }

if ! pkg-config --exists wlroots-0.19 &&
		! pkg-config --exists wlroots-0.18 &&
		! pkg-config --exists wlroots; then
	fail 'wlroots pkg-config modules unavailable'
fi
ok 'wlroots pkg-config modules available'

for marker in \
  'engineos_mux_client_connect' \
  'setup_native_terminal_scene' \
  'native_presentation_map' \
  'wlr_scene_subsurface_tree_set_clip' \
  'ENGINEOS_INPUT_GAME' \
  'engineos_mux_client_send_key'; do
  grep -F "$marker" "$SHELL_SOURCE" >/dev/null || fail "missing native shell marker: $marker"
  ok "native shell marker: $marker"
done

if rg -n 'ENGINEOS_MUX_MODE|--mux|launch-bounds|terminal-register|pane-(launch|focus|geometry|unbind)|ENGINEOS_PANE_LAUNCH_TOKEN|launchpad|engineos-tmux-(pane|window)' \
		--glob '!validate_shell.sh' \
    "$ROOT/shell" "$ROOT/tools/scripts" "$ROOT/tools/post-install-payload" >/dev/null; then
  fail 'retired mux bridge/bootstrap code remains'
fi
ok 'retired mux bridge/bootstrap code absent'

bash -n "$ROOT/tools/scripts/app.sh" "$ROOT/tools/scripts/game.sh" \
  "$ROOT/tools/scripts/shell_runner.sh" \
  "$ROOT/tools/post-install-payload/scripts/engineos-dev-shell-start"
python -c 'import pathlib,sys; compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")' \
  "$ROOT/tools/engineos/engine-image-preview"
ok 'native shell runtime scripts parse'
