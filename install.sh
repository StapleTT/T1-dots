#!/usr/bin/env bash
# Set up a fresh Arch install with these dotfiles. Safe to re-run.
#   ./install.sh                 asks for the install type
#   ./install.sh --minimal       Hyprland, Quickshell and what the desktop needs; log in on tty1
#   ./install.sh --desktop       minimal + GDM
#   ./install.sh --full          desktop + apps: Zen, 1Password, LocalSend, net-merge, mpv
#   add --vm                     T1 only: Win11 VM passthrough (implies at least --desktop)
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
TIER="" VM=false
for arg; do
  case $arg in
    --minimal|--desktop|--full) TIER=${arg#--} ;;
    --vm) VM=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done
[[ $EUID -ne 0 ]] || { echo "Run as your user, not root (sudo is used where needed)."; exit 1; }

if [[ -z $TIER ]]; then
  echo "Install type:"
  echo "  1) minimal  Hyprland, Quickshell and what the desktop needs; log in on tty1"
  echo "  2) desktop  minimal + GDM login screen"
  echo "  3) full     desktop + apps: Zen, 1Password, LocalSend, net-merge, mpv"
  while [[ -z $TIER ]]; do
    read -rp "Choose [1-3]: " choice </dev/tty
    case $choice in 1) TIER=minimal ;; 2) TIER=desktop ;; 3) TIER=full ;; esac
  done
fi
# The libvirt hook stops and restarts GDM around GPU handover
$VM && [[ $TIER == minimal ]] && TIER=desktop
# at_least desktop|full: whether the chosen tier includes that one
at_least() { [[ $1 == desktop && $TIER != minimal ]] || [[ $TIER == full ]]; }

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "Base tools and yay"
sudo pacman -S --needed --noconfirm base-devel git curl
if ! command -v yay >/dev/null; then
  tmp=$(mktemp -d)
  git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
  (cd "$tmp/yay-bin" && makepkg -si --noconfirm)
  rm -rf "$tmp"
fi

if at_least full && ! grep -q '^\[net-merge\]' /etc/pacman.conf; then
  step "net-merge repository"
  # lsign by pinned fingerprint: fails if the downloaded key isn't the expected one
  curl -fsSL https://rohit267.github.io/net-merge/apt/key.asc | sudo pacman-key --add -
  sudo pacman-key --lsign-key 0168C7AB77721656904811AE904F61E7F4F1C2A1
  printf '\n[net-merge]\nSigLevel = Required\nServer = https://rohit267.github.io/net-merge/arch/$arch\n' \
    | sudo tee -a /etc/pacman.conf >/dev/null
fi

step "Packages ($TIER$($VM && echo ' + vm'))"
lists=("$REPO/packages/repo.txt" "$REPO/packages/aur.txt")
at_least desktop && lists+=("$REPO/packages/desktop.txt")
at_least full && lists+=("$REPO/packages/full.txt")
$VM && lists+=("$REPO/packages/vm.txt")
yay -Syu --needed --noconfirm $(cat "${lists[@]}")

if at_least full; then
  step "Zen browser (/opt/zen)"
  if [[ ! -x /opt/zen/zen ]]; then
    curl -fL https://github.com/zen-browser/desktop/releases/latest/download/zen.linux-x86_64.tar.xz \
      | sudo tar -xJ -C /opt
  fi
  sudo ln -sfn /opt/zen/zen /usr/local/bin/zen
  sudo install -Dm644 "$REPO/system/usr/share/applications/zen.desktop" /usr/share/applications/zen.desktop
fi

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

step "Qt theme (qt6ct)"
# Generated rather than linked: qt6ct needs an absolute path to the colour scheme
mkdir -p ~/.config/qt6ct
cat > ~/.config/qt6ct/qt6ct.conf <<EOF
[Appearance]
color_scheme_path=$HOME/.local/share/color-schemes/Island.colors
custom_palette=true
icon_theme=breeze-plus-dark
standard_dialogs=default
style=Darkly

[Fonts]
fixed="JetBrainsMono Nerd Font,11,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
general="Rubik,11,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
EOF

step "GPU symlinks for hyprland.lua"
# Machine-specific: point igpu-card (and nvidia-card on hybrid machines) at the right /dev/dri/by-path card.
if [[ ! -e ~/.config/hypr/igpu-card ]]; then
  card=$(ls /dev/dri/by-path/*-card | head -n1)
  ln -s "$card" ~/.config/hypr/igpu-card
  echo "igpu-card -> $card  (check this on multi-GPU machines: ls /dev/dri/by-path/)"
fi

step "Services and settings"
sudo systemctl enable --now NetworkManager bluetooth
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

at_least desktop && sudo systemctl enable gdm

if $VM; then
  step "VM passthrough"
  cd "$REPO/system"
  # usr/share/applications is zen.desktop, installed with Zen above
  find . -type f -not -path './usr/share/applications/*' -printf '%P\n' | while read -r rel; do
    sudo install -Dm"$(stat -c %a "$rel")" "$rel" "/$rel"
  done
  cd "$REPO"
  sudo udevadm control --reload
  sudo systemctl enable libvirtd
  echo "Define the win11 VM yourself: virsh define <exported win11.xml>"
fi

if at_least desktop; then
  step "Done. Reboot and log in to Hyprland from GDM."
else
  step "Done. Reboot and log in on tty1; fish starts Hyprland (conf.d/auto-Hypr.fish)."
fi
