#!/bin/bash
set -e

INSTALL_PREFIX="/opt/mantle"
LAUNCHDEST="$HOME/Library/LaunchAgents/com.corebedtime.mantle.tool.plist"
LOG_DIR="$HOME/Library/Logs/Mantle"
SUDOERS_FILE="/etc/sudoers.d/mantle-root"

echo "Uninstalling Mantle..."

# Acquire sudo credentials early
echo "Requesting sudo permissions..."
sudo -v

# Unload launch agent if running
echo "Checking for running launch agent..."
if launchctl list | grep -q "com.corebedtime.mantle.tool"; then
    echo "Unloading mantle launch agent..."
    launchctl unload "$LAUNCHDEST" 2>/dev/null || true
    sleep 1
fi

# Remove launch agent plist
if [ -f "$LAUNCHDEST" ]; then
    echo "Removing launch agent plist..."
    rm -f "$LAUNCHDEST"
fi

# Remove sudoers file
if [ -f "$SUDOERS_FILE" ]; then
    echo "Removing sudoers file..."
    sudo rm -f "$SUDOERS_FILE"
fi

# Remove installation directory
if [ -d "$INSTALL_PREFIX" ]; then
    echo "Removing installation directory: $INSTALL_PREFIX"
    sudo rm -rf "$INSTALL_PREFIX"
fi

# Remove log directory
if [ -d "$LOG_DIR" ]; then
    echo "Removing log directory: $LOG_DIR"
    rm -rf "$LOG_DIR"
fi

echo ""
echo "Mantle has been uninstalled."

