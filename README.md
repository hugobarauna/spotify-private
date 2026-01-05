# Spotify Private Session Auto-Enabler

Automatically keeps Spotify's Private Session enabled on macOS, ensuring your listening history on this device never affects your recommendations or taste profile.

Perfect for work/focus playlists that don't represent your actual music taste.

## Features

- Enables Private Session automatically when Spotify launches
- Refreshes before Spotify's 6-hour auto-expiry
- Minimal UI interruption (only on launch and once every ~5.5 hours)
- Menubar icon shows when Private Session is active
- Click icon to manually trigger refresh

## Requirements

- macOS
- [Hammerspoon](https://www.hammerspoon.org/)

## Installation

1. Install Hammerspoon:
   ```bash
   brew install --cask hammerspoon
   ```

2. Clone this repo and run the installer:
   ```bash
   git clone https://github.com/yourusername/spotify-private.git
   cd spotify-private
   ./install.sh
   ```

3. Grant Accessibility permission to Hammerspoon:
   - System Settings → Privacy & Security → Accessibility → Enable Hammerspoon

4. Reload Hammerspoon config (click menubar icon → Reload Config)

## How It Works

Spotify doesn't provide an API to control Private Session, so this tool uses UI automation (AppleScript) to click the Spotify menu and toggle Private Session.

The script:
1. Watches for Spotify to launch
2. Enables Private Session after a short delay
3. Schedules a refresh 30 minutes before the 6-hour expiry
4. Shows a menubar icon when active

## Configuration

Edit `spotify-private.lua` to adjust timing:

```lua
PRIVATE_SESSION_DURATION = 6 * 60 * 60    -- Spotify's 6-hour limit
REFRESH_BEFORE_EXPIRY = 30 * 60           -- Refresh 30 min before expiry
LAUNCH_DELAY = 2                          -- Wait after Spotify launch
```

## Troubleshooting

**Icon not appearing:**
- Ensure Spotify is running
- Check Hammerspoon has Accessibility permission

**Private Session not enabling:**
- Verify the menu item exists: Spotify menu → Private Session
- Check Hammerspoon console for errors: `hs -c 'hs.console.getConsole()'`

## License

MIT
