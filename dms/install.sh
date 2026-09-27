#!/usr/bin/env bash
# Install (or update) the AI Limit Counter DankMaterialShell plugin for the current user.
# The plugin reads its data from the ai-limit-counter helper built from ../linux.
set -euo pipefail

PLUGIN_ID="aiLimitCounter"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_SRC="$ROOT/../linux"
BIN_DIR="$HOME/.local/bin"
PLUGIN_DEST="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/$PLUGIN_ID"

if ! command -v cargo &>/dev/null; then
  echo "cargo is required to build the helper (sudo dnf install cargo)" >&2
  exit 1
fi

cargo build --release --manifest-path "$HELPER_SRC/Cargo.toml"
install -Dm755 "$HELPER_SRC/target/release/ai-limit-counter" "$BIN_DIR/ai-limit-counter"
echo "Installed helper to $BIN_DIR/ai-limit-counter"

mkdir -p "$PLUGIN_DEST"
rm -rf "${PLUGIN_DEST:?}/"*
cp -r "$ROOT/$PLUGIN_ID/." "$PLUGIN_DEST/"
echo "Installed plugin to $PLUGIN_DEST"

if command -v dms &>/dev/null && dms ipc call plugins reload "$PLUGIN_ID" &>/dev/null; then
  echo "Reloaded the running plugin. A reload keeps the old format.js in memory, so if the"
  echo "bar shows \"!\" after an update, log out and back in to restart DMS."
else
  echo "In DMS: Settings → Plugins → Scan, enable AI Limit Counter, then add it to the bar."
fi
