# Spotify Private Session Auto-Enabler

Automatically keeps Spotify's Private Session enabled on macOS, ensuring your listening history on this device never affects your recommendations or taste profile.

Perfect for work/focus playlists that don't represent your actual music taste.

## Features

- **Auto-enable on launch**: Activates Private Session whenever Spotify starts
- **Sleep/wake aware**: Re-enables after your Mac wakes (sessions expire during sleep)
- **Smart refresh**: Renews 30 minutes before Spotify's 6-hour auto-expiry
- **Persistent state**: Remembers session timing across Hammerspoon restarts
- **Focus-friendly**: Restores your previous app after toggling the menu
- **Menubar indicator**: Shows when Private Session is active
- **Manual trigger**: Click the icon to force a refresh anytime

## Requirements

- macOS
- [Hammerspoon](https://www.hammerspoon.org/)

## Installation

1. **Install Hammerspoon:**
   ```bash
   brew install --cask hammerspoon
   ```

2. **Clone and install:**
   ```bash
   git clone https://github.com/hugobarauna/spotify-private.git
   cd spotify-private
   ./install.sh
   ```

3. **Grant Accessibility permission to Hammerspoon:**
   - Open Hammerspoon (it should prompt you)
   - Or manually: System Settings → Privacy & Security → Accessibility → Enable Hammerspoon

4. **Start Hammerspoon** and you're done!

The menubar icon appears when Spotify is running with Private Session active.

## How It Works

Spotify doesn't provide an API for Private Session, so this tool uses **UI automation** (AppleScript) to interact with the Spotify menu.

1. **Watches events** — Spotify launch/quit, system sleep/wake
2. **Enables Private Session** — After a short delay to let Spotify initialize
3. **Schedules refresh** — 30 minutes before the 6-hour expiry
4. **Persists state** — Saves timing to disk for crash recovery
5. **Shows status** — Menubar icon indicates active session

## Configuration

Edit `spotify-private-core.lua` to adjust timing:

```lua
PRIVATE_SESSION_DURATION = 6 * 60 * 60    -- Spotify's 6-hour limit
REFRESH_BEFORE_EXPIRY = 30 * 60           -- Refresh 30 min before expiry
WAKE_VERIFICATION_DELAY = 30 * 60         -- Verify sooner after wake
DEBOUNCE_INTERVAL = 5                     -- Min seconds between checks
SHORT_SLEEP_THRESHOLD = 5 * 60            -- Skip check if sleep < 5 min
```

## Testing

The core logic is extracted into a separate module with tests:

```bash
# Install test framework (one-time)
brew install luarocks
luarocks install busted

# Run tests
busted spotify-private-core_spec.lua
```

## Troubleshooting

**Icon not appearing:**
- Ensure Spotify is running
- Check Hammerspoon has Accessibility permission
- Reload Hammerspoon: `hs -c 'hs.reload()'`

**Private Session not enabling:**
- Verify the menu item exists: Spotify menu → Private Session
- Check Hammerspoon console for errors:
  ```bash
  hs -c 'hs.console.getConsole()' | grep spotify
  ```

**Check current state:**
```bash
cat ~/.hammerspoon/spotify-private-state.json
```

## Files

```
spotify-private.lua         # Main Hammerspoon module
spotify-private-core.lua    # Pure logic (testable)
spotify-private-core_spec.lua  # Tests
install.sh                  # Installer (creates symlinks)
icon-private.png            # Menubar icon
```

## License

MIT
