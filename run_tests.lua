-- Zero-dependency test runner for spotify-private-core_spec.lua
--
-- The project normally uses busted (see CLAUDE.md), but a Homebrew Lua 5.4->5.5
-- upgrade can leave busted/luarocks unrunnable (their launchers point at a
-- removed lua5.4, and the 5.4 C rocks won't load under 5.5). This runner
-- provides just enough of busted's `describe`/`it`/`assert` surface to run the
-- existing spec under plain `lua` with no external dependencies.
--
-- Usage:  lua run_tests.lua
--         busted spotify-private-core_spec.lua   (still works if busted is fixed)

-- Make `require("spotify-private-core")` resolve from this directory.
local thisDir = (arg[0] or ""):match("(.*/)") or "./"
package.path = thisDir .. "?.lua;" .. package.path

local passed, failed = 0, 0
local failures = {}
local stack = {}

function describe(name, fn)
    table.insert(stack, name)
    fn()
    table.remove(stack)
end

function it(name, fn)
    local ctx = table.concat(stack, " > ") .. " > " .. name
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        table.insert(failures, { ctx = ctx, err = err })
    end
end

local function fail(msg)
    error(msg, 3)
end

local function repr(v)
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end

-- Minimal luassert-compatible assertion object.
assert = setmetatable({
    is_true = function(v) if v ~= true then fail("expected true, got " .. repr(v)) end end,
    is_false = function(v) if v ~= false then fail("expected false, got " .. repr(v)) end end,
    is_nil = function(v) if v ~= nil then fail("expected nil, got " .. repr(v)) end end,
    is_table = function(v) if type(v) ~= "table" then fail("expected table, got " .. repr(v)) end end,
    is_number = function(v) if type(v) ~= "number" then fail("expected number, got " .. repr(v)) end end,
    is_string = function(v) if type(v) ~= "string" then fail("expected string, got " .. repr(v)) end end,
    are = {
        equal = function(expected, actual)
            if expected ~= actual then
                fail("expected " .. repr(expected) .. ", got " .. repr(actual))
            end
        end,
    },
}, {
    -- Allow plain assert(cond, msg) to still work.
    __call = function(_, cond, msg)
        if not cond then fail(msg or "assertion failed") end
    end,
})

-- Run the spec(s) passed on the command line, or the default core spec.
local specs = {}
for i = 1, #arg do specs[#specs + 1] = arg[i] end
if #specs == 0 then specs = { thisDir .. "spotify-private-core_spec.lua" } end

for _, spec in ipairs(specs) do
    dofile(spec)
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
    print("\nFailures:")
    for _, f in ipairs(failures) do
        print("  ✗ " .. f.ctx)
        print("      " .. tostring(f.err))
    end
    os.exit(1)
end
os.exit(0)
