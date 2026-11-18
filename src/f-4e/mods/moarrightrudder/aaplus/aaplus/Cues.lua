-- Phase 4: cue queue. Any sensor can add a cue; the search executor consumes the best one.
-- A cue: { key, source, az (deg), range_nm?, alt_ft?, target_id?, priority, born, ready_at,
--          expires, cooldown_until, covered_by? }
--   RWR        a forward-arc emitter with no radar track near its bearing. Waits for an IFF
--              return before searching; one cue per cluster of emitters.
--   IFF orphan hostile IFF reply with no matching radar track (bearing, range, altitude).
-- A cue ends when the radar paints a real track that matches it (same id, or about the same
-- bearing and range), or when it expires.
-- CURSOR     the pilot slewed the cursor and left it still (PILOT mode, Modes.lua).
-- The Combat-Tree light (no bearing, so no search) is not built.
local Utilities = require('base.Utilities')
local Config = require 'aaplus.Config'
local AADLog = require 'aaplus.Log'
local Picture = require 'aaplus.Picture'

local Cues = {}
Cues.list = {}       -- key -> cue
Cues.seen_rwr = {}   -- rwr id -> last seen time
Cues.handled = {}    -- rwr id -> true once counted into a cue (or matched to a track)
Cues.suppress_until = 0   -- no new searches before this time (pilot override)

local function now_seconds()
    local t = 0
    pcall(function()
        local raw = Utilities.GetTime().mission_time
        t = type(raw) == 'number' and raw or raw:ConvertTo(s).value
    end)
    return t
end

local function num(x, unit)
    if x == nil then return nil end
    if type(x) == 'number' then return x end
    local ok, v = pcall(function() return x:ConvertTo(unit).value end)
    if ok and type(v) == 'number' and v == v then return v end
    return nil
end

local function wrap180(a)
    a = (a + 180) % 360 - 180
    return a
end

-- Own heading in degrees (0..360): the ground track of the NED velocity vector. The INS true
-- heading was tried first and rejected: in testing it read 137, 238, 352 and later 218, 279, 151
-- within seconds while the aircraft held a steady course. It is read only to be logged beside this.
local function ins_heading()
    local ok, v = pcall(GetProperty, '/INS ASN-63/Nav Comp Outputs Calculator', 'True Heading (INS)')
    if ok and v and v.value ~= nil then
        local n = num(v.value, deg)
        if n then return n % 360 end
    end
    return nil
end
function Cues.OwnHeading()
    local ok, vv = pcall(function() return GetJester().awareness:GetObservation('gods_velocity_ned') end)
    if ok and vv then
        local x, y = num(vv.x, mps), num(vv.y, mps)
        if x and y then
            if (x * x + y * y) > 2500 then   -- above ~50 m/s
                return math.deg(math.atan2(y, x)) % 360, 'vel'
            end
            return nil, 'too slow'
        end
    end
    return nil, 'no velocity'
end

-- A cue's azimuth relative to the nose right now: it was fixed in space when it was made.
function Cues.CurrentAz(c)
    if c.rwr_id or c.cursor_live or not c.abs then return c.az end
    local h = Cues.OwnHeading()
    if not h then return c.az end
    return wrap180(c.abs - h)
end

-- Clock hour in the forward arc -> azimuth in degrees (10 o'clock = -60, 12 = 0, 2 = +60).
local function forward_arc_azimuth(hour)
    hour = tonumber(hour)
    if not hour then return nil end
    if hour == 12 then return 0 end
    if hour >= 10 then return (hour - 12) * 30 end
    if hour <= 2 and hour >= 1 then return hour * 30 end
    return nil
end

-- A real radar track: painted with two or more hits at some point, not friendly, and either on the
-- scope now or seen within TRACK_MEMORY_S. Two groups at different altitudes alternate in and out of
-- the radar's view, so a contact that is off the scope for a moment is still a track.
function Cues.IsKnownTrack(tr)
    if (tr.max_hits or tr.hits or 0) < 2 or not tr.az_deg then return false end
    if tr.ident == RadarTargetIdentification.FRIENDLY then return false end
    -- Jester keeps old returns in its list: a contact whose last hit is long gone is not a track we hold.
    if tr.age and tr.age > (Config.CUE_TRACK_MAX_AGE_S or 30) then return false end
    return tr.present or (now_seconds() - (tr.last_seen or 0)) <= Config.TRACK_MEMORY_S
end

-- Stock has this track: locked, being locked, focused, highlighted, or already called out.
local function held_by_stock(tr)
    local ok, res = pcall(function()
        local State = require('radar.State')
        for _, t in ipairs({ State.target_currently_locked, State.target_to_lock, State.target_to_focus_on, State.target_to_highlight }) do
            if t ~= nil then
                local okid, tid_ = pcall(function() return t.id end)   -- stock targets are userdata
                if okid and tid_ == tr.id then return true end
            end
        end
        -- "Already called out" only counts while the contact is on the scope: a contact called out earlier and since
        -- lost stays in stock's list and would otherwise satisfy a new BRAA / RWR cue forever.
        return tr.present == true and State.processed_targets ~= nil and State.processed_targets[tr.id] ~= nil
    end)
    return ok and res == true
end

-- A track that belongs to the group an EWRS cue stands for (the cue sits on the group's lead contact; a group of
-- several aircraft is spread over a few miles, wider than the usual track match): within 1.25 x the grouping distance
-- sideways (the cue's position is up to one EWRS picture old) and within the grouping height at that range.
local function in_ewrs_group(c, tr)
    local da = math.rad(c.az - tr.az_deg)
    local r1, r2 = c.range_nm, tr.range_nm
    local d = math.sqrt(math.max(0, r1 * r1 + r2 * r2 - 2 * r1 * r2 * math.cos(da)))
    if d > (Config.AWACS_SAME_GROUP_NM or 8) * 1.25 then return false end
    if c.alt_ft and tr.alt_ft then
        local okA, Awacs = pcall(require, 'aaplus.Awacs')
        local lim = (okA and Awacs.GroupAltFt) and Awacs.GroupAltFt(r1) or 6000
        if math.abs(c.alt_ft - tr.alt_ft) > lim * 1.5 then return false end
    end
    return true
end

-- The real radar tracks that match a cue.
function Cues.TracksNear(c, painted_ok)
    local out = {}
    for id, tr in pairs(Picture.tracks) do
        if Cues.IsKnownTrack(tr) then
            local match = false
            if c.target_id and id == c.target_id then
                match = true
            elseif c.source == 'CURSOR' then
                -- Only a contact on the scope now, close to where the pilot pointed.
                match = tr.present and tr.range_nm ~= nil
                    and math.abs(tr.az_deg - c.az) <= Config.CURSOR_TRACK_DEG
                    and (not c.range_nm or math.abs(tr.range_nm - c.range_nm) <= Config.CURSOR_TRACK_NM)
            elseif c.ewrs and (c.count or 1) > 1 and c.range_nm and tr.range_nm and tr.az_deg then
                match = in_ewrs_group(c, tr)
            elseif c.range_nm and tr.range_nm then
                match = math.abs(tr.az_deg - c.az) <= Config.CUE_IFF_TRACK_DEG
                    and math.abs(tr.range_nm - c.range_nm) <= Config.CUE_IFF_TRACK_NM
            elseif not c.range_nm then
                match = math.abs(tr.az_deg - c.az) <= Config.CUE_TRACK_TOL_DEG + (c.spread or 0)
            end
            -- A faint contact shows on the scope now and then without Jester ever holding it. For these cues a painted
            -- track is not enough: stock must have it focused / locked / called out, or the search goes on.
            if match and not painted_ok and Config.CUE_NEEDS_HELD and Config.CUE_NEEDS_HELD[c.source] and not held_by_stock(tr) then match = false end
            if match then out[#out + 1] = tr end
        end
    end
    return out
end

function Cues.TrackFor(c)
    return Cues.TracksNear(c)[1]
end

local function find_cue_near(source, az, deg_tol)
    for _, c in pairs(Cues.list) do
        if c.source == source and math.abs(c.az - az) <= deg_tol then return c end
    end
    return nil
end

local function add_or_refresh(key, source, az, range_nm, alt_ft, target_id, priority, now)
    local c = Cues.list[key]
    if not c then
        -- An RWR-only cue waits a few seconds so an IFF return can arrive first and give the
        -- real bearing, range and altitude. A launch warning does not wait.
        local wait = (source == 'RWR') and Config.RWR_CORRELATE_S or 0
        c = { key = key, source = source, born = now, cooldown_until = 0, ready_at = now + wait }
        Cues.list[key] = c
        AADLog.Info('cue: %s az=%d range=%s alt=%s prio=%d', key, math.floor(az + 0.5),
            range_nm and string.format('%.0f', range_nm) or '-', alt_ft and string.format('%.0f', alt_ft) or '-', priority)
    end
    c.az, c.range_nm, c.alt_ft, c.target_id = az, range_nm, alt_ft, target_id
    if c.source ~= 'RWR' then
        local h = Cues.OwnHeading()
        if h then c.abs = wrap180(h + az) end
    end
    if priority > (c.priority or 0) then c.priority = priority end
    c.expires = now + Config.CUE_TTL
    return c
end

-- A cursor cue: the pilot slewed the cursor to this bearing and left it there (PILOT mode).
function Cues.AddCursorCue(az, range_nm)
    local now = now_seconds()
    Cues.list.cursor = nil
    local c = add_or_refresh('cursor', 'CURSOR', az, range_nm, nil, nil, 2, now)
    c.cursor_live = true   -- its bearing is the cursor's own (PILOT mode): never pinned to a compass heading
    c.abs = nil
    return c
end

-- A contact from an AWACS / GCI report (BRAA call): a cue with a range, so the search puts the radar
-- range scale and the cursor on the contact.
function Cues.AddAwacsCue(az, range_nm, alt_ft, contact)
    local now = now_seconds()
    -- The same cue object is updated in place, so a search already running on it sees the new position.
    -- Returns the cue and how far (NM) the new report is from the one it replaced (nil for a first report).
    local old = Cues.list.awacs
    local moved
    if old and old.range_nm then
        local oaz = Cues.CurrentAz(old)
        local r1, r2 = old.range_nm, range_nm
        local c = math.cos(math.rad(wrap180(az - oaz)))
        moved = math.sqrt(math.max(0, r1 * r1 + r2 * r2 - 2 * r1 * r2 * c))
    end
    -- Stock reports only its closest bogey, but interleaves a call for a farther group now and then. A report far from
    -- the current cue and farther away than it, while that cue is fresh, is that other group: it must not drag the cue
    -- (and the search on it) away from the nearer bandit. A cue that stops being refreshed lets the far report in.
    if old and old.range_nm and moved and moved > (Config.AWACS_NEW_CUE_NM or 8) and range_nm > old.range_nm
        and old.aw_report_at and now - old.aw_report_at < (Config.AWACS_NEAR_HOLD_S or 25) then
        return nil, moved, true
    end
    local c = add_or_refresh('awacs', 'AWACS', az, range_nm, alt_ft, nil, 2, now)
    c.aw_report_at = now
    c.aw_abs, c.aw_range_nm, c.aw_used, c.aw_center = nil, nil, nil, nil   -- the contact moved: match it afresh
    c.cooldown_until = 0
    c.aw_contact = contact
    -- The cue lives as long as the report is usable, so a contact outside the gimbal limits can still be
    -- searched when we turn toward it or it drifts back inside.
    c.expires = now + (Config.AWACS_MAX_AGE_S or 90)
    return c, moved
end

-- EWRS picture: one cue per group (key 'ewrs:N'), kept across pictures by position so the search state and
-- cooldown survive the 20 s re-report. A group the picture no longer lists goes away unless it is being searched.
-- Skipped: a group the stock-BRAA cue already covers, or one stock already holds a track on.
Cues.ewrs_seq = Cues.ewrs_seq or 0
function Cues.SyncEwrs(groups)
    local now = now_seconds()
    local okA, Awacs = pcall(require, 'aaplus.Awacs')
    if not okA then return end
    local Search = package.loaded['aaplus.Search']
    local active = type(Search) == 'table' and Search.IsActive and Search.IsActive() and Search.cue or nil
    local used = {}
    local same = Config.AWACS_SAME_GROUP_NM or 8
    -- Which group is which cue: every (group, cue) pair within the drift allowance, nearest first. A group with no
    -- cue of its own (a track holds it, so its cue was already dropped) must not take a neighboring group's cue.
    local covered, cands, assigned = {}, {}, {}
    for gi, g in ipairs(groups) do
        local stock = Cues.list.awacs
        if stock and stock.aw_contact and Awacs.SameGroup(stock.aw_contact, g.contact, g.range_nm) then
            covered[gi] = true   -- the stock reply already cues this group
        else
            for _, e in pairs(Cues.list) do
                if e.ewrs and e.aw_contact and Awacs.SameGroup(e.aw_contact, g.contact, g.range_nm, 1.5) then
                    cands[#cands + 1] = { gi = gi, e = e, d = Awacs.Dist(e.aw_contact, g.contact) }
                end
            end
        end
    end
    table.sort(cands, function(a, b) return a.d < b.d end)
    for _, p in ipairs(cands) do
        if not assigned[p.gi] and not used[p.e.key] then
            assigned[p.gi] = p.e
            used[p.e.key] = true
        end
    end
    for gi, g in ipairs(groups) do
        if not covered[gi] then
            local best = assigned[gi]
            if best then
                local moved = Awacs.Dist(best.aw_contact, g.contact)
                add_or_refresh(best.key, 'AWACS', g.az, g.range_nm, g.alt_ft, nil, 2, now)
                if moved > 3 then best.aw_abs, best.aw_range_nm, best.aw_used, best.aw_center = nil, nil, nil, nil end
                if moved > (Config.AWACS_NEW_CUE_NM or 8) then best.cooldown_until = 0 end
                best.aw_contact, best.group_n, best.type = g.contact, g.n, g.type
                best.count = g.n   -- the cue stays open until every aircraft of the group has a track
                best.expires = now + (Config.AWACS_MAX_AGE_S or 90)
            else
                local probe = { key = 'ewrs:probe', source = 'AWACS', az = g.az, range_nm = g.range_nm, alt_ft = g.alt_ft,
                                ewrs = true, count = g.n }
                local held = false
                pcall(function() held = #Cues.TracksNear(probe) >= (g.n or 1) end)
                if not held then
                    Cues.ewrs_seq = Cues.ewrs_seq + 1
                    local key = 'ewrs:' .. Cues.ewrs_seq
                    local e = add_or_refresh(key, 'AWACS', g.az, g.range_nm, g.alt_ft, nil, 2, now)
                    e.ewrs, e.aw_contact, e.group_n, e.type = true, g.contact, g.n, g.type
                    e.count = g.n
                    e.expires = now + (Config.AWACS_MAX_AGE_S or 90)
                    used[key] = true
                end
            end
        end
    end
    for key, e in pairs(Cues.list) do
        if e.ewrs and not used[key] and e ~= active then
            Cues.list[key] = nil
            AADLog.Info('cue: %s dropped (no longer in the EWRS picture)', key)
        end
    end
end

-- The EWRS cue that already covers a stock-BRAA contact's group (nil if none): the stock reply is then not a cue of its
-- own, or the same group would be searched twice and the search on the other groups interrupted.
function Cues.EwrsCovering(contact, range_nm)
    if not contact then return nil end
    local okA, Awacs = pcall(require, 'aaplus.Awacs')
    if not okA then return nil end
    for _, e in pairs(Cues.list) do
        if e.ewrs and e.aw_contact and Awacs.SameGroup(e.aw_contact, contact, range_nm, 1.5) then return e end
    end
    return nil
end

function Cues.ClearCursor()
    Cues.list.cursor = nil
end

-- RWR emitters are clustered by bearing. A cluster of E emitters needs E radar tracks near its
-- bearing before it is satisfied (stacked groups share a bearing but not an altitude).
local function scan_rwr(now)
    local present, ems = {}, {}
    for _, r in pairs(rwr_contacts or {}) do
        if type(r) == 'table' and r.id ~= nil then
            present[r.id] = true
            Cues.seen_rwr[r.id] = now
            if Config.LOG_RWR_FIELDS then
                Cues.rwr_field_log = Cues.rwr_field_log or {}
                if now - (Cues.rwr_field_log[r.id] or -1e9) >= 5 then
                    Cues.rwr_field_log[r.id] = now
                    local parts = {}
                    for k, v in pairs(r) do parts[#parts + 1] = tostring(k) .. '=' .. tostring(v) end
                    table.sort(parts)
                    AADLog.Info('rwr fields: %s', table.concat(parts, ' '))
                end
            end
            if r.category_1 == 'airborne' and not r.known_friendly then
                local az = forward_arc_azimuth(r.hour)
                if az then ems[#ems + 1] = { id = r.id, az = az, launch = (r.launch == true or r.activity == 'launch'),
                    rwr_range = tonumber(r.range) } end
            end
        end
    end
    table.sort(ems, function(a, b) if a.az ~= b.az then return a.az < b.az end return tostring(a.id) < tostring(b.id) end)
    local clusters = {}
    for _, e in ipairs(ems) do
        local cl = clusters[#clusters]
        if cl and e.az - cl.first <= Config.RWR_CLUSTER_DEG then
            cl.list[#cl.list + 1] = e
            cl.sum = cl.sum + e.az
        else
            clusters[#clusters + 1] = { list = { e }, first = e.az, sum = e.az }
        end
    end
    -- One cue per emitter, so the pilot can step through them with the context button. Emitters in
    -- a cluster share a count: the cluster is satisfied only when that many tracks are near it.
    for _, cl in ipairs(clusters) do
        local n = #cl.list
        local mean = cl.sum / n
        local spread = 0
        for _, e in ipairs(cl.list) do spread = math.max(spread, math.abs(e.az - mean)) end
        for _, e in ipairs(cl.list) do
            local key = 'rwr:' .. tostring(e.id)
            local cue = Cues.list[key]
            if cue then
                cue.expires = now + Config.CUE_TTL
                cue.count = n
                cue.spread = spread
                cue.bin = e.az
                cue.rwr_range_nm = e.rwr_range and e.rwr_range * (Config.RWR_RANGE_SCALE_NM or 90) or cue.rwr_range_nm
                Cues.handled[e.id] = true
            elseif not Cues.handled[e.id] then
                local tracks = Cues.TracksNear({ az = mean, spread = spread })
                if #tracks >= n then
                    for _, t in ipairs(tracks) do Picture.AddBoost(t.id, Config.W.CUE, Config.CUE_TTL) end
                else
                    local c = add_or_refresh(key, 'RWR', e.az, nil, nil, nil, 1, now)
                    c.count = n
                    c.spread = spread
                    c.rwr_id, c.est, c.bin, c.last_h = e.id, e.az, e.az, Cues.OwnHeading()
                    c.rwr_range_nm = e.rwr_range and e.rwr_range * (Config.RWR_RANGE_SCALE_NM or 90) or nil
                    c.lo, c.hi = e.az - 15, e.az + 15
                    local iff = find_cue_near('IFF', e.az, Config.IFF_MERGE_DEG)
                    if iff then c.covered_by = iff.key end
                end
                Cues.handled[e.id] = true
            end
        end
    end
    -- Forget emitters that have been gone a while, so a returning one cues again.
    for id, last in pairs(Cues.seen_rwr) do
        if not present[id] and now - last > Config.RWR_FORGET_S then
            Cues.seen_rwr[id] = nil
            Cues.handled[id] = nil
        end
    end
end

local function scan_iff_orphans(now)
    if not Config.IFF_CUES then return end
    for id, t in pairs(radar_targets or {}) do
        if type(id) == 'number' and (t.number_of_hits or 0) < 2
            and t.identification == RadarTargetIdentification.HOSTILE then
            local az = num(t.scan_azimuth, deg)
            local rng = num(t.scan_range, NM)
            local alt = num(t.cheat_altitude, ft)
            if az and rng then
                local key = 'iff:' .. tostring(id)
                add_or_refresh(key, 'IFF', az, rng, alt, id, 2, now)
                -- RWR cues at about this bearing are covered by the IFF return while it lasts;
                -- they become searchable again if the IFF cue goes away and the emitter is still there.
                for _, c in pairs(Cues.list) do
                    if c.source == 'RWR' and not c.covered_by and math.abs(c.az - az) <= Config.IFF_MERGE_DEG then
                        c.covered_by = key
                        AADLog.Info('cue: %s covered by %s', c.key, key)
                    end
                end
            end
        end
    end
end

local last_debug = -1e9
local function debug_radar_targets(now)
    if not Config.LOG_CUE_DEBUG or now - last_debug < 2 then return end
    local lines = {}
    for id, t in pairs(radar_targets or {}) do
        lines[#lines + 1] = string.format('%s ident=%s hits=%s acq=%s az=%s rng=%s', tostring(id), tostring(t.identification),
            tostring(t.number_of_hits), tostring(t.found_in_acq_or_trk), tostring(num(t.scan_azimuth, deg)), tostring(num(t.scan_range, NM)))
    end
    local function prop(path, name)
        local ok, p = pcall(GetProperty, path, name)
        if not ok or not p then return nil end
        return p.value
    end
    local interrog = prop('/IFF Interrogator System', 'Is Interrogating')
    local light = prop('/IFF Interrogator System', 'Combat-Tree Activity Light')
    if #lines > 0 or interrog == true or (type(interrog) == 'number' and interrog > 0) then
        last_debug = now
        AADLog.Info('cue-debug: interrogating=%s light=%s radar_targets %d | %s', tostring(interrog), tostring(light),
            #lines, table.concat(lines, ' | '))
    end
end

function Cues.Debug() debug_radar_targets(now_seconds()) end

function Cues.Update()
    local now = now_seconds()
    debug_radar_targets(now)
    scan_rwr(now)
    scan_iff_orphans(now)
    local h, src = Cues.OwnHeading()
    for _, c in pairs(Cues.list) do
        if c.rwr_id then
            -- RWR bearing is only known to its 30 degree clock bin. Keep the interval the true
            -- bearing must lie in: slide it against our turn, intersect it with the bin the RWR
            -- reports now (a bin change pins the edge), and aim at its middle.
            if h then
                if c.last_h then
                    local d = wrap180(h - c.last_h)
                    c.lo, c.hi = c.lo - d, c.hi - d
                end
                c.last_h = h
            end
            local blo, bhi = c.bin - 15, c.bin + 15
            local lo, hi = math.max(c.lo or blo, blo), math.min(c.hi or bhi, bhi)
            if lo > hi then lo, hi = blo, bhi end
            c.lo, c.hi = lo, hi
            c.est = (lo + hi) / 2
            c.az = c.est
        elseif h and not c.cursor_live then
            if not c.abs then c.abs = wrap180(h + c.az) end
            c.az = wrap180(c.abs - h)
        end
    end
    if Config.LOG_CUE_DEBUG and now - (Cues.last_heading_log or -1e9) >= 5 then
        local any
        for _, c in pairs(Cues.list) do any = c break end
        if any then
            Cues.last_heading_log = now
            local ih = ins_heading()
            AADLog.Info('cue-debug: heading %s (%s) ins=%s cue %s abs=%s rel=%s',
                tostring(h and math.floor(h + 0.5)), tostring(src), tostring(ih and math.floor(ih + 0.5)),
                any.key, tostring((any.abs or any.bin) and math.floor((any.abs or any.bin) + 0.5)), tostring(math.floor(any.az + 0.5)))
        end
    end
    -- Threat inputs. An AWACS cue follows its contact (dead-reckoned) while no search is running on it; an RWR
    -- cue borrows the AWACS/EWRS contact found in its sector; an IFF cue uses the radar track's time to merge.
    if Config.CUE_THREAT then
        local okA, Awacs = pcall(require, 'aaplus.Awacs')
        local Search = package.loaded['aaplus.Search']
        local active = type(Search) == 'table' and Search.IsActive and Search.IsActive() and Search.cue or nil
        local lat, lon
        if okA and Awacs.Enabled and Awacs.Enabled() then lat, lon = Awacs.OwnState() end
        for _, c in pairs(Cues.list) do
            c.th = nil
            if lat and lon then
                if c.source == 'AWACS' and c.aw_contact then
                    local okt, th = pcall(Awacs.ThreatInfo, c.aw_contact, now, lat, lon)
                    if okt and th then
                        c.th = th
                        if c ~= active and h and th.dr then
                            c.abs, c.range_nm = wrap180(th.brg_true), th.range_nm
                            c.az = wrap180(c.abs - h)
                        end
                    end
                elseif c.source == 'RWR' or c.source == 'CURSOR' then
                    local tol = (Config.AWACS_RWR_TOL_DEG or 15) + (c.spread or 0)
                    local okm, el, info = pcall(Awacs.Match, c.az, c.range_nm, now, nil, (not c.range_nm) and tol or nil)
                    if okm and el and type(info) == 'table' and info.threat then
                        c.th = info.threat
                        c.th.elev = el
                    end
                end
                if c.th and not c.th.elev and c.th.alt_ft then
                    local _, _, own_alt = Awacs.OwnState()
                    if own_alt then
                        c.th.elev = math.deg(math.atan2(c.th.alt_ft - own_alt, math.max(c.th.range_nm, 1) * 6076.12))
                    end
                end
            end
            if c.source == 'IFF' and c.target_id then
                local tr = Picture.tracks and Picture.tracks[c.target_id]
                if tr then
                    c.th = { range_nm = tr.range_nm, ttm = tr.hot and tr.ttm or nil, closure_kt = tr.closure_kt,
                             aspect = tr.hot and 'HOT' or nil }
                end
            end
        end
    end
    -- An EWRS group in an RWR emitter's sector is that emitter: the EWRS cue hides behind the RWR cue (which takes
    -- the group's range, bearing and type through Awacs.Elevation), so the pilot meets the contact once. One to one,
    -- nearest bearing first.
    do
        local pairs_, tol0 = {}, (Config.AWACS_RWR_TOL_DEG or 15)
        for _, e in pairs(Cues.list) do
            if e.ewrs then
                e.covered_by, e.rwr_covered = nil, nil
                for _, r in pairs(Cues.list) do
                    if r.source == 'RWR' and not r.range_nm then
                        local d = math.abs(wrap180(e.az - r.az))
                        if d <= tol0 + (r.spread or 0) then pairs_[#pairs_ + 1] = { e = e, r = r, d = d } end
                    end
                end
            end
        end
        table.sort(pairs_, function(a, b) return a.d < b.d end)
        local used_e, used_r = {}, {}
        for _, p in ipairs(pairs_) do
            if not used_e[p.e] and not used_r[p.r] then
                used_e[p.e], used_r[p.r] = true, true
                p.e.covered_by, p.e.rwr_covered = p.r.key, true
                if not p.e.logged_cover then
                    p.e.logged_cover = true
                    AADLog.Info('cue: %s is the emitter %s (EWRS group, %.0f deg apart): one entry', p.e.key, p.r.key, p.d)
                end
            end
        end
    end
    for key, c in pairs(Cues.list) do
        local trs = Cues.TracksNear(c)
        if #trs >= (c.count or 1) then
            Cues.list[key] = nil
            for _, tr in ipairs(trs) do
                if c.source == 'RWR' then Picture.AddBoost(tr.id, Config.W.CUE, Config.CUE_TTL) end
            end
            AADLog.Info('cue: %s satisfied by %d track(s), first %s', key, #trs, tostring(trs[1].id))
        elseif now > c.expires then
            Cues.list[key] = nil
            if c.rwr_id then Cues.handled[c.rwr_id] = nil end   -- it may cue again when back in the forward arc
            AADLog.Info('cue: %s expired', key)
        end
    end
end

-- Threat score of a cue (higher = search it first). A launch warning does not count: by then it is too late.
-- Terms (weights in Config.CUE_THREAT): what the cue is (an RWR emitter is radiating at us, so it outranks a
-- bare AWACS bogey), aircraft class (EWRS type), time to merge, aspect (hot / flanking / beaming / cold), speed, closeness, elevation above
-- us, and nearness to the nose. An RWR cue with an AWACS/EWRS contact in its sector takes that contact's terms
-- on top of its own. Returns the score and a short breakdown for the log.
local function clamp(x, a, b) return math.max(a, math.min(b, x)) end
function Cues.Threat(c)
    local T = Config.CUE_THREAT
    if not T then return c.priority or 0, '' end
    local th = c.th or {}
    local parts = {}
    local sc = T[c.source] or 0
    parts[#parts + 1] = string.format('%s %.1f', c.source, sc)
    if th.ttm then
        local v = T.TTM * (1 - clamp(th.ttm / T.TTM_REF_S, 0, 1))
        sc = sc + v
        parts[#parts + 1] = string.format('ttm %ds %+.1f', math.floor(th.ttm), v)
    end
    if th.aspect and T.ASPECT[th.aspect] then
        sc = sc + T.ASPECT[th.aspect]
        parts[#parts + 1] = string.format('%s %+.1f', th.aspect:lower(), T.ASPECT[th.aspect])
    end
    if th.class and T.CLASS and T.CLASS[th.class] then
        sc = sc + T.CLASS[th.class]
        parts[#parts + 1] = string.format('%s %+.1f', tostring(th.type), T.CLASS[th.class])
    end
    if th.gs_kt then
        local v = T.SPEED * clamp((th.gs_kt - T.SPEED_LO_KT) / (T.SPEED_HI_KT - T.SPEED_LO_KT), 0, 1)
        sc = sc + v
        parts[#parts + 1] = string.format('%dkt %+.1f', math.floor(th.gs_kt), v)
    end
    -- Range: the AWACS/EWRS contact's, the cue's own, or the RWR scope's distance for the emitter (about 90 NM full scale).
    local rng = th.range_nm or c.range_nm or c.rwr_range_nm or T.UNKNOWN_RANGE_NM
    local from_rwr = not (th.range_nm or c.range_nm) and c.rwr_range_nm
    local v = (from_rwr and (T.RWR_RANGE or T.RANGE) or T.RANGE) * (1 - clamp(rng / (Config.RANGE_REF_NM or 80), 0, 1))
    sc = sc + v
    parts[#parts + 1] = string.format('%.0fNM%s %+.1f', rng, (th.range_nm or c.range_nm) and '' or (c.rwr_range_nm and ' rwr' or '?'), v)
    if th.elev then
        v = T.ELEVATION * clamp(th.elev / (T.ELEVATION_REF_DEG or 5), -1, 1)
        sc = sc + v
        parts[#parts + 1] = string.format('el %+.0f %+.1f', th.elev, v)
    end
    v = T.AZIMUTH * (1 - math.min(1, math.abs(c.az or 0) / 60))
    sc = sc + v
    return sc, table.concat(parts, ', ')
end

-- Distance of a cue in NM (AWACS/EWRS contact, own, or the RWR scope's), nil when unknown.
function Cues.RangeOf(c)
    return (c.th and c.th.range_nm) or c.range_nm or c.rwr_range_nm
end

-- Is cue a more urgent than cue b (by more than margin)?
function Cues.MoreUrgent(a, b, margin)
    return (Cues.Threat(a)) > (Cues.Threat(b)) + (margin or 0)
end

-- Highest threat first; skips cues in cooldown, still waiting, covered by a live cue, or outside the gimbal
-- limits (re-checked every second, so a cue comes back when we turn toward it or it drifts inside).
function Cues.Best(exclude)
    local now = now_seconds()
    local best
    for _, c in pairs(Cues.list) do
        local covered = c.covered_by and Cues.list[c.covered_by] ~= nil
        if c ~= exclude and now >= c.cooldown_until and now >= (c.ready_at or 0) and not covered
            and math.abs(c.az) <= Config.CUE_START_AZ then
            -- The highest threat score; then closest to the nose; then newest.
            local better = false
            if not best then
                better = true
            elseif Cues.MoreUrgent(c, best) then
                better = true
            elseif not Cues.MoreUrgent(best, c) then
                local ca, ba = math.abs(c.az), math.abs(best.az)
                better = ca < ba or (ca == ba and c.born > best.born)
            end
            if better then best = c end
        end
    end
    return best
end

-- Every live cue in priority order (then closest to the nose, then newest), ignoring readiness,
-- cooldown and coverage. Used when the pilot steps through cues by hand.
function Cues.Ordered()
    local list = {}
    for _, c in pairs(Cues.list) do
        if not c.rwr_covered then list[#list + 1] = c end   -- an EWRS group that is an RWR emitter is listed once, as the emitter
    end
    table.sort(list, function(a, b)
        local ta, tb = (Cues.Threat(a)), (Cues.Threat(b))
        if ta ~= tb then return ta > tb end
        local aa, ab = math.abs(a.az), math.abs(b.az)
        if aa ~= ab then return aa < ab end
        return a.born > b.born
    end)
    return list
end

-- The cue after `current` in the stepping order, wrapping around; nil when there is no other cue.
-- The order is frozen for Config.STEP_FREEZE_S after each press so the list does not reshuffle while the pilot
-- steps through it; cues that appear meanwhile join at the end, cues that are gone drop out.
function Cues.NextAfter(current)
    local now = now_seconds()
    local all
    if Cues.step_order and now - (Cues.step_time or -1e9) < (Config.STEP_FREEZE_S or 6) then
        local seen
        all, seen = {}, {}
        for _, e in ipairs(Cues.step_order) do
            if Cues.list[e.key] == e and not e.rwr_covered then all[#all + 1] = e seen[e] = true end
        end
        for _, e in ipairs(Cues.Ordered()) do
            if not seen[e] then all[#all + 1] = e end
        end
    else
        all = Cues.Ordered()
    end
    Cues.step_order, Cues.step_time = all, now
    -- A cue outside the gimbal limits cannot be searched: stepping skips it (it is still listed in the log).
    local list = {}
    for _, e in ipairs(all) do
        if e == current or math.abs(e.az or 0) <= (Config.CUE_START_AZ or 58) then list[#list + 1] = e end
    end
    if #list == 0 then return nil end
    if not current then return list[1] end
    for i, e in ipairs(list) do
        if e == current then
            local nxt = list[i % #list + 1]
            if nxt ~= current then return nxt end
            return nil
        end
    end
    return list[1]
end

function Cues.IsSuppressed()
    return now_seconds() < Cues.suppress_until
end

function Cues.Reset()
    Cues.list = {}
    Cues.seen_rwr = {}
    Cues.handled = {}
    Cues.suppress_until = 0
end

return Cues
