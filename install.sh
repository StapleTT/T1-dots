#!/usr/bin/env bash
# Set up a fresh Arch install with these dotfiles. Safe to re-run.
#   ./install.sh            packages, dotfiles, services
#   ./install.sh --desktop  also the T1 desktop extras: Win11 VM passthrough, Sunshine
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
DESKTOP=false
[[ "${1:-}" == --desktop ]] && DESKTOP=true
[[ $EUID -ne 0 ]] || { echo "Run as your user, not root (sudo is used where needed)."; exit 1; }

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "Base tools and yay"
sudo pacman -S --needed --noconfirm base-devel git curl
if ! command -v yay >/dev/null; then
  tmp=$(mktemp -d)
  git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
  (cd "$tmp/yay-bin" && makepkg -si --noconfirm)
  rm -rf "$tmp"
fi

step "net-merge repository"
if ! grep -q '^\[net-merge\]' /etc/pacman.conf; then
  # lsign by pinned fingerprint: fails if the downloaded key isn't the expected one
  curl -fsSL https://rohit267.github.io/net-merge/apt/key.asc | sudo pacman-key --add -
  sudo pacman-key --lsign-key 0168C7AB77721656904811AE904F61E7F4F1C2A1
  printf '\n[net-merge]\nSigLevel = Required\nServer = https://rohit267.github.io/net-merge/arch/$arch\n' \
    | sudo tee -a /etc/pacman.conf >/dev/null
fi

step "Packages"
lists=("$REPO/packages/repo.txt" "$REPO/packages/aur.txt")
$DESKTOP && lists+=("$REPO/packages/desktop.txt")
yay -Syu --needed --noconfirm net-merge $(cat "${lists[@]}")

step "Zen browser (/opt/zen)"
if [[ ! -x /opt/zen/zen ]]; then
  curl -fL https://github.com/zen-browser/desktop/releases/latest/download/zen.linux-x86_64.tar.xz \
    | sudo tar -xJ -C /opt
fi
sudo ln -sfn /opt/zen/zen /usr/local/bin/zen
sudo install -Dm644 "$REPO/system/usr/share/applications/zen.desktop" /usr/share/applications/zen.desktop

step "Framework7 icon font"
f7=~/.local/share/fonts/framework7-icons
if [[ ! -f $f7/Framework7Icons-Regular.ttf ]]; then
  mkdir -p "$f7"
  curl -fLo "$f7/Framework7Icons-Regular.ttf" https://cdn.jsdelivr.net/npm/framework7-icons@5.0.5/fonts/Framework7Icons-Regular.ttf
  curl -fLo "$f7/LICENSE" https://cdn.jsdelivr.net/npm/framework7-icons@5.0.5/LICENSE
fi

step "Linking dotfiles into ~ (existing files are kept as *.bak)"
cd "$REPO/home"
find . -type f -printf '%P\n' | while read -r rel; do
  src=$REPO/home/$rel dst=$HOME/$rel
  [[ "$(readlink "$dst" 2>/dev/null)" == "$src" ]] && continue
  mkdir -p "$(dirname "$dst")"
  [[ -e $dst || -L $dst ]] && mv "$dst" "$dst.bak"
  ln -s "$src" "$dst"
done
cd "$REPO"
fc-cache -f >/dev/null

step "GPU symlinks for hyprland.lua"
# Machine-specific: point igpu-card (and nvidia-card on hybrid machines) at the right /dev/dri/by-path card.
if [[ ! -e ~/.config/hypr/igpu-card ]]; then
  card=$(ls /dev/dri/by-path/*-card | head -n1)
  ln -s "$card" ~/.config/hypr/igpu-card
  echo "igpu-card -> $card  (check this on multi-GPU machines: ls /dev/dri/by-path/)"
fi

step "Services and settings"
sudo systemctl enable --now NetworkManager bluetooth
sudo systemctl enable gdm
[[ "$(getent passwd "$USER" | cut -d: -f7)" == /usr/bin/fish ]] || chsh -s /usr/bin/fish
sudo usermod -aG i2c "$USER"
echo i2c-dev | sudo tee /etc/modules-load.d/i2c-dev.conf >/dev/null
# dbus-run-session so gsettings also works from a TTY before the first graphical login
dbus-run-session -- sh -c '
  gsettings set org.gnome.desktop.interface gtk-theme adw-gtk3-dark
  gsettings set org.gnome.desktop.interface color-scheme prefer-dark
  gsettings set org.gnome.desktop.interface font-name "Rubik 11"
  gsettings set org.gnome.desktop.interface cursor-theme MacOS-Tahoe-Cursor'

step "AirDrop (omdrop)"
[[ -d ~/omdrop-plugin ]] || git clone https://github.com/netmojo-systems/omdrop-plugin.git ~/omdrop-plugin
~/omdrop-plugin/bin/omdrop setup
~/omdrop-plugin/bin/omdrop dir "$HOME"

if $DESKTOP; then
  step "Desktop extras: VM passthrough, Sunshine"
  cd "$REPO/system"
  find . -type f -printf '%P\n' | while read -r rel; do
    sudo install -Dm"$(stat -c %a "$rel")" "$rel" "/$rel"
  done
  cd "$REPO"
  sudo udevadm control --reload
  sudo systemctl enable libvirtd sunshine-eth-route
  systemctl --user enable app-dev.lizardbyte.app.Sunshine.service
  echo "Define the win11 VM yourself: virsh define <exported win11.xml>"
fi

step "Done. Reboot, then log in to Hyprland through GDM."
