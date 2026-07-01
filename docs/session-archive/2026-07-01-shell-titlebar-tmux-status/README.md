# Shell Titlebar and Tmux Status Session

Date: 2026-07-01 UTC

This archive records the focused follow-up that removed the visible foot
terminal titlebar in the GL shell path and made the default tmux status line
more informative.

## Outcome

- `tools/scripts/terminal_launcher.sh` now adds foot CSD overrides by default:
  - `--override csd.preferred=none`
  - `--override csd.size=0`
- The override is controlled by `ENGINEOS_TERMINAL_DECORATIONS`; any value other
  than `none` skips the no-titlebar foot arguments.
- The terminal launcher still preserves app metadata and tmux session startup
  arguments for foot, alacritty, kitty, and wezterm.
- The managed tmux config now uses a colored status line with:
  - tmux session name
  - hostname
  - current pane command
  - window and pane index
  - current pane path
  - date and time
- The same tmux status defaults were synced to:
  - `tools/post-install-payload/assets/tmux.conf`
  - `archiso/enginedev/airootfs/etc/skel/.tmux.conf`
  - `archiso/engineruntime/airootfs/etc/skel/.tmux.conf`

## Validation

Focused source checks passed:

```bash
bash -n tools/scripts/terminal_launcher.sh tools/eos/test/test_runner.sh tools/post-install-payload/scripts/setup_dev_environment.sh
env -u ENGINEOS_SCRIPT_DIR -u SCRIPT_DIR -u ENGINEOS_ROOT ./tools/eos/test/test_runner.sh terminal
env -u ENGINEOS_SCRIPT_DIR -u SCRIPT_DIR -u ENGINEOS_ROOT ./tools/eos/test/test_runner.sh post-first-deploy
env -u ENGINEOS_SCRIPT_DIR -u SCRIPT_DIR -u ENGINEOS_ROOT ./tools/eos/test/test_runner.sh shell-actions
foot --check-config -o csd.preferred=none -o csd.size=0
tmux -L engineos-check -f tools/post-install-payload/assets/tmux.conf start-server \; show -g status-style \; show -g status-left \; show -g status-right \; kill-server
```

Observed tmux status settings from the isolated check:

```text
status-style bg=colour235,fg=colour250
status-left "#[fg=colour16,bg=colour39,bold] #S #[fg=colour39,bg=colour236] #[fg=colour250,bg=colour236]#H #[fg=colour236,bg=colour235] "
status-right "#[fg=colour245]#{pane_current_command} #[fg=colour39]#I:#P #[fg=colour250]#{pane_current_path} #[fg=colour214]%Y-%m-%d #[fg=colour82]%H:%M "
```

## Notes

- A plain `./tools/engineos/eos-test terminal` run resolved to installed
  `/usr/lib/engineos` scripts because the live environment exported
  `ENGINEOS_SCRIPT_DIR`; source validation used the env-cleared commands above.
- The checkout was already dirty from the broader desktop update session. This
  record only covers the titlebar, tmux status, and focused test additions.
