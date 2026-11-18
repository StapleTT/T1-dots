#!/bin/sh
# Change the wallpaper: pick an image (zenity; or pass a path), show it on every monitor filling the screen (cover,
# cropping the overflow), and save it in hyprpaper.conf so it survives restarts. Quickshell's lock screen and overview
# read the wallpaper from that file too.
conf="$HOME/.config/hypr/hyprpaper.conf"

current=$(sed -n 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//p' "$conf" | head -1 | sed "s|^~|$HOME|")
start=$(dirname "${current:-$HOME/Pictures/Wallpapers/x}")

file=${1:-$(zenity --file-selection --title="Choose a wallpaper" --filename="$start/" \
    --file-filter="Images | *.png *.jpg *.jpeg *.webp *.jxl *.bmp *.PNG *.JPG *.JPEG" --file-filter="All files | *")} || exit 0
[ -f "$file" ] || { notify-send "Wallpaper" "Not a file: $file"; exit 1; }

hyprctl hyprpaper wallpaper ",$file,cover" >/dev/null || { notify-send "Wallpaper" "hyprpaper didn't take $file"; exit 1; }

# Save with ~ for files under home; escape what sed's replacement treats specially
short=$(printf '%s' "$file" | sed "s|^$HOME/|~/|" | sed 's/[\\&|]/\\&/g')
tmp=$(mktemp)
sed "s|^\([[:space:]]*path[[:space:]]*=[[:space:]]*\).*|\1$short|; s|^\([[:space:]]*fit_mode[[:space:]]*=[[:space:]]*\).*|\1cover|" "$conf" > "$tmp"
# Rewrite in place (same file, not a new one) so Quickshell's file watch on hyprpaper.conf sees the change
cat "$tmp" > "$conf" && rm -f "$tmp"
