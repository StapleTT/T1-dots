#!/bin/sh
# Screenshot with grim (+ slurp for regions), always copied to the clipboard.
# Usage: screenshot.sh region|screen|window [save]
#   save: also keep the PNG in ~/Pictures/Screenshots
set -eu

case "${1:-region}" in
    region)
        # Styled like the bar: dimmed screen, white outline. Esc / right click cancels.
        geom=$(slurp -d -b '#00000055' -c '#ffffffdd' -s '#ffffff12' -w 2 -F Rubik) || exit 0
        ;;
    screen)
        output=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')
        ;;
    window)
        geom=$(hyprctl activewindow -j | jq -r 'if .at then "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])" else empty end')
        [ -n "$geom" ] || { notify-send -a Screenshot "No window to capture"; exit 1; }
        ;;
    *)
        echo "usage: $0 region|screen|window [save]" >&2
        exit 2
        ;;
esac

if [ "${2:-}" = save ]; then
    dir="$HOME/Pictures/Screenshots"
    mkdir -p "$dir"
    file="$dir/Screenshot_$(date +%Y-%m-%d_%H-%M-%S).png"
else
    file=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/screenshot-XXXXXX.png")
    trap 'rm -f "$file"' EXIT
fi

if [ -n "${output:-}" ]; then
    grim -o "$output" "$file"
else
    grim -g "$geom" "$file"
fi
wl-copy --type image/png < "$file"

if [ "${2:-}" = save ]; then
    notify-send -a Screenshot "Screenshot saved and copied" "$file"
else
    notify-send -a Screenshot "Screenshot copied"
fi
