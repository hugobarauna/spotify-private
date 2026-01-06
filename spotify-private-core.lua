-- Spotify Private Session Core Logic
-- Pure functions for testing - no Hammerspoon dependencies

local M = {}

-- State file version (for future migrations)
M.STATE_VERSION = 1

-- Default configuration
M.DEFAULT_CONFIG = {
    PRIVATE_SESSION_DURATION = 6 * 60 * 60,    -- 6 hours
    REFRESH_BEFORE_EXPIRY = 30 * 60,           -- 30 minutes
    WAKE_VERIFICATION_DELAY = 30 * 60,         -- 30 minutes
    DEBOUNCE_INTERVAL = 5,                      -- 5 seconds
    SHORT_SLEEP_THRESHOLD = 5 * 60,            -- 5 minutes
}

-- Calculate remaining time until session expires
-- Returns: remaining seconds (negative if expired)
function M.remainingTime(enabledAt, currentTime, sessionDuration)
    sessionDuration = sessionDuration or M.DEFAULT_CONFIG.PRIVATE_SESSION_DURATION
    local elapsed = currentTime - enabledAt
    return sessionDuration - elapsed
end

-- Check if session is still valid
function M.isSessionValid(enabledAt, currentTime, sessionDuration)
    return M.remainingTime(enabledAt, currentTime, sessionDuration) > 0
end

-- Calculate when to schedule next refresh
-- Returns: seconds until refresh should happen, or nil if session expired
function M.calculateRefreshDelay(enabledAt, currentTime, config)
    config = config or M.DEFAULT_CONFIG
    local remaining = M.remainingTime(enabledAt, currentTime, config.PRIVATE_SESSION_DURATION)

    if remaining <= 0 then
        return nil  -- Session already expired
    end

    if remaining <= config.REFRESH_BEFORE_EXPIRY then
        return 0  -- Should refresh immediately
    end

    return remaining - config.REFRESH_BEFORE_EXPIRY
end

-- Check if we should debounce (skip this check)
-- Returns: true if should skip, false if should proceed
function M.shouldDebounce(lastCheckTime, currentTime, debounceInterval)
    debounceInterval = debounceInterval or M.DEFAULT_CONFIG.DEBOUNCE_INTERVAL
    if lastCheckTime == nil then
        return false
    end
    return (currentTime - lastCheckTime) < debounceInterval
end

-- Check if sleep was too short to warrant a check
-- Returns: true if sleep was short (should skip check)
function M.isShortSleep(sleepStartTime, wakeTime, threshold)
    threshold = threshold or M.DEFAULT_CONFIG.SHORT_SLEEP_THRESHOLD
    if sleepStartTime == nil then
        return false  -- Unknown sleep duration, assume long
    end
    local sleepDuration = wakeTime - sleepStartTime
    return sleepDuration < threshold
end

-- Calculate sleep duration in seconds
function M.sleepDuration(sleepStartTime, wakeTime)
    if sleepStartTime == nil then
        return nil
    end
    return wakeTime - sleepStartTime
end

-- Serialize state for persistence
-- Returns: table ready for JSON encoding
function M.serializeState(wallClockEnabledAt)
    if wallClockEnabledAt == nil then
        return nil
    end
    return {
        version = M.STATE_VERSION,
        enabledAt = wallClockEnabledAt,
        savedAt = os.time()
    }
end

-- Deserialize and validate state from persistence
-- Returns: enabledAt, elapsedTime or nil, nil if invalid/expired
function M.deserializeState(state, currentTime, sessionDuration)
    sessionDuration = sessionDuration or M.DEFAULT_CONFIG.PRIVATE_SESSION_DURATION

    if state == nil or state.enabledAt == nil then
        return nil, nil
    end

    local elapsed = currentTime - state.enabledAt

    if elapsed < 0 then
        -- Clock went backwards, state is invalid
        return nil, nil
    end

    if elapsed >= sessionDuration then
        -- Session expired
        return nil, nil
    end

    return state.enabledAt, elapsed
end

-- Determine if restored state is usable (not too close to expiry)
-- Returns: true if state is usable, false if should re-enable
function M.isRestoredStateUsable(elapsedTime, config)
    config = config or M.DEFAULT_CONFIG
    if elapsedTime == nil then
        return false
    end
    local remaining = config.PRIVATE_SESSION_DURATION - elapsedTime
    return remaining > config.REFRESH_BEFORE_EXPIRY
end

-- Calculate refresh delay for restored state
-- Returns 0 if the session is already within the refresh window
function M.refreshDelayForRestoredState(elapsedTime, config)
    config = config or M.DEFAULT_CONFIG
    local remaining = config.PRIVATE_SESSION_DURATION - elapsedTime
    local delay = remaining - config.REFRESH_BEFORE_EXPIRY
    return math.max(0, delay)
end

-- Format time for display (hours and minutes)
function M.formatTime(seconds)
    if seconds == nil or seconds < 0 then
        return "expired"
    end
    local hours = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    if hours > 0 then
        return string.format("%dh %dm", hours, mins)
    elseif mins > 0 then
        return string.format("%dm", mins)
    else
        return "< 1m"
    end
end

return M
