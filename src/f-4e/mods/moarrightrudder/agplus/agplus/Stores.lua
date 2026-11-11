-- What is hung on the aircraft and which stations are armed.
--   * Armed stations come from the weapon station button lamps (lit = armed). Read straight from the cockpit.
--   * What is on each station comes from the payload feed file written by AGPlusFeed.lua (DCS Export side).
-- Both are read only. Without the feed file Stores.available is false and nothing is reported as armed.
local Config = require('agplus.Config')

local Stores = {}

local BUTTONS = '/Weapons/Weapons Control Panel Buttons/'

-- Button lamp name -> payload station number (outer 1/13, inner 3/11, center 7).
local STATIONS = {
    { lamp = 'Left Outer',  station = '1'  },
    { lamp = 'Left Inner',  station = '3'  },
    { lamp = 'Center',      station = '7'  },
    { lamp = 'Right Inner', station = '11' },
    { lamp = 'Right Outer', station = '13' },
}

Stores.available = false
Stores.feed = {}   -- [station string] = { count = n, l1 = , l2 = , l3 = , l4 = }

local function lamp_on(name)
    local v
    pcall(function() v = GetProperty(BUTTONS .. name .. ' Station Button Lamp/Lamp Top', 'Light Intensity').value end)
    -- The value is not always a plain Lua number (it prints as 0.900000), so go through its text.
    local n = tonumber(v) or tonumber(tostring(v))
    return n ~= nil and n >= 0.5
end

-- Re-read the feed file.
function Stores.ReadFeed()
    local text
    pcall(function()
        local fh = io.open(Config.PAYLOAD_FEED, 'r')
        if fh then text = fh:read('*a') fh:close() end
    end)
    local feed, n = {}, 0
    if text and text ~= '' then
        for st, count, l1, l2, l3, l4 in text:gmatch('S (%S+) clsid=%S+ count=(%S+) type=(%d+)/(%d+)/(%d+)/(%d+)') do
            feed[st] = { count = tonumber(count) or 0, l1 = tonumber(l1), l2 = tonumber(l2), l3 = tonumber(l3), l4 = tonumber(l4) }
            n = n + 1
        end
    end
    Stores.feed = feed
    Stores.available = n > 0
end

-- Whether a station's button lamp is lit (armed), by station number ('3', '11', ...).
function Stores.StationArmed(station)
    for _, s in ipairs(STATIONS) do
        if s.station == station then return lamp_on(s.lamp) end
    end
    return false
end

-- The armed stations that carry a bomb: a single bomb (wsType 4/5/36/n) or a multiple-ejector rack of them
-- (4/5/9/n, the F-4E MER; n is still the bomb's own number). Returns a list of { station, l4 }.
function Stores.ArmedBombs()
    local out = {}
    if not Stores.available then return out end
    for _, s in ipairs(STATIONS) do
        local f = Stores.feed[s.station]
        if f and f.count > 0 and f.l1 == 4 and f.l2 == 5 and (f.l3 == 36 or f.l3 == 9) and lamp_on(s.lamp) then
            out[#out + 1] = { station = s.station, l4 = f.l4 }
        end
    end
    return out
end

-- Weapons hanging on the aircraft: the total count over every station that carries a weapon (level 1 = 4: bombs, rockets, missiles), armed or
-- not. Fuel tanks and pods are not counted. Nil when the feed is not available. A drop in this number is a release.
function Stores.WeaponCount()
    if not Stores.available then return nil end
    local n = 0
    for _, f in pairs(Stores.feed) do
        if f.l1 == 4 then n = n + (f.count or 0) end
    end
    return n
end

return Stores
