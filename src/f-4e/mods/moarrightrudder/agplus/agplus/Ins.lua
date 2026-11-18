-- INS position check from TACAN (read-only for now).
--   * Beacon positions come from the map's own beacon list: <DCS install>\Mods\terrains\<map>\beacons.lua.
--     Only the map's built-in airfield beacons are there (not carriers or beacons placed in a mission).
--   * The cockpit gives the TACAN bearing and range to the tuned station.
--   * From those two, Jester can work out where the aircraft really is and compare it with the INS.
-- Nothing here touches the cockpit.
local Config = require('agplus.Config')
local AGLog = require('agplus.Log')

local Ins = {}

local RAD = math.pi / 180
local NM_PER_DEG = 60

-- Which map the aircraft is over, from its latitude and longitude (same boxes as WRCS), the folder name
-- under Mods\terrains, and the magnetic variation (degrees, east positive).
local MAPS = {
    { name = "Caucasus",       folder = "Caucasus",       lat_min = 41,  lat_max = 44, lon_min = 36,   lon_max = 46,  dec = 6   },
    { name = "Syria",          folder = "Syria",          lat_min = 32,  lat_max = 37, lon_min = 34,   lon_max = 42,  dec = 5   },
    { name = "PersianGulf",    folder = "PersianGulf",    lat_min = 22,  lat_max = 30, lon_min = 50,   lon_max = 60,  dec = 2   },
    { name = "Sinai",          folder = "Sinai",          lat_min = 27,  lat_max = 33, lon_min = 30,   lon_max = 36,  dec = 4.8 },
    { name = "NTTR",           folder = "Nevada",         lat_min = 34,  lat_max = 40, lon_min = -120, lon_max = -112, dec = 12 },
    { name = "Normandy",       folder = "Normandy",       lat_min = 47,  lat_max = 51, lon_min = -3,   lon_max = 3,   dec = -10 },
    { name = "TheChannel",     folder = "TheChannel",     lat_min = 49,  lat_max = 53, lon_min = -2,   lon_max = 5,   dec = -10 },
    { name = "MarianaIslands", folder = "MarianaIslands", lat_min = 10,  lat_max = 20, lon_min = 140,  lon_max = 150, dec = 2   },
    { name = "Falklands",      folder = "Falklands",      lat_min = -55, lat_max = -48, lon_min = -65, lon_max = -55, dec = 12 },
    { name = "Kola",           folder = "Kola",           lat_min = 65,  lat_max = 72, lon_min = 25,   lon_max = 42,  dec = 15  },
    { name = "Afghanistan",    folder = "Afghanistan",    lat_min = 30,  lat_max = 38, lon_min = 62,   lon_max = 72,  dec = 3   },
}

local TACAN_TYPES = { BEACON_TYPE_TACAN = true, BEACON_TYPE_VORTAC = true, BEACON_TYPE_VOR_DME = true }

local cache = {}     -- folder -> list of beacons (or false when the file could not be read)

function Ins.MapAt(lat, lon)
    for _, m in ipairs(MAPS) do
        if lat >= m.lat_min and lat <= m.lat_max and lon >= m.lon_min and lon <= m.lon_max then return m end
    end
    return nil
end

-- TACAN channel paired with a VOR/DME frequency (MHz).
local function channel_from_freq(mhz)
    if mhz >= 112 then return math.floor((mhz - 112) * 10 + 57 + 0.5) end
    return math.floor((mhz - 108) * 10 + 17 + 0.5)
end

local function parse(text)
    local list = {}
    local body = text:match('beacons%s*=%s*(%b{})')
    if not body then return list end
    body = body:sub(2, -2)
    for block in body:gmatch('%b{}') do
        local btype = block:match('type%s*=%s*(BEACON_TYPE_[%w_]+)')
        if btype and TACAN_TYPES[btype] then
            local lat, lon = block:match('positionGeo%s*=%s*{%s*latitude%s*=%s*([%-%d%.]+)%s*,%s*longitude%s*=%s*([%-%d%.]+)')
            local _, alt = block:match('position%s*=%s*{%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)')
            local ch = tonumber(block:match('channel%s*=%s*(%d+)'))
            local derived, band = false, 'X'
            if not ch then
                local f = tonumber(block:match('frequency%s*=%s*([%d%.]+)'))
                if f then
                    ch = channel_from_freq(f / 1e6) derived = true
                    local tenths = f / 1e5
                    if math.abs(tenths - math.floor(tenths + 0.5)) > 0.25 then band = 'Y' end   -- a .x5 frequency
                end
            end
            if lat and lon and ch then
                list[#list + 1] = {
                    name = block:match("display_name%s*=%s*_%('([^']*)'%)") or '?',
                    callsign = block:match("callsign%s*=%s*'([^']*)'") or '',
                    channel = ch, band = band, derived = derived, type = btype,
                    lat = tonumber(lat), lon = tonumber(lon), alt = tonumber(alt) or 0,
                }
            end
        end
    end
    return list
end

-- The TACAN-capable beacons of a map folder (cached). nil if the file cannot be read.
function Ins.Beacons(folder)
    if cache[folder] ~= nil then return cache[folder] or nil end
    local text
    pcall(function()
        local fh = io.open(Config.DCS_INSTALL .. [[\Mods\terrains\]] .. folder .. [[\beacons.lua]], 'r')
        if fh then text = fh:read('*a') fh:close() end
    end)
    if not text then
        cache[folder] = false
        AGLog.Info('ins: no beacon list for %s', folder)
        return nil
    end
    local ok, list = pcall(parse, text)
    if not ok then
        cache[folder] = false
        AGLog.Info('ins: beacon list parse failed: %s', tostring(list))
        return nil
    end
    cache[folder] = list
    AGLog.Info('ins: %d TACAN-capable beacons on %s', #list, folder)
    return list
end

-- Flat-earth offset in NM (east, north) of point 2 from point 1. Fine over TACAN ranges.
local function offset_nm(lat1, lon1, lat2, lon2)
    local north = (lat2 - lat1) * NM_PER_DEG
    local east = (lon2 - lon1) * NM_PER_DEG * math.cos(((lat1 + lat2) / 2) * RAD)
    return east, north
end

function Ins.Distance(lat1, lon1, lat2, lon2)
    local e, n = offset_nm(lat1, lon1, lat2, lon2)
    return math.sqrt(e * e + n * n)
end

-- The nearest beacons to a position, nearest first. n defaults to 3.
function Ins.Nearest(list, lat, lon, n)
    local out = {}
    for _, b in ipairs(list) do out[#out + 1] = { b = b, d = Ins.Distance(lat, lon, b.lat, b.lon) } end
    table.sort(out, function(a, c) return a.d < c.d end)
    local r = {}
    for i = 1, math.min(n or 3, #out) do r[i] = out[i] end
    return r
end

-- Where the aircraft is, from a station position and the TACAN bearing (magnetic, to the station) and slant
-- range (NM). height_m is the aircraft's height above the station. Returns lat, lon (degrees).
function Ins.Position(beacon, bearing_mag, slant_nm, dec, height_m)
    local slant_m = slant_nm * 1852
    local ground_m = math.sqrt(math.max(0, slant_m * slant_m - (height_m or 0) ^ 2))
    local r = ground_m / 1852
    local from_station = (bearing_mag + (dec or 0) + 180) * RAD     -- true bearing station -> aircraft
    local north = r * math.cos(from_station)
    local east = r * math.sin(from_station)
    local lat = beacon.lat + north / NM_PER_DEG
    local lon = beacon.lon + east / (NM_PER_DEG * math.cos(beacon.lat * RAD))
    return lat, lon
end

-- ---- Live measurement from the cockpit -----------------------------------------------------------------------
-- The HSI/BDHI properties are already in degrees but tagged as radians, so a ConvertTo(deg) result is 57.2958 times
-- too large and is divided back here.
local DEG = 180 / math.pi

local function prop(path, name)
    local ok, v = pcall(function() return GetProperty(path, name).value end)
    if ok then return v end
    return nil
end

local function deg_of(path, name)
    local v = prop(path, name)
    if v == nil then return nil end
    local n
    pcall(function() n = v:ConvertTo(deg).value end)
    if type(n) == 'number' then return n / DEG end
    return nil
end

local function nm_of(path, name)
    local v = prop(path, name)
    if v == nil then return nil end
    local n
    pcall(function() n = v:ConvertTo(NM).value end)
    if type(n) == 'number' then return n end
    return nil
end

local INS_PATH = '/INS ASN-63/Nav Comp Outputs Calculator'

-- The position the INS believes (degrees), or nil.
-- Raw TACAN range sources (NM). The two "signal" ones are the receiver's own output, ahead of any instrument selector, so they
-- should not depend on what either seat has selected. The third is the rear seat's instrument.
local RANGE_SOURCES = {
    { 'mode switch', '/Navigation Mode Selector Switch', 'Distance TACAN signal' },
    { 'front panel', '/Flight Director and Nav Selector Panel/Navigation Function Bearing Distance Switch Logic', 'TACAN Range Input signal' },
    { 'rear gauge',  '/Horizontal Situation Indicator/HSI Meter', 'Distance Indication' },
}

-- All three, as { [name] = NM or nil }.
function Ins.RangeReadings()
    local out = {}
    for _, src in ipairs(RANGE_SOURCES) do out[src[1]] = nm_of(src[2], src[3]) end
    return out
end

-- The TACAN range (NM): the first source that reads a plausible value. Returns the value and the source name.
function Ins.RearRange()
    for _, src in ipairs(RANGE_SOURCES) do
        local v = nm_of(src[2], src[3])
        if v and v > 0.3 then return v, src[1] end
    end
    return nil
end

-- The front seat's bearing/distance selector: its switch position and the mode number the panel logic reports (numbers or nil).
function Ins.FrontSelector()
    local base = '/Flight Director and Nav Selector Panel/Navigation Function Bearing Distance Switch Logic'
    local function num(path, name)
        local v = prop(path, name)
        if v == nil then return nil end
        return tonumber(v) or tonumber(tostring(v):match('(-?[%d%.]+)'))
    end
    return num(base .. '/Navigation Function Bearing Distance Selector Switch', 'Position'), num(base, 'Navigation Mode Selected')
end

-- Range on the other instrument (the component called BDHI Meter), for comparison in the log.
function Ins.OtherRange()
    return nm_of('/Bearing Distance Heading Indicator/BDHI Meter', 'Distance Indication')
end

function Ins.InsPosition()
    local la, lo = deg_of(INS_PATH, 'Latitude (INS)'), deg_of(INS_PATH, 'Longitude (INS)')
    if la and lo and math.abs(la) <= 90 then return la, lo end
    return nil
end

-- The real position (degrees), or nil. Used only for logging how good a fix was.
function Ins.TruePosition()
    local la, lo = deg_of('/Gods INS', 'Latitude'), deg_of('/Gods INS', 'Longitude')
    if la and lo and math.abs(la) <= 90 then return la, lo end
    return nil
end

-- Where the aircraft is, from the TACAN the crew has tuned. Needs the HSI to be showing TACAN (the front seat's
-- NAV function set to TACAN). Which beacon it is gets worked out from the INS position: the beacon whose
-- bearing and range give a position closest to where the INS thinks it is (or only `want`, when the beacon is
-- already known). Returns a table, or nil and a reason.
-- Ground velocity (north, east) in m/s, plus the observation key that worked, or nil.
function Ins.GroundVelocity()
    for _, key in ipairs({ 'velocity_ned', 'gods_velocity_ned' }) do
        local vx, vy
        pcall(function()
            local v = GetJester().awareness:GetObservation(key)
            local function comp(q)
                local n
                pcall(function() n = q:ConvertTo(mps).value end)
                if type(n) ~= 'number' then pcall(function() n = q.value end) end
                if type(n) ~= 'number' then n = tonumber(tostring(q):match('(-?[%d%.]+)')) end
                return n
            end
            vx, vy = comp(v.x), comp(v.y)
        end)
        if type(vx) == 'number' and type(vy) == 'number' then return vx, vy, key end
    end
    return nil
end

-- True bearing (degrees) from point 1 to point 2.
function Ins.Bearing(lat1, lon1, lat2, lon2)
    local e, n = offset_nm(lat1, lon1, lat2, lon2)
    return (math.atan2(e, n) / RAD) % 360
end

-- One line of raw readings next to the truth, for working out the bearing convention (log only).
function Ins.Diag(b)
    local tlat, tlon = Ins.TruePosition()
    local function num(v) return tonumber(v) or tonumber(tostring(v):match('(-?[%d%.]+)')) end
    local BDHI, HSI = '/Bearing Distance Heading Indicator/BDHI Meter', '/Horizontal Situation Indicator/HSI Meter'
    local function f(v) return v and string.format('%.1f', v) or 'nil' end
    local dec = deg_of('/Gods Magnetic Field', 'Magnetic Declination (Variation)')
    local gmh = deg_of('/Gods Magnetic Field', 'Magnetic Heading')
    local insh = deg_of('/INS ASN-63/Nav Comp Outputs Calculator', 'True Heading (INS)')
    local trk
    local gvx, gvy = Ins.GroundVelocity()
    if gvx then trk = (math.atan2(gvy, gvx) / RAD) % 360 end
    local tb, tr
    if tlat and b then
        tb = Ins.Bearing(tlat, tlon, b.lat, b.lon)
        tr = Ins.Distance(tlat, tlon, b.lat, b.lon)
    end
    return string.format('DIAG true brg to station %s rng %s | rear rel %s rng %s | compass %s | front ptr1 %s ptr2 %s rng %s | dec %s | gods mag hdg %s | ins true hdg %s | track %s',
        f(tb), f(tr), f(deg_of(HSI, 'Bearing Pointer Indication')), f(nm_of(HSI, 'Distance Indication')), f(deg_of(BDHI, 'Compass Card Indication')),
        f(deg_of(BDHI, 'Pointer No.1 Indication')), f(deg_of(BDHI, 'Pointer No.2 Indication')), f(nm_of(BDHI, 'Distance Indication')), f(dec), f(gmh), f(insh), f(trk))
end

function Ins.Measure(want)
    local ilat, ilon = Ins.InsPosition()
    if not ilat then return nil, 'no INS position' end
    local map = Ins.MapAt(ilat, ilon)
    if not map then return nil, 'unknown map' end
    local list = Ins.Beacons(map.folder)
    if not list then return nil, 'no beacon list (check Config.DCS_INSTALL)' end

    -- Only the "... Indication" properties read in the live cockpit; the "... signal" ones come back nil.
    -- The REAR seat's instrument is the component called "HSI Meter" (the names are swapped against the cockpits). It follows
    -- the rear BDHI Mode switch that Jester sets, so the front seat's selectors do not matter. The component called
    -- "BDHI Meter" is the front seat's; only its compass card (heading) is used here. A pointer value may be relative to
    -- the nose or already a bearing, so both readings are tried and the one that lands nearest the INS position is kept.
    local BDHI, HSI = '/Bearing Distance Heading Indicator/BDHI Meter', '/Horizontal Situation Indicator/HSI Meter'
    local hdg = deg_of(BDHI, 'Compass Card Indication')
    local sources = {
        { name = 'rear', ptr = deg_of(HSI, 'Bearing Pointer Indication'), rng = nm_of(HSI, 'Distance Indication') },
    }
    local alt_m
    pcall(function() alt_m = GetJester().awareness:GetObservation('barometric_altitude'):ConvertTo(m).value end)

    -- The compass card is MAGNETIC, so a bearing built from it needs the declination added. In 5 Caucasus runs (declination 6.5)
    -- the rear pointer read about one more declination low (pointer = magnetic bearing - true heading), so the declination is
    -- applied twice: true bearing = pointer + card + 2 x declination (residuals within about 1 degree, one at 3).
    local dec = deg_of('/Gods Magnetic Field', 'Magnetic Declination (Variation)') or map.dec or 0
    local function try(brg, rng, d)
        local best
        for _, b in ipairs(want and { want } or list) do
            if want or Ins.Distance(ilat, ilon, b.lat, b.lon) < rng + 6 then
                local la, lo = Ins.Position(b, brg, rng, d or 0, (alt_m or 0) - b.alt)
                local shift = Ins.Distance(ilat, ilon, la, lo)
                if not best or shift < best.shift then best = { b = b, lat = la, lon = lo, shift = shift } end
            end
        end
        return best
    end

    local best, seen = nil, {}
    for _, sc in ipairs(sources) do
        seen[#seen + 1] = string.format('%s ptr %s rng %s', sc.name, sc.ptr and string.format('%.1f', sc.ptr) or 'nil', sc.rng and string.format('%.1f', sc.rng) or 'nil')
        if sc.ptr and sc.rng and sc.rng >= 0.3 then
            for _, mode in ipairs({ 'rel', 'abs' }) do
                local brg = (mode == 'rel') and hdg and ((sc.ptr + hdg) % 360) or (mode == 'abs' and sc.ptr) or nil
                if brg then
                    local c = try(brg, sc.rng, mode == 'rel' and (dec * (Config.INS_BEARING_DEC_FACTOR or 2)) or 0)
                    if c and (not best or c.shift < best.shift) then
                        c.rng, c.brg, c.src = sc.rng, brg, sc.name .. '/' .. mode
                        best = c
                    end
                end
            end
        end
    end
    if not best or best.shift > 2.5 then
        return nil, 'no TACAN match (' .. table.concat(seen, ' | ') .. ', compass ' .. (hdg and string.format('%.1f', hdg) or 'nil') .. ')'
    end
    if best.rng > (Config.INS_BEARING_MAX_RANGE_NM or 20) then return nil, string.format('TACAN too far for a bearing fix (%.0f NM)', best.rng) end
    best.ins_lat, best.ins_lon = ilat, ilon
    return best
end

return Ins
