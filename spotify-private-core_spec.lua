-- Tests for Spotify Private Session Core Logic
-- Run with: busted spotify-private-core_spec.lua

local core = require("spotify-private-core")

describe("spotify-private-core", function()

    describe("remainingTime", function()
        it("returns positive time when session is valid", function()
            local enabledAt = 1000
            local currentTime = 2000  -- 1000 seconds elapsed
            local duration = 6 * 60 * 60  -- 6 hours

            local remaining = core.remainingTime(enabledAt, currentTime, duration)

            assert.is_true(remaining > 0)
            assert.are.equal(duration - 1000, remaining)
        end)

        it("returns negative time when session is expired", function()
            local enabledAt = 1000
            local currentTime = 1000 + (7 * 60 * 60)  -- 7 hours later
            local duration = 6 * 60 * 60  -- 6 hours

            local remaining = core.remainingTime(enabledAt, currentTime, duration)

            assert.is_true(remaining < 0)
        end)

        it("returns zero at exact expiry time", function()
            local enabledAt = 1000
            local duration = 6 * 60 * 60
            local currentTime = enabledAt + duration

            local remaining = core.remainingTime(enabledAt, currentTime, duration)

            assert.are.equal(0, remaining)
        end)
    end)

    describe("isSessionValid", function()
        it("returns true when session has time remaining", function()
            local enabledAt = 1000
            local currentTime = 2000
            local duration = 6 * 60 * 60

            assert.is_true(core.isSessionValid(enabledAt, currentTime, duration))
        end)

        it("returns false when session is expired", function()
            local enabledAt = 1000
            local currentTime = enabledAt + (7 * 60 * 60)
            local duration = 6 * 60 * 60

            assert.is_false(core.isSessionValid(enabledAt, currentTime, duration))
        end)

        it("returns false at exact expiry time (zero remaining)", function()
            local enabledAt = 1000
            local duration = 6 * 60 * 60
            local currentTime = enabledAt + duration  -- Exactly at expiry

            -- At exactly zero remaining, session is NOT valid (uses > 0)
            assert.is_false(core.isSessionValid(enabledAt, currentTime, duration))
        end)
    end)

    describe("calculateRefreshDelay", function()
        local config = {
            PRIVATE_SESSION_DURATION = 6 * 60 * 60,  -- 6 hours
            REFRESH_BEFORE_EXPIRY = 30 * 60,          -- 30 minutes
        }

        it("returns correct delay for fresh session", function()
            local enabledAt = 1000
            local currentTime = 1000  -- Just enabled

            local delay = core.calculateRefreshDelay(enabledAt, currentTime, config)

            -- Should refresh 30 min before expiry = 5.5 hours
            assert.are.equal(5.5 * 60 * 60, delay)
        end)

        it("returns 0 when within refresh window", function()
            local enabledAt = 1000
            local currentTime = enabledAt + (5.5 * 60 * 60) + 60  -- 5.5 hours + 1 minute

            local delay = core.calculateRefreshDelay(enabledAt, currentTime, config)

            assert.are.equal(0, delay)
        end)

        it("returns nil when session expired", function()
            local enabledAt = 1000
            local currentTime = enabledAt + (7 * 60 * 60)  -- 7 hours later

            local delay = core.calculateRefreshDelay(enabledAt, currentTime, config)

            assert.is_nil(delay)
        end)
    end)

    describe("shouldDebounce", function()
        it("returns false when lastCheckTime is nil", function()
            assert.is_false(core.shouldDebounce(nil, 1000, 5))
        end)

        it("returns true when within debounce interval", function()
            local lastCheck = 1000
            local now = 1003  -- 3 seconds later
            local interval = 5

            assert.is_true(core.shouldDebounce(lastCheck, now, interval))
        end)

        it("returns false when outside debounce interval", function()
            local lastCheck = 1000
            local now = 1010  -- 10 seconds later
            local interval = 5

            assert.is_false(core.shouldDebounce(lastCheck, now, interval))
        end)

        it("returns false at exact boundary", function()
            local lastCheck = 1000
            local now = 1005  -- Exactly 5 seconds
            local interval = 5

            assert.is_false(core.shouldDebounce(lastCheck, now, interval))
        end)
    end)

    describe("isShortSleep", function()
        it("returns false when sleepStartTime is nil", function()
            assert.is_false(core.isShortSleep(nil, 1000, 300))
        end)

        it("returns true for short sleep", function()
            local sleepStart = 1000
            local wakeTime = 1060  -- 1 minute
            local threshold = 5 * 60  -- 5 minutes

            assert.is_true(core.isShortSleep(sleepStart, wakeTime, threshold))
        end)

        it("returns false for long sleep", function()
            local sleepStart = 1000
            local wakeTime = sleepStart + (10 * 60)  -- 10 minutes
            local threshold = 5 * 60  -- 5 minutes

            assert.is_false(core.isShortSleep(sleepStart, wakeTime, threshold))
        end)

        it("returns false at exact threshold (5 min is not short)", function()
            local sleepStart = 1000
            local wakeTime = sleepStart + (5 * 60)  -- Exactly 5 minutes
            local threshold = 5 * 60  -- 5 minutes

            -- At exact threshold, sleep is NOT considered short (uses < not <=)
            assert.is_false(core.isShortSleep(sleepStart, wakeTime, threshold))
        end)
    end)

    describe("sleepDuration", function()
        it("returns nil when sleepStartTime is nil", function()
            assert.is_nil(core.sleepDuration(nil, 1000))
        end)

        it("returns correct duration", function()
            local sleepStart = 1000
            local wakeTime = 1500

            assert.are.equal(500, core.sleepDuration(sleepStart, wakeTime))
        end)
    end)

    describe("serializeState", function()
        it("returns nil when enabledAt is nil", function()
            assert.is_nil(core.serializeState(nil))
        end)

        it("returns table with version, enabledAt and savedAt", function()
            local enabledAt = 1234567890
            local result = core.serializeState(enabledAt)

            assert.is_table(result)
            assert.are.equal(core.STATE_VERSION, result.version)
            assert.are.equal(enabledAt, result.enabledAt)
            assert.is_number(result.savedAt)
        end)
    end)

    describe("deserializeState", function()
        local duration = 6 * 60 * 60  -- 6 hours

        it("returns nil for nil state", function()
            local enabledAt, elapsed = core.deserializeState(nil, 1000, duration)
            assert.is_nil(enabledAt)
            assert.is_nil(elapsed)
        end)

        it("returns nil for state without enabledAt", function()
            local enabledAt, elapsed = core.deserializeState({}, 1000, duration)
            assert.is_nil(enabledAt)
            assert.is_nil(elapsed)
        end)

        it("returns nil for expired session", function()
            local state = { enabledAt = 1000 }
            local currentTime = 1000 + (7 * 60 * 60)  -- 7 hours later

            local enabledAt, elapsed = core.deserializeState(state, currentTime, duration)

            assert.is_nil(enabledAt)
            assert.is_nil(elapsed)
        end)

        it("returns nil when clock went backwards", function()
            local state = { enabledAt = 2000 }
            local currentTime = 1000  -- Before enabledAt

            local enabledAt, elapsed = core.deserializeState(state, currentTime, duration)

            assert.is_nil(enabledAt)
            assert.is_nil(elapsed)
        end)

        it("returns enabledAt and elapsed for valid session", function()
            local state = { enabledAt = 1000 }
            local currentTime = 2000  -- 1000 seconds later

            local enabledAt, elapsed = core.deserializeState(state, currentTime, duration)

            assert.are.equal(1000, enabledAt)
            assert.are.equal(1000, elapsed)
        end)
    end)

    describe("isRestoredStateUsable", function()
        local config = {
            PRIVATE_SESSION_DURATION = 6 * 60 * 60,
            REFRESH_BEFORE_EXPIRY = 30 * 60,
        }

        it("returns false for nil elapsed", function()
            assert.is_false(core.isRestoredStateUsable(nil, config))
        end)

        it("returns true when plenty of time remaining", function()
            local elapsed = 1 * 60 * 60  -- 1 hour elapsed
            assert.is_true(core.isRestoredStateUsable(elapsed, config))
        end)

        it("returns false when close to expiry", function()
            local elapsed = 5.75 * 60 * 60  -- 5.75 hours elapsed (only 15 min left)
            assert.is_false(core.isRestoredStateUsable(elapsed, config))
        end)
    end)

    describe("refreshDelayForRestoredState", function()
        local config = {
            PRIVATE_SESSION_DURATION = 6 * 60 * 60,
            REFRESH_BEFORE_EXPIRY = 30 * 60,
        }

        it("calculates correct delay", function()
            local elapsed = 1 * 60 * 60  -- 1 hour elapsed

            local delay = core.refreshDelayForRestoredState(elapsed, config)

            -- 6h - 1h = 5h remaining, minus 30min buffer = 4.5h
            assert.are.equal(4.5 * 60 * 60, delay)
        end)

        it("returns 0 when within refresh window", function()
            local elapsed = 5.75 * 60 * 60  -- 5.75 hours elapsed (only 15 min remaining)

            local delay = core.refreshDelayForRestoredState(elapsed, config)

            -- Would be negative, but clamps to 0
            assert.are.equal(0, delay)
        end)

        it("returns 0 when session is expired", function()
            local elapsed = 7 * 60 * 60  -- 7 hours elapsed (past expiry)

            local delay = core.refreshDelayForRestoredState(elapsed, config)

            -- Would be very negative, but clamps to 0
            assert.are.equal(0, delay)
        end)
    end)

    describe("formatTime", function()
        it("returns 'expired' for nil", function()
            assert.are.equal("expired", core.formatTime(nil))
        end)

        it("returns 'expired' for negative", function()
            assert.are.equal("expired", core.formatTime(-100))
        end)

        it("formats hours and minutes", function()
            local seconds = 2 * 60 * 60 + 30 * 60  -- 2h 30m
            assert.are.equal("2h 30m", core.formatTime(seconds))
        end)

        it("formats minutes only when less than 1 hour", function()
            local seconds = 45 * 60  -- 45 minutes
            assert.are.equal("45m", core.formatTime(seconds))
        end)

        it("returns '< 1m' for durations under 1 minute", function()
            assert.are.equal("< 1m", core.formatTime(30))  -- 30 seconds
            assert.are.equal("< 1m", core.formatTime(0))   -- 0 seconds
        end)

        it("returns '1m' for exactly 60 seconds", function()
            assert.are.equal("1m", core.formatTime(60))
        end)
    end)

end)
