#!/usr/bin/env bash
# Install (or update) the AI Limit Counter GNOME Shell extension for the current user.
set -euo pipefail

UUID="ailimitcounter@firatege.github.io"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$UUID"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$UUID"

mkdir -p "$DEST"
rm -rf "${DEST:?}/"*
cp -r "$SRC/." "$DEST/"
glib-compile-schemas "$DEST/schemas"

echo "Installed to $DEST"

if gnome-extensions info "$UUID" &>/dev/null; then
  gnome-extensions enable "$UUID"
  echo "Enabled. If it was already running, log out and back in to load the new version."
else
  echo "GNOME Shell hasn't seen the extension yet (Wayland can't reload the shell)."
  echo "Log out and back in, then run: gnome-extensions enable $UUID"
fi
