# EngineOS interactive zsh defaults.
export HISTFILE="${HISTFILE:-$HOME/.zsh_history}"
export HISTSIZE=1000000
export SAVEHIST=1000000

setopt append_history
setopt extended_history
setopt hist_expire_dups_first
setopt hist_find_no_dups
setopt hist_ignore_all_dups
setopt hist_ignore_space
setopt hist_reduce_blanks
setopt inc_append_history
setopt share_history

autoload -Uz compinit
if [[ -n ${ZDOTDIR:-} ]]; then
  compdump_file="$ZDOTDIR/.zcompdump"
else
  compdump_file="$HOME/.zcompdump"
fi
compinit -d "$compdump_file"
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

plugins=(git sudo tmux command-not-found colored-man-pages)
DISABLE_AUTO_UPDATE=true
ZSH_CACHE_DIR="${ZSH_CACHE_DIR:-$HOME/.cache/oh-my-zsh}"
ZSH_THEME="${ZSH_THEME:-robbyrussell}"
if [[ -r "${ZSH:-/usr/share/oh-my-zsh}/oh-my-zsh.sh" ]]; then
  export ZSH="${ZSH:-/usr/share/oh-my-zsh}"
  mkdir -p "$ZSH_CACHE_DIR"
  source "$ZSH/oh-my-zsh.sh"
else
  autoload -Uz colors vcs_info
  colors
  zstyle ':vcs_info:git:*' formats ' %F{blue}(%b)%f'
  precmd() { vcs_info; }
  PROMPT='%F{green}%n@%m%f:%F{cyan}%~%f${vcs_info_msg_0_}%# '
fi

[[ -r /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
[[ -r /usr/share/zsh/plugins/zsh-history-substring-search/zsh-history-substring-search.zsh ]] && source /usr/share/zsh/plugins/zsh-history-substring-search/zsh-history-substring-search.zsh
[[ -r /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[[ -r /usr/share/fzf/key-bindings.zsh ]] && source /usr/share/fzf/key-bindings.zsh
[[ -r /usr/share/fzf/completion.zsh ]] && source /usr/share/fzf/completion.zsh
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh --cmd cd)"

bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias t='tmux new-session -A -s engineos'
