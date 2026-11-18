# Start Hyprland on tty1 for installs without a display manager.
if [[ -o interactive && -z $DISPLAY && -z $WAYLAND_DISPLAY && $XDG_VTNR == 1 ]]; then
    mkdir -p "$HOME/.cache"
    exec start-hyprland > "$HOME/.cache/hyprland.log" 2>&1
fi
