if [[ -o interactive ]]; then
  printf 'EngineRuntime OS\n'
  if command -v engineos-recovery-help >/dev/null 2>&1; then
    engineos-recovery-help
  else
    printf 'Recovery shell available. Try: eos-logs runtime --last 200\n'
  fi
  if [[ -z "${TMUX:-}" && "${ENGINEOS_AUTO_TMUX:-1}" == "1" ]] &&
      command -v tmux >/dev/null 2>&1; then
    exec tmux new-session -A -s engineos
  fi
fi
