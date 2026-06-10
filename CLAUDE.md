# Spotify Private Session Auto-Enabler

## What This Does

Automatically keeps Spotify's Private Session enabled on macOS so your listening history on this device doesn't affect your Spotify recommendations or taste profile. Useful for work/focus playlists that don't represent your actual music taste.

## How It Works

1. **Hammerspoon** watches for Spotify app launch/quit events and **system sleep/wake events**
2. When action is needed (Spotify launch, wake from sleep, refresh), shows a **notification with "Enable" button** instead of automatically stealing focus
3. User clicks the notification (or menubar icon) when ready - then it enables Private Session via **UI automation** (AppleScript clicks the Spotify menu)
4. After enabling, **hides the Spotify window** to minimize disruption
5. Tracks when Private Session was enabled (using monotonic time for accuracy)
6. Schedules a refresh 30 minutes before the 6-hour expiry (Spotify auto-disables Private Session after 6 hours)
7. **Persists state to file** for recovery across Hammerspoon restarts
8. Shows a menubar icon: **●** when active, **○** when pending user action

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

### UI Automation Constraints (probed live against Spotify 1.2.90)

These rules are load-bearing — violating any of them makes the toggle silently no-op:

1. **The "Private Session" menu item is disabled (`AXEnabled=false`) unless Spotify's window is visible AND Spotify is the frontmost app.** Clicking a disabled item reports success but does nothing. `reopen` is required to recreate a closed window (`activate` alone won't), and the item takes ~0.5-1s to become enabled after the window comes up — so the script polls `AXEnabled` instead of using fixed delays.
2. **The item only fires via open-menu-then-click-item.** Direct menu-closed clicks, `AXPress`, and synthesized mouse events (eventtap) all no-op in this Spotify build.
3. **`click` returning success does not mean the item toggled.** Every toggle re-reads `AXMenuItemMarkChar` and retries until the flip is confirmed.
4. **Reads are invisible.** `AXMenuItemMarkChar` is readable *without* opening the menu, so "is it already on?" checks and post-click verification never open the menu, steal focus, or flicker. Only an actual toggle opens the menu (and item clicks auto-close it — no Escape needed, no orphaned-menu risk).

### Why Not Frequent Polling?
Early versions checked every 10 minutes, causing visible UI flicker (menu opening/closing). Current approach:
- Check once on Spotify launch
- Schedule single refresh at 5.5 hours
- No polling in between = no UI glitches

### Menubar Icon
- **●** (filled) when Private Session is active - uses SF Symbols PNG (template mode for light/dark adaptation)
- **○** (empty) when pending user action - indicates you need to click to enable
- Click icon to enable/refresh Private Session
- Tooltip shows status and time until next refresh

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

### Automated Tests
The core logic is extracted into `spotify-private-core.lua` for testability.

```bash
# Zero-dependency runner (works with plain lua, no luarocks needed)
lua run_tests.lua

# Or with busted, if installed and working
busted spotify-private-core_spec.lua
```

Note: a Homebrew Lua major upgrade (e.g. 5.4 → 5.5) breaks `busted`/`luarocks`
launchers (they pin the removed interpreter path). `run_tests.lua` is a minimal
busted-compatible shim that keeps the spec runnable regardless.

Tests cover: time calculations, debounce logic, sleep detection, state serialization/deserialization.

## Requirements

- macOS
- Hammerspoon (`brew install --cask hammerspoon`)
- Accessibility permission for Hammerspoon (System Settings > Privacy & Security > Accessibility)
- Notifications enabled for Hammerspoon (System Settings > Notifications > Hammerspoon)
- SF Symbols app for icon editing (`brew install --cask sf-symbols`)

## Known Limitations

1. **UI flash on toggle** - Enabling/refreshing briefly raises Spotify's window and opens its menu (the menu item is disabled otherwise — see UI Automation Constraints). Unavoidable without API access. Checks/verification are invisible.

## Future Improvements to Consider

- [ ] Add "pause" functionality (temporarily disable auto-enable)
- [x] ~~Different icons for different states~~ - Now shows ● (active) vs ○ (pending)
- [ ] Menu dropdown with options instead of just click-to-refresh
- [x] ~~Notification when refresh happens~~ - Now shows notification asking for permission before any UI automation

## Troubleshooting

**Icon not appearing:**
- Check Hammerspoon console for errors
- Verify `icon-private.png` exists in `~/.hammerspoon/`
- Ensure Spotify is running

**Private Session not enabling:**
- Grant Accessibility permission to Hammerspoon
- Check that Spotify's menu has "Private Session" option (not available on web player)
- If the script reports `verify_failed`/`no_menubar`: the menu item never became enabled. Check that Spotify's window can actually open (e.g. not on a disconnected display) — the item stays disabled while the window is hidden/closed or Spotify isn't frontmost

**UI glitch still happening:**
- Should only happen on Spotify launch and once every ~5.5 hours
- If happening more frequently, check for multiple Hammerspoon configs loading the module
