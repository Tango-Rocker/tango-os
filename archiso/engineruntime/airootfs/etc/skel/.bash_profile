if [[ -f ~/.bashrc ]]; then
  . ~/.bashrc
fi

printf 'EngineRuntime OS\n'
if command -v engineos-recovery-help >/dev/null 2>&1; then
  engineos-recovery-help
else
  printf 'Recovery shell available. Try: eos-logs runtime --last 200\n'
fi

if command -v eos-observe >/dev/null 2>&1; then
  eos-observe prompt-login --shell bash || true
  eval "$(eos-observe hook bash 2>/dev/null)" || true
fi
