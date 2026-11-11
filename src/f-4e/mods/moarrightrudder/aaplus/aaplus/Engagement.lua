-- Engagement state: NONE / BVR / TRANSITION / BFM, from the closest air threat and the radar mode.
--   TRANSITION  a bandit inside TRANSITION_NM
--   BFM         boresight/CAGE selected with a bandit inside BFM_RANGE_NM (or inside Heatblur's
--               dogfight distance, the merge, whatever the radar is doing)
--   leaving BFM no bandit inside BFM_EXIT_NM for BFM_EXIT_S, or the radar back out of boresight/CAGE
--               for BFM_CAGE_LOST_S while the fight is not a merge. The gap between BFM_RANGE_NM and
--               BFM_EXIT_NM keeps a bandit hovering at the edge from toggling the mode.
local Utilities = require('base.Utilities')
local Config = require 'aaplus.Config'
local AADLog = require 'aaplus.Log'

local Engagement = {}

Engagement.NONE = 'NONE'
Engagement.BVR = 'BVR'
Engagement.TRANSITION = 'TRANSITION'
Engagement.BFM = 'BFM'

Engagement.state = Engagement.NONE
Engagement.closest_nm = nil
Engagement.cage = false
local far_since, cage_lost_since

local function now_seconds()
    local t = 0
    pcall(function()
        local raw = Utilities.GetTime().mission_time
        t = type(raw) == 'number' and raw or raw:ConvertTo(s).value
    end)
    return t
end

local function closest_threat_nm()
    local nm
    pcall(function()
        local threat = GetJester().awareness:GetClosestAirThreat() or false
        if threat and threat.polar_body then
            nm = threat.polar_body.length:ConvertTo(NM).value
        end
    end)
    return nm
end

local function merge_nm()
    local v = 1.75
    pcall(function() v = JesterConstants.dogfight_distance:ConvertTo(NM).value end)
    return v
end

local function cage_selected()
    local on = false
    pcall(function()
        local Api = require('radar.Api')
        on = (Api.IsBoresightMode() or Api.IsInDogfightMode()) and true or false
    end)
    return on
end

-- Returns (new_state, changed).
function Engagement.Update()
    local nm = closest_threat_nm()
    local now = now_seconds()
    local cage = cage_selected()
    Engagement.closest_nm = nm
    Engagement.cage = cage
    local merged = nm ~= nil and nm < merge_nm()
    local old = Engagement.state
    local new_state

    if old == Engagement.BFM and Config.BFM_ENABLED then
        -- Stay in BFM until one of the exit conditions has held long enough.
        if nm and nm <= Config.BFM_EXIT_NM then far_since = nil elseif not far_since then far_since = now end
        if cage or merged then cage_lost_since = nil elseif not cage_lost_since then cage_lost_since = now end
        local leave = (far_since and now - far_since >= Config.BFM_EXIT_S)
            or (cage_lost_since and now - cage_lost_since >= Config.BFM_CAGE_LOST_S)
        if leave then
            far_since, cage_lost_since = nil, nil
            new_state = (nm and nm < Config.TRANSITION_NM) and Engagement.TRANSITION or (nm and Engagement.BVR or Engagement.NONE)
        else
            new_state = Engagement.BFM
        end
    elseif not nm then
        new_state = Engagement.NONE
    elseif Config.BFM_ENABLED and ((cage and nm < Config.BFM_RANGE_NM) or merged) then
        new_state = Engagement.BFM
        far_since, cage_lost_since = nil, nil
    elseif nm < Config.TRANSITION_NM then
        new_state = Engagement.TRANSITION
    else
        new_state = Engagement.BVR
    end

    local changed = new_state ~= old
    if changed then
        AADLog.Info('engagement %s -> %s (closest %s NM, cage %s)', old, new_state, nm and string.format('%.1f', nm) or 'none', tostring(cage))
        Engagement.state = new_state
    end
    return new_state, changed
end

function Engagement.Reset()
    Engagement.state = Engagement.NONE
    Engagement.closest_nm = nil
    Engagement.cage = false
    far_since, cage_lost_since = nil, nil
end

return Engagement
