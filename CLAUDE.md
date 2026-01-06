# Spotify Private Session Auto-Enabler

## What This Does

Automatically keeps Spotify's Private Session enabled on macOS so your listening history on this device doesn't affect your Spotify recommendations or taste profile. Useful for work/focus playlists that don't represent your actual music taste.

## How It Works

1. **Hammerspoon** watches for Spotify app launch/quit events and **system sleep/wake events**
2. When Spotify launches, waits 2 seconds then enables Private Session via **UI automation** (AppleScript clicks the Spotify menu)
3. Tracks when Private Session was enabled (using monotonic time for accuracy)
4. Schedules a refresh 30 minutes before the 6-hour expiry (Spotify auto-disables Private Session after 6 hours)
5. **Persists state to file** for recovery across Hammerspoon restarts
6. **Re-enables on wake** from sleep (since timers pause during sleep)
7. Shows a menubar icon when Private Session is active

## Key Files

```
spotify-private.lua         # Main Hammerspoon module (symlinked to ~/.hammerspoon/)
spotify-private-core.lua    # Pure logic functions (testable without Hammerspoon)
spotify-private-core_spec.lua  # Busted tests for core logic
icon-private.png            # Menubar icon - SF Symbol "wave.3.down.circle.fill" exported at 66x64px
install.sh                  # Creates symlinks to ~/.hammerspoon/
```

## Architecture Decisions

### Why UI Automation?
Spotify doesn't expose Private Session via:
- Web API
- AppleScript dictionary
- Keyboard shortcuts
- URL schemes

UI automation (clicking the Spotify menu) is the only viable approach. It's stable across Spotify updates since menu structure rarely changes.

### Why Not Frequent Polling?
Early versions checked every 10 minutes, causing visible UI flicker (menu opening/closing). Current approach:
- Check once on Spotify launch
- Schedule single refresh at 5.5 hours
- No polling in between = no UI glitches

### Menubar Icon
- Uses SF Symbols exported as PNG (template mode for light/dark adaptation)
- Icon only appears when Spotify is running with Private Session active
- Click icon to manually trigger a check

## Configuration (in spotify-private-core.lua)

```lua
PRIVATE_SESSION_DURATION = 6 * 60 * 60    -- Spotify's 6-hour limit
REFRESH_BEFORE_EXPIRY = 30 * 60           -- Refresh 30 min before expiry
WAKE_VERIFICATION_DELAY = 30 * 60         -- Verify sooner after wake
DEBOUNCE_INTERVAL = 5                     -- Min seconds between checks
SHORT_SLEEP_THRESHOLD = 5 * 60            -- Skip check if sleep < 5 min
```

## Testing

### Manual Testing
1. Reload Hammerspoon: `hs -c 'hs.reload()'`
2. Check logs: `hs -c 'hs.console.getConsole()' | grep spotify`
3. Manual trigger: Click the menubar icon

### Automated Tests (Busted)
The core logic is extracted into `spotify-private-core.lua` for testability.

```bash
# Install dependencies (one-time)
brew install luarocks
luarocks install busted

# Run tests
busted spotify-private-core_spec.lua
```

Tests cover: time calculations, debounce logic, sleep detection, state serialization/deserialization.

## Requirements

- macOS
- Hammerspoon (`brew install --cask hammerspoon`)
- Accessibility permission for Hammerspoon (System Settings > Privacy & Security > Accessibility)
- SF Symbols app for icon editing (`brew install --cask sf-symbols`)

## Known Limitations

1. **UI flash on enable** - The AppleScript briefly opens Spotify's menu. Unavoidable without API access.

## Future Improvements to Consider

- [ ] Add "pause" functionality (temporarily disable auto-enable)
- [ ] Different icons for different states (enabled vs. pending refresh)
- [ ] Menu dropdown with options instead of just click-to-refresh
- [ ] Notification when refresh happens (optional, off by default)

## Troubleshooting

**Icon not appearing:**
- Check Hammerspoon console for errors
- Verify `icon-private.png` exists in `~/.hammerspoon/`
- Ensure Spotify is running

**Private Session not enabling:**
- Grant Accessibility permission to Hammerspoon
- Check that Spotify's menu has "Private Session" option (not available on web player)

**UI glitch still happening:**
- Should only happen on Spotify launch and once every ~5.5 hours
- If happening more frequently, check for multiple Hammerspoon configs loading the module
