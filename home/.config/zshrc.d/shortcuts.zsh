# Created by newuser for 5.9

bindkey '^H' backward-kill-word
bindkey '^Z' undo

# Ctrl+V pastes from the Wayland clipboard.
clipboard-paste() { LBUFFER+=$(wl-paste --no-newline 2>/dev/null) }
zle -N clipboard-paste
bindkey '^V' clipboard-paste
