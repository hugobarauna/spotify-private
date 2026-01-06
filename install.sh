#!/bin/bash
# Install script for Spotify Private Session auto-enabler

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMERSPOON_DIR="$HOME/.hammerspoon"
SOURCE_FILE="$SCRIPT_DIR/spotify-private.lua"
TARGET_FILE="$HAMMERSPOON_DIR/spotify-private.lua"
CORE_SOURCE="$SCRIPT_DIR/spotify-private-core.lua"
CORE_TARGET="$HAMMERSPOON_DIR/spotify-private-core.lua"
ICON_SOURCE="$SCRIPT_DIR/icon-private.png"
ICON_TARGET="$HAMMERSPOON_DIR/icon-private.png"
INIT_FILE="$HAMMERSPOON_DIR/init.lua"

echo "Installing Spotify Private Session auto-enabler..."

# Create .hammerspoon directory if it doesn't exist
if [ ! -d "$HAMMERSPOON_DIR" ]; then
    echo "Creating $HAMMERSPOON_DIR"
    mkdir -p "$HAMMERSPOON_DIR"
fi

# Create symlink to source file
if [ -L "$TARGET_FILE" ]; then
    echo "Removing existing symlink..."
    rm "$TARGET_FILE"
elif [ -f "$TARGET_FILE" ]; then
    echo "Backing up existing file to ${TARGET_FILE}.bak"
    mv "$TARGET_FILE" "${TARGET_FILE}.bak"
fi

echo "Creating symlink: $TARGET_FILE -> $SOURCE_FILE"
ln -s "$SOURCE_FILE" "$TARGET_FILE"

# Create symlink for core module
if [ -L "$CORE_TARGET" ]; then
    rm "$CORE_TARGET"
elif [ -f "$CORE_TARGET" ]; then
    rm "$CORE_TARGET"
fi
echo "Creating symlink: $CORE_TARGET -> $CORE_SOURCE"
ln -s "$CORE_SOURCE" "$CORE_TARGET"

# Create symlink for icon
if [ -L "$ICON_TARGET" ]; then
    rm "$ICON_TARGET"
elif [ -f "$ICON_TARGET" ]; then
    rm "$ICON_TARGET"
fi
echo "Creating symlink: $ICON_TARGET -> $ICON_SOURCE"
ln -s "$ICON_SOURCE" "$ICON_TARGET"

# Add require line to init.lua if not present
if [ ! -f "$INIT_FILE" ]; then
    echo "Creating $INIT_FILE"
    echo 'require("spotify-private")' > "$INIT_FILE"
elif ! grep -q 'require("spotify-private")' "$INIT_FILE"; then
    echo "Adding require line to $INIT_FILE"
    echo '' >> "$INIT_FILE"
    echo '-- Spotify Private Session auto-enabler' >> "$INIT_FILE"
    echo 'require("spotify-private")' >> "$INIT_FILE"
else
    echo "require line already present in $INIT_FILE"
fi

echo ""
echo "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Open Hammerspoon (it should be in /Applications)"
echo "  2. Grant Accessibility permission when prompted"
echo "     (System Settings > Privacy & Security > Accessibility > Hammerspoon)"
echo "  3. Click Hammerspoon menubar icon > 'Reload Config'"
echo ""
echo "You should see a wave icon in the menubar when Spotify is running"
echo "with Private Session enabled. The icon disappears when Spotify is not running."
