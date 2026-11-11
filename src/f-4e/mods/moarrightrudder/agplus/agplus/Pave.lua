-- Pave Spike "look there" (TODO item 4, Phase 1).
-- In TGT FIND, a LONG context press points the pod at the ground spot the pilot is looking at, and a DOUBLE press resets the
-- pod (back out of track). A short press stays stock (lock / unlock what is ahead). Both of the new actions take over the
-- stock context handler only while the Pave Spike is the active DSCG system; in every other mode they hand the press straight
-- back to stock, so the radar context actions are unchanged.
--
-- Where the pilot is looking comes from the optional Export + hook pair (PaveProbeFeed.lua, PaveProbeHook.lua), which write
-- Logs\pavespike_look.txt about ten times a second: the aircraft position and attitude and the point where the view line
-- meets the terrain. Without that file a long press is answered with "can't do".
--
-- The pod only slews in TRACK, so a look-there first enters TRACK (the same trigger half action stock uses), then steers the
-- antenna hand control until the pod direction matches the direction to the spot, then lets go of the stick.
local Interactions = require('base.Interactions')
local Behavior = require('base.Behavior')
local Class = require('base.Class')
local Task = require('base.Task')
local Config = require('agplus.Config')
local AGLog = require('agplus.Log')
local Util = require('agplus.Util')
local Dbg = require('agplus.PaveDebug')
local PaveSpike = require('other.PaveSpike')
local PrepareDscg = require('behaviors.PrepareDscg')
local PickMenu = require('agplus.PickMenu')

local Pave = {}

local PS = '/EO TGT Designator System/Pave Spike'
local LOOK_FILE = (Config.PAYLOAD_FEED or ''):gsub('agplus_payload%.txt$', 'pavespike_look.txt')

local MAX_AGE = Config.PAVE_LOOK_MAX_AGE_S or 1.5
local GAIN = Config.PAVE_SLEW_GAIN_DEG or 5.0
local LEAD = Config.PAVE_SLEW_LEAD_S or 0.6
local TOL = Config.PAVE_SLEW_TOL_DEG or 0.4
local GROUND_TOL = Config.PAVE_SLEW_GROUND_TOL_M or 150   -- how far from the target, on the ground, counts as on it
local FEED = GAIN / (Config.PAVE_SLEW_RATE_DEG or 6.5)   -- stick needed per deg/s of target motion
local SLEW_TIMEOUT = Config.PAVE_SLEW_TIMEOUT_S or 20
local ENGAGE_TIMEOUT = Config.PAVE_ENGAGE_TIMEOUT_S or 3
local ENGAGE_FIRST = Config.PAVE_ENGAGE_FIRST_S or 8   -- the first wait for track after the trigger sequence (Jester's task queue may be busy)
local RECOVER_TRIES = Config.PAVE_RECOVER_TRIES or 4   -- re-entries of track after the pod loses a held target
local DATUM_LIMIT = Config.PAVE_DATUM_LIMIT_DEG or 2

local RAD = math.pi / 180

--------------------------------------------------------------------------------
-- Pure helpers (also exercised by the offline test)
--------------------------------------------------------------------------------

local function wrap180(a) return ((a + 180) % 360) - 180 end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

-- How far the pod is outside the nose-line trouble zone: 0 inside, 1 clear of it. Clear by azimuth (more than PAVE_ZONE_NOSE_DEG plus the
-- taper off the nose), or by elevation: the zone has a lower edge. A hand slew at -17 to -22 deg elevation with full stick across the
-- nose line (Oct 20 2026) showed no uncommanded elevation motion, and the stored slews show the coupling falling away below about -10 deg
-- (strong at -10 to -8, none below -25). Free from Config.PAVE_ZONE_LOW_EL (-12) over PAVE_ZONE_LOW_TAPER_DEG (4) below it.
local function nose_free(az, el)
    local fa = clamp((math.abs(az) - (Config.PAVE_ZONE_NOSE_DEG or 6)) / (Config.PAVE_ZONE_TAPER_DEG or 8), 0, 1)
    local fl = clamp(((Config.PAVE_ZONE_LOW_EL or -12) - el) / (Config.PAVE_ZONE_LOW_TAPER_DEG or 4), 0, 1)
    return math.max(fa, fl)
end

-- Azimuth (deg, true, clockwise) and elevation (deg, up positive) of the line from a to b. Positions are DCS world
-- coordinates: x north, y up, z east.
function Pave.Direction(a, b)
    local n, u, e = b.x - a.x, b.y - a.y, b.z - a.z
    local horiz = math.sqrt(n * n + e * e)
    return (math.deg(math.atan2(e, n))) % 360, math.deg(math.atan2(u, horiz))
end

-- A world direction (azimuth / elevation, deg) as azimuth / elevation in the aircraft frame: azimuth right of the nose,
-- elevation above the datum (nose) line. heading, pitch, bank in degrees (nose up and right wing down positive).
-- The pod is gimballed to the airframe, so a roll or pitch change by the pilot moves the pod's world direction; steering
-- in the aircraft frame keeps the loop from chasing the pilot's own maneuvers.
function Pave.ToBody(az, el, heading, pitch, bank)
    local a, e = az * RAD, el * RAD
    local n, east, d = math.cos(e) * math.cos(a), math.cos(e) * math.sin(a), -math.sin(e)
    local psi, th, ph = heading * RAD, pitch * RAD, bank * RAD
    local x1 = math.cos(psi) * n + math.sin(psi) * east
    local y1 = -math.sin(psi) * n + math.cos(psi) * east
    local x2 = math.cos(th) * x1 - math.sin(th) * d
    local z2 = math.sin(th) * x1 + math.cos(th) * d
    local y3 = math.cos(ph) * y1 + math.sin(ph) * z2
    local z3 = -math.sin(ph) * y1 + math.cos(ph) * z2
    return math.deg(math.atan2(y3, x2)), math.deg(math.asin(clamp(-z3, -1, 1)))
end

-- Elevation above the aircraft datum line. Looking above it inverts the hand control (HB manual), so look-there refuses those.
function Pave.BodyElevation(az, el, heading, pitch, bank)
    local _, be = Pave.ToBody(az, el, heading, pitch, bank)
    return be
end

-- Hand control deflection that closes an azimuth / elevation error. Measured: X +1 turns the pod view right, Y +1 turns it
-- down; full deflection is about 6.5 deg/s.
function Pave.Stick(az_err, el_err)
    return clamp(az_err / GAIN, -1, 1), -clamp(el_err / GAIN, -1, 1)
end

local function num(v)
    if type(v) == 'number' then return v end
    local ok, s = pcall(tostring, v)
    if not ok then return nil end
    return tonumber(s:match('[%-%d%.eE%+]+'))
end

--------------------------------------------------------------------------------
-- Reading the sim
--------------------------------------------------------------------------------

-- Pod camera direction (unit vector, NED world frame) as azimuth / elevation in degrees.
local function pod_angles()
    local ok, x, y, z = pcall(function()
        local p = GetProperty(PS, 'Pod Camera Direction')
        return num(p.x), num(p.y), num(p.z)
    end)
    if not ok or not x or not y or not z then return nil end
    return math.deg(math.atan2(y, x)) % 360, math.deg(math.asin(clamp(-z, -1, 1)))
end

local function dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function op_mode()
    local ok, v = pcall(function() return GetProperty(PS, 'Operation Mode').value end)
    if not ok then return nil end
    return num(v)
end

-- The regular Pave Spike is the one without the Smart-Track or Fast-Track upgrade (read from the pod, cached for a second). The tail blind zone, the trouble-zone
-- stick caps, the rear zone, the rotation curve and the shallow-angle gain were measured on the regular pod only and apply to it only (Oct 20 2026, user's
-- decision); the Fast/Smart-Track pod keeps the plain loop. Config.PAVE_POD_RULES_ALL = true applies them to every pod.
local pod_cache = { t = -10, v = true }
local function regular_pod()
    if Config.PAVE_POD_RULES_ALL then return true end
    local t = Util.Now()
    if t - pod_cache.t > 1 then
        local function flag(name)
            local v
            pcall(function() v = GetProperty(PS, name).value end)
            return v == true or tostring(v) == 'true' or num(v) == 1
        end
        pod_cache.t = t
        pod_cache.v = not (flag('Upgrade Smart-Track') or flag('Upgrade Fast-Track'))
    end
    return pod_cache.v
end

-- The pod's tail blind zone in the aircraft frame: the pod drops to acquisition or memory mode when it looks nearly straight aft and not far enough below the
-- datum line. Returns the azimuth limit (|az| above it is inside) and the elevation limit (above it is inside), both with a margin for the chase. Hand sweeps, Oct 20 2026:
--   regular pod: |az| >= 176 and el up to about -5.2 (apex at az 180);
--   Fast/Smart-Track pod: apex at az 180, el -4.0 to -4.3; the zone widens upward, edge at |az| 176.3 at -1.7, 176.0 at -0.9, 175.8 at +1.0, 176.8 at -2.4.
local function tail_zone()
    if regular_pod() then
        return Config.PAVE_TAIL_AZ_DEG or 175, Config.PAVE_TAIL_EL_DEG or -9
    end
    return Config.PAVE_TAIL_AZ_FST_DEG or 175, Config.PAVE_TAIL_EL_FST_DEG or -7.5
end

-- The look file, or nil when it is missing, half written or older than MAX_AGE.
function Pave.ReadLook()
    local f = io.open(LOOK_FILE, 'r')
    if not f then return nil, 'no look file' end
    local text = f:read('*a')
    f:close()
    if not text or not text:find('\nEND') then return nil, 'look file incomplete' end
    local view_t = tonumber(text:match('view_t=([%d%.]+)'))
    local s = { text:match('\nSELF ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)') }
    if not view_t or #s < 6 then return nil, 'look file unreadable' end
    local L = { view_t = view_t, age = Util.Now() - view_t,
        self = { x = tonumber(s[1]), y = tonumber(s[2]), z = tonumber(s[3]), heading = tonumber(s[4]), pitch = tonumber(s[5]), bank = tonumber(s[6]) } }
    -- The head camera (written by PaveProbeHook.lua since Oct 19 2026): where the player is looking relative to the aircraft.
    local c = { text:match('\nCAM ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)') }
    if #c == 6 then
        local px, py, pz, fx, fy, fz = tonumber(c[1]), tonumber(c[2]), tonumber(c[3]), tonumber(c[4]), tonumber(c[5]), tonumber(c[6])
        local waz = math.deg(math.atan2(fz, fx)) % 360
        local wel = math.deg(math.asin(math.max(-1, math.min(1, fy))))
        local baz, bel = Pave.ToBody(waz, wel, L.self.heading, L.self.pitch, L.self.bank)
        local dx, dy, dz = px - L.self.x, py - L.self.y, pz - L.self.z
        L.cam = { body_az = baz, body_el = bel, off_m = math.sqrt(dx * dx + dy * dy + dz * dz) }
    end
    local h = { text:match('\nHIT ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)') }
    if #h == 4 then L.hit = { x = tonumber(h[1]), y = tonumber(h[2]), z = tonumber(h[3]), dist = tonumber(h[4]) } end
    if L.age > MAX_AGE or L.age < -2 then return nil, string.format('look file stale (%.1f s)', L.age) end
    return L
end

-- The pilot's weapon release button, from the Export feed BombBtnFeed.lua (cockpit argument 2779, one line in
-- Logs\bombbtn.txt, rewritten at least twice a second). True only while the line says pilot=1 and is fresh; a missing or old
-- file means "not held", so a dead feed can never freeze the pod. Read at most 20 times a second.
local BTN_FILE = (Config.PAYLOAD_FEED or ''):gsub('agplus_payload%.txt$', 'bombbtn.txt')
local btn_cache, btn_read_at = false, -10
function Pave.ReleaseHeld()
    if Config.PAVE_RELEASE_FREEZE == false then return false end
    local now = Util.Now()
    if now - btn_read_at < 0.05 and now >= btn_read_at then return btn_cache end
    btn_read_at = now
    btn_cache = false
    local f = io.open(BTN_FILE, 'r')
    if not f then return false end
    local text = f:read('*a')
    f:close()
    local t = tonumber(text and text:match('t=([%d%.]+)'))
    local p = tonumber(text and text:match('pilot=(%d)'))
    if t and p == 1 then
        local age = now - t
        btn_cache = age < 1.5 and age > -2
    end
    return btn_cache
end

-- Whether the held target is hidden behind terrain, set once a second by PaveSearch from the terrain line-of-sight feed. The flag
-- expires after 3 s so a feed that stops can never leave it stuck on.
local masked_now, masked_t = false, -100
-- A look there whose point sits in the blind zone behind the tail (Oct 20 2026): the chase stops, the point is remembered here and the
-- slew is run again by itself when the point has been clear of the zone for PAVE_AUTO_REACQ_S (3) seconds (like a lost hold).
local lt_wait = nil
local last_look = nil   -- the point of the look there that just finished: if the pod loses track soon after (it flies up into the tail blind zone as the aircraft leaves the point), it is treated as a lost hold
function Pave.SetMasked(m)
    if m ~= masked_now then
        Dbg.Notice(m and 'Target Masked By Terrain' or 'Target Visible Again', 4)
        AGLog.Info('pave: held target is %s', m and 'masked by terrain, the pod keeps aiming along the line to it, no zoom in or laser changes' or 'visible again')
    end
    masked_now, masked_t = m, Util.Now()
end
function Pave.IsMasked()
    return masked_now and Util.Now() - masked_t < 3
end

local last_stick = { x = 0, y = 0, t = -100, n = 0 }   -- the last stick command Jester sent (HCU probe reads it)
function Pave.LastStick() return last_stick end

local function place_stick(x, y)
    last_stick = { x = x, y = y, t = Util.Now(), n = last_stick.n + 1 }
    pcall(function()
        ClickRaw(Interactions.devices.RADAR, Interactions.device_commands.RADAR_ANTENNA_HAND_CONTROL_SLEW_X, x)
        ClickRaw(Interactions.devices.RADAR, Interactions.device_commands.RADAR_ANTENNA_HAND_CONTROL_SLEW_Y, y)
    end)
end

-- One line of the cockpit and pod state that decides whether the trigger can take the pod into track (for the intermittent
-- "pod would not enter track" case, Oct 15 2026): power, stow, readiness, the WSO scope's video source and screen mode.
local function pod_state()
    local out = {}
    local function add(k, f)
        local ok, v = pcall(f)
        out[#out + 1] = k .. '=' .. (ok and tostring(v) or 'err')
    end
    add('ready', function() return PaveSpike.IsReady() end)
    add('stowed', function() return PaveSpike.IsStowed() end)
    add('power', function() return PaveSpike.IsPowerOn() end)
    add('video', function() return GetProperty('/WSO Cockpit/WSO Front Panel/Video Selector', 'Video Mode').value end)
    add('videoSel', function() return GetJester():GetCockpit():GetManipulator('Video Select'):GetState() end)
    add('screen', function() return GetJester():GetCockpit():GetManipulator('Screen Mode'):GetState() end)
    add('laserReady', function() return GetJester():GetCockpit():GetManipulator('TGP Laser Ready'):GetState() end)
    add('acqSw', function() return GetJester():GetCockpit():GetManipulator('TGP Acquisition Mode'):GetState() end)
    return table.concat(out, ' ')
end

-- Released -> half action -> released toggles ACQUISITION / TRACK (stock Pave Spike does exactly this). Logged so a trigger that
-- never reaches the pod can be told from one that did and had no effect (Oct 15 2026: look there left the pod in ACQUISITION).
local last_trigger_t = -100
local function send_trigger()
    last_trigger_t = Util.Now()
    local function note(what)
        local st
        pcall(function() st = tostring(GetJester():GetCockpit():GetManipulator('Antenna Trigger'):GetState()) end)
        AGLog.Info('pave: track trigger sequence %s (pod mode %s, Antenna Trigger %s)', what, tostring(op_mode()), tostring(st))
    end
    local ok, err = pcall(function()
        local t = Task:new():ClickSequenceFast('Antenna Trigger', 'RELEASED', 'HALF_ACTION', 'RELEASED')
        pcall(function() t:AddOnActivationCallback(function() note('started') end) end)
        pcall(function() t:AddOnFinishedCallback(function() note('finished') end) end)
        pcall(function() t:AddOnCancelledCallback(function() note('cancelled') end) end)
        GetJester():AddTask(t)
    end)
    AGLog.Info('pave: track trigger sequence queued%s', ok and '' or (' FAILED: ' .. tostring(err)))
end

-- Oct 16 2026: the trigger does nothing while the WSO scope is on the radar display (screen=radar in every failing mission,
-- screen=tv in every working one). When it is not on tv, a task of its own switches it and the trigger goes out about 1.2 s
-- later from the behavior tick. Never a Wait inside the task: Task:Wait with a plain number jammed Jester's queue (the first
-- try, same day). keep_screen = true (the cage press) leaves the screen alone.
local trigger_after = nil

-- Puts the WSO scope on TV when it is not (a task click). Returns true when a switch was ordered. Used by the track trigger
-- below and, since Oct 19 2026, by the laser code Enter press, so the scope is already on TV before any search is asked for.
local function ensure_tv_screen(why)
    if Config.PAVE_FORCE_TV_SCREEN == false then return false end
    local scr
    pcall(function() scr = tostring(GetJester():GetCockpit():GetManipulator('Screen Mode'):GetState()) end)
    if scr and scr ~= 'tv' then
        AGLog.Info('pave: WSO screen mode is %s, switching to tv (%s)', scr, why)
        Dbg.Say('Switching WSO Scope To TV')
        return (pcall(function() GetJester():AddTask(Task:new():Click('Screen Mode', 'tv')) end))
    end
    return false
end

local function trigger_half_action(keep_screen)
    if trigger_after then return end
    if not keep_screen and ensure_tv_screen('the track trigger follows') then
        trigger_after = Util.Now() + 1.2
        return
    end
    send_trigger()
end

local function say(phrase)
    pcall(function() GetJester():AddTask(Task:new():Say(phrase)) end)
end

local function cant_do()
    pcall(function() GetJester():AddTask(Task:new():CantDo()) end)
end

--------------------------------------------------------------------------------
-- Behavior
--------------------------------------------------------------------------------

local PaveBehavior = Class(Behavior)
Pave.Behavior = PaveBehavior

-- Zoom for a slew to a listed target. The pod's slew rate follows its field of view: measured at full stick, 5.8 deg/s zoomed
-- out (wide) and 1.8 deg/s zoomed in (narrow, 2.6x). So a slew to a picked target runs zoomed out, in three steps:
--   far:  the fast slew loop (full stick) until the pod is within ZOOM_FINE_M of the aim point on the ground
--   fine: the hold trim loop, still zoomed out, until the pod is within ZOOM_IN_M (then it zooms in)
--   near: zoomed in, the hold trim loop as before
-- The fine step trims with a stronger gain than the hold (0.3 per degree, dead band 0.004 deg; the pod answers a stick about
-- 0.25 s late, so this is still well inside stable). Even so 5 m is not always reached at long range and a shallow look
-- angle (a meter along the ground is a few thousandths of a degree), so the fine step also ends when the pod has stayed
-- within ZOOM_NEAR_M for half a second, or after ZOOM_FINE_MAX_S. The zoom is the challenge button (stick button 1)
-- and changes over about 1.3 s, so it is never pressed twice within ZOOM_GAP_S.
local ZOOM_IN_M = Config.PAVE_ZOOM_IN_M or 5
local ZOOM_IN_HOLD_S = 0.3
local ZOOM_NEAR_M = Config.PAVE_ZOOM_NEAR_M or 15      -- or within this for ZOOM_NEAR_HOLD_S
local ZOOM_NEAR_HOLD_S = 0.5
local ZOOM_FINE_M = Config.PAVE_ZOOM_FINE_M or 200
local ZOOM_FINE_MAX_S = Config.PAVE_ZOOM_FINE_MAX_S or 2.5
local ZOOM_SKIP_M = 40          -- already this close at the start: no point zooming out
local ZOOM_WIDE_FOV = 0.07      -- wide 0.103 rad, narrow 0.0395 rad
local ZOOM_GAP_S = 2.5
local zoom_click_t = -100

local function pod_is_wide()
    local ok, f = pcall(function() return num(GetProperty(PS .. '/Pave Spike (Local)', 'Field Of View').value) end)
    if not ok or not f then return nil end
    return f > ZOOM_WIDE_FOV
end

-- Ask for wide or narrow. Returns true when the pod is already there.
local zoom_raw = (Config.PAVE_ZOOM_RAW ~= false)   -- press the challenge button directly (no wait behind Jester's speech)
local zoom_release_at, zoom_last_raw, zoom_last_want = nil, false, nil
local cage_zoom_until = nil   -- after the pod is caged, zoom out (retried until the pod is wide or this time passes)

local function set_zoom(want_wide, now, why)
    local wide = pod_is_wide()
    if wide == nil then return true end
    if wide == want_wide then return true end
    if not want_wide and Pave.IsMasked() then return false end   -- no point zooming in on the terrain in the way
    if now - zoom_click_t < ZOOM_GAP_S then return false end
    if zoom_last_raw and zoom_raw and zoom_last_want ~= nil and wide ~= zoom_last_want then
        -- The last direct press did not change the field of view: go back to the task click that is known to work.
        zoom_raw = false
        AGLog.Info('pave: zoom: the direct button press did not change the field of view, using the task click')
    end
    zoom_click_t = now
    zoom_last_raw = false
    zoom_last_want = want_wide
    if zoom_raw then
        local ok = pcall(function()
            ClickRaw(Interactions.devices.RADAR, Interactions.device_commands.RADAR_ANTENNA_HAND_CONTROL_CHALLENGE, 1)
        end)
        if ok then
            zoom_release_at = now + 0.15
            zoom_last_raw = true
        else
            zoom_raw = false
        end
    end
    if not zoom_last_raw then
        pcall(function() GetJester():AddTask(Task:new():ClickShort('Antenna Challenge', 'ON')) end)
    end
    Dbg.Say('JPod Zoom ' .. (want_wide and 'Out' or 'In') .. ' - ' .. tostring(why))
    AGLog.Info('pave: zoom %s (%s)%s', want_wide and 'out' or 'in', why, zoom_last_raw and ' [direct press]' or ' [task click]')
    return false
end

-- True when the pod is zoomed out (wide), false when zoomed in, nil when unreadable.
function Pave.PodIsWide() return pod_is_wide() end

-- Ask for wide (true) or narrow (false) from outside this file (the search zoom). True when the pod is already there.
function Pave.SetZoom(want_wide, why)
    return set_zoom(want_wide, Util.Now(), why)
end

-- Called each tick for a job with zoom_slew. Returns true while the fast slew loop should run (zoomed out, far), false when
-- the hold trim loop should run.
local function zoom_step(job, now, S, hit, az_err, el_err, have_el)
    -- A look there goes back to the zoom the pod had when it was asked; a listed target always ends zoomed in.
    if job.zwas_wide == nil then job.zwas_wide = (pod_is_wide() == true) end
    if job.zphase == 'near' then
        if not job.zdone then
            if job.look and job.zwas_wide then job.zdone = true
            else job.zdone = set_zoom(false, now, 'close to the target') end
        end
        return false
    end
    local sl = dist3(S, hit)
    local graze = sl > 1 and ((S.y - hit.y) / sl) or 0
    local cel = math.max(math.cos(math.rad(have_el)), 0.05)
    local lat = sl * cel * math.rad(az_err)
    local along = sl * math.rad(el_err) / math.max(graze, 0.1)
    local miss = math.sqrt(lat * lat + along * along)
    job.zmiss = miss
    if pod_is_wide() == nil then
        job.zphase = 'near'; job.zdone = true
        AGLog.Info('pave: %s: zoom unreadable, no zoom change', job.what)
        return false
    end
    if not job.zphase then
        if graze > 0.82 or miss < (job.look and (Config.PAVE_LOOK_ZOOM_SKIP_M or 900) or ZOOM_SKIP_M) then
            job.zphase = 'near'
            AGLog.Info('pave: %s: %s (%.0f ft off, look angle %.0f deg), no wide slew', job.what, graze > 0.82 and 'steeply down' or 'already close', miss * 3.28084, math.deg(math.asin(clamp(graze, -1, 1))))
            return zoom_step(job, now, S, hit, az_err, el_err, have_el)
        end
        job.zphase = 'far'
        job.zstart = now
        AGLog.Info('pave: %s: slewing zoomed out, %.0f ft off, zooms in within %.0f ft', job.what, miss * 3.28084, ZOOM_IN_M * 3.28084)
    end
    if graze > 0.82 then
        job.zphase = 'near'
        AGLog.Info('pave: %s: look angle too steep to stay zoomed out, zooming in (%.0f ft off)', job.what, miss * 3.28084)
        return zoom_step(job, now, S, hit, az_err, el_err, have_el)
    end
    if not pod_is_wide() then set_zoom(true, now, 'fast slew') end
    if job.zphase == 'far' then
        if miss <= ZOOM_FINE_M and math.abs(az_err) < 0.6 and math.abs(el_err) < 0.6 then
            job.zphase = 'fine'
            job.zfine = now
            AGLog.Info('pave: %s: %.0f ft off after %.1f s, trimming zoomed out', job.what, miss * 3.28084, now - job.zstart)
        else
            return true
        end
    end
    -- fine
    if miss <= ZOOM_IN_M then job.zok = job.zok or now else job.zok = nil end
    if miss <= ZOOM_NEAR_M then job.znear = job.znear or now else job.znear = nil end
    local why
    if job.zok and now - job.zok >= ZOOM_IN_HOLD_S then
        why = string.format('within %.1f ft', miss * 3.28084)
    elseif job.znear and now - job.znear >= ZOOM_NEAR_HOLD_S then
        why = string.format('within %.0f ft (%.1f ft now, 16 ft not reached)', ZOOM_NEAR_M * 3.28084, miss * 3.28084)
    elseif now - job.zfine >= ZOOM_FINE_MAX_S then
        why = string.format('%.1f ft off after %.1f s of trimming', miss * 3.28084, ZOOM_FINE_MAX_S)
    end
    if why then
        job.zphase = 'near'
        AGLog.Info('pave: %s: %s after %.1f s, zooming in', job.what, why, now - job.zstart)
        return zoom_step(job, now, S, hit, az_err, el_err, have_el)
    end
    return false
end

function PaveBehavior:Constructor()
    Behavior.Constructor(self)
    self.job = nil
    self.dscg_seen = nil
    self.stick = { x = 0, y = 0 }
    self.current_cockpit = nil
    self.progress_log = 0
end

local function live()
    local inst
    pcall(function() inst = GetJester().behaviors[Pave.Behavior] end)
    return inst
end

-- True when the job's own zoom handling (the wide slew and the zoom in on arrival) is over, so another caller may change the zoom.
function Pave.ZoomSettled()
    local inst = live()
    local j = inst and inst.job
    return (not j) or (not j.zoom_slew) or (j.zphase == 'near' and j.zdone == true)
end

function PaveBehavior:SetStick(x, y)
    -- A held target is trimmed with taps well under 0.02, so the usual change threshold would swallow them.
    local step = (self.job and self.job.hold) and 0.003 or 0.02
    if math.abs(x - self.stick.x) > step or math.abs(y - self.stick.y) > step or (x == 0 and y == 0 and (self.stick.x ~= 0 or self.stick.y ~= 0)) then
        self.stick.x, self.stick.y = x, y
        place_stick(x, y)
    end
end

function PaveBehavior:Finish(ok, why)
    local job = self.job
    self.job = nil
    place_stick(0, 0)
    self.stick.x, self.stick.y = 0, 0
    if not job then return end
    if not ok then Dbg.Say('Pod Job Ended - ' .. tostring(job.what or 'slew') .. ': ' .. tostring(why or '')) elseif not job.quiet then Dbg.Say('Pod On Target - ' .. tostring(job.what or 'slew')) end
    AGLog.Info('pave: %s %s after %.1f s (%s)', job.what or 'slew', ok and 'done' or 'abandoned', Util.Now() - job.started, why or '')
    if ok and job.what == 'look there' then
        -- The slew has ended: the Tgt Alt dial goes to the terrain height where the pod looks now (once).
        local Search = package.loaded['agplus.PaveSearch']
        if Search and Search.TgtAltAtPod then pcall(Search.TgtAltAtPod) end
        if not lt_wait and Config.PAVE_TAIL_WAIT ~= false and Config.PAVE_LT_LOST_REACQ ~= false then
            local h
            pcall(function() h = job.get() end)
            if h then last_look = { hit = { x = h.x, y = h.y, z = h.z }, t = Util.Now(), tries = job.lt_tries or 0 } end
        end
    end
    if job.look and job.zoom_slew and job.zwas_wide == false then
        -- The look there ran zoomed out: back to the narrow view the pod had when it was asked.
        pcall(function() if pod_is_wide() then set_zoom(false, Util.Now(), 'look there ended') end end)
    end
    if not job.quiet then
        if ok then say('Lantirn/captured') else cant_do() end
    end
end

function Pave.JobActive()
    local inst = live()
    return inst ~= nil and inst.job ~= nil
end

-- Stop whatever the pod is steering to, without a word.
function Pave.Stop()
    local inst = live()
    if inst and inst.job then
        inst.job.quiet = true
        inst:Finish(false, 'stopped')
    end
end

-- A context press that is not for us goes straight back to stock.
local function forward_to_stock(task, kind)
    local inst
    pcall(function() inst = GetJester().behaviors[PrepareDscg] end)
    if inst then inst:PilotRequestsContextAction(task, PrepareDscg.click_type[kind]) end
end

local function pave_spike_active()
    local active = false
    pcall(function()
        local inst = GetJester().behaviors[PrepareDscg]
        active = inst ~= nil and inst.current_mode == PrepareDscg.mode.PAVE_SPIKE
    end)
    return active
end

-- Pave Spike (Tgt Find) is the active Jester mode.
function Pave.SpikeActive() return pave_spike_active() end

-- The running hold has reached its target and sat on it (see the slew job).
function Pave.HoldOnTarget()
    local inst = live()
    return inst ~= nil and inst.job ~= nil and inst.job.on_target == true
end

-- True while a track trigger sequence is queued, was sent in the last 4 s, or a job is still waiting for track. The laser cue shares the
-- Antenna Trigger (half action for track, full action for the laser): a laser toggle that lands in the middle of a track-entry
-- sequence (go to a target behind the aircraft, Oct 19 2026: both pods, 3.6 s into the job) puts the trigger through half and
-- full in the wrong order and the pod leaves track again. The laser cue waits while this is true.
function Pave.TriggerBusy()
    if trigger_after ~= nil then return true end
    if Util.Now() - last_trigger_t < 4 then return true end
    local inst = live()
    return (inst and inst.job and inst.job.phase == 'engage') and true or false
end

-- Start steering the pod to a world point. get() returns the point {x, y, z} each time it is asked (a moving target can
-- hand back a fresh position), or nil when the target is gone. L is a fresh look file read, if the caller has one.
-- opts: continuous = keep following the point until stopped (no arrival), quiet = no speech at the end, timeout = seconds.
function Pave.StartSlew(task, get, what, L, opts)
    cage_zoom_until = nil   -- a new job decides the zoom itself
    if not (opts and opts.lt_tries) then lt_wait = nil end   -- any other job, or a new look there, ends the wait
    last_look = nil
    local inst = live()
    if not inst then
        AGLog.Info('pave: %s refused: Pave behavior not running', what)
        task:CantDo()
        return false
    end
    if not PaveSpike.IsReady() then
        AGLog.Info('pave: %s refused: pod is not ready', what)
        task:CantDo()
        return false
    end
    if not L then
        local why
        L, why = Pave.ReadLook()
        if not L then
            AGLog.Info('pave: %s refused: %s', what, tostring(why))
            task:CantDo()
            return false
        end
    end
    local hit = get()
    if not hit then
        AGLog.Info('pave: %s refused: target position unknown', what)
        task:CantDo()
        return false
    end
    local az, el = Pave.Direction(L.self, hit)
    local body_el = Pave.BodyElevation(az, el, L.self.heading, L.self.pitch, L.self.bank)
    if body_el > DATUM_LIMIT then
        Dbg.Say(string.format('Slew Refused - %s is %.1f deg above the datum line (limit %.0f deg)', tostring(what), body_el, DATUM_LIMIT), 4)
        AGLog.Info('pave: %s refused: spot is %.1f deg above the aircraft datum line (limit %.1f)', what, body_el, DATUM_LIMIT)
        task:CantDo()
        return false
    end
    local mode = op_mode()
    inst.job = { get = get, what = what, started = Util.Now(), phase = (mode == 1) and 'slew' or 'engage', engage_by = Util.Now() + ENGAGE_FIRST, eng_t0 = Util.Now(), settled = 0,
        continuous = opts and opts.continuous, quiet = opts and opts.quiet, timeout = opts and opts.timeout,
        off_az = opts and opts.off_az, off_el = opts and opts.off_el, hold = opts and opts.hold, zoom_slew = opts and opts.zoom_slew, look = opts and opts.look, ground = opts and opts.ground, aft_ground = opts and opts.aft_ground, lt_tries = opts and opts.lt_tries }
    inst.job.body_el = body_el
    if not (opts and opts.quiet) then Dbg.Say('JPod Slewing - ' .. tostring(what) .. string.format(' (%.1f deg %s the datum line)', math.abs(body_el), body_el > 0 and 'above' or 'below') .. (mode ~= 1 and ' - entering track first' or '')) end
    AGLog.Info('pave: %s: bearing %.1f, elevation %.1f (body %.1f); pod mode %s', what, az, el, body_el, tostring(mode))
    do
        local pa, pe = pod_angles()
        AGLog.Info('pave: %s start: pod now %s / %s, want %.1f / %.1f (world), target %.0f ft from aircraft, target map position (%.0f, %.0f, %.0f) m',
            what, pa and string.format('%.1f', pa) or 'nil', pe and string.format('%.1f', pe) or 'nil', az, el, dist3(L.self, hit) * 3.28084, hit.x, hit.y, hit.z)
    end
    -- Oct 20 2026: the pod takes its range from the Target Alt dial (a flat plane at that height). Each finished look there sets the dial to
    -- the terrain under the pod, often a ridge above the aircraft; the next track then has no plane under it (slant range 5 ft, height above
    -- target negative), the stick moves the ground point at that range and the pod ran off at 10 to 20 deg/s ("pod left track", unable).
    -- So before a look there starts, the dial goes to the target's height, but never above 1000 ft under the aircraft.
    if what == 'look there' and Config.PAVE_AUTO_TGT_ALT ~= false and Config.PAVE_DIAL_BEFORE_SLEW ~= false then
        pcall(function()
            if tostring(Util.DeliveryMode()) ~= 'TGT_FIND' then return end
            local plane_m = math.min(hit.y, L.self.y - 304.8)
            local val = math.floor(plane_m / 0.3048 / 10 + 0.5) * 10
            AGLog.Info('pave: look there: Target Alt dial to %d ft before the slew (target %.0f ft, aircraft %.0f ft): the pod takes its range from it', val, hit.y / 0.3048, L.self.y / 0.3048)
            Dispatch('agp_tgt_alt', val)
        end)
    end
    if not (opts and opts.quiet) then task:Roger() end
    if inst.job.phase == 'engage' then
        AGLog.Info('pave: %s: pod state before the track trigger: %s', what, pod_state())
        trigger_half_action()
    end
    return true
end

-- Whether the player's head points at the panel and the scope (inside) rather than out of the canopy. Two zones, in degrees from the
-- aircraft nose line (Oct 19 2026, from the flight of that day: looks 20 to 30 deg down at 35 to 45 deg to the side were out of the
-- windscreen quarter panes and the canopy, and were wrongly inside):
--   the panel: within PAVE_LOOK_INSIDE_AZ_DEG (25) of the nose and more than PAVE_LOOK_INSIDE_EL_DEG (22) below it;
--   the floor and consoles: within PAVE_LOOK_FLOOR_AZ_DEG (60) of the nose and more than PAVE_LOOK_FLOOR_EL_DEG (50) below it.
-- A camera more than PAVE_LOOK_CAM_MAX_M from the aircraft is an external view and counts as outside (the ground line still works).
-- Returns inside (nil when the feed has no camera), body azimuth, body elevation.
function Pave.LookInside(L)
    local c = L and L.cam
    if not c then return nil end
    local az, el = math.abs(c.body_az), c.body_el
    local panel = az <= (Config.PAVE_LOOK_INSIDE_AZ_DEG or 25) and el < -(Config.PAVE_LOOK_INSIDE_EL_DEG or 22)
    local floor = az <= (Config.PAVE_LOOK_FLOOR_AZ_DEG or 60) and el < -(Config.PAVE_LOOK_FLOOR_EL_DEG or 50)
    local inside = c.off_m <= (Config.PAVE_LOOK_CAM_MAX_M or 20) and (panel or floor)
    return inside, c.body_az, c.body_el
end

function Pave.LookThere(task)
    local L, why = Pave.ReadLook()
    if not L then
        AGLog.Info('pave: look there refused: %s', tostring(why))
        task:CantDo()
        return
    end
    do
        local inside, baz, bel = Pave.LookInside(L)
        if inside ~= nil then
            AGLog.Info('pave: look there: head %s (azimuth %+.0f, elevation %+.0f deg to the aircraft nose line, camera %.0f ft from the aircraft)', inside and 'INSIDE' or 'outside', baz, bel, L.cam.off_m / 0.3048)
            if inside and Config.PAVE_LOOK_REQUIRE_OUTSIDE ~= false then
                task:CantDo()
                return
            end
        end
    end
    if not L.hit then
        AGLog.Info('pave: look there refused: the view line does not meet the ground')
        task:CantDo()
        return
    end
    local hit = L.hit
    -- A long slew runs zoomed out (the pod slews faster wide) and zooms back to where it was at the end.
    Pave.StartSlew(task, function() return hit end, 'look there', L, { zoom_slew = (Config.PAVE_LOOK_ZOOM_OUT ~= false), look = true, aft_ground = true })
end

-- The pod is in track and nothing is slewing: a long press starts the area search instead of a new look-there.
function Pave.PodInTrackIdle()
    local inst = live()
    return op_mode() == 1 and inst ~= nil and inst.job == nil
end

function Pave.Reset(task)
    lt_wait = nil
    last_look = nil
    local Search = package.loaded['agplus.PaveSearch']
    if Search then Search.Cancel() end
    local inst = live()
    if inst and inst.job then inst:Finish(false, 'reset by pilot') end
    place_stick(0, 0)
    local mode = op_mode()
    if mode and mode ~= 0 then trigger_half_action(true) end   -- back out of track / memory
    if Config.PAVE_CAGE_ZOOM_OUT ~= false then cage_zoom_until = Util.Now() + 8 end   -- caged to 12 VIS: zoom out too
    AGLog.Info('pave: reset (pod mode was %s)', tostring(mode))
    task:Roger()
end

-- Long press while a hold is active: set the WRCS Drag Coefficient dial for the bomb on the armed stations, from the flight state now
-- (the same tables the automatic mode uses, Lgb.lua). Jester is unable when no bomb is armed, when more than one type is armed, or
-- when the armed bomb has no drag table.
function Pave.ProgramDrag(task)
    local function unable(why)
        Dbg.Notice('Drag Coefficient Unable - ' .. why, 4)
        AGLog.Info('pave: drag coefficient request refused: %s', why)
        task:CantDo()
    end
    local ok, err = pcall(function()
        local Mode = require('agplus.Mode')
        local Lgb = require('agplus.Lgb')
        local w, reason, names = Mode.ArmedWeapon()
        if not w then
            if reason == 'mixed' then unable('Mixed Stations Armed (' .. tostring(names) .. ')')
            elseif reason == 'unknown' then unable('Unknown Weapon ' .. tostring(names))
            else unable('No Bomb Armed') end
            return
        end
        if not w.lgb then
            unable(tostring(w.label) .. ' Has No Drag Table')
            return
        end
        -- A moving held vehicle: the lead point (PaveSearch.lua) sets the altitude expected at the release for the drag coefficient.
        local plan
        local Search = package.loaded['agplus.PaveSearch']
        if Search and Search.LeadPlan then
            local okp, pl = pcall(Search.LeadPlan)
            if okp then plan = pl else AGLog.Info('pave: lead plan failed: %s', tostring(pl)) end
        end
        local dial, coeff, alt, tas, dive = Lgb.Program(w.lgb, plan and plan.alt_delta_ft or nil, plan and (Config.PAVE_LEAD_DIAL_OFFSET or -10) or nil)
        if not dial then unable(tostring(w.label) .. ' Has No Drag Table') return end
        -- One message for both: two Notices in the same frame overwrite each other and only the last is shown.
        local lead_set = false
        if plan and Search.LeadStart then
            local okl, el = pcall(Search.LeadStart, plan)
            if not okl then AGLog.Info('pave: lead start failed: %s', tostring(el)) else lead_set = el == true end
        end
        Dbg.Notice(string.format('%sDrag Coefficient %.2f Set - %s (%.0f ft, %.0f kt, %.0f deg dive)', lead_set and 'Lead Point and ' or '', coeff, w.label, alt, tas, dive), 5)
        task:Roger()
    end)
    if not ok then
        AGLog.Info('pave: drag coefficient request failed: %s', tostring(err))
        task:CantDo()
    end
end

-- Pod context list (Oct 21 2026): when the Strike List has targets and the pod is caged, holding or has a lost hold waiting, the first short press opens a
-- list of the Strike List slots with "Search Area" after the last slot (so the list goes round slot 1 ... last, Search Area, slot 1). Every further press
-- moves the cursor (short = next, double = previous) and Config.PAVE_PICK_DWELL_S (MAV_PICK_DWELL_S, 1.5) after the last press the pod goes to the
-- cursor (a slot: as the wheel's Go To) or starts the area search. A long press has no job in the list; it only drops a waiting pick. A double press
-- within PAVE_PICK_GRACE_S (1) after the list closed is swallowed (invisible protection). Config.PAVE_PICK = false turns the list off,
-- Config.PAVE_PICK_FROM_CAGE = false keeps a caged pod's short press as the stock action.
local pod_pick = nil        -- { cursor = slot number or 'search', t = last press, shown = last draw }
local pod_grace = -10

-- Inside the pod's blind zone behind the tail (az right of the nose, el above the datum line).
function Pave.InTailZone(az, el)
    local tz, te = tail_zone()
    return tz < 180 and math.abs(az) > tz and el > te
end

-- Where a vehicle sits relative to the nose, in arrows: one per 30 deg (6 arrows is straight behind us); the out mark for the blind zone behind the
-- tail and for a point above the datum line, which the pod cannot hold.
local function pod_glyph(Search, e)
    local L = Pave.ReadLook()
    if not L then return '?', 'no aircraft data' end
    local p = Search.EntryPoint(e)
    local waz, wel = Pave.Direction(L.self, p)
    local baz, bel = Pave.ToBody(waz, wel, L.self.heading, L.self.pitch, L.self.bank)
    local OUT, UP = PickMenu.Cfg('MAV_LIST_OUT', '!!!'), PickMenu.Cfg('MAV_LIST_UP', '^')
    if Config.PAVE_TAIL_MASK ~= false and Pave.InTailZone(baz, bel) then return OUT, 'behind the tail, the pod cannot hold there' end
    if bel > DATUM_LIMIT then return OUT .. UP, 'above the datum line, the pod cannot look there' end
    local glyph, ahead = PickMenu.Arrows(baz, PickMenu.Cfg('PAVE_LIST_DEG_PER_ARROW', 30), PickMenu.Cfg('MAV_LIST_MAX_ARROWS', 6), PickMenu.Cfg('PAVE_LIST_CENTER_DEG', 6))
    local a = math.abs(baz)
    local side = baz > 0 and 'right' or 'left'
    local words
    if ahead then words = 'ahead'
    elseif a < 45 then words = 'slightly ' .. side
    elseif a > 135 then words = 'behind us, ' .. side
    else words = side end
    return glyph, words
end

local function pod_pick_dwell() return Config.PAVE_PICK_DWELL_S or Config.MAV_PICK_DWELL_S or 1.5 end

-- The cursor positions in order: 'reacq' (a lost target that is not in a Strike List slot), the filled Strike List slots, then 'search'.
-- Search Area is always there, so the list opens with an empty Strike List too (Oct 22 2026).
-- Context List source (Nov 11 2026, Strike List > Manage > Context List): the Strike List slots (key = slot number) or the full target list
-- (key = the unit's id). Returns an array of { key, e } in list order.
local function pod_entries()
    local T = package.loaded['agplus.Targets']
    local Search = package.loaded['agplus.PaveSearch']
    local out = {}
    if T and T.ListFull and T.ListFull() then
        if Search and Search.FlatList then
            for _, e in ipairs(Search.FlatList()) do
                if e.id and e.id >= 0 then out[#out + 1] = { key = e.id, e = e } end
            end
        end
    else
        local slots, n = T and T.Slots and T.Slots(), (T and T.N) or 6
        if slots then
            for j = 1, n do if slots[j] then out[#out + 1] = { key = j, e = slots[j] } end end
        end
    end
    return out
end

-- The list key of the unit with this id (the held or last held one), or nil when it is not in the list.
local function pod_key_of(entries, id)
    if id == nil then return nil end
    local T = package.loaded['agplus.Targets']
    if T and T.ListFull and T.ListFull() then
        for _, it in ipairs(entries) do if it.e.id == id then return it.key end end
        return nil
    end
    return T and T.SlotOfId and T.SlotOfId(id) or nil
end

local function pod_keys()
    local Search = package.loaded['agplus.PaveSearch']
    local entries = pod_entries()
    local keys = {}
    pcall(function()
        local mode, hid = Search.PodPickState()
        if mode == 'lost' and Search.PodReacquire and not pod_key_of(entries, hid) then keys[#keys + 1] = 'reacq' end
    end)
    for _, it in ipairs(entries) do keys[#keys + 1] = it.key end
    keys[#keys + 1] = 'search'
    return keys, entries
end

local function pod_key_step(keys, cur, dir)
    local pos = 1
    for i, k in ipairs(keys) do if k == cur then pos = i end end
    return keys[((pos - 1 + dir) % #keys) + 1]
end

local function pod_pick_show(Search)
    local pk = pod_pick
    if not pk then return end
    local keys, entries = pod_keys()
    if #keys == 0 then return end
    local by_key = {}
    for _, it in ipairs(entries) do by_key[it.key] = it.e end
    local items, ci = {}, 1
    for i, k in ipairs(keys) do
        if k == 'search' then
            items[#items + 1] = { key = k, name = 'Search Area', glyph = '', words = 'looks for targets around the pod view' }
        elseif k == 'reacq' then
            items[#items + 1] = { key = k, name = 'Reacquire ' .. tostring(Search.PodLastHeldName and Search.PodLastHeldName() or 'Target'), glyph = '', words = 'the lost target, now' }
        else
            local e = by_key[k]
            local g, w = pod_glyph(Search, e)
            items[#items + 1] = { key = k, name = tostring(e.alias or '?'), glyph = g, words = w }
        end
        if k == pk.cursor then ci = i end
    end
    local _, hid = Search.PodPickState()
    local cur = pod_key_of(entries, hid)
    local lines = PickMenu.Lines(items, ci, cur, 'Press To Step - Pause To Switch')
    pk.shown = Util.Now()
    Dbg.Notice('MENU|' .. table.concat(lines, '|'), 1.0)
end

-- Returns true when the press belongs to the list.
local function pod_pick_press(Search, kind)
    if Config.PAVE_PICK == false or not (Search and Search.PodPickState) then return false end
    local now = Util.Now()
    if kind == 'DOUBLE' and not pod_pick and now < pod_grace then
        AGLog.Info('pave: double press just after the list closed, ignored')
        return true
    end
    local keys = pod_keys()
    if pod_pick then
        if #keys == 0 then pod_pick = nil return false end
        pod_pick.cursor = pod_key_step(keys, pod_pick.cursor, kind == 'SHORT' and 1 or -1)
        pod_pick.t = now
        AGLog.Info('pave: list cursor on %s', tostring(pod_pick.cursor))
        pod_pick_show(Search)
        return true
    end
    if kind ~= 'SHORT' or #keys == 0 then return false end
    if Search.Active() then return false end
    local mode, hid = Search.PodPickState()
    if not mode then
        -- Caged (acquisition mode): the list opens straight away instead of the stock uncage.
        if op_mode() ~= 0 or Config.PAVE_PICK_FROM_CAGE == false then return false end
        local lh = Search.PodLastHeldId and Search.PodLastHeldId()
        hid = lh
        mode = 'caged'
    end
    local cur = pod_key_of(pod_entries(), hid)
    pod_pick = { cursor = cur or keys[1], t = now, shown = -10 }
    AGLog.Info('pave: list opened (%s, cursor %s, %d entries)', mode, tostring(pod_pick.cursor), #keys)
    pod_pick_show(Search)
    return true
end

local function pod_pick_commit(Search, key)
    local T = package.loaded['agplus.Targets']
    if key == 'reacq' then
        AGLog.Info('pave: list: reacquire the lost target chosen')
        if Search.PodReacquire then Search.PodReacquire() end
        return
    end
    if key == 'search' then
        AGLog.Info('pave: list: search area chosen')
        Search.PodAreaSearch()
        return
    end
    local full = T and T.ListFull and T.ListFull()
    local e
    for _, it in ipairs(pod_entries()) do
        if it.key == key then e = it.e break end
    end
    if not e then
        Dbg.Notice((full and 'Target List' or 'Strike List') .. ' - That Target Is No Longer In The List', 4)
        return
    end
    local mode, hid = Search.PodPickState()
    if mode == 'hold' and not e.spot and hid == e.id then
        AGLog.Info('pave: list: already holding %s', tostring(e.alias))
        return
    end
    -- A lost hold with the pod in memory and the automatic reacquire on only switches the target Jester reacquires.
    if mode == 'lost' and op_mode() == 2 and Config.PAVE_AUTO_REACQUIRE ~= false and not e.spot and Search.InFlat(e.id) then
        Search.PodPickCommit(e.id, true)
        return
    end
    if full then
        -- Full target list: the pod goes to the unit itself (it need not be in a Strike List slot).
        Dbg.Notice(string.format('Target List - %s', tostring(e.alias)), 4)
        AGLog.Info('pave: list: going to %s (id %s) from the full target list', tostring(e.alias), tostring(e.id))
        if not Search.GoToEntry(e, 'go to ' .. tostring(e.alias) .. ' (full target list)') then
            AGLog.Info('pave: list: could not slew to %s', tostring(e.alias))
        end
        return
    end
    Dbg.Notice(string.format('Strike List %d - %s', key, tostring(e.alias)), 4)
    T.GoToSlot(key, 'list')
end

local function pod_pick_tick()
    local Search = package.loaded['agplus.PaveSearch']
    if Search and Search.PodAreaTick then Search.PodAreaTick() end
    local pk = pod_pick
    if not pk then return end
    local now = Util.Now()
    if not Search or not pave_spike_active() then pod_pick = nil return end
    if now < pk.t then pk.t = now end
    local dwell = pod_pick_dwell()
    if now - pk.t >= dwell then
        -- The switch waits for the pickle button and a track trigger that is still going (at most 5 s).
        if (Pave.ReleaseHeld() or Pave.TriggerBusy()) and now - pk.t < dwell + 5 then
            if now - pk.shown >= 0.5 or now < pk.shown then pod_pick_show(Search) end
            return
        end
        pod_pick = nil
        pod_grace = now + (Config.PAVE_PICK_GRACE_S or Config.MAV_PICK_GRACE_S or 1.0)
        local ok, err = pcall(pod_pick_commit, Search, pk.cursor)
        if not ok then AGLog.Info('pave: list commit failed: %s', tostring(err)) end
        return
    end
    if now - pk.shown >= 0.5 or now < pk.shown then pod_pick_show(Search) end
end

local function on_press(task, kind)
    lt_wait = nil   -- a press of the pilot ends a look there that was waiting for the blind zone to clear
    last_look = nil
    local ok, handled = pcall(function()
        local Search = package.loaded['agplus.PaveSearch']
        local active = pave_spike_active()
        do
            -- Every press is logged with what decides its path, so a press that ended in the stock handler can be traced.
            local mode, reacq, held = '?', false, false
            pcall(function()
                local inst = GetJester().behaviors[PrepareDscg]
                mode = inst and tostring(inst.current_mode) or 'no instance'
            end)
            pcall(function() reacq = Search and Search.ReacquirePending and Search.ReacquirePending() or false end)
            pcall(function() held = Search and Search.HoldActive and Search.HoldActive() or false end)
            AGLog.Info('pave: context press %s: Pave Spike active %s (DSCG mode %s), pod mode %s, hold %s, reacquire pending %s%s',
                tostring(kind), tostring(active), mode, tostring(op_mode()), tostring(held), tostring(reacq),
                active and '' or ' -> stock handler')
        end
        -- OFFSET delivery (Oct 22 2026): a long press sets the release range once (Wrcs.ProgramRange), like the drag coefficient in TGT FIND. A running
        -- search still ends first, and with the pod active and not holding anything the press stays look there.
        if kind == 'LONG' and string.find(string.upper(tostring(Util.DeliveryMode())), 'OFFSET') then
            local held = Search and Search.HoldActive and Search.HoldActive()
            local searching = Search and Search.Active and Search.Active()
            local W = package.loaded['agplus.Wrcs']
            if W and W.ProgramRange and not searching and (held or not active) then
                W.ProgramRange(task)
                return true
            end
        end
        if not active then
            -- Jester Mavericks (Oct 21 2026): in TV mode (DIRECT + TV) stock does nothing with the context button, so the Maverick module may take it.
            local Mav = package.loaded['agplus.Maverick']
            if Mav and Mav.ModeActive and Mav.OnPress and Mav.ModeActive() then return Mav.OnPress(task, kind) == true end
            return false
        end
        if kind ~= 'LONG' and pod_pick_press(Search, kind) then return true end
        if kind == 'LONG' then pod_pick = nil end      -- a long press has no job in the list; it only drops a waiting pick
        if kind == 'SHORT' then
            -- Pod in TRACK. Nothing held: designate and hold where the pod is looking (a vehicle within 3 deg of the crosshair, or
            -- else the ground spot). Holding something (a vehicle or a ground spot) with a target list: go on down the list (the
            -- first target after a ground spot, the next after a vehicle). Holding with no list: the pod goes to the player and
            -- Jester watches. Not in TRACK: the stock action.
            -- A lost hold comes first: the press reacquires that target (even when the pod has left track), until a hold is
            -- established again or the player double presses or long presses.
            if Search and Search.ReacquirePending and Search.ReacquirePending() then
                -- In memory Jester reacquires by himself when the target is back inside the pod limits (PaveSearch auto_reacq_tick), so the
                -- press switches to the next target in the list instead. Without the automatic reacquire, or with the pod out of memory, it
                -- reacquires the lost target now as before.
                if op_mode() == 2 and Config.PAVE_AUTO_REACQUIRE ~= false and Search.SwitchPending then
                    Search.SwitchPending(task)
                else
                    Search.Reacquire(task)
                end
                return true
            end
            -- Track (1), or memory (2: the pod lost the track itself and keeps pointing at the last spot, which is what happens after a lost
            -- hold): designate what the pod looks at. Acquisition (0) and anything else is the stock action.
            local pm = op_mode()
            if not (Search and Search.HoldStart) or (pm ~= 1 and pm ~= 2) then return false end
            if Search.Active() then Search.Cancel() end
            Search.HoldStart(task, Search.HasList and Search.HasList())
        elseif kind == 'LONG' then
            -- A running search ends. While something is held (a vehicle or a ground spot) the press programs the drag coefficient
            -- from the armed stations. Otherwise it is look there: the pod slews to where the player looks. Searching is on the
            -- wheel (Search Area).
            if Search and Search.ClearReacquire then Search.ClearReacquire() end
            if Search and Search.Active() then
                Search.EndEarly(task)
            elseif Search and Search.HoldActive and Search.HoldActive() then
                Pave.ProgramDrag(task)
            else
                Pave.LookThere(task)
            end
        else
            -- Double press: first let go of the hold / search / slew and leave the pod where it is; only when Jester is
            -- already idle does it cage the pod (back to 12 VIS, half action).
            if Search and Search.ReleaseHold and Search.ReleaseHold() then
                task:Roger()
            else
                Pave.Reset(task)
            end
        end
        return true
    end)
    if not ok then
        AGLog.Info('pave: press handler failed: %s', tostring(handled))
        handled = false
    end
    if not handled then forward_to_stock(task, kind) end
end

-- Stock registers its context handlers again whenever its behavior is rebuilt, so ours are put back every time the stock
-- instance changes. The last registration under a name wins.
local function register_handlers()
    ListenTo('context_action_short', 'PrepareDscg', function(task) on_press(task, 'SHORT') end)
    ListenTo('context_action_long', 'PrepareDscg', function(task) on_press(task, 'LONG') end)
    ListenTo('context_action_double', 'PrepareDscg', function(task) on_press(task, 'DOUBLE') end)
end

function PaveBehavior:Tick()
    pcall(pod_pick_tick)
    local cockpit = Util.Cockpit()
    if not cockpit then
        self.current_cockpit = nil
        self.job = nil
        self.dm_last, self.code_at = nil, nil
        trigger_after = nil
        self.stick.x, self.stick.y = 0, 0
        return
    end
    if self.current_cockpit ~= cockpit then
        self.current_cockpit = cockpit
        self.job = nil
        place_stick(0, 0)
    end

    if trigger_after and Util.Now() >= trigger_after then
        trigger_after = nil
        send_trigger()
    end

    if cage_zoom_until then
        local tz = Util.Now()
        if tz > cage_zoom_until or set_zoom(true, tz, 'pod caged') then cage_zoom_until = nil end
    end

    -- A look there that has just finished and then loses track (Oct 20 2026: after an overflight the point is behind the aircraft; as the aircraft flies away the
    -- point rises toward the nose-line angle of the pod's tail blind zone, the pod drops to acquisition mode or memory mode and stays there with nothing to bring
    -- it back): treat it as a lost hold, wait for the point to be clear and in view, and reacquire it by itself. Regular pod only, like the blind-zone stop.
    if last_look and not lt_wait then
        local tnow = Util.Now()
        local Search = package.loaded['agplus.PaveSearch']
        if self.job or (Search and ((Search.Active and Search.Active()) or (Search.HoldActive and Search.HoldActive()))) then
            last_look = nil
        elseif tnow - last_look.t > (Config.PAVE_LT_LOST_KEEP_S or 180) then
            last_look = nil
        elseif op_mode() ~= 1 and pave_spike_active() then
            last_look.lost_since = last_look.lost_since or tnow
            if tnow - last_look.lost_since >= (Config.PAVE_LT_LOST_CONFIRM_S or 0.5) then
                lt_wait = { hit = last_look.hit, t0 = tnow, tries = last_look.tries or 0 }
                AGLog.Info('pave: look there: the pod lost track %.1f s after the look there ended (pod mode %s); treating it as a lost hold, the point is reacquired once it is clear of the blind zone and the aircraft is steady (try %d)', tnow - last_look.t, tostring(op_mode()), lt_wait.tries + 1)
                Dbg.Notice('Look There - Pod Lost Track, Will Reacquire When Clear', 5)
                last_look = nil
            end
        else
            last_look.lost_since = nil
        end
    end

    if lt_wait then
        local tnow = Util.Now()
        local Search = package.loaded['agplus.PaveSearch']
        if self.job or Config.PAVE_TAIL_WAIT == false or (Search and ((Search.Active and Search.Active()) or (Search.HoldActive and Search.HoldActive()))) then
            lt_wait = nil
        elseif tnow - lt_wait.t0 > (Config.PAVE_TAIL_WAIT_MAX_S or 180) then
            AGLog.Info('pave: look there: the point never came clear of the blind zone in %.0f s, forgetting it', tnow - lt_wait.t0)
            lt_wait = nil
        elseif tnow - (lt_wait.checked or -1) >= 0.25 then
            lt_wait.checked = tnow
            local L2 = Pave.ReadLook()
            if L2 then
                local waz, wel = Pave.Direction(L2.self, lt_wait.hit)
                local baz, bel = Pave.ToBody(waz, wel, L2.self.heading, L2.self.pitch, L2.self.bank)
                -- Clear of the zone, well below the datum line (the first test run reacquired at -0.6 and -2.7 deg, at the pod's limit, in a bank of 30
                -- to 95 deg, and both slews ended 'pod left track'), not far round to the tail, and the aircraft flying reasonably level.
                -- Wings level (Oct 20 2026: a point 3 NM out is only 2 to 3 deg down from 1,000 ft, and the 3 deg gate held the reacquire for nearly 30 s after the
                -- rollout) the pod is not at risk in a bank, so the shallower gates apply; in a bank the stricter ones stay.
                local lvl = math.abs(L2.self.bank or 0) <= (Config.PAVE_TAIL_REACQ_LEVEL_BANK_DEG or 20)
                -- The 'world' angle is the depression angle from the aircraft down to the point itself, with the point's own altitude (a hilltop is measured to the
                -- hilltop), so a high point is judged correctly. Without the test (Oct 20 2026 run) reacquires began at 1.1 and 1.4 deg down, 31,000 and 27,000 ft out:
                -- one timed out, the other finished 2,063 ft off. At 2.2 deg and 28,000 ft one finished 632 ft off in 6.6 s.
                local g_bel = lvl and (Config.PAVE_TAIL_REACQ_EL_LEVEL_DEG or 0) or (Config.PAVE_TAIL_REACQ_EL_DEG or 4)
                local g_wel = Config.PAVE_TAIL_REACQ_WORLD_EL_DEG or false   -- off by default (Oct 20 2026): steady flying decides, not the angle
                -- Steady: pitch and bank within a few degrees of where they were when the clock started, for the whole confirm time. A change beyond the limit
                -- restarts the clock from the new attitude.
                local sp_, sb_ = L2.self.pitch or 0, L2.self.bank or 0
                local ref = lt_wait.ref
                local steady = true
                if not ref or math.abs(sp_ - ref.p) > (Config.PAVE_TAIL_STEADY_PITCH_DEG or 2) or math.abs(sb_ - ref.b) > (Config.PAVE_TAIL_STEADY_BANK_DEG or 5) then
                    lt_wait.ref = { p = sp_, b = sb_ }
                    steady = false
                end
                local tzc, tec = tail_zone()
                local clear = not (math.abs(baz) > tzc - 3 and bel > tec - 1.5)
                    and bel <= -g_bel
                    and (not g_wel or wel <= -g_wel)
                    and steady
                    and math.abs(baz) <= (Config.PAVE_TAIL_REACQ_AZ_DEG or 130)
                    and math.abs(L2.self.bank or 0) <= (Config.PAVE_TAIL_REACQ_BANK_DEG or 65)   -- a 55 to 60 deg bank is the normal turn back to the point
                    and math.abs(L2.self.pitch or 0) <= (Config.PAVE_TAIL_REACQ_PITCH_DEG or 25)
                if not clear then
                    lt_wait.since = nil
                elseif not lt_wait.since then
                    lt_wait.since = tnow
                    AGLog.Info('pave: look there: the waiting point is %.0f deg off the nose, %.1f deg below the horizon: clear of the blind zone and the aircraft steady, %.1f s to confirm', baz, -bel, Config.PAVE_TAIL_CONFIRM_S or 2)
                elseif tnow - lt_wait.since >= (Config.PAVE_TAIL_CONFIRM_S or 2) then
                    local w = lt_wait
                    lt_wait = nil
                    if w.tries >= (Config.PAVE_TAIL_WAIT_TRIES or 3) then
                        AGLog.Info('pave: look there: %d tries at the point behind the tail, leaving it', w.tries)
                    else
                        AGLog.Info('pave: look there: the waiting point is clear of the blind zone, reacquiring it without a press (try %d)', w.tries + 1)
                        Dbg.Say('Look There - Reacquiring', 3)
                        Pave.StartSlew({ Roger = function() end, CantDo = function() end }, function() return w.hit end, 'look there', L2,
                            { zoom_slew = (Config.PAVE_LOOK_ZOOM_OUT ~= false), look = true, aft_ground = true, lt_tries = w.tries + 1 })
                    end
                end
            end
        end
    end

    if zoom_release_at and Util.Now() >= zoom_release_at then
        zoom_release_at = nil
        pcall(function()
            ClickRaw(Interactions.devices.RADAR, Interactions.device_commands.RADAR_ANTENNA_HAND_CONTROL_CHALLENGE, 0)
        end)
    end

    -- Laser code: a few seconds after the Delivery Mode switch goes to TGT_FIND, press the Enter Laser Code button once
    -- (Config.PAVE_LASER_CODE_DELAY_S, default 5, false switches it off). The switch position is watched, so a flip back out
    -- of TGT_FIND before the delay is up cancels the press. The button is pressed directly (device command, held 0.15 s)
    -- like the pod zoom button, so no task can stall on a state name; if the command ids are missing it falls back to a task click.
    do
        local delay = Config.PAVE_LASER_CODE_DELAY_S
        if delay == nil then delay = 5 end
        local tnow = Util.Now()
        if self.code_release_at and tnow >= self.code_release_at then
            self.code_release_at = nil
            pcall(function()
                ClickRaw(Interactions.devices.EO_TGT_DESIGNATOR_SYSTEM_AN_ASQ_153, Interactions.device_commands.WSO_LASER_CODER_CONTROL_ENTER_BUTTON, 0)
            end)
        end
        if delay then
            local dm = tostring(Util.DeliveryMode())
            if dm ~= self.dm_last then
                if self.dm_last ~= nil and dm == 'TGT_FIND' then
                    self.code_at = tnow + delay
                    Dbg.Say('Laser Code - Entering in ' .. string.format('%.0f', delay) .. ' s (TGT FIND selected)')
                    AGLog.Info('pave: delivery mode switched to TGT_FIND, laser code goes in after %.0f s', delay)
                elseif dm ~= 'TGT_FIND' and self.code_at then
                    self.code_at = nil
                    Dbg.Say('Laser Code - Canceled (left TGT FIND)')
                    AGLog.Info('pave: delivery mode left TGT_FIND, laser code entry canceled')
                end
                self.dm_last = dm
            end
            if self.code_at and tnow >= self.code_at then
                self.code_at = nil
                ensure_tv_screen('laser code entry')
                local ok = pcall(function()
                    local dev = Interactions.devices.EO_TGT_DESIGNATOR_SYSTEM_AN_ASQ_153
                    local cmd = Interactions.device_commands.WSO_LASER_CODER_CONTROL_ENTER_BUTTON
                    assert(dev and cmd, 'ids missing')
                    ClickRaw(dev, cmd, 1)
                end)
                if ok then
                    self.code_release_at = tnow + 0.15
                    Dbg.Say('Laser Code - Entered')
                    AGLog.Info('pave: laser code entered (Enter Laser Code pressed, direct)')
                else
                    pcall(function() GetJester():AddTask(Task:new():ClickShort('Laser Code Enter', 'ON')) end)
                    Dbg.Say('Laser Code - Entered')
                    AGLog.Info('pave: laser code entered (Enter Laser Code pressed, task click)')
                end
            end
        end
    end

    local dscg
    pcall(function() dscg = GetJester().behaviors[PrepareDscg] end)
    if dscg and dscg ~= self.dscg_seen then
        self.dscg_seen = dscg
        register_handlers()
        AGLog.Info('pave: context press handlers installed')
    end

    -- While the player holds the weapon release button during a bombing run, Jester makes no input to the pod: the stick goes
    -- to center once (so the pod is not left slewing) and nothing else is sent until the button is let go. The job's clocks
    -- are pushed back by the time spent frozen so it does not time out, and the line-of-sight rate memory starts fresh.
    if Pave.ReleaseHeld() then
        Dbg.Say('Input Paused - Pickle Button Held')
        if not self.frozen_at then
            self.frozen_at = Util.Now()
            place_stick(0, 0)
            self.stick.x, self.stick.y = 0, 0
            AGLog.Info('pave: weapon release held, pod inputs stopped')
        end
        return
    elseif self.frozen_at then
        local dur = Util.Now() - self.frozen_at
        self.frozen_at = nil
        local j = self.job
        if j then
            j.started = j.started + dur
            if j.engage_by then j.engage_by = j.engage_by + dur end
            j.lw_t, j.lw_vt = nil, nil
            if j.zstart then j.zstart = j.zstart + dur end
            if j.zfine then j.zfine = j.zfine + dur end
            j.zok, j.znear = nil, nil
        end
        Dbg.Say(string.format('Input Resumed - Pickle Released (held %.1f s)', dur))
        AGLog.Info('pave: weapon release let go after %.1f s, pod inputs resume', dur)
    end

    local job = self.job
    if not job then return end
    local now = Util.Now()

    -- A slew with no set timeout (a look there) runs as long as the pod keeps closing on the target: the pod turns at 2 to 6 deg/s
    -- zoomed in or out, so a half turn takes well over the old 20 s. It ends when it has made no progress for a while, or at the
    -- hard limit.
    if job.timeout then
        if now - job.started > job.timeout then self:Finish(false, 'timed out') return end
    else
        local stall = Config.PAVE_SLEW_STALL_S or 12
        local hard = Config.PAVE_SLEW_MAX_S or 120
        if now - job.started > SLEW_TIMEOUT and now - (job.progress_t or job.started) > stall then self:Finish(false, 'timed out (no progress for ' .. tostring(stall) .. ' s)') return end
        if now - job.started > hard then self:Finish(false, 'timed out') return end
    end
    local mode = op_mode()

    if job.phase == 'engage' then
        if now - (job.eng_log or job.eng_t0 or now) >= 1 then
            job.eng_log = now
            local acq, fovm
            pcall(function() acq = GetProperty(PS, 'Acquisition Mode').value end)
            pcall(function() fovm = GetProperty(PS, 'Field Of View Mode').value end)
            AGLog.Info('pave: %s: waiting for track, %.1f s, pod mode %s, acquisition mode %s, field of view mode %s, target %.1f deg %s the datum line', job.what or 'slew', now - (job.eng_t0 or now), tostring(mode), tostring(acq), tostring(fovm), math.abs(job.body_el or 0), (job.body_el or 0) > 0 and 'above' or 'below')
        end
        if job.cage_wait and not job.cage_entered then
            -- The pod is leaving track to the forward (caged) position; once it is out, enter track again.
            if mode ~= 1 then
                job.cage_entered = true
                trigger_half_action()
                AGLog.Info('pave: %s: pod caged (mode %s), entering track', job.what or 'slew', tostring(mode))
            elseif now - job.cage_wait > 3 then
                job.cage_entered = true
                AGLog.Info('pave: %s: the pod stayed in track after the cage trigger, slewing as it is', job.what or 'slew')
            end
            return
        end
        if mode == 1 then
            job.phase = 'slew'
            job.slew_t0 = now
            AGLog.Info('pave: %s: pod in track %.1f s after the trigger sequence', job.what or 'slew', now - (job.eng_t0 or now))
        elseif now > job.engage_by then
            AGLog.Info('pave: %s: no track after %.1f s, pod mode %s; %s', job.what or 'slew', now - (job.eng_t0 or now), tostring(mode), pod_state())
            if job.hold and (job.recover or 0) > 0 and job.recover < RECOVER_TRIES then
                job.recover = job.recover + 1
                job.engage_by = now + ENGAGE_TIMEOUT
                trigger_half_action()
                Dbg.Say(string.format('Pod Not In Track - Trying Again (%d/%d)', job.recover, RECOVER_TRIES))
                AGLog.Info('pave: pod still not in track, trying again (try %d of %d)', job.recover, RECOVER_TRIES)
            else
                self:Finish(false, 'pod would not enter track')
            end
        end
        return
    end

    if job.recover_t and now - job.recover_t > 20 then job.recover, job.recover_t = 0, nil end   -- steady again: a fresh set of tries
    if mode ~= 1 then
        -- Mode 2 is MEMORY: the pod itself lost the track (the target went behind terrain, say). A held target is picked up
        -- again: the stick goes to center, the track is entered again and the hold carries on once the pod is back in track. Mode 0
        -- (acquisition) is the pilot or a trigger press leaving track, so that still ends the job.
        -- With the automatic reacquire on (Oct 20 2026) this in-job re-entry is left out: it pressed the trigger as soon as the pod went to
        -- memory, with the aircraft still banked and the target outside the pod's limits, and the pod went to acquisition and wandered for
        -- 80 s. The job ends instead and PaveSearch goes back to the target when it has been inside the limits for 3 s.
        if job.hold and mode == 2 and Config.PAVE_AUTO_REACQUIRE == false and (job.recover or 0) < RECOVER_TRIES then
            job.recover = (job.recover or 0) + 1
            job.recover_t = now
            job.phase = 'engage'
            job.engage_by = now + ENGAGE_TIMEOUT
            place_stick(0, 0)
            self.stick.x, self.stick.y = 0, 0
            trigger_half_action()
            Dbg.Say(string.format('Pod Lost Track (Memory) - Re-entering Track (%d/%d)', job.recover, RECOVER_TRIES))
            AGLog.Info('pave: pod lost the track (memory), entering track again (try %d of %d)', job.recover, RECOVER_TRIES)
            return
        end
        -- A job that had to cage the pod forward first (target behind the aircraft) and lost the track within a few seconds of
        -- entering it again (seen Oct 19 2026 on both pods: 3.6 s in, "unable", the second try worked): enter track once more.
        if job.cage_wait and not job.cage_retry and mode == 0 and job.slew_t0 and now - job.slew_t0 < 8 and Config.PAVE_ENGAGE_RETRY ~= false then
            job.cage_retry = true
            job.cage_wait = nil
            job.phase = 'engage'
            job.engage_by = now + ENGAGE_TIMEOUT + 2
            job.eng_t0 = now
            place_stick(0, 0)
            self.stick.x, self.stick.y = 0, 0
            trigger_half_action(true)
            AGLog.Info('pave: %s: the pod left track %.1f s after entering it, entering track once more', job.what or 'slew', now - job.slew_t0)
            return
        end
        -- Oct 20 2026: four of nine look-theres ended "unable" with the pod dropping out of track mid-slew (pod drifting up into the sky
        -- or running away at the nose line). Try the track once more and carry on with the slew before giving up.
        if not job.hold and not job.slew_retry and (mode == 0 or mode == 2) and now - (job.slew_t0 or job.started) < 20 and Config.PAVE_SLEW_RETRY ~= false then
            job.slew_retry = true
            job.phase = 'engage'
            job.engage_by = now + ENGAGE_TIMEOUT + 2
            job.eng_t0 = now
            place_stick(0, 0)
            self.stick.x, self.stick.y = 0, 0
            trigger_half_action(true)
            AGLog.Info('pave: %s: the pod left track %.1f s into the slew (pod mode %s), entering track once more and carrying on', job.what or 'slew', now - (job.slew_t0 or job.started), tostring(mode))
            return
        end
        self:Finish(false, 'pod left track')
        return
    end

    local L, why = Pave.ReadLook()
    if not L then
        job.stale = (job.stale or 0) + 1
        if job.stale > 15 then self:Finish(false, tostring(why)) end   -- about 1.5 s without a usable file
        return
    end
    job.stale = 0
    local pod_az, pod_el = pod_angles()
    if not pod_az then self:Finish(false, 'pod direction unreadable') return end
    local hit = job.get()
    if not hit then self:Finish(false, 'target gone') return end
    if job.hold then
        -- Fixed aim offset for a hold only, in meters. Measured Oct 15 2026 on the T-90: the pod sat a few meters off the unit
        -- position, and the user finds the bias the same whichever way the aircraft approaches, so it is an aircraft-frame
        -- offset (the pod's own geometry), not a map offset. RIGHT is to the right of the aircraft's heading, AHEAD is along
        -- the heading; both turn with the aircraft. It uses the heading, not the line of sight, so it does not flip sides
        -- when the aircraft passes over the target. The map-fixed EAST and NORTH values are still there, default 0.
        if not job.base_done then
            job.base_done = true
            job.base_right = Config.PAVE_AIM_OFFSET_RIGHT or 0.8
            job.base_ahead = Config.PAVE_AIM_OFFSET_AHEAD or -2.0
            -- The regular Pave Spike (neither the Smart-Track nor the Fast-Track upgrade) has its own aim offset: PAVE_AIM_OFFSET_RIGHT_REGULAR
            -- and PAVE_AIM_OFFSET_AHEAD_REGULAR (meters). A key that is not set falls back to the normal one above.
            local function flag(name)
                local v
                pcall(function() v = GetProperty(PS, name).value end)
                return v == true or tostring(v) == 'true' or num(v) == 1
            end
            job.regular_pod = not (flag('Upgrade Smart-Track') or flag('Upgrade Fast-Track'))
            if job.regular_pod then
                if Config.PAVE_AIM_OFFSET_RIGHT_REGULAR ~= nil then job.base_right = Config.PAVE_AIM_OFFSET_RIGHT_REGULAR end
                if Config.PAVE_AIM_OFFSET_AHEAD_REGULAR ~= nil then job.base_ahead = Config.PAVE_AIM_OFFSET_AHEAD_REGULAR end
            end
        end
        local right = job.base_right
        local ahead = job.base_ahead
        local oe, on = Config.PAVE_AIM_OFFSET_E or 0, Config.PAVE_AIM_OFFSET_N or 0
        local hr = math.rad(L.self.heading or 0)
        local dn = ahead * math.cos(hr) - right * math.sin(hr) + on
        local de = ahead * math.sin(hr) + right * math.cos(hr) + oe
        hit = { x = hit.x + dn, y = hit.y, z = hit.z + de }
        if not job.offset_logged then
            job.offset_logged = true
            AGLog.Info('pave: hold aim offset (%s pod) %+.1f ft right, %+.1f ft ahead of the aircraft heading (%+.1f ft east, %+.1f ft north map-fixed); heading %.0f gives %+.1f ft north, %+.1f ft east in total', job.regular_pod and 'regular' or 'Smart/Fast-Track', right * 3.28084, ahead * 3.28084, oe * 3.28084, on * 3.28084, L.self.heading or 0, dn * 3.28084, de * 3.28084)
        end
    end
    local az, el = Pave.Direction(L.self, hit)
    local S = L.self
    local want_az, want_el = Pave.ToBody(az, el, S.heading, S.pitch, S.bank)
    want_el = want_el + (job.bias_el or 0)
    -- Two delays matter, and they are not the same size. The picture on the pod display follows Pod Camera Direction almost
    -- at once (a screen recording against the logged gimbal angles, four clean edges: within 0.01 s, so 0 to 0.03 s with the
    -- message delay). The aircraft position and attitude in the look file are old by the time they are read (0.09 to 0.11 s on
    -- average, 0.04 s spread). The old fixed 0.14 s lead was mostly that age, and the jitter in the age showed up as a fake
    -- error that the trim taps chased. The age-compensated lead below is the age of the sample plus the picture lag, so the
    -- pod is pointed where the target is now, and a little ahead of it, so the picture shows it centered.
    local att_h, att_p, att_b = S.heading, S.pitch, S.bank   -- aircraft attitude as of now (brought up to date below)
    local gdir   -- the wanted line of sight in the world, with the lead applied (north, east, up): for the ground-frame trim below
    if Config.PAVE_HOLD_WORLD_LEAD == false then
        -- The lead is done on the direction as a vector, not on azimuth and elevation: steeply down, azimuth swings tens of
        -- degrees a second while the picture barely moves, and a lead worked out in azimuth was clamped well short of what
        -- was needed there (a recorded pass: sideways error to 24 m at the overhead, along-track dip 20 m).
        local ra_, re_ = math.rad(want_az), math.rad(want_el)
        local vx, vy, vz = math.cos(re_) * math.cos(ra_), math.cos(re_) * math.sin(ra_), math.sin(re_)
        local lw_t = job.lw_t
        if lw_t and now - lw_t >= 0.08 then
            local dt2 = now - lw_t
            local rx, ry, rz = (vx - job.lw_x) / dt2, (vy - job.lw_y) / dt2, (vz - job.lw_z) / dt2
            job.rate_x = job.rate_x and (job.rate_x * 0.5 + rx * 0.5) or rx
            job.rate_y = job.rate_y and (job.rate_y * 0.5 + ry * 0.5) or ry
            job.rate_z = job.rate_z and (job.rate_z * 0.5 + rz * 0.5) or rz
            job.lw_t, job.lw_x, job.lw_y, job.lw_z = now, vx, vy, vz
        elseif not lw_t then
            job.lw_t, job.lw_x, job.lw_y, job.lw_z = now, vx, vy, vz
        end
        -- Measured on a player-flown pass: the picture runs about 0.115 s behind on the way in and about 0.165 s behind once
        -- the pod looks back past the wing line (0.20 used: the picture still sat short on the far side), so the lead grows from one to the other between 60 and 120 deg of azimuth.
        local pb_az = Pave.ToBody(pod_az, pod_el, S.heading, S.pitch, S.bank)
        local back = clamp((math.abs(pb_az) - 60) / 60, 0, 1)
        local lead = Config.PAVE_HOLD_LEAD_S or (0.14 + 0.0 * back)
        local ox, oy, oz = (job.rate_x or 0) * lead, (job.rate_y or 0) * lead, (job.rate_z or 0) * lead
        local om = math.sqrt(ox * ox + oy * oy + oz * oz)
        if om > 0.035 then ox, oy, oz = ox * 0.035 / om, oy * 0.035 / om, oz * 0.035 / om end   -- 2 degrees at most
        local lx, ly, lz = vx + ox, vy + oy, vz + oz
        local lm = math.sqrt(lx * lx + ly * ly + lz * lz)
        if lm > 1e-6 then
            want_az = math.deg(math.atan2(ly, lx))
            want_el = math.deg(math.asin(clamp(lz / lm, -1, 1)))
        end
    else
        -- World-frame lead. The old lead differenced the aircraft-frame vector, which carried the jitter of the 10 Hz attitude
        -- samples into the lead (recorded passes: tick-to-tick jitter of the wanted direction about 30% lower with this, same
        -- mean, so the 0.14 s calibration holds). The line-of-sight rate is taken in the world frame, per look-file sample (not
        -- per tick, so a repeated sample cannot halve it), and the aircraft's own smoothed turn rate over the lead is applied
        -- when the result is put into the aircraft frame.
        local ra_, re_ = math.rad(az), math.rad(el)
        local wx, wy, wz = math.cos(re_) * math.cos(ra_), math.cos(re_) * math.sin(ra_), math.sin(re_)
        local vt = L.view_t
        if job.lw_vt and vt < job.lw_vt - 0.5 then job.lw_vt = nil end   -- model time went backwards: start over
        if job.lw_vt and vt - job.lw_vt > 0.02 then
            local dt2 = vt - job.lw_vt
            local rx, ry, rz = (wx - job.lw_x) / dt2, (wy - job.lw_y) / dt2, (wz - job.lw_z) / dt2
            job.rate_x = job.rate_x and (job.rate_x * 0.5 + rx * 0.5) or rx
            job.rate_y = job.rate_y and (job.rate_y * 0.5 + ry * 0.5) or ry
            job.rate_z = job.rate_z and (job.rate_z * 0.5 + rz * 0.5) or rz
            local rh = clamp(wrap180(S.heading - job.lw_h) / dt2, -30, 30)
            local rp = clamp((S.pitch - job.lw_p) / dt2, -30, 30)
            local rb = clamp(wrap180(S.bank - job.lw_b) / dt2, -30, 30)
            job.att_h = (job.att_h or 0) * 0.8 + rh * 0.2
            job.att_p = (job.att_p or 0) * 0.8 + rp * 0.2
            job.att_b = (job.att_b or 0) * 0.8 + rb * 0.2
            job.lw_vt, job.lw_x, job.lw_y, job.lw_z, job.lw_h, job.lw_p, job.lw_b = vt, wx, wy, wz, S.heading, S.pitch, S.bank
        elseif not job.lw_vt then
            job.lw_vt, job.lw_x, job.lw_y, job.lw_z, job.lw_h, job.lw_p, job.lw_b = vt, wx, wy, wz, S.heading, S.pitch, S.bank
        end
        local age = 0
        local lead = Config.PAVE_HOLD_LEAD_S or 0.14
        if Config.PAVE_HOLD_AGE_LEAD ~= false then
            age = clamp(L.age or 0, 0, 0.3)
            lead = age + (Config.PAVE_PICTURE_LAG_S or 0.02)
            att_h = S.heading + clamp((job.att_h or 0) * age, -1, 1)
            att_p = S.pitch + clamp((job.att_p or 0) * age, -1, 1)
            att_b = S.bank + clamp((job.att_b or 0) * age, -1, 1)
        end
        local ox, oy, oz = (job.rate_x or 0) * lead, (job.rate_y or 0) * lead, (job.rate_z or 0) * lead
        local om = math.sqrt(ox * ox + oy * oy + oz * oz)
        if om > 0.035 then ox, oy, oz = ox * 0.035 / om, oy * 0.035 / om, oz * 0.035 / om end   -- 2 degrees at most
        local lx, ly, lz = wx + ox, wy + oy, wz + oz
        local lm = math.sqrt(lx * lx + ly * ly + lz * lz)
        if lm > 1e-6 then
            gdir = { lx / lm, ly / lm, lz / lm }
            local waz = math.deg(math.atan2(ly, lx)) % 360
            local wel = math.deg(math.asin(clamp(lz / lm, -1, 1)))
            local dl = lead - age   -- the part of the lead that is ahead of now
            local ah = clamp((job.att_h or 0) * dl, -0.5, 0.5)
            local ap = clamp((job.att_p or 0) * dl, -0.5, 0.5)
            local ab = clamp((job.att_b or 0) * dl, -0.5, 0.5)
            want_az, want_el = Pave.ToBody(waz, wel, att_h + ah, att_p + ap, att_b + ab)
            want_el = want_el + (job.bias_el or 0)
        end
        if not job.lead_logged then
            job.lead_logged = true
            AGLog.Info('pave: hold lead: world-frame, %s, with aircraft turn-rate lead (first sample age %.3f s)', Config.PAVE_HOLD_AGE_LEAD ~= false and string.format('age-compensated, age + %.2f s', Config.PAVE_PICTURE_LAG_S or 0.02) or string.format('fixed %.2f s', lead), L.age or 0)
        end
    end
    -- A held target takes the lead above instead of the designation offset, which was mostly that lead.
    if not job.hold then
        if job.off_az then want_az = want_az + job.off_az end
        if job.off_el then want_el = want_el + job.off_el end
    end
    local have_az, have_el = Pave.ToBody(pod_az, pod_el, att_h, att_p, att_b)
    -- Blind zone behind the tail (Oct 20 2026): all 11 'pod left track' events in the stored pavesig history happened with the pod within about 4 deg
    -- of straight aft (azimuth 176 to 180) and no more than about 5 deg below the horizon. Pods looking there lose track (about 1 s gap) and then
    -- dive 8 to 12 deg, which was the bouncing. A point wanted inside that zone is looked at from its edge: azimuth held at
    -- Config.PAVE_TAIL_AZ_DEG (175) on the side the pod is on. PAVE_TAIL_MASK = false turns it off.
    if Config.PAVE_TAIL_MASK ~= false and not job.hold then
        local tz, te = tail_zone()   -- hand sweep Oct 20 2026: the pod drops to acquisition mode at |az| >= 176 and el up to about -5.2 (aircraft frame); margin added
        if tz < 180 and math.abs(want_az) > tz and want_el > te then
            if not job.tail_side then job.tail_side = (math.abs(have_az) > 90 and have_az ~= 0) and (have_az >= 0 and 1 or -1) or (want_az >= 0 and 1 or -1) end
            local before = want_az
            if job.what == 'look there' and Config.PAVE_TAIL_WAIT ~= false and not job.continuous then
                lt_wait = { hit = hit, t0 = now, tries = job.lt_tries or 0 }
                AGLog.Info('pave: look there: the point is %.0f deg off the nose, %.1f deg below the horizon: inside the pod blind zone behind the tail (the pod drops track there). Stopping the chase, the pod stays where it is, the point is reacquired once it has been clear of the zone for %.1f s (try %d)', before, -want_el, Config.PAVE_TAIL_CONFIRM_S or 2, lt_wait.tries + 1)
                Dbg.Notice('Look There - Point Behind The Tail, Will Reacquire When Clear', 5)
                job.quiet = true
                self:Finish(true, 'point in the pod blind zone behind the tail, waiting to reacquire')
                return
            end
            want_az = job.tail_side * tz
            if not job.tail_logged then
                job.tail_logged = true
                AGLog.Info('pave: %s: the point is %.0f deg off the nose, %.1f deg below the horizon: inside the pod blind zone behind the tail (it loses track there), looking at the nearest visible point %.0f deg off the nose', job.what or 'slew', before, -want_el, want_az)
            end
        end
    end
    local az_err, el_err = wrap180(want_az - have_az), want_el - have_el
    -- The pilot is manoeuvring (Oct 20 2026: pitch -6 to +6 deg in 15 s, the target swung against the pod, 'no progress for 12 s' ended the slew):
    -- the no-progress clock does not run while the aircraft pitches or rolls, only the hard limit applies.
    if math.abs(job.att_p or 0) > (Config.PAVE_MAN_PITCH_RATE or 1) or math.abs(job.att_b or 0) > (Config.PAVE_MAN_BANK_RATE or 3) then job.progress_t = now end
    do
        local e = math.sqrt(az_err * az_err + el_err * el_err)
        if not job.best_err or e < job.best_err - 1 then job.best_err, job.progress_t = e, now
        -- The target ran away from a pod that was on it (the aircraft flew over a close target, error 0 to 20 deg in two seconds, Oct 20
        -- 2026): the old best could never be beaten again and the slew timed out 12 s later while the pod was catching up. The baseline
        -- moves up with the error; progress is credited when the error then falls 1 deg below it.
        elseif e > job.best_err + 5 then job.best_err = e end
    end
    -- A hold slew that starts with the pod looking far aft (the pod swung round while a hold was lost, say): driving the stick the
    -- long way round stalls at the 90 deg point, where the stick axes reverse (seen Oct 19 2026: the pod sat at -90 with the stick
    -- flipping each tick). Cage the pod forward first, enter track again and slew from there, as a slew from the caged pod does.
    if job.hold and job.phase == 'slew' and not job.cage_tried and Config.PAVE_AFT_CAGE ~= false
        and not (job.aft_ground and Config.PAVE_AFT_GROUND ~= false and Config.PAVE_GROUND_STEER ~= false and not job.gs_shallow)
        and math.abs(have_az) > (Config.PAVE_AFT_CAGE_DEG or 100)
        and math.abs(az_err) > (Config.PAVE_AFT_CAGE_ERR_DEG or 30)
        and (dist3(S, hit) < 1 or (S.y - hit.y) / dist3(S, hit) < 0.82) then
        -- Not while the pod is on the target (small error) or steeply down: at the overhead the pod swings through 180 deg of azimuth
        -- by itself (Oct 20 2026, regular pod: caged at 86.6 deg look angle with the pod 2 deg off the unit, track lost, hold gone).
        job.cage_tried = true
        job.phase = 'engage'
        job.engage_by = now + ENGAGE_TIMEOUT + 4
        job.eng_t0 = now
        job.cage_wait, job.cage_entered = now, false
        place_stick(0, 0)
        self.stick.x, self.stick.y = 0, 0
        trigger_half_action(true)
        Dbg.Say('Pod Looking Aft - Caging It Forward First')
        AGLog.Info('pave: %s: pod looks %.0f deg aft, caging it forward before the slew', job.what or 'slew', have_az)
        return
    end
    -- A target about half a turn from where the pod looks makes the wrapped error jump between +180 and -180 with the slightest
    -- noise, and the stick then flips from one end to the other every tick and the pod goes nowhere (seen Oct 15 2026: 15 s of
    -- full stick back and forth, 178 deg off). Past 150 deg the direction is kept: the side the error had when it got there.
    if math.abs(az_err) > 150 then
        job.az_lat = job.az_lat or (az_err >= 0 and 1 or -1)
        az_err = job.az_lat * math.abs(az_err)
    else
        job.az_lat = nil
    end
    -- The pod keeps moving for about half a second after the stick changes, so steer on where it will be, not where it is.
    local dt = now - (job.last_t or now)
    local vaz, vel = 0, 0
    if job.last_az and dt > 0.02 then
        vaz, vel = wrap180(have_az - job.last_az) / dt, (have_el - job.last_el) / dt
        job.vaz = (job.vaz or 0) * 0.6 + vaz * 0.4
        job.vel = (job.vel or 0) * 0.6 + vel * 0.4
    end
    job.last_t, job.last_az, job.last_el = now, have_az, have_el
    -- Low route for a target up near the datum line (Oct 20 2026, the hill target: 53 to 56 s, stick 0.30 from azimuth 15 to 100 because the pod
    -- was in the upper-side zone the whole way, and it dropped track twice anyway). Far round in azimuth the wanted elevation is replaced by one
    -- below the zone (upper limit less its taper less half a degree, -4 deg), blended in over 10 deg of azimuth error beyond Config.PAVE_LOW_ROUTE_AZ
    -- (25), so the swing runs at full stick outside the zone and the elevation climbs into it only for the last 25 deg. Look there, regular pod.
    -- Config.PAVE_LOW_ROUTE = false turns it off.
    if job.what == 'look there' and regular_pod() and Config.PAVE_LOW_ROUTE ~= false and (Config.PAVE_ZONE_CAP or 0.3) < 1 then
        local low_el = (Config.PAVE_ZONE_UPPER_EL or -1.5) - (Config.PAVE_ZONE_UPPER_TAPER_DEG or 2) - 0.5
        if want_el > low_el then
            local lo_az = Config.PAVE_LOW_ROUTE_AZ or 25
            local b = clamp((math.abs(az_err) - lo_az) / 10, 0, 1)
            if b > 0 then
                local we = want_el + (low_el - want_el) * b
                if not job.low_route_logged then
                    job.low_route_logged = true
                    AGLog.Info('pave: look there: target at %+.1f deg, %.0f deg round: swinging round at %.1f deg (below the upper-side zone), then up', want_el, math.abs(az_err), low_el)
                end
                el_err = el_err + (we - want_el)
                want_el = we
            end
        end
    end
    -- Settling is judged on how fast the error is changing, not how fast the pod is moving: when the aircraft flies past the
    -- target the pod has to keep turning just to stay on it.
    if job.last_eaz and dt > 0.02 then
        job.veaz = (job.veaz or 0) * 0.6 + (wrap180(az_err - job.last_eaz) / dt) * 0.4
        job.veel = (job.veel or 0) * 0.6 + ((el_err - job.last_eel) / dt) * 0.4
    end
    job.last_eaz, job.last_eel = az_err, el_err
    local speed = math.sqrt((job.veaz or 0) ^ 2 + (job.veel or 0) ^ 2)
    -- How fast the wanted direction itself is moving in the aircraft frame (the aircraft flying past the target).
    if job.last_waz and dt > 0.02 then
        job.wvaz = (job.wvaz or 0) * 0.9 + (wrap180(want_az - job.last_waz) / dt) * 0.1
        job.wvel = (job.wvel or 0) * 0.9 + ((want_el - job.last_wel) / dt) * 0.1
    end
    job.last_waz, job.last_wel = want_az, want_el
    local wvaz, wvel = job.wvaz or 0, job.wvel or 0
    -- Ignore small apparent motion: it is mostly jitter in the aircraft attitude.
    if math.abs(wvaz) < 0.6 then wvaz = 0 end
    if math.abs(wvel) < 0.6 then wvel = 0 end
    -- The pod cannot turn faster than its stick rate, so the wanted direction's own rate is no use beyond that. Steeply down (a
    -- search started with the aircraft over the top of the point, pod 70 to 80 deg down) the wanted azimuth sweeps tens of deg/s,
    -- the feed forward and lead terms below swamp the error and the stick flips end to end (seen Oct 19 2026). Capped at the
    -- pod's rate (Config.PAVE_FEED_MAX_DEG_S, default the slew rate).
    do
        local fmax = Config.PAVE_FEED_MAX_DEG_S or Config.PAVE_SLEW_RATE_DEG or 6.5
        wvaz, wvel = clamp(wvaz, -fmax, fmax), clamp(wvel, -fmax, fmax)
    end
    local zoom_far = false
    if job.zoom_slew then zoom_far = zoom_step(job, now, S, hit, az_err, el_err, have_el) end
    -- Ground-frame steering (Oct 19 2026, for the search sweep). Measured from two hand-flown spirals through the overhead: the stick moves the
    -- pod's tracked ground point at a rate set by the picture's size on the ground, in the AIRCRAFT-HEADING frame (stick right = right of
    -- the heading, stick forward = along it), whatever the pod azimuth. Sideways: ground speed = KR * fov * slant * stick (KR about 0.8,
    -- 0.73 to 0.88); along the heading the rate is KF * fov * slant / sin(elevation) (KF about 0.72, higher up at low look angles). The pod
    -- holds the point itself, so the aircraft's motion does not matter, and unlike the azimuth/elevation gimbal angles nothing goes singular
    -- straight down. So the search steers the ground error (waypoint minus where the line of sight meets the ground), rotated into the
    -- heading frame, with the waypoint's own ground velocity fed forward. Config.PAVE_GROUND_STEER = false falls back to the gimbal loop;
    -- PAVE_GROUND_KR / _KF / _TAU (0.7 s closing time) tune it.
    -- Slews to a spot behind the aircraft (go to a target, look there) use the same ground-frame steering for the long part of the move,
    -- so the pod is not caged forward first (Oct 19 2026): the stick moves the tracked point in the aircraft-heading frame whichever
    -- way the pod looks, so there is no stick reversal at 90 deg azimuth to get through. Once the point is within a picture width of the
    -- target the usual loops take over. Config.PAVE_AFT_GROUND = false returns to the cage-and-slew.
    -- Not for a shallow look angle (Oct 20 2026, 22 NM out at about 4 deg: the ground error flipped by +/-90,000 ft, the stick sawed
    -- between +1 and -1 for 20 s). There the point where the line of sight meets the ground is hypersensitive (a 0.3 deg wobble in the pod
    -- angle moves it by 0.3/sin(look angle) times the range), and a sideways stick hardly changes the elevation. The look angle of the
    -- waypoint itself is steady, so it decides: below Config.PAVE_GROUND_MIN_SIN (0.09, about 5 deg) the gimbal loop does the job, and the
    -- ground steering is taken up again above PAVE_GROUND_MIN_SIN + 0.03.
    do
        local sw = (S.y - hit.y) / math.max(dist3(S, hit), 1)
        local lo = Config.PAVE_GROUND_MIN_SIN or 0.09
        -- Not while an aft chase is under way and the pod's own line of sight is still steep (Oct 20 2026: the target behind the aircraft had a
        -- look angle of 5 deg, the pod was at 22 deg and 18 deg short, and the hand-over to the pod-angle loop stalled there).
        local pod_steep = false
        if job.gs_on then
            pcall(function()
                local pp = GetProperty(PS, 'Pod Camera Direction')
                pod_steep = (-num(pp.z)) < -(Config.PAVE_GROUND_KEEP_SIN or 0.14)
            end)
        end
        if sw < lo and not pod_steep then
            if not job.gs_shallow then
                job.gs_shallow = true
                AGLog.Info('pave: %s: look angle %.1f deg to the target is too shallow for ground steering (needs %.1f), using the pod-angle loop', job.what or 'slew', math.deg(math.asin(clamp(sw, -1, 1))), math.deg(math.asin(lo)))
            end
        elseif sw > lo + 0.03 then
            job.gs_shallow = false
        end
    end
    local gs_use = job.ground and Config.PAVE_GROUND_STEER ~= false and not job.gs_shallow
    local gs_aft = (not job.ground) and job.aft_ground and Config.PAVE_AFT_GROUND ~= false and Config.PAVE_GROUND_STEER ~= false and not job.gs_done and not job.gs_shallow
    if gs_use or gs_aft then
        local gx, gy, gz
        pcall(function()
            local p = GetProperty(PS, 'Pod Camera Direction')
            local dn, de, dd = num(p.x), num(p.y), num(p.z)
            local dy = -dd
            if dy < -0.01 then
                local t = (hit.y - S.y) / dy
                if t > 0 and t < 90000 then gx, gy, gz = S.x + dn * t, hit.y, S.z + de * t end
            end
            if not gx then
                local q = GetProperty(PS, 'Pod Target (Track)')
                gx, gy, gz = S.x + num(q.x), S.y - num(q.z), S.z + num(q.y)
            end
        end)
        if gx then
            local hr = math.rad(S.heading or 0)
            local ch, sh = math.cos(hr), math.sin(hr)
            local ex, ez = hit.x - gx, hit.z - gz
            local ef, er = ex * ch + ez * sh, -ex * sh + ez * ch      -- ahead / right of the aircraft heading
            -- The waypoint's own ground velocity (smoothed, capped): fed forward so the picture keeps up with a moving spiral.
            local wvx, wvz = job.gw_vx or 0, job.gw_vz or 0
            if job.gw_t and now - job.gw_t > 0.02 then
                local gdt = now - job.gw_t
                local rx, rz = (hit.x - job.gw_x) / gdt, (hit.z - job.gw_z) / gdt
                local rm = math.sqrt(rx * rx + rz * rz)
                if rm > 300 then rx, rz = rx * 300 / rm, rz * 300 / rm end
                wvx, wvz = wvx + (rx - wvx) * 0.4, wvz + (rz - wvz) * 0.4
                job.gw_vx, job.gw_vz = wvx, wvz
            end
            job.gw_t, job.gw_x, job.gw_z = now, hit.x, hit.z
            local wvf, wvr = wvx * ch + wvz * sh, -wvx * sh + wvz * ch
            local fovg = 0.07
            pcall(function() fovg = num(GetProperty(PS .. '/Pave Spike (Local)', 'Field Of View').value) or fovg end)
            local sdx, sdy, sdz = gx - S.x, gy - S.y, gz - S.z
            local gslant = math.max(math.sqrt(sdx * sdx + sdy * sdy + sdz * sdz), 500)
            local sinel = clamp((S.y - gy) / gslant, 0.2, 1)
            local Wg = math.max(fovg * gslant, 50)
            local steer = true
            if gs_aft then
                local ed = math.sqrt(ex * ex + ez * ez)
                if not job.gs_on then
                    if (math.abs(want_az) > 100 or math.abs(have_az) > 100) and ed > 2.5 * Wg then
                        job.gs_on = true
                        AGLog.Info('pave: %s: target is behind (pod %.0f, target %.0f deg off the nose), %.1f NM from the pod ground point: steering the ground point, no cage', job.what or 'slew', have_az, want_az, ed / 1852)
                    end
                elseif ed < 1.0 * Wg then
                    job.gs_on, job.gs_done = false, true
                    AGLog.Info('pave: %s: ground point within %.0f ft of the target, the normal loop takes over', job.what or 'slew', ed * 3.28084)
                end
                steer = job.gs_on and true or false
            end
            if steer then
            local KR, KF, PX, TAU = Config.PAVE_GROUND_KR or 0.8, Config.PAVE_GROUND_KF or 0.72, Config.PAVE_GROUND_P or 1.0, Config.PAVE_GROUND_TAU or 0.7
            local up = (ef / TAU + wvf) * (sinel ^ PX) / (KF * Wg)
            local sx = (er / TAU + wvr) / (KR * Wg)
            local m = math.max(math.abs(up), math.abs(sx), 1)
            up, sx = up / m, sx / m
            -- Direction check for the along-heading stick (Oct 20 2026, overflight look-theres). With the pod looking aft the ground error
            -- GREW from 1,650 to 7,400 ft at full "ahead -1.00" while the pod data showed the tracked point riding along with the aircraft
            -- (700 ft/s) for as long as the elevation stick was held: from the side and behind the elevation stick does not move the point along
            -- the heading the way it does looking ahead. If the error has grown by half a picture width over 2.5 s with the stick at
            -- full deflection, the along-heading stick is turned round, and back again if it then grows again.
            if job.what == 'look there' and Config.PAVE_GROUND_FLIP ~= false then
                local ed2 = math.sqrt(ef * ef + er * er)
                local g = job.gflip
                if not g then g = { t = now, ed = ed2, k = 1 }; job.gflip = g end
                if math.max(math.abs(up), math.abs(sx)) < 0.95 then
                    g.t, g.ed = now, ed2
                elseif now - g.t >= 2.5 then
                    if ed2 > g.ed + 0.5 * Wg then
                        g.k = -g.k
                        AGLog.Info('pave: %s: ground error grew %.0f ft in %.1f s at full stick, along-heading stick turned %s', job.what, (ed2 - g.ed) * 3.28084, now - g.t, g.k < 0 and 'round' or 'back')
                    end
                    g.t, g.ed = now, ed2
                end
                up = up * g.k
            end
            job.settled = 0
            self:SetStick(sx, -up)
            if now - self.progress_log >= 2 then
                self.progress_log = now
                AGLog.Detail('pave: ground steer: error %+.0f ft ahead / %+.0f ft right of the heading, stick right %+.2f ahead %+.2f, picture %.0f ft wide, look angle %.0f deg, waypoint speed %.0f kt',
                    ef * 3.28084, er * 3.28084, sx, up, Wg * 3.28084, math.deg(math.asin(sinel)), math.sqrt(wvx * wvx + wvz * wvz) * 1.94384)
            end
            return
            end
        end
    end
    -- Ground-frame trim for a hold steeply down (Oct 20 2026). Above about 55 deg look angle the azimuth/elevation trim below goes
    -- singular (azimuth swings tens of degrees a second, the stick axes turn with it), so it needed a smoothing filter, a steeper-approach
    -- boost, a hands-off zone at the overhead and another round azimuth 90. The stick moves the tracked ground point in the AIRCRAFT-HEADING
    -- frame whatever the pod azimuth (flown for the search and the aft slews), so here the error is measured on the ground instead: where
    -- the wanted line of sight (the same lead-corrected one as below) and where the pod's line of sight meet the ground plane at the target's
    -- height, both from the same point so the age of the aircraft sample drops out. That distance, rotated into the heading frame, goes to
    -- the stick as a small proportional tap (cap 0.1, closing time 1.2 s, smoothed). No stick rotation, no hands-off zone, nothing singular.
    -- _TAU, _CAP, _DB_FT, _SMOOTH, _ON / _OFF (look angle sine, 0.82 / 0.78) tune it.
    if job.hold then
        -- On target (Oct 22 2026): the pod is in track and the error has stayed inside PAVE_CAPTURED_DEG (0.6) for PAVE_CAPTURED_S (0.5) s. A hold
        -- never finishes, so this is what tells Jester the hold is established ("captured" for a hold from the menu or the list).
        if not job.on_target and op_mode() == 1 then
            if math.abs(az_err) <= (Config.PAVE_CAPTURED_DEG or 0.6) and math.abs(el_err) <= (Config.PAVE_CAPTURED_DEG or 0.6) then
                job.on_target_t = job.on_target_t or now
                if now - job.on_target_t >= (Config.PAVE_CAPTURED_S or 0.5) then job.on_target = true end
            else
                job.on_target_t = nil
            end
        end
    end
    if job.hold and not zoom_far and gdir and Config.PAVE_GROUND_STEER ~= false then
        local sl1 = dist3(S, hit)
        local gr1 = sl1 > 1 and ((S.y - hit.y) / sl1) or 0
        local on_th = job.gtrim and (Config.PAVE_HOLD_GROUND_OFF or 0.78) or (Config.PAVE_HOLD_GROUND_ON or 0.82)
        if gr1 > on_th then
            local px, pz, wx2, wz2
            pcall(function()
                local p = GetProperty(PS, 'Pod Camera Direction')
                local dn, de, dd = num(p.x), num(p.y), num(p.z)
                local dy = -dd
                local ty = hit.y - S.y
                if dy < -0.01 and gdir[3] < -0.01 then
                    local t1, t2 = ty / dy, ty / gdir[3]
                    if t1 > 0 and t1 < 90000 and t2 > 0 and t2 < 90000 then
                        px, pz = dn * t1, de * t1
                        wx2, wz2 = gdir[1] * t2, gdir[2] * t2
                    end
                end
            end)
            if px then
                local hr = math.rad(S.heading or 0)
                local ch, sh = math.cos(hr), math.sin(hr)
                local ex, ez = wx2 - px, wz2 - pz
                local ef, er = ex * ch + ez * sh, -ex * sh + ez * ch      -- ahead / right of the aircraft heading
                local fov0 = 0.07
                pcall(function() fov0 = num(GetProperty(PS .. '/Pave Spike (Local)', 'Field Of View').value) or fov0 end)
                local Wg0 = math.max(fov0 * math.max(sl1, 500), 50)
                if math.sqrt(ef * ef + er * er) > (Config.PAVE_HOLD_GROUND_MAX_PICS or 4) * Wg0 then
                    -- The pod is nowhere near the target (the track was lost or the pod was caged): not a trim job, and a stick sized to a
                    -- 30 mile error is nonsense (Oct 20 2026: -194,000 ft ahead, stick pinned at the cap). Leave it to the loop below.
                    if job.gtrim then
                        job.gtrim = nil
                        job.g_ef, job.g_er = nil, nil
                        AGLog.Info('pave: hold: ground error %.0f ft is more than %d picture widths, the pod is not on the target: ground-frame trim off', math.sqrt(ef * ef + er * er) * 3.28084, Config.PAVE_HOLD_GROUND_MAX_PICS or 4)
                    end
                    px = nil
                end
            end
            if px then
                local hr = math.rad(S.heading or 0)
                local ch, sh = math.cos(hr), math.sin(hr)
                local ex, ez = wx2 - px, wz2 - pz
                local ef, er = ex * ch + ez * sh, -ex * sh + ez * ch
                local k = Config.PAVE_HOLD_GROUND_SMOOTH or 0.55
                job.g_ef = job.g_ef and (job.g_ef + k * (ef - job.g_ef)) or ef
                job.g_er = job.g_er and (job.g_er + k * (er - job.g_er)) or er
                local fovg = 0.07
                pcall(function() fovg = num(GetProperty(PS .. '/Pave Spike (Local)', 'Field Of View').value) or fovg end)
                local gslant = math.max(sl1, 500)
                local sinel = clamp(gr1, 0.2, 1)
                local Wg = math.max(fovg * gslant, 50)
                local KR, KF = Config.PAVE_GROUND_KR or 0.8, Config.PAVE_GROUND_KF or 0.72
                local TAU = Config.PAVE_HOLD_GROUND_TAU or 1.2
                local cap = Config.PAVE_HOLD_GROUND_CAP or 0.1
                local db = (Config.PAVE_HOLD_GROUND_DB_FT or 6) / 3.28084
                local fe, fr = job.g_ef, job.g_er
                local up = (math.abs(fe) > db) and (fe / TAU) * sinel / (KF * Wg) or 0
                local sx = (math.abs(fr) > db) and (fr / TAU) / (KR * Wg) or 0
                up, sx = clamp(up, -cap, cap), clamp(sx, -cap, cap)
                if not job.gtrim then
                    job.gtrim = true
                    AGLog.Info('pave: hold: ground-frame trim on (look angle %.0f deg, error %+.0f ft ahead / %+.0f ft right of the heading, picture %.0f ft wide)', math.deg(math.asin(clamp(gr1, -1, 1))), ef * 3.28084, er * 3.28084, Wg * 3.28084)
                end
                self:SetStick(sx, -up)
                if now - (job.gtrim_log or -10) >= 2 then
                    job.gtrim_log = now
                    AGLog.Detail('pave: hold ground trim: error %+.0f ft ahead / %+.0f ft right of the heading, stick right %+.3f ahead %+.3f, picture %.0f ft wide, look angle %.0f deg, pod azimuth %.0f',
                        fe * 3.28084, fr * 3.28084, sx, up, Wg * 3.28084, math.deg(math.asin(clamp(gr1, -1, 1))), have_az)
                end
                return
            end
        elseif job.gtrim then
            job.gtrim = nil
            job.g_ef, job.g_er = nil, nil
            AGLog.Info('pave: hold: ground-frame trim off (look angle %.0f deg), the pod-angle trim again', math.deg(math.asin(clamp(gr1, -1, 1))))
        end
    end
    if job.hold and not zoom_far then
        -- The pod stabilizes itself on its tracked point and follows the target through the whole approach and pass on its own
        -- (a recorded pass flown by hand: error 0.07 deg rms inside 30 deg look angle, 1.5 deg at the worst, and the hand
        -- on the stick was tiny taps: median 0.012, never above 0.05, one 0.2 s tap at a time). So this only trims:
        -- a dead band, a small proportional tap capped at the size a hand uses, no integral, no lead.
        local TAP_GAIN, TAP_MAX, DB = 0.15, 0.05, 0.04
        local hx, hy = 0, 0
        -- Steeply down the sideways error is measured through azimuth, which swings fast there, and the pod and aircraft
        -- samples are a fraction of a second apart, so the azimuth error jumps by up to a degree from one reading to the
        -- next while the picture error is a tenth of that (a recorded pass: stick flipping between -0.25 and +0.25 in the last
        -- 20 degrees before the pass). Above about 55 deg look angle, steer on a smoothed error (about 0.25 s).
        local sl0 = dist3(S, hit)
        local graze0 = sl0 > 1 and ((S.y - hit.y) / sl0) or 0
        local f_az, f_el = az_err, el_err
        if graze0 > 0.82 then
            -- Oct 19 2026: the azimuth/elevation error here alternates +/-0.1 to 0.2 deg from one sample to the next (pod and aircraft
            -- samples a fraction of a second apart) with the real mean near zero or a few hundredths; at 0.35 the smoothed value
            -- still swung +/-0.05 and the stick chattered +/-0.06 around a steady lateral error that was never taken out (45 ft at the
            -- pass). A slower filter shows the mean. Config.PAVE_HOLD_STEEP_SMOOTH, flown Oct 18: 0.25 oscillated, 0.55 is good (0.35 = the old filter).
            local k = (Config.PAVE_HOLD_STEEP_BOOST ~= false) and (Config.PAVE_HOLD_STEEP_SMOOTH or 0.55) or 0.35
            job.f_az = job.f_az and (job.f_az + k * (az_err - job.f_az)) or az_err
            job.f_el = job.f_el and (job.f_el + k * (el_err - job.f_el)) or el_err
            f_az, f_el = job.f_az, job.f_el
        else
            job.f_az, job.f_el = nil, nil
        end
        -- Steeply down, azimuth moves the picture only by cos(elevation) of what it moves at the horizon, so the same
        -- sideways error needs a bigger azimuth error to show, and a bigger stick to remove (a recorded pass: sideways error
        -- grew from 0.03 to 0.35 deg between 55 and 80 deg look angle while hands-off). Scale the azimuth dead band and cap
        -- by 1/cos(elevation) so the correction in the picture stays the size of a normal tap.
        -- Ground spot (Oct 20 2026 flight, pavesig): the pod follows a ground point by itself (error 0.02 deg with the stick at 0) but the pod and
        -- aircraft samples alternate 0.4 s apart, so the measured azimuth error alternates 0 / -0.35 deg every sample, and the fast trim answered each
        -- reading with the stick at +/-0.4 (a 0.8 s limit cycle that drew circles on the picture). A vehicle never shows this: the pod's image track
        -- sits on it and the error stays inside the dead band. Here the error is averaged (0.25 per sample, two samples cancel the alternation) and
        -- left alone inside Config.PAVE_SPOT_DB_DEG (0.5), so only a real drift gets a stick. PAVE_SPOT_FILTER = false returns to the old trim.
        if job.what == 'hold ground spot' and graze0 <= 0.82 and Config.PAVE_SPOT_FILTER ~= false then
            local k = Config.PAVE_SPOT_SMOOTH or 0.25
            job.sp_az = job.sp_az and (job.sp_az + k * (f_az - job.sp_az)) or f_az
            job.sp_el = job.sp_el and (job.sp_el + k * (f_el - job.sp_el)) or f_el
            local sdb = Config.PAVE_SPOT_DB_DEG or 0.5
            f_az = math.abs(job.sp_az) > sdb and job.sp_az or 0
            f_el = math.abs(job.sp_el) > sdb and job.sp_el or 0
        else
            job.sp_az, job.sp_el = nil, nil
        end
        local cel = math.max(math.cos(math.rad(have_el)), 0.2)
        local mx = math.min((math.abs(f_az) > 0.4 and 0.08 or TAP_MAX) / cel, 0.08)
        local my = math.abs(f_el) > 0.4 and 0.08 or TAP_MAX
        -- Acquisition: when the target is more than 0.4 deg from where the pod points (the player pressed with the crosshair
        -- off the vehicle) and the look angle is not steep, slew onto it properly rather than at trim speed.
        -- Well before the overhead the measured error is quiet (a recorded approach: 1.5 m spread), but a dead band of
        -- 0.04 deg left a steady 5 to 7 m sideways bias (0.05 deg at 25,000 ft). Use a tighter dead band there.
        if graze0 <= 0.82 then DB = 0.015 end
        local gain = TAP_GAIN
        -- Steeper-approach boost (Oct 19 2026): the pod drifted to the far side of the target on the way in to the pass and came
        -- back after it. Down the steep part of the approach the trim above (gain 0.15, cap 0.05 to 0.08, dead band 0.04) is
        -- far below the rate the picture needs, so a small steady error is never taken out. Here the gain, the cap and the dead
        -- band are tighter/larger. The smoothing, the hands-off zone at the overhead and the +/-25 deg zone round azimuth 90 stay.
        -- Config.PAVE_HOLD_STEEP_BOOST = false restores the old trim; _GAIN, _CAP and _DB tune it.
        if graze0 > 0.82 and Config.PAVE_HOLD_STEEP_BOOST ~= false then
            gain = Config.PAVE_HOLD_STEEP_GAIN or 0.35
            DB = Config.PAVE_HOLD_STEEP_DB or 0.02
            local cap = Config.PAVE_HOLD_STEEP_CAP or 0.12
            mx, my = math.max(mx, math.min(cap / cel, 0.2)), math.max(my, cap)
        end
        if graze0 <= 0.82 and (math.abs(f_az) > 0.4 or math.abs(f_el) > 0.4) then
            gain = 0.3
            mx, my = 0.4, 0.4
        end
        if job.zphase == 'fine' then gain, mx, my, DB = 0.3, 0.3, 0.3, 0.004 end   -- zoomed out the pod answers 2.6x faster
        -- Faster return after a bump (Oct 16 2026). The trim above is a hand-sized tap (gain 0.15, cap 0.05), which at the
        -- measured pod rate (about 0.85 deg/s per unit of stick, 0.2 to 0.3 s late) takes many seconds to take out the few
        -- tenths of a degree a bump leaves. Here the gain is higher and the cap larger, with the error's rate used to stop the
        -- stick once the pod would reach the point inside that delay, so it closes quickly without running past. Only the zoomed
        -- in, not steeply down phase; the zoomed-out fine phase and the steep path keep their own settings. Off with
        -- Config.PAVE_HOLD_FAST = false.
        local pa, pe = f_az, f_el
        if Config.PAVE_HOLD_FAST ~= false and graze0 <= 0.82 and job.zphase ~= 'fine' then
            local FG, FC, PRED = Config.PAVE_HOLD_FAST_GAIN or 0.8, Config.PAVE_HOLD_FAST_CAP or 0.3, Config.PAVE_HOLD_FAST_PRED_S or 0.3
            gain = math.max(gain, FG)
            mx, my = math.max(mx, FC), math.max(my, FC)
            local qa, qe = f_az + (job.veaz or 0) * PRED, f_el + (job.veel or 0) * PRED
            pa = (qa * f_az < 0) and 0 or qa     -- would cross zero within the delay: coast
            pe = (qe * f_el < 0) and 0 or qe
        end
        -- Close-wide gyration (Oct 21 2026): inside 10,000 ft PaveSearch puts the pod wide, where the stick moves it about 2.6 times faster than
        -- zoomed in (7 against 2.7 deg/s per unit; the pod's own fine phase already uses gain 0.3 for that). The settings above are tuned for the
        -- narrow view, so with the pod wide the loop gain was 2.6 times too high and the pod oscillated, the swing growing until the pod went
        -- narrow again. With the pod wide and not in the job's own fine phase, gain and caps are scaled by Config.PAVE_HOLD_WIDE_SCALE (0.4;
        -- 1 = off). The ground-frame trim above is sized in picture widths and needs no scaling.
        do
            local ws = Config.PAVE_HOLD_WIDE_SCALE or 0.4
            if ws < 1 and job.zphase ~= 'fine' and pod_is_wide() == true then
                gain, mx, my = gain * ws, mx * ws, my * ws
                if not job.ws_logged then
                    job.ws_logged = true
                    AGLog.Info('pave: hold: pod is wide, trim gain and caps scaled by %.2f (gain %.2f, caps %.2f / %.2f)', ws, gain, mx, my)
                end
            elseif job.ws_logged and pod_is_wide() == false then
                job.ws_logged = nil
            end
        end
        if math.abs(f_az) > DB / cel then hx = clamp(pa * gain, -mx, mx) end
        if math.abs(f_el) > DB then hy = -clamp(pe * gain, -my, my) end
        -- Once the pod looks back past the wing line the stick acts on the picture, which is turned round, so both axes work
        -- the other way. Measured on a pass: with the pod at 170 deg azimuth, a stick that closed the error before the pass
        -- opened it steadily.
        local backwards = math.abs(have_az) > 90
        if graze0 <= 0.82 and Config.PAVE_HOLD_ROTATE ~= false and math.abs(have_az) > 15 then
            -- Oct 20 2026 flight: a short-press ground spot 80-90 deg off the wing line (look angle 38) sat in a limit cycle for 47 s, stick +/-0.4
            -- flipping every sample and the pod's elevation swinging +/-1.5 deg: the azimuth tap went to the stick axis that moves the pod in elevation
            -- there. The slew rotates the stick by the pod azimuth (regular pod: the measured curve); the hold only flipped it past 90. Same rotation here
            -- while not steeply down (the steep path has its own handling). Config.PAVE_HOLD_ROTATE = false returns to the flip.
            local psi = math.abs(have_az)
            if regular_pod() and psi > 90 then
                if psi < 125 then psi = 90 + (psi - 90) * (84 / 35)
                elseif psi < 180 then psi = 174 + (psi - 125) * (6 / 55)
                else psi = 180 end
            end
            local phi = math.rad(have_az >= 0 and -psi or psi)
            local c, sn = math.cos(phi), math.sin(phi)
            hx, hy = hx * c + hy * sn, -hx * sn + hy * c
            backwards = false
        end
        if backwards then hx, hy = -hx, -hy end
        -- Only the last few degrees around the overhead point are hands-off (look angle above about 84 deg: the pod swings
        -- through 180 deg of azimuth in about two seconds and the stick reverses part way). Before that the trim stays on:
        -- hands-off from 55 deg let the sideways error grow to 15 to 20 m at the pass.
        local sl = dist3(S, hit)
        local graze = sl > 1 and ((S.y - hit.y) / sl) or 0
        if graze > 0.994 then job.over = true end
        if job.over and not job.passed and graze < 0.994 and math.abs(have_az) > 120 then
            job.passed = true
            AGLog.Info('pave: hold: past the overhead point (look angle %.0f deg, pod azimuth %.0f), trimming again, error %+.2f az %+.2f el', math.deg(math.asin(clamp(graze, -1, 1))), have_az, az_err, el_err)
        end
        if job.over and not job.passed then hx, hy = 0, 0 end
        -- The stick reverses as the pod swings past the wing line (azimuth 90), and the picture is turning fastest there:
        -- no stick while the pod is within 25 deg of it and steeply down.
        if graze0 > 0.82 and math.abs(math.abs(have_az) - 90) < 25 then hx, hy = 0, 0 end
        self:SetStick(hx, hy)
        if now - self.progress_log >= 5 then
            self.progress_log = now
            AGLog.Detail('pave: hold loop: error %+.2f az %+.2f el, integral %+.2f %+.2f, stick %+.2f %+.2f', az_err, el_err, job.iaz or 0, job.iel or 0, hx, hy)
        end
        return
    end
    -- Flight 2 (Oct 20 2026), both unables: the feed-forward assumes the pod stands still in the aircraft frame, but in track the pod holds a ground point
    -- and already swings with the ground. At a target rate of 4.4 deg/s (a point abeam at 3 NM) the feed term was 3.4 deg, which canceled a 3.3 deg
    -- error exactly: stick 0.04 for 9 s with the pod 3.3 deg ahead, then "no progress", unable. In track the feed is cut to
    -- Config.PAVE_FEED_TRACK (0.25) of its value, regular pod, look there. 1 = old behavior.
    local feed = FEED
    if job.what == 'look there' and regular_pod() and op_mode() == 1 then feed = FEED * (Config.PAVE_FEED_TRACK or 0.25) end
    local pred_az = az_err - ((job.vaz or 0) - wvaz) * LEAD + wvaz * feed
    local pred_el = el_err - ((job.vel or 0) - wvel) * LEAD + wvel * feed
    -- Steeply down the azimuth gimbal angle means little on the ground: a degree of pod azimuth moves the picture only cos(elevation)
    -- degrees (a quarter of a degree at 75 deg down), and the stick moves the picture, not the gimbal, at a fixed rate. So the loop
    -- gain on the azimuth error was three to four times too high there and the stick sawed from end to end (searches that run over
    -- the top of a point, seen Oct 19 2026: errors of 2 to 7 deg, stick flipping +/-0.7 each second at 70 to 80 deg down). The azimuth
    -- term is scaled by cos(elevation), floor 0.2. 
    local cel_s = clamp(math.cos(math.rad(have_el)), 0.2, 1)
    pred_az = pred_az * cel_s
    -- Tolerance is a distance on the ground, so a given angle error matters less up close than far away, and elevation
    -- matters least of all at a shallow look angle.
    local sdx, sdy, sdz = hit.x - S.x, hit.y - S.y, hit.z - S.z
    local slant = math.max(math.sqrt(sdx * sdx + sdy * sdy + sdz * sdz), 500)
    local graze = math.max(math.abs(sdy) / slant, 0.05)
    local tol_az = math.min(TOL, math.max(0.15, math.deg(GROUND_TOL / slant)))
    local tol_el = math.min(TOL, math.max(0.15, math.deg(GROUND_TOL * graze / slant)))
    if job.what == 'look there' then tol_az, tol_el = TOL, TOL end   -- the player sweetens the view afterwards
    -- Elevation error at a shallow look angle (Oct 20 2026): two look theres ended 0.8 to 0.9 deg low at a 4 deg look angle, which put the pod's
    -- ground point 3,400 to 3,600 ft short of the point. The elevation limit is a fraction of the look angle (Config.PAVE_LOOK_EL_FRAC, 0.06,
    -- floor PAVE_LOOK_EL_MIN_DEG 0.15), given up after PAVE_LOOK_EL_RELAX_S (25 s) so it can never turn into an unable.
    local el_lim_look = 1e9
    if job.what == 'look there' and now - job.started < (Config.PAVE_LOOK_EL_RELAX_S or 25) then
        local dep = math.deg(math.asin(clamp(graze, 0, 1)))
        el_lim_look = math.max(Config.PAVE_LOOK_EL_MIN_DEG or 0.15, (Config.PAVE_LOOK_EL_FRAC or 0.06) * dep)
        tol_el = math.min(tol_el, el_lim_look)
    end
    -- Good enough after a few seconds, so a stubborn last fraction of a degree never holds the stick for long.
    -- A look there that has run 10 s and sits within 1 deg counts as there (Oct 20 2026: it hung 0.7 to 1.0 deg off for 12 s with the aircraft
    -- yawing slowly, then timed out as "unable"; the player sweetens the view afterwards anyway).
    local nlim = (job.what == 'look there' and now - job.started > (Config.PAVE_NEAR_AFTER_S or 10)) and (Config.PAVE_NEAR_DEG or 1.0) or 0.5
    local nlim_el = math.min(nlim, el_lim_look)
    local near = now - job.started > 6 and math.abs(az_err) <= nlim and math.abs(el_err) <= nlim_el and speed < 1.5
    if near then tol_az, tol_el = math.max(tol_az, nlim), math.max(tol_el, nlim_el) end
    if not job.continuous and math.abs(az_err * cel_s) <= tol_az and math.abs(el_err) <= tol_el and speed < 1.5 then
        job.settled = job.settled + 1
        self:SetStick(0, 0)
        if job.settled >= 3 then
            -- The pod reports where its line of sight meets the ground. When that is clearly short of or beyond the target the
            -- picture is centered on the wrong spot, so nudge the elevation by what that distance implies and settle again.
            local gx, gy, gz
            pcall(function()
                local p = GetProperty(PS, 'Pod Target (Track)')
                local n, e, d = num(p.x), num(p.y), num(p.z)
                gx, gy, gz = S.x + n, S.y - d, S.z + e
            end)
            local gd = 'n/a'
            if gx then
                local pt = { x = gx, y = gy, z = gz }
                gd = string.format('%.0f ft', dist3(pt, hit) * 3.28084)
            end
            self:Finish(true, string.format('error %.2f / %.2f deg, pod ground point %s from target', az_err, el_err, gd))
        end
        return
    end
    job.settled = 0
    local x, y = Pave.Stick(pred_az, pred_el)
    -- Zoomed in the stick moves the pod 2.7 deg/s per unit against 7 to 8 zoomed out, but GAIN and FEED are set for the wide view. Result
    -- (Oct 20 2026 log, three unables): the pod trailed a moving target by about 1.1 s of its angular rate, 1 deg at 1 deg/s and 4 deg at
    -- 3.5 deg/s, with the stick near 0.04 and no way to close it, then the slew timed out. A look there gets the stick multiplied by
    -- Config.PAVE_ZOOMIN_GAIN (2.5) once it is zoomed in, which leaves the loop gain near the wide one (1.35 against 1.5 per second).
    if job.what == 'look there' and not zoom_far and (Config.PAVE_ZOOMIN_GAIN or 2.5) ~= 1 then
        local k = Config.PAVE_ZOOMIN_GAIN or 2.5
        x, y = clamp(x * k, -1, 1), clamp(y * k, -1, 1)
    end
    -- Shallow look angle (Oct 20 2026): a look there reacquired at 6 NM and a 1.7 deg look angle chased +/-0.5 deg in a 0.8 s limit cycle, the stick
    -- going end to end in both axes (circling), until it timed out. A degree of pod angle there is thousands of feet on the ground and the
    -- lead term multiplies the pod's own jitter. The stick is scaled by look angle / PAVE_SHALLOW_GAIN_DEG (6), not below PAVE_SHALLOW_GAIN_MIN (0.3).
    if job.what == 'look there' and (Config.PAVE_SHALLOW_GAIN_DEG or 6) > 0 and regular_pod() then
        local dep = math.deg(math.asin(clamp(math.abs(sdy) / slant, 0, 1)))
        local sg = clamp(dep / (Config.PAVE_SHALLOW_GAIN_DEG or 6), Config.PAVE_SHALLOW_GAIN_MIN or 0.3, 1)
        -- The scaling cures a small-error limit cycle, so it fades out with the error: full from PAVE_SHALLOW_FADE_LO_DEG (4) of error, gone by _HI (12).
        -- (Oct 20 2026, hill target at about 1 deg look angle: with the low route the pod was clear of the zone and the stick still sat at the 0.30 floor
        -- through the whole 100 deg swing; 39.6 s.)
        local emax = math.max(math.abs(az_err * cel_s), math.abs(el_err))
        local fade = clamp((emax - (Config.PAVE_SHALLOW_FADE_LO_DEG or 4)) / ((Config.PAVE_SHALLOW_FADE_HI_DEG or 12) - (Config.PAVE_SHALLOW_FADE_LO_DEG or 4)), 0, 1)
        sg = sg + (1 - sg) * fade
        if sg < 1 then x, y = x * sg, y * sg end
    end
    if not job.continuous then
        -- Keep a little stick on while outside tolerance so the last fraction of a degree is not left unfinished.
        if math.abs(az_err * cel_s) > tol_az and math.abs(x) < 0.04 then x = (pred_az >= 0) and 0.04 or -0.04 end
        if math.abs(el_err) > tol_el and math.abs(y) < 0.04 then y = (pred_el >= 0) and -0.04 or 0.04 end
    end
    -- The stick axes turn with the pod's azimuth. Measured Oct 19 2026 from 200 one-second steps of the log: with the pod looking
    -- ahead the stick moves the pod normally; at -90 deg the stick's X moves the pod in elevation and Y in azimuth; at -180 both
    -- are reversed (what the old rule only did past 90 deg, as a flip). A rotation of the stick by minus the pod azimuth fits the
    -- steps with a correlation of 0.8 (0.1 to 0.2 without it). x, y here are the stick wanted if the axes were the normal ones.
    -- Elevation boost on the nose line (Oct 20 2026): crossing it at azimuth stick 0.30 the elevation sank 4 deg in 5 s (about 1.3 deg/s)
    -- while the elevation stick asked for only -0.04 to -0.17, then rebounded 5 deg when the cap lifted. The elevation stick is
    -- multiplied by 1 + Config.PAVE_ZONE_EL_BOOST (2) at the middle of the nose zone, easing to 1 at its edge, and may use up to
    -- Config.PAVE_ZONE_EL_MAX (0.5) there. PAVE_ZONE_EL_BOOST = 0 turns it off. Wide zoom only.
    if zoom_far and regular_pod() and (Config.PAVE_ZONE_CAP or 0.3) < 1 and (Config.PAVE_ZONE_EL_BOOST or 2) > 0 and math.abs(y) < (Config.PAVE_ZONE_EL_MAX or 0.5) then
        local fz = nose_free(have_az, have_el)
        if fz < 1 then
            local ym = Config.PAVE_ZONE_EL_MAX or 0.5
            y = clamp(y * (1 + (Config.PAVE_ZONE_EL_BOOST or 2) * (1 - fz)), -ym, ym)
            -- The boost also multiplies the noise in the predicted-motion term: the elevation stick flipped between +0.5 and -0.5
            -- every half second while the pod moved +/-0.3 deg. Low-passed here (time constant Config.PAVE_ZONE_EL_SMOOTH_S, 0.35 s),
            -- so the steady push against the sag stays and the flipping goes.
            local tau = Config.PAVE_ZONE_EL_SMOOTH_S or 0.35
            if tau > 0 then
                local ys = job.ysm or y
                local a = 1 - math.exp(-math.min(now - (job.ysm_t or now), 0.5) / tau)
                job.ysm = ys + (y - ys) * a
                job.ysm_t = now
                y = job.ysm
            end
        else
            job.ysm, job.ysm_t = nil, nil
        end
    else
        job.ysm, job.ysm_t = nil, nil
    end
    local xp, yp = x, y   -- the stick wanted with the normal axes (x: azimuth, y: elevation, down = more elevation)
    if Config.PAVE_STICK_ROTATE ~= false then
        -- Rotation angle (Oct 20 2026, regression of the pod rates on the logged stick, ground motion removed, both sides mirrored): the pod's own stick
        -- frame turns with the azimuth up to about 90 deg, then turns on to about 175 deg by 125 deg and stays there (shallow looks: 170 to 178 at
        -- 110-165 deg off the nose). The old rule used the azimuth itself, 30 to 60 deg short of that between 100 and 150 deg.
        -- (the old azimuth rotation was removed Oct 20 2026)
        local psi = math.abs(have_az)
        if regular_pod() then
            if psi > 90 then
                if psi < 125 then psi = 90 + (psi - 90) * (84 / 35)
                elseif psi < 180 then psi = 174 + (psi - 125) * (6 / 55)
                else psi = 180 end
            end
        end
        local phi = math.rad(have_az >= 0 and -psi or psi)
        -- (The aft rotation drop, PAVE_AFT_NO_ROTATE_DEG, was tried and left off; removed Oct 20 2026.)
        -- Straight down the pod's azimuth is ill defined: it reads anything while the pod passes through -90 deg elevation (seen
        -- Oct 19 2026: 1, -19, -1, 1, -13, 99 degrees in successive seconds), and the stick rotation that follows it saws. Within
        -- Config.PAVE_NADIR_DEG (82) of straight down the rotation angle from the last good reading is kept, and the stick is
        -- smoothed, until the pod is past it. PAVE_NADIR_DEG = 90 switches this off.
        local nadir = Config.PAVE_NADIR_DEG or 82
        if have_el < -nadir then
            phi = job.phi_keep or phi
            job.nadir_smooth = true
        else
            job.phi_keep = phi
        end
        local c, sn = math.cos(phi), math.sin(phi)
        x, y = x * c + y * sn, -x * sn + y * c
        x, y = clamp(x, -1, 1), clamp(y, -1, 1)
        -- (The reversed stick past PAVE_AFT_FLIP_DEG was tried and left off; removed Oct 20 2026.)
        if have_el < -(Config.PAVE_NADIR_DEG or 82) + 4 and job.last_sx then
            x, y = job.last_sx + (x - job.last_sx) * 0.35, job.last_sy + (y - job.last_sy) * 0.35
        end
        -- Rear zone: the sign of the azimuth error flips as the target crosses 180 and the pod barely answers, so the stick sawed +/-1.
        -- Low-passed (PAVE_REAR_SMOOTH_S, 0.6 s) from PAVE_REAR_ZONE_DEG.
        -- Flight 2: a zoomed-in look there round the side (pod azimuth 90 to 135, target running away at 4 deg/s) sawed the stick +/-1.0 every sample
        -- for 12 s with the pod 3 to 4 deg ahead of the point, then timed out as unable. The rear low-pass starts at Config.PAVE_SIDE_SMOOTH_FROM_DEG
        -- (85) for a zoomed-in look there on the regular pod; 181 = off.
        local side_sm = job.what == 'look there' and not zoom_far and math.abs(have_az) > (Config.PAVE_SIDE_SMOOTH_FROM_DEG or 85)
        if regular_pod() and (side_sm or math.abs(have_az) > (Config.PAVE_REAR_ZONE_DEG or 168) - 6) and (Config.PAVE_REAR_SMOOTH_S or 0.6) > 0 then
            local a = 1 - math.exp(-math.min(now - (job.rsm_t or now), 0.5) / (Config.PAVE_REAR_SMOOTH_S or 0.6))
            job.rsx = (job.rsx or x) + (x - (job.rsx or x)) * a
            job.rsy = (job.rsy or y) + (y - (job.rsy or y)) * a
            job.rsm_t = now
            x, y = job.rsx, job.rsy
        else
            job.rsx, job.rsy, job.rsm_t = nil, nil, nil
        end
        job.last_sx, job.last_sy = x, y
        if math.abs(have_az) > 45 and not job.rear_logged then
            job.rear_logged = true
            AGLog.Info('pave: pod looks %.0f deg off the nose: stick rotated by %.0f deg (the stick axes turn with the pod azimuth)', have_az, -have_az)
        end
    elseif Config.PAVE_REAR_STICK_FLIP ~= false and math.abs(have_az) > 90 then
        x, y = -x, -y
    end
    -- Limits on the stick size (one scale factor, applied to the stick and to the stick the pod is expected to answer).
    -- 1. Adaptive back-off (Config.PAVE_ADAPTIVE, default on): the pod is meant to answer the stick the way a rate model says
    --    (about 7 deg/s per unit of stick zoomed out, 2.7 zoomed in, lagging about 0.7 s). When it moves in a way the stick did not
    --    ask for (Oct 19 2026 log marks: elevation dropping by 5 deg with no elevation stick, azimuth running back against a full
    --    stick) for 0.25 s (Config.PAVE_ADAPT_PERSIST_S), the cap is halved (floor Config.PAVE_ADAPT_FLOOR, 0.12) and then given back at 0.15 per second once
    --    the pod has behaved for Config.PAVE_ADAPT_HOLD_S (2 s). Covers pod positions and types that have not been mapped.
    -- 2. Datum band (removed Oct 20 2026; it was a fixed cap while the pod is within PAVE_BAND_LO / _HI
    --    deg of the aircraft datum plane, held PAVE_BAND_HOLD_S (3 s) after it leaves. Flown clean at 0.30; 0.50 was not.
    local capnow, why = 1, nil
    -- 3. Trouble zones (Config.PAVE_ZONE_CAP, default 0.30; 1 = off). Mapped Oct 20 2026 from every stored wide-zoom slew:
    --    (a) the nose line, pod azimuth within 6 deg of the aircraft nose, any elevation: an azimuth stick moves the pod in
    --        elevation by 0.8 to 2.1 deg/s (0.2 to 0.7 elsewhere) and the azimuth answer falls to 2 to 4 deg/s per unit of stick;
    --    (b) off to the side (azimuth 15 deg or more) with the pod looking at or above about -1.5 deg to the datum plane:
    --        2.3 to 3.2 deg/s of elevation motion at 40 to 90 deg azimuth.
    --    The cap eases back to full stick over Config.PAVE_ZONE_TAPER_DEG (8) so the pod is slowed before it arrives.
    --    Everywhere else the pod moves at full speed.
    local zcap = Config.PAVE_ZONE_CAP or 0.3
    -- A look there restarted after the tail wait begins on the nose line and crawled out at 0.7 deg/s; the pod dropped track in it twice (Oct 20 2026).
    if job.lt_tries and zcap < 1 then zcap = math.max(zcap, Config.PAVE_REACQ_ZONE_CAP or 0.6) end
    if not regular_pod() then zcap = 1 end   -- trouble zones, nose line and rear zone: regular pod only
    if zcap < 1 then
        local nose = Config.PAVE_ZONE_NOSE_DEG or 6
        local taper = Config.PAVE_ZONE_TAPER_DEG or 8
        local up_el = Config.PAVE_ZONE_UPPER_EL or -1.5
        local up_az = Config.PAVE_ZONE_UPPER_AZ or 15
        local fa = nose_free(have_az, have_el)                                         -- 0 on the nose line, 1 clear of it
        local fe = clamp((have_el - up_el) / (Config.PAVE_ZONE_UPPER_TAPER_DEG or 2), 0, 1)   -- 1 at or above the upper limit
        local fs = clamp((math.abs(have_az) - up_az) / taper, 0, 1)                   -- 1 well off to the side
        local zn = zcap + (1 - zcap) * fa
        local zu = 1 - (1 - zcap) * fe * fs
        -- Rear zone (Oct 20 2026): the stick answer falls from about 11 deg/s per unit at 100 deg off the nose to 3 at 165 and about 0 past
        -- 175 (reversed all the way, so the rotation stays). Same treatment as the nose line: cap from PAVE_REAR_ZONE_DEG (168) minus a 6 deg taper.
        local rz = Config.PAVE_REAR_ZONE_DEG or 168
        local zr = 1
        if rz <= 180 then zr = 1 - (1 - (Config.PAVE_REAR_ZONE_CAP or 0.35)) * clamp((math.abs(have_az) - (rz - 6)) / 6, 0, 1) end
        local zc = math.min(zn, zu, zr)
        if zc < 1 then
            -- Held briefly after the pod leaves the zone: it can be thrown out of it, and the cap is needed most then.
            job.zone_until, job.zone_cap = now + (Config.PAVE_ZONE_HOLD_S or 1), zc
        elseif job.zone_until and now < job.zone_until then
            zc = job.zone_cap or 1
        end
        if zc < 1 then
            capnow, why = zc, 'zone'
            if not job.zone_logged and zc < 0.95 then
                job.zone_logged = true
                AGLog.Info('pave: pod at %.0f az %+.1f el is in a trouble zone (%s): stick capped at %.2f', have_az, have_el, zn <= zu and 'nose line' or 'upper side', zc)
            end
        end
    end
    local ad
    if Config.PAVE_ADAPTIVE ~= false then
        ad = job.ad
        if not ad then ad = { cap = 1, ex = 0, ey = 0, t = now, last_bad = -100, n = 0 }; job.ad = ad end
        local dta = math.min(now - ad.t, 0.5)
        if dta > 0.01 then
            ad.t = now
            local floor = Config.PAVE_ADAPT_FLOOR or 0.30
            local tol = Config.PAVE_ADAPT_TOL or 2.5
            -- The pod's own motion, not the aircraft's: where the last line of sight would be in the aircraft frame NOW if it had not
            -- moved in the world is taken off, so rolling, pitching or turning does not read as the pod moving by itself.
            local oaz, oel = 0, 0
            if ad.pw_az and now - ad.pw_t > 0.02 then
                local bz, be = Pave.ToBody(ad.pw_az, ad.pw_el, att_h, att_p, att_b)
                local dtp = now - ad.pw_t
                ad.rz = (ad.rz or 0) * 0.6 + (wrap180(have_az - bz) / dtp) * 0.4
                ad.re = (ad.re or 0) * 0.6 + ((have_el - be) / dtp) * 0.4
            end
            if ad.pw_az then oaz, oel = ad.rz or 0, ad.re or 0 end
            ad.pw_az, ad.pw_el, ad.pw_t = pod_az, pod_el, now
            local eaz, eel = oaz - ad.ex, oel - ad.ey
            -- Far targets only (Config.PAVE_ADAPT_MIN_FT, 60,000 ft). Close in, the aircraft flying past the held point turns the line of
            -- sight by up to 7 to 18 deg/s (Oct 20 2026, targets 2 to 4 NM out): that read as the pod moving by itself, the cap went to the
            -- floor and two slews stalled. The rate model has no term for the aircraft's own motion over the ground.
            local far = dist3(S, hit) > (Config.PAVE_ADAPT_MIN_FT or 60000) / 3.28084
            if not far and ad.cap < 1 then
                ad.cap = 1
                ad.bad_since = nil
                AGLog.Info('pave: adaptive back-off released: target %.0f ft away is inside the range it works at', dist3(S, hit) * 3.28084)
            end
            local bad = far and (now - (job.started or now)) > 1.0 and have_el > -60
                and (math.abs(eaz) > tol + 0.4 * math.abs(ad.ex) or math.abs(eel) > tol + 0.4 * math.abs(ad.ey))
            if bad then
                ad.bad_since = ad.bad_since or now
                if now - ad.bad_since >= (Config.PAVE_ADAPT_PERSIST_S or 0.25) then
                    ad.bad_since = now
                    ad.last_bad = now
                    ad.n = ad.n + 1
                    ad.cap = math.max(floor, ad.cap * 0.5)
                    AGLog.Info('pave: adaptive back-off #%d: pod moved %+.1f az %+.1f el deg/s, the stick asked %+.1f / %+.1f (pod at %.0f az %+.1f el): stick capped at %.2f', ad.n, oaz, oel, ad.ex, ad.ey, have_az, have_el, ad.cap)
                end
            else
                ad.bad_since = nil
                if ad.cap < 1 and now - ad.last_bad > (Config.PAVE_ADAPT_HOLD_S or 2) then
                    ad.cap = math.min(1, ad.cap + 0.15 * dta)
                    if ad.cap >= 1 then AGLog.Info('pave: adaptive back-off released (%d in this slew)', ad.n) end
                end
            end
        end
        if ad.cap < capnow then capnow, why = ad.cap, 'adaptive' end
    end
    if why == 'zone' and nose_free(have_az, have_el) < 1 then
        -- In the nose zone the azimuth stick is held to the cap and the elevation stick (boosted above) may use up to PAVE_ZONE_EL_MAX.
        local yc = math.max(capnow, Config.PAVE_ZONE_EL_MAX or 0.5)
        local fx = math.abs(x) > capnow and capnow / math.abs(x) or 1
        local fy = math.abs(y) > yc and yc / math.abs(y) or 1
        x, y, xp, yp = x * fx, y * fy, xp * fx, yp * fy
    else
        local m = math.max(math.abs(x), math.abs(y))
        if m > capnow then
            local f = capnow / m
            x, y, xp, yp = x * f, y * f, xp * f, yp * f
        end
    end
    if ad then
        -- What the pod should now be doing in answer to the stick (first-order lag).
        local K = zoom_far and 7 or 2.7
        local a = 1 - math.exp(-math.min(now - (ad.t_ex or now), 0.5) / (Config.PAVE_ADAPT_LAG_S or 0.7))
        ad.t_ex = now
        ad.ex = ad.ex + (K * xp - ad.ex) * a
        ad.ey = ad.ey + (-K * yp - ad.ey) * a
    end
    self:SetStick(x, y)
    if now - self.progress_log >= 1 then
        self.progress_log = now
        AGLog.Detail('pave: slewing%s, error %+.1f az %+.1f el, stick %+.2f %+.2f | pod %.0f/%+.0f want %.0f/%+.0f (aircraft frame) bank %+.0f pitch %+.0f', zoom_far and string.format(' zoomed out (%.0f ft off)', (job.zmiss or 0) * 3.28084) or '', az_err, el_err, x, y, have_az, have_el, want_az, want_el, S.bank, S.pitch)
    end
end

return Pave
