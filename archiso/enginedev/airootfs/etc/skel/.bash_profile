if [[ -f ~/.bashrc ]]; then
  . ~/.bashrc
fi

printf 'EngineDev OS\n'
printf 'Try: eos-doctor --vm\n'

if command -v eos-observe >/dev/null 2>&1; then
  eos-observe prompt-login --shell bash || true
  eval "$(eos-observe hook bash 2>/dev/null)" || true
fi
