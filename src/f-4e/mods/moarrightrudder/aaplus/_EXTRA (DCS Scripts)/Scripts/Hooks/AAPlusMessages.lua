-- Jester A/A+ message listener. Logs the trigger, radio and show messages DCS hands to the client, so A/A+ can read
-- what the stock AWACS subtitles and custom GCI scripts (EWRS) say. Player chat is not logged.
-- Output: Saved Games\DCS\Logs\aaplus_messages.txt, one line per message:
--   t=<model time> kind=<callback> dur=<seconds> self=<lat,lon,alt_m,heading_deg> | <text>
-- The file is wiped each time DCS starts. Delete this hook to turn it off. A hook is only loaded at DCS start, so it needs a full restart.
local path = ((lfs and lfs.writedir and lfs.writedir()) or '') .. 'Logs\\aaplus_messages.txt'
local started = false

local function esc(s)
    s = tostring(s == nil and '' or s)
    s = s:gsub('\r', ''):gsub('\n', ' / '):gsub('\t', ' ')
    return s
end

local function now()
    local t = 0
    pcall(function() t = DCS.getModelTime() end)
    return t or 0
end

local function self_snap()
    local out = 'n/a'
    pcall(function()
        local sd = Export.LoGetSelfData()
        if type(sd) == 'table' and type(sd.LatLongAlt) == 'table' then
            out = string.format('%.5f,%.5f,%.0f,%.0f', sd.LatLongAlt.Lat or 0, sd.LatLongAlt.Long or 0,
                sd.LatLongAlt.Alt or 0, math.deg(sd.Heading or 0))
        end
    end)
    return out
end

-- Magnetic declination: DISABLED. Export.LoGetMagneticYaw called from this hook at spawn is the only change
-- that matches two F-4E load-in crashes ("Lua panic: attempt to index a nil value" in Jester's tick).
local function decl()
    return 'off'
end

local function write(line)
    pcall(function()
        local mode = 'a'
        if not started then mode = 'w' started = true end
        local f = io.open(path, mode)
        if f then f:write(line .. '\n') f:close() end
    end)
end

-- The player's own callsign (for A/A+'s AWACS filter). DCS.UNIT_CALLSIGN returns a number-like id ("010"), not the flight callsign the
-- AWACS speaks ("Enfield 1"), so the callsign is read from the mission data instead: the player's unit is found by name and its
-- mission entry holds callsign.name ("Enfield11"). Read lazily at every logged message (never at spawn), so a respawn or a slot change
-- in multiplayer is picked up: a new line is written whenever it changes.
local last_callsign, callsign_fails = nil, 0
local function mission_callsign(unit_name)
    local found
    pcall(function()
        local m = DCS.getCurrentMission().mission
        for _, side in pairs(m.coalition or {}) do
            for _, country in pairs(side.country or {}) do
                for _, kind in ipairs({ 'plane', 'helicopter' }) do
                    local groups = country[kind] and country[kind].group
                    for _, g in pairs(groups or {}) do
                        for _, u in pairs(g.units or {}) do
                            if u.name == unit_name and u.callsign then
                                found = type(u.callsign) == 'table' and u.callsign.name or tostring(u.callsign)
                            end
                        end
                    end
                end
            end
        end
    end)
    return found
end

local function announce_callsign(write_fn)
    local cs, how
    pcall(function()
        local id = DCS.getPlayerUnit()
        if id then
            local name = DCS.getUnitProperty(id, DCS.UNIT_NAME)
            cs = name and mission_callsign(name)
            how = 'mission data, unit ' .. tostring(name)
        end
    end)
    cs = cs and tostring(cs) or ''
    if cs ~= '' then
        callsign_fails = 0
        if cs ~= last_callsign then
            last_callsign = cs
            write_fn('---- self callsign ---- ' .. cs .. ' (via ' .. how .. ')')
        end
    elseif not last_callsign then
        callsign_fails = callsign_fails + 1
        if callsign_fails == 10 then write_fn('---- self callsign ---- none found (no callsign in the mission data for the player unit)') end
    end
end

local function log(kind, dur, text)
    announce_callsign(write)
    write(string.format('t=%.1f kind=%s dur=%s self=%s decl=%s | %s', now(), kind, tostring(dur), self_snap(), decl(), esc(text)))
end

local cb = {}
function cb.onSimulationStart()
    last_callsign, callsign_fails = nil, 0
    local theatre = ''
    pcall(function() theatre = DCS.getCurrentMission().mission.theatre or '' end)
    write('---- simulation start ---- theatre=' .. tostring(theatre):gsub('%s', ''))
end
function cb.onTriggerMessage(message, duration, clearview) log('trigger', duration, message) end
function cb.onRadioMessage(message, duration) log('radio', duration, message) end
function cb.onShowMessage(message, duration) log('show', duration, message) end
DCS.setUserCallbacks(cb)
