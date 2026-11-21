-- Laser Code menu inside the root wheel's Pave Spike menu (RootMenu.lua). The player picks the digits on the wheel, one pie slice
-- per digit, and the center text shows the new code; "Enter Laser Code" then sends it. The code goes to Heatblur's
-- PROXY_SET_LASER_CODE command (device JESTER) as a plain number, which Jester enters in the coder himself (tested Nov 20 2026).
-- The "Format Test" menu (Config.LASER_FORMAT_TEST = true) sends 1689 in three value formats; it is off by default.
local Interactions = require('base.Interactions')
local Config = require('agplus.Config')
local AGLog = require('agplus.Log')

local LaserCode = {}

local TOP = 'Laser Code'
local POS_NAMES = { 'Thousands', 'Hundreds', 'Tens', 'Ones' }

-- Jester only accepts the standard DCS laser codes (1111 to 1788): first digit 1, second 1 to 7, third and fourth 1 to 8
-- (1687 was accepted and 1689 refused in testing). The wheel offers only those digits. Config.LASER_ANY_DIGITS = true offers 0 to 9 everywhere.
local ANY = (Config.LASER_ANY_DIGITS == true)
local RANGE = ANY and { {0, 9}, {0, 9}, {0, 9}, {0, 9} } or { {1, 1}, {1, 7}, {1, 8}, {1, 8} }
local function in_range(pos, n) return n >= RANGE[pos][1] and n <= RANGE[pos][2] end

local function default_code()
    local c = tonumber(Config.LASER_DEFAULT_CODE) or 1688       -- the rear seat starts at 1688
    return math.max(0, math.min(9999, math.floor(c)))
end

local function split(code)
    return { math.floor(code / 1000) % 10, math.floor(code / 100) % 10, math.floor(code / 10) % 10, code % 10 }
end

local d = split(default_code())     -- the code being built
local last_sent = nil               -- the last code sent from this menu (nil = none yet, the rear seat still has its default)

local function code_number() return d[1] * 1000 + d[2] * 100 + d[3] * 10 + d[4] end
local function code_text(n) return string.format('%04d', n) end

local function loaded(name) return package.loaded[name] end

local function item(name, action, value)
    return Wheel.Item:new({ name = name, action = action, action_value = value, reaction = Wheel.Reaction.NOTHING })
end

local function ring(pos)
    local name = POS_NAMES[pos]
    local items = {}
    for n = RANGE[pos][1], RANGE[pos][2] do items[#items + 1] = item(tostring(n), 'agp_lc_digit', pos .. ':' .. n) end
    return Wheel.Item:new({ name = name, outer_menu = Wheel.Menu:new({ name = name, items = items }) })
end

function LaserCode.BuildItem()
    local items = { item('Enter Laser Code', 'agp_lc_send', 'raw') }
    for pos = 1, 4 do
        if RANGE[pos][1] ~= RANGE[pos][2] then items[#items + 1] = ring(pos) end    -- a digit with one choice has no ring
    end
    if Config.LASER_FORMAT_TEST == true then
        items[#items + 1] = Wheel.Item:new({ name = 'Format Test', menu = Wheel.Menu:new({ name = 'Format Test', items = {
            item('Send 1689', 'agp_lc_send', 'test_raw'),
            item('Send 0.1689', 'agp_lc_send', 'test_div10000'),
            item('Send 1.689', 'agp_lc_send', 'test_div1000'),
        } }) })
    end
    return Wheel.Item:new({ name = TOP, menu = Wheel.Menu:new({ name = TOP, items = items }) })
end

-- Center text of the Laser Code menu and its digit rings, wherever the root item currently is on the wheel.
function LaserCode.SendInfo()
    local R = loaded('agplus.RootMenu')
    local base = R and R.ShownName and R.ShownName()
    if not base then return end
    local text = string.format('Laser Code\nNew: %s\nLast Sent: %s', code_text(code_number()),
        last_sent and code_text(last_sent) or (code_text(default_code()) .. ' (default)'))
    pcall(function() Wheel.SetMenuInfo(text, { base, 'Pave Spike', TOP }) end)
    for pos, nm in ipairs(POS_NAMES) do
        if RANGE[pos][1] ~= RANGE[pos][2] then
            pcall(function() Wheel.SetMenuInfo(text, { base, 'Pave Spike', TOP, nm }) end)
        end
    end
end

ListenTo('agp_lc_digit', 'AGPlus_LaserDigit', function(task, value)
    local pos, n = tostring(value):match('^(%d):(%d)$')
    pos, n = tonumber(pos), tonumber(n)
    if not (pos and n and d[pos] and in_range(pos, n)) then return end
    d[pos] = n
    LaserCode.SendInfo()
    AGLog.Info('laser code menu: new code %s', code_text(code_number()))
end)

ListenTo('agp_lc_send', 'AGPlus_LaserSend', function(task, value)
    local fmt = tostring(value)
    -- The Format Test items always send 1689, so the test does not depend on the digits picked.
    local code = code_number()
    if fmt:sub(1, 5) == 'test_' then code = 1689 fmt = fmt:sub(6) end
    for pos = 1, 4 do
        if not in_range(pos, split(code)[pos]) then
            AGLog.Info('laser code menu: %s is not a code Jester accepts, not sent', code_text(code))
            pcall(function() task:CantDo() end)
            return
        end
    end
    local v = code
    if fmt == 'div10000' then v = code / 10000 elseif fmt == 'div1000' then v = code / 1000 end
    local ok, err = pcall(function()
        local dev = Interactions.devices.JESTER
        local cmd = Interactions.device_commands.PROXY_SET_LASER_CODE
        assert(dev and cmd, 'device or command id missing')
        ClickRaw(dev, cmd, v)
    end)
    if ok then
        last_sent = code
        AGLog.Info('laser code menu: sent %s as %s (value %s)', code_text(code), fmt, tostring(v))
        pcall(function() task:Roger() end)
    else
        AGLog.Info('laser code menu: send failed: %s', tostring(err))
        pcall(function() task:CantDo() end)
    end
    LaserCode.SendInfo()
end)

return LaserCode
