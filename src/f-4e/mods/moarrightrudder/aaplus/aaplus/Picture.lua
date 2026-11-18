-- Phase 3: contact picture and threat scoring.
-- Reads radar_targets at 1 Hz, keeps a short history per contact, derives closure / time to
-- merge / bearing drift, scores every contact, clusters contacts into groups, and (through the
-- patch registry) makes stock's priority comparison follow the score instead of range alone.
local Utilities = require('base.Utilities')
local Config = require 'aaplus.Config'
local AADLog = require 'aaplus.Log'
local Patches = require 'aaplus.Patches'

local Picture = {}

Picture.tracks = {}   -- id -> track
Picture.groups = {}   -- sorted by score, highest first
Picture.count = 0
Picture.boosts = {}   -- id -> { amount, expires }; set by the cue / search engines (Phase 4)

function Picture.AddBoost(id, amount, ttl)
    local now = 0
    pcall(function()
        local raw = Utilities.GetTime().mission_time
        now = type(raw) == 'number' and raw or raw:ConvertTo(s).value
    end)
    Picture.boosts[id] = { amount = amount, expires = now + ttl }
end

Picture.cue_boost = function(id)
    local b = Picture.boosts[id]
    if not b then return 0 end
    local now = 0
    pcall(function()
        local raw = Utilities.GetTime().mission_time
        now = type(raw) == 'number' and raw or raw:ConvertTo(s).value
    end)
    if now > b.expires then Picture.boosts[id] = nil return 0 end
    return b.amount
end

local function num(x, unit)
    if x == nil then return nil end
    if type(x) == 'number' then return x end
    local ok, v = pcall(function() return x:ConvertTo(unit).value end)
    if ok and type(v) == 'number' and v == v then return v end
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
    local v
    pcall(function() v = num(GetJester().awareness:GetObservation('barometric_altitude'), ft) end)
    return v
end

local function ident_name(id)
    local I = RadarTargetIdentification
    if id == I.HOSTILE then return 'HOSTILE' end
    if id == I.FRIENDLY then return 'FRIENDLY' end
    if id == I.NEUTRAL then return 'NEUTRAL' end
    return 'UNKNOWN'
end

local function ident_weight(id)
    local I = RadarTargetIdentification
    local W = Config.W
    if id == I.HOSTILE then return W.IDENT_HOSTILE end
    if id == I.FRIENDLY then return W.IDENT_FRIENDLY end
    if id == I.NEUTRAL then return W.IDENT_NEUTRAL end
    return W.IDENT_UNKNOWN
end

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

-- Least-squares slope of y over t. Returns nil when there is too little spread.
local function slope(samples, key)
    local n = #samples
    if n < 3 then return nil end
    local span = samples[n].t - samples[1].t
    if span < 2 then return nil end
    local mt, my = 0, 0
    for _, p in ipairs(samples) do mt = mt + p.t; my = my + p[key] end
    mt, my = mt / n, my / n
    local num_, den = 0, 0
    for _, p in ipairs(samples) do
        num_ = num_ + (p.t - mt) * (p[key] - my)
        den = den + (p.t - mt) ^ 2
    end
    if den == 0 then return nil end
    return num_ / den
end

-- Pure function of a view {ident, range_nm, az_deg, alt_ft, ttm, age, id}.
local function score_view(v)
    local W = Config.W
    local sc = ident_weight(v.ident)
    sc = sc + W.RANGE * (1 - clamp((v.range_nm or Config.RANGE_REF_NM) / Config.RANGE_REF_NM, 0, 1))
    if v.ttm then
        sc = sc + W.TTM * (1 - clamp(v.ttm / Config.TTM_REF_S, 0, 1))
    end
    if v.az_deg then
        sc = sc + W.AZIMUTH * (1 - clamp(math.abs(v.az_deg) / 60, 0, 1))
    end
    if v.alt_ft and v.own_alt_ft then
        sc = sc + W.ALTITUDE * clamp((v.alt_ft - v.own_alt_ft) / Config.ALT_REF_FT, -1, 1)
    end
    if v.age then
        sc = sc + W.RECENCY * (1 - clamp(v.age / Config.RECENCY_REF_S, 0, 1))
    end
    sc = sc + (Picture.cue_boost(v.id) or 0)
    if sc ~= sc then sc = -1e6 end
    return sc
end

-- View of a raw radar target without history (used before a track exists).
local function bare_view(t, now)
    local age
    local ht = num(t.last_hit_timestamp, s)
    if ht then age = now - ht end
    return {
        id = t.id, ident = t.identification,
        range_nm = num(t.scan_range, NM), az_deg = num(t.scan_azimuth, deg),
        alt_ft = num(t.cheat_altitude, ft), own_alt_ft = own_altitude_ft(),
        age = age,
    }
end

function Picture.ScoreOf(target)
    if not target then return -1e6 end
    local live = (radar_targets and radar_targets[target.id]) or target
    local tr = Picture.tracks[live.id]
    if tr and tr.score then return tr.score end
    return score_view(bare_view(live, now_seconds()))
end

local function update_tracks(now)
    local own_alt = own_altitude_ft()
    Picture.incumbent_id = nil
    pcall(function()
        local State = require('radar.State')
        local t = State.target_to_focus_on or State.target_to_highlight
        if t and not State.target_currently_locked then Picture.incumbent_id = t.id end
    end)
    local seen = {}
    local count = 0
    for id, t in pairs(radar_targets or {}) do
        if type(id) == 'number' then
            seen[id] = true
            count = count + 1
            local tr = Picture.tracks[id]
            if not tr then
                tr = { id = id, samples = {}, first_seen = now }
                Picture.tracks[id] = tr
            end
            tr.present = true
            tr.last_seen = now
            tr.ident = t.identification
            tr.hits = t.number_of_hits or 0
            tr.max_hits = math.max(tr.max_hits or 0, tr.hits)
            tr.range_nm = num(t.scan_range, NM)
            tr.az_deg = num(t.scan_azimuth, deg)
            tr.alt_ft = num(t.cheat_altitude, ft)
            -- estimated_vc is negative while closing (it matches the range-rate fit with the sign flipped).
            local vc = num(t.estimated_vc, kt)
            tr.vc_kt = vc and -vc or nil
            local ht = num(t.last_hit_timestamp, s)
            tr.age = ht and (now - ht) or nil
            -- New sample only when the radar produced a new hit.
            if tr.range_nm and tr.az_deg and (ht == nil or ht ~= tr.last_ht) then
                tr.last_ht = ht
                local sm = tr.samples
                sm[#sm + 1] = { t = ht or now, range = tr.range_nm, az = tr.az_deg }
                while #sm > Config.HISTORY_SAMPLES do table.remove(sm, 1) end
            end
            -- Closure (positive = closing). Range-rate fit first; estimated_vc as fallback.
            local rate = slope(tr.samples, 'range')
            tr.fit_kt = rate and (-rate * 3600) or nil
            tr.closure_kt = tr.fit_kt or tr.vc_kt
            local drift = slope(tr.samples, 'az')
            tr.drift = drift
            tr.hot = tr.closure_kt ~= nil and tr.closure_kt > Config.MIN_CLOSURE_KT
            tr.ttm = (tr.hot and tr.range_nm) and (tr.range_nm / (tr.closure_kt / 3600)) or nil
            tr.score = score_view({
                id = id, ident = tr.ident, range_nm = tr.range_nm, az_deg = tr.az_deg,
                alt_ft = tr.alt_ft, own_alt_ft = own_alt, ttm = tr.ttm, age = tr.age,
            })
            -- The contact stock is already focused on or highlighting keeps its place unless a rival
            -- beats it by SWITCH_MARGIN, so the focus does not flip back and forth.
            if id == Picture.incumbent_id and tr.ident ~= RadarTargetIdentification.FRIENDLY then
                tr.score = tr.score + Config.SWITCH_MARGIN
            end
        end
    end
    for id, tr in pairs(Picture.tracks) do
        if not seen[id] then
            tr.present = false
            if now - (tr.last_seen or 0) > Config.FORGET_AFTER then
                Picture.tracks[id] = nil
            end
        end
    end
    Picture.count = count
end

local function build_groups()
    local list = {}
    for _, tr in pairs(Picture.tracks) do
        if tr.present and tr.range_nm and tr.az_deg and tr.ident ~= RadarTargetIdentification.FRIENDLY then
            list[#list + 1] = tr
        end
    end
    table.sort(list, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.id < b.id
    end)
    local function xy(tr)
        local a = math.rad(tr.az_deg)
        return tr.range_nm * math.sin(a), tr.range_nm * math.cos(a)
    end
    local groups = {}
    for _, tr in ipairs(list) do
        local placed
        local x, y = xy(tr)
        for _, g in ipairs(groups) do
            if g.ident == tr.ident then
                for _, m in ipairs(g.members) do
                    local mx, my = xy(m)
                    local d = math.sqrt((x - mx) ^ 2 + (y - my) ^ 2)
                    if d < Config.GROUP_NM and math.abs(tr.az_deg - m.az_deg) < Config.GROUP_DEG then
                        placed = g
                        break
                    end
                end
            end
            if placed then break end
        end
        if placed then
            placed.members[#placed.members + 1] = tr
            if tr.range_nm < placed.range_nm then placed.range_nm = tr.range_nm end
            if tr.hot then placed.hot = true end
            if tr.ttm and (not placed.ttm or tr.ttm < placed.ttm) then placed.ttm = tr.ttm end
        else
            groups[#groups + 1] = {
                lead = tr, members = { tr }, ident = tr.ident, score = tr.score,
                range_nm = tr.range_nm, az_deg = tr.az_deg, hot = tr.hot, ttm = tr.ttm,
            }
        end
    end
    Picture.groups = groups
end

local last_top_id, last_debug = nil, -1e9
function Picture.Update()
    local now = now_seconds()
    update_tracks(now)
    build_groups()

    local top = Picture.groups[1]
    local top_id = top and top.lead.id or nil
    if top_id ~= last_top_id then
        last_top_id = top_id
        if top then
            AADLog.Info('top group: %s', Picture.Describe(top))
        else
            AADLog.Info('top group: none')
        end
    end
    if top and Config.LOG_PICTURE_EVERY > 0 and now - last_debug >= Config.LOG_PICTURE_EVERY then
        last_debug = now
        local l = top.lead
        AADLog.Info('picture: %d grps | %s | score %.2f fit=%s vc=%s drift=%s hits=%s',
            #Picture.groups, Picture.Describe(top), l.score,
            l.fit_kt and string.format('%.0f', l.fit_kt) or 'nil',
            l.vc_kt and string.format('%.0f', l.vc_kt) or 'nil',
            l.drift and string.format('%.2f', l.drift) or 'nil', tostring(l.hits))
    end
end

function Picture.Describe(g)
    local az = g.az_deg or 0
    local side = az < 0 and 'L' or 'R'
    local txt = string.format('%s %.0f NM %s%d %s', ident_name(g.ident), g.range_nm or 0, side, math.floor(math.abs(az) + 0.5),
        g.hot and 'hot' or 'cold')
    if g.hot and g.ttm and g.ttm < 999 then txt = txt .. string.format(' %ds', math.floor(g.ttm)) end
    if #g.members > 1 then txt = txt .. string.format(' x%d', #g.members) end
    return txt
end

function Picture.StatusText()
    local n = #Picture.groups
    if n == 0 then return 'no contacts' end
    return string.format('%d grp%s, top %s', n, n == 1 and '' or 's', Picture.Describe(Picture.groups[1]))
end

function Picture.Reset()
    Picture.tracks = {}
    Picture.groups = {}
    Picture.count = 0
    Picture.boosts = {}
    last_top_id = nil
end

-- Make stock's priority comparison follow the threat score.
function Picture.Install(Fixes)
    Patches.Install('threat_sort', function()
        local Api = require('radar.Api')
        Fixes.Wrap(Api, 'IsTargetHigherPriorityThan', 'THREAT_SORT', function(original, a, b)
            local sa, sb = Picture.ScoreOf(a), Picture.ScoreOf(b)
            if sa ~= sb then return sa > sb end
            local ra = num(a.scan_range, NM) or 1e9
            local rb = num(b.scan_range, NM) or 1e9
            if ra ~= rb then return ra < rb end
            return (a.id or 0) < (b.id or 0)
        end)
    end)
end

return Picture
