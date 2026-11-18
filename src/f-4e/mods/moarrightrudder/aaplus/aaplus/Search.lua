-- Phase 4: directed search. Turns a cue into a radar search, built on stock's own machinery:
--   * the cursor is held at the cue azimuth (stock normally recenters it every tick),
--   * the scan type is narrow, so the beam follows the cursor,
--   * elevation bands are stepped through stock's pilot_requested_scan_zone, one band per
--     SEARCH_DWELL, with stock doing the scanning, IFF and call-out.
-- It runs from two wrapped stock functions: Radar.FindNextPhase (only reached when the radar's
-- task queue is idle) and Radar.UpdateTargetHighlight (cursor hold).
-- It never starts while a lock, focus, highlight or pilot-requested zone exists, and it hands
-- back to stock as soon as one of those appears.
local Utilities = require('base.Utilities')
local Task = require('base.Task')
local Config = require 'aaplus.Config'
local AADLog = require 'aaplus.Log'
local Patches = require 'aaplus.Patches'
local Picture = require 'aaplus.Picture'
local Cues = require 'aaplus.Cues'
local Engagement = require 'aaplus.Engagement'
local Awacs = require 'aaplus.Awacs'

local Search = {}
Search.phase = 'idle'   -- idle | sweeping | holding
Search.cue = nil
Search.bands = nil
Search.idx = 0

local sw = {}  -- search working state

-- Stock's targets (focus, highlight, lock) are userdata, not tables: read the id through pcall, never test type().
local function tid(t)
    if t == nil then return nil end
    local ok, id = pcall(function() return t.id end)
    if ok then return id end
    return nil
end

local function now_seconds()
    local t = 0
    pcall(function()
        local raw = Utilities.GetTime().mission_time
        t = type(raw) == 'number' and raw or raw:ConvertTo(s).value
    end)
    return t
end

local function own_altitude_ft()
    local v = 25000
    pcall(function()
        local o = GetJester().awareness:GetObservation('barometric_altitude')
        if o then v = o:ConvertTo(ft).value end
    end)
    return v
end

-- The cue's azimuth relative to the nose now: an AWACS/EWRS contact's bearing when the cue has been matched to one.
local function cue_az(cue)
    if cue.aw_abs then
        local h = Cues.OwnHeading()
        if h then return (cue.aw_abs - h + 180) % 360 - 180 end
    end
    return Cues.CurrentAz(cue)
end

-- The cue's own range, or the one an AWACS/EWRS contact gave it.
local function cue_range(cue)
    return cue and (cue.range_nm or cue.aw_range_nm) or nil
end

local function stock()
    return require('radar.State'), require('radar.Api'), require('radar.Config')
end

-- Coarse gain for the look-down bands. Ground return rises with gain, so a lower gain lets a low target stand
-- out of the clutter. Set when a band points down, put back when the search ends. A gain the pilot moved
-- meanwhile is left alone.
local gain_diag_logged = false
local function get_gain()
    local ok, r = pcall(function() return require('radar.Api').GetCurrentGainCoarse() end)
    local v
    if ok and type(r) == 'number' then
        v = r
    elseif ok and r ~= nil then
        pcall(function() v = tonumber(r.value) or tonumber(tostring(r)) end)
    end
    if v == nil then
        pcall(function()
            local x = GetJester():GetCockpit():GetManipulator('Radar Gain Coarse'):GetState()
            v = type(x) == 'number' and x or tonumber(x and x.value)
        end)
    end
    if v == nil and not gain_diag_logged then
        gain_diag_logged = true
        AADLog.Info('search: gain read failed: ok=%s type=%s value=%s', tostring(ok), type(r), tostring(r))
    end
    return v
end

-- The knob is turned the way stock's own phases do it: a task that clicks the control (a bare manipulator
-- click did nothing). A knob the pilot has bound to an axis is the pilot's and stays theirs.
local function set_gain(v)
    local ok, err = pcall(function()
        local t = Task:new()
        t:ClickFast('Radar Gain Coarse', v, true)
        GetJester():AddTask(t)
    end)
    if not ok then AADLog.Info('search: gain click failed: %s', tostring(err)) end
end

-- Stock re-adjusts gain every time a new scan zone starts (and we start one per band), so setting the knob
-- does not stick: it was reset to stock's own value within the band. Instead, stock's two gain settings
-- (close and far) are lowered for the look-down bands and put back afterwards, so stock picks our value itself.
-- Main-lobe clutter range in NM: where the radar beam meets the ground. Nil when it does not meet it.
local function mlc_nm()
    local ok, v = pcall(GetRadarMlcRange)
    if not ok or v == nil then return nil end
    local n
    pcall(function() n = v:ConvertTo(NM).value end)
    if not n then pcall(function() n = tonumber(v.value) end) end
    if n and n > 0 then return n end
    return nil
end

-- True when v is (about) one of the gains this search sets: a knob reading there that is not the remembered
-- original means an earlier restore has not landed.
local function near_set_gain(v)
    if not v then return false end
    for _, g in ipairs({ Config.SEARCH_DOWN_GAIN, Config.SEARCH_UP_GAIN, Config.SEARCH_UNKNOWN_GAIN }) do
        if g and math.abs(v - g) < 0.05 then return true end
    end
    return false
end

local keep_knob_once = false   -- a new search is starting: leave the knob where it is (it is about to be set again)

local function restore_gain(why)
    if not sw.gain_cfg then return end
    local saved = sw.gain_cfg
    sw.gain_cfg = nil
    pcall(function()
        local rcfg = require('radar.Config')
        rcfg.GAIN_COARSE_CLOSE, rcfg.GAIN_COARSE_FAR = saved.close, saved.far
    end)
    -- Put the knob back unless the pilot moved it away from what the search set.
    local cur = get_gain()
    if why == 'interrupted' then
        -- A slew usually starts another search at once: leave the knob, GainHoldUpdate puts it back if none does.
        if saved.knob and cur and saved.target and math.abs(cur - saved.target) < 0.05 then Search.left_knob_at = now_seconds() end
    elseif not keep_knob_once and saved.knob and cur and saved.target and math.abs(cur - saved.target) < 0.05 then
        set_gain(saved.knob)
    end
    AADLog.Info('search: stock gain settings back to %s / %s (%s)', tostring(saved.close), tostring(saved.far), why or '?')
end

-- Look-up gain kept after the search ends: stock re-focusing the contact would otherwise put the gain back to
-- stock and lose a faint contact that only the higher gain showed. Released when the contact has been off the
-- scope a while, when the beam meets the ground behind it, after a maximum time, or when a new search starts.
local gh = nil

-- Diagnostic: every setting in stock's radar config / state whose name mentions gain (what else drives the knob?).
local gain_keys_dumped = false
local function dump_gain_keys()
    if gain_keys_dumped then return end
    gain_keys_dumped = true
    -- Which radar modules / functions deal with gain or clutter at all.
    pcall(function()
        for name, mod in pairs(package.loaded) do
            if type(name) == 'string' and name:find('^radar') and type(mod) == 'table' then
                local hits = {}
                for k, v in pairs(mod) do
                    if type(k) == 'string' and (k:lower():find('gain') or k:lower():find('clutter') or k:lower():find('mlc')) then
                        hits[#hits + 1] = k .. '(' .. type(v) .. ')'
                    end
                end
                if #hits > 0 then AADLog.Info('gain key: module %s: %s', name, table.concat(hits, ', ')) end
            end
        end
    end)
    pcall(function()
        local State, _, rcfg = stock()
        for label, tbl in pairs({ config = rcfg, state = State }) do
            for k, v in pairs(tbl) do
                if type(k) == 'string' and k:lower():find('gain') then
                    local val = v
                    if type(v) == 'table' then
                        local parts = {}
                        for k2, v2 in pairs(v) do parts[#parts + 1] = tostring(k2) .. '=' .. tostring(v2) end
                        val = '{' .. table.concat(parts, ', ') .. '}'
                    end
                    AADLog.Info('gain key: %s.%s = %s', label, k, tostring(val))
                end
            end
        end
    end)
end

local function release_gain_hold(why, keep_knob)
    if not gh then return end
    keep_knob_once = keep_knob and true or false
    local keep = sw.gain_cfg
    sw.gain_cfg = gh.cfg
    gh = nil
    restore_gain('gain hold: ' .. tostring(why))
    keep_knob_once = false
    sw.gain_cfg = keep
end

-- The look-up gain also follows a focus that did not come from a search (a context-button cycle, a lock): stock's own
-- gain routine would otherwise walk the knob back down as soon as it focuses a contact above the horizon.
local function start_follow_hold()
    if Config.GAIN_FOLLOW_FOCUS == false or Config.SEARCH_UP_GAIN_HOLD == false or not Config.SEARCH_UP_GAIN then return end
    if Search.phase ~= 'idle' then return end
    local ok, St = pcall(stock)
    if not ok or not St then return end
    local tgt = St.target_currently_locked or St.target_to_lock or St.target_to_focus_on or St.target_to_highlight
    local tgtid = tid(tgt)
    if not tgtid then return end
    local tr = Picture.tracks[tgtid]
    local own = own_altitude_ft()
    if not (tr and tr.alt_ft and tr.range_nm and own) then return end
    local elev = math.deg(math.atan2(tr.alt_ft - own, math.max(tr.range_nm, 1) * 6076.12))
    local want, kind
    if elev > 0.5 then want, kind = Config.SEARCH_UP_GAIN, 'above'
    elseif elev < -0.5 and Config.SEARCH_DOWN_GAIN then want, kind = Config.SEARCH_DOWN_GAIN, 'below'
    else return end
    local rcfg = require('radar.Config')
    local k = get_gain()
    if k and Search.orig_knob and near_set_gain(k) then k = Search.orig_knob elseif k then Search.orig_knob = k end
    local now = now_seconds()
    gh = { cfg = { close = rcfg.GAIN_COARSE_CLOSE, far = rcfg.GAIN_COARSE_FAR, knob = k, target = want },
           born = now, id = tgtid, last_seen = now }
    rcfg.GAIN_COARSE_CLOSE, rcfg.GAIN_COARSE_FAR = want, want
    set_gain(want)
    AADLog.Info('search: focus on a contact %.1f deg %s you (%.0f NM): gain %.2f held (stock %s / %s, knob was %s)',
        elev, kind, tr.range_nm, want, tostring(gh.cfg.close), tostring(gh.cfg.far), tostring(k))
end

local function put_back_left_knob()
    Search.left_knob_at = nil
    local cur = get_gain()
    if Search.orig_knob and cur and near_set_gain(cur) and math.abs(cur - Search.orig_knob) > 0.05 then
        set_gain(Search.orig_knob)
        AADLog.Info('search: knob was left at %.2f, put back to %.2f', cur, Search.orig_knob)
    end
end

function Search.GainHoldUpdate()
    if Search.postlock and now_seconds() > Search.postlock.until_t then Search.postlock = nil end
    if Search.prep then
        local okp, errp = pcall(Search.PrepUpdate)
        if not okp then
            AADLog.Info('lockprep error: %s', tostring(errp))
            Search.prep = nil
        end
    end
    -- Stock keeps its focus on a contact that has left the scope (gimbal exit, lost paint) forever, so the radar stays
    -- narrow on the spot where it vanished and no search is ever requested. After FOCUS_RELEASE_LOST_S unseen, with no
    -- lock, drop the focus and highlight so stock's normal scan resumes (a context double press does the same by hand).
    if Search.phase == 'idle' and not Search.prep then
        pcall(function()
            local St = stock()
            local f = St and St.target_to_focus_on
            if not f or St.target_to_lock or St.target_currently_locked then return end
            local id = tid(f)
            local tr = id and Picture.tracks[id]
            local now = now_seconds()
            if tr and not tr.present and tr.last_seen and now - tr.last_seen >= (Config.FOCUS_RELEASE_LOST_S or 20) then
                AADLog.Info('search: the focused contact %s has been off the scope for %.0f s: dropping the focus, the radar goes back to its normal scan',
                    tostring(id), now - tr.last_seen)
                St.target_to_focus_on = nil
                St.target_to_highlight = nil
                St.pilot_requested_target_to_highlight = nil
            end
        end)
    end
    if Search.left_knob_at and Search.phase == 'idle' and not gh and now_seconds() - Search.left_knob_at > 3 then
        put_back_left_knob()
    end
    if not gh then return start_follow_hold() end
    local now = now_seconds()
    if Search.phase ~= 'idle' then return release_gain_hold('search active') end
    -- No time limit: the gain is held for as long as the contact is worked (focus / lock / highlight). It is released
    -- when the contact has been gone for SEARCH_UP_GAIN_LOST_S, a new search starts, or stock keeps changing the gain.
    -- A faint contact is painted only now and then, so recent hits are no measure of whether it is still being
    -- worked: stock's own focus / lock / highlight is. The 'lost' timer only runs when none of those exist.
    local ok, St = pcall(stock)
    local tgt = ok and St and (St.target_currently_locked or St.target_to_lock or St.target_to_focus_on or St.target_to_highlight)
    if tid(tgt) then gh.id = tid(tgt) gh.last_seen = now
    elseif tgt then gh.last_seen = now end
    local tr = gh.id and Picture.tracks[gh.id]
    if tr and tr.present and tr.last_seen and now - tr.last_seen < 5 then gh.last_seen = now end
    -- The held contact's elevation decides the gain: above the horizon the look-up gain (also replacing the unknown-
    -- elevation gain), below it the look-down gain. Re-checked every second, so a contact that crosses the horizon
    -- gets the other gain.
    if tr and tr.alt_ft and tr.range_nm and (Config.SEARCH_UP_GAIN or Config.SEARCH_DOWN_GAIN) and not Search.prep then
        local own = own_altitude_ft()
        if own then
            local elev = math.deg(math.atan2(tr.alt_ft - own, math.max(tr.range_nm, 1) * 6076.12))
            local want
            if elev > 0.5 then want = Config.SEARCH_UP_GAIN elseif elev < -0.5 then want = Config.SEARCH_DOWN_GAIN end
            local cur = gh.cfg.target
            local ours = cur and (cur == Config.SEARCH_UP_GAIN or cur == Config.SEARCH_DOWN_GAIN or cur == Config.SEARCH_UNKNOWN_GAIN)
            if want and ours and math.abs(want - cur) > 0.001 then
                gh.cfg.target = want
                pcall(function() local rcfg = require('radar.Config') rcfg.GAIN_COARSE_CLOSE, rcfg.GAIN_COARSE_FAR = want, want end)
                set_gain(want)
                AADLog.Info('search: held contact at %+.1f deg: gain %.2f -> %.2f', elev, cur, want)
            end
        end
    end
    -- Stock changes the gain itself at some points (after a call-out, say). Log what it did and put ours back.
    local target = gh.cfg.target
    local knob = get_gain()
    local rc_close, rc_far
    pcall(function() local rcfg = require('radar.Config') rc_close, rc_far = rcfg.GAIN_COARSE_CLOSE, rcfg.GAIN_COARSE_FAR end)
    local cfg_off = rc_close and rc_far and target and (math.abs(rc_close - target) > 0.01 or math.abs(rc_far - target) > 0.01)
    local knob_off = knob and target and math.abs(knob - target) > 0.03
    if cfg_off or knob_off then
        gh.fixes = (gh.fixes or 0) + 1
        AADLog.Info('search: gain hold: stock changed the gain (knob %s, close/far %s / %s, want %.2f) focus=%s lock=%s: %s',
            tostring(knob), tostring(rc_close), tostring(rc_far), target, tostring(ok and St and St.target_to_focus_on ~= nil),
            tostring(ok and St and St.target_currently_locked ~= nil), gh.fixes <= 6 and 'putting it back' or 'giving up')
        if gh.fixes > 6 then return release_gain_hold('stock keeps changing it') end
        pcall(function() local rcfg = require('radar.Config') rcfg.GAIN_COARSE_CLOSE, rcfg.GAIN_COARSE_FAR = target, target end)
        if knob_off then set_gain(target) end
    end
    if now - (gh.last_seen or gh.born) > (Config.SEARCH_UP_GAIN_LOST_S or 10) then return release_gain_hold('contact gone') end
    -- No ground-range release while holding: the radar only reports ground during a sweep, and a contact that paints
    -- steadily at the held gain must keep it (see DESIGN.md, step 7).
end

-- The gain wanted for a band: low for look-down (ground clutter), high for look-up (a faint contact in clear sky).
-- Stock applies a gain late, so a look-down gain starts one band early (on the band before the first look-down one).
local function want_gain(b)
    -- A search centered on a reported contact keeps one gain for the whole pattern, chosen by where the contact is:
    -- the bars either side of it are only there to cover its uncertainty, and a gain that flips on each bar
    -- (high on the contact's bar, low on the one just below the horizon) lets a faint contact slip through.
    local scue = Search.cue
    if scue and scue.aw_used and scue.aw_center and Config.AWACS_ONE_GAIN ~= false then
        if scue.aw_center > 0 then
            if Config.SEARCH_UP_GAIN and not sw.up_gain_blocked then return Config.SEARCH_UP_GAIN, 'look-up (contact above)' end
            return nil
        end
        if Config.SEARCH_DOWN_GAIN then return Config.SEARCH_DOWN_GAIN, 'look-down (contact below)' end
        return nil
    end
    local cur = b.angle or 0
    -- No contact elevation known for this cue: level and up bars take a middle gain (below the horizon stays low).
    if Config.SEARCH_UNKNOWN_GAIN and cur >= 0 and not (scue and scue.aw_used) and not sw.up_gain_blocked then
        return Config.SEARCH_UNKNOWN_GAIN, 'level/up (elevation unknown)'
    end
    local nxt = Search.bands and Search.bands[Search.idx + 1]
    local na = nxt and (nxt.angle or 0) or nil
    if Config.SEARCH_DOWN_GAIN and (cur < 0 or (na and na < 0)) then return Config.SEARCH_DOWN_GAIN, 'look-down' end
    if Config.SEARCH_UP_GAIN and not sw.up_gain_blocked and (cur > 0 or (cur == 0 and na and na > 0)) then
        return Config.SEARCH_UP_GAIN, 'look-up'
    end
    return nil
end

local function band_gain(b)
    if not b then return end
    local g, kind = want_gain(b)
    if g then
        if not sw.gain_cfg then
            pcall(function()
                local rcfg = require('radar.Config')
                -- A knob already near one of our values means an earlier restore has not landed (or never did):
                -- the knob to give back is the one remembered from before, not the one read now.
                local k = get_gain()
                if k and Search.orig_knob and near_set_gain(k) then
                    k = Search.orig_knob
                elseif k then
                    Search.orig_knob = k
                end
                sw.gain_cfg = { close = rcfg.GAIN_COARSE_CLOSE, far = rcfg.GAIN_COARSE_FAR, knob = k }
            end)
        end
        if sw.gain_cfg and (not sw.gain_cfg.target or math.abs(sw.gain_cfg.target - g) > 0.001) then
            sw.gain_cfg.target = g
            pcall(function()
                local rcfg = require('radar.Config')
                rcfg.GAIN_COARSE_CLOSE, rcfg.GAIN_COARSE_FAR = g, g
            end)
            -- Stock only applies its settings when its gain phase comes round, which can be after the band is over:
            -- turn the knob now as well, so the first band is not scanned at the old gain.
            set_gain(g)
            AADLog.Info('search: %s band, gain -> %.3f (stock %s / %s, knob was %s)', kind, g,
                tostring(sw.gain_cfg.close), tostring(sw.gain_cfg.far), tostring(sw.gain_cfg.knob))
        end
    elseif sw.gain_cfg then
        restore_gain('level band')
    elseif Search.left_knob_at then
        put_back_left_knob()
    end
end

local function range_setting(rcfg, nm)
    if nm <= 45 then return rcfg.range.nm_50 end
    if nm <= 90 then return rcfg.range.nm_100 end
    return rcfg.range.nm_200
end

-- Elevation (degrees) of the pilot's last stock scan-elevation command; 0 when none.
local function pilot_elevation_deg()
    local pe = Search.pilot_elev
    if not pe then return 0 end
    local rel = pe.relative and pe.alt_ft or (pe.alt_ft - own_altitude_ft())
    return math.deg(math.atan2(rel, math.max(pe.range_nm, 1) * 6076.12))
end

-- Elevation bands as antenna angles, assuming the bandit starts co-altitude: level first, then
-- steps away from level in the pilot's direction, then (jumping back to level) the other way.
-- With no pilot elevation, or a centered one, up comes first.
local function build_bands(cue, opts)
    opts = opts or {}
    local step, ups, downs = Config.SEARCH_STEP_DEG, Config.SEARCH_UP_STEPS, Config.SEARCH_DOWN_STEPS
    local seq = {}
    -- A scan the pilot interrupted: look once more at the elevation it was at, then go to level.
    if opts.first_angle and math.abs(opts.first_angle) > 0.1 then seq[#seq + 1] = opts.first_angle end
    seq[#seq + 1] = 0
    -- Finer steps looking down: a small target in clutter is lost at the edge of a band, so bands overlap there.
    local down_step = Config.SEARCH_DOWN_STEP_DEG or step
    local function run(sign, n)
        local st = sign < 0 and down_step or step
        for i = 1, n do seq[#seq + 1] = sign * i * st end
    end
    local down_first
    if opts.dir and opts.dir ~= 0 then
        down_first = opts.dir < 0          -- PILOT mode: the last vertical slew picks the direction
    else
        down_first = pilot_elevation_deg() < -Config.SEARCH_CENTER_DEG
    end
    if down_first then run(-1, downs) run(1, ups) else run(1, ups) run(-1, downs) end
    -- An AWACS / EWRS contact at the cue's position tells us the elevation: look there first.
    local aw_angle
    local okw, ea, info = pcall(Awacs.Elevation, cue)
    cue.aw_used = (okw and ea) and true or false
    if okw and ea then
        local lim_up, lim_dn = ups * step, downs * down_step
        aw_angle = math.max(-lim_dn, math.min(lim_up, ea))
        -- The contact's altitude is known to about a thousand feet: look there, then step outwards on a lattice
        -- anchored on the contact (even overlap both sides), alternating up and down, instead of starting at level.
        local sp = Config.AWACS_STEP_DEG or 3.0
        local lim_up, lim_dn = ups * step, downs * down_step
        local bars = Config.AWACS_BARS or 2
        local function lattice(sign)
            local out, k, last = {}, 1, aw_angle
            while k <= bars do
                local a = aw_angle + sign * k * sp
                if a > lim_up or a < -lim_dn then
                    local edge = a > lim_up and lim_up or -lim_dn
                    if math.abs(edge - last) > 1.5 then out[#out + 1] = edge end
                    break
                end
                out[#out + 1] = a
                last, k = a, k + 1
            end
            return out
        end
        local ups_l, dns_l = lattice(1), lattice(-1)
        local first, second = ups_l, dns_l
        if aw_angle < 0 then first, second = dns_l, ups_l end
        -- Center, up, center, down: the most likely band (the contact's own) is revisited between the others.
        local kept = {}
        for i = 1, math.max(#first, #second) do
            for _, lst in ipairs({ first, second }) do
                local a = lst[i]
                if a and (not Config.AWACS_SPAN_DEG or math.abs(a - aw_angle) <= Config.AWACS_SPAN_DEG) then
                    kept[#kept + 1] = aw_angle
                    kept[#kept + 1] = a
                end
            end
        end
        if #kept == 0 then kept = { aw_angle } end
        cue.aw_center = aw_angle
        local grid = seq
        seq = {}
        for _ = 1, math.max(1, Config.AWACS_PASSES or 3) do
            for _, a in ipairs(kept) do seq[#seq + 1] = a end
        end
        if Config.AWACS_FALLBACK then
            for _, a in ipairs(grid) do seq[#seq + 1] = a end
        end
        AADLog.Info('search: %s contact %s %d ft at %d NM -> elevation %+.1f deg first (age %.0f s)', info.src, tostring(info.type),
            info.alt_ft, info.range_nm, aw_angle, info.age)
    end
    -- No elevation known and the pilot bumped the cursor up or down: look only that way. Level, then the bump
    -- side, then back to level and the same side again (SEARCH_BUMP_LAPS laps), never the other side.
    if not cue.aw_used and opts.dir and opts.dir ~= 0 then
        local sign = opts.dir < 0 and -1 or 1
        local st = sign < 0 and down_step or step
        local n = sign < 0 and downs or ups
        seq = {}
        if opts.first_angle and math.abs(opts.first_angle) > 0.1 then seq[#seq + 1] = opts.first_angle end
        for _ = 1, math.max(1, Config.SEARCH_BUMP_LAPS or 2) do
            seq[#seq + 1] = 0
            for i = 1, n do seq[#seq + 1] = sign * i * st end
        end
        AADLog.Info('search: bump %s: %d lap(s) of level then %d band(s) %s only', sign < 0 and 'down' or 'up',
            math.max(1, Config.SEARCH_BUMP_LAPS or 2), n, sign < 0 and 'down' or 'up')
    end
    -- Sideways bumps of the cursor (Modes.lua): the first pauses the elevation scan at the elevation the radar was at, the
    -- next centers the elevation (hold_angle 0). One band, held, no up/down scan.
    local hold_dwell
    if opts.hold then
        local a = opts.hold_angle or opts.first_angle or pilot_elevation_deg()
        seq = { a }
        aw_angle = nil
        hold_dwell = Config.SEARCH_HOLD_S or 120
        AADLog.Info('search: sideways bump: elevation %s at %+.1f deg, no up/down scan', opts.centre and 'centered' or 'paused', a)
    end
    local r = cue_range(cue) or Config.SEARCH_RANGE_NM
    local bands = {}
    local skip_logged = {}
    local agl_ft = own_altitude_ft()
    for _, a in ipairs(seq) do
      -- A band pointing down hits the ground before the cue range when its lower beam edge reaches the ground
      -- inside that range: it would only look at clutter. Level and upward bands are always kept.
      local clutter = false
      if Config.SEARCH_SKIP_CLUTTER and a < 0 and a ~= aw_angle and not hold_dwell then
          local edge = math.abs(a) - (Config.SEARCH_BEAM_HALF_DEG or 1.7)
          if edge <= 0 then edge = 0.1 end
          clutter = agl_ft / math.tan(math.rad(edge)) / 6076.12 < r * (Config.SEARCH_CLUTTER_MARGIN or 1)
      end
      if clutter then
        if not skip_logged[a] then
          skip_logged[a] = true
          AADLog.Info('search: band %+.1f deg skipped, beam meets the ground inside %d NM (alt %d ft)', a, r, agl_ft)
        end
      else
        bands[#bands + 1] = { range = r, altitude = math.tan(math.rad(a)) * r * 6076.12, relative = true, angle = a,
                              dwell = hold_dwell or (aw_angle and Config.AWACS_DWELL) or ((a < 0) and Config.SEARCH_DOWN_DWELL or nil) }
      end
    end
    return bands
end

function Search.IsActive() return Search.phase ~= 'idle' end

-- Seconds the current search has run (nil when idle). A search that has found nothing for a while gives way to any cue
-- that scores higher (Director).
function Search.Age()
    if Search.phase == 'idle' then return nil end
    -- Holding the beam on a far contact that stock has not called out yet: the time since the find.
    if Search.phase == 'holding' then
        if sw.far == true and sw.found_at then return now_seconds() - sw.found_at end
        return nil
    end
    if not sw.started then return nil end
    return now_seconds() - sw.started
end

-- True while the beam is held on a far contact waiting for stock's call-out (nothing focused yet): a more urgent cue may
-- take over from this, as from a sweep.
function Search.FarHold() return Search.phase == 'holding' and sw.far == true end

-- PILOT mode: the pilot took the cursor. Stop sweeping but leave the antenna where it is (zone, scan
-- type and range untouched), so the pilot can look at, and lock, a contact Jester has not recognized.
-- The elevation it was at is remembered for the next scan; ClearCarry gives the settings back.
function Search.Interrupt(reason)
    if Search.phase == 'idle' then return end
    local b = Search.bands and Search.bands[math.max(Search.idx, 1)]
    if Config.SEARCH_UP_GAIN_HOLD ~= false and sw.gain_cfg and Config.SEARCH_UP_GAIN
        and (((sw.gain_cfg.target == Config.SEARCH_UP_GAIN or sw.gain_cfg.target == Config.SEARCH_UNKNOWN_GAIN) and not sw.up_gain_blocked)
             or sw.gain_cfg.target == Config.SEARCH_DOWN_GAIN) then
        -- The pilot's slew usually starts another search or a focus at once: keep the look-up gain instead of
        -- dropping to stock and climbing again (released by the usual hold rules).
        local now = now_seconds()
        gh = { cfg = sw.gain_cfg, born = now, id = Search.found and Search.found.id or nil, last_seen = now }
        sw.gain_cfg = nil
        AADLog.Info('search: keeping gain %.2f after the pilot slew', gh.cfg.target or 0)
    else
        restore_gain('interrupted')
    end
    Search.carry = {
        angle = b and b.angle or 0,
        saved_type = sw.saved_type,
        saved_range = sw.saved_range,
        at = now_seconds(),
    }
    AADLog.Info('search: interrupted (%s) at %+.1f deg after %.1f s', reason, Search.carry.angle, now_seconds() - (sw.started or 0))
    Search.phase = 'idle'
    Search.cue = nil
    Search.bands = nil
    sw = {}
end

function Search.ClearCarry(reason)
    local carry = Search.carry
    if not carry then return end
    Search.carry = nil
    local State, _, rcfg = stock()
    if carry.saved_type then State.pilot_requested_scan_type = carry.saved_type end
    if carry.saved_range then State.pilot_requested_range = carry.saved_range end
    if State.pilot_requested_scan_zone and State.pilot_requested_scan_zone.name == 'AAD_SEARCH' then
        State.pilot_requested_scan_zone = nil
    end
    State.max_scan_time_for_zone_no_bandits = rcfg.MAX_ZONE_SCAN_TIME
    AADLog.Info('search: interrupted scan dropped (%s), stock scan resumes', reason or '?')
end

-- Stock's focus / highlight sits on a contact that has been off the scope for a while (lost, e.g. after the gain
-- dropped): it must not block a search for a new report.
local function stale_focus(t)
    local id = tid(t)
    if not id then return false end
    local tr = Picture.tracks[id]
    if not tr then return true end
    return not tr.present and (now_seconds() - (tr.last_seen or 0)) > (Config.FOCUS_LOST_S or 8)
end

-- Dawger list #5 (13 Oct 2026): stock's background scan stands still while a bandit is inside TRANSITION_NM (and in BFM), so
-- it does not compete with a manual lock and the IFF check. Stock already does this when the radar is caged or in boresight
-- and inside 1.75 NM; this covers the uncaged stretch out to TRANSITION_NM. Not frozen: a lock (handled as always), our own
-- search or lock prep (they use stock's phases), and a task already running (the radar tick waits for it). The scan resumes
-- by itself when the engagement state drops back to BVR or NONE. G is not used: inside TRANSITION_NM Jester is heads out.
local scan_frozen_logged = false
local function scan_frozen()
    local frozen = false
    pcall(function()
        local st = Engagement.state
        if st ~= Engagement.TRANSITION and st ~= Engagement.BFM then return end
        local State = stock()
        if State.target_to_lock or State.target_currently_locked then return end
        if Search.phase ~= 'idle' or Search.prep then return end
        frozen = true
    end)
    if frozen ~= scan_frozen_logged then
        scan_frozen_logged = frozen
        AADLog.Info('scan: stock background scan %s (engagement %s)', frozen and 'frozen' or 'resumed', tostring(Engagement.state))
    end
    return frozen
end

-- Guards that must all hold for a search to start.
function Search.CanStart()
    if Search.phase ~= 'idle' then return false, 'active' end
    local State, Api = stock()
    if not State.is_active or not Api.IsPowered() then return false, 'radar off' end
    if State.current_context_mode ~= require('radar.Config').context_mode.A2A then return false, 'not A2A' end
    if Api.IsInDogfightMode() or Api.IsBoresightMode() then return false, 'dogfight/boresight' end
    if Engagement.state == Engagement.BFM then return false, 'BFM' end
    if State.current_scan_zone == nil then return false, 'no scan zone' end   -- stock's regular scan must already be running
    if State.target_to_lock or State.target_currently_locked then return false, 'lock' end
    if State.target_to_focus_on and not stale_focus(State.target_to_focus_on) then return false, 'focus' end
    if State.target_to_highlight and not stale_focus(State.target_to_highlight) then return false, 'highlight' end
    local z = State.pilot_requested_scan_zone
    if z and z.name ~= 'AAD_SEARCH' then return false, 'pilot zone' end
    return true
end

local last_cannot_log = -1e9
function Search.Start(cue, opts)
    local can, why = Search.CanStart()
    if not can then
        local now = now_seconds()
        if why ~= 'active' and now - last_cannot_log > 5 then
            last_cannot_log = now
            AADLog.Info('search: cannot start %s (%s)', cue.key, why)
        end
        return false
    end
    local held_knob = gh ~= nil
    local carried_cfg = gh and gh.cfg or nil
    if gh then gh = nil end   -- the new search takes the held gain over (no drop to stock in between)
    -- A contact above the highest band is too steep for a bar search (close, high): stock / boresight handles it.
    if Config.AWACS_ELEVATION and Config.AWACS_ENABLED then
        local okp, ep, pinfo = pcall(Awacs.Elevation, cue)
        local max_el = Config.AWACS_MAX_ELEV_DEG or (Config.SEARCH_UP_STEPS * Config.SEARCH_STEP_DEG)
        if okp and ep and ep > max_el then
            if not cue.aw_skip_logged then
                cue.aw_skip_logged = true
                AADLog.Info('search: %s contact %s at %+.1f deg (%d ft, %d NM) is above the scan limit (%.1f): no search, left to stock',
                    cue.key, tostring(pinfo.type), ep, pinfo.alt_ft, pinfo.range_nm, max_el)
            end
            cue.cooldown_until = now_seconds() + (Config.CUE_COOLDOWN_S or 20)
            return false
        end
    end
    local State, _, rcfg = stock()
    if State.target_to_focus_on and stale_focus(State.target_to_focus_on) then
        AADLog.Info('search: dropping the focus on a contact that left the scope')
        State.target_to_focus_on = nil
        State.pilot_requested_target_to_highlight = nil
        if State.target_to_highlight and stale_focus(State.target_to_highlight) then State.target_to_highlight = nil end
    end
    Search.cue = cue
    Search.last_cue = cue
    Search.auto = false   -- the Director sets this when it starts a search by itself
    Search.bands = build_bands(cue, opts)
    if #Search.bands == 0 then return false end
    Search.idx = 0
    sw = {
        started = now_seconds(),
        saved_type = State.pilot_requested_scan_type,
        saved_range = State.pilot_requested_range,
        known = {},
        aw_rev = Awacs.revision,
        gain_cfg = carried_cfg,
    }
    -- A knob still sitting at one of our gains from an earlier search is put back before this one starts.
    -- (Left where it is: band_gain sets this search's gain directly, or puts it back if the first band wants none.)
    -- Carrying over from an interrupted scan: keep the settings that were saved before it began.
    local carry = Search.carry
    if carry then
        sw.saved_type, sw.saved_range = carry.saved_type, carry.saved_range
        Search.carry = nil
    end
    -- Tracks the radar already has are not "found" by this search, so it can look for new groups. Except for a cue that
    -- stock has to hold (RWR / AWACS): a contact the radar list already has at the cue's position is what the search is
    -- for, so it is found as soon as it is painted again (see find_catch).
    sw.seed = {}
    local crng = cue_range(cue)
    for id, tr in pairs(Picture.tracks) do
        if Cues.IsKnownTrack(tr) then
            local at_cue = Config.CUE_NEEDS_HELD and Config.CUE_NEEDS_HELD[cue.source] and tr.az_deg
                and math.abs(tr.az_deg - cue_az(cue)) <= Config.SEARCH_AZ_TOLERANCE + (cue.spread or 0)
                and (not crng or not tr.range_nm or math.abs(tr.range_nm - crng) <= 10)
            if at_cue then sw.seed[id] = true else sw.known[id] = true end
        end
    end
    State.pilot_requested_scan_type = rcfg.scan_type.narrow
    -- A cursor cue keeps the pilot's display range, so the cursor stays where it was put.
    if cue.source ~= 'CURSOR' then
        State.pilot_requested_range = range_setting(rcfg, cue_range(cue) or Config.SEARCH_RANGE_NM)
    end
    Search.phase = 'sweeping'
    AADLog.Info('search: start %s az=%d, %d bands, %s first%s', cue.key, math.floor(cue.az + 0.5), #Search.bands,
        Search.bands[2] and Search.bands[2].angle < 0 and 'down' or 'up',
        (cue.count or 1) > 1 and (', ' .. cue.count .. ' emitters') or '')
    return true
end

local function finalize(reason, say_return, cooldown)
    local State, _, rcfg = stock()
    local handed = type(reason) == 'string' and (reason:find('^handover') or reason == 'called out' or reason == 'hold timeout')
    local tg = sw.gain_cfg and sw.gain_cfg.target
    local keepable = tg and (((tg == Config.SEARCH_UP_GAIN or tg == Config.SEARCH_UNKNOWN_GAIN) and not sw.up_gain_blocked)
        or tg == Config.SEARCH_DOWN_GAIN)
    if Config.SEARCH_UP_GAIN_HOLD ~= false and keepable and ((handed and Search.found) or reason == 'preempted') then
        -- Keep the look-up gain while the contact is being worked (see GainHoldUpdate).
        local now = now_seconds()
        gh = { cfg = sw.gain_cfg, born = now, id = Search.found and Search.found.id or nil, last_seen = now }
        sw.gain_cfg = nil
        AADLog.Info('search: keeping gain %.2f while the contact is held (%s)', tg, reason)
    else
        restore_gain(reason)
    end
    if sw.saved_type then State.pilot_requested_scan_type = sw.saved_type end
    if sw.saved_autofocus ~= nil then State.is_auto_focus_allowed = sw.saved_autofocus end
    if sw.saved_range then State.pilot_requested_range = sw.saved_range end
    if State.pilot_requested_scan_zone and State.pilot_requested_scan_zone.name == 'AAD_SEARCH' then
        State.pilot_requested_scan_zone = nil
    end
    -- Do not let stock sit in the search zone for its 90 s manual-zone timeout.
    State.max_scan_time_for_zone_no_bandits = rcfg.MAX_ZONE_SCAN_TIME
    if say_return then
        pcall(function() GetJester():AddTask(Task:new():Say('radar/returningtoscan')) end)
    end
    if Search.cue then Search.cue.cooldown_until = now_seconds() + (cooldown or Config.CUE_COOLDOWN_S) end
    AADLog.Info('search: end (%s) after %.1f s', reason, now_seconds() - (sw.started or 0))
    Search.phase = 'idle'
    Search.cue = nil
    Search.bands = nil
    sw = {}
end

function Search.Stop(reason)
    if Search.phase == 'idle' then return end
    finalize(reason, false)
end

-- The pilot overrode the search: stop, and stay quiet for a while.
function Search.PilotOverride(reason)
    if Search.phase == 'idle' then return end
    Cues.suppress_until = now_seconds() + Config.PILOT_OVERRIDE_S
    finalize(reason, false, Config.PILOT_OVERRIDE_S)
end

local function apply_band()
    local State, _, rcfg = stock()
    local b = Search.bands[Search.idx]
    State.pilot_requested_scan_zone = {
        name = 'AAD_SEARCH', range = NM(b.range), altitude = ft(b.altitude), is_relative = b.relative,
    }
    State.current_phase = rcfg.phase.PREPARE_SCAN_PATTERN
    sw.band_started = now_seconds()
    local mlc = 'n/a'
    band_gain(b)
    pcall(function() mlc = tostring(GetRadarMlcRange()) end)
    AADLog.Info('search: band %d/%d %+.1f deg (range %d NM alt %d ft) mlc=%s knob=%s', Search.idx, #Search.bands, b.angle or 0,
        b.range, b.altitude, mlc, tostring(get_gain()))
end

-- A track that is being painted near the cue but has not yet had the two hits that make it a track (a faint contact
-- paints once per pass): worth staying on this bar a little longer for the second hit.
local function candidate_track()
    local cue = Search.cue
    for id, tr in pairs(Picture.tracks) do
        if not sw.known[id] and tr.present and (tr.age or 99) <= 1.5 and (tr.hits or 0) >= 1
            and tr.az_deg and tr.ident ~= RadarTargetIdentification.FRIENDLY and not Cues.IsKnownTrack(tr)
            and math.abs(tr.az_deg - cue_az(cue)) <= Config.SEARCH_AZ_TOLERANCE + (cue.spread or 0)
            and (not (cue.range_nm and tr.range_nm) or math.abs(tr.range_nm - cue.range_nm) <= 12) then
            return tr
        end
    end
    return nil
end

local function find_catch()
    local cue = Search.cue
    local now = now_seconds()
    for id, tr in pairs(Picture.tracks) do
        -- A seeded track (already on the list when the search began) counts only when it is being painted right now.
        local fresh = not (sw.seed and sw.seed[id]) or (tr.present and (tr.age or 99) <= 4)
        local known = Cues.IsKnownTrack(tr)
        local near = (cue.target_id and id == cue.target_id)
            or (tr.az_deg and math.abs(tr.az_deg - cue_az(cue)) <= Config.SEARCH_AZ_TOLERANCE + (cue.spread or 0))
        if known and not sw.known[id] and fresh and near then
            return tr
        end
    end
    return nil
end

-- True while the cue still has more emitters than radar tracks and resumes remain.
local function more_emitters_pending()
    local cue = Search.cue
    return cue ~= nil and cue.source ~= 'CURSOR' and Cues.list[cue.key] == cue and (cue.count or 1) > math.max(#Cues.TracksNear(cue, true), 1)
        and (sw.resumes or 0) < Config.SEARCH_RESUMES
end

-- Should the search give way to stock? A lock, focus, or a highlight the pilot asked for always wins.
-- A highlight stock made by itself (after a call-out) is cleared while the cue still has unmatched
-- emitters, so the sweep can go on looking for the next group.
local function must_hand_over(State)
    if State.target_to_lock or State.target_currently_locked then return 'handover: lock' end
    if State.target_to_focus_on then
        if not sw.focus_logged then
            sw.focus_logged = true
            local n = 0
            for _, tr in pairs(Picture.tracks) do if Cues.IsKnownTrack(tr) then n = n + 1 end end
            AADLog.Info('search: focus seen: target %s, pilot_requested=%s, auto_focus_allowed=%s, tracks=%d, cue count=%s',
                tostring(State.target_to_focus_on.id), tostring(State.pilot_requested_target_to_highlight ~= nil),
                tostring(State.is_auto_focus_allowed), n, tostring(Search.cue and Search.cue.count))
        end
        return 'handover: focus'
    end
    if State.pilot_requested_target_to_highlight then return 'handover: pilot highlight' end
    if State.target_to_highlight then
        if more_emitters_pending() then
            State.target_to_highlight = nil
            if not sw.hl_logged then
                sw.hl_logged = true
                AADLog.Info('search: stock highlight cleared, more emitters than tracks')
            end
            return nil
        end
        return 'handover: highlight'
    end
    return nil
end

-- Stock focuses (and so stops scanning for anything else) any bandit closer than 30 NM. While the
-- cue still has more emitters than tracks, hold that off, unless the nearest group is already close.
local function manage_auto_focus(State)
    if not Config.SEARCH_HOLD_AUTOFOCUS then return end
    local suppress = false
    -- A search the pilot started (context press) is held against stock's auto-focus whatever the cue: with a single-emitter
    -- cue nothing was pending, stock refocused the nearest bandit within 0.1 s and the press never got past it (test 8, Oct 2026).
    local pilot_search = Search.auto == false and Search.phase ~= 'idle'
    if pilot_search or more_emitters_pending() then
        local nearest = 1e9
        for _, tr in pairs(Picture.tracks) do
            if Cues.IsKnownTrack(tr) and tr.range_nm then
                nearest = math.min(nearest, tr.range_nm)
            end
        end
        suppress = pilot_search or nearest >= Config.SEARCH_AUTOFOCUS_FLOOR_NM
        -- Do not hold stock off for longer than the cap, however the sweep is going.
        if suppress and sw.saved_autofocus ~= nil and sw.hold_since
            and now_seconds() - sw.hold_since > Config.SEARCH_AUTOFOCUS_MAX_S then
            suppress = false
            sw.hold_expired = true
        end
        if sw.hold_expired then suppress = false end
    end
    if suppress then
        if sw.saved_autofocus == nil then
            sw.saved_autofocus = State.is_auto_focus_allowed
            sw.hold_since = sw.hold_since or now_seconds()
            AADLog.Info('search: auto-focus held off while looking for more groups')
        end
        State.is_auto_focus_allowed = false
    elseif sw.saved_autofocus ~= nil then
        State.is_auto_focus_allowed = sw.saved_autofocus
        sw.saved_autofocus = nil
        AADLog.Info('search: auto-focus restored')
    end
end

-- Where a contact is now: its last measured bearing and range carried forward by its fitted bearing drift and
-- closure for the time since that measurement, at most EXTRAP_MAX_S (a contact that left the scope must not drag
-- the cursor away). Needs the 3+ samples the fit uses; without them the measured position is returned.
local function extrapolated(tr, max_dt)
    local az, rng = tr.az_deg, tr.range_nm
    local sm = tr.samples
    local last = sm and sm[#sm]
    if not last or #sm < 3 then return az, rng, 0 end
    local dt = math.min(math.max(now_seconds() - last.t, 0), max_dt or Config.EXTRAP_MAX_S or 10)
    if dt <= 0 then return az, rng, 0 end
    local d, c = tr.drift, tr.closure_kt
    if az and d and math.abs(d) <= 2 then az = az + d * dt end
    if rng and c and c > 0 and c < 1500 then rng = math.max(1, rng - c / 3600 * dt) end
    return az, rng, dt
end

-- Focus the contact this search found, the way a short press of the context button would (stock's own next-bandit
-- pick, which also covers a contact that is between paints). Stock only does this by itself inside about 30 NM.
local function focus_found(State, Api)
    if Config.SEARCH_FOCUS_FOUND == false or not Search.found then return false end
    local function why() return false end
    if State.target_to_focus_on then return why('stock already has a focus on ' .. tostring(tid(State.target_to_focus_on))) end
    if State.target_currently_locked then return why('locked on ' .. tostring(tid(State.target_currently_locked))) end
    local id = Search.found.id
    local tgt
    local bid
    pcall(function()
        local b = Api.GetNextBanditOrNil(nil)
        bid = b and b.id
        if b and b.id == id then tgt = b end
    end)
    local rt
    if not tgt then pcall(function() rt = radar_targets and radar_targets[id] tgt = rt end) end
    if not tgt then return why(string.format('no stock target object (next bandit %s, radar_targets entry %s)', tostring(bid), tostring(rt ~= nil))) end
    State.target_to_highlight = tgt
    State.target_to_focus_on = tgt
    -- Stock drops a focus it did not get from the pilot (the log showed it gone within a second): mark this one as
    -- pilot-requested, the way the context button does, so it stays until the pilot or a lock changes it.
    State.pilot_requested_target_to_highlight = tgt
    AADLog.Info('search: focusing the contact found at %.0f NM (stock would not at this range)', Search.found.range_nm or 0)
    return true
end

-- Called at the top of Radar.FindNextPhase, when the radar's task queue is idle.
function Search.Step()
    if Search.phase == 'idle' then return end
    local State, Api, rcfg = stock()
    local now = now_seconds()

    if Engagement.state == Engagement.BFM then return Search.Stop('bfm') end
    local why = must_hand_over(State)
    if why then return Search.Stop(why) end
    manage_auto_focus(State)
    -- The cue has swung outside what the radar can look at (the pilot turned away): stop, and
    -- let it start again once it is back in the forward arc.
    if math.abs(cue_az(Search.cue)) > Config.CUE_MAX_AZ then
        return finalize('out of coverage', false, 0)
    end
    local z = State.pilot_requested_scan_zone
    if z and z.name ~= 'AAD_SEARCH' then return Search.Stop('pilot zone') end

    if Search.phase == 'holding' then
        -- Keep the knob where the search put it while the contact is held, as the sweep does (stock's auto-gain or a
        -- queued click can pull it off, and the useful window is only a few hundredths wide).
        if sw.gain_cfg and sw.gain_cfg.target and now - (sw.gain_fix_t or -9) > 1.5 and (sw.gain_fixes or 0) < 15 then
            local kv = get_gain()
            if kv and math.abs(kv - sw.gain_cfg.target) > 0.04 then
                sw.gain_fix_t = now
                sw.gain_fixes = (sw.gain_fixes or 0) + 1
                AADLog.Info('search: knob reads %.2f, wanted %.2f while the contact is held: turning it again (%d)', kv, sw.gain_cfg.target, sw.gain_fixes)
                set_gain(sw.gain_cfg.target)
            end
        end
        -- A contact found on a bar well away from its real elevation (the beam only grazes it) is lost as soon as the
        -- search hands over: stock does not re-aim the antenna at a focused contact. Point the beam at the contact's
        -- own elevation (from its reported altitude) and wait for a fresh paint before handing over.
        if Search.found and not sw.recentre_done then
            sw.recentre_done = true
            local tr0 = Picture.tracks[Search.found.id] or Search.found
            local own0 = own_altitude_ft()
            local b0 = Search.bands and Search.bands[math.max(Search.idx, 1)]
            if tr0 and tr0.alt_ft and tr0.range_nm and own0 and b0 then
                local elev0 = math.deg(math.atan2(tr0.alt_ft - own0, math.max(tr0.range_nm, 1) * 6076.12))
                elev0 = math.max(-10, math.min(17.5, elev0))
                if math.abs(elev0 - (b0.angle or 0)) >= (Config.SEARCH_RECENTER_DEG or 1.5) then
                    State.pilot_requested_scan_zone = {
                        name = 'AAD_SEARCH', range = NM(b0.range), altitude = ft(math.tan(math.rad(elev0)) * b0.range * 6076.12),
                        is_relative = true,
                    }
                    State.current_phase = rcfg.phase.PREPARE_SCAN_PATTERN
                    sw.recentred_at = now
                    AADLog.Info('search: contact found on the %+.1f deg bar is at %+.1f deg (%d ft at %.0f NM): aiming the beam at it before the handover',
                        b0.angle or 0, elev0, math.floor(tr0.alt_ft), tr0.range_nm)
                    return
                end
            end
        end
        if sw.recentred_at then
            local trr = Search.found and Picture.tracks[Search.found.id]
            local fresh = trr and trr.present and (trr.age or 99) <= 1.5 and now - sw.recentred_at >= 1.0
            if not fresh and now - sw.recentred_at < (Config.SEARCH_RECENTER_HOLD_S or 3.5) then return end
            if fresh and not sw.recentre_logged then
                sw.recentre_logged = true
                AADLog.Info('search: contact painted on its own elevation after %.1f s', now - sw.recentred_at)
            end
        end
        local called_out = Search.found and State.processed_targets[Search.found.id] ~= nil
        -- A long hold (beam kept on the contact, focus at SEARCH_FOCUS_HITS or on the call-out) for a contact beyond
        -- STOCK_FOCUS_NM, and for one that has not painted enough yet (7b: a one-hit find at 25 NM was dropped after 8 s).
        if sw.far == nil and Search.found then
            local t0 = Picture.tracks[Search.found.id]
            sw.far = (Search.found.range_nm or 0) > (Config.SEARCH_HOLD_LONG_NM or 20)
                or not (t0 and t0.present and (t0.hits or 0) >= (Config.SEARCH_FOCUS_HITS or 5))
        end
        local far = sw.far == true
        local hold_s = far and (Config.SEARCH_HOLD_FAR_S or 60) or Config.SEARCH_HOLD_S
        if far and not called_out then
            if Search.cue and Search.cue.expires < now + 10 then Search.cue.expires = now + 10 end
            -- Stock does not focus a contact this far out by itself. Keep the beam on it, following it in as it closes,
            -- until stock calls it out and focuses it (the search then hands over); no focus is forced before the timeout.
            local trs = Picture.tracks[Search.found.id]
            -- Painted steadily already (several hits, on the scope now): focus it without waiting for stock's call-out,
            -- so the cursor moves first and stock's report follows. A contact that paints rarely waits as before.
            if trs and trs.present and (trs.age or 99) <= 1.5 and (trs.max_hits or trs.hits or 0) >= (Config.SEARCH_FOCUS_HITS or 5)
                and focus_found(State, Api) then
                AADLog.Info('search: contact has %d hits: focusing it ahead of the call-out', trs.max_hits or trs.hits or 0)
                return finalize('handover: focus (found)', false)
            end
            if trs and trs.alt_ft and trs.range_nm then
                local own2 = own_altitude_ft()
                if own2 then
                    local _, xr = extrapolated(trs)
                    xr = xr or trs.range_nm
                    local elev2 = math.max(-10, math.min(17.5, math.deg(math.atan2(trs.alt_ft - own2, math.max(xr, 1) * 6076.12))))
                    local rng2 = math.max(10, math.ceil(xr + 3))
                    if not sw.far_el or math.abs(elev2 - sw.far_el) >= 0.7 or math.abs(rng2 - (sw.far_rng or rng2)) >= 3 then
                        State.pilot_requested_scan_zone = {
                            name = 'AAD_SEARCH', range = NM(rng2), altitude = ft(math.tan(math.rad(elev2)) * rng2 * 6076.12),
                            is_relative = true,
                        }
                        State.current_phase = rcfg.phase.PREPARE_SCAN_PATTERN
                        AADLog.Info('search: holding the beam on the contact at %+.1f deg (%d ft at %.0f NM) until stock calls it out',
                            elev2, math.floor(trs.alt_ft), trs.range_nm)
                        sw.far_el, sw.far_rng = elev2, rng2
                    end
                end
            end
        end
        if called_out or now - sw.found_at > hold_s then
            local cue = Search.cue
            -- More emitters on this bearing than tracks: keep looking in the other bands.
            if cue and cue.source ~= 'CURSOR' and Cues.list[cue.key] == cue and (cue.count or 1) > #Cues.TracksNear(cue, true)
                and (sw.resumes or 0) < Config.SEARCH_RESUMES then
                sw.resumes = (sw.resumes or 0) + 1
                sw.known[Search.found.id] = true
                sw.skip_band = Search.idx
                Search.found = nil
                Search.phase = 'sweeping'
                Search.idx = 0
                AADLog.Info('search: group found, %d emitter(s) not matched yet, resuming', (cue.count or 1) - math.max(#Cues.TracksNear(cue, true), 1))
                return
            end
            -- Stock focuses a called-out contact only inside STOCK_FOCUS_NM: one it called out farther out is focused here.
            local ftr = Search.found and Picture.tracks[Search.found.id]
            local called_far = called_out and ((ftr and ftr.range_nm) or (Search.found and Search.found.range_nm) or 0) > (Config.STOCK_FOCUS_NM or 30)
            if (not called_out or called_far) and focus_found(State, Api) then
                if called_far then AADLog.Info('search: stock called the contact out at %.0f NM but does not focus beyond %d NM: focusing it',
                    (ftr and ftr.range_nm) or 0, Config.STOCK_FOCUS_NM or 30) end
                return finalize('handover: focus (found)', false)
            end
            return finalize(called_out and 'called out' or 'hold timeout', false)
        end
        return
    end

    -- Keep the cue alive while we are working on it.
    if Search.cue.expires < now + 10 then Search.cue.expires = now + 10 end

    local tr = find_catch()
    if not tr and Cues.list[Search.cue.key] ~= Search.cue then
        -- The cue ended: the radar painted the contact it was about.
        tr = Cues.TrackFor(Search.cue)
    end
    if tr then
        Search.found = tr
        sw.found_at = now
        Picture.AddBoost(tr.id, Config.W.CUE, Config.CUE_TTL)
        AADLog.Info('search: found id=%s az=%d range=%.0f NM', tostring(tr.id), math.floor((tr.az_deg or 0) + 0.5), tr.range_nm or 0)
        Search.phase = 'holding'
        return
    end

    -- A contact the AWACS / EWRS reports after the search began: take its range, bearing and elevation now.
    -- When the search already has one and the new report puts it a band or more away, re-center on it.
    if Awacs.revision ~= sw.aw_rev then
        sw.aw_rev = Awacs.revision
        local cue = Search.cue
        if cue and Search.idx >= 1 then
            local okr, er = pcall(Awacs.Elevation, cue, true)
            local max_el = Config.AWACS_MAX_ELEV_DEG or (Config.SEARCH_UP_STEPS * Config.SEARCH_STEP_DEG)
            local replan = false
            if okr and er then
                if er > max_el then
                    AADLog.Info('search: contact now at %+.1f deg, above the scan limit (%.1f): stopping, left to stock', er, max_el)
                    cue.cooldown_until = now + (Config.CUE_COOLDOWN_S or 20)
                    return Search.Stop('contact above scan limit')
                end
                if not cue.aw_used then
                    replan = true
                elseif cue.aw_center and math.abs(er - cue.aw_center) >= (Config.AWACS_RECENTER_DEG or Config.AWACS_STEP_DEG or 3.0) then
                    replan = true
                end
            end
            if replan then
                local saved_idx = Search.idx
                local was_center = cue.aw_center
                local nb = build_bands(cue, nil)
                if cue.aw_used and #nb > 0 then
                    Search.bands = nb
                    Search.idx = 0
                    local State2, _, rcfg2 = stock()
                    if cue.source ~= 'CURSOR' and cue_range(cue) then
                        State2.pilot_requested_range = range_setting(rcfg2, cue_range(cue))
                    end
                    AADLog.Info('search: contact report during band %d: %s, %d bands, center %+.1f deg, range %s NM, az %d', saved_idx,
                        was_center and string.format('re-centred from %+.1f', was_center) or 'contact adopted', #nb, cue.aw_center or 0,
                        tostring(cue_range(cue) and math.floor(cue_range(cue) + 0.5)), math.floor(cue_az(cue) + 0.5))
                    return
                end
            end
        end
    end
    if Search.idx == 0 then
        Search.idx = (sw.skip_band == 1) and 2 or 1
        return apply_band()
    end
    if State.current_phase == nil then
        -- Something called State.Reset(): a pilot command (context-button double press, a wheel
        -- action) or the radar being switched off. Either way, let go.
        return Search.PilotOverride('reset')
    end
    -- The higher look-up gain is for clear sky. With the beam on the ground at (or beyond) the contact's range - a
    -- mountain behind it - the extra gain only lifts the clutter, so go back to stock for the rest of this search.
    if sw.gain_cfg and sw.gain_cfg.target == Config.SEARCH_UP_GAIN and not sw.up_gain_blocked and now - sw.band_started > 1.0 then
        local bnd = Search.bands and Search.bands[Search.idx]
        local m = mlc_nm()
        -- Only with a contact range to compare against: a bearing-only (RWR) search scans out to the band range,
        -- and the ground somewhere inside that says nothing about clutter behind a contact whose range is unknown.
        local rng = Search.cue and cue_range(Search.cue)
        if m and rng and m >= rng * (Config.SEARCH_UP_GAIN_CLUTTER_FRAC or 0.6) then
            sw.up_gain_blocked = true
            AADLog.Info('search: beam meets the ground at %.0f NM (contact range %d NM): clutter behind the contact, look-up gain off', m, rng)
            restore_gain('ground clutter behind the contact')
        end
    end
    -- Keep the knob where the search put it. Stock, or a click queued by an earlier restore, can pull it back after
    -- the one click we made when the band's gain was chosen (the log showed the knob back at 0.59 for a whole search).
    if sw.gain_cfg and sw.gain_cfg.target and now - (sw.gain_fix_t or -9) > 1.5 and (sw.gain_fixes or 0) < 15 then
        local kv = get_gain()
        if kv and math.abs(kv - sw.gain_cfg.target) > 0.04 then
            sw.gain_fix_t = now
            sw.gain_fixes = (sw.gain_fixes or 0) + 1
            AADLog.Info('search: knob reads %.2f, wanted %.2f: turning it again (%d)', kv, sw.gain_cfg.target, sw.gain_fixes)
            set_gain(sw.gain_cfg.target)
        end
    end
    if sw.gain_cfg and not sw.gain_logged and now - sw.band_started > 1.5 then
        sw.gain_logged = true
        AADLog.Info('search: knob reads %s on the look-down band', tostring(get_gain()))
    end
    local cur = Search.bands[Search.idx]
    local dwell = (cur and cur.dwell) or Config.SEARCH_DWELL
    sw.cand_bonus = sw.cand_bonus or {}
    if now - sw.band_started >= dwell and not sw.cand_bonus[Search.idx] then
        local cand = candidate_track()
        if cand then
            sw.cand_bonus[Search.idx] = true
            dwell = dwell + (Config.SEARCH_CANDIDATE_HOLD_S or 3)
            local own1 = own_altitude_ft()
            local aimed = false
            if cand.alt_ft and cand.range_nm and own1 and cur then
                local elev1 = math.deg(math.atan2(cand.alt_ft - own1, math.max(cand.range_nm, 1) * 6076.12))
                elev1 = math.max(-10, math.min(17.5, elev1))
                if math.abs(elev1 - (cur.angle or 0)) >= (Config.SEARCH_RECENTER_DEG or 1.5) then
                    -- Painted once on a bar that only grazes it: point the beam at the elevation its altitude implies.
                    State.pilot_requested_scan_zone = {
                        name = 'AAD_SEARCH', range = NM(cur.range), altitude = ft(math.tan(math.rad(elev1)) * cur.range * 6076.12),
                        is_relative = true,
                    }
                    State.current_phase = rcfg.phase.PREPARE_SCAN_PATTERN
                    sw.band_started = now
                    sw.cand_id, sw.cand_el, sw.cand_rng = cand.id, elev1, cur.range
                    aimed = true
                    AADLog.Info('search: %s painted once on the %+.1f deg bar, its altitude puts it at %+.1f deg (%d ft at %.0f NM): aiming the beam at it for a second hit',
                        tostring(cand.id), cur.angle or 0, elev1, math.floor(cand.alt_ft), cand.range_nm)
                end
            end
            if not aimed then
                AADLog.Info('search: %s painted once (%s hit) on the %+.1f deg bar: staying on it up to %.0f s for a second hit',
                    tostring(cand.id), tostring(cand.hits), cur and cur.angle or 0, Config.SEARCH_CANDIDATE_HOLD_S or 3)
            end
        end
    elseif sw.cand_bonus[Search.idx] then
        dwell = dwell + (Config.SEARCH_CANDIDATE_HOLD_S or 3)
        -- Follow the one-hit contact's elevation as it closes while the beam is held on it.
        local ct = sw.cand_id and Picture.tracks[sw.cand_id]
        local own3 = own_altitude_ft()
        if ct and ct.alt_ft and ct.range_nm and own3 and sw.cand_el then
            local el3 = math.max(-10, math.min(17.5, math.deg(math.atan2(ct.alt_ft - own3, math.max(ct.range_nm, 1) * 6076.12))))
            local rg3 = math.max(10, math.ceil(ct.range_nm + 3))
            if math.abs(el3 - sw.cand_el) >= 0.7 or math.abs(rg3 - (sw.cand_rng or rg3)) >= 3 then
                State.pilot_requested_scan_zone = {
                    name = 'AAD_SEARCH', range = NM(rg3), altitude = ft(math.tan(math.rad(el3)) * rg3 * 6076.12), is_relative = true,
                }
                State.current_phase = rcfg.phase.PREPARE_SCAN_PATTERN
                AADLog.Info('search: following the one-hit contact to %+.1f deg (%d ft at %.0f NM)', el3, math.floor(ct.alt_ft), ct.range_nm)
                sw.cand_el, sw.cand_rng = el3, rg3
            end
        end
    end
    if now - sw.band_started >= dwell then
        if Search.idx < #Search.bands then
            Search.idx = Search.idx + 1
            if Search.idx == sw.skip_band then
                if Search.idx >= #Search.bands then return finalize('timeout', true) end
                Search.idx = Search.idx + 1
            end
            return apply_band()
        end
        if now - sw.band_started >= dwell + Config.SEARCH_TIMEOUT then
            return finalize('timeout', true)
        end
    end
end

-- Called after Radar.UpdateTargetHighlight: keep the cursor on the cue instead of recentering it.
function Search.HoldCursor()
    if Search.phase == 'idle' then
        if Search.prep then
            Search.PrepCursor()
        elseif Search.postlock and Search.postlock.lead_until and now_seconds() < Search.postlock.lead_until then
            pcall(Search.LeadCursor, Search.postlock.id, false)
        end
        return
    end
    local State = stock()
    local why = must_hand_over(State)
    if why then return Search.Stop(why) end
    -- PILOT mode: the cursor is the pilot's. Jester never moves it during a scan (Modes.CursorGate).
    if Search.pilot_owns_cursor then return end
    -- Pilot override: the cursor is not moving but is away from where we want it, so something
    -- else (the pilot's stick) is holding it. Give up after a moment.
    local MoveRadarCursor = require('radar.MoveRadarCursor')
    local mc = GetJester().behaviors[MoveRadarCursor]
    local away = false
    if mc and mc.is_active and sw.band_started then
        local cx, cy = mc.current_cursor_x, mc.current_cursor_y
        if mc.is_cursor_moving or not cx then
            sw.settled = nil
            sw.away_since = nil
        elseif not sw.settled then
            sw.settled = { x = cx, y = cy }
        else
            local d = math.max(math.abs(cx - sw.settled.x), math.abs(cy - sw.settled.y))
            if d > Config.PILOT_SLEW_DIFF then
                away = true
                sw.away_since = sw.away_since or now_seconds()
                if now_seconds() - sw.away_since > 1.5 then
                    AADLog.Info('search: pilot slew moved=%.3f cur=(%.2f,%.2f) was=(%.2f,%.2f)', d, cx, cy, sw.settled.x, sw.settled.y)
                    return Search.PilotOverride('pilot slew')
                end
            else
                sw.away_since = nil
            end
        end
    end
    if away then return end
    local b = Search.bands and Search.bands[math.max(Search.idx, 1)]
    local rng = cue_range(Search.cue) or (b and b.range) or Config.SEARCH_RANGE_NM
    local az = cue_az(Search.cue)
    -- Holding on a found contact: the narrow scan follows the cursor, so put the cursor on the contact's own last
    -- measured bearing and range, not on the cue (the cue's bearing lags a closing contact; 7b: B at -40, cursor at -30).
    if Search.phase == 'holding' and Search.found then
        local ht = Picture.tracks[Search.found.id]
        if ht and ht.az_deg then
            local xa, xr, dt = extrapolated(ht)
            az = xa
            rng = xr or rng
            if dt > 0 and now_seconds() - (sw.extrap_log or -1e9) >= 3 then
                sw.extrap_log = now_seconds()
                AADLog.Info('search: cursor on the extrapolated contact position az %.0f rng %.0f (measured %.0f / %.0f, %.1f s old)',
                    xa, xr or 0, ht.az_deg, ht.range_nm or 0, dt)
            end
        end
    end
    -- Sweeping: a radar track near the cue that painted a moment ago is the contact itself, and its measured bearing is
    -- better than the cue's (stock's BRAA lags a closing contact by 7-10 deg: 7b, B at -43, cue at -33, the narrow scan
    -- missing it). Steer the cursor there; the beam elevation is still the band's.
    if Search.phase == 'sweeping' and Search.cue and Search.cue.source ~= 'CURSOR' then
        local now2, best, bt = now_seconds(), nil, nil
        local cz = cue_az(Search.cue)
        for id, tr in pairs(Picture.tracks) do
            if not sw.known[id] and tr.az_deg and tr.last_seen and now2 - tr.last_seen <= (Config.SEARCH_STALE_TRACK_S or 12)
                and tr.ident ~= RadarTargetIdentification.FRIENDLY
                and math.abs(tr.az_deg - cz) <= Config.SEARCH_AZ_TOLERANCE + (Search.cue.spread or 0)
                and (not (Search.cue.range_nm and tr.range_nm) or math.abs(tr.range_nm - Search.cue.range_nm) <= 12)
                and (not bt or tr.last_seen > bt) then
                best, bt = tr, tr.last_seen
            end
        end
        if best then
            if not sw.az_steer_logged then
                sw.az_steer_logged = true
                AADLog.Info('search: steering the cursor to the contact\'s own bearing %.0f (cue %.0f)', best.az_deg, cz)
            end
            local xa = extrapolated(best)
            az = xa or best.az_deg
        end
    end
    az = math.max(-Config.CUE_MAX_AZ, math.min(Config.CUE_MAX_AZ, az))
    if mc then mc:MoveCursorTo(deg(az), NM(rng)) end
end

-- Short press of the context button in the scan state. Returns true when it was used here.
--   searching          -> switch to the next cue
--   nothing to cycle   -> start a search on the best cue now
-- Otherwise stock keeps the press (cycling bandits on the scope).
function Search.ContextShort(task)
    local State, Api = stock()
    -- While the pilot steps, the Director starts no search of its own (it would steer the cursor away from the press).
    Cues.suppress_until = now_seconds() + (Config.STEP_FREEZE_S or 6)
    if Search.phase == 'sweeping' then
        local nxt = Cues.NextAfter(Search.cue)
        if not nxt then
            task:CantDo()
            return true
        end
        Search.Stop('next cue')
        if Search.Start(nxt) then task:Roger() else task:CantDo() end
        return true
    end
    if Search.phase == 'idle' then
        -- Stock steps through the bandits (left to right and back, Fixes Bug 3); a press only ever moves to the
        -- neighboring contact, also at the ends of the sweep (test 9, Oct 2026: a cue search started from an end
        -- ended on a contact further along and the neighbor was skipped). With no bandit on the scope the press
        -- starts a search on the next cue.
        local hl = State.target_to_highlight
        local bandit = Api.GetNextBanditOrNil(hl)
        local cue
        if bandit then
            AADLog.Info('context short: stock cycles bandits (highlight %s, next %s)', tostring(hl and hl.id), tostring(bandit.id))
            return false
        else
            cue = Cues.NextAfter(nil)
            if not cue then return false end
        end
        cue.cooldown_until = 0
        -- Let go of the highlighted or focused bandit so the search can run; put it back if it cannot.
        local saved = { State.target_to_highlight, State.target_to_focus_on, State.pilot_requested_target_to_highlight }
        State.target_to_highlight, State.target_to_focus_on, State.pilot_requested_target_to_highlight = nil, nil, nil
        if Search.Start(cue) then
            manage_auto_focus(State)
            AADLog.Info('search: started by the pilot, focus released')
            task:Roger()
            return true
        end
        State.target_to_highlight, State.target_to_focus_on, State.pilot_requested_target_to_highlight =
            saved[1], saved[2], saved[3]
    end
    return false
end

-- Look-down lock preparation (DESIGN.md, "Lock preparation").
-- A long press of the context button on a contact below the horizon does not lock at once: a lock taken with the
-- contact in ground clutter can land on the ground. Jester keeps the focus, lowers the gain a step at a time while the
-- contact paints steadily (less clutter around it) and raises it when the paint is lost; while it is lost the cursor
-- and the beam elevation are carried forward on the contact's extrapolated position. When the paint is steady and the
-- beam's ground intercept is well behind the contact (or the paint has been steady LOCKPREP_STEADY_MAX_S), the
-- stock long-press action is run, so the lock itself is stock's.
local function prep_elev_deg(tr)
    local own = own_altitude_ft()
    if not (own and tr and tr.alt_ft and tr.range_nm) then return nil end
    return math.deg(math.atan2(tr.alt_ft - own, math.max(tr.range_nm, 1) * 6076.12))
end

-- Paints of the track: age of the newest one and how many fall inside the steady window.
local function prep_paint(tr, now)
    local sm = tr.samples or {}
    local last = sm[#sm]
    local age = last and (now - last.t) or 1e9
    local n = 0
    for i = #sm, 1, -1 do
        if now - sm[i].t <= (Config.LOCKPREP_STEADY_WINDOW_S or 6) then n = n + 1 else break end
    end
    return age, n
end

local function prep_clear_zone(p)
    if not p.zone_set then return end
    p.zone_set = false
    pcall(function()
        local St = stock()
        if St.pilot_requested_scan_zone and St.pilot_requested_scan_zone.name == 'AAD_SEARCH' then
            St.pilot_requested_scan_zone = nil
        end
    end)
end

-- Put the cursor where the contact will be about LOCKPREP_LEAD_S from now: the contact closes at several hundred knots (0.2 NM/s),
-- a lock takes about a second to complete and the last paint is 1-3 s old, so the cursor at the last paint is behind the contact.
-- Used just before the lock is fired and for LOCKPREP_LOCK_HOLD_S after it.
local function lead_cursor(id, log)
    if Search.pilot_owns_cursor then return end
    local tr = Picture.tracks[id]
    if not tr or not tr.az_deg then return end
    local xa, xr, xdt = extrapolated(tr, Config.LOCKPREP_EXTRAP_MAX_S)
    if not (xa and xr) then return end
    local lead = Config.LOCKPREP_LEAD_S or 1.0
    local xr0, xa0 = xr, xa
    if tr.closure_kt and tr.closure_kt > 0 and tr.closure_kt < 1500 then xr = math.max(1, xr - tr.closure_kt / 3600 * lead) end
    if tr.drift and math.abs(tr.drift) <= 2 then xa = xa + tr.drift * lead end
    xa = math.max(-Config.CUE_MAX_AZ, math.min(Config.CUE_MAX_AZ, xa))
    local MoveRadarCursor = require('radar.MoveRadarCursor')
    local mc = GetJester().behaviors[MoveRadarCursor]
    if not mc then return end
    if log then
        AADLog.Info('lockprep: cursor lead: contact measured az %.1f rng %.1f (%.1f s old) | extrapolated az %.1f rng %.1f | cursor sent to az %.1f rng %.1f (+%.1f s) | cursor now=(%s,%s) closure %s kt',
            tr.az_deg, tr.range_nm or -1, xdt or -1, xa0, xr0, xa, xr, lead,
            tostring(mc.current_cursor_x and string.format('%.3f', mc.current_cursor_x)), tostring(mc.current_cursor_y and string.format('%.3f', mc.current_cursor_y)),
            tr.closure_kt and string.format('%.0f', tr.closure_kt) or 'nil')
    end
    mc:MoveCursorTo(deg(xa), NM(xr))
end
Search.LeadCursor = lead_cursor

local function prep_end(why, lock)
    local p = Search.prep
    if not p then return end
    Search.prep = nil
    prep_clear_zone(p)
    AADLog.Info('lockprep: end (%s) at t=%.1f after %.1f s, gain %.2f, lock=%s',
        tostring(why), now_seconds(), now_seconds() - p.born, p.gain or -1, tostring(lock and true or false))
    if lock then
        pcall(lead_cursor, p.id, true)
        local ok, err = pcall(function()
            local t = Task:new()
            p.fire(t)
            GetJester():AddTask(t)
        end)
        if not ok then AADLog.Info('lockprep: lock failed: %s', tostring(err)) end
        Search.postlock = { id = p.id, until_t = now_seconds() + 8, next_t = 0, lead_until = now_seconds() + (Config.LOCKPREP_LOCK_HOLD_S or 3) }
    end
end

function Search.PrepCancel(why) prep_end(why, false) end
function Search.PrepFire(why) prep_end(why, true) end

-- Returns true when the long press was taken (the lock is prepared first); false leaves it to stock.
function Search.PrepBegin(fire)
    if Search.prep or Search.phase ~= 'idle' or Search.pilot_owns_cursor then return false end
    local ok, State = pcall(stock)
    if not ok or not State then return false end
    if State.target_currently_locked or State.target_to_lock then return false end
    local id = tid(State.target_to_focus_on or State.target_to_highlight)
    local tr = id and Picture.tracks[id]
    local el = prep_elev_deg(tr)
    if not el or el > -(Config.LOCKPREP_MIN_DEPR_DEG or 0.5) then return false end
    -- Paint already steady: nothing to wait for. Stock's own lock acts at once (silent start, the call follows the lock).
    do
        local age0, n0 = prep_paint(tr, now_seconds())
        if tr.present and age0 <= (Config.LOCKPREP_PAINT_AGE_S or 2.5) and n0 >= (Config.LOCKPREP_STEADY_HITS or 4) then
            AADLog.Info('lockprep: paint already steady on %s (%d hits, %.1f s old, %.1f NM): stock locks at once', tostring(id), n0, age0, tr.range_nm or -1)
            return false
        end
    end
    if not gh then start_follow_hold() end
    if not gh or not gh.cfg or not gh.cfg.target then return false end
    local now = now_seconds()
    gh.id, gh.last_seen = id, now
    Search.prep = { id = id, born = now, fire = fire, gain = gh.cfg.target, log_at = -1e9 }
    local mlc = mlc_nm()
    AADLog.Info('lockprep: start on %s: %.1f deg below, %.0f NM, mlc=%s, gain %.2f, paint hits=%s',
        tostring(id), -el, tr.range_nm or -1, mlc and string.format('%.1f', mlc) or 'none', gh.cfg.target, tostring(tr.hits))
    return true
end

function Search.PrepUpdate()
    local p = Search.prep
    if not p then return end
    local State = stock()
    local now = now_seconds()
    if State.target_currently_locked or State.target_to_lock then return prep_end('locked') end
    local tid_now = tid(State.target_to_focus_on or State.target_to_highlight)
    if not tid_now then
        -- Stock clears the focus and highlight for a moment when the paint is lost (seen 1.4 s into a prep, back a few seconds
        -- later): wait LOCKPREP_FOCUS_GRACE_S before giving up on it. The preparation carries on with the contact it started on.
        p.focus_gone_at = p.focus_gone_at or now
        if now - p.focus_gone_at > (Config.LOCKPREP_FOCUS_GRACE_S or 4) then
            return prep_end('focus gone')
        end
    else
        p.focus_gone_at = nil
        if tid_now ~= p.id then return prep_end('focus moved to ' .. tostring(tid_now)) end
    end
    if Search.phase ~= 'idle' then return prep_end('search started') end
    if not gh then return prep_end('gain hold released') end
    local tr = Picture.tracks[p.id]
    if not tr then return prep_end('track forgotten') end
    gh.id, gh.last_seen = p.id, now
    if now - p.born > (Config.LOCKPREP_MAX_S or 25) then
        -- No clean steady paint in time (flights 1 and 2: both timeout locks landed on the ground): do not lock. Jester says
        -- the lock is lost and stays on the contact; the pilot can press again.
        prep_end('time limit: no steady paint, not locking', false)
        pcall(function() GetJester():AddTask(Task:new():Say('radar/lostlock')) end)
        return
    end

    local age, n = prep_paint(tr, now)
    local painting = tr.present and age <= (Config.LOCKPREP_PAINT_AGE_S or 2.5)
    local steady = painting and n >= (Config.LOCKPREP_STEADY_HITS or 4)
    local mlc = mlc_nm()

    if steady then
        return prep_end(string.format('steady paint (%d hits in %ds, newest %.1f s old, range %.1f NM)', n, Config.LOCKPREP_STEADY_WINDOW_S or 6, age, tr.range_nm or -1), true)
    elseif painting then
        p.lost_since = nil   -- flickering: stock's own follow has the cursor
    else
        p.lost_since = p.lost_since or now
        local lost_s = now - p.lost_since
        -- Beam elevation on the extrapolated position (stock's focus zone stays where the contact vanished).
        if lost_s >= (Config.LOCKPREP_LOST_S or 1.5) then
            local own = own_altitude_ft()
            local _, xr = extrapolated(tr, Config.LOCKPREP_EXTRAP_MAX_S)
            if own and tr.alt_ft and xr then
                local el = math.max(-10, math.min(17.5, math.deg(math.atan2(tr.alt_ft - own, math.max(xr, 1) * 6076.12))))
                local rg = math.max(10, math.ceil(xr + 3))
                if not p.zone_el or math.abs(el - p.zone_el) >= (Config.LOCKPREP_ELEV_STEP_DEG or 0.3) or math.abs(rg - (p.zone_rg or rg)) >= 3 then
                    State.pilot_requested_scan_zone = {
                        name = 'AAD_SEARCH', range = NM(rg), altitude = ft(math.tan(math.rad(el)) * rg * 6076.12), is_relative = true,
                    }
                    local rc = require('radar.Config')
                    State.current_phase = rc.phase.PREPARE_SCAN_PATTERN
                    p.zone_set, p.zone_el, p.zone_rg = true, el, rg
                    AADLog.Info('lockprep: beam elevation -> %+.1f deg on the extrapolated position (%.0f NM)', el, xr)
                end
            end
        end
    end
    if now - p.log_at >= 2 then
        p.log_at = now
        AADLog.Info('lockprep: %s hits=%d/6s age=%.1f gain=%.2f knob=%s range=%.1f mlc=%s',
            painting and 'flicker' or 'LOST', n, age < 1e8 and age or -1, p.gain, tostring(get_gain()),
            tr.range_nm or -1, mlc and string.format('%.1f', mlc) or 'none')
    end
end

-- While the paint is lost the cursor goes to where the contact should be now; while it paints, stock's own follow does.
function Search.PrepCursor()
    local p = Search.prep
    if not p or not p.lost_since then return end
    local now = now_seconds()
    if now - p.lost_since < 0.5 then return end
    local tr = Picture.tracks[p.id]
    local MoveRadarCursor = require('radar.MoveRadarCursor')
    local mc = GetJester().behaviors[MoveRadarCursor]
    local xa, xr
    if tr and tr.az_deg then xa, xr = extrapolated(tr, Config.LOCKPREP_EXTRAP_MAX_S) end
    if not Search.pilot_owns_cursor and mc and xa and xr then
        xa = math.max(-Config.CUE_MAX_AZ, math.min(Config.CUE_MAX_AZ, xa))
        mc:MoveCursorTo(deg(xa), NM(xr))
    end
end

function Search.StatusText()
    if Search.phase == 'idle' then return nil end
    if Search.phase == 'holding' then return 'SEARCH found' end
    return string.format('SEARCH %s%d band %d/%d', Search.cue.az < 0 and 'L' or 'R',
        math.floor(math.abs(Search.cue.az) + 0.5), math.max(Search.idx, 1), #Search.bands)
end

function Search.Reset()
    Search.prep = nil
    release_gain_hold('reset')
    Search.phase, Search.cue, Search.bands, Search.idx, Search.found = 'idle', nil, nil, 0, nil
    Search.pilot_elev = nil
    sw = {}
end

function Search.Install(Fixes)
    Patches.Install('search_hooks', function()
        local Radar = require('radar.Radar')
        Fixes.Wrap(Radar, 'FindNextPhase', 'SEARCH_ENABLED', function(original)
            local ok, err = pcall(Search.Step)
            if not ok then
                AADLog.Info('search step error: %s', tostring(err))
                pcall(Search.Stop, 'error') pcall(Search.Reset)
            end
            if scan_frozen() then return end
            return original()
        end)
        local UserActions = require('radar.UserActions')
        local rcfg = require('radar.Config')
        -- Stock's gain phase hands the focused contact's range to the radar's own automatic gain, which then walks the
        -- knob down (about 0.03 per second) to its clutter optimum - that is what undid the look-up gain after the
        -- handover. While the look-up gain is held the phase is skipped; it changes nothing else (no phase change, no result).
        local Phases = require('radar.Phases')
        local skipped = 0
        Fixes.Wrap(Phases, 'AdjustGain', 'SEARCH_ENABLED', function(original, ...)
            -- Experiment (SEARCH_SKIP_AUTOGAIN): also skip it while a search runs with one of our gains set. Stock calls it
            -- at every band start with that band's range, and it also sets the radar's clutter interest range, which
            -- may be what makes the picture go noisy and clean from one band to the next.
            local in_hold = gh ~= nil and Config.SEARCH_UP_GAIN_HOLD ~= false
            local in_search = Config.SEARCH_SKIP_AUTOGAIN and Search.phase ~= 'idle' and sw.gain_cfg ~= nil
            if in_hold or in_search then
                skipped = skipped + 1
                if skipped == 1 or skipped % 20 == 0 then
                    AADLog.Info('search: stock auto-gain skipped (%d, %s)', skipped, in_hold and 'gain hold' or 'during the search')
                end
                return
            end
            return original(...)
        end)
        Fixes.Wrap(UserActions, 'ScanZone', 'SEARCH_ENABLED', function(original, task, range, altitude, is_relative)
            pcall(function()
                if range and altitude then
                    Search.pilot_elev = { range_nm = range:ConvertTo(NM).value, alt_ft = altitude:ConvertTo(ft).value,
                        relative = is_relative and true or false }
                else
                    Search.pilot_elev = nil
                end
            end)
            return original(task, range, altitude, is_relative)
        end)
        Fixes.Wrap(UserActions, 'HandleContextActionScan', 'CONTEXT_SEARCH', function(original, task, action_type)
            if rcfg.context_action_type.LONG ~= nil and action_type == rcfg.context_action_type.LONG then
                local ok, used = pcall(function()
                    if Search.prep then Search.PrepFire('second long press') return true end
                    return Search.PrepBegin(function(t) return original(t, action_type) end)
                end)
                if not ok then AADLog.Info('lockprep error: %s', tostring(used)) end
                if ok and used then task:Roger() return end   -- the prep is waiting for steady paint: acknowledge the press
            end
            if Search.prep and action_type ~= rcfg.context_action_type.LONG then
                Search.PrepCancel('context press ' .. tostring(action_type))
            end
            if action_type == rcfg.context_action_type.DOUBLE then
                local ok, err = pcall(function() require('aaplus.Modes').ContextDouble() end)
                if not ok then AADLog.Info('context double error: %s', tostring(err)) end
            end
            if action_type == rcfg.context_action_type.SHORT then
                local ok, used = pcall(Search.ContextShort, task)
                if not ok then AADLog.Info('context short error: %s', tostring(used)) end
                if ok and used then return end
            end
            return original(task, action_type)
        end)
        Fixes.Wrap(Radar, 'UpdateTargetHighlight', 'SEARCH_ENABLED', function(original)
            original()
            local ok, err = pcall(Search.HoldCursor)
            if not ok then
                AADLog.Info('search hold error: %s', tostring(err))
                pcall(Search.Stop, 'error') pcall(Search.Reset)
            end
        end)
    end)
end

return Search
