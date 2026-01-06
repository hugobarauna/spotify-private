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

-- Persistence file path
local STATE_FILE = hs.configdir .. "/spotify-private-state.json"

-- Icons (loaded in M.start())
local ICON_PRIVATE = nil

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
local ENABLE_SCRIPT = [[
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
                delay 0.2
                tell application frontApp to activate
                return "enabled"
            else
                key code 53 -- Escape to close menu
                tell application frontApp to activate
                return "already_enabled"
            end if
        on error errMsg
            key code 53 -- Escape to close menu if open
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
    elseif state == "not_running" then
        menubar:setTitle(nil)
        menubar:setIcon(nil)
        menubar:setTooltip("Spotify: Not running")
    else
        menubar:setTitle("⚠️")
        menubar:setIcon(nil)
        menubar:setTooltip("Spotify Private Session: " .. (state or "Unknown"))
    end
end

-- Show notification only on failure (and only once per failure state)
local function notifyIfNeeded(state, message)
    if state ~= "enabled" and state ~= "already_enabled" and state ~= "not_running" then
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
            ensurePrivateSession()
        end
    end)

    print(string.format("[spotify-private] Next refresh scheduled in %s", core.formatTime(refreshDelay)))
end

-- Main function to ensure Private Session is enabled
-- Options:
--   skipDebounce: bypass debounce check (for manual triggers)
--   afterWake: use shorter verification timer if already_enabled
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

    -- Run the enable script
    local ok, result = hs.osascript.applescript(ENABLE_SCRIPT)

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
        elseif result == "already_enabled" then
            print("[spotify-private] Private Session already active")
            -- If we don't know when it was enabled, assume now (conservative)
            -- But if this is after wake, use shorter verification timer
            if not lastEnabledTime then
                lastEnabledTime = monotonicTime()
                lastWallClockEnabled = os.time()
                saveState()
                if options.afterWake then
                    -- After wake, we don't know the true session age
                    -- Schedule a shorter verification check
                    print("[spotify-private] After wake: scheduling verification in 30 min")
                    scheduleRefresh(CONFIG.WAKE_VERIFICATION_DELAY)
                else
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
    print("[spotify-private] Spotify launched, waiting " .. LAUNCH_DELAY .. "s before enabling Private Session")
    hs.timer.doAfter(LAUNCH_DELAY, ensurePrivateSession)
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
        -- Try to reload state from file (saved before sleep)
        local savedEnabledAt, elapsedSinceEnable = loadState()
        if savedEnabledAt and elapsedSinceEnable then
            if core.isRestoredStateUsable(elapsedSinceEnable, CONFIG) then
                -- Session is still valid, restore state and schedule refresh
                lastWallClockEnabled = savedEnabledAt
                lastEnabledTime = monotonicTime() - elapsedSinceEnable
                local refreshIn = core.refreshDelayForRestoredState(elapsedSinceEnable, CONFIG)
                print(string.format("[spotify-private] Restored session after wake, refresh in %s", core.formatTime(refreshIn)))
                scheduleRefresh(refreshIn)
                updateMenubar("enabled")
                lastState = "enabled"
                return
            else
                print("[spotify-private] Saved session expired during sleep, will re-enable")
                clearState()
            end
        end

        -- No valid saved state, check and enable Private Session
        print("[spotify-private] Spotify running after wake, checking Private Session")
        hs.timer.doAfter(LAUNCH_DELAY, function()
            ensurePrivateSession({ afterWake = true })
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
    ensurePrivateSession({ skipDebounce = true })
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

    -- Try to load persisted state (from previous session/restart)
    local savedEnabledAt, elapsedSinceEnable = loadState()
    if savedEnabledAt and elapsedSinceEnable and isSpotifyRunning() then
        -- We have a valid saved state and Spotify is running
        if core.isRestoredStateUsable(elapsedSinceEnable, CONFIG) then
            -- Session is still valid and not close to expiry
            -- Set up state and schedule refresh
            lastWallClockEnabled = savedEnabledAt
            lastEnabledTime = monotonicTime() - elapsedSinceEnable
            local refreshIn = core.refreshDelayForRestoredState(elapsedSinceEnable, CONFIG)
            print(string.format("[spotify-private] Restored session state, refresh in %s", core.formatTime(refreshIn)))
            scheduleRefresh(refreshIn)
            updateMenubar("enabled")
            lastState = "enabled"
        else
            -- Session is close to expiry or expired, clear and re-check
            print("[spotify-private] Saved session near expiry, will re-enable")
            clearState()
        end
    end

    -- Check immediately if Spotify is already running (and we don't have valid restored state)
    if isSpotifyRunning() and not lastEnabledTime then
        print("[spotify-private] Spotify already running, checking Private Session")
        hs.timer.doAfter(1, ensurePrivateSession)
    elseif not isSpotifyRunning() then
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
