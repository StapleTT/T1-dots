# Match the interactive Fish environment.
typeset -U path
path=("$HOME/.local/bin" "$HOME/models/llama.cpp/build/bin" $path "$HOME/.lmstudio/bin")
export PATH

HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt EXTENDED_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_FIND_NO_DUPS
setopt HIST_IGNORE_SPACE HIST_SAVE_NO_DUPS AUTO_CD INTERACTIVE_COMMENTS

mkdir -p "$HOME/.cache/zsh"
autoload -Uz compinit
compinit -d "$HOME/.cache/zsh/zcompdump-$ZSH_VERSION"
zmodload zsh/complist
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' completer _expand _complete _ignored

bindkey -e
bindkey '^[[3~' delete-char
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[1;5C' forward-word
bindkey '^[[1;5D' backward-word
bindkey '^ ' autosuggest-accept

alias clear="printf '\033[2J\033[3J\033[1;1H'"
alias celar=clear
alias claer=clear
alias pamcan=pacman
alias q='qs -c ii'
[[ $TERM != linux ]] && alias ls='eza --icons=auto'
[[ $TERM == xterm-kitty ]] && alias ssh='kitten ssh'

# Shortcut bindings. Colours come from kitty's theme.conf (the old illogical-impulse
# sequences.txt replay was removed: it overrode the palette with purple/green).
source "$HOME/.config/zshrc.d/shortcuts.zsh"

if [[ $TERM != linux ]] && (( $+commands[starship] )); then
    eval "$(starship init zsh)"
fi

ZSH_AUTOSUGGEST_STRATEGY=(history completion)
source "/usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
source "/usr/share/zsh/plugins/zsh-history-substring-search/zsh-history-substring-search.zsh"
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down
bindkey '^[OA' history-substring-search-up
bindkey '^[OB' history-substring-search-down

# Highlighting must load after widgets and other plugins.
source "/usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
