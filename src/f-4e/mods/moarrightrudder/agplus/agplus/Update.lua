-- "Update INS": Jester corrects the INS from a TACAN station. One wheel item, nothing to set up.
--   1. Finds the nearest TACAN beacons from the map's beacon list and the INS position.
--   2. Takes TACAN command (NAV CMD), tunes his own head to the nearest one (T/R) and waits for the lock.
--   3. Turns the HSI bearing and range into a position and runs the stock nav fix: SET, latitude and
--      longitude, FIX, back to NORMAL. If there is no lock he tries the next beacon.
--   4. Puts his TACAN head back on the station it had (unless that is the station he fixed on) and gives
--      NAV CMD back to whoever had it.
-- Needs a station inside Config.INS_MAX_RANGE_NM and line of sight to it. Jester sets his own (rear seat) BDHI Mode switch
-- and reads the rear instrument, so the front seat's selectors do not matter.
local Class = require('base.Class')
local Behavior = require('base.Behavior')
local Task = require('base.Task')
local Interactions = require('base.Interactions')
local Config = require('agplus.Config')
local AGLog = require('agplus.Log')
local Util = require('agplus.Util')
local Ins = require('agplus.Ins')

local Update = {}

local PILOT_LAMP = '/Pilot Cockpit/Pilot Right Console/Comm Nav CMD Panel/NAV CMD Light/Lamp'
local WSO_LAMP = '/WSO Cockpit/WSO Left Console/Comm Nav CMD Panel/NAV CMD Light/Lamp'

local Menu = require('agplus.Menu')

-- True when the front seat's selector is on TACAN (or when we do not know which position that is: Config.FRONT_TACAN_POSITIONS
-- is a list of selector positions, empty or missing until it has been measured).
function Update.TacanSelected()
    local list = Config.FRONT_TACAN_POSITIONS
    if not list or #list == 0 then return true end
    local pos = Ins.FrontSelector()
    if pos == nil then return true end
    for _, p in ipairs(list) do if pos == p then return true end end
    return false
end

local INFO_OK = 'TACAN selected'
local INFO_UNABLE = 'Select TACAN on the front selector'

local shown_ok = nil

-- The INS Update menu: both fix methods, prefixed *UNABLE* while TACAN is not selected in front.
function Update.BuildItem()
    local ok = Update.TacanSelected()
    shown_ok = ok
    local prefix = ok and '' or '*UNABLE* '
    local items = {
        Wheel.Item:new({ name = prefix .. 'Overfly TACAN', action = 'agp_ins_update', reaction = Wheel.Reaction.CLOSE_REMEMBER }),
        Wheel.Item:new({ name = prefix .. 'Fix By Bearing', action = 'agp_ins_bearing', reaction = Wheel.Reaction.CLOSE_REMEMBER }),
    }
    return Wheel.Item:new({ name = 'INS Update', menu = Wheel.Menu:new({ name = 'INS Update', items = items }) })
end

local function number(v)
    return tonumber(v) or tonumber(tostring(v))
end

local function lamp(path)
    local v
    pcall(function() v = GetProperty(path, 'Light Intensity').value end)
    return number(v)
end

-- Which seat has NAV CMD: "pilot", "wso", or nil when the lamps cannot be read.
local function holder()
    local p, w = lamp(PILOT_LAMP), lamp(WSO_LAMP)
    local pl, wl = p and p > 0.05, w and w > 0.05
    if pl and not wl then return 'pilot' end
    if wl and not pl then return 'wso' end
    return nil
end

local function manip_state(name)
    local v
    pcall(function() v = GetJester():GetCockpit():GetManipulator(name):GetState() end)
    if v == nil then return nil end
    return tostring(v)
end

-- Jester's own TACAN head: channel from its roller gauges (tens/100 and ones/10), band and function from the switches.
local function head_state()
    local function roller(which)
        local v
        pcall(function() v = GetProperty('/TACAN Gauge WSO/TACAN Channel Rollers ' .. which, 'Indication (unified argument)').value end)
        return number(v)
    end
    local t, o = roller('Tens'), roller('Ones')
    local ch = (t and o) and (math.floor(t * 100 + 0.5) + math.floor(o * 10 + 0.5)) or nil
    local mt, mo = manip_state('TACAN Channel Tens'), manip_state('TACAN Channel Ones')
    if not ch and mt and mo then
        local tn, on = tonumber(mt:match('%d+')), tonumber(mo:match('%d+'))
        if tn and on then ch = tn * 10 + on end
    end
    AGLog.Info('ins update: head read: gauge tens=%s ones=%s | switch tens=%s ones=%s | ch=%s', tostring(t), tostring(o), tostring(mt), tostring(mo), tostring(ch))
    local band = manip_state('TACAN Band')
    if band then band = band:upper() if band ~= 'X' and band ~= 'Y' then band = nil end end
    local fn = manip_state('TACAN Function')
    local FUNCS = { OFF = true, REC = true, TR = true, AA_REC = true, AA_TR = true }
    if fn and not FUNCS[fn] then fn = nil end
    return { ch = ch, band = band, fn = fn }
end

local function set_channel(task, ch, band)
    local tens = string.format('%02d', math.floor(ch / 10))
    local ones = tostring(ch % 10)
    task:Click('TACAN Channel Tens', tens)
    task:Click('TACAN Channel Ones', ones)
    task:Click('TACAN Band', band or 'X')
end

-- Pushes a TACAN command button and holds it; UpdateBehavior:Tick lets go after a moment. A press and release in the same
-- frame is canceled by the cockpit, so ClickRawButton (which does both at once) did not take command.
local held = nil

local function press(command)
    local dev = Interactions.devices and Interactions.devices.TACAN_AN_ARN_118
    local cmd = Interactions.device_commands and Interactions.device_commands[command]
    if not dev or not cmd then
        AGLog.Info('ins update: cannot press %s (device %s, command %s)', command, tostring(dev), tostring(cmd))
        return false
    end
    if held then pcall(ClickRaw, held.dev, held.cmd, 0) end
    local ok, err = pcall(ClickRaw, dev, cmd, 1)
    held = { dev = dev, cmd = cmd, t0 = Util.Now() }
    AGLog.Info('ins update: pressed %s (device %s, command %s) %s', command, tostring(dev), tostring(cmd), ok and 'ok' or ('ERROR ' .. tostring(err)))
    return ok
end

local function release_held(force)
    if held and (force or Util.Now() - held.t0 >= 0.4) then
        pcall(ClickRaw, held.dev, held.cmd, 0)
        held = nil
    end
end

local UpdateBehavior = Class(Behavior)
Update.Behavior = UpdateBehavior

function UpdateBehavior:Constructor()
    Behavior.Constructor(self)
    self.state = 'idle'
    self.n = 0
end

local function same_station(a_ch, a_band, b)
    return a_ch ~= nil and a_ch == b.channel and (a_band == nil or a_band == (b.band or 'X'))
end

-- Starts an update. Clicks for the first tuning go on `task`. Returns true, or false and a reason.
function UpdateBehavior:Start(task, mode)
    mode = mode or 'bearing'
    if self.state == 'overfly' then
        self.cancel = true       -- picking the item again while waiting for the overfly cancels it
        return true
    end
    if self.state ~= 'idle' then return false, 'busy' end
    self.cancel = false
    local ilat, ilon = Ins.InsPosition()
    if not ilat then return false, 'no INS position' end
    local map = Ins.MapAt(ilat, ilon)
    local list = map and Ins.Beacons(map.folder)
    if not list then return false, 'no beacon list (check Config.DCS_INSTALL)' end
    -- A bearing is good to a degree or so, which is 0.3 NM at 20 NM and 1.7 NM at 100 NM, so the bearing fix only uses near
    -- stations; the overfly can use any (the range alone is accurate).
    local max = (mode == 'overfly') and (Config.INS_MAX_RANGE_NM or 120) or (Config.INS_BEARING_MAX_RANGE_NM or 20)
    local cands = {}
    for _, r in ipairs(Ins.Nearest(list, ilat, ilon, mode == 'overfly' and 1 or 3)) do
        if r.d <= max + 2 then cands[#cands + 1] = r.b end
    end
    if #cands == 0 then
        local n = Ins.Nearest(list, ilat, ilon, 1)[1]
        return false, n and string.format('no TACAN station within range; nearest is %s ch%d at %.1f NM, limit %d NM', n.b.name, n.b.channel, n.d, max) or 'no TACAN station within range'
    end

    local alt_ft
    pcall(function() alt_ft = GetJester().awareness:GetObservation('barometric_altitude'):ConvertTo(ft).value end)
    local dists = {}
    for _, c in ipairs(cands) do dists[#dists + 1] = string.format('%s %.0f NM', c.name, Ins.Distance(ilat, ilon, c.lat, c.lon)) end
    AGLog.Info('ins update: INS %.3f %.3f alt %s ft | %s', ilat, ilon, alt_ft and string.format('%.0f', alt_ft) or '?', table.concat(dists, ', '))
    local orig = head_state()
    orig.holder = holder()
    orig.bdhi = manip_state('BDHI Mode')
    if orig.bdhi ~= 'NAV_COMP' and orig.bdhi ~= 'VOR_TAC' and orig.bdhi ~= 'UHF_ADF_TACAN' then orig.bdhi = nil end
    self.job = { cands = cands, idx = 1, orig = orig, ok = false, mode = mode }
    AGLog.Info('ins update: start (%s). holder=%s head ch=%s band=%s fn=%s BDHI=%s | trying %s ch%d%s', mode, tostring(orig.holder),
        tostring(orig.ch), tostring(orig.band), tostring(orig.fn), tostring(orig.bdhi), cands[1].name, cands[1].channel, cands[1].band or 'X')
    if orig.holder ~= 'wso' then press('TACAN_RIO_COMMAND') end
    -- Jester's own BDHI switch to a TACAN position (the pointer 2 / distance feed).
    if orig.bdhi ~= 'VOR_TAC' then task:Click('BDHI Mode', 'VOR_TAC') end
    self:Tune(task)
    return true
end

function UpdateBehavior:Tune(task)
    local job = self.job
    local b = job.cands[job.idx]
    job.tuned = b
    self.prev, self.stable = nil, 0
    if job.orig.fn ~= 'TR' and job.orig.fn ~= 'AA_TR' then task:Click('TACAN Function', 'TR') end
    if not same_station(job.orig.ch, job.orig.band, b) or job.idx > 1 then set_channel(task, b.channel, b.band or 'X') end
    self.state = 'tuning'
    self.t0 = Util.Now()
end

-- Bearing mode: take the reading, then work it out for Config.INS_FIX_DELAY_S (10 s: a WSO plotting a bearing and range on a
-- chart is not instant). The position entered is where the aircraft will be at the end of that delay, keyed in over the last
-- 7 s, and FIX is flipped at the end, so the variable time Jester takes to key the numbers in does not matter.
function UpdateBehavior:TimedFix(m, vx, vy)
    local lead = math.max(Config.INS_FIX_DELAY_S or 10, 7)
    local click = Config.INS_FIX_CLICK_S or 0.3
    local pj = lead + (Config.INS_FIX_JUMP_S or 1.7)  -- the INS takes the position a moment after the flip
    local lat = m.lat + (vx * pj / 1852) / 60
    local lon = m.lon + (vy * pj / 1852) / (60 * math.cos(m.lat * math.pi / 180))
    AGLog.Info('ins update: %s', Ins.Diag(m.b))
    self.job.key_at = Util.Now() + lead - 7
    self.job.key_lat, self.job.key_lon = lat, lon
    self.job.flip_at = Util.Now() + lead - click
    self.job.target = { lat = lat, lon = lon }
    self.job.ok = true
    self.state = 'timedfix'
    AGLog.Info('ins update: %s ch%d (%s) brg %.1f rng %.1f -> %.5f %.5f at +%.1fs | INS moved %.2f NM', m.b.name, m.b.channel, tostring(m.src),
        m.brg, m.rng, lat, lon, lead, m.shift)
end

function UpdateBehavior:Fix(m)
    if m.src ~= 'overfly' then
        local vx, vy = Ins.GroundVelocity()
        if vx and (vx * vx + vy * vy) > 2500 then return self:TimedFix(m, vx, vy) end
    end
    -- The nav fix takes a moment to key in, and the aircraft keeps moving (350 kt is 0.1 NM per second), so enter
    -- the position where the aircraft will be when the FIX switch goes over.
    local lead = Config.INS_FIX_LEAD_S or 1.5
    local vx, vy, vkey = Ins.GroundVelocity()
    if vx and lead > 0 then
        m.lat = m.lat + (vx * lead / 1852) / 60
        m.lon = m.lon + (vy * lead / 1852) / (60 * math.cos(m.lat * math.pi / 180))
        AGLog.Info('ins update: projected %.1fs ahead at %.0f kt (%s)', lead, math.sqrt(vx * vx + vy * vy) * 1.94384, tostring(vkey))
    elseif lead > 0 then
        AGLog.Info('ins update: ground velocity unavailable, no projection')
    end
    AGLog.Info('ins update: %s', Ins.Diag(m.b))
    local Nav = require('tasks.navigation.NavInteractions')
    local t = Task:new()
    Nav.PrepareNavFix(t, string.format('%.5f', m.lat), string.format('%.5f', m.lon))
    Nav.ReleaseNavFix(t)
    GetJester():AddTask(t)
    local tlat, tlon = Ins.TruePosition()
    AGLog.Info('ins update: %s ch%d (%s) brg %.1f rng %.1f -> %.5f %.5f | INS moved %.2f NM | estimate vs true %s NM | INS vs true %s NM',
        m.b.name, m.b.channel, tostring(m.src), m.brg, m.rng, m.lat, m.lon, m.shift,
        tlat and string.format('%.2f', Ins.Distance(tlat, tlon, m.lat, m.lon)) or '?',
        tlat and string.format('%.2f', Ins.Distance(tlat, tlon, m.ins_lat, m.ins_lon)) or '?')
    self.job.ok = true
    self.job.est_err = tlat and Ins.Distance(tlat, tlon, m.lat, m.lon) or nil
    self.state = 'fixing'
    self.t0 = Util.Now()
end

-- Puts the head back and says how it went. NAV CMD is handed back once the head has been retuned.
function UpdateBehavior:Restore()
    local job = self.job
    local t = Task:new()
    local o, b = job.orig, job.tuned
    if job.prep and not job.ok then require('tasks.navigation.NavInteractions').SetPositionUpdateSwitch(t, 'normal') end
    if b and o.ch and not same_station(o.ch, o.band, b) then set_channel(t, o.ch, o.band or 'X') end
    if o.fn and o.fn ~= 'TR' and o.fn ~= 'AA_TR' then t:Click('TACAN Function', o.fn) end
    if o.bdhi and o.bdhi ~= 'VOR_TAC' then t:Click('BDHI Mode', o.bdhi) end
    if not job.silent then t:Say(job.ok and 'misc/fixsuccess' or 'misc/fixnosuccess') end
    GetJester():AddTask(t)
    self.state = 'restoring'
    self.t0 = Util.Now()
end

-- Waiting for the overfly. The station position is known exactly, so the slow part of the nav fix is done early:
--   * about 30 s before the station Jester puts the nav panel on SET and keys in the station's latitude and longitude;
--   * he then flips FIX a moment before the aircraft crosses the station (the lead is the time the click takes), timed from
--     the slant range (x = sqrt(slant^2 - height^2) to go) and the ground speed.
-- If the overfly is started too close to the station, or the crossing is missed, the position is worked out from the range
-- after the station instead (station plus x along the ground track) and the whole nav fix is keyed in.
function UpdateBehavior:Overfly()
    local job, now = self.job, Util.Now()
    local timeout = Config.INS_OVERFLY_TIMEOUT_S or 600
    if self.cancel or now - job.t_arm > timeout then
        AGLog.Info('ins update: overfly %s', self.cancel and 'canceled' or 'timed out')
        job.silent = self.cancel
        self:Restore()
        return
    end
    local r, rsrc = Ins.RearRange()
    local b = job.tuned
    local alt_m
    pcall(function() alt_m = GetJester().awareness:GetObservation('barometric_altitude'):ConvertTo(m).value end)
    local h = math.max(0, ((alt_m or 0) - (b.alt or 0)) / 1852)
    local vx, vy = Ins.GroundVelocity()
    local sp = vx and math.sqrt(vx * vx + vy * vy) or 0
    local x, xg, approaching, dead
    if r then
        if not job.min or r < job.min then job.min = r end
        xg = math.sqrt(math.max(0, r * r - h * h))
        approaching = r <= job.min + 0.03
        -- The slant range is flat close to the station (r barely changes inside about 0.5 NM), so the last stretch is timed
        -- from the ground speed instead of the range.
        if approaching and (xg >= 0.5 or not job.x_est or sp < 50) then
            job.x_est = xg
        else
            job.x_est = job.x_est - sp * (now - job.t_est) / 1852
        end
        job.t_est = now
        x = approaching and math.max(0, job.x_est) or xg
    elseif job.prep and job.x_est and sp >= 50 then
        -- With the nav panel on SET the range readouts can drop to zero (seen with the front seat on a steering waypoint), so
        -- carry on from the last range, taking off the distance flown at the measured ground speed.
        job.x_est = job.x_est - sp * (now - job.t_est) / 1852
        job.t_est = now
        x, approaching, dead = math.max(0, job.x_est), true, true
    else
        if now - (job.last_log or 0) >= 1 then
            job.last_log = now
            local rr = Ins.RangeReadings()
            AGLog.Info('ins update: overfly: no usable TACAN range (mode switch %s, front panel %s, rear gauge %s, other instrument %s)',
                tostring(rr['mode switch']), tostring(rr['front panel']), tostring(rr['rear gauge']), tostring(Ins.OtherRange()))
        end
        return
    end
    local ttg = (sp >= 50) and (x * 1852 / sp) or nil
    if now - (job.last_log or 0) >= 1 then
        job.last_log = now
        local rr = Ins.RangeReadings()
        local ilat, ilon = Ins.InsPosition()
        local tlat, tlon = Ins.TruePosition()
        local trng = tlat and math.sqrt(Ins.Distance(tlat, tlon, b.lat, b.lon) ^ 2 + h * h)
        AGLog.Info('ins update: overfly watching %s: %s %.2f NM [rear gauge %s | other instrument %s] true slant %s height %.2f NM x %.2f NM ground %.0f kt to go %s s%s',
            b.name, dead and 'dead-reckoned' or ('range from ' .. tostring(rsrc)), r or x, tostring(rr['rear gauge']), tostring(Ins.OtherRange()),
            trng and string.format('%.2f', trng) or '?', h, x, sp * 1.94384, ttg and string.format('%.1f', ttg) or '?', job.prep and ' (keyed in)' or '')
    end
    local Nav = require('tasks.navigation.NavInteractions')

    -- Key in the station position ahead of time.
    if approaching and ttg and not job.prep and ttg <= (Config.INS_PREP_S or 14) and ttg >= 10 then
        local t = Task:new()
        Nav.SetPositionUpdateSwitch(t, 'set')
        t:Wait(s(0.2), { hands = true })
        Nav.SetPositionCoords(t, string.format('%.5f', b.lat), string.format('%.5f', b.lon))
        t:Wait(s(0.2), { hands = true })
        GetJester():AddTask(t)
        job.prep = now
        AGLog.Info('ins update: overfly: station position keyed in with %.1f s to go', ttg)
    end

    -- Flip FIX just before the crossing.
    if approaching and job.prep and not job.flipped and now - job.prep >= 7 and ttg and ttg <= (Config.INS_FIX_CLICK_S or 0.3) then
        local t = Task:new()
        Nav.SetPositionUpdateSwitch(t, 'fix')
        Nav.ReleaseNavFix(t)
        GetJester():AddTask(t)
        job.flipped, job.ok = now, true
        local ilat, ilon = Ins.InsPosition()
        local tlat, tlon = Ins.TruePosition()
        AGLog.Info('ins update: overfly: FIX flipped with %.2f s to go (x %.2f NM, %.0f kt) | INS vs true %s NM', ttg, x, sp * 1.94384,
            tlat and ilat and string.format('%.2f', Ins.Distance(tlat, tlon, ilat, ilon)) or '?')
        self.last_ins = nil
        self.state = 'fixing'
        self.t0 = now
        return
    end

    -- Passed the station without the early fix: work the position out from the range after the station.
    if not r then return end
    if job.min < 4 and r > job.min + 0.05 and xg >= 0.4 then
        job.rise = (job.rise or 0) + 1
    else
        job.rise = 0
    end
    if job.rise < 2 then return end
    local dmin = math.sqrt(math.max(0, job.min * job.min - h * h))
    AGLog.Info('ins update: overfly passed %s: min slant %.2f NM height %.2f NM => passed %.2f NM to the side | slant now %.2f => %.2f NM past', b.name, job.min, h, dmin, r, xg)
    if job.min > h * 1.25 + 0.3 then
        AGLog.Info('ins update: overfly missed (passed too far to the side)')
        self:Restore()
        return
    end
    if sp < 50 then
        AGLog.Info('ins update: overfly: no usable ground track')
        self:Restore()
        return
    end
    local ilat, ilon = Ins.InsPosition()
    local lat = b.lat + (xg * vx / sp) / 60
    local lon = b.lon + (xg * vy / sp) / (60 * math.cos(b.lat * math.pi / 180))
    AGLog.Info('ins update: overfly: station was not keyed in %s, using the range after the station', job.prep and 'in time' or 'early')
    self:Fix({ b = b, lat = lat, lon = lon, brg = 0, rng = r, src = 'overfly', shift = Ins.Distance(ilat, ilon, lat, lon), ins_lat = ilat, ins_lon = ilon })
end

-- Twice a second: watch the front selector. When TACAN gets selected or deselected, rebuild the menu so the *UNABLE* prefix
-- follows; the center text is re-sent whenever it changed. The raw selector value is logged on every change (to learn which
-- position is TACAN).
function UpdateBehavior:PollSelector()
    local pos, mode = Ins.FrontSelector()
    if pos ~= self.last_pos or mode ~= self.last_mode then
        AGLog.Info('ins update: front selector position %s, mode selected %s (TACAN positions configured: %s)', tostring(pos), tostring(mode),
            Config.FRONT_TACAN_POSITIONS and table.concat(Config.FRONT_TACAN_POSITIONS, ',') or 'none')
        self.last_pos, self.last_mode = pos, mode
    end
    local ok = Update.TacanSelected()
    if shown_ok ~= nil and ok ~= shown_ok then Menu.Rebuild() end
    Menu.SetInfoFor('INS Update', ok and INFO_OK or INFO_UNABLE)
end

function UpdateBehavior:Tick()
    release_held()
    if self.state == 'overfly' and Util.Cockpit() then self:Overfly() return end
    if self.state == 'timedfix' and Util.Cockpit() then
        local now = Util.Now()
        if not self.job.prep and now >= self.job.key_at then
            local Nav = require('tasks.navigation.NavInteractions')
            local t = Task:new()
            Nav.SetPositionUpdateSwitch(t, 'set')
            t:Wait(s(0.2), { hands = true })
            Nav.SetPositionCoords(t, string.format('%.5f', self.job.key_lat), string.format('%.5f', self.job.key_lon))
            t:Wait(s(0.2), { hands = true })
            GetJester():AddTask(t)
            self.job.prep = now
        end
        if not self.job.prep then return end
        if now >= self.job.flip_at then
            local Nav = require('tasks.navigation.NavInteractions')
            local t = Task:new()
            Nav.SetPositionUpdateSwitch(t, 'fix')
            Nav.ReleaseNavFix(t)
            GetJester():AddTask(t)
            local ilat, ilon = Ins.InsPosition()
            local tlat, tlon = Ins.TruePosition()
            AGLog.Info('ins update: FIX flipped | entered position vs true now %s NM | INS vs true %s NM',
                tlat and string.format('%.2f', Ins.Distance(tlat, tlon, self.job.target.lat, self.job.target.lon)) or '?',
                tlat and ilat and string.format('%.2f', Ins.Distance(tlat, tlon, ilat, ilon)) or '?')
            self.job.flipped = now
            self.last_ins = nil
            self.state = 'fixing'
            self.t0 = now
        end
        return
    end
    if self.state == 'fixing' and self.job.flipped then
        local ilat, ilon = Ins.InsPosition()
        if ilat and self.last_ins and not self.job.jump and Ins.Distance(ilat, ilon, self.last_ins[1], self.last_ins[2]) > 0.1 then
            self.job.jump = true
            AGLog.Info('ins update: INS jumped %.2f s after the FIX flip', Util.Now() - self.job.flipped)
        end
        if ilat then self.last_ins = { ilat, ilon } end
    end
    self.n = self.n + 1
    if self.n < 5 then return end              -- about twice a second
    self.n = 0
    if Util.Cockpit() then self:PollSelector() end
    if self.state == 'idle' or not Util.Cockpit() then return end
    local now, job = Util.Now(), self.job
    if self.state == 'tuning' and job.mode == 'overfly' then
        if now - self.t0 < 3 then return end
        local b = job.cands[1]
        local r = Ins.RearRange()
        local ilat, ilon = Ins.InsPosition()
        local d = ilat and Ins.Distance(ilat, ilon, b.lat, b.lon)
        -- The range should roughly match the distance to the station (the INS is off by about a mile).
        if r and r > 0.3 and d and math.abs(r - d) < 6 then
            self.stable = self.stable + 1
        else
            self.stable = 0
        end
        if self.stable >= 3 then
            AGLog.Info('ins update: locked %s ch%d at %.1f NM; waiting for the overfly', b.name, b.channel, r)
            job.t_arm, job.min, job.rise = now, nil, 0
            self.state = 'overfly'
            return
        end
        if now - (self.last_log or 0) >= 2 then
            self.last_log = now
            AGLog.Info('ins update: waiting on %s: range %s, INS distance %s', b.name, tostring(r), tostring(d))
        end
        if now - self.t0 > (Config.INS_LOCK_TIMEOUT_S or 12) then
            AGLog.Info('ins update: no lock on %s', b.name)
            self:Restore()
        end
        return
    end
    if self.state == 'tuning' then
        if now - self.t0 < 3 then return end
        local m, why = Ins.Measure(job.cands[job.idx])
        if m then
            -- The pointer and range indicators slew to a new station, so a first reading is mid-swing (a 15 degree
            -- error at 9.5 NM on the first live test). Wait until several readings in a row agree.
            local p = self.prev
            -- The range changes while closing on the station, so only the bearing has to hold still.
            -- Steady means the pointer is no longer slewing: successive position estimates move by what the aircraft flew
            -- (ground velocity x time). A fixed bearing test fails when the bearing sweeps (flying around the station).
            m.t = now
            local steady
            if p and p.src == m.src and p.t then
                local vx, vy = Ins.GroundVelocity()
                if vx then
                    local dt = now - p.t
                    local dn = (m.lat - p.lat) * 60 - vx * dt / 1852
                    local de = (m.lon - p.lon) * 60 * math.cos(m.lat * math.pi / 180) - vy * dt / 1852
                    steady = math.sqrt(dn * dn + de * de) < 0.15
                else
                    steady = math.abs(((m.brg - p.brg + 180) % 360) - 180) < 0.4
                end
            end
            self.stable = steady and (self.stable + 1) or 0
            self.prev = m
            if self.stable >= 4 then self:Fix(m) return end
            why = string.format('settling: %s brg %.1f rng %.2f (%d steady)', m.src, m.brg, m.rng, self.stable)
        else
            self.prev, self.stable = nil, 0
        end
        if now - (self.last_log or 0) >= 2 then
            self.last_log = now
            local h = head_state()
            AGLog.Info('ins update: waiting on %s: command=%s head ch=%s band=%s fn=%s | %s', job.cands[job.idx].name,
                tostring(holder()), tostring(h.ch), tostring(h.band), tostring(h.fn), tostring(why))
            AGLog.Info('ins update: %s', Ins.Diag(job.cands[job.idx]))
        end
        if now - self.t0 > (Config.INS_LOCK_TIMEOUT_S or 12) then
            AGLog.Info('ins update: no lock on %s', job.cands[job.idx].name)
            job.idx = job.idx + 1
            if job.idx > #job.cands then self:Restore() return end
            local t = Task:new()
            self:Tune(t)
            GetJester():AddTask(t)
        end
    elseif self.state == 'fixing' then
        local ilat, ilon = Ins.InsPosition()
        local tlat, tlon = Ins.TruePosition()
        if ilat and tlat then
            AGLog.Info('ins update: %.1fs after the fix command the INS is %.2f NM from the true position (estimate was %.2f NM)',
                now - self.t0, Ins.Distance(tlat, tlon, ilat, ilon), job.est_err or -1)
        end
        if now - self.t0 >= 6 then self:Restore() end
    elseif self.state == 'restoring' then
        if now - self.t0 >= 3.5 then
            if job.orig.holder == 'pilot' then press('TACAN_PILOT_COMMAND') end
            self.state = 'returned'
            self.t0 = now
        end
    elseif self.state == 'returned' then
        if now - self.t0 >= 1 then
            AGLog.Info('ins update: done (%s), command now %s, was %s', job.ok and 'fixed' or 'no fix', tostring(holder()), tostring(job.orig.holder))
            self.state = 'idle'
        end
    end
end

local function start_update(task, mode)
    local b = GetJester().behaviors[UpdateBehavior]
    if not b then task:CantDo() return end
    if not Update.TacanSelected() then
        AGLog.Info('ins update: not started (TACAN is not selected on the front selector)')
        task:CantDo()
        return
    end
    local ok, started, why = pcall(b.Start, b, task, mode)
    if not ok then AGLog.Info('ins update: error %s', tostring(started)) task:CantDo() return end
    if not started then AGLog.Info('ins update: not started (%s)', tostring(why)) task:CantDo() return end
    task:Roger()
end

ListenTo('agp_ins_update', 'AGPlus_InsUpdate', function(task) start_update(task, 'overfly') end)
ListenTo('agp_ins_bearing', 'AGPlus_InsBearing', function(task) start_update(task, 'bearing') end)

return Update
