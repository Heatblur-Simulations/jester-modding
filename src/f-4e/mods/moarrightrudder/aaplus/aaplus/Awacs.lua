-- AWACS / EWRS picture: reads the radar-contact messages the hook (Scripts\Hooks\AAPlusMessages.lua) writes
-- to Logs\aaplus_messages.txt, keeps them as world positions, and tells the search where a cue's contact is
-- vertically. Needs io in the Jester Lua state (missionscripting.lua de-sanitised) - without it this module is idle.
--
-- Facts measured from logs (see the bearing/range/altitude notes in Config):
--   * stock AWACS: "BRA, 319 for 30, at 7000, hot" - one group; bearing MAGNETIC (true - 4.0), range NM, altitude MSL, ~1000 ft steps
--   * EWRS: "BBB | R NM | A ft | ASPECT | Type" lines above a "Friendly" separator; bearing magnetic (true - ~2.5), 5 deg steps
--   * stock's hot/cold is CLOSURE only (range decreasing / increasing), not aspect: used only as a closing sign
--   * EWRS's HOT/COLD/FLANKING/BEAMING is real aspect; EWRS also gives the type (Fulcrum, Hip, ...)
local Config = require 'aaplus.Config'
local AADLog = require 'aaplus.Log'

local Awacs = { contacts = {}, offset = 0, last_size = 0, polled = 0, ingested = 0, warned = false, revision = 0 }

local function wrap180(a) return (a + 180) % 360 - 180 end
local FT_PER_NM = 6076.12

local function now_seconds()
    local t = 0
    pcall(function()
        local raw = require('base.Utilities').GetTime().mission_time
        t = type(raw) == 'number' and raw or raw:ConvertTo(s).value
    end)
    return t
end

----------------------------------------------------------------------------------------------------
-- Parsing (pure functions; Awacs.ParseLine is exercised offline against real logs)
----------------------------------------------------------------------------------------------------

-- One log line -> { t, kind, lat, lon, alt_m, hdg, text } or nil. Lines without self= position are kept (lat=nil).
function Awacs.ParseLine(line)
    local t, kind, selfs, text = line:match('^t=([%d%.%-]+) kind=(%a+) dur=%S+ self=(%S+) decl=%S* | (.*)$')
    if not t then t, kind, selfs, text = line:match('^t=([%d%.%-]+) kind=(%a+) dur=%S+ self=(%S+) | (.*)$') end
    if not t then return nil end
    local m = { t = tonumber(t), kind = kind, text = text }
    local lat, lon, alt, hdg = selfs:match('^(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)$')
    if lat then m.lat, m.lon, m.alt_m, m.hdg = tonumber(lat), tonumber(lon), tonumber(alt), tonumber(hdg) end
    return m
end

-- Message text -> source name and a list of { brg_mag, range_nm, alt_ft, type }. Nil for anything else.
function Awacs.ParseText(text)
    if text:find('EWRS :', 1, true) then
        local out = {}
        local cut = text:find('Friendly', 1, true)
        local hostile = cut and text:sub(1, cut - 1) or text
        for part in hostile:gmatch('[^/]+') do
            local b, r, a, asp, ty = part:match('^%s*(%d%d%d) | (%d+) NM | (%d+)ft | (%a+) | (.-)%s*$')
            if b then out[#out + 1] = { brg_mag = tonumber(b), range_nm = tonumber(r), alt_ft = tonumber(a), type = ty, aspect = asp:upper() } end
        end
        return 'ewrs', out
    end
    if text:find('AWACS', 1, true) then
        local b, r, a = text:match('BRA, (%d+) for (%d+), at (%d+)')
        local asp = text:match('BRA, %d+ for %d+, at %d+,%s*(%a+)')
        if b then return 'stock', { { brg_mag = tonumber(b), range_nm = tonumber(r), alt_ft = tonumber(a), type = 'bogey',
                                      aspect = asp and asp:upper() or nil } } end
        return 'stock', {}
    end
    return nil
end

-- Magnetic variation by map, degrees east (true = magnetic + value). The per-map values MOOSE uses
-- (UTILS.GetMagneticDeclination), keyed by DCS's theatre name. Override or extend with Config.MAGVAR.
Awacs.MAGVAR = {
    Caucasus = 6, Nevada = 12, Normandy = -10, PersianGulf = 2, TheChannel = -10, Syria = 5, MarianaIslands = 2,
    Falklands = 12, SinaiMap = 4.8, Kola = 15, Afghanistan = 3, Iraq = 4.4, GermanyCW = 0.1,
}
-- Config.AWACS_DECL (per source) was measured on this map; every other map is that figure plus the difference in variation.
Awacs.MAGVAR_REF = 'Caucasus'

local function magvar_of(name)
    local c = Config.MAGVAR
    if type(c) == 'table' and c[name] ~= nil then return c[name] end
    return Awacs.MAGVAR[name]
end

-- A map with no entry (a new release) is taken as 0 degrees of variation. No map name at all (an old hook) keeps
-- the Caucasus figures as measured.
local function declination(source)
    local d = (Config.AWACS_DECL or {})[source] or 0
    local ref = magvar_of(Awacs.MAGVAR_REF) or 0
    if not Awacs.theatre then return d end
    local here = magvar_of(Awacs.theatre)
    if here == nil then
        if not Awacs.warned_map then
            Awacs.warned_map = true
            AADLog.Info('awacs: no magnetic variation for map "%s": using 0 degrees', tostring(Awacs.theatre))
        end
        here = 0
    end
    return d + (here - ref)
end

-- Local flat-earth offset: good to a few hundred meters over 100 NM, far inside the 5 degree / 5 NM rounding of the sources.
local function project(lat, lon, brg_true_deg, range_nm)
    local b = math.rad(brg_true_deg)
    local north, east = range_nm * math.cos(b), range_nm * math.sin(b)
    return lat + north / 60, lon + east / (60 * math.cos(math.rad(lat)))
end

local function offset_nm(lat1, lon1, lat2, lon2)
    local north = (lat2 - lat1) * 60
    local east = (lon2 - lon1) * 60 * math.cos(math.rad((lat1 + lat2) / 2))
    local rng = math.sqrt(north * north + east * east)
    local brg = (math.deg(math.atan2(east, north)) + 360) % 360
    return brg, rng
end

----------------------------------------------------------------------------------------------------
-- Contact store
----------------------------------------------------------------------------------------------------

-- Callsign filter. A stock AWACS reply names who it answers: "AWACS (Overlord1-1): Enfield 1, Overlord1-1, BRA, 345 for 50, ...".
-- On a server the other players' replies reach the log too. The hook writes the player's own callsign from the game
-- ("---- self callsign ---- Enfield11 (via ...)", rewritten whenever it changes, e.g. after a respawn or slot change);
-- a reply addressed to another flight is ignored. The callsign comes from the game only: it is never guessed from the radio
-- text. Until the hook has reported one, stock AWACS replies are ignored. Flights compare by name and flight number
-- ("Enfield 1" = "Enfield 1-1" = "Enfield11").
local function flight_key(cs)
    if not cs then return nil end
    local name = cs:gsub('[^%a]', ''):lower()
    local num = cs:match('%d')
    if name == '' or not num then return nil end
    return name .. num
end

-- A stock AWACS reply is used only when the game has told us the player's callsign and the reply is addressed to it. With no
-- callsign (the game call failed, or the hook is not installed) every stock AWACS reply is ignored. EWRS lines carry no callsign.
function Awacs.IsForMe(text)
    local cs = text:match('^AWACS %b(): ([^,]+), ')
    if not cs then return true end                  -- not a stock AWACS reply
    if not Awacs.my_flight then return false end
    local key = flight_key(cs)
    if not key then return false end
    return key == Awacs.my_flight
end

-- Text for the center of the wheel.
function Awacs.StatusText()
    if not Config.AWACS_ENABLED then return nil end
    return Awacs.my_callsign and ('ID: ' .. Awacs.my_callsign) or 'ID: none'
end

function Awacs.Ingest(msg)
    if not msg.lat then return 0 end   -- no own position at the time: cannot place the contacts
    if not Awacs.IsForMe(msg.text) then
        Awacs.ignored = (Awacs.ignored or 0) + 1
        if Awacs.ignored <= 3 then AADLog.Info('awacs: reply for another flight ignored: %s', msg.text:sub(1, 80)) end
        return 0
    end
    local source, list = Awacs.ParseText(msg.text)
    if not source or #list == 0 then return 0 end
    local keep = {}
    for _, c in ipairs(Awacs.contacts) do
        if c.src ~= source then keep[#keep + 1] = c end
    end
    local dec = declination(source)
    local added = {}
    for _, e in ipairs(list) do
        local lat, lon = project(msg.lat, msg.lon, e.brg_mag + dec, e.range_nm)
        added[#added + 1] = { src = source, lat = lat, lon = lon, alt_ft = e.alt_ft, type = e.type, t = msg.t,
                              range_nm = e.range_nm, brg_mag = e.brg_mag, aspect = e.aspect, fresh = true }
    end
    -- Ground velocity from the previous report of the same group (same source, nearest plausible position).
    for _, n in ipairs(added) do
        local best, bd
        for _, p in ipairs(Awacs.contacts) do
            local dt = n.t - p.t
            if p.src == source and dt >= (Config.AWACS_VEL_MIN_DT_S or 8) and dt <= (Config.AWACS_MAX_AGE_S or 90)
                and math.abs((p.alt_ft or 0) - (n.alt_ft or 0)) <= 6000 then
                local _, d = offset_nm(p.lat, p.lon, n.lat, n.lon)
                local lim = (Config.AWACS_QUANT_NM or 3) + dt * (Config.AWACS_SPEED_KT or 350) / 3600 * 2
                if d <= lim and (not bd or d < bd) then best, bd = p, d end
            end
        end
        if best then
            local dt = n.t - best.t
            local vn = (n.lat - best.lat) * 60 / dt
            local ve = (n.lon - best.lon) * 60 * math.cos(math.rad(n.lat)) / dt
            local a = Config.AWACS_VEL_SMOOTH or 0.5
            if best.vn then vn, ve = a * vn + (1 - a) * best.vn, a * ve + (1 - a) * best.ve end
            local gs = math.sqrt(vn * vn + ve * ve) * 3600
            if gs <= (Config.AWACS_MAX_GS_KT or 1500) then
                n.vn, n.ve, n.gs_kt = vn, ve, gs
                n.reports = (best.reports or 1) + 1
            end
            -- Closure from the reported ranges (each is relative to us at its time): the real closing speed.
            if n.range_nm and best.range_nm then
                local cl = (best.range_nm - n.range_nm) / dt * 3600
                if best.closure_meas then cl = a * cl + (1 - a) * best.closure_meas end
                n.closure_meas = cl
            end
        end
    end
    -- Stock AWACS answers one group per request: new answers replace the old only when they are the same group.
    if source == 'stock' then
        keep = {}
        for _, c in ipairs(Awacs.contacts) do
            local replaced = false
            for _, n in ipairs(added) do
                local _, d = offset_nm(c.lat, c.lon, n.lat, n.lon)
                if c.src == 'stock' and d < (Config.AWACS_SAME_GROUP_NM or 8) then replaced = true end
            end
            if not replaced then keep[#keep + 1] = c end
        end
    end
    for _, n in ipairs(added) do keep[#keep + 1] = n end
    Awacs.contacts = keep
    Awacs.ingested = Awacs.ingested + #added
    Awacs.revision = Awacs.revision + 1
    return #added
end

function Awacs.Prune(now)
    local keep, max_age = {}, Config.AWACS_MAX_AGE_S or 90
    for _, c in ipairs(Awacs.contacts) do
        if now - c.t <= max_age and c.t <= now + 5 then keep[#keep + 1] = c end
    end
    Awacs.contacts = keep
end

-- The AWACS / BRAA feature reads a file through io, which DCS removes from the Jester Lua state unless
-- Scripts\\missionscripting.lua is de-sanitised. Without io the feature stays off (checked once).
local io_state
function Awacs.Enabled()
    if not Config.AWACS_ENABLED then return false end
    if io_state == nil then
        io_state = (type(io) == 'table' and type(io.open) == 'function') and true or false
        if not io_state then AADLog.Info('awacs: io is not available in this Lua state (missionscripting.lua is sanitised): AWACS cues are off') end
    end
    return io_state
end

-- Read what the hook appended since the last poll. Never throws.
function Awacs.Poll()
    if not Awacs.Enabled() then return end
    local now = now_seconds()
    Awacs.polled = Awacs.polled + 1
    local ok, err = pcall(function()
        local f = io.open(Config.AWACS_FILE, 'r')
        if not f then
            if not Awacs.warned then Awacs.warned = true AADLog.Info('awacs: cannot open %s', tostring(Config.AWACS_FILE)) end
            return
        end
        local size = f:seek('end') or 0
        -- The hook truncates the file when DCS starts: start over when it is shorter than what was read.
        if size < Awacs.offset then Awacs.offset = 0 Awacs.contacts = {} end
        if not Awacs.started then
            -- First look at the file (Director load or CTRL+R): the file spans missions, so start at the last
            -- '---- simulation start ----' marker the hook wrote. Anything older belongs to another mission clock.
            Awacs.started = true
            f:seek('set', 0)
            local all = f:read(size) or ''
            local pos, last = 1, 0
            while true do
                local i = all:find('---- simulation start ----', pos, true)
                if not i then break end
                last = i
                pos = i + 1
            end
            Awacs.offset = last > 0 and (last - 1) or size
            Awacs.contacts = {}
        end
        if size > Awacs.offset then
            f:seek('set', Awacs.offset)
            local data = f:read(size - Awacs.offset) or ''
            -- Only whole lines: leave a half-written last line for the next poll.
            local last_nl = data:match('^.*()\n')
            if last_nl then
                Awacs.offset = Awacs.offset + last_nl
                for line in data:sub(1, last_nl):gmatch('[^\n]+') do
                    if line:find('---- simulation start ----', 1, true) then
                        Awacs.theatre = line:match('theatre=(%S+)') or Awacs.theatre
                        Awacs.contacts = {}   -- a new mission: its clock restarts
                        Awacs.my_flight, Awacs.my_callsign = nil, nil
                        Awacs.revision = Awacs.revision + 1
                    end
                    local own = line:match('^%-%-%-%- self callsign %-%-%-%- (.-) %(via') or line:match('^%-%-%-%- self callsign %-%-%-%- (%S+)$')
                    if own and flight_key(own) then
                        Awacs.my_flight = flight_key(own)
                        Awacs.my_callsign = own
                        AADLog.Info('awacs: own callsign "%s" from the game', own)
                    end
                    local m = Awacs.ParseLine(line)
                    if m and (m.kind == 'trigger' or m.kind == 'radio' or m.kind == 'show') then
                        local n = Awacs.Ingest(m)
                        if n > 0 and Config.AWACS_LOG then
                            AADLog.Info('awacs: %d contact(s) from %s message t=%.0f', n, (Awacs.ParseText(m.text)), m.t)
                        end
                    end
                end
            end
        end
        f:close()
    end)
    if not ok and not Awacs.warned then Awacs.warned = true AADLog.Info('awacs: poll error %s', tostring(err)) end
    Awacs.Prune(now)
end

----------------------------------------------------------------------------------------------------
-- Matching a cue to a contact
----------------------------------------------------------------------------------------------------

local function own_state()
    local lat, lon, alt_ft
    pcall(function()
        local a = GetJester().awareness
        lat = a:GetObservation('latitude').value * 180 / math.pi
        lon = a:GetObservation('longitude').value * 180 / math.pi
        alt_ft = a:GetObservation('barometric_altitude'):ConvertTo(ft).value
    end)
    local hdg
    pcall(function() hdg = require('aaplus.Cues').OwnHeading() end)
    return lat, lon, alt_ft, hdg
end

-- Own ground velocity, NM per second north / east (nil when unknown).
local function own_velocity()
    local vn, ve
    pcall(function()
        local v = GetJester().awareness:GetObservation('gods_velocity_ned')
        local x, y = v.x, v.y
        if type(x) ~= 'number' then x = x:ConvertTo(mps).value end
        if type(y) ~= 'number' then y = y:ConvertTo(mps).value end
        vn, ve = x * 1.94384 / 3600, y * 1.94384 / 3600
    end)
    return vn, ve
end

local ASPECT_CLOSING = { HOT = 1.0, FLANKING = 0.7, FLANK = 0.7, BEAMING = 0.0, BEAM = 0.0, COLD = -1.0, DRAG = -1.0 }

-- Threat data for a contact as seen from our position now: the contact is dead-reckoned when its velocity is
-- known. Closure = our speed along the line of sight + the contact's (its measured velocity, or the aspect word
-- times Config.AWACS_ASSUMED_KT). Time to merge only when closing.
-- Aircraft class from the reported type (EWRS names: NATO names for Russian types, US names otherwise).
-- Stock AWACS gives no type ('bogey'): unknown.
function Awacs.TypeClass(ty)
    if type(ty) ~= 'string' or ty == '' or ty == 'bogey' then return nil end
    local t = ty:lower()
    local classes = Config.AWACS_TYPE_CLASSES or {}
    for _, cls in ipairs({ 'HELO', 'ATTACK', 'FIGHTER' }) do   -- fixed order: 'blackhawk' is a helo, 'thunderbolt' attack
        for _, name in ipairs(classes[cls] or {}) do
            if t:find(name, 1, true) then return cls end
        end
    end
    return 'OTHER'
end

function Awacs.ThreatInfo(c, now, lat, lon)
    local age = math.max(0, now - c.t)
    -- Velocity from rounded reports is noisy (EWRS rounds to 5 deg / 5 NM): trust it after three reports.
    local vel_ok = c.vn and (c.reports or 0) >= (Config.AWACS_VEL_MIN_REPORTS or 3)
    local clat, clon = c.lat, c.lon
    if vel_ok then clat, clon = clat + c.vn * age / 60, clon + c.ve * age / (60 * math.cos(math.rad(clat))) end
    local brg, rng = offset_nm(lat, lon, clat, clon)
    local un, ue = math.cos(math.rad(brg)), math.sin(math.rad(brg))
    local ovn, ove = own_velocity()
    local own_cl = ovn and (ovn * un + ove * ue) * 3600 or 0
    local gs = vel_ok and c.gs_kt or nil
    -- Aspect: EWRS's word is real aspect; stock's hot/cold is only closure, so stock gets the aspect from its
    -- measured track (three reports), or none.
    local aspect = (c.src ~= 'stock') and c.aspect or nil
    local track_aspect
    if vel_ok and gs and gs > 80 then
        local cosA = -(c.vn * un + c.ve * ue) * 3600 / gs
        local A = math.deg(math.acos(math.max(-1, math.min(1, cosA))))
        track_aspect = A <= 30 and 'HOT' or A <= 70 and 'FLANKING' or A <= 110 and 'BEAMING' or 'COLD'
    end
    if not aspect then aspect = track_aspect end
    local closure
    if vel_ok and ovn then
        closure = own_cl - (c.vn * un + c.ve * ue) * 3600                 -- geometry now (both velocities known)
    elseif c.closure_meas then
        closure = c.closure_meas                                          -- range trend between reports
    elseif c.src == 'stock' and c.aspect then
        -- One stock call: hot = closing, cold = opening, size unknown: our own speed along the line of sight.
        local w = c.aspect
        if w == 'HOT' then closure = math.max(own_cl, 100) elseif w == 'COLD' then closure = math.min(own_cl, -100) end
    elseif aspect and ASPECT_CLOSING[aspect] then
        closure = own_cl + ASPECT_CLOSING[aspect] * (Config.AWACS_ASSUMED_KT or 450)
    end
    local ttm
    if closure and closure > 50 then ttm = rng / (closure / 3600) end
    return { range_nm = rng, brg_true = brg, aspect = aspect, gs_kt = gs, closure_kt = closure, ttm = ttm,
             alt_ft = c.alt_ft, age = age, dr = vel_ok, class = Awacs.TypeClass(c.type), type = c.type }
end

-- The contact a cue most plausibly is, and the antenna elevation (degrees) to it.
-- own = optional { lat, lon, alt_ft, hdg } (tests); az is relative to the nose, range_nm may be nil (RWR cues).
function Awacs.Match(az, range_nm, now, own, az_tol)
    local lat, lon, alt_ft, hdg
    if own then lat, lon, alt_ft, hdg = own.lat, own.lon, own.alt_ft, own.hdg else lat, lon, alt_ft, hdg = own_state() end
    if not (lat and lon and alt_ft and hdg) then return nil, 'no own state' end
    local cue_brg = (hdg + az) % 360
    local best, best_score
    for _, c in ipairs(Awacs.contacts) do
        local age = math.max(0, now - c.t)
        if age <= (Config.AWACS_MAX_AGE_S or 90) then
            local brg, rng = offset_nm(lat, lon, c.lat, c.lon)
            local unc = (Config.AWACS_QUANT_NM or 3) + age * (Config.AWACS_SPEED_KT or 350) / 3600
            local dang = math.abs(wrap180(brg - cue_brg))
            local cross = rng * math.rad(dang)
            local drng = range_nm and math.abs(rng - range_nm) or 0
            local ok, score
            if range_nm or not az_tol then
                ok = cross <= unc and drng <= unc + 2
                score = cross + drng
            else
                -- A bearing-only cue (RWR clock position is coarse): accept anything inside the sector,
                -- nearest bearing first, nearer contact on a tie.
                ok = dang <= az_tol + math.deg(unc / math.max(rng, 1))
                score = dang + rng / 100
            end
            if ok then
                if not best_score or score < best_score then
                    best, best_score = c, score
                    best.m_brg, best.m_rng, best.m_age, best.m_dang = brg, rng, age, dang
                end
            end
        end
    end
    if not best then return nil, 'no contact near cue' end
    local elev = math.deg(math.atan2(best.alt_ft - alt_ft, math.max(best.m_rng, 1) * FT_PER_NM))
    local th
    pcall(function() th = Awacs.ThreatInfo(best, now, lat, lon) end)
    return elev, { type = best.type, src = best.src, alt_ft = best.alt_ft, range_nm = best.m_rng, age = best.m_age,
                   brg_true = best.m_brg, dang = best.m_dang, threat = th, contact = best }
end

-- A new report that should become a search cue: the nearest unconsumed contact (stock BRA replies; EWRS
-- only with Config.AWACS_EWRS_CUES). Each contact is handed out once. Returns { az, range_nm, alt_ft, type, src } or nil.
function Awacs.TakeCue()
    if not (Awacs.Enabled() and Config.AWACS_CUES) then return nil end
    local want
    for _, c in ipairs(Awacs.contacts) do
        if c.fresh and c.src == 'stock' then want = true end
    end
    if not want then return nil end
    local lat, lon, alt_ft, hdg = own_state()
    if not (lat and lon and hdg) then return nil end   -- keep them fresh: try again next second
    local now = now_seconds()
    local best
    for _, c in ipairs(Awacs.contacts) do
        if c.fresh and c.src == 'stock' then
            if now - c.t > 15 then c.fresh = false   -- too old to be worth a search of its own
            else
                local brg, rng = offset_nm(lat, lon, c.lat, c.lon)
                local az = wrap180(brg - hdg)
                -- Outside the radar's gimbal limits is still a cue: Cues.Best skips it until we turn toward it
                -- or it drifts back inside.
                if rng <= (Config.AWACS_CUE_MAX_NM or 60) and (not best or rng < best.range_nm) then
                    best = { az = az, range_nm = rng, alt_ft = c.alt_ft, type = c.type, src = c.src, c = c }
                end
            end
        end
    end
    for _, c in ipairs(Awacs.contacts) do if c.src == 'stock' then c.fresh = false end end
    if not best then return nil end
    best.contact, best.c = best.c, nil
    return best
end

-- Altitude difference (ft) that puts two contacts in different groups at this range: one radar bar apart
-- (Config.AWACS_GROUP_ALT_DEG, about 6,400 ft at 30 NM), never less than 3,000 ft (reports are in 1,000 ft steps) or
-- more than 12,000 ft.
function Awacs.GroupAltFt(range_nm)
    local deg = Config.AWACS_GROUP_ALT_DEG or 2.0
    local ft = (range_nm or 30) * math.tan(math.rad(deg)) * FT_PER_NM
    return math.max(Config.AWACS_GROUP_ALT_MIN_FT or 3000, math.min(Config.AWACS_GROUP_ALT_MAX_FT or 12000, ft))
end

-- Are two stored contacts one group? Within AWACS_SAME_GROUP_NM sideways and one bar apart vertically.
-- slack > 1 loosens both (matching the same group between pictures: it drifts).
function Awacs.SameGroup(a, b, range_nm, slack)
    slack = slack or 1
    if Awacs.Dist(a, b) > (Config.AWACS_SAME_GROUP_NM or 8) * slack then return false end
    if a.alt_ft and b.alt_ft and math.abs(a.alt_ft - b.alt_ft) > Awacs.GroupAltFt(range_nm) * slack then return false end
    return true
end

-- Distance (NM) between two stored contacts.
function Awacs.Dist(a, b)
    local _, d = offset_nm(a.lat, a.lon, b.lat, b.lon)
    return d
end

-- A new EWRS picture as groups: contacts within AWACS_SAME_GROUP_NM of each other are one group (EWRS lists every
-- aircraft). Returns up to Config.EWRS_MAX_CUES groups, highest threat first, inside the gimbal limits before the
-- rest: { az, range_nm, alt_ft, type, contact = lead contact, n = members, score }. Nil when there is no new picture.
function Awacs.TakeEwrsGroups()
    if not (Awacs.Enabled() and Config.AWACS_CUES and Config.AWACS_EWRS_CUES) then
        for _, c in ipairs(Awacs.contacts) do if c.src == 'ewrs' then c.fresh = false end end
        return nil
    end
    local want
    for _, c in ipairs(Awacs.contacts) do
        if c.fresh and c.src == 'ewrs' then want = true end
    end
    if not want then return nil end
    local lat, lon, alt_ft, hdg = own_state()
    if not (lat and lon and hdg) then return nil end
    local now = now_seconds()
    local Cues = require 'aaplus.Cues'
    local groups = {}
    for _, c in ipairs(Awacs.contacts) do
        if c.fresh and c.src == 'ewrs' and now - c.t <= 15 then
            local brg, rng = offset_nm(lat, lon, c.lat, c.lon)
            if rng <= (Config.AWACS_CUE_MAX_NM or 60) then
                local az = wrap180(brg - hdg)
                local th, score
                pcall(function()
                    th = Awacs.ThreatInfo(c, now, lat, lon)
                    if th.alt_ft and alt_ft then
                        th.elev = math.deg(math.atan2(th.alt_ft - alt_ft, math.max(th.range_nm, 1) * FT_PER_NM))
                    end
                    score = (Cues.Threat({ source = 'AWACS', az = az, range_nm = rng, th = th }))
                end)
                score = score or -rng
                local g
                for _, o in ipairs(groups) do
                    if Awacs.SameGroup(o.contact, c, rng) then g = o break end
                end
                if g then
                    g.n = g.n + 1
                    if score > g.score then
                        g.az, g.range_nm, g.alt_ft, g.type, g.contact, g.score = az, rng, c.alt_ft, c.type, c, score
                    end
                else
                    groups[#groups + 1] = { az = az, range_nm = rng, alt_ft = c.alt_ft, type = c.type, contact = c, n = 1, score = score }
                end
            end
        end
    end
    for _, c in ipairs(Awacs.contacts) do if c.src == 'ewrs' then c.fresh = false end end
    local lim = Config.CUE_START_AZ or 58
    for _, g in ipairs(groups) do g.key = g.score - (math.abs(g.az) > lim and 100 or 0) end
    table.sort(groups, function(a, b) return a.key > b.key end)
    local cap = Config.EWRS_MAX_CUES or 5
    while #groups > cap do groups[#groups] = nil end
    for _, g in ipairs(groups) do g.key = nil end
    return groups
end

-- Own position for callers outside this module.
function Awacs.OwnState() return own_state() end
function Awacs.Now() return now_seconds() end

-- For Search: elevation to the cue's contact, or nil.
function Awacs.Elevation(cue, keep_on_miss)
    if not (Awacs.Enabled() and Config.AWACS_ELEVATION) or #Awacs.contacts == 0 then return nil end
    local Cues = require 'aaplus.Cues'
    local az = cue.az
    pcall(function() az = Cues.CurrentAz(cue) end)
    if not az then return nil end
    local tol
    if not cue.range_nm then tol = (Config.AWACS_RWR_TOL_DEG or 15) + (cue.spread or 0) end
    local old_abs, old_rng = cue.aw_abs, cue.aw_range_nm
    cue.aw_abs, cue.aw_range_nm = nil, nil
    local elev, info = Awacs.Match(az, cue.range_nm, now_seconds(), nil, tol)
    if not elev and keep_on_miss then cue.aw_abs, cue.aw_range_nm = old_abs, old_rng end
    if elev then
        -- A cue with no range of its own (RWR) takes the contact's: the search then sets the radar range
        -- and the cursor there instead of running the cursor out to the edge of the screen.
        if not cue.range_nm and Config.AWACS_CUE_RANGE ~= false then cue.aw_range_nm = info.range_nm end
        -- The cue's bearing is refined to the contact's. A cursor cue is the pilot's own placement, so it only
        -- snaps when the contact is close to where the cursor is.
        if Config.AWACS_REFINE_AZ ~= false and (cue.source ~= 'CURSOR' or info.dang <= (Config.AWACS_CURSOR_SNAP_DEG or 10)) then
            cue.aw_abs = wrap180(info.brg_true)
        end
    end
    return elev, info
end

return Awacs
