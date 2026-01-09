-- Spotify Private Session Auto-Enabler
-- Ensures Private Session is always enabled when Spotify is running
-- https://github.com/hugobarauna/spotify-private

local M = {}

-- Load core module (pure functions for testability)
local scriptDir = debug.getinfo(1, "S").source:match("@(.*/)")
local core = dofile((scriptDir or "") .. "spotify-private-core.lua")

-- Configuration (use defaults from core, with local overrides)
local CONFIG = core.DEFAULT_CONFIG
local LAUNCH_DELAY = 2  -- Seconds to wait after Spotify launches (Hammerspoon-specific)

-- State
local menubar = nil
local refreshTimer = nil
local appWatcher = nil
local sleepWatcher = nil
local lastState = nil
local lastEnabledTime = nil      -- Monotonic time when we last enabled Private Session
local lastWallClockEnabled = nil -- Wall clock time for persistence
local lastCheckTime = nil        -- For debouncing
local lastSleepTime = nil        -- Monotonic time when system went to sleep
local pendingEnable = false      -- True when waiting for user permission to enable
local pendingIsRefresh = false   -- True if pending enable is a refresh (needs forceRefresh)
local pendingNotification = nil  -- Active notification (to withdraw before showing new one)

-- Persistence file path
local STATE_FILE = hs.configdir .. "/spotify-private-state.json"

-- Icons (loaded in M.start())
local ICON_PRIVATE = nil
local ICON_PENDING = nil  -- Different icon when waiting for user to enable

-- Get monotonic time in seconds (not affected by clock changes)
local function monotonicTime()
    return hs.timer.absoluteTime() / 1e9  -- Convert nanoseconds to seconds
end

-- Get the directory where this script lives
local function getScriptDir()
    local info = debug.getinfo(1, "S")
    local path = info.source:match("@(.*/)")
    return path or hs.configdir .. "/"
end

-- Save state to file for persistence across restarts
local function saveState()
    local state = core.serializeState(lastWallClockEnabled)
    if state then
        local json = hs.json.encode(state)
        local file = io.open(STATE_FILE, "w")
        if file then
            file:write(json)
            file:close()
            print("[spotify-private] State saved to file")
        end
    end
end

-- Load state from file
local function loadState()
    local file = io.open(STATE_FILE, "r")
    if file then
        local content = file:read("*all")
        file:close()
        local ok, state = pcall(hs.json.decode, content)
        if ok then
            local enabledAt, elapsed = core.deserializeState(state, os.time(), CONFIG.PRIVATE_SESSION_DURATION)
            if enabledAt then
                print(string.format("[spotify-private] Loaded state: enabled %s ago", core.formatTime(elapsed)))
                return enabledAt, elapsed
            else
                print("[spotify-private] Loaded state: session expired or invalid")
            end
        end
    end
    return nil, nil
end

-- Clear persisted state
local function clearState()
    os.remove(STATE_FILE)
end

-- Debounce check: returns true if we should skip this check
local function shouldDebounce()
    local now = monotonicTime()
    if core.shouldDebounce(lastCheckTime, now, CONFIG.DEBOUNCE_INTERVAL) then
        print("[spotify-private] Debounced (too soon since last check)")
        return true
    end
    return false
end

-- Mark that a check is happening
local function markCheck()
    lastCheckTime = monotonicTime()
end

-- AppleScript to enable Private Session (checks first, then enables if needed)
-- Saves and restores frontmost app to minimize focus disruption
local CHECK_AND_ENABLE_SCRIPT = [[
set frontApp to path to frontmost application as text
tell application "Spotify" to activate
delay 0.3
tell application "System Events"
    tell process "Spotify"
        if not (exists menu bar 1) then
            tell application frontApp to activate
            return "no_menubar"
        end if
        try
            set spotifyMenu to menu bar item "Spotify" of menu bar 1
            click spotifyMenu
            delay 0.1
            set privateItem to menu item "Private Session" of menu 1 of spotifyMenu
            set isChecked to (value of attribute "AXMenuItemMarkChar" of privateItem) is not missing value
            if not isChecked then
                click privateItem
                delay 0.3
                -- Menu should auto-close after click, but ensure it's closed
                key code 53
                delay 0.1
                key code 53
                -- Hide Spotify window and return to previous app
                set visible to false
                tell application frontApp to activate
                return "enabled"
            else
                -- Close menu robustly with multiple escape attempts
                key code 53
                delay 0.1
                key code 53
                delay 0.1
                -- Hide Spotify window and return to previous app
                set visible to false
                tell application frontApp to activate
                return "already_enabled"
            end if
        on error errMsg
            -- Try hard to close any open menu
            key code 53
            delay 0.1
            key code 53
            delay 0.1
            key code 53
            tell application frontApp to activate
            return "error:" & errMsg
        end try
    end tell
end tell
]]

-- AppleScript to force re-enable Private Session (toggles off then on to reset timer)
-- Used during scheduled refresh to ensure Spotify's 6-hour timer is reset
local FORCE_REFRESH_SCRIPT = [[
set frontApp to path to frontmost application as text
tell application "Spotify" to activate
delay 0.3
tell application "System Events"
    tell process "Spotify"
        if not (exists menu bar 1) then
            tell application frontApp to activate
            return "no_menubar"
        end if
        try
            set spotifyMenu to menu bar item "Spotify" of menu bar 1
            click spotifyMenu
            delay 0.1
            set privateItem to menu item "Private Session" of menu 1 of spotifyMenu
            set isChecked to (value of attribute "AXMenuItemMarkChar" of privateItem) is not missing value
            if isChecked then
                -- Turn OFF first
                click privateItem
                delay 0.3
                -- Re-open menu and turn back ON
                click spotifyMenu
                delay 0.1
                set privateItem to menu item "Private Session" of menu 1 of spotifyMenu
                click privateItem
                delay 0.3
                -- Menu should auto-close after click, but ensure it's closed
                key code 53
                delay 0.1
                key code 53
                -- Hide Spotify window and return to previous app
                set visible to false
                tell application frontApp to activate
                return "refreshed"
            else
                -- Not enabled, just enable it
                click privateItem
                delay 0.3
                -- Ensure menu is closed
                key code 53
                delay 0.1
                key code 53
                -- Hide Spotify window and return to previous app
                set visible to false
                tell application frontApp to activate
                return "enabled"
            end if
        on error errMsg
            -- Try hard to close any open menu
            key code 53
            delay 0.1
            key code 53
            delay 0.1
            key code 53
            tell application frontApp to activate
            return "error:" & errMsg
        end try
    end tell
end tell
]]

-- Check if Spotify is running
local function isSpotifyRunning()
    local app = hs.application.find("Spotify")
    return app ~= nil and app:isRunning()
end

-- Update menubar icon
local function updateMenubar(state)
    if not menubar then return end

    if state == "enabled" or state == "already_enabled" then
        pendingEnable = false
        if ICON_PRIVATE then
            menubar:setTitle(nil)
            menubar:setIcon(ICON_PRIVATE, true)
        else
            menubar:setTitle("●")
        end
        local timeLeft = ""
        if lastEnabledTime then
            local remaining = core.remainingTime(lastEnabledTime, monotonicTime(), CONFIG.PRIVATE_SESSION_DURATION)
            if remaining > 0 then
                timeLeft = string.format(" (refreshes in %s)", core.formatTime(remaining))
            end
        end
        menubar:setTooltip("Spotify Private Session: Active" .. timeLeft)
    elseif state == "pending" then
        pendingEnable = true
        if ICON_PENDING then
            menubar:setTitle(nil)
            menubar:setIcon(ICON_PENDING, true)
        else
            menubar:setTitle("○")  -- Empty circle = needs action
        end
        menubar:setTooltip("Click to enable Private Session")
    elseif state == "not_running" then
        pendingEnable = false
        menubar:setTitle(nil)
        menubar:setIcon(nil)
        menubar:setTooltip("Spotify: Not running")
    else
        pendingEnable = false
        menubar:setTitle("⚠️")
        menubar:setIcon(nil)
        menubar:setTooltip("Spotify Private Session: " .. (state or "Unknown"))
    end
end

-- Clear pending state (used when user acts or state becomes stale)
local function clearPendingState()
    pendingEnable = false
    pendingIsRefresh = false
    if pendingNotification then
        pendingNotification:withdraw()
        pendingNotification = nil
    end
end

-- Show notification only on failure (and only once per failure state)
local function notifyIfNeeded(state, message)
    if state ~= "enabled" and state ~= "already_enabled" and state ~= "not_running" and state ~= "pending" then
        if lastState ~= state then
            hs.notify.new({
                title = "Spotify Private Session",
                informativeText = message or ("Failed to enable: " .. (state or "unknown error")),
                withdrawAfter = 10
            }):send()
        end
    end
    lastState = state
end

-- Request user permission to enable Private Session
-- Shows notification and updates menubar to pending state
-- If isRefresh is true, will use forceRefresh to toggle off/on when user approves
local function requestEnablePermission(reason, isRefresh)
    if not isSpotifyRunning() then
        updateMenubar("not_running")
        return
    end

    -- Already pending, don't spam
    if pendingEnable then
        return
    end

    print("[spotify-private] Requesting permission: " .. (reason or "enable Private Session"))
    updateMenubar("pending")
    lastState = "pending"
    pendingIsRefresh = isRefresh or false

    -- Withdraw any existing notification to prevent accumulation
    if pendingNotification then
        pendingNotification:withdraw()
        pendingNotification = nil
    end

    -- Show notification with action
    local notification = hs.notify.new(function(n)
        -- User clicked the notification - enable now
        print("[spotify-private] User approved via notification")
        pendingNotification = nil  -- Clear reference since user acted
        if pendingIsRefresh then
            ensurePrivateSession({ skipDebounce = true, forceRefresh = true })
        else
            ensurePrivateSession({ skipDebounce = true })
        end
        pendingIsRefresh = false
    end, {
        title = "Spotify Private Session",
        informativeText = reason or "Click to enable Private Session",
        actionButtonTitle = "Enable",
        hasActionButton = true,
        withdrawAfter = 0,  -- Don't auto-withdraw, stay until user acts
    })
    notification:send()
    pendingNotification = notification
end

-- Schedule the next refresh before expiry
-- Optional delay parameter for custom timing (e.g., shorter verification after wake)
local function scheduleRefresh(customDelay)
    -- Cancel any existing timer
    if refreshTimer then
        refreshTimer:stop()
        refreshTimer = nil
    end

    -- Use custom delay or default (30 minutes before expiry)
    local refreshDelay = customDelay or (CONFIG.PRIVATE_SESSION_DURATION - CONFIG.REFRESH_BEFORE_EXPIRY)
    refreshTimer = hs.timer.doAfter(refreshDelay, function()
        if isSpotifyRunning() then
            print("[spotify-private] Scheduled refresh triggered")
            requestEnablePermission("Private Session expiring soon - click to refresh", true)
        end
    end)

    print(string.format("[spotify-private] Next refresh scheduled in %s", core.formatTime(refreshDelay)))
end

-- Main function to ensure Private Session is enabled
-- Options:
--   skipDebounce: bypass debounce check (for manual triggers)
--   afterWake: use shorter verification timer if already_enabled
--   forceRefresh: force toggle off/on to reset Spotify's 6-hour timer (for scheduled refresh)
--   savedTiming: { enabledAt, elapsed } - use saved timing if session was already_enabled
function ensurePrivateSession(options)
    options = options or {}

    -- Debounce check (unless explicitly skipped)
    if not options.skipDebounce and shouldDebounce() then
        return
    end
    markCheck()

    if not isSpotifyRunning() then
        updateMenubar("not_running")
        lastState = "not_running"
        lastEnabledTime = nil
        lastWallClockEnabled = nil
        clearState()
        return
    end

    -- Choose script based on whether this is a scheduled refresh
    local script = options.forceRefresh and FORCE_REFRESH_SCRIPT or CHECK_AND_ENABLE_SCRIPT
    local ok, result = hs.osascript.applescript(script)

    if ok then
        result = result:gsub("^%s*(.-)%s*$", "%1")  -- trim whitespace

        if result == "enabled" then
            print("[spotify-private] Private Session enabled")
            lastEnabledTime = monotonicTime()
            lastWallClockEnabled = os.time()
            saveState()
            updateMenubar("enabled")
            lastState = "enabled"
            scheduleRefresh()
        elseif result == "refreshed" then
            print("[spotify-private] Private Session refreshed (toggled off/on)")
            lastEnabledTime = monotonicTime()
            lastWallClockEnabled = os.time()
            saveState()
            updateMenubar("enabled")
            lastState = "enabled"
            scheduleRefresh()
        elseif result == "already_enabled" then
            print("[spotify-private] Private Session already active")
            -- Use saved timing if available, otherwise assume now (conservative)
            if not lastEnabledTime then
                if options.savedTiming then
                    -- Use saved timing from persisted state
                    lastWallClockEnabled = options.savedTiming.enabledAt
                    lastEnabledTime = monotonicTime() - options.savedTiming.elapsed
                    local refreshIn = core.refreshDelayForRestoredState(options.savedTiming.elapsed, CONFIG)
                    print(string.format("[spotify-private] Using saved timing, refresh in %s", core.formatTime(refreshIn)))
                    saveState()
                    scheduleRefresh(refreshIn)
                elseif options.afterWake then
                    -- After wake, we don't know the true session age
                    -- Schedule a shorter verification check
                    lastEnabledTime = monotonicTime()
                    lastWallClockEnabled = os.time()
                    saveState()
                    print("[spotify-private] After wake: scheduling verification in 30 min")
                    scheduleRefresh(CONFIG.WAKE_VERIFICATION_DELAY)
                else
                    lastEnabledTime = monotonicTime()
                    lastWallClockEnabled = os.time()
                    saveState()
                    scheduleRefresh()
                end
            end
            updateMenubar("enabled")
            lastState = "enabled"
        elseif result == "no_menubar" then
            print("[spotify-private] Spotify menubar not ready, will retry in 5s")
            hs.timer.doAfter(5, function() ensurePrivateSession(options) end)
        else
            print("[spotify-private] Unexpected result: " .. result)
            updateMenubar(result)
            notifyIfNeeded(result, "Unexpected state: " .. result)
        end
    else
        local errMsg = result or "AppleScript execution failed"
        print("[spotify-private] Error: " .. errMsg)
        updateMenubar("error")
        notifyIfNeeded("error", errMsg)
    end
end

-- Handle Spotify launch
local function onSpotifyLaunch()
    print("[spotify-private] Spotify launched")
    hs.timer.doAfter(LAUNCH_DELAY, function()
        requestEnablePermission("Spotify started - click to enable Private Session")
    end)
end

-- Handle Spotify quit
local function onSpotifyQuit()
    print("[spotify-private] Spotify terminated")
    if refreshTimer then
        refreshTimer:stop()
        refreshTimer = nil
    end
    lastEnabledTime = nil
    lastWallClockEnabled = nil
    clearState()
    updateMenubar("not_running")
    lastState = "not_running"
end

-- App watcher callback
local function appWatcherCallback(appName, eventType, app)
    if appName == "Spotify" then
        if eventType == hs.application.watcher.launched then
            onSpotifyLaunch()
        elseif eventType == hs.application.watcher.terminated then
            onSpotifyQuit()
        end
    end
end

-- Handle system sleep
local function onSystemSleep()
    print("[spotify-private] System going to sleep")
    lastSleepTime = monotonicTime()
    -- Save current state before sleep
    saveState()
end

-- Handle system wake
local function onSystemWake()
    print("[spotify-private] System woke from sleep")

    local now = monotonicTime()

    -- Check if this was a short sleep (< 5 minutes)
    if core.isShortSleep(lastSleepTime, now, CONFIG.SHORT_SLEEP_THRESHOLD) then
        local duration = core.sleepDuration(lastSleepTime, now)
        print(string.format("[spotify-private] Short sleep (%d sec), skipping check", math.floor(duration or 0)))
        return
    end

    local duration = core.sleepDuration(lastSleepTime, now)
    if duration then
        print(string.format("[spotify-private] Sleep duration: %s", core.formatTime(duration)))
    end

    -- Cancel stale timer (it was paused during sleep, timing is wrong now)
    if refreshTimer then
        refreshTimer:stop()
        refreshTimer = nil
    end

    -- Clear in-memory state
    lastEnabledTime = nil
    lastWallClockEnabled = nil

    if isSpotifyRunning() then
        -- Clear any stale pending state from before sleep (notification is likely gone)
        if pendingEnable then
            print("[spotify-private] Clearing stale pending state from before sleep")
            clearPendingState()
        end

        -- Ask permission to verify/enable Private Session after wake
        print("[spotify-private] Spotify running after wake, requesting permission")
        hs.timer.doAfter(LAUNCH_DELAY, function()
            requestEnablePermission("Woke from sleep - click to verify Private Session")
        end)
    end
end

-- Sleep/wake watcher callback
local function sleepWatcherCallback(event)
    if event == hs.caffeinate.watcher.systemWillSleep then
        onSystemSleep()
    elseif event == hs.caffeinate.watcher.systemDidWake then
        onSystemWake()
    end
end

-- Manual check (called from menubar click)
local function manualCheck()
    print("[spotify-private] Manual check triggered")
    -- Capture refresh flag before clearing, then clear pending state
    local isRefresh = pendingIsRefresh
    clearPendingState()
    if isRefresh then
        ensurePrivateSession({ skipDebounce = true, forceRefresh = true })
    else
        ensurePrivateSession({ skipDebounce = true })
    end
end

-- Initialize
function M.start()
    print("[spotify-private] Starting Spotify Private Session auto-enabler")

    -- Load icon
    local scriptDir = getScriptDir()
    local iconPath = scriptDir .. "icon-private.png"
    local img = hs.image.imageFromPath(iconPath)
    if img then
        ICON_PRIVATE = img:setSize({w=20, h=20})
        print("[spotify-private] Loaded icon from: " .. iconPath)
    else
        print("[spotify-private] Warning: Could not load icon from: " .. iconPath)
    end

    -- Create menubar
    menubar = hs.menubar.new()
    if menubar then
        menubar:setTooltip("Spotify Private Session")
        menubar:setClickCallback(manualCheck)
    end

    -- Start app watcher
    appWatcher = hs.application.watcher.new(appWatcherCallback)
    appWatcher:start()

    -- Start sleep/wake watcher
    sleepWatcher = hs.caffeinate.watcher.new(sleepWatcherCallback)
    sleepWatcher:start()
    print("[spotify-private] Sleep/wake watcher started")

    -- On startup, ask permission if Spotify is running
    if isSpotifyRunning() then
        print("[spotify-private] Spotify running on startup")
        hs.timer.doAfter(1, function()
            requestEnablePermission("Hammerspoon started - click to enable Private Session")
        end)
    else
        updateMenubar("not_running")
    end

    print("[spotify-private] Initialized with sleep/wake detection and state persistence.")
end

-- Cleanup
function M.stop()
    if refreshTimer then refreshTimer:stop() end
    if appWatcher then appWatcher:stop() end
    if sleepWatcher then sleepWatcher:stop() end
    if menubar then menubar:delete() end
    saveState()  -- Persist state before stopping
    print("[spotify-private] Stopped")
end

-- Auto-start on load
M.start()

return M
