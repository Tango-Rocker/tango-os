if [[ -o interactive ]]; then
  printf 'EngineDev OS\n'
  printf 'Try: eos-doctor --vm\n'
  if [[ -z "${TMUX:-}" && "${ENGINEOS_AUTO_TMUX:-1}" == "1" ]] &&
      command -v tmux >/dev/null 2>&1; then
    exec tmux new-session -A -s engineos
  fi
fi
