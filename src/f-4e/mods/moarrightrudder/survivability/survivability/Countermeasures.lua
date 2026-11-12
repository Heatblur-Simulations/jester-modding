-- Jester Survivability: countermeasures and missile defense (additive).
--   * Eyes:     every missile inside AIR.visible_nm is seen at once (stock: a random roll).
--   * Shooter:  a hostile aircraft behind the missile on its track is the shooter (a fighter launch); none = a ground launch (SAM).
--   * Close fighter launch (time to impact under AIR.long_tti_s): the program starts at once, from any direction.
--   * Long-range fighter launch Jester watches: warning call at once, "missile missile missile" at AIR.warn_tti_s, program at
--     AIR.dispense_tti_s, skipped while the missile is in the rear sector (you turned away).
--   * Program:  launch within AIR.ir_range_nm with no RWR emitter at the shooter's bearing = flares only; otherwise chaff and flares.
--               Ground launches (SAMs) = chaff, or both when first seen inside AIR.ir_range_nm; timed by SAM.* time to impact.
--   * Feed:     optional (Config.FEED): SurvFeed.lua in DCS's Export environment lists missiles in flight, including the semi-active
--               radar ones the sim never gives Jester; handled by the same rules, as a missile with no type.
--   * Singer:   a ground launch the RWR does not report (SA-6 and others; the ALR-46 flags only SA-2, SA-3, SA-15 and a few) gets
--               "singer <clock>, <type>" when the missile is first seen. DEPENDS ON THE OBJECT FEED for an early call: with the feed
--               the call comes at the launch (the feed lists the missile from the rail); without it (server blocks object export,
--               SurvFeed.lua not installed) the call comes only when Jester's own eyes first see the missile (inside SAM.visible_nm,
--               often a dozen seconds later) and not at all for a missile never seen. See Config.SINGER.
--   * Presses:  the dispense button is pressed directly, one knob/button change per tick (see PROGRAMS).
-- Settings: survivability\Config.lua. Timing of every step is written to survivability.log ("CM:" lines).
local Task = require('base.Task')
local Utilities = require('base.Utilities')
local Tempo = require('survivability.Config')

local function contains(list, name)
    for _, frag in ipairs(list) do
        if string.find(name, frag, 1, true) then return true end
    end
    return false
end

local function classify(missile)
    if not missile then return 'unknown', 'no missile' end
    local name = ''
    pcall(function() name = string.lower(tostring(missile.type or '')) end)
    if name == '' then return 'unknown', 'no type' end
    if contains(Tempo.IR_TYPES, name) then return 'ir', name end
    if contains(Tempo.RADAR_TYPES, name) then return 'radar', name end
    return 'unknown', name
end

local function is_sam(missile)
    local name = ''
    pcall(function() name = string.lower(tostring(missile.type or '')) end)
    return name ~= '' and contains(Tempo.SAM_TYPES, name)
end

local HOURS = { 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve' }

-- Spoken heads-up: HI-intensity "missile" call plus the clock position.
local function say_missile_now(hour)
    pcall(function()
        local Task = require('base.Task')
        local task = Task:new()
        local h = HOURS[tonumber(hour)]
        if h then task:Say('spotting/missileHI', 'spotting/' .. h .. 'oclock') else task:Say('spotting/missileHI') end
        task:SetPriority(Tempo.PRIORITY.missile)
        GetJester():AddTask(task)
    end)
end

-- Defined below (it needs the clock and the log): true when a call of this kind was just made for the same direction.
local call_coalesced

-- Initial call for a long-range shot Jester watches: the plain "missile, <clock>" (Config.PHRASE_LONG_LAUNCH).
local function say_launch_now(hour)
    if call_coalesced and call_coalesced('launch', hour) then return end
    pcall(function()
        local task = Task:new()
        local h = HOURS[tonumber(hour)]
        if h then task:Say(Tempo.PHRASE_LONG_LAUNCH, 'spotting/' .. h .. 'oclock') else task:Say(Tempo.PHRASE_LONG_LAUNCH) end
        task:SetPriority(Tempo.PRIORITY.missile)
        GetJester():AddTask(task)
    end)
end

-- Heads-up just before the dump: always Jester's "missile missile missile" line (one of Config.PHRASES_HEADSUP, picked at random),
-- never his single "missile", so it cannot be mistaken for the initial call.
local function say_headsup_now(hour)
    if call_coalesced and call_coalesced('headsup', hour) then return end
    pcall(function()
        local list = Tempo.PHRASES_HEADSUP
        local phrase = list[math.random(#list)]
        local task = Task:new()
        local h = HOURS[tonumber(hour)]
        if h then task:Say(phrase, 'spotting/' .. h .. 'oclock') else task:Say(phrase) end
        task:SetPriority(Tempo.PRIORITY.missile)
        GetJester():AddTask(task)
    end)
end

local function now_seconds()
    local t = 0
    pcall(function()
        local raw = Utilities.GetTime().mission_time
        t = type(raw) == 'number' and raw or raw:ConvertTo(s).value
    end)
    return t
end

-- Time to notice a missile that has come inside visibility range: REACT.far_s at REACT.far_nm, falling in a straight line to REACT.near_s
-- at REACT.near_nm and closer (a faint plume at the edge of sight takes a while to find; a close missile is seen at once).
local function react_delay(range_nm, sam)
    local R = Tempo and ((sam and Tempo.REACT_SAM) or Tempo.REACT)   -- SAM plumes have their own, shorter curve
    if not R then return 0 end
    if range_nm >= R.far_nm then return R.far_s end
    if range_nm <= R.near_nm then return R.near_s end
    return R.near_s + (R.far_s - R.near_s) * (range_nm - R.near_nm) / (R.far_nm - R.near_nm)
end

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    pcall(function() require('survivability.Log').Info(string.format('CM: t=%.2f %s', now_seconds(), msg)) end)
end

-- Range trace for the plume-visibility test: once a second, each tracked missile's range, closing speed and bearing, stamped with
-- mission time (the "CM: t=" prefix). Match the time you first saw the plume to these lines.
local trace_count = 0
local function trace(tr, src, range_m, closing_mps, az)
    local now = now_seconds()
    if tr.trace_t and now - tr.trace_t < 1 then return end
    tr.trace_t = now
    if not tr.trace_id then trace_count = trace_count + 1 tr.trace_id = trace_count end
    log('trace %s#%d: range=%.1f NM closing=%s az=%s %s', src, tr.trace_id, (range_m or 0) / 1852,
        closing_mps and string.format('%.0f m/s', closing_mps) or '-', az and string.format('%.0f', az) or '-', tr.sam and 'SAM' or 'air')
end

-- One "missile missile missile" (or one plain "missile") per direction, not one per missile (test flight, 13 Oct 2026: a salvo of two
-- SA-6 missiles, each also reported by the feed and then by the eyes, gave up to four heads-up calls within six seconds). A call of the
-- same kind for the same clock (plus or minus one hour) within CALLS.gap_s of the last one made is not repeated. A different direction
-- is always called. Dispensing is not affected, only the speech.
local last_call = { launch = { t = -999 }, headsup = { t = -999 } }
call_coalesced = function(kind, hour)
    local rec = last_call[kind]
    local h = tonumber(hour)
    local now = now_seconds()
    local gap = (Tempo.CALLS and Tempo.CALLS.gap_s) or 8
    if rec.hour and h and now - rec.t < gap then
        local d = math.abs(h - rec.hour)
        if math.min(d, 12 - d) <= 1 then
            log('%s call for clock %s skipped, one was made for clock %d %.1f s ago', kind, tostring(hour), rec.hour, now - rec.t)
            return true
        end
    end
    rec.t, rec.hour = now, h
    return false
end

-- ---------------------------------------------------------------------------------------------
-- Dispense engine: direct button presses on a timeline, run from the behavior's Tick.
-- ---------------------------------------------------------------------------------------------
local tracked = {}             -- per missile contact: first sighting, bursts so far
local events = {}              -- { t =, fn = }, run in time order
local busy_until = 0
local saved = nil              -- the WSO control unit's chaff/flare mode knobs as they were before a program
local restore_at = nil
local last_burst_t = -999
local release_state = 'OFF'
local last_allowed = nil
local cms_probe = nil

local function manip(name)
    return GetJester():GetCockpit():GetManipulator(name)
end

local function set_mode(name, target)
    local m = manip(name)
    if m:GetState() ~= target then m:SetState(target) end
end

-- btn = true marks an event that changes the knobs or the button. At most one such event runs per Jester tick:
-- a press and its release in the same tick would never reach the cockpit as a press.
local function add_event(t, fn, btn)
    table.insert(events, { t = t, fn = fn, btn = btn })
end

local function allowed()
    local ok, res = pcall(function() return GetJester().memory:GetJesterCountermeasuresDispensingAllowed() end)
    if ok and res ~= nil then return res end
    return true
end

-- kind: 'flare' (chaff off), 'chaff' (flares off) or 'both'. The knobs go to Config.CHAFF_MODE / FLARE_MODE.
local function burst(kind, why)
    if not allowed() then return false end
    local program = Tempo.PROGRAMS[kind]
    local now = now_seconds()
    local ok, err = pcall(function()
        if not saved then
            saved = { chaff = manip('Chaff Mode'):GetState(), flare = manip('Flare Mode'):GetState() }
        end
        local t = math.max(now, busy_until)
        local want_chaff = (kind == 'flare') and 'OFF' or Tempo.CHAFF_MODE
        local want_flare = (kind == 'chaff') and 'OFF' or Tempo.FLARE_MODE
        add_event(t, function()
            set_mode('Chaff Mode', want_chaff)
            set_mode('Flare Mode', want_flare)
            log('modes set: chaff=%s flare=%s (knobs were chaff=%s flare=%s)', tostring(manip('Chaff Mode'):GetState()),
                tostring(manip('Flare Mode'):GetState()), tostring(saved and saved.chaff), tostring(saved and saved.flare))
        end, true)
        t = t + Tempo.MODE_GAP_S
        for i = 1, program.count do
            local press_t = t
            local hold_i = (program.holds and program.holds[i]) or program.hold
            add_event(press_t, function()
                local m = manip('Dispense Button')
                local cur = m:GetState()
                if cur ~= 'ON' then release_state = cur end
                m:SetState('ON')
                if i == 1 then log('first press (+%.2f s after request), hold %.2f s', now_seconds() - now, hold_i) else log('press %d, hold %.2f s (state was %s)', i, hold_i, tostring(cur)) end
            end, true)
            add_event(press_t + hold_i, function() manip('Dispense Button'):SetState(release_state) end, true)
            t = t + program.interval
        end
        busy_until = t
        restore_at = t + 0.4
        table.sort(events, function(a, b) return a.t < b.t end)
    end)
    if not ok then log('burst failed: %s', tostring(err)) return false end
    last_burst_t = now
    log('%s burst: %d x %.2f s (%s)', kind, program.count, program.interval, tostring(why))
    return true
end

local function pump()
    local now = now_seconds()
    -- Log Jester's own 'dispensing allowed' setting (the wheel's chaff/flare handoff) whenever it changes, and once at the start.
    local okp, cur = pcall(function() return GetJester().memory:GetJesterCountermeasuresDispensingAllowed() end)
    if okp and cur ~= last_allowed then
        log('Jester dispensing allowed: %s (was %s)', tostring(cur), tostring(last_allowed))
        last_allowed = cur
    end
    -- Probe for the CMS menu handoff: list every Jester memory getter with 'ountermeasure' in its name, then log any whose value changes.
    if cms_probe == nil then
        cms_probe = {}
        pcall(function()
            local mem = GetJester().memory
            local names = {}
            local function scan(t)
                if type(t) ~= 'table' then return end
                for k in pairs(t) do if type(k) == 'string' and k:find('ountermeasure') then names[k] = true end end
            end
            local mt = getmetatable(mem)
            if mt then scan(mt); if type(mt.__index) == 'table' then scan(mt.__index) end end
            scan(mem)
            local list = {}
            for k in pairs(names) do list[#list + 1] = k end
            table.sort(list)
            log('memory countermeasure members: %s', #list > 0 and table.concat(list, ', ') or '(none found)')
            for _, k in ipairs(list) do if k:sub(1, 3) == 'Get' then cms_probe[k] = {} end end
        end)
    end
    for k, rec in pairs(cms_probe) do
        local okg, v = pcall(function() local m = GetJester().memory; return m[k](m) end)
        local sv = okg and tostring(v) or 'error'
        if sv ~= rec.v then log('memory %s: %s (was %s)', k, sv, tostring(rec.v)); rec.v = sv end
    end
    local changed = false
    while events[1] and events[1].t <= now do
        if events[1].btn and changed then break end        -- one knob/button change per tick; the rest wait
        local e = table.remove(events, 1)
        local ok, err = pcall(e.fn)
        if not ok then log('event failed: %s', tostring(err)) end
        if e.btn then changed = true end
    end
    if saved and #events == 0 and restore_at and now >= restore_at then
        pcall(function()
            set_mode('Chaff Mode', saved.chaff)
            set_mode('Flare Mode', saved.flare)
        end)
        saved, restore_at = nil, nil
    end
end

-- ---------------------------------------------------------------------------------------------
-- RWR launch watch.
-- ---------------------------------------------------------------------------------------------
local rwr_watch = {}

local function sam_tracked_recently(now)
    for _, tr in pairs(tracked) do
        if tr.sam and tr.seen and now - tr.seen < 2 then return true end
    end
    return false
end

local rwr_launch_t = -999   -- last time any RWR contact showed a launch
local rwr_act = {}          -- last logged activity per RWR emitter id
local rwr_audio_on, rwr_audio_t, rwr_audio_read = false, -999, false
local function clock_of(az)
    local h = math.floor(((az % 360) + 15) / 30) % 12
    return h == 0 and 12 or h
end
local rwr_missile = {}      -- RWR missile symbols already answered, by emitter id
-- One answer to an active missile warning (the ALR-46 missile symbol, or its launch tone): "missile missile missile" and one chaff program.
-- Shared by both cues, so a symbol and a tone for the same missile are answered once (one answer per 10 s).
local function answer_active_missile(hour, src)
    local now = now_seconds()
    if now - rwr_audio_t <= 10 then return end
    rwr_audio_t = now
    if Tempo.RWR.warn then say_headsup_now(hour) end
    for _, tr in pairs(tracked) do
        if tr.az and not tr.sam and not tr.ignore and tr.seen and now - tr.seen < 2 then tr.warned = true end
    end
    -- The missile this warning is about is the nearest one the feed tracks: it has been answered, so its own program (which would come
    -- later, at about 3 s to impact for a coasting missile) is not dispensed again.
    local near
    for _, tr in pairs(tracked) do
        if tr.feed and tr.az and not tr.ignore and not tr.sam and tr.rng and tr.seen and now - tr.seen < 2 and (not near or tr.rng < near.rng) then near = tr end
    end
    if near then near.bursts = math.max(near.bursts or 0, 1) near.sighted = true near.warned = true end
    if now - last_burst_t > 6 then burst('chaff', string.format('RWR active missile warning, hour %d from %s', hour, src)) end
    log('RWR active missile: heads-up for hour %d (%s)', hour, src)
end

local function rwr_scan()
    local list = rawget(_G, 'rwr_contacts')
    if type(list) ~= 'table' then return end
    local now = now_seconds()
    local present_missiles = {}
    -- ALR-46 launch tone. An active missile such as the AIM-54 raises it when its seeker goes active (the manual's "tracking" warning),
    -- and fired from TWS there may be no aircraft emitter on the scope, so the tone itself is watched. It carries no bearing: the clock
    -- comes from the missile track the feed or eyes already hold, else from an aircraft emitter on the RWR, else 12.
    local okp, raw = pcall(function() return GetProperty('/RWR AN_ALR_46_Audio', 'Launch Audio Playing').value end)
    if not rwr_audio_read then
        rwr_audio_read = true
        log('RWR launch audio property reads: ok=%s type=%s value=%s', tostring(okp), type(raw), tostring(raw))
    end
    local playing = false
    if okp and raw ~= nil then
        local n = tonumber(raw)
        playing = (raw == true) or (n ~= nil and n > 0.5)
    end
    if playing ~= rwr_audio_on then
        log('RWR launch audio: %s', playing and 'ON' or 'off')
        if playing then
            local hour, src = nil, nil
            local best_seen = -1
            for _, tr in pairs(tracked) do
                if tr.az and not tr.sam and not tr.ignore and tr.seen and now - tr.seen < 2 and tr.seen > best_seen then
                    best_seen = tr.seen hour, src = clock_of(tr.az), 'launch tone, missile track'
                end
            end
            if not hour then
                for _, c in ipairs(list) do
                    if c.category_1 == 'air' and c.hour and not c.known_friendly then hour, src = tonumber(c.hour), 'launch tone, RWR air emitter' break end
                end
            end
            if not hour then hour, src = 12, 'launch tone, default' end
            answer_active_missile(hour, src)
        end
        rwr_audio_on = playing
    end
    for _, c in ipairs(list) do
        -- Every change of an emitter's activity is logged (to learn what the ALR-46 shows for active missiles such as the AIM-54).
        if c.id ~= nil and rwr_act[c.id] ~= c.activity then
            log('RWR activity: id=%s %s -> %s category=%s/%s type=%s/%s hour=%s range=%s', tostring(c.id), tostring(rwr_act[c.id]), tostring(c.activity),
                tostring(c.category_1), tostring(c.category_2), tostring(c.type_1), tostring(c.type_2), tostring(c.hour), tostring(c.range))
            rwr_act[c.id] = c.activity
        end
        -- A missile symbol on the scope (the manual's "correlated" / "uncorrelated missile": an active-seeker missile that has gone active).
        -- The strings the sim uses are not known yet, so any field mentioning "missile" counts; the first sighting logs every field.
        if c.id ~= nil and not c.known_friendly then
            local blob = string.lower(table.concat({ tostring(c.category_1), tostring(c.category_2), tostring(c.type_1), tostring(c.type_2),
                tostring(c.symbol_1), tostring(c.symbol_2), tostring(c.subcategory_1), tostring(c.subcategory_2) }, ' '))
            if blob:find('missile', 1, true) then
                present_missiles[c.id] = true
                if not rwr_missile[c.id] then
                    rwr_missile[c.id] = now
                    log('RWR missile symbol: id=%s hour=%s range=%s activity=%s fields=%s', tostring(c.id), tostring(c.hour), tostring(c.range), tostring(c.activity), blob)
                    answer_active_missile(tonumber(c.hour) or 12, 'RWR missile symbol')
                end
            end
        end
        -- An aircraft emitter showing a launch is an active missile heading for you (AIM-54, AIM-120, R-77 ...): the missile is not
        -- visible yet, so answer at once with the heads-up and one chaff program, unless a missile track has just dispensed.
        if c.activity == 'launch' and c.category_1 == 'air' and not c.known_friendly then
            local w = rwr_watch[c.id]
            if not w then w = { first = now, bursts = 0, last = -999 } rwr_watch[c.id] = w end
            w.seen = now
            if not w.air_reacted then
                w.air_reacted = true
                if Tempo.RWR.warn then say_headsup_now(c.hour) end
                if now - last_burst_t > 6 and burst('chaff', string.format('RWR active missile %s, hour %s', tostring(c.type_1), tostring(c.hour))) then
                    w.bursts = w.bursts + 1
                    w.last = now
                end
                log('RWR active-missile launch: %s/%s hour=%s range=%s', tostring(c.type_1), tostring(c.type_2), tostring(c.hour), tostring(c.range))
            end
        elseif c.activity == 'launch' then
            rwr_launch_t = now
            local id = c.id
            local w = rwr_watch[id]
            if not w then
                w = { first = now, bursts = 0, last = -999 }
                rwr_watch[id] = w
                log('RWR launch: id=%s category=%s/%s type=%s/%s hour=%s range=%s friendly=%s', tostring(id), tostring(c.category_1),
                    tostring(c.category_2), tostring(c.type_1), tostring(c.type_2), tostring(c.hour), tostring(c.range), tostring(c.known_friendly))
            end
            w.seen = now
            if c.category_1 == 'surface' and not c.known_friendly and not sam_tracked_recently(now)
                and now - w.first >= Tempo.RWR.first_s and now - w.last >= Tempo.RWR.repeat_s and w.bursts < Tempo.RWR.max_bursts then
                if Tempo.RWR.warn then say_headsup_now(c.hour) end
                if burst('chaff', string.format('RWR SAM launch %s, burst %d, %.0f s since launch', tostring(c.type_1), w.bursts + 1, now - w.first)) then
                    w.bursts = w.bursts + 1
                    w.last = now
                end
            end
        end
    end
    for id in pairs(rwr_missile) do
        if not present_missiles[id] then rwr_missile[id] = nil end
    end
    for id, w in pairs(rwr_watch) do
        if w.seen and now - w.seen > 2 then rwr_watch[id] = nil end
    end
end

-- Singer-style call for ground launches the RWR does not report (13 Oct 2026). The ALR-46 gives a launch indication only for a few
-- systems (SA-2, SA-3, SA-15, NASAMS and some missiles; not SA-5, SA-6, SA-8, SA-10, SA-11, Hawk or Patriot), so stock's "singer"
-- call never comes for the rest. The first sighting of a ground-launched radar missile (object feed or eyes) now gets the same
-- call at the clock position the missile was first seen: "singer <clock>", or "and singer <clock>" when it follows another within
-- SINGER.and_s. Skipped while the RWR shows a launch itself (stock's call covers it), for IR missiles (MANPADS), and when a call
-- was made for the same site (same clock +-1) in the last SINGER.same_site_s. Stock's singer (RWR) goes through the same record,
-- so the two never say the same launch twice.
local last_gcall = { t = -999, hour = nil }

local function recent_call_near(h, now)
    if not last_gcall.hour then return false end
    if now - last_gcall.t >= Tempo.SINGER.same_site_s then return false end
    local d = math.abs(h - last_gcall.hour)
    return math.min(d, 12 - d) <= 1
end

-- The site's type, as the pilot hears it ("SA-6"): the voice phrase of the RWR surface emitter at (or next to) that clock, else a
-- lookup by the missile's name (extend Config.SINGER.types as more names show up in the log). nil = the call has no type.
local function singer_type(h, missile_name)
    local best, best_d, best_r
    pcall(function()
        for _, c in ipairs(rawget(_G, 'rwr_contacts') or {}) do
            local ch = tonumber(c.hour)
            if c.category_1 == 'surface' and not c.known_friendly and ch and type(c.type_1) == 'string' then
                local d = math.abs(ch - h)
                d = math.min(d, 12 - d)
                local r = tonumber(c.range) or 1
                if d <= 1 and (not best_d or d < best_d or (d == best_d and r < best_r)) then
                    best, best_d, best_r = c.type_1, d, r
                end
            end
        end
    end)
    if best then return best, 'RWR emitter' end
    local key = missile_name and string.lower(tostring(missile_name))
    local phrase = key and Tempo.SINGER.types[key]
    if phrase then return phrase, 'missile name' end
    return nil, 'unknown'
end

-- "Singer <clock>, <type>" (the clip carries the clock), or "and a singer" + clock + type when it follows another call at once.
local function say_singer(h, now, type_phrase)
    local subsequent = last_gcall.hour ~= nil and now - last_gcall.t <= Tempo.SINGER.and_s
    pcall(function()
        local task = Task:new()
        local hs = HOURS[h]
        if subsequent then
            task:Say('phrases/andasinger')    -- ("andsinger", which stock uses, has no voice file)
            task:Say('spotting/' .. hs .. 'oclock')
        else
            task:Say('phrases/singer' .. hs .. 'oclock')
        end
        if type_phrase then task:Say(type_phrase) end
        task:SetPriority(Tempo.PRIORITY.launch)
        GetJester():AddTask(task)
    end)
    last_gcall.t, last_gcall.hour = now, h
    return subsequent
end

local function ground_launch_call(hour, source, missile_name)
    local now = now_seconds()
    local h = tonumber(hour)
    if not h or not HOURS[h] then return end
    if now - rwr_launch_t < Tempo.SINGER.rwr_cover_s then
        log('ground launch call (%s): the RWR shows a launch, stock singer covers it', source)
        return
    end
    if recent_call_near(h, now) then
        log('ground launch call (%s): clock %d skipped, a call was made for this site %.0f s ago', source, h, now - last_gcall.t)
        return
    end
    local type_phrase, type_from = singer_type(h, missile_name)
    local subsequent = say_singer(h, now, type_phrase)
    log('ground launch call (%s): %ssinger %d o\'clock, type %s (%s), missile %s', source, subsequent and 'and a ' or '', h,
        tostring(type_phrase), type_from, tostring(missile_name))
end

-- ---------------------------------------------------------------------------------------------
-- Missile geometry.
-- ---------------------------------------------------------------------------------------------
-- Returns closing (bool), miss distance (m), range (m), closing speed (m/s).
local function geometry(missile)
    local own_ned = GetJester().awareness:GetObservation('velocity_ned') or Vector(coords.NED, 0, 0, 0, mps)
    local rel = missile.velocity_body - TransformToBody(own_ned)
    local p = missile.position_body
    local px, py, pz = p.x.value, p.y.value, p.z.value
    local vx, vy, vz = rel.x.value, rel.y.value, rel.z.value
    local range = math.sqrt(px * px + py * py + pz * pz)
    local v2 = vx * vx + vy * vy + vz * vz
    if v2 < 1 then return false, range, range, 0 end
    local dot = px * vx + py * vy + pz * vz
    if dot >= 0 then return false, range, range, 0 end
    local tt = -dot / v2
    local mx, my, mz = px + vx * tt, py + vy * tt, pz + vz * tt
    return true, math.sqrt(mx * mx + my * my + mz * mz), range, (-dot / math.max(range, 1))
end


-- ---------------------------------------------------------------------------------------------
-- Shooter correlation. A missile starts at its launcher, so a hostile aircraft sitting behind the missile on its
-- track line is the shooter; if there is none, the launch was from the ground (a SAM).
-- ---------------------------------------------------------------------------------------------
local function azimuth_deg(contact)
    local a = 0
    pcall(function() a = contact.polar_body.azimuth:ConvertTo(deg).value end)
    a = a % 360
    return a
end

-- Position of a contact in body axes (m): position_body when it has one, else rebuilt from its polar position.
-- The polar conversion's signs are matched against a missile's own position_body (see calibrate_polar).
local function polar_xyz(cc, sy, sz)
    local pb = cc.polar_body
    local L = pb.length:ConvertTo(NM).value * 1852
    local az = math.rad(pb.azimuth:ConvertTo(deg).value)
    local el = math.rad(pb.elevation:ConvertTo(deg).value)
    return L * math.cos(el) * math.cos(az), sy * L * math.cos(el) * math.sin(az), sz * L * math.sin(el)
end

local function calibrate_polar(cc)
    if rawget(_G, 'CMT_CONV') then return end
    pcall(function()
        local p = cc.position_body
        local px, py, pz = p.x.value, p.y.value, p.z.value
        local best, best_e
        for _, sy in ipairs({ 1, -1 }) do
            for _, sz in ipairs({ 1, -1 }) do
                local x, y, z = polar_xyz(cc, sy, sz)
                local e = math.abs(x - px) + math.abs(y - py) + math.abs(z - pz)
                if not best_e or e < best_e then best, best_e = { sy = sy, sz = sz }, e end
            end
        end
        if best and best_e < 0.05 * math.sqrt(px * px + py * py + pz * pz) + 5 then _G.CMT_CONV = best end
    end)
end

local function pos_of(cc)
    local ok, x, y, z = pcall(function() local p = cc.position_body return p.x.value, p.y.value, p.z.value end)
    if ok and type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then return x, y, z, 'pos' end
    local cv = rawget(_G, 'CMT_CONV') or { sy = 1, sz = -1 }
    local ok2, x2, y2, z2 = pcall(polar_xyz, cc, cv.sy, cv.sz)
    if ok2 and type(x2) == 'number' then return x2, y2, z2, 'polar' end
    return nil
end

-- threats is optional (defaults to the awareness list). Returns the shooter contact, how far the missile has flown past it (m),
-- and a short description of every aircraft tried (for the log).
function Tempo.FindShooter(contact, threats)
    local best, best_lat, best_along
    local dbg = {}
    local okf, errf = pcall(function()
        local c = Tempo.AIR
        calibrate_polar(contact)
        local mx, my, mz = pos_of(contact)
        local mv = contact.velocity_body
        local vx, vy, vz = mv.x.value, mv.y.value, mv.z.value
        local vl = math.sqrt(vx * vx + vy * vy + vz * vz)
        if not mx then dbg[#dbg + 1] = 'no missile position' return end
        if vl < 20 then dbg[#dbg + 1] = string.format('missile speed %.0f', vl) return end
        vx, vy, vz = vx / vl, vy / vl, vz / vl
        local list = threats or GetJester().awareness:GetAirThreats()
        dbg[#dbg + 1] = string.format('%d threats', #list)
        for i, a in ipairs(list) do
            local ax, ay, az, src = pos_of(a)
            if not ax then
                dbg[#dbg + 1] = string.format('#%d no position', i)
            else
                local rx, ry, rz = mx - ax, my - ay, mz - az
                local along = rx * vx + ry * vy + rz * vz
                local lx, ly, lz = rx - along * vx, ry - along * vy, rz - along * vz
                local lat = math.sqrt(lx * lx + ly * ly + lz * lz)
                if i <= 4 then dbg[#dbg + 1] = string.format('#%d %s along=%.0f lat=%.0f', i, src, along, lat) end
                if along > -c.shooter_behind_m and lat < c.shooter_lateral_m + c.shooter_lateral_frac * math.max(along, 0) then
                    if not best_lat or lat < best_lat then best, best_lat, best_along = a, lat, along end
                end
            end
        end
    end)
    if not okf then dbg[#dbg + 1] = 'error: ' .. tostring(errf) end
    return best, best_along, table.concat(dbg, '; ')
end

-- Is an airborne RWR emitter showing near this bearing (degrees from the nose)? (The shooter's radar is on.)
local function rwr_emitter_near(az_deg)
    local list = rawget(_G, 'rwr_contacts')
    if type(list) ~= 'table' then return false end
    local hour = math.floor(az_deg / 30 + 0.5) % 12
    if hour == 0 then hour = 12 end
    for _, c in ipairs(list) do
        if type(c) == 'table' and c.category_1 == 'airborne' and not c.known_friendly then
            local h = tonumber(c.hour)
            if h then
                local d = math.abs(h - hour)
                d = math.min(d, 12 - d)
                if d <= Tempo.AIR.rwr_hour_tol then return true end
            end
        end
    end
    return false
end

local function in_rear_sector(contact)
    local c = Tempo.AIR
    if not c.rear_skip then return false end
    local a = azimuth_deg(contact)
    return a > c.rear_from_deg and a < c.rear_to_deg
end


-- ---------------------------------------------------------------------------------------------
-- Export feed: missiles listed by SurvFeed.lua (DCS Export environment). Covers what the sim contact list lacks (radar missiles).
-- Same rules as the contact path: close or unwatched = at once, long-range = by time to impact, rear sector skipped, one burst.
-- ---------------------------------------------------------------------------------------------
local feed_last_poll, feed_hdr_t, feed_hdr_changed = -999, nil, -999
local feed_alive, feed_names = nil, {}
local feed_err = false
local feed_ticking = false
local feed_live_at, feed_status_at

local function feed_read(F)
    local f = io.open(F.path, 'r')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    if not text or not text:find('END', 1, true) then return nil end
    return text
end

local function hour_of(az)
    local h = math.floor(((az % 360) + 15) / 30) % 12
    return h == 0 and 12 or h
end

local function feed_scan()
    local F = Tempo.FEED
    if not F or not F.enabled then return end
    local now = now_seconds()
    if now - feed_last_poll < F.poll_s then return end
    feed_last_poll = now
    local text = feed_read(F)
    local alive = false
    local missiles = {}
    if text then
        local t = tonumber(text:match('V1 t=([%d%.%-]+)'))
        if t and t ~= feed_hdr_t then
            if feed_hdr_t ~= nil then feed_ticking = true end      -- the clock moved while we watched: this session's feeder is running
            feed_hdr_t, feed_hdr_changed = t, now
        end
        -- a file left over from an earlier session (clock never moves) is never trusted
        alive = feed_ticking and now - feed_hdr_changed < F.stale_s
        if alive then
            local hdr = text:match('^[^\n]*') or ''
            if feed_alive ~= true then log('feed live: %s', hdr) end
            -- Status line 5 s after the feed goes live, then once a minute: shows whether the server hands over any objects at all.
            if feed_alive ~= true then feed_live_at, feed_status_at = now, now + 5 end
            if feed_status_at and now >= feed_status_at then
                feed_status_at = now + 60
                local obj = tonumber(hdr:match('obj=(%d+)')) or 0
                local ac = tonumber((hdr:match('L1=(%S+)') or ''):match('1:(%d+)')) or 0
                log('feed status: objects=%d aircraft=%d -> %s   [%s]', obj, ac, (ac > 1) and 'object export looks ON' or 'object export looks OFF (no other aircraft listed)', hdr)
            end
            for line in text:gmatch('[^\r\n]+') do
                local tag = line:sub(1, 2)
                if tag == 'W ' then
                    local n = line:match('n=([^%s]+)') or '?'
                    if not feed_names[n] then feed_names[n] = true log('feed weapon: %s', line:sub(3)) end
                elseif tag == 'M ' then
                    local m = {}
                    for k, v in line:gmatch('(%w+)=([^%s]+)') do m[k] = v end
                    if m.id and m.rng then missiles[#missiles + 1] = m end
                end
            end
        end
    end
    if alive ~= feed_alive then
        if alive == false then log('feed %s', text and 'not updating (feeder not running yet, or the sim stopped it)' or 'unavailable (no file; is SurvFeed.lua in Export.lua, and the server allowing object export?)') end
        feed_alive = alive
    end
    if not alive then return end

    for _, m in ipairs(missiles) do
        local id = 'F' .. m.id
        local name = m.n or '?'
        local range_m, closing, miss_m = tonumber(m.rng) or 0, tonumber(m.cls) or 0, tonumber(m.miss) or 0
        local az = tonumber(m.az) or 0
        local tr = tracked[id]
        -- Already tracked through the sim's own contact list? Then that path decides everything.
        local covered = false
        for oid, o in pairs(tracked) do
            if not o.feed and o.rng and o.seen and now - o.seen < 1 and math.abs(o.rng - range_m) < F.match_m then covered = true break end
        end
        if covered then
            if tr then tr.seen = now else tracked[id] = { first = now, bursts = 0, last = -999, feed = true, ignore = true, seen = now } end
        else
            local is_close = closing > 0
            local tti = is_close and (range_m / math.max(closing, Tempo.MIN_CLOSING_MPS)) or 999
            if not tr then
                tr = { first = now, bursts = 0, last = -999, feed = true }
                tracked[id] = tr
                local lnm = tonumber(m.lnm) or -1
                local shooter = (m.sh ~= nil and m.sh ~= '-')
                tr.sam = not shooter
                tr.watched = (not tr.sam) and tti > Tempo.AIR.long_tti_s
                local radar_on = shooter and rwr_emitter_near(az) or false
                if tr.sam then tr.kind = (range_m / 1852 < Tempo.AIR.ir_range_nm) and 'both' or 'chaff'
                else
                    local launch_nm = lnm >= 0 and lnm or range_m / 1852
                    local ir_likely = launch_nm <= Tempo.AIR.ir_range_nm and not (Tempo.AIR.ir_needs_quiet_rwr and radar_on)
                    tr.kind = ir_likely and 'flare' or 'both'
                end
                log('feed missile: %s (%s) %s range=%.1f NM closing=%.0f m/s miss=%.1f NM az=%.0f shooter=%s (%s NM) radar_on=%s tti0=%.0f -> %s, program=%s',
                    id, name, tr.sam and 'SAM' or 'air', range_m / 1852, closing, miss_m / 1852, az, tostring(m.sh), tostring(m.lnm), tostring(radar_on), tti,
                    tr.sam and 'ground launch' or (tr.watched and 'long-range, watched' or 'close, immediate'), tostring(tr.kind))
                -- the singer call waits until the missile is inside visibility range and the reaction delay has passed (below)
                if tr.sam and not contains(Tempo.IR_TYPES, string.lower(name)) then tr.need_singer = true end
            end
            tr.seen = now
            tr.rng = range_m
            tr.az = az
            trace(tr, 'feed', range_m, closing, az)
            -- Plume visibility: while the motor burns the missile is seen out to F.max_nm. A burnout shows as the missile's OWN speed (the
            -- feed's spd field: the world-object position differenced over time, so it does not depend on how you fly) falling F.coast_drop_mps
            -- below its peak. Without a spd field (an older SurvFeed.lua) the closing speed stands in for it. A coasting missile that has not
            -- been sighted yet is only seen inside F.coast_nm, once its smoke (F.smoke_s after burnout) has gone. Once sighted it stays tracked.
            local spd = tonumber(m.spd)
            local sp = spd or closing
            if sp > (tr.peak or 0) then tr.peak = sp end
            local coasting = tr.peak ~= nil and now - tr.first > 3 and sp < tr.peak - (F.coast_drop_mps or 40)
            if coasting and not tr.burnout_at then tr.burnout_at = now end
            -- The smoke hangs in the air for a few seconds after burnout, so the missile is still found by its trail for F.smoke_s.
            local smoke = tr.burnout_at ~= nil and now < tr.burnout_at + (F.smoke_s or 10)
            local limit_nm = (coasting and not smoke) and (F.coast_nm or 1.5) or F.max_nm
            local vis = tr.sighted or range_m / 1852 <= limit_nm
            if vis and not tr.vis_since then tr.vis_since = now end
            local in_gate = vis and tr.vis_since ~= nil and now - tr.vis_since >= react_delay(range_m / 1852, tr.sam)
            if in_gate and tr.need_singer then
                tr.need_singer = false
                ground_launch_call(hour_of(az), 'feed', name)
            end
            if in_gate and not tr.sighted then
                tr.sighted = true
                log('feed: missile sighted at %.1f NM (%s) speed=%.0f peak=%.0f m/s', range_m / 1852, coasting and 'coasting, no plume' or 'motor burning', sp, tr.peak or 0)
            end
            local rear = Tempo.AIR.rear_skip and az > Tempo.AIR.rear_from_deg and az < Tempo.AIR.rear_to_deg
            local allow_miss = Tempo.DISPENSE_MISS_NM * 1852 + (tr.sam and Tempo.SAM.miss_growth * range_m or 0)
            if in_gate and is_close and miss_m < allow_miss then
                local want = false
                if tr.sam then
                    want = tr.bursts == 0 and tti <= Tempo.SAM.dispense_tti_s
                elseif tr.bursts == 0 then
                    if not tr.watched then want = true
                    elseif tti <= Tempo.AIR.dispense_tti_s then
                        if rear then
                            if not tr.rear_logged then tr.rear_logged = true log('feed: long-range shot in the rear sector (bearing %.0f) at tti %.0f s: not dispensing yet', az, tti) end
                        else want = true end
                    end
                end
                if want and burst(tr.kind, string.format('feed %.1f NM tti %.0f s, +%.2f s since seen', range_m / 1852, tti, now - tr.first)) then
                    tr.bursts = tr.bursts + 1
                    tr.last = now
                end
                local warn_tti = tr.sam and Tempo.SAM.warn_tti_s or (tr.watched and Tempo.AIR.warn_tti_s) or nil
                if warn_tti and not tr.warned and tti <= warn_tti and (tr.sam or not rear) then
                    tr.warned = true
                    say_headsup_now(hour_of(az))
                    log('feed: heads-up call at tti %.0f s', tti)
                end
                if not tr.sam and not tr.called and not tr.warned then
                    tr.called = true
                    if tr.watched then
                        say_launch_now(hour_of(az))     -- the "missile missile missile" heads-up follows at warn_tti
                    else
                        say_headsup_now(hour_of(az))     -- a close shot: the same "missile missile missile" as the heads-up
                    end
                    log('feed: warning call at +%.2f s since seen', now - tr.first)
                end
            end
        end
    end
    for id, tr in pairs(tracked) do
        if tr.feed or tr.ignore then
            if now - (tr.seen or 0) > 3 then tracked[id] = nil end
        end
    end
end

local state = rawget(_G, 'CMT_STATE')
if not state then state = { threat = nil, t = -999 } _G.CMT_STATE = state end

function Tempo.Install()
    local CM = require('behaviors.CountermeasuresDispensing')
    local RM = require('behaviors.ReportMissiles')
    local Eyes = require('senses.EyeballsMk1')
    local Labels = require('base.Labels')
    _G.CMT_CFG = Tempo
    Tempo.IsSam = is_sam

    -- Eyes: every missile inside the range limit is seen at once, whatever its size, plume or the cockpit
    -- structure (MISSILE_VISION = 'all'); 'plume' limits that to missiles with the motor burning, and anything
    -- else leaves the stock random roll alone. A small, smokeless missile such as the R-60M only gets
    -- the stock roll's tiny chance at range, which is why 'all' is the default.
    local eyes_first = {}      -- when each missile first came inside the visibility limit (for the reaction delay)
    if type(Eyes.IsContactVisible) == 'function' and not rawget(_G, 'CMT_EYES3_WRAPPED') then
        local orig_visible = Eyes.IsContactVisible
        Eyes.IsContactVisible = function(self, contact, ...)
            local seen = false
            pcall(function()
                local cfg = rawget(_G, 'CMT_CFG')
                if cfg and contact:Is(Labels.missile) then
                    local mode = cfg.MISSILE_VISION
                    local d = contact.polar_ned.length:ConvertTo(NM).value
                    local lim = cfg.IsSam(contact) and cfg.SAM.visible_nm or cfg.AIR.visible_nm
                    if (mode == 'all' or (mode == 'plume' and contact.active_missile_plume))
                        and d <= lim and (mode == 'all' or not self:IsOccludedByCockpit(contact.polar_body)) then
                        -- noticed only after the reaction delay for its range, counted from when it came inside the limit
                        local key = contact.true_id or contact
                        local t = now_seconds()
                        eyes_first[key] = eyes_first[key] or t
                        if t - eyes_first[key] >= react_delay(d, cfg.IsSam(contact)) then seen = true end
                    end
                end
            end)
            if seen then return true end
            return orig_visible(self, contact, ...)
        end
        _G.CMT_EYES3_WRAPPED = true
    end

    -- Warning-call threat test: closing, and closest approach inside THREAT_MISS_NM.
    RM.IsMissileAThreat = function(self, missile)
        local ok, res = pcall(function()
            if missile:Is(Labels.friendly) and missile.polar_ned.length < NM(1) then return false end
            local closing, miss, range = geometry(missile)
            local allow = Tempo.THREAT_MISS_NM * 1852
            local tr = tracked[missile.true_id or missile]
            if (tr and tr.sam) or is_sam(missile) then allow = allow + Tempo.SAM.miss_growth * range end
            return closing and miss < allow
        end)
        return ok and res or false
    end

    -- Spoken warnings queue at a higher priority than stock's 0, so they play ahead of routine chatter.
    -- (Same phrases as stock; the task just carries a priority.)
    RM.SayMissile = function(self, hour)
        local task = Task:new()
        task:Say('spotting/missile', 'spotting/' .. (HOURS[tonumber(hour)] or 'twelve') .. 'oclock')
        task:SetPriority(Tempo.PRIORITY.missile)
        GetJester():AddTask(task)
    end
    local ok_rwr, RWRB = pcall(require, 'behaviors.ObserveRWR')
    if ok_rwr and type(RWRB) == 'table' then
        RWRB.SaySinger = function(self, hour, type_1, type_2, subsequent)
            -- A ground-launch call for the same site was just made from the missile's first sighting: do not say it twice.
            local hnum, tnow = tonumber(hour), now_seconds()
            if hnum and recent_call_near(hnum, tnow) then
                self.last_singer_time_stamp = Utilities.GetTime().mission_time
                log('RWR singer %s o\'clock skipped, already called %.0f s ago', tostring(hour), tnow - last_gcall.t)
                return
            end
            if hnum then last_gcall.t, last_gcall.hour = tnow, hnum end
            local task = Task:new()
            local h = HOURS[tonumber(hour)] or 'twelve'
            if not subsequent then
                task:Say('phrases/singer' .. h .. 'oclock')
            else
                task:Say('phrases/andasinger')    -- stock says 'phrases/andsinger', which has no voice file (it would stall the task)
                task:Say('spotting/' .. h .. 'oclock')
            end
            if type_1 then task:Say(type_1) end
            task:SetPriority(Tempo.PRIORITY.launch)
            GetJester():AddTask(task)
            -- Stock sets this after the call; its "and singer" follow-up for a second launch within a few seconds depends on it.
            -- (Stock also asks for chaff here; that stays off, the launch watch above times the chaff.)
            self.last_singer_time_stamp = Utilities.GetTime().mission_time
        end
    end

    local first_seen = {}
    RM.Tick = function(self)
        local okt, errt = pcall(function()
            local now = now_seconds()
            for _, contact in ipairs(GetJester().awareness:GetContacts()) do
                if contact:Is(Labels.missile) then
                    local id = contact.true_id or contact
                    local tr = tracked[id]
                    local closing, miss_m, range_m, closing_mps = geometry(contact)
                    local friendly = contact:Is(Labels.friendly)
                    -- The object feed already tracks this missile (same range): it decides everything. Without this the eyes saw a missile
                    -- the feed had followed from launch, found no shooter nearby, and made a second "SAM" track (singer call, second warning).
                    if not tr then
                        local F = Tempo.FEED
                        for _, o in pairs(tracked) do
                            if o.feed and not o.ignore and o.rng and o.seen and now - o.seen < 1 and F and math.abs(o.rng - range_m) < F.match_m then
                                tr = { first = now, bursts = 0, last = -999, feed = true, ignore = true, seen = now, rng = range_m }
                                tracked[id] = tr
                                log('eyes: missile at %.1f NM is the feed missile already tracked, left to the feed', range_m / 1852)
                                break
                            end
                        end
                    end
                    if tr and tr.ignore then
                        tr.seen = now
                        tr.rng = range_m
                        goto continue
                    end
                    if not tr then
                        tr = { first = now, bursts = 0, last = -999 }
                        tracked[id] = tr
                        local guidance, name = classify(contact)
                        local shooter, along_m, sdbg = Tempo.FindShooter(contact)
                        local tti0 = closing and (range_m / math.max(closing_mps, Tempo.MIN_CLOSING_MPS)) or 999
                        local range_nm = range_m / 1852
                        tr.sam = is_sam(contact) or shooter == nil
                        tr.watched = (not tr.sam) and tti0 > Tempo.AIR.long_tti_s
                        local launch_nm = range_nm + math.max(along_m or 0, 0) / 1852
                        local az = shooter and azimuth_deg(shooter) or nil
                        local radar_on = az and rwr_emitter_near(az) or false
                        if guidance == 'ir' then tr.kind = 'flare'
                        elseif guidance == 'radar' then tr.kind = 'chaff'
                        elseif tr.sam then tr.kind = (range_nm < Tempo.AIR.ir_range_nm) and 'both' or 'chaff'
                        else
                            local ir_likely = launch_nm <= Tempo.AIR.ir_range_nm and not (Tempo.AIR.ir_needs_quiet_rwr and radar_on)
                            tr.kind = ir_likely and 'flare' or 'both'
                        end
                        local sname, sdist = 'none', -1
                        if shooter then
                            pcall(function() sname = tostring(shooter.type or shooter.true_id) end)
                            pcall(function() sdist = shooter.polar_ned.length:ConvertTo(NM).value end)
                        end
                        log('missile seen: %s type=%s (%s) range=%.1f NM plume=%s closing=%s miss=%.1f NM', tr.sam and 'SAM' or 'air', tostring(contact.type),
                            guidance, range_nm, tostring(contact.active_missile_plume and true or false), tostring(closing), miss_m / 1852)
                        log('shooter search: %s', tostring(sdbg))
                        log('launch: shooter=%s (%.1f NM, bearing %s) launch~%.1f NM tti0=%.0f s radar_on=%s -> %s, program=%s',
                            sname, sdist, az and string.format('%.0f', az) or '-', launch_nm, tti0, tostring(radar_on),
                            tr.sam and 'ground launch' or (tr.watched and 'long-range, watched' or 'close, immediate'), tostring(tr.kind))
                        if tr.sam and guidance ~= 'ir' and not friendly then
                            pcall(function() ground_launch_call(self:AzimuthToHour(self:GetAzimuth(contact)), 'eyes', tostring(contact.type or '')) end)
                        end
                    end
                    tr.seen = now
                    tr.rng = range_m
                    trace(tr, 'eyes', range_m, closing_mps, nil)
                    local sam = tr.sam

                    -- Dispense. Close fighter launches: at once, from any direction. Watched long-range fighter launches and SAMs:
                    -- by time to impact.
                    local allow_miss = Tempo.DISPENSE_MISS_NM * 1852 + (sam and Tempo.SAM.miss_growth * range_m or 0)
                    local tti = closing and (range_m / math.max(closing_mps, Tempo.MIN_CLOSING_MPS)) or 999
                    if not friendly and closing and miss_m < allow_miss then
                        local want = false
                        if sam then
                            local c = Tempo.SAM
                            if tr.bursts == 0 then want = tti <= c.dispense_tti_s
                            else want = tti <= c.sustain_tti_s and now - tr.last >= c.sustain_s and tr.bursts < c.max_bursts end
                        else
                            local c = Tempo.AIR
                            if tr.bursts == 0 then
                                if not tr.watched then
                                    want = true
                                elseif tti <= c.dispense_tti_s then
                                    if in_rear_sector(contact) then
                                        if not tr.rear_logged then
                                            tr.rear_logged = true
                                            log('long-range shot in the rear sector (bearing %.0f) at tti %.0f s: not dispensing yet', azimuth_deg(contact), tti)
                                        end
                                    else
                                        want = true
                                    end
                                end
                            else
                                want = range_m < c.sustain_nm * 1852 and now - tr.last >= c.sustain_s and tr.bursts < c.max_bursts
                            end
                        end
                        if want then
                            if burst(tr.kind, string.format('%s %.1f NM tti %.0f s, burst %d, +%.2f s since seen', sam and 'SAM' or 'air',
                                    range_m / 1852, tti, tr.bursts + 1, now - tr.first)) then
                                tr.bursts = tr.bursts + 1
                                tr.last = now
                            end
                        end
                    end

                    -- Heads-up just before the dump (SAMs, and watched long-range shots that will be dispensed against).
                    local warn_tti = sam and Tempo.SAM.warn_tti_s or (tr.watched and Tempo.AIR.warn_tti_s) or nil
                    if warn_tti and not friendly and not tr.warned and closing and miss_m < allow_miss
                        and tti <= warn_tti and (sam or not in_rear_sector(contact)) then
                        tr.warned = true
                        say_headsup_now(self:AzimuthToHour(self:GetAzimuth(contact)))
                        log('heads-up call at tti %.0f s', tti)
                    end

                    -- Warning call.
                    local fast = false
                    pcall(function()
                        local vx = contact.velocity_ned.x:ConvertTo(mps).value
                        local vy = contact.velocity_ned.y:ConvertTo(mps).value
                        fast = Tempo.HORIZONTAL_MPS <= 0 or math.abs(vx) > Tempo.HORIZONTAL_MPS or math.abs(vy) > Tempo.HORIZONTAL_MPS
                    end)
                    if fast and not self:IsMissileKnown(contact) then
                        first_seen[id] = first_seen[id] or now
                        if self:IsMissileAThreat(contact) then
                            table.insert(self.known_missiles, id)
                            state.threat, state.t = contact, now
                            if tr.warned then
                                -- the "missile missile missile" heads-up was just spoken: do not stack the plain call on it
                                log('warning call skipped, heads-up already given (+%.2f s since seen)', now - tr.first)
                            else
                                log('warning call at +%.2f s since seen', now - tr.first)
                                if tr.watched and not tr.sam then say_launch_now(self:AzimuthToHour(self:GetAzimuth(contact)))
                                else say_headsup_now(self:AzimuthToHour(self:GetAzimuth(contact))) end   -- close shot or SAM: defend now
                            end
                        elseif now - first_seen[id] > Tempo.REEVAL_S then
                            table.insert(self.known_missiles, id)       -- not a threat to us
                        end
                    end
                    ::continue::
                end
            end
            for id, tr in pairs(tracked) do
                if tr.seen and now - tr.seen > 5 then tracked[id] = nil end
            end
        end)
        if not okt then log('missile tick failed: %s', tostring(errt)) end
    end

    -- The warning call also asks for a dispense; the missile tracker above has normally started one already.
    -- The tracker above decides every countermeasure program (what, when); stock's fallback request does nothing.
    CM.StartDispensing = function(self) end
    -- The stock "singer" call asks for chaff the moment the RWR shows a launch, however far the SAM is.
    -- The launch watch above and the SAM missile tracker time it instead.
    CM.StartDispensingChaff = function(self) end
    CM.StartDispensingFlare = function(self) burst('flare', 'flares requested') end

    -- Stock sequencing is not used; this Tick runs the timeline.
    CM.Tick = function(self)
        pump()
        local ok, err = pcall(rwr_scan)
        if not ok then log('rwr scan failed: %s', tostring(err)) end
        local okf, errf = pcall(feed_scan)
        if not okf and not feed_err then feed_err = true log('feed scan failed: %s', tostring(errf)) end
    end
    log('installed')
end

return Tempo
