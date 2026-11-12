-- Phase 2: fixes for stock radar behavior (next-bandit stepping, lock handling). The single-bandit and close-bandit
-- stock bugs are fixed by the separate mods in the fixes folder.
-- Each fix wraps the stock function through the patch registry. It is a pass-through when the
-- Director is OFF or when its Config flag is false, and it falls back to the stock function if
-- the replacement ever errors.
local Utilities = require('base.Utilities')
local State = require('radar.State')
local Api = require('radar.Api')
local Routines = require('radar.Routines')
local Radar = require('radar.Radar')
local Phases = require('radar.Phases')
local UserActions = require('radar.UserActions')
local Task = require('base.Task')
local Config = require 'aaplus.Config'
local AADLog = require 'aaplus.Log'
local Patches = require 'aaplus.Patches'

local Fixes = {}

local function pack(...) return { n = select('#', ...), ... } end

-- Wraps mod[fname]. impl(original, ...) is the replacement. The stock module outlives a CTRL+R, so the
-- installed wrapper is only a trampoline: it looks up the latest impl (and Config, Patches, log) in a
-- global each call. Loading this file again just refreshes that entry, so edits apply without a restart.
_G.AAD_IMPL = _G.AAD_IMPL or {}

local function wrap(mod, fname, flag, impl)
    mod.__aad_wrapped = mod.__aad_wrapped or {}
    -- Keyed by function AND flag: two different patches may wrap the same stock function (FindNextPhase).
    local key = fname .. ':' .. flag
    local id = tostring(mod) .. ':' .. key
    _G.AAD_IMPL[id] = { impl = impl, Config = Config, Patches = Patches, Log = AADLog, failed = false }
    if mod.__aad_wrapped[key] then return end
    local original = mod[fname]
    assert(type(original) == 'function', fname .. ' not found')
    mod[fname] = function(...)
        local e = rawget(_G, 'AAD_IMPL')[id]
        if not e or e.failed or not e.Patches.is_active() or not e.Config[flag] then
            return original(...)
        end
        local res = pack(pcall(e.impl, original, ...))
        if res[1] then return unpack(res, 2, res.n) end
        e.failed = true
        e.Log.Info('fix %s errored, reverting to stock: %s', fname, tostring(res[2]))
        return original(...)
    end
    mod.__aad_wrapped[key] = true
end

-- Bug 3: stock walks pairs() order, which is arbitrary. Step through the contacts left to right across the scope
-- instead, then back the other way, so the pilot always knows what the next press does (test 8 and 9, Oct 2026: a list
-- ordered by range reshuffled between presses and the stepping felt random). At an end of the sweep the press steps back.
local function step_now()
    local now = 0
    pcall(function()
        local raw = Utilities.GetTime().mission_time
        now = type(raw) == 'number' and raw or raw:ConvertTo(s).value
    end)
    return now
end

local function azimuth_deg(t)
    local a
    pcall(function() a = t.scan_azimuth:ConvertTo(deg).value end)
    return a or 0
end

-- Painted within STEP_MAX_AGE_S. A contact stock still lists but the radar has not painted for a while is not on the
-- scope: stepping onto it only gets the focus dropped again and the press repeats (test 9, Oct 2026).
local function fresh(target)
    local ok, age = pcall(function() return Utilities.GetTime().mission_time - target.last_hit_timestamp end)
    return ok and age < s(Config.STEP_MAX_AGE_S or 15)
end

-- Contacts the radar holds that stock has not identified as bandits yet (a contact our search found, whose call-out the
-- pilot's own stepping pre-empted: test 9, Oct 2026, the high contact at the far right was never reachable). They join the
-- sweep once they have STEP_UNID_MIN_HITS hits and are fresh.
local function unidentified_contacts(known)
    local out = {}
    for id, target in pairs(State.all_targets) do
        target = radar_targets[id] or target
        if type(id) == 'number' and not known[id] and target.identification ~= RadarTargetIdentification.FRIENDLY
            and (target.number_of_hits or 0) >= (Config.STEP_UNID_MIN_HITS or 3) and fresh(target) then
            out[#out + 1] = target
        end
    end
    return out
end

-- Everything the pilot can step to, ordered by azimuth (left first). The highlighted contact (ref) is always in it: a
-- contact just found or just focused can be missing from stock's lists for a few seconds, and without it the press has
-- no position in the sweep and jumps to an end (test 9, Oct 2026: contacts skipped).
local function step_list(with_unid, ref)
    local list, known = {}, {}
    for _, t in ipairs(State.bandits_by_priority_desc) do
        local tt = radar_targets[t.id] or t
        if State.all_targets[t.id] ~= nil and not known[t.id] and (fresh(tt) or (ref and t.id == ref.id)) then
            list[#list + 1] = tt
            known[t.id] = true
        end
    end
    if with_unid then
        for _, t in ipairs(unidentified_contacts(known)) do
            list[#list + 1] = t
            known[t.id] = true
        end
    end
    if ref and not known[ref.id] then list[#list + 1] = radar_targets[ref.id] or ref end
    local az = {}
    for _, t in ipairs(list) do az[t] = azimuth_deg(t) end
    table.sort(list, function(a, b)
        if az[a] ~= az[b] then return az[a] < az[b] end
        return tostring(a.id) < tostring(b.id)
    end)
    return list
end

-- The last step: from, to, dir (+1 = rightwards), reverse (the step turned the sweep round), time. Stock asks for the next
-- bandit twice per press with the same reference, so a repeat within a moment gives the same answer.
-- The direction is remembered without a time limit: it only changes when a press reaches an end of the sweep.
local last_step = nil
local step_dir = 1
local function step_plan(list, ref_id, now)
    local idx
    for i, t in ipairs(list) do
        if t.id == ref_id then idx = i break end
    end
    if not idx then return nil end
    local dir = step_dir
    local ni, reverse = idx + dir, false
    if ni < 1 or ni > #list then
        dir = -dir
        ni = idx + dir
        reverse = true
    end
    if ni < 1 or ni > #list then ni = idx end   -- only one contact
    return idx, ni, dir, reverse
end

local function same_press(ref_id, now)
    local ls = last_step
    return ls and ls.from == ref_id and now - ls.time < 1.5 and ls or nil
end

local function next_bandit(_, reference_target)
    local now = step_now()
    if not reference_target then
        local list = step_list(false)
        local head = list[1]   -- nothing highlighted yet: start at the left
        if head then
            step_dir = 1
            last_step = { from = 'none', to = head.id, dir = 1, reverse = false, time = now }
            return head
        end
        return nil
    end
    local list = step_list(true, reference_target)
    if #list == 0 then return nil end
    local ls = same_press(reference_target.id, now)
    if ls then
        for _, t in ipairs(list) do
            if t.id == ls.to then return t end
        end
    end
    local idx, ni, dir, reverse = step_plan(list, reference_target.id, now)
    local pick
    if idx then
        pick = list[ni]
    else
        -- the highlighted contact is not in the sweep (gone, or never was): carry on from the end the sweep is heading for
        dir, reverse = step_dir, false
        pick = dir > 0 and list[1] or list[#list]
    end
    step_dir = dir
    last_step = { from = reference_target.id, to = pick.id, dir = dir, reverse = reverse, time = now }
    local ids = {}
    for i, t in ipairs(list) do ids[i] = tostring(t.id) .. '@' .. string.format('%.0f', azimuth_deg(t)) end
    AADLog.Info('fix: next bandit %s (%s%s; sweep %s)', tostring(pick.id), dir > 0 and 'rightwards' or 'leftwards',
        reverse and ', turned round' or '', table.concat(ids, ' '))
    return pick
end

-- Bug 4 (behavior gap): when the player locks a target by hand (WSO HCU full action), Jester's radar
-- state has no target to lock, so his next scan phase sends an unlock click and he returns to search.
-- Stock only adopts a hand lock when Jester is reactivated (Radar.ResetToSituation). Do the same
-- whenever the radar is in track state with a skin track and Jester has no lock of his own.
local last_adopt = -100
local release_until = -100
local function adopt_player_lock(original, ...)
    local locking = State.target_to_lock ~= nil or State.target_currently_locked ~= nil
    local now = 0
    pcall(function()
        local raw = Utilities.GetTime().mission_time
        now = type(raw) == 'number' and raw or raw:ConvertTo(s).value
    end)
    if not locking and now > release_until and now - last_adopt > 2 and Api.IsInTrackState() and Api.HasSkinTrack() then
        last_adopt = now
        AADLog.Info('fix: adopting the lock the player made')
        Radar.ResetToSituation()
    end
    return original(...)
end

-- Behavior change: a commanded lock acts first and talks afterwards.
-- Stock LockTarget speaks "I am locking, left 25, 17 miles" (or a Roger) on the context press, and the
-- stable-lock call only comes after the lock. Here the opening call is dropped so the voice is free the
-- moment the lock lands, and the lock phase outranks Jester's equal-priority scan work.
local function fast_lock_target(original, task, target_id)
    -- Refuse a lock on a contact the radar has not painted for a while: the bearing is old and the lock would chase it.
    if Config.LOCK_STALE_S then
        local ok, stale = pcall(function()
            local t = radar_targets[target_id] or State.all_targets[target_id]
            if not t or not t.last_hit_timestamp then return false end
            return (Utilities.GetTime().mission_time - t.last_hit_timestamp) > s(Config.LOCK_STALE_S)
        end)
        if ok and stale then
            AADLog.Info('fix: lock %s refused, no radar hit for over %d s', tostring(target_id), Config.LOCK_STALE_S)
            task:CantDo()
            return
        end
    end
    local dummy = Task:new()          -- never queued, so whatever the stock function says on it is dropped
    original(dummy, target_id)
    if State.target_to_lock ~= nil then
        AADLog.Info('fix: lock %s started silently', tostring(target_id))
        return
    end
    return original(task, target_id)  -- refused: let the stock CantDo be spoken
end

local function fast_lock_phase(original, ...)
    local task, extra = original(...)
    if task and type(task.SetPriority) == 'function' then
        task:SetPriority(Config.LOCK_PRIORITY or 1.5)
    end
    return task, extra
end

-- Bug 5 (behavior gap): when a lock attempt is abandoned or a lock is lost, stock keeps the contact (and its old
-- bearing) as if nothing happened. Forget it, and keep it quiet for FORGET_QUIET_S if the radar finds it again.
-- A lock the pilot released on purpose (unlock, context press) is not forgotten.
local lock_prev = nil
local forgotten = {}
local function drop_target(id)
    for _, name in ipairs({ 'all_targets', 'processed_targets', 'identified_targets', 'unidentified_new_targets' }) do
        local t = State[name]
        if type(t) == 'table' then t[id] = nil end
    end
    for _, name in ipairs({ 'bandits_by_priority_desc', 'not_bandits_by_priority_desc' }) do
        local l = State[name]
        if type(l) == 'table' then
            for i = #l, 1, -1 do
                if l[i] and l[i].id == id then table.remove(l, i) end
            end
        end
    end
end

local function forget_lost(original, ...)
    local res = pack(original(...))
    pcall(function()
        local now = 0
        local raw = Utilities.GetTime().mission_time
        now = type(raw) == 'number' and raw or raw:ConvertTo(s).value
        local cur = State.target_currently_locked or State.target_to_lock
        if not State.is_active then
            lock_prev = nil
        elseif cur then
            lock_prev = cur.id
        elseif lock_prev then
            local id = lock_prev
            lock_prev = nil
            drop_target(id)
            forgotten[id] = now + (Config.FORGET_QUIET_S or 20)
            AADLog.Info('fix: lock on %s lost or abandoned, contact forgotten', tostring(id))
        end
        for id, untilt in pairs(forgotten) do
            if now > untilt then
                forgotten[id] = nil
            else
                local t = State.all_targets[id]
                if t and State.processed_targets and State.processed_targets[id] == nil then
                    State.processed_targets[id] = t   -- found again: no new-contact call
                end
            end
        end
    end)
    return unpack(res, 1, res.n)
end

local function pilot_released(original, ...)
    lock_prev = nil
    return original(...)
end

-- A context press while Jester is in the lock state (double = back to scan, long = unlock but keep focus) clears his
-- lock state but the radar is still tracking for a moment: without a pause adopt_player_lock would take that track
-- for a lock the player made and keep it. Hold the adoption off while the unlock goes through.
local function release_pause(original, task, action_type)
    local now = 0
    pcall(function()
        local raw = Utilities.GetTime().mission_time
        now = type(raw) == 'number' and raw or raw:ConvertTo(s).value
    end)
    release_until = now + (Config.RELEASE_HOLD_S or 4)
    lock_prev = nil
    AADLog.Info('fix: context press %s while locked, lock adoption paused %ds', tostring(action_type), Config.RELEASE_HOLD_S or 4)
    return original(task, action_type)
end

Fixes.Wrap = wrap

function Fixes.Install()
    Patches.Install('fix_next_bandit', function()
        wrap(Api, 'GetNextBanditOrNil', 'FIX_NEXT_BANDIT', next_bandit)
    end)
    Patches.Install('fix_player_lock', function()
        wrap(Radar, 'FindNextPhase', 'ADOPT_PLAYER_LOCK', adopt_player_lock)
        wrap(UserActions, 'HandleContextActionLock', 'ADOPT_PLAYER_LOCK', release_pause)
    end)
    Patches.Install('fix_forget_lost', function()
        wrap(Radar, 'Tick', 'FORGET_LOST_LOCK', forget_lost)
        wrap(Api, 'UnlockTarget', 'FORGET_LOST_LOCK', pilot_released)
    end)
    Patches.Install('fix_fast_lock', function()
        wrap(UserActions, 'LockTarget', 'FAST_LOCK', fast_lock_target)
        wrap(Phases, 'HandleTargetLocking', 'FAST_LOCK', fast_lock_phase)
    end)
end

return Fixes
