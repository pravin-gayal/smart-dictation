#!/usr/bin/env bash
set -euo pipefail

echo "=== smart-dictation uninstall ==="
echo ""

PLIST="$HOME/Library/LaunchAgents/com.pravingayal.smart-dictation.plist"

# 1. Unload LaunchAgent
echo "[1/2] Unloading LaunchAgent..."
if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST"
    echo "      LaunchAgent unloaded."
else
    echo "      LaunchAgent plist not found at $PLIST — skipping unload."
fi
echo ""

# 2. Remove plist from LaunchAgents
echo "[2/2] Removing LaunchAgent plist..."
if [ -f "$PLIST" ]; then
    rm "$PLIST"
    echo "      Removed $PLIST"
else
    echo "      Plist already absent — nothing to remove."
fi
echo ""

echo "Uninstalled. Binary and model files retained in Resources/."
