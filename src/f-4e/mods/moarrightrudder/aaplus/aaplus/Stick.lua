-- The antenna hand control ("stick") as Jester drives it, and as it actually reads.
-- Jester moves the cursor by writing the stick (MoveRadarCursor:PlaceStickAt). The pilot's own slew
-- writes the same control. The knob's actual position (/Radar Stick Knobs/Slew X|Y Knob) differs from
-- what Jester last wrote exactly when the pilot is pushing, so a mismatch is the pilot's input.
local Utilities = require('base.Utilities')
local Patches = require 'aaplus.Patches'

local Stick = {}
local S = { x = 0, y = 0, t = -1e9 }

local function now_seconds()
    local t = 0
    pcall(function()
        local raw = Utilities.GetTime().mission_time
        t = type(raw) == 'number' and raw or raw:ConvertTo(s).value
    end)
    return t
end

local function num(v)
    for _ = 1, 3 do
        if type(v) == 'number' then return v end
        if v == nil then return nil end
        local ok, r = pcall(function() return v.value end)
        if not ok or r == nil then break end
        v = r
    end
    return tonumber(v)
end

function Stick.OnCommand(x, y)
    S.x, S.y, S.t = x or 0, y or 0, now_seconds()
end

-- What Jester last wrote to the stick: x, y, mission time.
function Stick.Cmd() return S.x, S.y, S.t end

-- The knob's actual position, or nil when unreadable.
function Stick.Knob()
    local ok, kx, ky = pcall(function()
        local px = GetProperty('/Radar Stick Knobs/Slew X Knob', 'Position')
        local py = GetProperty('/Radar Stick Knobs/Slew Y Knob', 'Position')
        return px and num(px.value), py and num(py.value)
    end)
    if ok and kx and ky then return kx, ky end
    return nil
end

-- true when the knob is not where Jester put it: the pilot is on the stick. Also returns the knob.
function Stick.PilotInput(eps)
    local kx, ky = Stick.Knob()
    if not kx then return false end
    eps = eps or 0.05
    return (math.abs(kx - S.x) > eps or math.abs(ky - S.y) > eps), kx, ky
end

_G.AAD_STICK = Stick

-- The wrapper keeps its marker and its link to this module in globals, so a reload neither wraps
-- twice nor leaves the wrapper pointing at a dead copy (see Modes.Install).
function Stick.Install()
    Patches.Install('stick_commands', function()
        local MoveRadarCursor = require('radar.MoveRadarCursor')
        if rawget(_G, 'AAD_STICK2_WRAPPED') then return end
        local original = MoveRadarCursor.PlaceStickAt
        assert(type(original) == 'function', 'MoveRadarCursor.PlaceStickAt not found')
        MoveRadarCursor.PlaceStickAt = function(self, slew_x, slew_y)
            local St = rawget(_G, 'AAD_STICK')
            if St then pcall(St.OnCommand, slew_x, slew_y) end
            return original(self, slew_x, slew_y)
        end
        _G.AAD_STICK2_WRAPPED = true
    end)
end

return Stick
