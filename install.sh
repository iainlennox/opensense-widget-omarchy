#!/usr/bin/env bash
# Install the OPNsense Widget as an Omarchy shell plugin.
#
# Copies the plugin into ~/.config/omarchy/plugins/opensense-widget/ and
# registers it in ~/.config/omarchy/shell.json so the shell loads it.
# The shell watches both directories, so no restart is normally required.
#
# Usage:
#   ./install.sh               # install panel (loads floating widget)
#   ./install.sh --bar         # also add a bar icon to the right section
#   ./install.sh --uninstall   # remove the plugin
set -euo pipefail

PLUGIN_ID="opensense-widget"
OMARCHY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy"
PLUGIN_DIR="$OMARCHY_DIR/plugins/$PLUGIN_ID"
SHELL_JSON="$OMARCHY_DIR/shell.json"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "--uninstall" ]; then
  echo "Removing $PLUGIN_DIR ..."
  rm -rf "$PLUGIN_DIR"
  if [ -f "$SHELL_JSON" ]; then
    jq --arg id "$PLUGIN_ID" \
      '.plugins = [ (.plugins // [])[] | select(.id != $id) ]' \
      "$SHELL_JSON" > "$SHELL_JSON.tmp" && mv "$SHELL_JSON.tmp" "$SHELL_JSON"
    # Remove the bar layout entry too, if present.
    jq --arg id "$PLUGIN_ID" \
      '.bar.layout.left = [ (.bar.layout.left // [])[] | select(.id != $id) ]
       | .bar.layout.center = [ (.bar.layout.center // [])[] | select(.id != $id) ]
       | .bar.layout.right = [ (.bar.layout.right // [])[] | select(.id != $id) ]' \
      "$SHELL_JSON" > "$SHELL_JSON.tmp" && mv "$SHELL_JSON.tmp" "$SHELL_JSON"
  fi
  echo "Uninstalled. The shell will pick this up shortly."
  exit 0
fi

echo "Installing $PLUGIN_ID ..."
mkdir -p "$PLUGIN_DIR"
cp "$HERE/manifest.json" "$HERE/Panel.qml" "$HERE/BarWidget.qml" \
   "$HERE/Model.js" "$HERE/config.js" "$HERE/opensense-status.py" "$PLUGIN_DIR/"
chmod +x "$PLUGIN_DIR/opensense-status.py"

if [ ! -f "$SHELL_JSON" ]; then
  echo "WARNING: $SHELL_JSON not found; cannot register the plugin."
  echo "Add this to shell.json manually under \"plugins\": [ { \"id\": \"$PLUGIN_ID\" } ]"
else
  # Register the panel (and optionally the bar widget) in shell.json.
  jq --arg id "$PLUGIN_ID" \
    '.plugins = (([.plugins[]?] + [{ id: $id }]) | unique_by(.id))' \
    "$SHELL_JSON" > "$SHELL_JSON.tmp" && mv "$SHELL_JSON.tmp" "$SHELL_JSON"

  if [ "${1:-}" = "--bar" ]; then
    jq --arg id "$PLUGIN_ID" \
      '.bar.layout.right = (([.bar.layout.right[]?] + [{ id: $id }]) | unique_by(.id))' \
      "$SHELL_JSON" > "$SHELL_JSON.tmp" && mv "$SHELL_JSON.tmp" "$SHELL_JSON"
    echo "Bar icon added to the right section."
  fi
fi

echo "Done. The floating OPNsense Widget should appear shortly."
echo "Open the gear (⚙) to configure your OPNsense API credentials."
