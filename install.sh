#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
INSTALL_PREFIX="/opt/mantle"
LAUNCHDEST="$HOME/Library/LaunchAgents/com.mantle.tool.plist"
LOG_DIR="$HOME/Library/Logs/Mantle"

echo "Will do installation script"

# Acquire sudo credentials early (for /opt)
echo "Requesting sudo permissions for /opt..."
sudo -v

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$LOG_DIR"

# Create install dirs (needs sudo)
sudo mkdir -p "$INSTALL_PREFIX/bin"
sudo mkdir -p "$INSTALL_PREFIX/lib"

# Build
if [ -f "$BUILD_DIR/mantle" ]; then
    rm -rf "$BUILD_DIR/"
fi

if [ ! -f "$BUILD_DIR/mantle" ]; then
    echo "Building Mantle..."
    "$SCRIPT_DIR/build.sh"
fi

# Verify build artifacts exist
if [ ! -f "$BUILD_DIR/mantle" ]; then
    echo "Error: mantle executable not found in $BUILD_DIR"
    exit 1
fi

if [ ! -f "$BUILD_DIR/libcore.dylib" ]; then
    echo "Error: libcore.dylib not found in $BUILD_DIR"
    exit 1
fi

# Install binaries (needs sudo)
echo "Installing mantle to $INSTALL_PREFIX/bin/mantle..."
sudo cp "$BUILD_DIR/mantle" "$INSTALL_PREFIX/bin/mantle"
sudo chmod 755 "$INSTALL_PREFIX/bin/mantle"

echo "Installing libcore.dylib to $INSTALL_PREFIX/libcore.dylib..."
sudo cp "$BUILD_DIR/libcore.dylib" "$INSTALL_PREFIX/libcore.dylib"
sudo chmod 755 "$INSTALL_PREFIX/libcore.dylib"

echo "Installing wm_std_lib to $INSTALL_PREFIX/wm_std_lib..."
sudo cp -r "$SCRIPT_DIR/wm_std_lib" "$INSTALL_PREFIX/"
sudo chown -R root:wheel "$INSTALL_PREFIX/wm_std_lib"
sudo chmod -R 755 "$INSTALL_PREFIX/wm_std_lib"

# Unload existing instance if running
echo "Checking for existing instance..."
if launchctl list | grep -q "com.mantle.tool"; then
    echo "Unloading existing mantle launch agent..."
    launchctl unload "$LAUNCHDEST" 2>/dev/null || true
fi

# Generate and install launch agent plist
echo "Installing launch agent to $LAUNCHDEST..."
cat > "$LAUNCHDEST" << EOF
<?xml version="1.0" encoding="UTF-8" ?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mantle.tool</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>/usr/bin/sudo -n /opt/mantle/bin/mantle /Users/bedtime/Developer/Mantle/example_springy.js</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/mantle.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/mantle.err</string>
</dict>
</plist>
EOF

chmod 644 "$LAUNCHDEST"

sudo install -m 440 -o root -g wheel ./sudoers-mantle-root /etc/sudoers.d/mantle-root
echo "sudoers file installed and secured."

# Load the launch agent (must NOT be sudo)
echo "Loading mantle launch agent..."
launchctl load "$LAUNCHDEST"

echo ""
echo "Mantle has been installed to $INSTALL_PREFIX"
echo "Launch Agent: $LAUNCHDEST"
echo ""
echo "To check status:"
echo "  launchctl list | grep mantle"
echo ""
echo "To view logs:"
echo "  tail -f $LOG_DIR/mantle.log"
echo ""
echo "To unload:"
echo "  launchctl unload $LAUNCHDEST"
