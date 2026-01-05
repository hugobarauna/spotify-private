-- Spotify Private Session Auto-Enabler
-- Ensures Private Session is always enabled when Spotify is running
-- https://github.com/hugobarauna/spotify-private

local M = {}

-- Configuration
local PRIVATE_SESSION_DURATION = 6 * 60 * 60    -- Spotify's Private Session lasts 6 hours
local REFRESH_BEFORE_EXPIRY = 30 * 60           -- Re-enable 30 minutes before expiry (at 5.5 hours)
local LAUNCH_DELAY = 2                          -- Seconds to wait after Spotify launches

-- State
local menubar = nil
local refreshTimer = nil
local appWatcher = nil
local lastState = nil
local lastEnabledTime = nil  -- Track when we last enabled Private Session

-- Icons (loaded in M.start())
local ICON_PRIVATE = nil

-- Get the directory where this script lives
local function getScriptDir()
    local info = debug.getinfo(1, "S")
    local path = info.source:match("@(.*/)")
    return path or hs.configdir .. "/"
end

-- AppleScript to enable Private Session (checks first, then enables if needed)
local ENABLE_SCRIPT = [[
tell application "System Events"
    tell process "Spotify"
        if not (exists menu bar 1) then
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
                return "enabled"
            else
                key code 53 -- Escape to close menu
                return "already_enabled"
            end if
        on error errMsg
            key code 53 -- Escape to close menu if open
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
            local elapsed = os.time() - lastEnabledTime
            local remaining = PRIVATE_SESSION_DURATION - elapsed
            if remaining > 0 then
                local hours = math.floor(remaining / 3600)
                local mins = math.floor((remaining % 3600) / 60)
                timeLeft = string.format(" (refreshes in %dh %dm)", hours, mins)
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
local function scheduleRefresh()
    -- Cancel any existing timer
    if refreshTimer then
        refreshTimer:stop()
        refreshTimer = nil
    end

    -- Schedule refresh 30 minutes before expiry (at 5.5 hours)
    local refreshDelay = PRIVATE_SESSION_DURATION - REFRESH_BEFORE_EXPIRY
    refreshTimer = hs.timer.doAfter(refreshDelay, function()
        if isSpotifyRunning() then
            print("[spotify-private] Proactive refresh before 6-hour expiry")
            ensurePrivateSession()
        end
    end)

    local hours = math.floor(refreshDelay / 3600)
    local mins = math.floor((refreshDelay % 3600) / 60)
    print(string.format("[spotify-private] Next refresh scheduled in %dh %dm", hours, mins))
end

-- Main function to ensure Private Session is enabled
function ensurePrivateSession()
    if not isSpotifyRunning() then
        updateMenubar("not_running")
        lastState = "not_running"
        lastEnabledTime = nil
        return
    end

    -- Run the enable script
    local ok, result = hs.osascript.applescript(ENABLE_SCRIPT)

    if ok then
        result = result:gsub("^%s*(.-)%s*$", "%1")  -- trim whitespace

        if result == "enabled" then
            print("[spotify-private] Private Session enabled")
            lastEnabledTime = os.time()
            updateMenubar("enabled")
            lastState = "enabled"
            scheduleRefresh()
        elseif result == "already_enabled" then
            print("[spotify-private] Private Session already active")
            -- If we don't know when it was enabled, assume now (conservative)
            if not lastEnabledTime then
                lastEnabledTime = os.time()
                scheduleRefresh()
            end
            updateMenubar("enabled")
            lastState = "enabled"
        elseif result == "no_menubar" then
            print("[spotify-private] Spotify menubar not ready, will retry in 5s")
            hs.timer.doAfter(5, ensurePrivateSession)
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

-- Manual check (called from menubar click)
local function manualCheck()
    print("[spotify-private] Manual check triggered")
    ensurePrivateSession()
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

    -- Check immediately if Spotify is already running
    if isSpotifyRunning() then
        print("[spotify-private] Spotify already running, checking Private Session")
        hs.timer.doAfter(1, ensurePrivateSession)
    else
        updateMenubar("not_running")
    end

    print("[spotify-private] Initialized. Will refresh Private Session 30 min before 6-hour expiry.")
end

-- Cleanup
function M.stop()
    if refreshTimer then refreshTimer:stop() end
    if appWatcher then appWatcher:stop() end
    if menubar then menubar:delete() end
    print("[spotify-private] Stopped")
end

-- Auto-start on load
M.start()

return M
