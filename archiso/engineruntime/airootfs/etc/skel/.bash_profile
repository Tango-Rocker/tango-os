if [[ -f ~/.bashrc ]]; then
  . ~/.bashrc
fi

printf 'EngineRuntime OS\n'
if command -v engineos-recovery-help >/dev/null 2>&1; then
  engineos-recovery-help
else
  printf 'Recovery shell available. Try: engineos logs runtime --last 200\n'
fi
