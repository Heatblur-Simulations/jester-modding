-- Phase 7: BFM mode. A separate module beside the Director, driven by Engagement.state.
--   Enter  the Director yields (searches stop, cursor and antenna go back to stock) and the muted
--          stock behaviors stay silent until BFM ends.
--   During lookout/clock calls, RWR, missile warnings, countermeasures, damage reports carry on (they
--          are never touched); Jester also calls speed on his own schedule.
--   Exit   the wrappers pass through again, the Director resumes from a fresh picture.
-- Muting wraps each behavior's Tick once (marker and module link in globals, like the cursor patch).
local Utilities = require('base.Utilities')
local Config = require 'aaplus.Config'
local AADLog = require 'aaplus.Log'
local Patches = require 'aaplus.Patches'
local Engagement = require 'aaplus.Engagement'
local Search = require 'aaplus.Search'
local Cues = require 'aaplus.Cues'
local Picture = require 'aaplus.Picture'
local Modes = require 'aaplus.Modes'

local BFM = {}
BFM.active = false
local last_call_t, last_call_speed
local iffed_lock
local speed_task, speed_band, speed_said_t

local function now_seconds()
    local t = 0
    pcall(function()
        local raw = Utilities.GetTime().mission_time
        t = type(raw) == 'number' and raw or raw:ConvertTo(s).value
    end)
    return t
end

function BFM.IsActive()
    return BFM.active
end

function BFM.Enter()
    BFM.active = true
    last_call_t, last_call_speed = nil, nil
    iffed_lock = nil
    speed_task, speed_band, speed_said_t = nil, nil, nil
    pcall(function()
        if Search.IsActive() then Search.Stop('bfm') end
        Search.ClearCarry('bfm')
        Cues.ClearCursor()
        if Modes.mode == 'UNIFIED' and Modes.owner == 'PILOT' then Modes.HandBack('bfm') end
    end)
    AADLog.Info('BFM: entered, Director yields, %d behaviors muted', #Config.BFM_MUTE)
end

function BFM.Exit(reason)
    if not BFM.active then return end
    BFM.active = false
    pcall(function()
        Picture.Reset()
        Cues.suppress_until = 0
        if Modes.mode == 'UNIFIED' then Modes.HandBack('bfm over') end
    end)
    AADLog.Info('BFM: over (%s), Director resumes', reason or 'engagement')
end

-- Hard release: the Director is off or the cockpit changed.
function BFM.Release()
    BFM.active = false
    last_call_t, last_call_speed = nil, nil
end

-- Indicated airspeed that gives a Mach number at a pressure altitude (ISA).
local function ias_for_mach(mach, alt_ft)
    local a0 = 661.47
    local alt_m = alt_ft * 0.3048
    local p_ratio
    if alt_m < 11000 then
        p_ratio = (1 - 2.25577e-5 * alt_m) ^ 5.25588
    else
        p_ratio = 0.22336 * math.exp(-(alt_m - 11000) / 6341.6)
    end
    local qc_p = (1 + 0.2 * mach ^ 2) ^ 3.5 - 1      -- qc / ambient pressure
    local qc_p0 = qc_p * p_ratio                      -- qc / sea-level pressure
    return a0 * math.sqrt(5 * ((qc_p0 + 1) ^ (2 / 7) - 1))
end

-- Speed calls around best sustained turn rate (STR, Mach SPEED_STR_MACH):
--   50 kt or more above or below it  the speed is called every SPEED_REPEAT_S
--   back at STR                       one call when the speed comes back inside the band
-- The numbers are the stock speed phrases (the ones near corner speed carry "almost corner" and the like).
local function speed_call(now)
    if not Config.SPEED_CALLS then return end
    local ias, str_kt
    pcall(function()
        local i = GetJester().awareness:GetObservation('indicated_airspeed')
        local alt = GetJester().awareness:GetObservation('barometric_altitude')
        if i and alt then
            ias = i
            str_kt = ias_for_mach(Config.SPEED_STR_MACH, alt:ConvertTo(ft).value)
        end
    end)
    if not ias then return end
    local dev = ias:ConvertTo(kt).value - str_kt
    local out = Config.SPEED_STR_BAND_KT
    local band = speed_band or 'in'
    if band == 'in' then
        if dev <= -out then band = 'low' elseif dev >= out then band = 'high' end
    elseif math.abs(dev) < out - Config.SPEED_BAND_HYST then
        band = 'in'
    end
    local changed = band ~= (speed_band or 'in')
    speed_band = band
    local due
    if band == 'in' then
        due = changed                                  -- the one call on the way back to STR
    else
        due = (not speed_said_t) or changed or now - speed_said_t >= Config.SPEED_REPEAT_S
    end
    if not due then return end
    if speed_said_t and now - speed_said_t < Config.SPEED_CALL_MIN_S then return end
    if speed_task then
        local fin = true
        pcall(function() fin = speed_task:IsFinished() end)
        if not fin then return end
    end
    local kts = ias:ConvertTo(kt).value
    pcall(function()
        local Task = require('base.Task')
        local tens = math.floor(kts / 10 + 0.5) * 10
        local phrase
        if tens < 100 then phrase = 'awareness/wereslow'
        elseif tens > 600 then phrase = 'awareness/werefast'
        else phrase = 'awareness/' .. Utilities.NumberToText(tens) end
        speed_task = Task:new()
        speed_task:Say(phrase)
        speed_task:AddOnActivationCallback(function()
            AADLog.Info('BFM: speed call SPOKEN %s (t %.1f)', phrase, now_seconds())
        end)
        GetJester():AddTask(speed_task)
    end)
    AADLog.Info('BFM: speed call %s (%d kt, STR %d kt, dev %+d, t %.1f)', band, ias:ConvertTo(kt).value, str_kt, dev, now)
    speed_said_t = now
end

-- A new lock in BFM gets an IFF challenge at once (once per locked target).
local function iff_on_lock()
    if not Config.BFM_IFF_ON_LOCK then return end
    local State = require('radar.State')
    local Api = require('radar.Api')
    local locked = State.target_currently_locked
    if not locked then iffed_lock = nil return end
    local id = locked.id or locked
    if iffed_lock == id then return end
    iffed_lock = id
    if not (State.is_active and Api.IsPowered()) then return end
    local Task = require('base.Task')
    local task = Task:new()
    if Config.BFM_IFF_SAY then task:Say('contacts_iff/checkingiff') end
    task:Require({ hands = true })
    Api.ClickIffButton(task)
    GetJester():AddTask(task)
    AADLog.Info('BFM: lock %s, IFF challenge', tostring(id))
end

-- Runs from the Director's engagement tick.
function BFM.Update()
    local _, changed = Engagement.Update()
    local in_bfm = Engagement.state == Engagement.BFM
    if changed then
        if in_bfm then BFM.Enter() else BFM.Exit() end
    elseif in_bfm and not BFM.active then
        BFM.Enter()
    end
    if BFM.active then
        speed_call(now_seconds())
        pcall(iff_on_lock)
    end
end

function BFM.Install()
    _G.AAD_BFM = BFM
    local marks = rawget(_G, 'AAD_BFM_WRAPPED')
    if not marks then marks = {} _G.AAD_BFM_WRAPPED = marks end
    for _, name in ipairs(Config.BFM_MUTE) do
        Patches.Install('bfm_mute_' .. name, function()
            if marks[name] then return end
            local class = require(name)
            local original = class.Tick
            assert(type(original) == 'function', name .. '.Tick not found')
            class.Tick = function(...)
                local B = rawget(_G, 'AAD_BFM')
                if B and B.active and Patches.is_active() then return end
                return original(...)
            end
            marks[name] = true
        end)
    end
end

return BFM
