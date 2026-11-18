-- Mode policy.
--   UNIFIED  Jester in charge until the pilot touches the cursor, then Pilot control, then back.
--            JESTER owner: Phase 3/4 behavior: stock auto-focus follows the threat score (a focused group
--            keeps it unless a rival beats it by SWITCH_MARGIN) and Jester searches RWR/IFF cues himself.
--            The pilot's stick input (the knob reads something other than what Jester last wrote) hands
--            the cursor to the pilot: his search stops with the antenna elevation held, his focus is dropped,
--            auto-focus goes off.
--            PILOT owner: as PILOT mode below. A context double-press with nothing focused, or
--            HANDBACK_IDLE_S without a slew, scan or target, gives control back to Jester. With a
--            contact focused, a double-press is stock (it releases the focus, the pilot keeps control).
--            In Jester's hands a double-press releases the focus and holds auto-focus off for
--            DOUBLE_HOLDOFF_S so stock does not re-grab the same contact.
--   PILOT    The cursor belongs to the pilot unless a target is focused/highlighted/locked, then Jester
--            holds it (stock follows the target) until the pilot double-presses the context button.
--            Pilot owns the cursor: stock's cursor logic is skipped and Jester never moves it. Moving it
--            cancels any Jester scan on the spot, leaving the antenna elevation where it was.
--            CURSOR_SETTLE_S after the cursor stops, a search starts at the cursor's bearing and range: once
--            at the elevation the interrupted scan was at, then level, then up or down depending on which
--            way the cursor was last moved vertically (the "bump"; the stock elevation menu is unused).
--   OFF      Stock pass-through.
local Utilities = require('base.Utilities')
local Config = require 'aaplus.Config'
local AADLog = require 'aaplus.Log'
local Patches = require 'aaplus.Patches'
local Picture = require 'aaplus.Picture'
local Cues = require 'aaplus.Cues'
local Search = require 'aaplus.Search'
local Engagement = require 'aaplus.Engagement'
local Stick = require 'aaplus.Stick'

local Modes = {}
Modes.mode = 'OFF'
Modes.owner = 'JESTER'      -- UNIFIED: who has the cursor, 'JESTER' or 'PILOT' (PILOT mode: always the pilot)
Modes.vert_dir = nil        -- last vertical cursor movement: +1 up, -1 down; nil until the pilot has bumped (then the default pattern is used)

local cur = {}   -- a settled cursor position waiting to be acted on
local gate = {}  -- cursor ownership state (see CursorGate)

local function now_seconds()
    local t = 0
    pcall(function()
        local raw = Utilities.GetTime().mission_time
        t = type(raw) == 'number' and raw or raw:ConvertTo(s).value
    end)
    return t
end

local function stock()
    return require('radar.State'), require('radar.Api'), require('radar.Config')
end

local function prop(path, name)
    local ok, p = pcall(GetProperty, path, name)
    if not ok or not p then return nil end
    local v = p.value
    for _ = 1, 2 do
        if type(v) ~= 'number' and v ~= nil then
            local ok2, r = pcall(function() return v.value end)
            if ok2 and r ~= nil then v = r end
        end
    end
    return tonumber(v)
end

local function cursor_behavior()
    local ok, mc = pcall(function() return GetJester().behaviors[require('radar.MoveRadarCursor')] end)
    return ok and mc or nil
end

-- Cursor position in -1..1 units: the TDC properties, else the behavior's own copy.
local function tdc()
    local g = '/Radar/Digital Scan Converter Group Screen'
    local x, y = prop(g, 'TDC X'), prop(g, 'TDC Y')
    if x and y then return x, y, 'prop' end
    local mc = cursor_behavior()
    if mc and tonumber(mc.current_cursor_x) and tonumber(mc.current_cursor_y) then
        return tonumber(mc.current_cursor_x), tonumber(mc.current_cursor_y), 'mc'
    end
    return nil, nil, 'none'
end

local function restore_auto_focus()
    if Modes.saved_auto_focus ~= nil then
        pcall(function() require('radar.State').is_auto_focus_allowed = Modes.saved_auto_focus end)
        Modes.saved_auto_focus = nil
    end
end

local function has_target(State)
    return State.target_to_lock or State.target_currently_locked or State.target_to_focus_on
        or State.target_to_highlight or State.pilot_requested_target_to_highlight
end

local function pilot_owner()
    return Modes.mode == 'PILOT' or (Modes.mode == 'UNIFIED' and Modes.owner == 'PILOT')
end
Modes.IsPilotOwner = pilot_owner

-- Jester's cue searches (and auto-focus) run only while he is in charge in UNIFIED mode.
function Modes.JesterSearches()
    return Modes.mode == 'UNIFIED' and Modes.owner == 'JESTER'
end

local function set_owner(owner)
    Modes.owner = owner
    Search.pilot_owns_cursor = pilot_owner()
end

local function radar_ready(State, Api, rcfg)
    return State.is_active and Api.IsPowered()
        and State.current_context_mode == rcfg.context_mode.A2A
        and not Api.IsInDogfightMode() and not Api.IsBoresightMode()
        and Engagement.state ~= Engagement.BFM
end

function Modes.SetMode(mode)
    Modes.mode = mode
    Modes.paused = nil
    cur = {}
    gate = {}
    Modes.holdoff_until = nil
    set_owner(mode == 'PILOT' and 'PILOT' or 'JESTER')
    if not pilot_owner() then
        Cues.ClearCursor()
        Search.ClearCarry('mode change')
        restore_auto_focus()
    end
end

function Modes.StatusSuffix()
    if Modes.mode ~= 'UNIFIED' then return nil end
    return Modes.owner == 'PILOT' and 'pilot' or 'Jester'
end

-- Jester's stick commands are the only thing that should move the cursor while he is in charge.
-- Give the cursor to the pilot (UNIFIED, from the JESTER owner).
function Modes.HandToPilot(reason, x, y, ky)
    local State = stock()
    if State.target_to_lock or State.target_currently_locked then return false end
    local now = now_seconds()
    set_owner('PILOT')
    Modes.activity = now
    AADLog.Info('unified: the pilot has the cursor (%s)', reason)
    -- The pilot is choosing now: Jester's focus does not survive.
    State.target_to_focus_on, State.target_to_highlight, State.pilot_requested_target_to_highlight = nil, nil, nil
    gate = { owner = 'pilot', since = now - 1 }
    if ky and math.abs(ky) > Config.STICK_EPS then Modes.vert_dir = ky < 0 and 1 or -1 end
    gate.slewing = true
    gate.moved_at = now
    cur.pending = nil
    Cues.ClearCursor()
    if Search.IsActive() then Search.Interrupt('pilot slew') end
    return true
end

-- Give the cursor back to Jester (UNIFIED, from the PILOT owner).
function Modes.HandBack(reason)
    set_owner('JESTER')
    Modes.paused = nil
    gate, cur = {}, {}
    if Search.IsActive() then Search.Stop('hand back') end
    Search.ClearCarry('hand back')
    Cues.ClearCursor()
    Cues.suppress_until = 0
    restore_auto_focus()
    AADLog.Info('unified: Jester has the cursor back (%s)', reason)
end

-- Runs just before the stock handler of a context-button double press.
function Modes.ContextDouble()
    if Modes.mode ~= 'UNIFIED' then return end
    local State = stock()
    if Modes.owner == 'PILOT' then
        -- A focused contact: stock releases it and the pilot keeps control. Otherwise: back to Jester.
        if not has_target(State) then Modes.HandBack('double press') end
    elseif State.target_to_focus_on or State.target_to_highlight then
        -- Stock's reset would be undone at once by auto-focus; hold it off for a while.
        Modes.holdoff_until = now_seconds() + Config.DOUBLE_HOLDOFF_S
        AADLog.Info('unified: focus released, auto-focus held off for %d s', Config.DOUBLE_HOLDOFF_S)
    end
end

-- Jester moves the cursor by deflecting the antenna hand-control stick and releases it from Tick.
-- While Tick is skipped, release it here.
function Modes.ReleaseStick()
    local mc = cursor_behavior()
    if mc and mc.is_cursor_moving and mc.StopCursorMovement then
        mc:StopCursorMovement()
    end
end

-- The pilot started moving the cursor: end any Jester scan (the antenna stays at its elevation).
local function begin_slew(x, y, now)
    gate.slewing = true
    gate.moved_at = now
    cur.pending = nil
    Cues.ClearCursor()
    if Search.IsActive() then Search.Interrupt('pilot slew') end
    AADLog.Info('cursor: pilot slew (x=%.2f y=%.2f)', x, y)
end

-- Runs on every Tick of MoveRadarCursor from the wrapper, before stock acts; true = skip stock.
--   Jester in charge (UNIFIED)  stock's Tick runs; the pilot's stick input hands the cursor over.
--   target exists               Jester owns the cursor: stock follows the target.
--   no target                   the pilot owns it: stock's Tick is skipped, the stick released, and any
--                               movement or stick input is the pilot's slew.
function Modes.CursorGate()
    if Engagement.state == Engagement.BFM then gate = {} return false end
    if Modes.mode ~= 'UNIFIED' and Modes.mode ~= 'PILOT' then gate = {} return false end
    local mc = cursor_behavior()
    local x, y = tdc()
    if not mc or not x or not y then return false end
    local State, Api, rcfg = stock()
    local now = now_seconds()

    if Modes.mode == 'UNIFIED' and Modes.owner == 'JESTER' then
        if not (State.target_to_lock or State.target_currently_locked) and radar_ready(State, Api, rcfg) then
            local inp, _, ky = Stick.PilotInput(Config.STICK_EPS)
            if inp then Modes.HandToPilot('stick input', x, y, ky) end
        end
        if Modes.owner == 'JESTER' then return false end
    end

    if has_target(State) then
        if gate.owner ~= 'jester' then
            gate.owner = 'jester'
            gate.slewing = false
            cur.pending = nil
            Cues.ClearCursor()
            AADLog.Info('cursor: a target is focused, Jester holds the cursor')
        end
        return false
    end
    if gate.owner ~= 'pilot' then
        gate.owner = 'pilot'
        gate.since = now
        gate.ref = nil
        AADLog.Info('cursor: the pilot has the cursor')
    end
    Modes.ReleaseStick()
    pcall(function() mc.desired_cursor_x, mc.desired_cursor_y = x, y end)
    local ref = gate.ref
    if not ref or now - ref.t > 0.15 then
        gate.ref = { x = x, y = y, t = now }
        ref = gate.ref
    end
    if now - gate.since > 0.4 then
        local dx, dy = x - ref.x, y - ref.y
        local inp, kx, ky = Stick.PilotInput(Config.STICK_EPS)
        local moved = math.abs(dx) > Config.PILOT_SLEW_FRAME_EPS or math.abs(dy) > Config.PILOT_SLEW_FRAME_EPS
        if moved or inp then
            if not gate.slewing then begin_slew(x, y, now) end
            gate.moved_at = now
            -- Which way the cursor last moved: sideways (left/right) or vertical (range). Read when it stops (Modes.Update).
            if inp and kx and ky and (math.abs(kx) > Config.STICK_EPS or math.abs(ky) > Config.STICK_EPS) then
                gate.last_axis = math.abs(kx) > math.abs(ky) and 'side' or 'vert'
            elseif moved then
                gate.last_axis = math.abs(dx) > math.abs(dy) and 'side' or 'vert'
            end
            if inp and ky and math.abs(ky) > Config.STICK_EPS then
                Modes.vert_dir = ky < 0 and 1 or -1       -- stick forward (y < 0) is cursor up
            elseif math.abs(dy) > Config.BUMP_EPS and math.abs(dy) >= math.abs(dx) * 0.5 then
                Modes.vert_dir = dy > 0 and 1 or -1
            end
            gate.ref = { x = x, y = y, t = now }
        end
    else
        gate.ref = { x = x, y = y, t = now }
    end
    return true
end

-- Radar range bump: the pilot moves the cursor into the top or bottom edge region of the scope = he wants to see further or nearer.
-- Jester steps one range; the cursor has to leave the edge region and enter it again for another step.
-- Jester steps the radar range up (or down) one setting. Ranges are read from the stock radar config (rcfg.range.nm_<N>).
local edge_latched = false   -- a bump happened and the cursor has not left the edge region since: no further bump until it does
local function range_steps(rcfg)
    local out = {}
    for _, n in ipairs({ 5, 10, 15, 20, 25, 30, 40, 50, 60, 80, 100, 120, 160, 200, 300 }) do
        local v = rcfg.range and rcfg.range['nm_' .. n]
        if v ~= nil then out[#out + 1] = { nm = n, setting = v } end
    end
    return out
end

local function range_bump(State, Api, rcfg, x, y, now)
    local edge = Config.RANGE_BUMP_EDGE or 0.88
    local dir = (y >= edge and 1) or (y <= -edge and -1) or 0
    if dir == 0 then gate.edge_since = nil edge_latched = false return end   -- left the edge region: armed again
    if edge_latched then return end
    gate.edge_since = gate.edge_since or now
    if now - gate.edge_since < (Config.RANGE_BUMP_HOLD_S or 0.4) then return end   -- the cursor has to stay at the edge a moment
    local cur_nm
    pcall(function() cur_nm = Api.GetCurrentDisplayRange():ConvertTo(NM).value end)
    local steps = range_steps(rcfg)
    if not cur_nm or #steps < 2 then return end
    local idx, best
    for i, st in ipairs(steps) do
        local d = math.abs(st.nm - cur_nm)
        if not best or d < best then best, idx = d, i end
    end
    local nxt = steps[idx + dir]
    edge_latched = true
    gate.edge_since = nil
    if not nxt then
        AADLog.Info('range bump: already at the %s range (%d NM)', dir > 0 and 'longest' or 'shortest', steps[idx].nm)
        return
    end
    State.pilot_requested_range = nxt.setting
    AADLog.Info('range bump: cursor at the %s edge (y=%.2f), range %d -> %d NM', dir > 0 and 'top' or 'bottom', y, steps[idx].nm, nxt.nm)
end

-- Called a few times a second by the Director.
function Modes.Update()
    if Modes.mode ~= 'UNIFIED' and Modes.mode ~= 'PILOT' then return end
    local State, Api, rcfg = stock()
    local now = now_seconds()
    local ready = radar_ready(State, Api, rcfg)

    -- Auto-focus stays off while the pilot picks the target, and for a while after a double press.
    local holdoff = Modes.holdoff_until and now < Modes.holdoff_until
    if Modes.holdoff_until and not holdoff then Modes.holdoff_until = nil end
    if pilot_owner() or holdoff then
        if State.is_auto_focus_allowed ~= false then
            if Modes.saved_auto_focus == nil then
                Modes.saved_auto_focus = State.is_auto_focus_allowed
                -- Stock drops a focus it did not get from the pilot as soon as auto-focus is off.
                -- On a mode change the current focus is the pilot's own.
                local cur_t = State.target_to_focus_on or State.target_to_highlight
                if pilot_owner() and cur_t and not State.pilot_requested_target_to_highlight then
                    State.pilot_requested_target_to_highlight = cur_t
                    AADLog.Info('mode: kept the current focus %s across the mode change', tostring(cur_t.id))
                end
            end
            State.is_auto_focus_allowed = false
        end
    elseif Modes.saved_auto_focus ~= nil then
        restore_auto_focus()
    end

    if not pilot_owner() then return end
    if not ready then Modes.activity = now return end
    local x, y = tdc()
    if not x or not y then return end

    if has_target(State) then
        cur.pending = nil
        gate.slewing = false
        Modes.paused = nil
        Modes.activity = now
        return
    end

    if not Search.IsActive() then pcall(range_bump, State, Api, rcfg, x, y, now) end

    -- The cursor has been still for CURSOR_SETTLE_S: act on where it was left.
    if gate.slewing and now - (gate.moved_at or now) >= Config.CURSOR_SETTLE_S then
        gate.slewing = false
        -- If the last movement before the cursor stopped was sideways, the elevation centers and does not scan up or down
        -- (the counterpart of the vertical bump, which picks the scan direction).
        local sideways = gate.last_axis == 'side'
        -- The interrupted scan's elevation is held for CURSOR_HOLD_S after the cursor stopped moving, so the pilot can lock a contact
        -- by hand; only then does the bump logic (above, and Search) take over.
        local start_at = (gate.moved_at or now) + (Config.CURSOR_HOLD_S or 0.5)
        cur.pending = { x = x, y = y, since = now, next_try = math.max(now, start_at), dir = Modes.vert_dir, hold = sideways }
    end
    local pend = cur.pending
    if pend and not gate.slewing and now >= pend.next_try then
        if Search.IsActive() or now - pend.since > 6 then
            cur.pending = nil
        elseif Modes.HandleSettled(State, Api, x, y, pend.dir, not pend.logged, pend.hold) then
            cur.pending = nil
        else
            pend.logged = true
            pend.next_try = now + 0.3
        end
    end
    -- A running cursor search follows the cursor bearing.
    local cue = Cues.list.cursor
    if cue and Search.cue == cue and not gate.slewing then cue.az = x * 60 end
    -- An interrupted scan nobody continued: give the radar back to stock.
    if Search.carry and not Search.IsActive() and not gate.slewing and not cur.pending
        and now - math.max(Search.carry.at or 0, gate.moved_at or 0) > Config.CARRY_S then
        Search.ClearCarry('timeout')
    end
    -- UNIFIED: a pilot who has done nothing for a while hands the cursor back to Jester.
    if Modes.mode == 'UNIFIED' then
        if gate.slewing or Search.IsActive() or cur.pending then Modes.activity = now end
        if now - (Modes.activity or now) >= Config.HANDBACK_IDLE_S then Modes.HandBack('idle') end
    end
end

-- The cursor was left at (x, y). Returns true when it is dealt with (false: try again).
function Modes.HandleSettled(State, Api, x, y, dir, first, hold)
    local az = x * 60
    -- TDC Y is range: y = 2 * range / display range - 1.
    local rng
    pcall(function()
        local disp = Api.GetCurrentDisplayRange():ConvertTo(NM).value
        if type(disp) == 'number' and disp > 0 then rng = math.max(5, (y + 1) / 2 * disp) end
    end)
    if first then
        AADLog.Info('cursor: settled x=%.2f y=%.2f (az %d, range %s NM, %s first)', x, y, math.floor(az + 0.5),
            rng and string.format('%.0f', rng) or '?', (not dir or dir == 0) and 'no bump, up' or (dir < 0 and 'bump down' or 'bump up'))
    end
    Cues.suppress_until = 0
    local carry = Search.carry
    local cue = Cues.AddCursorCue(az, rng)
    -- Sideways bumps (the last movement before the cursor stopped was sideways): the first pauses the elevation scan where it
    -- is, the next one centers the elevation. A vertical bump ends the pause and picks the scan direction again.
    local hold_angle, centre
    if hold then
        local p = Modes.paused
        centre = p ~= nil and now_seconds() - p.at <= (Config.SEARCH_HOLD_S or 120)
        hold_angle = centre and 0 or (carry and carry.angle or nil)
    end
    if Search.Start(cue, { dir = dir, first_angle = carry and carry.angle or nil, hold = hold, hold_angle = hold_angle, centre = centre }) then
        Modes.paused = hold and { at = now_seconds() } or nil
        Search.auto = false
        pcall(Search.Step)   -- apply the first band now instead of waiting for stock's next phase
        return true
    end
    Cues.ClearCursor()
    return false
end

function Modes.Reset()
    cur = {}
    gate = {}
end

-- Fixes.Wrap cannot be used here: it writes a marker onto the module, and Behavior classes are
-- read-only prototypes. The wrapper keeps its marker and its link to this module in globals, so a
-- reload neither wraps twice nor leaves the wrapper pointing at a dead copy of this file.
_G.AAD_MODES = Modes

function Modes.Install(Fixes)
    Patches.Install('cursor_hold', function()
        local MoveRadarCursor = require('radar.MoveRadarCursor')
        if rawget(_G, 'AAD_CURSOR_WRAPPED') then return end
        local original = MoveRadarCursor.Tick
        assert(type(original) == 'function', 'MoveRadarCursor.Tick not found')
        MoveRadarCursor.Tick = function(...)
            local M = rawget(_G, 'AAD_MODES')
            if M and Patches.is_active() and Config.CURSOR_HOLD then
                local ok, skip = pcall(M.CursorGate)
                if ok and skip then return end
            end
            return original(...)
        end
        _G.AAD_CURSOR_WRAPPED = true
    end)
end

return Modes
