-- Active LGB: keeps the WRCS Drag Coefficient dial matched to the selected laser-guided bomb while the
-- Delivery Mode switch is in TGT_FIND. The coefficient comes from a 3D table of altitude, speed and dive angle.
require('base.Interactions')
local Behavior = require('base.Behavior')
local Class = require('base.Class')
local AGLog = require('agplus.Log')
local Util = require('agplus.Util')
local Mode = require('agplus.Mode')

local Lgb = {}

-- 3D Lookup table for GBU-12 Drag Coefficient
local drag_table_gbu12 = {
    [10000] = {
        [400] = { [0] = 1.15, [15] = 1.13, [30] = 1.12 },
        [450] = { [0] = 1.19, [15] = 1.16, [30] = 1.14 },
        [500] = { [0] = 1.23, [15] = 1.20, [30] = 1.17 }
    },
    [20000] = {
        [400] = { [0] = 1.20, [15] = 1.19, [30] = 1.19 },
        [450] = { [0] = 1.24, [15] = 1.23, [30] = 1.22 },
        [500] = { [0] = 1.30, [15] = 1.29, [30] = 1.27 }
    },
    [30000] = {
        [400] = { [0] = 1.22, [15] = 1.23, [30] = 1.24 },
        [450] = { [0] = 1.27, [15] = 1.28, [30] = 1.28 },
        [500] = { [0] = 1.33, [15] = 1.34, [30] = 1.33 }
    }
}

-- 3D Lookup table for GBU-10 Drag Coefficient
local drag_table_gbu10 = {
    [10000] = {
        [400] = { [0] = 1.12, [15] = 1.11, [30] = 1.09 },
        [450] = { [0] = 1.15, [15] = 1.13, [30] = 1.11 },
        [500] = { [0] = 1.19, [15] = 1.17, [30] = 1.14 }
    },
    [20000] = {
        [400] = { [0] = 1.16, [15] = 1.16, [30] = 1.15 },
        [450] = { [0] = 1.20, [15] = 1.20, [30] = 1.19 },
        [500] = { [0] = 1.26, [15] = 1.25, [30] = 1.24 }
    },
    [30000] = {
        [400] = { [0] = 1.19, [15] = 1.20, [30] = 1.21 },
        [450] = { [0] = 1.24, [15] = 1.25, [30] = 1.25 },
        [500] = { [0] = 1.29, [15] = 1.30, [30] = 1.30 }
    }
}

-- 3D Lookup table for GBU-24 Drag Coefficient
local drag_table_gbu24 = {
    [10000] = {
        [400] = { [0] = 1.10, [15] = 1.09, [30] = 1.07 },
        [450] = { [0] = 1.11, [15] = 1.09, [30] = 1.08 },
        [500] = { [0] = 1.12, [15] = 1.10, [30] = 1.08 }
    },
    [20000] = {
        [400] = { [0] = 1.12, [15] = 1.11, [30] = 1.10 },
        [450] = { [0] = 1.13, [15] = 1.12, [30] = 1.11 },
        [500] = { [0] = 1.14, [15] = 1.13, [30] = 1.12 }
    },
    [30000] = {
        [400] = { [0] = 1.12, [15] = 1.12, [30] = 1.12 },
        [450] = { [0] = 1.13, [15] = 1.13, [30] = 1.13 },
        [500] = { [0] = 1.15, [15] = 1.16, [30] = 1.15 }
    }
}

local alts = {10000, 20000, 30000}
local speeds = {400, 450, 500}
local dives = {0, 15, 30}

local function get_bounds(val, arr)
    if val <= arr[1] then return arr[1], arr[2] end
    if val >= arr[#arr] then return arr[#arr-1], arr[#arr] end
    for i = 1, #arr - 1 do
        if val >= arr[i] and val <= arr[i+1] then
            return arr[i], arr[i+1]
        end
    end
    return arr[1], arr[2]
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function get_drag_coefficient(table_ref, alt, speed, dive)
    local a1, a2 = get_bounds(alt, alts)
    local s1, s2 = get_bounds(speed, speeds)
    local d1, d2 = get_bounds(dive, dives)

    local function get_val(a, s, d)
        return table_ref[a][s][d]
    end

    local t_a = (alt - a1) / (a2 - a1)
    local t_s = (speed - s1) / (s2 - s1)
    local t_d = (dive - d1) / (d2 - d1)

    local c00 = lerp(get_val(a1, s1, d1), get_val(a1, s1, d2), t_d)
    local c01 = lerp(get_val(a1, s2, d1), get_val(a1, s2, d2), t_d)
    local c10 = lerp(get_val(a2, s1, d1), get_val(a2, s1, d2), t_d)
    local c11 = lerp(get_val(a2, s2, d1), get_val(a2, s2, d2), t_d)

    local c0 = lerp(c00, c01, t_s)
    local c1 = lerp(c10, c11, t_s)

    return lerp(c0, c1, t_a)
end

--------------------------------------------------------------------------------
-- Behavior
--------------------------------------------------------------------------------

-- The drag coefficient for a bomb from the flight state now: the same tables and clamping the automatic mode uses.
-- Returns the WRCS dial value (1.15 is 115), the coefficient, and the altitude (ft), TAS (kt) and dive angle (deg) it used.
local function compute_dial(key, alt_delta_ft)
    local obs_alt = GetJester().awareness:GetObservation("barometric_altitude")
    local altitude_ft = (obs_alt and obs_alt:ConvertTo(ft).value or 10000) + (alt_delta_ft or 0)
    local obs_tas = GetJester().awareness:GetObservation("TAS")
    local tas_kts = obs_tas and obs_tas:ConvertTo(kt).value or 400
    local obs_pitch = GetJester().awareness:GetObservation("gods_pitch")
    local pitch_deg = obs_pitch and obs_pitch:ConvertTo(deg).value or 0
    local dive_deg = -pitch_deg
    altitude_ft = math.max(0, math.min(45000, altitude_ft))
    tas_kts = math.max(200, math.min(700, tas_kts))
    dive_deg = math.max(-10, math.min(60, dive_deg))
    local tref = (key == "GBU-12" and drag_table_gbu12) or (key == "GBU-10" and drag_table_gbu10) or (key == "GBU-24" and drag_table_gbu24)
    local coeff = tref and get_drag_coefficient(tref, altitude_ft, tas_kts, dive_deg) or 1.0
    return math.floor((coeff * 100) + 0.5), coeff, altitude_ft, tas_kts, dive_deg
end

-- Laser-guided bombs only (callers pass only GBU-10/-12/-24): a level release, a dive shallower than LEVEL_DIVE_DEG, gets a small
-- drag dial offset (default -5) so the bomb captures the laser earlier. Dumb munitions never reach this and use their table values.
local function level_offset(dive_deg)
    local Cfg = package.loaded['agplus.Config'] or {}
    if Cfg.PAVE_LEVEL_DIAL_OFFSET == false then return 0 end
    if dive_deg < (Cfg.PAVE_LEVEL_DIVE_DEG or 10) then return Cfg.PAVE_LEVEL_DIAL_OFFSET or -5 end
    return 0
end

-- One-shot: set the Drag Coefficient dial for this bomb from the flight state now (the Pave Spike long press while holding).
-- Returns the dial value and the numbers it was worked from, or nil when the bomb has no drag table.
function Lgb.Program(key, alt_delta_ft, dial_offset)
    if key ~= "GBU-12" and key ~= "GBU-10" and key ~= "GBU-24" then return nil end
    local dial, coeff, alt, tas, dive = compute_dial(key, alt_delta_ft)
    local table_dial = dial
    if dial_offset == nil then dial_offset = level_offset(dive) end
    if dial_offset and dial_offset ~= 0 then
        dial = math.max(1, math.min(999, dial + dial_offset))
        coeff = dial / 100
    end
    Dispatch("agp_lgb_apply", dial)
    AGLog.Info('drag coefficient programmed on request: %s %.3f (dial %d, table %d, offset %d) from %.0f ft, %.0f kt TAS, %.1f deg dive', key, coeff, dial, table_dial, dial_offset or 0, alt, tas, dive)
    return dial, coeff, alt, tas, dive
end

local AutoBombingCalculator = Class(Behavior)
Lgb.Behavior = AutoBombingCalculator

function AutoBombingCalculator:Constructor()
    Behavior.Constructor(self)
    self.selected_lgb = nil
    self.last_drag_dial_value = nil
    self.current_cockpit = nil
    self.tick_counter = 0
end

-- Silent Drag Coefficient dial update.
-- The dial value Jester sent last (for the Pave Spike menu text); nil until he has set it.
function Lgb.DialText()
    if not Lgb.last_dial then return 'not set' end
    return string.format('%.2f', Lgb.last_dial / 100)
end

ListenTo("agp_lgb_apply", "AGPlus_LgbApply", function(task, drag_dial_value)
    Lgb.last_dial = tonumber(drag_dial_value)
    task:ClickFast("Drag Coefficient", tostring(drag_dial_value))
end)

local DIAG_DIALS = { 'Drag Coefficient', 'Target Alt/Range', 'Release Range', 'Release Advance', 'North/South Offset', 'East/West Offset',
    'Pullup Timer', 'Release Timer', 'High Angle Knob', 'Low Angle Knob' }

function AutoBombingCalculator:ReleaseDiag()
    local ok_p, Pave = pcall(require, 'agplus.Pave')
    if not ok_p or not Pave or not Pave.ReleaseHeld then return end
    local held = Pave.ReleaseHeld()
    local now = Util.Now()
    if not held and not self.diag_held then return end
    if held and self.diag_held and now - (self.diag_t or 0) < 0.5 then return end
    local tag = (held and not self.diag_held) and 'PRESS' or ((not held) and 'RELEASE' or 'held')
    self.diag_held, self.diag_t = held, now
    local function obs(key, unit)
        local v
        pcall(function() local o = GetJester().awareness:GetObservation(key); v = o and (unit and o:ConvertTo(unit).value or o.value) end)
        return v
    end
    local alt, tas, gs, pitch = obs('barometric_altitude', ft), obs('TAS', kt), obs('ground_speed', kt), obs('gods_pitch', deg)
    local table_now = '-'
    if self.selected_lgb and alt and tas and pitch then
        local tref = (self.selected_lgb == 'GBU-12' and drag_table_gbu12) or (self.selected_lgb == 'GBU-10' and drag_table_gbu10) or (self.selected_lgb == 'GBU-24' and drag_table_gbu24)
        if tref then
            local okc, v = pcall(get_drag_coefficient, tref, math.max(0, math.min(45000, alt)), math.max(200, math.min(700, tas)), math.max(-10, math.min(60, -pitch)))
            if okc then table_now = string.format('%.3f', v) end
        end
    end
    local parts = {}
    for _, name in ipairs(DIAG_DIALS) do
        local st
        pcall(function() st = GetJester():GetCockpit():GetManipulator(name):GetState() end)
        parts[#parts + 1] = name .. '=' .. tostring(st)
    end
    local mode
    pcall(function() mode = Util.DeliveryMode() end)
    local logf = (tag == 'held') and AGLog.Detail or AGLog.Info
    logf('release diag %s: alt %s ft, TAS %s kt, GS %s kt, dive %s deg, delivery %s, lgb %s, table now %s, dial sent %s | %s',
        tag, alt and string.format('%.0f', alt) or '?', tas and string.format('%.0f', tas) or '?', gs and string.format('%.0f', gs) or '?',
        pitch and string.format('%.1f', -pitch) or '?', tostring(mode), tostring(self.selected_lgb), table_now, tostring(self.last_drag_dial_value), table.concat(parts, ', '))
end

function AutoBombingCalculator:Tick()
    local cockpit = Util.Cockpit()
    if not cockpit then
        self.current_cockpit = nil
        return
    end

    -- Release diagnostics: while the player holds the weapon release button (Pave.ReleaseHeld, from the Export feed), log every
    -- 0.5 s what the WRCS is working from: the flight state, the coefficient the table gives right now, and what the WRCS dials
    -- actually read. One line at the press and one at the release. Read-only.
    self:ReleaseDiag()

    -- The weapon and mode live in agplus.Mode; this runs only while Drag Coefficient is the running mode.
    local key = Mode.DragKey()
    if key ~= self.selected_lgb or self.current_cockpit ~= cockpit then
        self.current_cockpit = cockpit
        self.selected_lgb = key
        self.last_drag_dial_value = nil
    end

    if not self.selected_lgb then
        return
    end

    -- Run the calculation approximately 2 times a second to avoid spamming
    self.tick_counter = (self.tick_counter or 0) + 1
    if self.tick_counter < 5 then return end
    self.tick_counter = 0

    local delivery_mode = Util.DeliveryMode()

    if delivery_mode ~= "TGT_FIND" then
        self.last_drag_dial_value = nil
        return
    end

    local drag_dial_value, drag_coeff, _, _, dive_now = compute_dial(self.selected_lgb)
    local off = level_offset(dive_now)
    if off ~= 0 and self.selected_lgb then
        drag_dial_value = math.max(1, math.min(999, drag_dial_value + off))
        drag_coeff = drag_dial_value / 100
    end

    -- If the required dial value has changed, have Jester physically update it
    if drag_dial_value ~= self.last_drag_dial_value then
        self.last_drag_dial_value = drag_dial_value
        AGLog.Info('Active LGB: drag changed to %s, adjusting dial', tostring(drag_coeff))
        Dispatch("agp_lgb_apply", drag_dial_value)
    end
end

return Lgb
