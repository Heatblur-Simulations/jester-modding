-- Periodic IFF challenge (Nov 2026). Jester presses the IFF challenge button on his own while the radar is the screen in use:
--   * every Config.IFF_PERIOD_S, with or without radar contacts (an IFF return can show on the scope with no radar paint),
--   * at once when a contact he has not had for a while appears (Config.IFF_ON_NEW_CONTACT),
--   * at once when a lock is made (Config.IFF_ON_LOCK; BFM has its own challenge on lock, see BFM.lua, and nothing here runs in BFM).
-- Never while the radar is off or in standby, while the scope is not the radar picture (Pave Spike, Maverick, any other video), or outside
-- the A2A radar context. Challenges are at least Config.IFF_MIN_GAP_S apart and never stacked on one still being pressed.
-- Triggers are radar contacts only: IFF-only returns are invisible to Jester (see DESIGN.md).
local Utilities = require('base.Utilities')
local Config = require 'aaplus.Config'
local AADLog = require 'aaplus.Log'
local Engagement = require 'aaplus.Engagement'

local Iff = {}

local last_t = -1e9          -- last challenge pressed
local known = {}             -- radar contact id -> last time it was on the radar
local lock_id                -- the contact locked at the last update
local pending                -- reason of a challenge held back by the minimum gap
local last_task
local gate_why               -- last refusal logged
local busy_logged
local seen_state = {}        -- last logged position of each probed knob

local function now_seconds()
    local t = 0
    pcall(function()
        local raw = Utilities.GetTime().mission_time
        t = type(raw) == 'number' and raw or raw:ConvertTo(s).value
    end)
    return t
end

local function knob(name)
    local v
    pcall(function() v = GetJester():GetCockpit():GetManipulator(name):GetState() end)
    return v
end

local function in_list(v, list)
    if v == nil then return false end
    local sv = string.upper(tostring(v))
    for _, w in ipairs(list or {}) do
        if string.upper(tostring(w)) == sv then return true end
    end
    return false
end

function Iff.Reset()
    last_t, known, lock_id, pending, last_task, gate_why = -1e9, {}, nil, nil, nil, nil
end

-- The radar is the screen in use. Returns true, or false and a short reason.
local function screen_ok(State, Api, RCfg)
    if not (State.is_active and Api.IsPowered()) then return false, 'radar off' end
    local rm = knob('Radar Mode')
    if in_list(rm, Config.IFF_RADAR_OFF_STATES) then return false, 'radar mode ' .. tostring(rm) end
    if State.current_context_mode ~= RCfg.context_mode.A2A then return false, 'not A2A' end
    if Api.IsInDogfightMode() then return false, 'dogfight mode' end
    if Api.IsBoresightMode() then return false, 'boresight mode' end
    local list = Config.IFF_VIDEO_RADAR_STATES
    if list and #list > 0 then
        local v = knob('Video Select')
        if not in_list(v, list) then return false, 'video select ' .. tostring(v) end
    end
    list = Config.IFF_SCREEN_RADAR_STATES
    if list and #list > 0 then
        local v = knob('Screen Mode')
        if not in_list(v, list) then return false, 'screen mode ' .. tostring(v) end
    end
    return true
end

-- Logs the position of the scope and radar knobs whenever they change, so the video-select values can be read off a test.
local function probe_knobs()
    if not Config.IFF_LOG_KNOBS then return end
    for _, name in ipairs({ 'Video Select', 'Screen Mode', 'Radar Mode' }) do
        local v = tostring(knob(name))
        if seen_state[name] ~= v then
            AADLog.Info('IFF: %s = %s', name, v)
            seen_state[name] = v
        end
    end
end

-- The cursor position on the scope (-1..1), for the log: a challenge was reported missing while the cursor sat at the center.
local function cursor_text()
    local x, y
    pcall(function()
        local g = '/Radar/Digital Scan Converter Group Screen'
        x, y = GetProperty(g, 'TDC X').value, GetProperty(g, 'TDC Y').value
    end)
    if tonumber(x) and tonumber(y) then return string.format('cursor %.2f/%.2f', x, y) end
    return 'cursor ?'
end

local function press(reason, now)
    local State, Api = require('radar.State'), require('radar.Api')
    local Task = require('base.Task')
    local task = Task:new()
    -- Above the radar scan tasks (priority 1): at equal priority the press waited behind them and went out every 25 to 30 s (user, Nov 10 2026).
    pcall(function() task:SetPriority(Config.IFF_PRIORITY or 1.5) end)
    if Config.IFF_SAY then task:Say('contacts_iff/checkingiff') end
    task:Require({ hands = true })
    Api.ClickIffButton(task)
    pcall(function()
        task:AddOnActivationCallback(function()
            AADLog.Info('IFF: challenge started %.1f s after it was queued (%s)', now_seconds() - now, reason)
        end)
    end)
    GetJester():AddTask(task)
    last_task, last_t, pending = task, now, nil
    AADLog.Info('IFF: challenge queued (%s, %s)', reason, cursor_text())
end

function Iff.Update()
    if not Config.IFF_PERIODIC then return end
    local now = now_seconds()
    if now < last_t then last_t = -1e9 end            -- a mission restart
    pcall(probe_knobs)
    if Engagement.state == Engagement.BFM then lock_id, pending = nil, nil return end
    local State, Api, RCfg = require('radar.State'), require('radar.Api'), require('radar.Config')
    local ok, why = screen_ok(State, Api, RCfg)
    if not ok then
        if why ~= gate_why then AADLog.Info('IFF: no challenges (%s, %s)', why, cursor_text()) gate_why = why end
        pending = nil
        return
    end
    if gate_why then AADLog.Info('IFF: challenges resume') gate_why = nil end

    -- Contacts on the radar now (stock ignores contacts with fewer than 2 hits).
    local n, new_id = 0, nil
    local minhits = Config.IFF_MIN_HITS or 2
    local forget = Config.IFF_NEW_FORGET_S or 60
    for id, t in pairs(radar_targets or {}) do
        if type(id) == 'number' and type(t) == 'table' and (t.number_of_hits or 0) >= minhits then
            n = n + 1
            local seen = known[id]
            if not seen or now - seen > forget then new_id = new_id or id end
            known[id] = now
        end
    end

    local locked = State.target_currently_locked
    local lid = locked and (locked.id or locked) or nil
    local new_lock = lid ~= nil and lid ~= lock_id
    lock_id = lid

    local want
    if new_lock and Config.IFF_ON_LOCK then want = 'lock ' .. tostring(lid)
    elseif new_id and Config.IFF_ON_NEW_CONTACT then want = 'new contact ' .. tostring(new_id)
    elseif now - last_t >= (Config.IFF_PERIOD_S or 15) then want = 'periodic' end
    want = want or pending
    if not want then return end

    -- Not stacked: the last challenge must be done and the gap kept. A held-back lock or new contact goes out when the gap is over.
    local busy = false
    if last_task then pcall(function() busy = not last_task:IsFinished() end) end
    if busy or now - last_t < (Config.IFF_MIN_GAP_S or 5) then
        if want ~= 'periodic' then pending = want end
        if busy and not busy_logged then busy_logged = true AADLog.Info('IFF: the last challenge is still waiting for Jester (%s held back)', want) end
        return
    end
    busy_logged = false
    local okp, err = pcall(press, want, now)
    if not okp then AADLog.Info('IFF: challenge failed: %s', tostring(err)) pending = nil end
end

return Iff
