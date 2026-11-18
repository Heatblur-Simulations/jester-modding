-- Jester A/A+: owns the mode, the sub-system scheduler, the respawn lifecycle,
-- the wheel menu and the status line. Phase 1 changes nothing about Jester's behavior.
local Class = require('base.Class')
local Behavior = require('base.Behavior')
local Utilities = require('base.Utilities')
local Config = require 'aaplus.Config'
local AADLog = require 'aaplus.Log'
local Patches = require 'aaplus.Patches'
local Engagement = require 'aaplus.Engagement'
local BFM = require 'aaplus.BFM'
local Fixes = require 'aaplus.Fixes'
local Picture = require 'aaplus.Picture'
local Stick = require 'aaplus.Stick'
local Cues = require 'aaplus.Cues'
local Search = require 'aaplus.Search'
local Modes = require 'aaplus.Modes'
local Awacs = require 'aaplus.Awacs'
local Iff = require 'aaplus.Iff'

local Director = Class(Behavior)

Director.MODES = { 'OFF', 'UNIFIED', 'PILOT' }

local MODE_ITEMS = {
    { mode = 'UNIFIED', label = 'Unified', event = 'aad_mode_unified', handler = 'AADModeUnified' },
    { mode = 'PILOT', label = 'Pilot', event = 'aad_mode_pilot', handler = 'AADModePilot' },
    { mode = 'OFF',   label = 'Off',   event = 'aad_mode_off',   handler = 'AADModeOff'   },
}

local function is_valid_mode(mode)
    for _, m in ipairs(Director.MODES) do
        if m == mode then return true end
    end
    return false
end

-- Mission time in seconds as a plain number.
local function now_seconds()
    local t = 0
    pcall(function()
        local raw = Utilities.GetTime().mission_time
        if type(raw) == 'number' then
            t = raw
        else
            t = raw:ConvertTo(s).value
        end
    end)
    return t
end

function Director.Get()
    return GetJester().behaviors[Director]
end

local function menu_path()
    local path = {}
    for _, p in ipairs(Config.MENU_PARENT) do path[#path + 1] = p end
    path[#path + 1] = Config.MENU_NAME
    return path
end

-- Menu items are consumed by Wheel.Menu:new, so build fresh ones every time.
local function build_menu_item()
    local items = {}
    for _, m in ipairs(MODE_ITEMS) do
        items[#items + 1] = Wheel.Item:new({
            name = m.label,
            action = m.event,
            reaction = Wheel.Reaction.CLOSE_REMEMBER,
        })
    end
    return Wheel.Item:new({
        name = Config.MENU_NAME,
        menu = Wheel.Menu:new({ name = Config.MENU_NAME, items = items }),
    })
end

local function register_wheel_menu()
    pcall(function() Wheel.RemoveItem(Config.MENU_NAME, Config.MENU_PARENT) end)
    local ok, err = pcall(function() Wheel.AddItem(build_menu_item(), Config.MENU_PARENT) end)
    AADLog.Info('wheel menu registered ok=%s %s', tostring(ok), ok and '' or tostring(err))
end

local function register_events()
    for _, m in ipairs(MODE_ITEMS) do
        ListenTo(m.event, m.handler, function(task)
            local d = Director.Get()
            if d then d:SetMode(m.mode) end
            pcall(function() task:Roger() end)
        end)
    end
end

function Director:Constructor()
    Behavior.Constructor(self)
    AADLog.Reset()

    -- AUTO and OFFER (older builds) now mean UNIFIED.
    local start = Config.DEFAULT_MODE
    if start == 'AUTO' or start == 'OFFER' then start = 'UNIFIED' end
    self.mode = is_valid_mode(start) and start or 'UNIFIED'
    self.current_cockpit = nil
    self.menu_settle_ticks = 0
    self.last_run = {}

    -- Sub-systems run at their own periods. Each entry: name, period (s), fn(self).
    self.subsystems = {
        { name = 'engagement', period = Config.PERIOD_ENGAGEMENT, fn = self.RunEngagement },
        { name = 'picture',    period = Config.PERIOD_PICTURE,    fn = self.RunPicture },
        { name = 'cues',       period = 1.0,                      fn = self.RunCues },
        { name = 'cursor',     period = Config.PERIOD_CURSOR,     fn = self.RunCursor },
        { name = 'ui',         period = Config.PERIOD_UI,         fn = self.RunUi },
        { name = 'awacs',      period = 2.0,                      fn = function() Awacs.Poll() end },
        { name = 'iff',        period = 1.0,                      fn = self.RunIff },
    }

    Patches.SetActiveCheck(function()
        local d = Director.Get()
        return d ~= nil and d.mode ~= 'OFF'
    end)

    Fixes.Install()
    Picture.Install(Fixes)
    Search.Install(Fixes)
    Modes.Install(Fixes)
    Stick.Install()
    BFM.Install()
    Modes.SetMode(self.mode)

    register_events()

    local conflicts = Patches.DetectRadarConflicts()
    for _, c in ipairs(conflicts) do AADLog.Info('conflict warning: %s', c) end
    AADLog.Info('Director created, mode %s', self.mode)
end

function Director:SetMode(mode)
    if not is_valid_mode(mode) then return end
    if mode == self.mode then
        self:RunUi()
        return
    end
    AADLog.Info('mode %s -> %s', self.mode, mode)
    self.mode = mode
    Modes.SetMode(mode)
    BFM.Release()
    Engagement.Reset()
    Iff.Reset()
    self:RunUi()
end

function Director:StatusText()
    local suffix = Modes.StatusSuffix()
    local parts = { self.mode .. (suffix and (' ' .. suffix) or '') }
    if self.mode ~= 'OFF' then
        local nm = Engagement.closest_nm
        parts[#parts + 1] = Engagement.state .. (nm and string.format(' %.0f NM', nm) or '')
        parts[#parts + 1] = Search.StatusText() or Picture.StatusText()
        local aw = Awacs.StatusText()
        if aw then parts[#parts + 1] = aw end
    else
        parts[#parts + 1] = 'stock'
    end
    return table.concat(parts, ' | ')
end

function Director:RunEngagement()
    if self.mode == 'OFF' then BFM.Release() return end
    BFM.Update()
end

-- Periodic IFF challenge (Iff.lua); not in OFF, where stock runs alone.
function Director:RunIff()
    if self.mode == 'OFF' then Iff.Reset() return end
    Iff.Update()
end

function Director:RunPicture()
    if self.mode == 'OFF' then return end
    Picture.Update()
end

-- While the beam is held on a contact that was found, only a cue that is closer than that contact may take the radar.
function Director.CloserThanFound(cue)
    local f = Search.found
    local fr = f and f.range_nm
    local r = Cues.RangeOf(cue)
    return (fr == nil) or (r ~= nil and r < fr)
end

function Director:RunCues()
    if self.mode == 'OFF' then
        Search.Stop('mode off')
        Search.GainHoldUpdate()
        pcall(Cues.Debug)
        return
    end
    local ac = Awacs.TakeCue()
    local acue, moved
    if ac then
        local covering = Cues.EwrsCovering(ac.contact, ac.range_nm)
        if covering then
            AADLog.Info('awacs cue: stock %s az=%.0f %.0f NM is the group of %s: no cue of its own', tostring(ac.type), ac.az, ac.range_nm, covering.key)
            ac = nil
        end
    end
    if ac then
        AADLog.Info('awacs cue: %s %s az=%.0f %.0f NM %s ft', tostring(ac.src), tostring(ac.type), ac.az, ac.range_nm, tostring(ac.alt_ft))
        local far_other
        acue, moved, far_other = Cues.AddAwacsCue(ac.az, ac.range_nm, ac.alt_ft, ac.contact)
        if far_other then
            AADLog.Info('awacs cue: that report is a farther group %.0f NM from the nearer one: keeping the nearer bandit', moved or 0)
            ac = nil
        end
    end
    if ac then
        -- A search on the previous report that the contact has since left moves to the new position. A search on
        -- another cue (an RWR emitter) only gives way if the report out-scores it (threat preemption below).
        -- A contact already found is left to stock.
        -- A search on another cue that has already taken this contact's position (the report was adopted mid-search)
        -- carries on: restarting would only throw away the bars it has swept.
        local same_contact = false
        if Search.IsActive() and Search.cue and Search.cue ~= acue and Search.cue.aw_used then
            pcall(function()
                local az1, r1 = Cues.CurrentAz(Search.cue), Search.cue.aw_range_nm or Search.cue.range_nm
                if r1 then
                    local c = math.cos(math.rad(((ac.az - az1) + 180) % 360 - 180))
                    local d = math.sqrt(math.max(0, r1 * r1 + ac.range_nm * ac.range_nm - 2 * r1 * ac.range_nm * c))
                    same_contact = d <= (Config.AWACS_NEW_CUE_NM or 8)
                end
            end)
        end
        local in_gimbal = math.abs(ac.az) <= Config.CUE_START_AZ
        if not in_gimbal then AADLog.Info('awacs cue: outside the gimbal limits (az %.0f), kept until it comes inside', ac.az) end
        if in_gimbal and Search.IsActive() and Search.phase == 'sweeping' and Search.cue and not same_contact
            and Search.cue == acue and moved and moved > (Config.AWACS_NEW_CUE_NM or 8) then
            AADLog.Info('awacs cue: new report%s, restarting the search there', moved and string.format(' %.0f NM from the last', moved) or '')
            Search.Stop('new awacs report')
            acue.cooldown_until = 0
        end
    end
    local groups = Awacs.TakeEwrsGroups()
    if groups then
        Cues.SyncEwrs(groups)
        if Config.AWACS_LOG then AADLog.Info('ewrs: %d group(s) in the picture', #groups) end
    end
    Cues.Update()
    Search.GainHoldUpdate()
    -- A search the Director started by itself ends when Jester is no longer in charge.
    if not Modes.JesterSearches() and Search.IsActive() and Search.auto then Search.Stop('mode change') end
    if Modes.JesterSearches() and Config.AUTO_SEARCH and Config.SEARCH_ENABLED
        and not Cues.IsSuppressed() then
        local cue = Cues.Best()
        if not Search.IsActive() then
            if cue then
                local sc, why = Cues.Threat(cue)
                if Search.Start(cue) then
                    Search.auto = true
                    AADLog.Info('cue: searching %s first, threat %.1f (%s)', cue.key, sc, why)
                    for _, o in ipairs(Cues.Ordered()) do
                        if o ~= cue then
                            local so, wo = Cues.Threat(o)
                            AADLog.Info('cue:   waiting %s threat %.1f (%s)%s', o.key, so, wo,
                                math.abs(o.az) > Config.CUE_START_AZ and ' outside gimbal' or '')
                        end
                    end
                end
            end
        elseif Search.auto and cue and (Search.phase == 'sweeping' or (Search.FarHold() and Director.CloserThanFound(cue))) and cue ~= Search.cue and Cues.MoreUrgent(cue, Search.cue,
            ((Search.Age() or 0) >= (Config.CUE_STALL_S or 20)) and (Config.CUE_STALL_MARGIN or 0.3) or (Config.CUE_SWITCH_MARGIN or 1.0)) then
            -- A more threatening cue (closer or higher contact) arrived while searching a weaker one: switch to it.
            AADLog.Info('cue: %s (threat %.1f) preempts %s (threat %.1f)%s', cue.key, (Cues.Threat(cue)), Search.cue.key, (Cues.Threat(Search.cue)),
                ((Search.Age() or 0) >= (Config.CUE_STALL_S or 20)) and string.format(' (that search has had nothing to show for %.0f s)', Search.Age() or 0) or '')
            Search.Stop('preempted')
            if Search.Start(cue) then Search.auto = true end
        elseif Search.auto and (Search.phase == 'sweeping' or Search.FarHold()) and Search.cue and (Search.Age() or 0) >= (Config.CUE_STALL_S or 20) then
            -- A search with nothing to show for CUE_STALL_S gives way to a CLOSER waiting cue, even one that scores lower:
            -- a far emitter that will not paint must not keep the radar from a bandit that is closing.
            local other = Cues.Best(Search.cue)
            if other then
                local ro, rs = Cues.RangeOf(other), Cues.RangeOf(Search.cue)
                if ro and (not rs or ro < rs) then
                    AADLog.Info('cue: %s (%.0f NM) takes over from %s (%s): that search has had nothing to show for %.0f s', other.key, ro,
                        Search.cue.key, rs and string.format('%.0f NM', rs) or 'range unknown', Search.Age() or 0)
                    Search.Stop('preempted')
                    if Search.Start(other) then Search.auto = true end
                end
            end
        end
    end
end

function Director:RunCursor()
    if self.mode == 'OFF' then return end
    Modes.Update()
end

function Director:RunUi()
    pcall(function() Wheel.SetMenuInfo(self:StatusText(), menu_path()) end)
end

function Director:Tick()
    local cockpit
    pcall(function()
        local j = GetJester()
        if j then cockpit = j:GetCockpit() end
    end)

    if not cockpit then
        self.current_cockpit = nil
        self.menu_settle_ticks = 0
        return
    end

    -- New cockpit (first spawn or respawn): register at once, then again after the settle delay.
    if self.current_cockpit ~= cockpit then
        self.current_cockpit = cockpit
        self.menu_settle_ticks = Config.MENU_SETTLE_TICKS
        self.last_run = {}
        BFM.Release()
        Engagement.Reset()
        Picture.Reset()
        Cues.Reset()
        Search.Reset()
        Modes.Reset()
        Iff.Reset()
        register_wheel_menu()
    end

    if self.menu_settle_ticks > 0 then
        self.menu_settle_ticks = self.menu_settle_ticks - 1
        if self.menu_settle_ticks == 0 then register_wheel_menu() end
    end

    local now = now_seconds()
    for _, sub in ipairs(self.subsystems) do
        local last = self.last_run[sub.name]
        if not last or now - last >= sub.period then
            self.last_run[sub.name] = now
            local ok, err = pcall(sub.fn, self)
            if not ok then AADLog.Info('subsystem %s error: %s', sub.name, tostring(err)) end
        end
    end
end

Director:Seal()
return Director
