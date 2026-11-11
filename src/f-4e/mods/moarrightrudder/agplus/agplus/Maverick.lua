-- Jester A/G+ Mavericks (Oct 2026). Jester gets the Maverick seeker onto a target and hands it to the pilot; he does not lock or fire (that waits
-- for Heatblur to expose the seeker properties). Plan, findings and design notes: MAVERICK_PLAN.md section 7. Optional Config keys: see the
-- "Maverick" block in Config.lua (the measured defaults); every key has the same default in the code, so a missing key changes nothing.
--
-- WHAT THE PLAYER SEES (Air To Ground > A/G Plus > Maverick, with the Mavericks armed, DIRECT and TV; Jester Maverick turns itself On once)
--   Jester Maverick: On / Off   Off = the context buttons in TV mode are left alone.
--   FOV: Wide / Narrow          The D/G picture the seeker is in. Jester has no readout, so he tracks it: a fresh missile is Wide, the pilot's trigger
--                               presses are followed, and each missile (station) keeps its own FOV and cap state.
--   After Launch: Next / Stop   Stored.
--   Seeker                      After Slew (Lock / Hold), Lock Now, Cage Seeker.
--   Loadout Report              Shows the Maverick stations and variants.
--   Config.MAV_DEV_MENU = true adds Maverick Dev: Trim (train, save bump, use, bump size, clear), FOV Probe, Rate Calibrate, Gimbal Calibrate.
-- Context button in TV mode (Jester Maverick On)
--   short = opens the target list (Strike List slots, then Search Area), cursor to the next; double = previous; MAV_PICK_DWELL_S (1.5) after the last press
--     Jester slews to the cursor. The seeker starts caging at once (MAV_PICK_EARLY_CAGE). Lines show the direction in arrows and a note.
--   long = closes an open list, otherwise starts the SEARCH at the ground point the player is looking at (Unable if it is beyond the gimbal limits or
--     there is no ground there). Search Area in the list searches from the boresight. Double press cancels a search or a slew.
--
-- SEEKER FACTS (measured in-sim; see the skill jester-f4e-maverick-seeker)
--   A and B are separate TV seekers: B picture 2.24 x 2.28 deg, rate K 3.75, gimbal 30; A picture 4.26 x 4.42, K 7.37, gimbal 29.4. D and G share the
--   IR seeker: narrow 2.20 x 2.30, wide 4.40 x 4.52 deg. Boresight 2.58 deg below the datum. Slew rate = K x stick^2 deg/s (D/G narrow 3.75,
--   wide 7.5). Stick Y negative = up.
--   No readout: the seeker position is dead reckoned from the stick and rate, known after a cage, unknown after a pilot slew or a lock attempt.
--   Cage = full action of the WSO stick trigger (after an unlock: half press of the hand control trigger, then the cage MAV_UNLOCK_S later).
--   The first full action on a missile whose cap is on only takes the cap off (no cage, no FOV change). On a caged seeker, or while the hand control
--   half action is held, a full action switches the D/G FOV.
--
-- SLEW AND TRACK
--   Slew: cage, then the hand-control stick steers the dead-reckoned seeker until it matches the target direction (gimbal geometry correction plus the
--   trim). After arrival the loop keeps tracking (target rate + MAV_TRACK_KP x error) until the lock attempt: Lock mode releases the trigger when the
--   error has stayed under MAV_LOCK_ERR_DEG (0.08) for MAV_SETTLE_S (0.2), or after MAV_LOCK_WAIT_S (4); Hold mode tracks until a press, Lock Now, the
--   target leaving the gimbal, or MAV_TRACK_MAX_S (45). A frame hitch over MAV_HITCH_S (0.6) loses the position (cage again).
--   The smallest stick comes from a minimum rate (MAV_MIN_RATE 0.23 deg/s), so the wide seeker does not chatter.
-- SEARCH
--   A spiral flown in the seeker's own angles (MAV_SEARCH_SPEED 1.5 deg/s, turns MAV_SEARCH_GAP 0.8 pictures apart, MAV_SEARCH_S 360 s cap) round a
--   ground point fixed in the world (a terrain ray), so it stays over the same ground as the aircraft moves. Every hostile unit in the picture, inside
--   the detection range for the seeker (MAV_SEE_SCALE_*), in line of sight, joins the target list from the moment the seeker is on the boresight.
--   It ends and cages when finished, canceled, or when the center reaches a gimbal limit. A D/G search runs in Narrow; the pilot's FOV is put back after
--   the cage (1 press with the cap off, 2 with it on).
-- PILOT ACTIONS JESTER WATCHES (ARR from BombBtnFeed.lua, the Pilot Trigger position 0 / 1 / 2, Master Arm must be ON for the trigger rules)
--   ARR held and the hand-control stick off center = the pilot is slewing, the seeker is not caged, Jester lets go (MAV_AAR_HANDOVER = false turns the watch off).
--   Pilot trigger full action: A/B always a cage (Jester finishes it himself if he held the trigger). D/G: with ARR held, or on a caged / returning
--   seeker, or with the hand control half action held = FOV change; otherwise a re-cage. The first one after the cap is on = uncage only.
--   A pilot hand-over says Config.MAV_TAKEOVER_VOICE; after a slew Jester says Config.MAV_DONE_VOICE (names in Maverick.Voices, 'none' is silent).
-- TRIM (Dev menu): Trim Train holds the trigger after a slew, the player bumps the seeker onto the target with the hand control (ARR released; Pan X =
--   stick up / down, Pan Y = right / left), Save Bump stores travel and bump per seeker set (TV-A, TV-B, IR-Narrow, IR-Wide) in Logs\mavtrim.txt
--   (lines "K key Tx Ty Bx By slot range alias"). The fit per set is bump = a + b x travel + c x other-axis travel; Trim Use adds it to every slew.
-- TOOLS (Dev menu): FOV Probe (picture size by edge bisection), Rate Calibrate and Gimbal Calibrate (the D/G display's elevation lines read about 10 percent low).
-- LOGGING: events go to agplus.log; the per-tick lines (mav-steer, mav-track, mav-pan, mav-release, trim travel) only with Config.PAVE_LOG_DETAIL = true,
--   and the search's nearest-unit lines with Config.MAV_SEARCH_DEBUG = true.
local Class = require('base.Class')
local Behavior = require('base.Behavior')
local Config = require('agplus.Config')
local AGLog = require('agplus.Log')
local Menu = require('agplus.Menu')
local Dbg = require('agplus.PaveDebug')
local Util = require('agplus.Util')
local Stores = require('agplus.Stores')
local Pave = require('agplus.Pave')
local PrepareDscg = require('behaviors.PrepareDscg')
local Interactions = require('base.Interactions')
local Task = require('base.Task')
local PickMenu = require('agplus.PickMenu')

local Maverick = {}

local TOP = 'Maverick'
local BORESIGHT_EL = -2.58     -- 45 mil below the aircraft datum line (HB manual: sight depression matches the seeker boresight)
local FOVS = { 'Wide', 'Narrow' }

local st = { on = false, fire = 'Pilot Commanded', fov = 1, after_next = true, idx = 0, hold = false, fresh = true,
    train = false, trim_on = false, bump = { x = 0, y = 0 }, nq = {}, bump_deg = Config.MAV_BUMP_DEG or 0.1 }
local BUMP_SIZES = { 0.05, 0.1, 0.2 }
Maverick.State = st

-- What each variant is (HB manual). Gimbal limits and slew rates unmeasured, so they are not here.
local PROFILES = {
    A = { seeker = 'TV', fovs = 'wide only', steer = true },
    B = { seeker = 'TV', fovs = 'narrow only', steer = true },
    D = { seeker = 'IR', fovs = 'wide and narrow', steer = true },
    G = { seeker = 'IR', fovs = 'wide and narrow', steer = true },
}
local STICK = 0.5              -- the stick deflection the measured rate belongs to

local function pretty(name) return (tostring(name or '?'):gsub('_', ' ')) end

--------------------------------------------------------------------------------
-- Loadout: Maverick stations from the payload feed (type 4/4/8/n; the class id names the variant)
--------------------------------------------------------------------------------

function Maverick.Loadout()
    local out = {}
    local text
    pcall(function()
        local fh = io.open(Config.PAYLOAD_FEED, 'r')
        if fh then text = fh:read('*a') fh:close() end
    end)
    Maverick.feed_missing = (text == nil)
    if not text then return out end
    for station, clsid, count, l1, l2, l3 in text:gmatch('S (%S+) clsid=(%S*) count=(%d+) type=(%d+)/(%d+)/(%d+)/%d+') do
        if tonumber(l1) == 4 and tonumber(l2) == 4 and tonumber(l3) == 8 and (tonumber(count) or 0) > 0 then
            local v = clsid:match('AGM%-65(%u)')
            out[#out + 1] = { station = station, variant = v or '?', count = tonumber(count), armed = Stores.StationArmed(station) }
        end
    end
    table.sort(out, function(a, b) return (tonumber(a.station) or 0) < (tonumber(b.station) or 0) end)
    return out
end

local function loadout_text(list)
    list = list or Maverick.Loadout()
    if #list == 0 then
        if Maverick.feed_missing then return 'No Payload Feed - Check Paths In Config.lua' end
        return 'No Mavericks'
    end
    local parts = {}
    for _, m in ipairs(list) do
        parts[#parts + 1] = string.format('%s: AGM-65%s%s', m.station, m.variant, m.armed and ' (armed)' or '')
    end
    return table.concat(parts, ', ')
end

--------------------------------------------------------------------------------
-- TV mode (stock: Delivery DIRECT + Weapon Select TV)
--------------------------------------------------------------------------------

function Maverick.ModeActive()
    local active = false
    pcall(function()
        local inst = GetJester().behaviors[PrepareDscg]
        active = inst ~= nil and inst.current_mode == PrepareDscg.mode.TV_WEAPON
    end)
    return active
end

--------------------------------------------------------------------------------
-- Aim maths: where a target is relative to the aircraft and to the Maverick boresight
--------------------------------------------------------------------------------

local function dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- entry: a Strike List snapshot. Returns { rng (m), az (deg right of the nose), el (deg above the boresight) } or nil, reason.
-- Target motion (Phase 3b, Oct 21 2026). The unit feed gives a position once a second; the velocity comes from the last two samples
-- (smoothed) and carries the position forward from the sample to now, at most 1.5 s. Standing vehicles (under 0.5 m/s) stay put.
-- Off with Config.MAV_TARGET_PREDICT = false.
local vtrack = {}
local function target_point(entry, Search)
    local p = { x = entry.x, y = entry.y, z = entry.z }
    local u = Search and Search.S and Search.S.units and Search.S.units[entry.id]
    if not u then return p end
    p = { x = u.x, y = u.y, z = u.z }
    local ut = Search.S.units_t
    if Config.MAV_TARGET_PREDICT == false or not ut or ut < 0 then return p end
    local v = vtrack[entry.id]
    if not v then
        v = { ut = ut, x = u.x, z = u.z, vx = 0, vz = 0 }
        vtrack[entry.id] = v
    elseif v.ut ~= ut then
        local dt = ut - v.ut
        if dt > 0 and dt < 5 then
            local vx, vz = (u.x - v.x) / dt, (u.z - v.z) / dt
            if vx * vx + vz * vz < 0.25 then vx, vz = 0, 0 end
            if vx * vx + vz * vz > 3600 then vx, vz = v.vx, v.vz end      -- over 60 m/s: a jump, not a vehicle
            v.vx, v.vz = v.vx + 0.5 * (vx - v.vx), v.vz + 0.5 * (vz - v.vz)
        else
            v.vx, v.vz = 0, 0
        end
        v.ut, v.x, v.z = ut, u.x, u.z
    end
    local dtp = Util.Now() - ut
    if dtp > 0 then
        if dtp > 1.5 then dtp = 1.5 end
        p.x, p.z = p.x + v.vx * dtp, p.z + v.vz * dtp
    end
    return p
end

function Maverick.Aim(entry, L0)
    local Search = package.loaded['agplus.PaveSearch']
    local L, why = L0, nil
    if not L then L, why = Pave.ReadLook() end
    if not L then return nil, why or 'no aircraft data' end
    local p = target_point(entry, Search)
    local waz, wel = Pave.Direction(L.self, p)
    local baz, bel = Pave.ToBody(waz, wel, L.self.heading, L.self.pitch, L.self.bank)
    return { rng = dist3(L.self, p), az = baz, el = bel - BORESIGHT_EL, body_el = bel }
end

local function aim_text(a)
    local lr = a.az >= 0 and 'right' or 'left'
    local ud = a.el >= 0 and 'above' or 'below'
    return string.format('%.1f NM, %.0f deg %s, %.0f deg %s the boresight', a.rng / 1852, math.abs(a.az), lr, math.abs(a.el), ud)
end

--------------------------------------------------------------------------------
-- Strike List access
--------------------------------------------------------------------------------

local function next_slot()
    local T = package.loaded['agplus.Targets']
    if not (T and T.Slots) then return nil end
    local slots, n = T.Slots(), T.N or 6
    for j = st.idx + 1, n do
        if slots[j] then return j, slots[j], false end
    end
    for j = 1, st.idx do
        if slots[j] then return j, slots[j], true end
    end
    return nil
end

-- The filled slot before the current one, wrapping from the first to the last (double press within 5 s).
local function prev_slot()
    local T = package.loaded['agplus.Targets']
    if not (T and T.Slots) then return nil end
    local slots, n = T.Slots(), T.N or 6
    for j = st.idx - 1, 1, -1 do
        if slots[j] then return j, slots[j], false end
    end
    for j = n, math.max(st.idx, 1), -1 do
        if slots[j] then return j, slots[j], true end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Seeker steering (A/B head)
--------------------------------------------------------------------------------

-- Seeker slew speed (deg/s, signed) for a stick value: it goes with the SQUARE of the stick (measured Oct 21 2026: 0.94 deg/s at 0.5, 3.76 at 1.0).
-- D/G (IR) steering, Oct 21 2026: the rate constant and the gimbal limit are still the A/B numbers until they are measured. st.variant is the
-- variant of the running slew; the FOV the seeker is in comes from the FOV menu : the D/G wide / narrow switch is a trigger action,
-- and Jester has no readout of it. Config.MAV_RATE_K_IR_WIDE / MAV_RATE_K_IR_NARROW / MAV_GIMBAL_DEG_IR set the IR numbers.
local function is_ir()
    local p = st.variant and PROFILES[st.variant]
    return p ~= nil and p.seeker == 'IR'
end
local function rate_k()
    if is_ir() then
        -- D measured Oct 21 2026 with the elevation lines of the display: narrow K 3.41, wide K 6.79 (twice the narrow). Slews with those numbers overshot by
        -- about 10 percent of the travel on both axes (target left of / above the gate), and 3.41 x 1.10 = 3.75 (the A/B rate) and 27.0 x 1.10 = 29.7 (the A/B gimbal 30): the
        -- lines read about 10 percent low. So the D/G use the A/B numbers: narrow K 3.75, wide K 7.5 (twice), gimbal 30.
        if FOVS[st.fov] == 'Narrow' then return Config.MAV_RATE_K_IR_NARROW or Config.MAV_RATE_K or 3.75 end
        return Config.MAV_RATE_K_IR_WIDE or (2 * (Config.MAV_RATE_K or 3.75))
    end
    -- The A and B are separate seekers (user, Oct 22 2026): MAV_RATE_K_A / MAV_RATE_K_B, else the common MAV_RATE_K.
    return (st.cal and st.cal['K_' .. tostring(st.variant)]) or Config['MAV_RATE_K_' .. tostring(st.variant)] or Config.MAV_RATE_K or 3.75      -- st.cal: a Rate Calibrate result of this session
end
-- The rate goes with the stick to a power: 2 (the square) measured on the A/B, and assumed for the D/G (Config.MAV_RATE_P_IR); Rate Cal Stick 1.00 can measure the D/G
-- rate at full stick (p = ln(rate at 1.0 / rate at 0.5) / ln 2). Config.MAV_FAST_STICK_IR (1.0) caps the stick of the long moves on the D/G.
local function rate_p()
    if is_ir() then return Config.MAV_RATE_P_IR or 2.0 end
    return Config['MAV_RATE_P_' .. tostring(st.variant)] or 2.0
end
local function fast_stick()
    if is_ir() then return Config.MAV_FAST_STICK_IR or 1.0 end
    return 1.0
end
local function rate_at(s)
    local k = rate_k()
    return (s >= 0 and 1 or -1) * k * math.abs(s) ^ rate_p()
end
local function gimbal()
    if is_ir() then return Config.MAV_GIMBAL_DEG_IR or Config.MAV_GIMBAL_DEG or 30 end      -- D lines read 27.0 (x 1.10 = 29.7), see rate_k
    return Config['MAV_GIMBAL_DEG_' .. tostring(st.variant)] or Config.MAV_GIMBAL_DEG or 30
end
local function margin() return Config.MAV_GIMBAL_MARGIN or 1.0 end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local unknown_logged = {}
local function raw(dev, cmd, value)
    local ok = pcall(function()
        local d, c = Interactions.devices[dev], Interactions.device_commands[cmd]
        if d == nil or c == nil then
            if not unknown_logged[cmd] then unknown_logged[cmd] = true AGLog.Info('mav: unknown command %s/%s', dev, cmd) end
            return
        end
        ClickRaw(d, c, value)
    end)
    if not ok then AGLog.Info('mav: raw %s failed', tostring(cmd)) end
end

local last_x, last_y = 0, 0
local function stick(x, y)
    if x == last_x and y == last_y then return end
    last_x, last_y = x, y
    raw('RADAR', 'RADAR_ANTENNA_HAND_CONTROL_SLEW_X', x)
    raw('RADAR', 'RADAR_ANTENNA_HAND_CONTROL_SLEW_Y', y)
end

local function trigger(v) st.trig_v = v raw('RADAR', 'RADAR_ANTENNA_HAND_CONTROL_TRIGGER', v) end
-- The back-seat cage is the full action of the WSO stick trigger (user finding).
-- The length of Jester's cage click (s). A full action on a TV (A/B) Maverick whose cap is still on has to be HELD for 0.5 s to take the cap off
-- (user, Oct 22 2026); every other press is only a click (0.2 s).
local function cage_click_s()
    if not is_ir() and not st.dome_open then return Config.MAV_CAP_HOLD_S or 0.5 end
    return Config.MAV_CAGE_CLICK_S or 0.2
end

-- After Launch: Next (Oct 22 2026). A Maverick launch needs the pilot's weapon release button held for 2 s. When one has gone (the station's
-- count dropped within 12 s of the button reaching 2 s), the NEXT time a cap comes off (the pilot's first full trigger on the next missile, or
-- Jester's own first cage press) the current target moves on to the next filled Strike List slot. After Launch: Stop leaves it alone.
local function cap_popped(by)
    if not st.advance_pending then return end
    st.advance_pending = false
    if not st.after_next then return end
    local j, e = next_slot()
    if j then
        st.idx = j
        AGLog.Info('mav: cap off (%s) after a launch, the current target is now slot %d %s', by, j, tostring(e and e.alias))
        Dbg.Notice('Maverick - Next Target: ' .. tostring(e and e.alias or j), 4)
        return true
    end
end

local function cage_btn(v)
    -- D/G: the same trigger action switches wide / narrow when the seeker is caged or on its way back to the cage, so Jester never presses it a
    -- second time (the pilot's own cage already started, a cage of a seeker known to be caged) - user, Oct 21 2026.
    if v == 1 and is_ir() and st.job and st.job.skip_cage then return end
    if v == 1 then
        if not st.dome_open then cap_popped('Jester') end
        st.dome_open = true
    end      -- the first full action uncages the seeker, and only that: it does not switch the FOV
    raw('WEAPONS', 'WSO_WEAPONS_Trigger', v)
end

-- The variant that the next press steers for: the armed station's, else the first Maverick station's.
function Maverick.Variant()
    local list = Maverick.Loadout()
    for _, m in ipairs(list) do
        if m.armed then return m.variant, m.station end
    end
    if list[1] then return list[1].variant, list[1].station end
    return nil
end

local function can_steer(variant)
    local p = PROFILES[variant]
    if not p then return false end
    if p.seeker == 'IR' and Config.MAV_STEER_DG == false then return false end      -- Oct 21 2026: D/G steering is on (MAV_STEER_DG = false turns it off)
    return p.steer == true or Config.MAV_STEER_DG == true
end

-- body elevation limits as elevation relative to the boresight
local function el_limits()
    local G = gimbal()
    return -G - BORESIGHT_EL, G - BORESIGHT_EL
end

local function in_gimbal(a)
    local lim = gimbal() - margin()
    return math.abs(a.az) <= lim and math.abs(a.body_el) <= lim
end

-- Jester's voice lines for the hand-over. Only phrase groups that exist as sound files are listed (a missing phrase stalls the task queue).
-- Config.MAV_DONE_VOICE picks the one said when a slew is finished, Config.MAV_TAKEOVER_VOICE the one said when the pilot takes the seeker.
-- 'none' is silent. A list to choose from in the wheel can be built on this table later.
local VOICES = {
    -- NOT on disk (listed in transcripts.csv only, no Temporary/ or sorting/ folder in the sound set, so Say plays nothing): Temporary/dot
    -- ("Your dot"), Temporary/Designated, sorting/Dot. Do not add them back.
    gotit      = { 'misc/copy',             'You got it / Got it / Copy / Roger' },
    captured   = { 'Lantirn/captured',      'Captured / Okay, captured' },
    centered   = { 'Lantirn/werecentered',  "We're centered / Dead on center line" },
    roger      = { 'misc/roger',            'Roger / Roger that / You got it' },
    wilco      = { 'misc/wilco',            'Wilco / Got it' },
}
Maverick.Voices = VOICES

local function say_voice(key, default)
    if Config.MAV_HANDOVER_CALL == false then return end
    local name = Config[key] or default
    if name == 'none' then return end
    local v = VOICES[name] or VOICES[default]
    if not v then return end
    pcall(function() GetJester():AddTask(Task:new():Say(v[1])) end)
end

-- The one running slew: st.job = { phase = 'cage'|'slew', t0, last_t, slot, entry, sx, sy, dx, dy, still, cage_only }
local function stop_job(why, quiet)
    local job = st.job
    if not job then return end
    stick(0, 0)
    local locked = false
    if job.trig and Config.MAV_HOLD_TRIGGER ~= true and not st.hold and not st.train then
        trigger(0)              -- releasing the half-pressed trigger makes the Maverick try a contrast / IR lock on what is under the crosshair
        locked = true
    end
    if locked then
        -- Diagnostic (Oct 21 2026): where every Strike List slot is relative to the boresight at the moment of the release, so a seeker jump
        -- after the release can be matched with a vehicle from the crosshair position in a screenshot.
        pcall(function()
            local T = package.loaded['agplus.Targets']
            if not (T and T.Slots) then return end
            local slots = T.Slots()
            for j = 1, (T.N or 6) do
                local e = slots[j]
                local a = e and Maverick.Aim(e)
                if a then
                    AGLog.Detail('mav-release slot %d %s: az %+.2f el %+.2f (above boresight), %.1f NM%s', j, tostring(e.alias), a.az, a.el, a.rng / 1852,
                        (job.slot == j) and '  <- this slew' or '')
                end
            end
        end)
    end
    st.job = nil
    st.pos_t = Util.Now()
    AGLog.Info('mav: slew ended (%s) after %.1f s, seeker at az %+.2f el %+.2f (dead reckoned)%s', tostring(why), st.pos_t - job.t0,
        st.pos and st.pos.az or 0, st.pos and st.pos.el or 0, locked and ', trigger released = lock attempt, seeker position now unknown' or '')
    -- Where the seeker was left (until a lock it stays fixed to the airframe, Oct 21 2026), so a long press can retry from here without a recage.
    -- az / el are the believed position (target direction); the seeker itself sits at that plus the correction that was applied.
    if job.arrived and st.pos then
        if job.tcx ~= 0 or job.tcy ~= 0 then      -- the seeker was steered to target + correction, so it really points at the target
            st.pos.az, st.pos.el = st.pos.az - (job.tcx or 0), st.pos.el - (job.tcy or 0)
        end
        st.rel = { az = st.pos.az, el = st.pos.el, tcx = job.tcx or 0, tcy = job.tcy or 0, slot = job.slot, t = st.pos_t }
    end
    if locked then st.pos = nil end      -- a locked seeker tracks the target, so the dead reckoning no longer holds
    if not quiet then Dbg.Notice('Maverick - ' .. tostring(why), 4) end
    -- Hand-over (Oct 21 2026): Jester's part ends at the target; the call (Config.MAV_DONE_VOICE, "Your dot" by default) tells the pilot to
    -- finish the slew and lock if the seeker did not lock.
    if job.arrived and not quiet and not st.train then
        say_voice('MAV_DONE_VOICE', 'captured')
    end
end

local function start_job(slot, entry, cage_only, quick, off)
    local now = Util.Now()
    st.variant = Maverick.Variant()
    -- Every slew starts from a cage (the trim was measured from a cage, and a chained slew carries the last slew's error).
    -- A fresh seeker (mission start, after a rifle, after a Cage Seeker) is caged already, so the first slew starts at once with no cage wait
    -- (Oct 21 2026). The pilot taking the seeker with ARR clears it. Config.MAV_ASSUME_CAGED = false always cages first.
    local fresh = st.fresh and not cage_only and not quick and Config.MAV_ASSUME_CAGED ~= false
    st.fresh = false
    st.arr_tap = nil
    -- A fresh missile still has its cap on, and only a full action on the WSO stick trigger takes it off (user, Oct 22 2026: the A/B cap never came
    -- off, because a fresh seeker skipped every press). So Jester takes the cap off first, with no half press, then slews from the (caged) boresight.
    local pop = fresh and not st.dome_open
    if pop then fresh = false end
    if fresh then
        st.pos, st.pos_t = { az = 0, el = 0 }, now
        AGLog.Info('mav: the seeker is assumed caged (fresh missile or just caged), no cage wait')
    end
    local need_cage = (not quick) and (not fresh) and true
    if pop then st.pos, st.pos_t = { az = 0, el = 0 }, now AGLog.Info('mav: fresh missile, taking the cap off first (trigger full action)') end
    local pilot_cage = cage_only and st.pilot_cage_next
    local pilot_real = cage_only and st.pilot_cage_real      -- the pilot's own cage press (not Jester's end-of-search cage)
    st.pilot_cage_next, st.pilot_cage_real = nil, nil
    local dist = 0
    if st.pos then dist = math.max(math.abs(st.pos.az), math.abs(st.pos.el)) end
    -- A known position (the seeker was held, not locked) is caged for 1.5 s plus 0.12 s per degree. After a lock attempt the position is unknown
    -- and the locked seeker may be anywhere in the gimbal, so it gets Config.MAV_CAGE_UNKNOWN_S (8.5; 5.5 left slews that followed a far lock
    -- short, Oct 21 2026).
    local wait = need_cage and (st.pos and (1.5 + 0.12 * dist) or (Config.MAV_CAGE_UNKNOWN_S or 6.5)) or 0      -- 5 s for the cage to return (user measured about 4 s from a corner) + the 1.5 s half press before the slew
    -- The pilot's own cage press already started the cage, so Jester's finishing cage only has to cover the cage time (a corner takes about 4 s,
    -- user measured) and nothing more: Config.MAV_PILOT_CAGE_S (4.5).
    if pilot_cage and need_cage then wait = Config.MAV_PILOT_CAGE_S or 4.5 end
    st.job = { phase = need_cage and 'cage' or 'slew', t0 = now, last_t = now, slot = slot, entry = entry, sx = 0, sy = 0,
        dx = 0, dy = 0, still = 0, cage_only = cage_only, pilot_cage = pilot_cage, skip_cage = (pilot_real and is_ir()) or nil, wait = wait, stage = 0, quick = quick, off = off }
    st.nudge, st.nq = nil, {}
    if not need_cage and st.pos then st.job.p0 = { az = st.pos.az, el = st.pos.el } end
    if need_cage then
        -- Unlock first: the half press of the hand control trigger that follows a lock in the WSO seat breaks the lock, then the cage goes in
        -- Config.MAV_UNLOCK_S (1.0) later. Cage with the lock still held made the seeker jump to another vehicle. The trigger stays half pressed
        -- through the cage and the slew, except for the short click released after Config.MAV_UNLOCK_HOLD_S.
        local u = (not pop) and (not cage_only or pilot_cage or is_ir()) and (Config.MAV_UNLOCK_S or 1.0) or 0      -- the pilot-cage finish uses the same unlock gap: the cage click in the same frame as the trigger release did nothing (21 Oct 2026 test)
        st.job.u = u
        st.job.wait = wait + u
        if u > 0 then
            trigger(0.5)
            st.job.trig = true
        else
            st.job.click = cage_click_s()
            cage_btn(1)
        end
        if not pop then st.pos = nil end
        AGLog.Info('mav: slew start slot=%s, caging first (wait %.1f s)%s', tostring(slot), wait + u, u > 0 and ', trigger half press first to break the lock' or '')
    else
        trigger(0.5)
        st.job.trig = true
        st.job.stage = 3
        AGLog.Info('mav: slew start slot=%s from dead-reckoned az %+.2f el %+.2f', tostring(slot), st.pos.az, st.pos.el)
    end
end

-- one control axis: 0, +1 or -1. Hysteresis: starts moving beyond Config.MAV_STEER_START_DEG (0.12), stops inside MAV_STEER_STOP_DEG (0.04).
-- One tick at 0.5 stick moves the seeker about 0.08 deg, so the stop band is about half a tick.
local function ctl(prev, err, tight)
    local a = math.abs(err)
    local on, off = Config.MAV_STEER_START_DEG or 0.12, Config.MAV_STEER_STOP_DEG or 0.04
    -- A quick retry nudges by 0.07 deg, which the normal 0.12 start band swallows (Oct 21 2026: the four nudges did not move the seeker).
    if tight then on, off = 0.03, 0.015 end
    if prev ~= 0 and (err > 0) == (prev > 0) then
        if a > off then return err > 0 and 1 or -1 end
        return 0
    end
    if a > on then return err > 0 and 1 or -1 end
    return 0
end

-- Full stick (1.0, about 3.8 deg/s) while the target is far; half stick (0.5, about 0.94 deg/s) for the last stretch. The full-stick zone ends
-- Config.MAV_FAST_ZONE_DEG (2.0) plus what one frame moves the seeker from the target. Config.MAV_FAST = false keeps half stick throughout.
local function ctl2(prev, err, dt, tight)
    local dir = ctl(prev, err, tight)
    if dir == 0 then return 0, 0 end
    -- tight (quick retry): a gentle stick for the last 0.4 deg, so one frame moves the seeker only ~0.012 deg and the 0.015 stop band holds
    if tight and math.abs(err) < 0.4 then return dir, Config.MAV_BUMP_STICK or 0.25 end
    local fs = fast_stick()
    local fast_from = (Config.MAV_FAST_ZONE_DEG or 2.0) + rate_at(fs) * math.min(dt, 0.3)
    if Config.MAV_FAST ~= false and fs > STICK and math.abs(err) > fast_from then return dir, fs end
    return dir, STICK
end

--------------------------------------------------------------------------------
-- Seeker trim: samples { Tx, Ty = slew travel (deg, right / up), Bx, By = player bump needed afterwards (deg, right / up) }
--------------------------------------------------------------------------------

local TRIM_FILE = ((Config.PAYLOAD_FEED or ''):gsub('agplus_payload%.txt$', 'mavtrim.txt'))
local function empty_fit() return { x = { a = 0, b = 0, c = 0 }, y = { a = 0, b = 0, c = 0 }, tx = { 0, 0 }, ty = { 0, 0 } } end
-- Samples are kept per seeker (Oct 21 2026): s.k = 'TV-A' / 'TV-B' (separate sets; the old 'TV' lines load as TV-B) or 'IR-Wide' / 'IR-Narrow' (D and G share the seeker). Each key has its own fit,
-- its own samples in mavtrim.txt (lines 'K <key> Tx Ty Bx By slot rng alias'; the old unkeyed 'S' lines are ignored) and its own Clear Trim.
local trim = { samples = {}, fits = {} }
Maverick.Trim = trim

local function trim_key()
    local v = st.variant or Maverick.Variant()
    local p = v and PROFILES[v]
    if p and p.seeker == 'IR' then return 'IR-' .. (FOVS[st.fov] or 'Narrow') end
    return v and ('TV-' .. v) or '?'      -- A and B have separate sets (user, Oct 22 2026); the old 'TV' lines are read as the B's
end
local function cur_fit() return trim.fits[trim_key()] or empty_fit() end
local function cur_samples()
    local k, out = trim_key(), {}
    for _, q in ipairs(trim.samples) do if q.k == k then out[#out + 1] = q end end
    return out
end

-- Per axis the bump the player needed is fitted as  a + b * (travel on this axis) + c * (travel on the other axis).  Measured Oct 21 2026: moving
-- the seeker left left it too HIGH by about 0.008 deg per degree of travel (a slight tilt of the slew axes), so the other-axis term matters.
-- A term is kept only when it changes the bump by Config.MAV_TRIM_SLOPE_MIN_DEG (0.05) or more across the travel the samples cover, and only
-- with 2 more samples than parameters; otherwise the mean bump is a plain offset. Travel is limited to the range the samples cover.
local function lsq(rows, ys)
    local k = #rows[1]
    local A, B = {}, {}
    for i = 1, k do
        A[i], B[i] = {}, 0
        for j = 1, k do A[i][j] = 0 end
    end
    for r, row in ipairs(rows) do
        for i = 1, k do
            B[i] = B[i] + row[i] * ys[r]
            for j = 1, k do A[i][j] = A[i][j] + row[i] * row[j] end
        end
    end
    for c = 1, k do
        local piv = c
        for r = c + 1, k do
            if math.abs(A[r][c]) > math.abs(A[piv][c]) then piv = r end
        end
        if math.abs(A[piv][c]) < 1e-9 then return nil end
        A[c], A[piv] = A[piv], A[c]
        B[c], B[piv] = B[piv], B[c]
        for r = c + 1, k do
            local f = A[r][c] / A[c][c]
            for j = c, k do A[r][j] = A[r][j] - f * A[c][j] end
            B[r] = B[r] - f * B[c]
        end
    end
    local x = {}
    for i = k, 1, -1 do
        local sum = B[i]
        for j = i + 1, k do sum = sum - A[i][j] * x[j] end
        x[i] = sum / A[i][i]
    end
    return x
end

local function sdev(S, key)
    local n, m = #S, 0
    for _, q in ipairs(S) do m = m + q[key] end
    m = m / n
    local v = 0
    for _, q in ipairs(S) do v = v + (q[key] - m) ^ 2 end
    return math.sqrt(v / n)
end

local function fit_axis(S, own, oth, bkey)
    local n = #S
    local res = { a = 0, b = 0, c = 0 }
    if n == 0 then return res end
    local ys, mean = {}, 0
    for i, q in ipairs(S) do ys[i] = q[bkey] mean = mean + q[bkey] end
    mean = mean / n
    res.a = clamp(mean, -3, 3)
    local minfx = Config.MAV_TRIM_SLOPE_MIN_DEG or 0.05
    local active = { 'b', 'c' }
    while #active > 0 and n >= #active + 3 do
        local rows = {}
        for i, q in ipairs(S) do
            local row = { 1 }
            for _, t in ipairs(active) do row[#row + 1] = (t == 'b') and q[own] or q[oth] end
            rows[i] = row
        end
        local x = lsq(rows, ys)
        if not x then
            table.remove(active)
        else
            local worst, worst_fx = nil, math.huge
            for i, t in ipairs(active) do
                local fx = math.abs(x[i + 1]) * sdev(S, (t == 'b') and own or oth)
                if fx < worst_fx then worst, worst_fx = i, fx end
            end
            if worst_fx < minfx then
                table.remove(active, worst)
            else
                res = { a = clamp(x[1], -3, 3), b = 0, c = 0 }
                for i, t in ipairs(active) do res[t] = clamp(x[i + 1], -0.3, 0.3) end
                break
            end
        end
    end
    return res
end

-- Gimbal geometry (Oct 21 2026, fits all 33 training samples with no free parameters: residual sd 0.04 / 0.05 deg, down from 0.07 / 0.09).
-- The seeker boresight sits 2.58 deg below the datum and the AZIMUTH gimbal is the outer one, so a travel (right, up) measured from the cage
-- position is not the same as a gimbal angle pair once the seeker is off to one side: elevation needs more correction the further it swings in
-- azimuth. Returns the correction (deg, right / up) to add to a travel (tx, ty) so the seeker looks at the intended direction.
local function geom_corr(tx, ty)
    if Config.MAV_GEOMETRY == false then return 0, 0 end
    local d = math.rad(-BORESIGHT_EL)
    local az, el = math.rad(tx), math.rad(ty + BORESIGHT_EL)
    local vx, vy, vz = math.cos(el) * math.cos(az), math.cos(el) * math.sin(az), math.sin(el)
    local xs = vx * math.cos(d) - vz * math.sin(d)
    local zs = vx * math.sin(d) + vz * math.cos(d)
    return math.deg(math.atan2(vy, xs)) - tx, math.deg(math.asin(clamp(zs, -1, 1))) - ty
end

local function refit_key(k)
    local S = {}
    for _, q in ipairs(trim.samples) do if q.k == k then S[#S + 1] = q end end
    local f = empty_fit()
    trim.fits[k] = f
    for _, q in ipairs(S) do
        local gx, gy = geom_corr(q.Tx, q.Ty)
        q.Rx, q.Ry = q.Bx - gx, q.By - gy      -- what the geometry does not explain
    end
    f.x = fit_axis(S, 'Tx', 'Ty', 'Rx')
    f.y = fit_axis(S, 'Ty', 'Tx', 'Ry')
    if #S > 0 then
        f.tx, f.ty = { math.huge, -math.huge }, { math.huge, -math.huge }
        for _, q in ipairs(S) do
            f.tx[1], f.tx[2] = math.min(f.tx[1], q.Tx), math.max(f.tx[2], q.Tx)
            f.ty[1], f.ty[2] = math.min(f.ty[1], q.Ty), math.max(f.ty[2], q.Ty)
        end
    end
    AGLog.Info('mav-trim: [%s] %d samples. Right/left bump = %+.3f %+.4f*Tx %+.4f*Ty, up/down bump = %+.3f %+.4f*Ty %+.4f*Tx (travel limited to Tx %.1f..%.1f, Ty %.1f..%.1f)',
        k, #S, f.x.a, f.x.b, f.x.c, f.y.a, f.y.b, f.y.c, f.tx[1], f.tx[2], f.ty[1], f.ty[2])
end

local function refit()
    local keys, seen = {}, {}
    for _, q in ipairs(trim.samples) do if not seen[q.k] then seen[q.k] = true keys[#keys + 1] = q.k end end
    trim.fits = {}
    for _, k in ipairs(keys) do refit_key(k) end
end

local function trim_load()
    if TRIM_FILE == '' then return end
    local text
    pcall(function()
        local fh = io.open(TRIM_FILE, 'r')
        if fh then text = fh:read('*a') fh:close() end
    end)
    if not text then return end
    for k, tx, ty, bx, by, slot, rng, alias in text:gmatch('K (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) ([^\r\n]*)') do
        if k == 'TV' then k = 'TV-B' end      -- the old A/B samples were trained on the B (user, Oct 22 2026)
        local s = { k = k, Tx = tonumber(tx), Ty = tonumber(ty), Bx = tonumber(bx), By = tonumber(by), slot = slot, rng = tonumber(rng), alias = alias }
        if s.Tx and s.Ty and s.Bx and s.By then trim.samples[#trim.samples + 1] = s end
    end
    if #trim.samples > 0 then
        refit()
        if Config.MAV_TRIM_START_ON ~= false then st.trim_on = true end      -- a reload (Shift+R) must not silently drop the trim
    end
end

local function trim_append(s)
    if TRIM_FILE == '' then return end
    pcall(function()
        local fh = io.open(TRIM_FILE, 'a')
        if fh then
            fh:write(string.format('K %s %.3f %.3f %.3f %.3f %s %.2f %s\n', s.k, s.Tx, s.Ty, s.Bx, s.By, tostring(s.slot), s.rng or 0, tostring(s.alias or '?')))
            fh:close()
        end
    end)
end

local function trim_clear()
    local k, keep = trim_key(), {}
    for _, q in ipairs(trim.samples) do if q.k ~= k then keep[#keep + 1] = q end end
    trim.samples = keep
    if TRIM_FILE ~= '' then
        pcall(function()
            local fh = io.open(TRIM_FILE, 'w')
            if fh then fh:close() end
        end)
        for _, q in ipairs(keep) do trim_append(q) end
    end
    refit()
    AGLog.Info('mav-trim: cleared [%s], %d samples of other seekers kept', k, #keep)
end

-- the correction added to a slew's target (deg, right / up); none while training or when the trim is off
local function trim_corr(tx, ty)
    if not st.trim_on then return 0, 0 end
    local gx, gy = geom_corr(tx, ty)
    local f = trim.fits[trim_key()]
    if not f then return gx, gy end
    local x, y = clamp(tx, f.tx[1], f.tx[2]), clamp(ty, f.ty[1], f.ty[2])
    return gx + f.x.a + f.x.b * x + f.x.c * y, gy + f.y.a + f.y.b * y + f.y.c * x
end

-- One axis while tracking: the stick (signed, + = increasing angle) for the wanted rate  w = target rate + Kp x error, and w itself.
-- Continuous (Oct 21 2026, after the 0.5 pulses of the last build left the seeker jerking and behind the target): the rate goes with the square
-- of the stick (measured at 0.5 and 1.0, and the slow rate tests at 0.25), so stick = sqrt(|w| / 3.75), never below 0.25 (0.23 deg/s). The stick
-- stays off while the error is under 'stop' deg and the wanted rate under 0.05 deg/s. 'prev' is not used any more.
-- Smallest stick the tracking uses. It was a flat 0.25, which is 0.23 deg/s on the narrow / TV seekers but 0.47 deg/s on the wide D/G (twice the rate
-- constant): against a 0.02 deg stop band that chattered left and right (user, Oct 22 2026, wide FOV probe trim). Now the same minimum RATE
-- (Config.MAV_MIN_RATE, 0.23 deg/s) for every seeker, never above 0.25 and never under 0.12.
local function min_stick()
    local k = rate_k()
    local sm = ((Config.MAV_MIN_RATE or 0.23) / k) ^ (1 / rate_p())
    return clamp(sm, 0.12, 0.25)
end

local function track_axis(err, rf, stop, prev)
    local w = rf + (Config.MAV_TRACK_KP or 2.0) * err
    local a = math.abs(w)
    if a < 0.05 and math.abs(err) < stop then return 0, w end
    local k = rate_k()
    local smax = fast_stick()
    local s = (math.min(a, rate_at(smax)) / k) ^ (1 / rate_p())
    local smin = min_stick()
    if s < smin then s = smin end
    return (w > 0) and s or -s, w
end

-- From here the seeker stays on the target: Lock mode releases the trigger when the error is small, Hold mode tracks until a press.
local function begin_track(job, a, ex, ey, now, why)
    local e = job.entry
    local n = tostring(job.slot)
    AGLog.Info('mav: %s slot=%s seeker az %+.2f el %+.2f, target az %+.2f el %+.2f (error %+.2f %+.2f), target rate (%+.2f, %+.2f) deg/s, %.1f NM, in %.1f s',
        why, n, st.pos.az, st.pos.el, a.az, a.el, ex, ey, job.rf_az or 0, job.rf_el or 0, a.rng / 1852, now - job.t0)
    job.arrived = true
    job.tracking = true
    job.track_t0 = now
    job.settle_t = nil
    job.sx, job.sy = 0, 0
    Dbg.Notice(string.format('Maverick - Slot %s %s On Target, Tracking', n, tostring(e and e.alias or '?')), 3)
end

-- Seeker search (Oct 22 2026). A spiral from the boresight, flown in the seeker's own angles (az right, el above the boresight), so it does not depend
-- on the terrain or the heading. Jester slews along it (the stick tracks a moving set point) and every hostile unit from the unit feed that comes into the
-- seeker picture, inside the detection range for this seeker and not hidden by terrain, joins the target list. It stays inside the gimbal limits.
-- Config (all optional): MAV_SEARCH_MAX_DEG (20, spiral radius cap), MAV_SEARCH_S (180, time cap), MAV_SEARCH_SPEED (3.0 deg/s along the spiral),
-- MAV_SEARCH_GAP (0.8 picture widths between turns), MAV_FOV_WIDE_DEG (4.46, measured) and MAV_FOV_NARROW_DEG (2.25, measured), MAV_SEARCH_DWELL_S (0.3),
-- MAV_SEE_SCALE_TV (0.5) and MAV_SEE_SCALE_IR (0.6): the share of the pod's see range per category (PAVE_SEE_RANGE_M); MAV_SEE_RANGE_TV_M and
-- MAV_SEE_RANGE_IR_M can replace the scaling with a table by category (aa, armor, cv, soft, inf, struct) in meters.
local end_search
local cant_do_now
local function search_range_fn(variant, narrow)
    local ir = PROFILES[variant] and PROFILES[variant].seeker == 'IR'
    local tbl = ir and Config.MAV_SEE_RANGE_IR_M or Config.MAV_SEE_RANGE_TV_M
    local pod = Config.PAVE_SEE_RANGE_M or { aa = 30000, armor = 30000, cv = 30000, soft = 26000, inf = 20000, struct = 30000 }
    -- Oct 21 2026, flown: large units are seen at about 12 NM (22224 m) with the TV seekers, so 0.74 of the pod's 30000 m (infantry kept at 0.62).
    -- The IR seeker sees large units at about 8 NM wide (0.49 of the pod's range, infantry scaled the same) and as far as the pod when narrow (1.0).
    local scale, inf_scale
    if ir and narrow then
        scale = Config.MAV_SEE_SCALE_IR_NARROW or 1.0
        inf_scale = Config.MAV_SEE_SCALE_INF_NARROW or scale
    elseif ir then
        scale = Config.MAV_SEE_SCALE_IR or 0.494
        inf_scale = Config.MAV_SEE_SCALE_INF_IR or scale
    else
        scale = Config.MAV_SEE_SCALE_TV or 0.74
        inf_scale = Config.MAV_SEE_SCALE_INF or 0.62
    end
    return function(cat)
        if tbl and tbl[cat] then return tbl[cat] end
        return (pod[cat] or 15000) * ((cat == 'inf') and inf_scale or scale)
    end
end

-- The world direction (map coordinates x north, y up, z east, unit vector) of a direction given in the aircraft frame (az right of the nose, el
-- above the datum line): the inverse of Pave.ToBody.
local function from_body(az, el, heading, pitch, bank)
    local R = math.rad
    local a, e = R(az), R(el)
    local x2, y3, z3 = math.cos(e) * math.cos(a), math.cos(e) * math.sin(a), -math.sin(e)
    local psi, th, ph = R(heading), R(pitch), R(bank)
    local y1 = math.cos(ph) * y3 - math.sin(ph) * z3
    local z2 = math.sin(ph) * y3 + math.cos(ph) * z3
    local x1 = math.cos(th) * x2 + math.sin(th) * z2
    local d = -math.sin(th) * x2 + math.cos(th) * z2
    local n = math.cos(psi) * x1 - math.sin(psi) * y1
    local east = math.sin(psi) * x1 + math.cos(psi) * y1
    return { x = n, y = -d, z = east }
end

local function search_scan(sr, now, Search)
    -- What the seeker sees now (also while the pattern is being set up: every unit in view from the moment the seeker is on the boresight).
    local Lk = (Search and Search.MavScan and now - (sr.scan_t or -1) >= 0.2) and Pave.ReadLook() or nil
    if Lk then
        sr.scan_t = now
        local seen_now = {}
        local list = Search.MavScan(function(e) return Maverick.Aim(e, Lk) end, st.pos.az, st.pos.el, sr.fov * 0.5, sr.range_fn)
        for _, c in ipairs(list) do
            if not sr.seen[c.id] then
                seen_now[c.id] = true
                sr.in_view[c.id] = sr.in_view[c.id] or now
                if now - sr.in_view[c.id] >= (Config.MAV_SEARCH_DWELL_S or 0.3) then
                    sr.seen[c.id] = true
                    sr.found = sr.found + 1
                    local nm = Search.Pretty and Search.Pretty(c.u.name) or tostring(c.u.name)
                    Dbg.Notice('Spotted - ' .. nm, 4)
                    AGLog.Info('mav: search spotted %s at %.1f NM, seeker az %+.1f el %+.1f, after %.0f s (%d found)', nm, c.rng / 1852, st.pos.az, st.pos.el, now - sr.t0, sr.found)
                    if Search.AddSpotted then pcall(Search.AddSpotted, c.u) end
                end
            end
        end
        for id in pairs(sr.in_view) do if not seen_now[id] then sr.in_view[id] = nil end end
    end
end

local function search_tick(job, now, dt, lo, hi, G)
    local sr = job.search
    local Search = package.loaded['agplus.PaveSearch']
    if Search and Search.TouchFeed then Search.TouchFeed(3) end
    if not sr.t0 then
        sr.t0, sr.th = now, 0
        sr.R = math.min(Config.MAV_SEARCH_MAX_DEG or 20, G - margin() - 0.5, math.min(-lo, hi) - margin() - 0.5)
        local variant = sr.variant
        local ir_v = PROFILES[variant] and PROFILES[variant].seeker == 'IR'
        local narrow = (variant == 'A' or variant == 'B') or (ir_v and FOVS[st.fov] == 'Narrow')
        -- The D/G search runs in NARROW (longer range, finer picture): a full press of the WSO stick trigger with the hand control half action held
        -- switches the FOV, and the FOV the pilot had is put back when the seeker has been caged again (st.restore_fov, see fov_restore_tick).
        if ir_v and not narrow then
            sr.restore_fov = st.fov
            st.fov = 2
            narrow = true
            -- With the cap still on, the first full action only takes it off: the FOV press has to come after it.
            sr.press_n = st.dome_open and 1 or 2
            AGLog.Info('mav: search: FOV Wide -> Narrow for the search, %d press(es) (cap %s), back to Wide after the cage', sr.press_n, st.dome_open and 'off' or 'on')
            Dbg.Notice('Maverick FOV: Narrow (Search)', 3)
        end      -- the A and B are the same seeker with one picture; the FOV menu is for the D and G
        if variant == 'A' or variant == 'B' then sr.fov = Config['MAV_FOV_' .. variant .. '_DEG'] or Config.MAV_FOV_B_DEG or 2.26      -- measured Oct 21 2026: 2.24 wide x 2.28 high
        else sr.fov = narrow and (Config.MAV_FOV_NARROW_DEG or 2.25) or (Config.MAV_FOV_WIDE_DEG or 4.46) end      -- D/G probe, Oct 22 2026: narrow 2.20 x 2.30, wide 4.40 x 4.52
        sr.gap = (Config.MAV_SEARCH_GAP or 0.8) * sr.fov
        sr.range_fn = search_range_fn(variant, narrow)
        sr.seen, sr.in_view, sr.found = {}, {}, 0
        -- The pattern is held on a fixed point of the terrain (Oct 22 2026): the point where the boresight line meets the ground when the search
        -- starts. The spiral is still flown in the seeker's own angles, but round that point, so it stays over the same ground as the aircraft moves.
        -- No terrain answer = the pattern stays on the boresight as before.
        sr.anchor_wait = true
        local Lr = Pave.ReadLook()
        if sr.anchor then
            sr.anchor_wait = false
        elseif Lr and Search and Search.Ray and Config.MAV_SEARCH_ANCHOR ~= false then
            local dir = from_body(0, BORESIGHT_EL, Lr.self.heading, Lr.self.pitch, Lr.self.bank)
            Search.Ray({ x = Lr.self.x, y = Lr.self.y, z = Lr.self.z }, dir, function(hit)
                sr.anchor_wait = false
                if hit then
                    sr.anchor = { id = -1, x = hit.x, y = hit.y, z = hit.z }
                    AGLog.Info('mav: search anchored on the ground %.1f NM ahead of the boresight', (hit.dist or 0) / 1852)
                else
                    AGLog.Info('mav: search: the boresight meets no ground, the pattern stays on the boresight')
                end
            end)
        else
            sr.anchor_wait = false
        end
        AGLog.Info('mav: search started: variant %s, picture %.1f deg, turns %.1f deg apart, radius %.1f deg, time cap %d s', tostring(variant), sr.fov, sr.gap, sr.R, Config.MAV_SEARCH_S or 360)
    end
    if not sr.ending and now - sr.t0 >= (Config.MAV_SEARCH_S or 360) then end_search('Search Time Is Up') return end
    if sr.press_t then
        if now - sr.press_t >= 0.4 then
            cage_btn(0)
            sr.press_t = nil
            sr.press_n = (sr.press_n or 1) - 1
            sr.hold_until = now + 0.6
        end
    elseif (sr.press_n or 0) > 0 and not (sr.hold_until and now < sr.hold_until) then
        cage_btn(1)
        sr.press_t = now
    end
    if sr.ending and not sr.press_t and (sr.press_n or 0) <= 0 and not (sr.hold_until and now < sr.hold_until) then
        local why = sr.ending
        sr.ending = nil
        sr.fov_done = true
        st.fov = sr.restore_fov or st.fov
        AGLog.Info('mav: FOV back to %s before the cage (search ended)', FOVS[st.fov])
        Dbg.Notice('Maverick FOV: ' .. FOVS[st.fov], 3)
        sr.restore_fov = nil
        local S = package.loaded['agplus.PaveSearch']
        if S and S.RefreshMenu then pcall(S.RefreshMenu) else pcall(Menu.Rebuild) end
        end_search(why)
        return
    end
    if sr.press_t or (sr.press_n or 0) > 0 or sr.anchor_wait or (sr.hold_until and now < sr.hold_until) then
        job.sx, job.sy = 0, 0
        stick(0, 0)
        search_scan(sr, now, Search)
        return
    end
    -- the fixed ground point in the seeker's angles, and the pattern round it
    -- Smooth (Oct 22 2026): the aircraft data arrives in steps, so differencing it every tick made the set point jump. Each NEW sample gives the
    -- ground point's angles; between samples they are extrapolated with a low-passed angular velocity.
    local ox, oy = 0, 0
    local avx, avy = 0, 0
    if sr.anchor then
        local L = Pave.ReadLook()
        if L and L.view_t ~= sr.lvt then
            local a = Maverick.Aim(sr.anchor, L)
            if a then
                if sr.s_t and now - sr.s_t > 0.02 then
                    local k = clamp((now - sr.s_t) / 0.4, 0, 1)
                    sr.sv_x = (sr.sv_x or 0) + ((a.az - sr.s_x) / (now - sr.s_t) - (sr.sv_x or 0)) * k
                    sr.sv_y = (sr.sv_y or 0) + ((a.el - sr.s_y) / (now - sr.s_t) - (sr.sv_y or 0)) * k
                end
                sr.lvt, sr.s_t, sr.s_x, sr.s_y = L.view_t, now, a.az, a.el
            end
        end
        if sr.s_t then
            local dtp = clamp(now - sr.s_t, 0, 0.6)
            avx, avy = sr.sv_x or 0, sr.sv_y or 0
            ox, oy = sr.s_x + avx * dtp, sr.s_y + avy * dtp
            if math.abs(ox) > G - margin() - 0.5 or oy < lo + margin() + 0.5 or oy > hi - margin() - 0.5 then
                end_search('Search Ended - Gimbal Limit')
                return
            end
        end
    end
    -- The set point goes round the spiral at a set speed, but waits whenever the seeker has fallen behind it.
    local r = sr.gap * sr.th / (2 * math.pi)
    local cx, cy = r * math.cos(sr.th), r * math.sin(sr.th)
    local lag = math.sqrt((cx + ox - st.pos.az) ^ 2 + (cy + oy - st.pos.el) ^ 2)
    -- The speed round the spiral fades out smoothly as the seeker falls behind (it was an on / off switch, which made the pattern stop and start).
    local thr = math.max(1.5, sr.gap * 0.6)
    local adv = clamp((thr - lag) / (0.5 * thr), 0, 1)
    local v = (Config.MAV_SEARCH_SPEED or 1.5) * adv
    local vx, vy = 0, 0
    if adv > 0 then
        local rr = math.max(r, sr.gap * 0.5)
        local thd = v / rr                       -- angle rate (rad/s)
        sr.th = sr.th + thd * dt
        local r2 = sr.gap * sr.th / (2 * math.pi)
        local rd = sr.gap / (2 * math.pi) * thd  -- radius rate
        -- velocity of the set point (feed forward), worked out from the spiral itself
        vx = rd * math.cos(sr.th) - r2 * math.sin(sr.th) * thd
        vy = rd * math.sin(sr.th) + r2 * math.cos(sr.th) * thd
        cx, cy = r2 * math.cos(sr.th), r2 * math.sin(sr.th)
        r = r2
    end
    if r > sr.R then end_search('Search Complete') return end
    local ex, ey = clamp(cx + ox, -(G - margin()), G - margin()) - st.pos.az, clamp(cy + oy, lo + margin(), hi - margin()) - st.pos.el
    local sx, _ = track_axis(ex, vx + avx, 0.0, 0)
    local sy, _ = track_axis(ey, vy + avy, 0.0, 0)
    if sx * sx + sy * sy > 1.0 and sx ~= 0 and sy ~= 0 then
        local f = 1 / math.sqrt(sx * sx + sy * sy)
        sx, sy = sx * f, sy * f
    end
    -- a gentle low-pass on the stick (time constant 0.12 s) so a change of command is a ramp, not a step
    local kf = clamp(dt / 0.12, 0, 1)
    sr.fx = (sr.fx or sx) + (sx - (sr.fx or sx)) * kf
    sr.fy = (sr.fy or sy) + (sy - (sr.fy or sy)) * kf
    sx, sy = sr.fx, sr.fy
    job.sx, job.sy = sx, -sy      -- a negative stick Y moves the seeker UP
    stick(job.sx, job.sy)
    search_scan(sr, now, Search)
    if now - (sr.log or -9) >= 5 then
        sr.log = now
        AGLog.Info('mav: search %.0f s, seeker az %+.1f el %+.1f, set point az %+.1f el %+.1f, radius %.1f of %.1f deg, %d found', now - sr.t0, st.pos.az, st.pos.el, cx, cy, r, sr.R, sr.found)
        -- Diagnostic (Oct 22 2026): the three closest units to the seeker line of sight with no range limit, to see why a unit is not spotted.
        local Lk2 = (Config.MAV_SEARCH_DEBUG and Search and Search.MavScan and Pave.ReadLook()) or nil
        if Lk2 then
            local all = Search.MavScan(function(e) return Maverick.Aim(e, Lk2) end, st.pos.az, st.pos.el, 90, function() return 1e9 end)
            local rows = {}
            for _, c in ipairs(all) do
                local a2 = Maverick.Aim({ id = c.id, x = c.u.x, y = c.u.y, z = c.u.z }, Lk2)
                if a2 then rows[#rows + 1] = { n = tostring(c.u.name), d = math.sqrt((a2.az - st.pos.az) ^ 2 + (a2.el - st.pos.el) ^ 2), az = a2.az, el = a2.el, rng = c.rng, lim = sr.range_fn(c.u.cat) } end
            end
            table.sort(rows, function(x, y) return x.d < y.d end)
            AGLog.Info('mav: search sees %d units in line of sight (picture %.1f deg, FOV menu %s)', #rows, sr.fov, FOVS[st.fov])
            for i = 1, math.min(3, #rows) do
                local q = rows[i]
                AGLog.Info('mav:   nearest %d: %s at az %+.1f el %+.1f (%.1f deg from the seeker), %.1f NM, range limit %.1f NM', i, q.n, q.az, q.el, q.d, q.rng / 1852, q.lim / 1852)
            end
        end
    end
    Dbg.NoticeStatus(string.format('Searching - Found %d - Double Press To Cancel', sr.found))
end

-- FOV probe (Oct 22 2026): measures the seeker picture. Run it in active pause with a stationary target 3 to 5 NM away. Jester centers the seeker on the
-- current Strike List target, then pans it away at 0.25 deg/s along one edge direction; a short press marks the moment the unit reaches the picture edge.
-- Then a ladder: Jester puts the seeker a set offset from the target and asks "is the unit still inside?" (short = inside, double = outside); each answer
-- halves the bracket (Config.MAV_FOVP_BRACKET 0.5 deg either side of the mark) until it is under Config.MAV_FOVP_RES (0.04 deg) and the edge is logged.
-- A long press in the ladder accepts the middle of the bracket; a double press during the first sweep, or the menu item again, ends the probe.
-- Four edges in turn (right, left, up, down): the offsets are the half sizes of the picture. The trigger stays half pressed throughout (no lock attempt).
local FOVP_EDGES = { { 'Right', 1, 0 }, { 'Left', -1, 0 }, { 'Up', 0, 1 }, { 'Down', 0, -1 } }
local fovp_finish

local function fovp_tick(job, now, dt, lo, hi, G)
    local fp = job.fovp
    local Search = package.loaded['agplus.PaveSearch']
    if Search and Search.TouchFeed then Search.TouchFeed(3) end
    local a = Maverick.Aim(fp.entry)
    if not a then fovp_finish('FOV Probe - No Aircraft Data') return end
    local ed = FOVP_EDGES[fp.edge]
    local dx, dy = ed[2], ed[3]
    local rf = 0
    if fp.phase == 'coarse' then
        local sp = Config.MAV_FOVP_SPEED or 0.25
        fp.off = fp.off + sp * dt
        rf = sp
        fp.cur = fp.off
        if fp.off > 12 then fovp_finish('FOV Probe - Edge Not Found') return end
    elseif fp.phase == 'centre' or fp.phase == 'trim' then
        fp.cur = 0
    end
    local az_t = clamp(a.az + fp.tx + fp.cur * dx, -(G - 0.5), G - 0.5)
    local el_t = clamp(a.el + fp.ty + fp.cur * dy, lo + 0.5, hi - 0.5)
    local ex, ey = az_t - st.pos.az, el_t - st.pos.el
    local sx = track_axis(ex, rf * dx, 0.02, 0)
    local sy = track_axis(ey, rf * dy, 0.02, 0)
    if sx * sx + sy * sy > 1.0 and sx ~= 0 and sy ~= 0 then
        local f = 1 / math.sqrt(sx * sx + sy * sy)
        sx, sy = sx * f, sy * f
    end
    job.sx, job.sy = sx, -sy
    stick(job.sx, job.sy)
    local tol = (fp.phase == 'coarse') and 9 or 0.03
    if math.abs(ex) <= tol and math.abs(ey) <= tol then fp.still = fp.still or now else fp.still = nil end
    if fp.phase == 'centre' and fp.still and now - fp.still >= 0.6 then
        if fp.trimmed then
            fp.phase, fp.off, fp.cur = 'coarse', 0, 0
            Dbg.Notice(string.format('FOV Probe - %s Edge: Press When The Unit Touches The Edge', ed[1]), 5)
            AGLog.Info('mav-fovp: %s edge, sweeping at %.2f deg/s from the centered target', ed[1], Config.MAV_FOVP_SPEED or 0.25)
        else
            fp.phase, fp.shown = 'trim', now
            Dbg.Notice(string.format('FOV Probe - Trim For The %s Edge: Double = Pick Direction, Short = Nudge 0.02, Long = Start The Sweep', ed[1]), 6)
        end
    elseif fp.phase == 'trim' and now - fp.shown >= 6 then
        fp.shown = now
        Dbg.Notice(string.format('FOV Probe - Trim Direction %s: Short = Nudge, Double = Next Direction, Long = Start', FOVP_EDGES[fp.tdir][1]), 4)
    elseif fp.phase == 'move' and fp.still and now - fp.still >= 0.5 then
        fp.phase = 'ask'
        fp.asked = now
        fp.shown = now
        Dbg.Notice(string.format('FOV Probe - %s Edge, Offset %.2f: Unit Inside? Short = Inside, Double = Outside, Long = Done', ed[1], fp.cur), 6)
    elseif fp.phase == 'ask' and now - fp.shown >= 4 then
        fp.shown = now
        Dbg.Notice(string.format('FOV Probe - %s Edge: Unit Inside? Short = Inside, Double = Outside, Long = Done', ed[1]), 4)
    end
end

fovp_finish = function(why)
    local job = st.job
    local fp = job and job.fovp
    if not fp then return end
    job.fovp = nil
    stop_job(why, true)
    st.pilot_cage_next = true
    start_job(nil, nil, true)
    st.fovp_on = false
    Dbg.Notice(why, 6)
    AGLog.Info('mav-fovp: %s', why)
end

-- A press while the probe runs. Returns true (the press is used).
local function fovp_press(kind)
    local job = st.job
    local fp = job and job.fovp
    if not fp then return false end
    local ed = FOVP_EDGES[fp.edge]
    local B = Config.MAV_FOVP_BRACKET or 0.5
    local res = Config.MAV_FOVP_RES or 0.04
    local function next_edge()
        fp.edge = fp.edge + 1
        if fp.edge > #FOVP_EDGES then
            local r = fp.res
            local w = (r.Right or 0) + (r.Left or 0)
            local h = (r.Up or 0) + (r.Down or 0)
            local msg = string.format('FOV Probe Done (FOV %s): half sizes right %.2f left %.2f up %.2f down %.2f, picture %.2f wide x %.2f high deg',
                FOVS[st.fov], r.Right or 0, r.Left or 0, r.Up or 0, r.Down or 0, w, h)
            fovp_finish(msg)
            return
        end
        fp.phase, fp.still, fp.trimmed = 'centre', nil, false
        Dbg.Notice(string.format('FOV Probe - %s Edge Done (%.2f deg), Centering For The %s Edge', ed[1], fp.res[ed[1]] or 0, FOVP_EDGES[fp.edge][1]), 5)
    end
    if fp.phase == 'trim' then
        local step = Config.MAV_FOVP_TRIM or 0.02
        if kind == 'DOUBLE' then
            fp.tdir = fp.tdir % #FOVP_EDGES + 1
            Dbg.Notice('FOV Probe - Trim Direction: ' .. FOVP_EDGES[fp.tdir][1], 3)
        elseif kind == 'SHORT' then
            local td = FOVP_EDGES[fp.tdir]
            fp.tx, fp.ty = fp.tx + step * td[2], fp.ty + step * td[3]
            Dbg.Notice(string.format('FOV Probe - Trim %s: Total Right %.2f Up %.2f', td[1], fp.tx, fp.ty), 3)
        else
            fp.trimmed = true
            fp.phase, fp.off, fp.cur, fp.still = 'coarse', 0, 0, nil
            AGLog.Info('mav-fovp: %s edge trim az %.2f el %.2f deg (right, up positive)', ed[1], fp.tx, fp.ty)
            Dbg.Notice(string.format('FOV Probe - Trim Accepted (%.2f, %.2f), %s Edge: Press When The Unit Touches The Edge', fp.tx, fp.ty, ed[1]), 5)
        end
        return true
    end
    if fp.phase == 'coarse' then
        if kind == 'SHORT' then
            local c = fp.off
            fp.lo, fp.hi = math.max(0, c - B), c + B
            fp.cur = (fp.lo + fp.hi) / 2
            fp.phase, fp.still = 'move', nil
            AGLog.Info('mav-fovp: %s edge marked at offset %.2f deg, bracket %.2f to %.2f', ed[1], c, fp.lo, fp.hi)
            Dbg.Notice(string.format('FOV Probe - %s Edge Marked At %.2f, Starting The Ladder', ed[1], c), 4)
        elseif kind == 'DOUBLE' then
            fovp_finish('FOV Probe Canceled')
        end
        return true
    end
    if fp.phase == 'ask' then
        local done = false
        if kind == 'SHORT' then fp.lo = fp.cur
        elseif kind == 'DOUBLE' then fp.hi = fp.cur
        else done = true end
        AGLog.Info('mav-fovp: %s edge, offset %.3f: %s -> bracket %.3f to %.3f', ed[1], fp.cur, kind == 'SHORT' and 'inside' or (kind == 'DOUBLE' and 'outside' or 'accepted'), fp.lo, fp.hi)
        if done or fp.hi - fp.lo <= res then
            fp.res[ed[1]] = (fp.lo + fp.hi) / 2
            AGLog.Info('mav-fovp: %s edge = %.3f deg (bracket %.3f to %.3f)', ed[1], fp.res[ed[1]], fp.lo, fp.hi)
            next_edge()
        else
            fp.cur = (fp.lo + fp.hi) / 2
            fp.phase, fp.still = 'move', nil
        end
        return true
    end
    -- centering or moving: the press waits
    if kind == 'DOUBLE' then fovp_finish('FOV Probe Canceled') end
    return true
end

local function fovp_start()
    local variant = Maverick.Variant()
    if not variant then Dbg.Notice('Maverick - No Mavericks Loaded', 4) cant_do_now() return end
    if not can_steer(variant) then Dbg.Notice('Maverick - FOV Probe Needs Steering For This Variant', 5) cant_do_now() return end
    if st.job then Dbg.Notice('Maverick - Seeker Busy', 3) cant_do_now() return end
    local T = package.loaded['agplus.Targets']
    local slots = T and T.Slots and T.Slots()
    local e = (st.idx > 0 and slots) and slots[st.idx] or nil
    if not e then Dbg.Notice('FOV Probe - Slew To A Strike List Target First (Its Slot Is The Current Target)', 6) cant_do_now() return end
    local Search = package.loaded['agplus.PaveSearch']
    if Search and Search.TouchFeed then Search.TouchFeed(5) end
    start_job(nil, nil, false)
    if st.job then
        st.job.fovp = { entry = e, edge = 1, phase = 'centre', off = 0, cur = 0, res = {}, tx = 0, ty = 0, tdir = 1 }
        st.fovp_on = true
        Dbg.Notice('FOV Probe - Centering On ' .. tostring(e.alias) .. ' (FOV ' .. FOVS[st.fov] .. ')', 5)
        AGLog.Info('mav-fovp: probe started on %s, FOV setting %s, variant %s', tostring(e.alias), FOVS[st.fov], tostring(variant))
    end
end

-- Rate calibration for the D and G (Oct 21 2026). The seeker has no readout, but the D/G picture shows a cross for where the seeker points and elevation lines
-- at -5, -10 and -15 deg (manual). Jester cages, then holds the stick DOWN at Config.MAV_RC_STICK (0.5) for T seconds and stops; you say whether the cross
-- has reached the line. A bisection on T (about 5 trials a line, 3% resolution) gives the time to cross each line, and so the slew rate: rate = angle / T,
-- K = rate / stick^2. Three lines let the fit also show an offset if the lines are not measured from the caged position. Run it once per FOV.
local RC_LINES = { 5, 10, 15 }
local rc_finish, rc_start_trial

-- A and B (no graduations on the TV picture): the reference is a Strike List target whose angle from the boresight Jester knows from the geometry
-- (Maverick.Aim). Run in active pause so that it holds still. Jester cages, slews toward the target at a set stick (both axes in proportion, so they
-- arrive together) for T seconds and stops; you say whether the target is at the center of the picture. Three sticks, so the fit also gives the law's power.
local TV_STICKS = { 0.35, 0.5, 0.7 }
local function rc_ang(rc) return rc.tv and (rc.tv.m or 10) or RC_LINES[rc.li] end
local function rc_nl(rc) return rc.tv and #TV_STICKS or #RC_LINES end
local function rc_vec(rc)
    if rc.tv and rc.tv.m then
        local sx = (rc.tv.az >= 0 and 1 or -1) * rc.stick * math.sqrt(math.abs(rc.tv.az) / rc.tv.m)
        local sy = -(rc.tv.el >= 0 and 1 or -1) * rc.stick * math.sqrt(math.abs(rc.tv.el) / rc.tv.m)      -- stick Y negative = seeker up
        return sx, sy
    end
    return 0, rc.stick
end
local function rc_init_line(rc)
    if rc.tv then rc.stick = TV_STICKS[rc.li] end
    local s = rc.stick
    local T0 = rc_ang(rc) / rate_at(s)
    rc.lo, rc.hi = T0 * 0.6, T0 * 1.5
    rc.lo_ok, rc.hi_ok = false, false      -- an end of the bracket counts only after an answer has confirmed it
    rc.T = (rc.lo + rc.hi) / 2
    rc.n = 0
end

local function rc_tick(job, now, dt)
    local rc = st.rc
    if not rc then return end
    if rc.tv then
        local Search = package.loaded['agplus.PaveSearch']
        if Search and Search.TouchFeed then Search.TouchFeed(3) end
    end
    if rc.phase == 'settle' then
        job.sx, job.sy = 0, 0
        if now >= rc.t0 then
            if rc.tv then
                local a = Maverick.Aim(rc.tv.entry)
                if not a then rc_finish('Rate Cal - No Aircraft Data') return end
                rc.tv.az, rc.tv.el, rc.tv.m = a.az, a.el, math.max(math.abs(a.az), math.abs(a.el))
                if rc.tv.m < 3 or rc.tv.m > 25 then
                    rc_finish(string.format('Rate Cal - The Target Is %.1f deg From The Boresight, It Needs To Be 3 To 25: Reposition And Run Again', rc.tv.m))
                    return
                end
                if rc.n == 0 then rc_init_line(rc) end
            end
            rc.phase, rc.t0 = 'run', now
            rc.n = rc.n + 1
            AGLog.Info('mav-rc: line -%.1f trial %d: stick %.2f for %.2f s (K guess %.2f)', rc_ang(rc), rc.n, rc.stick, rc.T, rate_k())
            Dbg.Notice(string.format('Rate Cal - %s, Trial %d: Moving For %.1f s', rc.tv and string.format('Target %.1f deg', rc_ang(rc)) or ('Line -' .. rc_ang(rc)), rc.n, rc.T), 3)
        end
    elseif rc.phase == 'run' then
        if now - rc.t0 < rc.T then
            job.sx, job.sy = rc_vec(rc)
        else
            job.sx, job.sy = 0, 0
            rc.phase, rc.shown = 'ask', now
            Dbg.Notice(rc.tv and 'Rate Cal - Is The Target At The Center Of The Picture? Short = Not Yet, Double = Past It, Long = On It'
                or string.format('Rate Cal - Has The Cross Reached The -%d Line? Short = Not Yet, Double = Past It, Long = On It', rc_ang(rc)), 8)
        end
    else
        job.sx, job.sy = 0, 0
        if rc.phase == 'ask' and now - rc.shown >= 6 then
            rc.shown = now
            Dbg.Notice(rc.tv and 'Rate Cal - Target At The Center? Short = Not Yet, Double = Past, Long = On It'
                or string.format('Rate Cal - Cross At The -%d Line? Short = Not Yet, Double = Past, Long = On It', rc_ang(rc)), 4)
        end
    end
    stick(job.sx, job.sy)
end

rc_finish = function(why)
    local rc = st.rc
    st.rc = nil
    local job = st.job
    if job then job.ratecal = nil job.rc_job = nil end
    if job then stop_job(why, true) end
    st.pilot_cage_next = true
    if not st.job then start_job(nil, nil, true) end
    Dbg.Notice(why, 8)
    AGLog.Info('mav-rc: %s', why)
end

-- The line is done: record, move to the next line or finish the run.
local function rc_line_done(rc, T)
    local ang = rc_ang(rc)
    local k = ang / (T * rc.stick ^ rate_p())      -- the full stick rate if the law is right (at stick 1.0 it is the rate itself)
    rc.res[#rc.res + 1] = { ang = ang, T = T, k = k, stick = rc.stick }
    AGLog.Info('mav-rc: line -%.1f reached after %.2f s at stick %.2f: rate %.3f deg/s, K %.3f (FOV %s)', ang, T, rc.stick, ang / T, k, FOVS[st.fov])
    rc.li = rc.li + 1
    if rc.li > rc_nl(rc) then
        if rc.tv then
            -- rate = angle / T at each stick; rate = K x stick^p: a fit of ln(rate) on ln(stick) gives p and K.
            local n, sx, sy, sxx, sxy, ksum, parts = #rc.res, 0, 0, 0, 0, 0, {}
            for _, r in ipairs(rc.res) do
                local x, y = math.log(r.stick), math.log(r.ang / r.T)
                sx = sx + x sy = sy + y sxx = sxx + x * x sxy = sxy + x * y ksum = ksum + r.k
                parts[#parts + 1] = string.format('%.2f at stick %.2f', r.ang / r.T, r.stick)
            end
            local den = n * sxx - sx * sx
            local pw = (den ~= 0) and (n * sxy - sx * sy) / den or 2
            local kfit = math.exp((sy - pw * sx) / n)
            local v = tostring(st.variant)
            st.cal = st.cal or {}
            st.cal['K_' .. v] = ksum / n      -- the Gimbal Calibrate and every slew of this session use it from now on
            rc_finish(string.format('Rate Cal Done (A/B %s): K %.2f with the square law (deg/s: %s); free fit power %.2f, K %.2f. Config.MAV_RATE_K_%s = %.2f',
                v, ksum / n, table.concat(parts, ', '), pw, kfit, v, ksum / n))
            return
        end
        local n, sx, sy, sxx, sxy, ksum = #rc.res, 0, 0, 0, 0, 0
        for _, r in ipairs(rc.res) do sx = sx + r.T sy = sy + r.ang sxx = sxx + r.T * r.T sxy = sxy + r.T * r.ang ksum = ksum + r.k end
        local den = n * sxx - sx * sx
        local slope = (den ~= 0) and (n * sxy - sx * sy) / den or 0
        local off = (sy - slope * sx) / n
        local msg = string.format('Rate Cal Done (FOV %s): mean K %.2f, fit rate %.3f deg/s at stick %.2f = K %.2f, offset %.2f deg', FOVS[st.fov], ksum / n, slope,
            rc.stick, slope / (rc.stick ^ rate_p()), off)
        rc_finish(msg)
        return
    end
    rc_init_line(rc)
end

local function rc_press(kind)
    local rc = st.rc
    if not rc then return false end
    if not st.job then st.rc = nil return false end
    if rc.phase ~= 'ask' then
        if kind == 'DOUBLE' then rc_finish('Rate Calibration Canceled') end
        return true
    end
    local T = rc.T
    local done = false
    if kind == 'SHORT' then
        rc.lo, rc.lo_ok = T, true
    elseif kind == 'DOUBLE' then
        rc.hi, rc.hi_ok = T, true
    else
        done = true
    end
    -- The bracket has closed on an end nobody tested (every answer was 'past' or every answer 'not yet'): the true time lies beyond it, so open it outward.
    if not done and ((rc.hi - rc.lo) / T <= 0.03 or rc.hi - rc.lo <= 0.06) then
        if not rc.lo_ok then
            rc.hi = rc.lo
            rc.lo = rc.lo / 1.6
        elseif not rc.hi_ok then
            rc.lo = rc.hi
            rc.hi = rc.hi * 1.6
        end
    end
    AGLog.Info('mav-rc: line -%.1f, T %.2f s: %s -> bracket %.2f to %.2f', rc_ang(rc), T, kind == 'SHORT' and 'not yet' or (kind == 'DOUBLE' and 'past' or 'on it'), rc.lo, rc.hi)
    if done or (((rc.hi - rc.lo) / T <= 0.03 or rc.hi - rc.lo <= 0.06) and rc.lo_ok and rc.hi_ok) or rc.n >= 14 then
        rc_line_done(rc, done and T or (rc.lo + rc.hi) / 2)
        if not st.rc then return true end
    else
        rc.T = (rc.lo + rc.hi) / 2
    end
    -- the next trial starts from a fresh cage
    local job = st.job
    job.ratecal = nil
    stop_job('Rate Trial Done', true)
    st.pilot_cage_next = true
    rc.pending = true
    start_job(nil, nil, true)
    return true
end

rc_start_trial = function()
    local rc = st.rc
    if not rc then return end
    rc.pending = nil
    start_job(nil, nil, false)
    if st.job then
        st.job.ratecal = true
        rc.phase, rc.t0 = 'settle', Util.Now() + 1.5
    end
end

local function rc_start()
    local variant = Maverick.Variant()
    if not variant then Dbg.Notice('Maverick - No Mavericks Loaded', 4) cant_do_now() return end
    if st.job then Dbg.Notice('Maverick - Seeker Busy', 3) cant_do_now() return end
    st.variant = variant
    local tv
    if not (PROFILES[variant] and PROFILES[variant].seeker == 'IR') then
        local T = package.loaded['agplus.Targets']
        local slots = T and T.Slots and T.Slots()
        local e = (st.idx > 0 and slots) and slots[st.idx] or nil
        if not e then Dbg.Notice('Rate Cal - Slew To A Strike List Target First (It Is The Reference), Use Active Pause, Target 3 To 25 deg From The Boresight', 7) cant_do_now() return end
        local Search = package.loaded['agplus.PaveSearch']
        if Search and Search.TouchFeed then Search.TouchFeed(5) end
        tv = { entry = e }
    end
    st.rc = { stick = st.rc_stick or Config.MAV_RC_STICK or 0.5, li = 1, res = {}, phase = 'cage', tv = tv }
    rc_init_line(st.rc)
    AGLog.Info('mav-rc: started, variant %s, FOV %s, stick %.2f, %s, K guess %.2f', variant, FOVS[st.fov], st.rc.stick, tv and ('reference ' .. tostring(tv.entry.alias)) or ('lines ' .. table.concat(RC_LINES, '/')), rate_k())
    Dbg.Notice('Rate Cal - Caging First; Then Press As Asked (Short = Not Yet, Double = Past, Long = On The Line)', 6)
    if st.fresh then
        rc_start_trial()
    else
        st.rc.pending = true
        st.pilot_cage_next = true
        start_job(nil, nil, true)
    end
end

-- Gimbal calibration for the D and G (Oct 21 2026). Per direction (right, left, up, down): Jester cages, holds the stick over at 0.5 for T seconds, lets go, waits 2 s,
-- then nudges the same way for 1.5 s. If the seeker was short of its stop the picture moves during the nudge. Short = it moved (the pulse was short of the stop),
-- Long = it did not move (the seeker sits at the stop), Double = it moved only a hair (done). A bisection on T gives the time to the stop; the travel is
-- rate x T plus the start offset measured with the rate test (Config.MAV_RC_OFFSET, -0.2 deg). The result is the gimbal angle from the caged position;
-- the elevation ones are converted to the datum line (the seeker is caged 2.58 deg below it).
local GC_DIRS = {
    { 'Right', 1, 0 }, { 'Left', -1, 0 }, { 'Up', 0, -1 }, { 'Down', 0, 1 },
}
local gc_finish, gc_start_trial

local function gc_rate(gc) return rate_at(gc.stick) end

local function gc_init_dir(gc)
    local d = GC_DIRS[gc.di]
    local G = is_ir() and gimbal() or (Config['MAV_GIMBAL_DEG_' .. tostring(st.variant)] or Config.MAV_GIMBAL_GUESS or 25)      -- A/B start from 25 deg (user, Oct 22 2026)
    local guess = G
    if d[1] == 'Up' then guess = G - BORESIGHT_EL elseif d[1] == 'Down' then guess = G + BORESIGHT_EL end
    local T0 = (guess - (Config.MAV_RC_OFFSET or -0.2)) / gc_rate(gc)
    gc.lo, gc.hi = T0 * 0.7, T0 * 1.3
    gc.lo_ok, gc.hi_ok = false, false
    gc.T = (gc.lo + gc.hi) / 2
    gc.n = 0
end

local function gc_tick(job, now, dt)
    local gc = st.gc
    if not gc then return end
    local d = GC_DIRS[gc.di]
    local sx, sy = 0, 0
    if gc.phase == 'settle' then
        if now >= gc.t0 then
            gc.phase, gc.t0 = 'run', now
            gc.n = gc.n + 1
            AGLog.Info('mav-gc: %s trial %d: stick %.2f for %.2f s (K %.2f)', d[1], gc.n, gc.stick, gc.T, rate_k())
            Dbg.Notice(string.format('Gimbal Cal - %s, Trial %d: Moving For %.1f s', d[1], gc.n, gc.T), 3)
        end
    elseif gc.phase == 'run' then
        if now - gc.t0 < gc.T then sx, sy = d[2] * gc.stick, d[3] * gc.stick
        else gc.phase, gc.t0 = 'rest', now end
    elseif gc.phase == 'rest' then
        if now - gc.t0 >= 2.0 then
            gc.phase, gc.t0 = 'nudge', now
            Dbg.Notice('Gimbal Cal - Nudge: Does The Picture Move?', 3)
        end
    elseif gc.phase == 'nudge' then
        if now - gc.t0 < 1.5 then sx, sy = d[2] * gc.stick, d[3] * gc.stick
        else
            gc.phase, gc.shown = 'ask', now
            Dbg.Notice(string.format('Gimbal Cal - %s: Short = It Moved, Long = It Did Not, Double = A Hair', d[1]), 8)
        end
    elseif gc.phase == 'ask' and now - gc.shown >= 6 then
        gc.shown = now
        Dbg.Notice(string.format('Gimbal Cal - %s: Short = It Moved, Long = It Did Not, Double = A Hair', d[1]), 4)
    end
    job.sx, job.sy = sx, sy
    stick(sx, sy)
end

gc_finish = function(why)
    st.gc = nil
    local job = st.job
    if job then job.gimbalcal = nil end
    if job then stop_job(why, true) end
    st.pilot_cage_next = true
    if not st.job then start_job(nil, nil, true) end
    Dbg.Notice(why, 9)
    AGLog.Info('mav-gc: %s', why)
end

local function gc_dir_done(gc, T)
    local d = GC_DIRS[gc.di]
    local travel = gc_rate(gc) * T + (Config.MAV_RC_OFFSET or -0.2)
    local datum = travel
    if d[1] == 'Up' then datum = travel + BORESIGHT_EL elseif d[1] == 'Down' then datum = travel - BORESIGHT_EL end
    gc.res[#gc.res + 1] = { name = d[1], T = T, travel = travel, datum = datum }
    AGLog.Info('mav-gc: %s stop after %.2f s at stick %.2f: %.1f deg from the caged position, %.1f deg from the datum line (FOV %s)', d[1], T, gc.stick, travel, datum, FOVS[st.fov])
    gc.di = gc.di + 1
    if gc.di > #GC_DIRS then
        local parts, sum = {}, 0
        for _, r in ipairs(gc.res) do parts[#parts + 1] = string.format('%s %.1f', r.name, r.datum) sum = sum + r.datum end
        gc_finish(string.format('Gimbal Cal Done (FOV %s): from the datum line %s, mean %.1f deg. Config.MAV_GIMBAL_DEG_%s = %.1f', FOVS[st.fov], table.concat(parts, ', '), sum / #gc.res, tostring(st.variant), sum / #gc.res))
        return
    end
    gc_init_dir(gc)
end

local function gc_press(kind)
    local gc = st.gc
    if not gc then return false end
    if not st.job then st.gc = nil return false end
    if gc.phase ~= 'ask' then
        if kind == 'DOUBLE' then gc_finish('Gimbal Calibration Canceled') end
        return true
    end
    local T = gc.T
    local done = false
    if kind == 'SHORT' then gc.lo, gc.lo_ok = T, true       -- it moved: the stop is further
    elseif kind == 'LONG' then gc.hi, gc.hi_ok = T, true    -- it did not move: already at the stop
    else done = true end
    local tol = 0.4 / gc_rate(gc)      -- 0.4 deg of travel, in seconds
    if not done and (gc.hi - gc.lo) <= tol then
        if not gc.lo_ok then gc.hi = gc.lo gc.lo = gc.lo / 1.6      -- a bracket that closed on an end nobody tested opens out fast
        elseif not gc.hi_ok then gc.lo = gc.hi gc.hi = gc.hi * 1.6 end
    end
    AGLog.Info('mav-gc: %s, T %.2f s: %s -> bracket %.2f to %.2f', GC_DIRS[gc.di][1], T, kind == 'SHORT' and 'moved' or (kind == 'LONG' and 'did not move' or 'a hair'), gc.lo, gc.hi)
    if done or ((gc.hi - gc.lo) <= tol and gc.lo_ok and gc.hi_ok) or gc.n >= 12 then
        gc_dir_done(gc, done and T or (gc.lo + gc.hi) / 2)
        if not st.gc then return true end
    else
        gc.T = (gc.lo + gc.hi) / 2
    end
    local job = st.job
    job.gimbalcal = nil
    stop_job('Gimbal Trial Done', true)
    st.pilot_cage_next = true
    gc.pending = true
    start_job(nil, nil, true)
    return true
end

gc_start_trial = function()
    local gc = st.gc
    if not gc then return end
    gc.pending = nil
    start_job(nil, nil, false)
    if st.job then
        st.job.gimbalcal = true
        gc.phase, gc.t0 = 'settle', Util.Now() + 1.5
    end
end

local function gc_start()
    local variant = Maverick.Variant()
    if not variant then Dbg.Notice('Maverick - No Mavericks Loaded', 4) cant_do_now() return end
    if st.job then Dbg.Notice('Maverick - Seeker Busy', 3) cant_do_now() return end
    st.variant = variant
    st.gc = { stick = Config.MAV_GC_STICK or (is_ir() and (Config.MAV_RC_STICK or 0.5) or 0.7), di = 1, res = {}, phase = 'cage' }
    gc_init_dir(st.gc)
    AGLog.Info('mav-gc: started, variant %s, FOV %s, stick %.2f, rate %.3f deg/s', variant, FOVS[st.fov], st.gc.stick, gc_rate(st.gc))
    Dbg.Notice('Gimbal Cal - Caging First; Then Watch The Picture During Each Nudge', 6)
    if st.fresh then
        gc_start_trial()
    else
        st.gc.pending = true
        st.pilot_cage_next = true
        start_job(nil, nil, true)
    end
end

local function job_tick()
    local job = st.job
    if not job then return end
    local now = Util.Now()
    local dt = now - job.last_t
    if dt < 0.05 then return end
    job.last_t = now
    if not st.on or not Maverick.ModeActive() then
        st.pos = nil
        stop_job('Left TV Mode, Slew Stopped')
        return
    end
    -- The search has its own time cap, and the FOV probe runs as long as the user needs (30 min safety).
    local cap = job.search and 100000 or ((job.fovp or job.ratecal or job.gimbalcal) and 1800 or 120)
    if now - job.t0 > cap then
        if job.fovp then fovp_finish('FOV Probe Timed Out') else stop_job('Slew Timed Out') end
        return
    end

    if job.phase == 'cage' then
        local el = now - job.t0
        local u = job.u or 0
        if u > 0 and not job.cage_sent then
            if job.trig and el >= math.min(Config.MAV_UNLOCK_HOLD_S or 0.2, u) then trigger(0) job.trig = nil end      -- the hand control half press is only a click      -- release the half press, then wait out the rest of the delay before the cage
            if el >= u then job.click = cage_click_s() cage_btn(1) job.cage_sent = true end      -- the lock was broken by the reject tap (or the half press) u seconds ago
            return
        end
        if job.stage == 0 and el >= u + (job.click or Config.MAV_CAGE_CLICK_S or 0.2) then cage_btn(0) job.stage = 1 end      -- the WSO trigger full action is only a click
        if job.stage == 1 and el >= job.wait - 1.5 then
            if not job.cage_only then trigger(0.5) job.trig = true end
            job.stage = 2
        end
        if el >= job.wait then
            st.pos = { az = 0, el = 0 }
            job.p0 = { az = 0, el = 0 }
            job.stage = 3
            if job.cage_only then
                st.fresh = true
                stop_job('Seeker Caged', st.pick ~= nil or st.rc ~= nil or st.gc ~= nil)
                if st.rc and st.rc.pending then rc_start_trial() end
                if st.gc and st.gc.pending then gc_start_trial() end
                return
            end
            job.phase = 'slew'
            job.last_t = now
        end
        return
    end

    -- A frame hitch: the stick was held for the whole stall and the dead reckoning cannot say how far the seeker went, so the position is lost.
    if dt > (Config.MAV_HITCH_S or 0.6) then
        AGLog.Info('mav: frame hitch of %.2f s, the seeker position is lost', dt)
        stop_job('Frame Hitch, Seeker Position Lost')
        st.pos, st.rel = nil, nil
        return
    end

    -- dead reckoning with the stick that was applied over the last interval
    local lo, hi = el_limits()
    local G = gimbal()
    st.pos.az = clamp(st.pos.az + rate_at(job.sx) * dt, -G, G)
    st.pos.el = clamp(st.pos.el - rate_at(job.sy) * dt, lo, hi)      -- a negative stick Y moves the seeker UP

    if job.search then search_tick(job, now, dt, lo, hi, G) return end
    if job.fovp then fovp_tick(job, now, dt, lo, hi, G) return end
    if job.ratecal then rc_tick(job, now, dt) return end
    if job.gimbalcal then gc_tick(job, now, dt) return end

    local a, why = Maverick.Aim(job.entry)
    local Search = package.loaded['agplus.PaveSearch']
    if Search and Search.TouchFeed then Search.TouchFeed(3) end
    if not a then
        job.nodata = (job.nodata or 0) + dt
        if job.nodata > 3 then stop_job('No Aircraft Data, Slew Stopped') end
        stick(0, 0)
        job.sx, job.sy = 0, 0
        return
    end
    job.nodata = 0
    if not job.tracking and not in_gimbal(a) then
        -- The aircraft moved while the seeker was caging or slewing and the target is now beyond the gimbal: the seeker could only sit at the stop.
        AGLog.Info('mav: the target left the seeker limit during the slew (az %+.1f, body el %+.1f)', a.az, a.body_el)
        stop_job('Target Left The Seeker Limit, Slew Stopped')
        return
    end
    local m = 0.3
    local az_t = clamp(a.az, -(G - m), G - m)
    local el_t = clamp(a.el, lo + m, hi - m)
    if job.Tx == nil then
        job.p0 = job.p0 or { az = st.pos.az, el = st.pos.el }
        job.Tx, job.Ty = az_t - job.p0.az, el_t - job.p0.el
        if job.quick then job.Tx, job.Ty = az_t, el_t end      -- the trim is a function of the position from the cage, which is the absolute angle
        job.tcx, job.tcy = trim_corr(job.Tx, job.Ty)
        if job.off then job.tcx, job.tcy = job.tcx + job.off[1], job.tcy + job.off[2] end      -- retry nudge
        AGLog.Detail('mav-trim: travel (%+.2f right, %+.2f up) correction (%+.2f, %+.2f)%s', job.Tx, job.Ty, job.tcx, job.tcy,
            st.trim_on and '' or ' (trim off)')
    end
    az_t = clamp(az_t + job.tcx, -(G - 0.1), G - 0.1)
    el_t = clamp(el_t + job.tcy, lo + 0.1, hi - 0.1)
    local ex, ey = az_t - st.pos.az, el_t - st.pos.el
    -- The target's own rate across the airframe (deg/s, smoothed), from the aim direction of this tick and the last, from the start of the slew.
    job.rf_az, job.rf_el = job.rf_az or 0, job.rf_el or 0
    local pa = job.pa
    if pa and now > pa.t then
        local k = Config.MAV_TRACK_SMOOTH or 0.1
        local ra, re = (a.az - pa.az) / (now - pa.t), (a.el - pa.el) / (now - pa.t)
        job.rf_az = job.rf_az + k * (clamp(ra, -4, 4) - job.rf_az)
        job.rf_el = job.rf_el + k * (clamp(re, -4, 4) - job.rf_el)
    end
    job.pa = { az = a.az, el = a.el, t = now }
    if job.tracking then
        -- Phase 3b: the seeker is on the target and stays fixed to the airframe, so as the aircraft flies the target drifts across it.
        -- Each axis: wanted rate = the target's own rate across the airframe + Kp x error, as the nearest measured stick level.
        if not in_gimbal(a) then
            AGLog.Info('mav-track: the target left the seeker limit (az %+.1f, body el %+.1f)', a.az, a.body_el)
            stop_job('Target Left The Seeker Limit, Tracking Ended')
            return
        end
        local stop = 0.03      -- one tick of 0.5 stick is 0.047 deg, so a finer band would only chatter
        -- Lead (Oct 21 2026): in flight the seeker sat just behind a target that drifted (high left of one drifting right and down, high over one
        -- sinking with the pitch), so the seeker answers the stick late (or the aircraft data is a little old). The believed seeker is put ahead
        -- of the target by its rate x Config.MAV_TRACK_LEAD_S (0.4, a first guess); a rate under 0.1 deg/s is noise and gets no lead.
        local lead = Config.MAV_TRACK_LEAD_S or 0.4
        if math.abs(job.rf_az) >= 0.1 then ex = ex + job.rf_az * lead end
        if math.abs(job.rf_el) >= 0.1 then ey = ey + job.rf_el * lead end
        local sx, wx = track_axis(ex, job.rf_az, stop, job.px)
        local sy, wy = track_axis(ey, job.rf_el, stop, job.py)
        -- A stick beyond the unit circle (both axes high) is cut back and the rate is no longer the measured one:
        -- the axis that needs more goes first, the other waits for the next tick.
        if sx * sx + sy * sy > 1.0 and sx ~= 0 and sy ~= 0 then
            if math.abs(wx) >= math.abs(wy) then sy = 0 else sx = 0 end
        end
        -- Oct 21 2026: the smallest stick (0.25, about 0.23 deg/s) moved a seeker that had arrived on a still target by about 0.15 deg during the settle time,
        -- right before the lock attempt. In Lock mode a seeker inside the lock error stays still: the trigger is let go at once.
        if not st.hold and math.abs(ex) <= (Config.MAV_LOCK_ERR_DEG or 0.08) and math.abs(ey) <= (Config.MAV_LOCK_ERR_DEG or 0.08) then sx, sy = 0, 0 end
        job.px, job.py = sx, sy
        job.sx = sx
        job.sy = -sy      -- a negative stick Y moves the seeker UP
        stick(job.sx, job.sy)
        if now - (job.tlog or -9) >= 1.0 then
            job.tlog = now
            AGLog.Detail('mav-track t=%.1f error (%+.2f, %+.2f) target rate (%+.2f, %+.2f) deg/s stick (%+.2f, %+.2f) seeker (%+.2f, %+.2f) %.1f NM',
                now - job.track_t0, ex, ey, job.rf_az, job.rf_el, job.sx, job.sy, st.pos.az, st.pos.el, a.rng / 1852)
        end
        local e = job.entry
        local name = string.format('Slot %s %s - Seeker On Target', tostring(job.slot), tostring(e and e.alias or '?'))
        local held = now - job.track_t0
        if st.hold then
            if held >= (Config.MAV_TRACK_MAX_S or 45) then
                stop_job(name .. ' (Tracking Time Limit)')
            end
        else
            -- Lock mode: release the trigger (the lock attempt) once the error has been small for the settle time, or after MAV_LOCK_WAIT_S.
            local lim = Config.MAV_LOCK_ERR_DEG or 0.08
            if math.abs(ex) <= lim and math.abs(ey) <= lim then job.settle_t = job.settle_t or now else job.settle_t = nil end
            local settled = job.settle_t and (now - job.settle_t) >= (Config.MAV_SETTLE_S or 0.2)
            if settled or held >= (Config.MAV_LOCK_WAIT_S or 4.0) then
                AGLog.Info('mav-track: lock attempt after %.1f s on target, error (%+.2f, %+.2f)%s', held, ex, ey, settled and '' or ' (did not settle)')
                stop_job(name)
            end
        end
        return
    end
    local cx, mx = ctl2(job.dx, ex, dt, job.quick)
    local cy, my = ctl2(job.dy, ey, dt, job.quick)          -- +1 = up
    -- One axis at a time at full stick: the axis is chosen once (the larger error) and kept until it is inside the full-stick zone, then the
    -- other axis runs, then both finish together at half stick. (Switching axis every tick, as the first version did, left the seeker short.)
    local fast_x, fast_y = (mx == 1.0), (my == 1.0)
    if job.fast == 'x' and not fast_x then job.fast = nil end
    if job.fast == 'y' and not fast_y then job.fast = nil end
    if not job.fast then
        if fast_x and fast_y then job.fast = (math.abs(ex) >= math.abs(ey)) and 'x' or 'y'
        elseif fast_x then job.fast = 'x'
        elseif fast_y then job.fast = 'y' end
    end
    if job.fast == 'x' then cy, my = 0, 0
    elseif job.fast == 'y' then cx, mx = 0, 0 end
    -- A target that moves across the airframe faster than 0.4 deg/s is not caught by the half-stick finish, and the stick never rests long enough
    -- to count as arrived: once no axis needs full stick any more, the tracking controller takes over.
    if Config.MAV_TRACK ~= false and not st.train and not job.cage_only and not job.fast
        and (math.abs(job.rf_az) > 0.4 or math.abs(job.rf_el) > 0.4) then
        stick(0, 0)
        begin_track(job, a, ex, ey, now, 'moving target, tracking from')
        return
    end
    job.dx, job.dy = cx, cy
    job.sx, job.sy = cx * mx, -cy * my
    if job.sx ~= job.lx or job.sy ~= job.ly then
        job.lx, job.ly = job.sx, job.sy
        AGLog.Detail('mav-steer t=%.1f stick x=%+.2f y=%+.2f seeker (%+.2f, %+.2f) target (%+.2f, %+.2f) error (%+.2f, %+.2f)', now - job.t0, job.sx, job.sy,
            st.pos.az, st.pos.el, az_t, el_t, ex, ey)
    end
    stick(job.sx, job.sy)
    if cx == 0 and cy == 0 then job.still = job.still + dt else job.still = 0 job.settle_t = nil end
    if job.still >= 0.3 then
        -- Settle (Oct 21 2026): the first release after a slew failed on 4 of 6 slews and a retry from the same spot locked, so the gimbal may still be
        -- coming to rest when the trigger is released. Lock mode holds the trigger half pressed for Config.MAV_SETTLE_S (0.4) more seconds first (default 0.4).
        local track = not (st.train or job.cage_only) and Config.MAV_TRACK ~= false
        local settle = (st.hold or st.train or job.cage_only or track) and 0 or (Config.MAV_SETTLE_S or 0.4)
        if settle > 0 then
            job.settle_t = job.settle_t or now
            if now - job.settle_t < settle then return end
        end
        local n = tostring(job.slot)
        local e = job.entry
        if track then
            begin_track(job, a, ex, ey, now, 'arrived')
            return
        end
        AGLog.Info('mav: arrived slot=%s seeker az %+.2f el %+.2f, target az %+.2f el %+.2f (error %+.2f %+.2f), %.1f NM, in %.1f s',
            n, st.pos.az, st.pos.el, a.az, a.el, ex, ey, a.rng / 1852, now - job.t0)
        job.arrived = true
        if st.train then
            st.last = { Tx = job.Tx, Ty = job.Ty, cx = job.tcx, cy = job.tcy, slot = job.slot, alias = e and e.alias, rng = a.rng / 1852 }
            st.bump = { x = 0, y = 0 }
        end
        stop_job(string.format('Slot %s %s - Seeker On Target%s', n, tostring(e and e.alias or '?'),
            st.train and ' (Bump With The Hand Control, Then Save Bump)' or ''), false)
    end
end
Maverick.JobTick = job_tick

--------------------------------------------------------------------------------
-- Bump trainer: the player's hand control (read from the Maverick Pan X/Y readings, ARR released) becomes small seeker nudges
--------------------------------------------------------------------------------

local PAN_PATH = { x = '/Weapons/Weapons Control Panel Knobs/Maverick Pan X Button', y = '/Weapons/Weapons Control Panel Knobs/Maverick Pan Y Button' }
local pan_armed, pan_t = { x = true, y = true }, -1
local pan_last, pan_logs, pan_nil_warned = {}, 0, false
local watch   -- assigned further down

local function read_pan(ax)
    local ok, v = pcall(function() return GetProperty(PAN_PATH[ax], 'Position').value end)
    if not ok or v == nil then return nil end
    return tonumber(v) or tonumber((tostring(v):match('-?%d+%.?%d*')))
end

local function nudge_ok()
    if not Maverick.ModeActive() then return false end
    return st.job == nil and st.pos ~= nil and st.trig_v == 0.5
end

local function nudge_tick()
    if not (st.train and st.on) then
        if st.nudge then st.nudge, st.nq = nil, {} stick(0, 0) end
        return
    end
    local now = Util.Now()
    local ok = nudge_ok()
    if not ok and st.nudge then st.nudge, st.nq = nil, {} stick(0, 0) end
    if now - pan_t >= 0.05 or now < pan_t then
        pan_t = now
        for _, ax in ipairs({ 'x', 'y' }) do
            local v = read_pan(ax)
            if v ~= nil and v ~= pan_last[ax] and pan_logs < 60 and (math.abs(v) >= 0.2 or math.abs(pan_last[ax] or 0) >= 0.2) then
                pan_logs = pan_logs + 1
                AGLog.Detail('mav-pan: %s = %.2f (ARR %s, job %s, pos %s, trigger %s, nudge ok %s)', ax, v, tostring(watch and watch.aar), tostring(st.job ~= nil),
                    tostring(st.pos ~= nil), tostring(st.trig_v), tostring(ok))
            end
            if v ~= nil then pan_last[ax] = v end
            if v == nil and not pan_nil_warned then
                pan_nil_warned = true
                AGLog.Info('mav-pan: the Maverick Pan %s reading is nil, the bump trainer cannot see the hand control', ax)
            end
            if v then
                if math.abs(v) < 0.2 then
                    pan_armed[ax] = true
                elseif pan_armed[ax] and math.abs(v) >= 0.6 then
                    pan_armed[ax] = false
                    if ok then
                        -- Measured Oct 21 2026: the "Pan X" reading is the stick's UP / DOWN axis (up = +) and the "Pan Y" reading is its
                        -- RIGHT / LEFT axis (right = +).
                        local nax, dir
                        if ax == 'y' then nax, dir = 'x', (v > 0 and 1 or -1) * (Config.MAV_BUMP_X_SIGN or 1)
                        else nax, dir = 'y', (v > 0 and 1 or -1) * (Config.MAV_BUMP_Y_SIGN or 1) end
                        if #st.nq < 4 then st.nq[#st.nq + 1] = { ax = nax, dir = dir } end
                    elseif Maverick.ModeActive() then
                        Dbg.Notice('Bump Ignored - Slew To A Target First (Trim Train Holds The Trigger After A Slew)', 3)
                    end
                end
            end
        end
    end
    if not ok then return end
    if not st.nudge and #st.nq > 0 then
        local q = table.remove(st.nq, 1)
        st.nudge = { ax = q.ax, dir = q.dir, left = st.bump_deg, last = now, applied = false }
    end
    local n = st.nudge
    if not n then return end
    local bs = Config.MAV_BUMP_STICK or min_stick()      -- a gentle stick so one frame moves the seeker only ~0.02 deg (rate goes with the square: ~0.23 deg/s)
    local dt = clamp(now - n.last, 0, 0.5)
    n.last = now
    if n.applied and dt > 0 then
        local m = rate_at(bs) * dt
        n.left = n.left - m
        local G = gimbal()
        local lo, hi = el_limits()
        if n.ax == 'x' then
            st.pos.az = clamp(st.pos.az + n.dir * m, -G, G)
            st.bump.x = st.bump.x + n.dir * m
        else
            st.pos.el = clamp(st.pos.el + n.dir * m, lo, hi)
            st.bump.y = st.bump.y + n.dir * m
        end
        st.pos_t = now
    end
    local per = rate_at(bs) * clamp(dt, 0.03, 0.3)
    if n.left < 0.5 * per then
        stick(0, 0)
        st.nudge = nil
        local name = (n.ax == 'x') and (n.dir > 0 and 'Right' or 'Left') or (n.dir > 0 and 'Up' or 'Down')
        Dbg.Notice(string.format('Bump %s - Total %+.2f Right, %+.2f Up (deg)', name, st.bump.x, st.bump.y), 2)
        AGLog.Info('mav-bump %s total right %+.2f up %+.2f, seeker (%+.2f, %+.2f)', name, st.bump.x, st.bump.y, st.pos.az, st.pos.el)
    else
        if n.ax == 'x' then stick(n.dir * bs, 0) else stick(0, -n.dir * bs) end
        n.applied = true
    end
end

local function save_sample()
    local l = st.last
    if not l then
        Dbg.Notice('Save Bump - Slew To A Target First (Trim Train On), Bump It Onto The Target, Then Save', 5)
        return false
    end
    local s = { k = trim_key(), Tx = l.Tx, Ty = l.Ty, Bx = st.bump.x + (l.cx or 0), By = st.bump.y + (l.cy or 0), slot = l.slot, alias = l.alias or '?', rng = l.rng or 0 }
    trim.samples[#trim.samples + 1] = s
    trim_append(s)
    refit()
    st.last = nil
    st.bump = { x = 0, y = 0 }
    Dbg.Notice(string.format('Bump Saved [%s] (%d) - Travel %+.1f Right %+.1f Up, Bumped %+.2f Right %+.2f Up', s.k, #cur_samples(), s.Tx, s.Ty, s.Bx, s.By), 6)
    AGLog.Info('mav-trim: sample %d saved [%s] slot=%s %s %.1f NM travel (%+.2f, %+.2f) bump (%+.2f, %+.2f)', #cur_samples(), s.k, tostring(s.slot), tostring(s.alias),
        s.rng, s.Tx, s.Ty, s.Bx, s.By)
    return true
end

local function show_trim()
    local f = cur_fit()
    local S = cur_samples()
    local n = #S
    for i, s in ipairs(S) do
        AGLog.Info('mav-trim: sample %d slot=%s %s travel (%+.2f, %+.2f) bump (%+.2f, %+.2f)', i, tostring(s.slot), tostring(s.alias), s.Tx, s.Ty, s.Bx, s.By)
    end
    if n == 0 then
        Dbg.Notice('Seeker Trim [' .. trim_key() .. '] - No Samples Yet. Trim ' .. (st.trim_on and 'On' or 'Off'), 5)
        return
    end
    Dbg.Notice(string.format('Seeker Trim [' .. trim_key() .. '] %s, %d Samples - Right/Left %+.2f %+.3f Tx %+.3f Ty, Up/Down %+.2f %+.3f Ty %+.3f Tx (deg)',
        st.trim_on and 'On' or 'Off', n, f.x.a, f.x.b, f.x.c, f.y.a, f.y.b, f.y.c), 9)
end

--------------------------------------------------------------------------------
-- Context presses
--------------------------------------------------------------------------------

-- Ends a search (finished, canceled or timed out): the slew stops, the seeker is caged back to the boresight (the unlock first, as after a lock, because
-- stopping releases the hand control trigger), and the next slew then starts from a seeker known to be caged (st.fresh, set when the cage job ends).
end_search = function(why)
    local job = st.job
    local sr = job and job.search
    if not sr then return end
    if sr.ending then return end
    -- A D/G search that switched the FOV to Narrow gives it back FIRST, while the hand control half action is still held (a full press then switches the
    -- FOV at once); the cage comes after that (user, Oct 22 2026: the FOV used to come back only after the whole cage, a long wait). search_tick
    -- makes the press and then calls this again.
    if sr.restore_fov and not sr.fov_done then
        sr.ending = why
        sr.press_n = 1
        job.sx, job.sy = 0, 0
        stick(0, 0)
        return
    end
    local found = sr.found or 0
    job.search = nil
    if sr.press_t then cage_btn(0) end
    if sr.restore_fov then st.restore_fov = { fov = sr.restore_fov, t = Util.Now() } end
    stop_job(why, true)
    st.pilot_cage_next = true
    start_job(nil, nil, true)
    Dbg.Notice(string.format('Maverick - %s, %d Found%s', why, found, found > 0 and '' or ' (Nothing In View)'), 5)
    AGLog.Info('mav: %s after %.0f s, %d found; caging the seeker back to the boresight', why, Util.Now() - (sr.t0 or Util.Now()), found)
end

local function start_search(use_look)
    local variant = Maverick.Variant()
    if not variant then
        Dbg.Notice('Maverick - No Mavericks Loaded', 4)
        cant_do_now()
        return
    end
    if not can_steer(variant) then
        Dbg.Notice(string.format('Maverick - AGM-65%s Steering Not Measured Yet, Search Unavailable', variant), 6)
        cant_do_now()
        return
    end
    if st.job then
        Dbg.Notice('Maverick - Seeker Busy', 3)
        cant_do_now()
        return
    end
    local Search = package.loaded['agplus.PaveSearch']
    if Search and Search.TouchFeed then Search.TouchFeed(5) end
    -- Long press (Oct 22 2026): the pattern is held on the ground point the player is LOOKING at (the head camera ray from the look file). The seeker
    -- slews there from the boresight, the spiral starts when it arrives, and units are added all the way. Jester says unable when that point is
    -- beyond the gimbal limits, or when the player looks at no ground. Search Area in the list keeps the boresight.
    local look_anchor
    if use_look and Config.MAV_SEARCH_LOOK ~= false then
        local L = Pave.ReadLook()
        if L then
            if not L.hit then
                Dbg.Notice('Maverick - Unable, No Ground There', 4)
                AGLog.Info('mav: search: the look ray meets no ground')
                cant_do_now()
                return
            end
            local pt = { id = -1, x = L.hit.x, y = L.hit.y, z = L.hit.z }
            local a = Maverick.Aim(pt, L)
            local G = gimbal()
            local lo, hi = el_limits()
            if not a or math.abs(a.az) > G - margin() - 0.5 or a.el < lo + margin() + 0.5 or a.el > hi - margin() - 0.5 then
                Dbg.Notice('Maverick - Unable, Beyond Gimbal Limits', 4)
                AGLog.Info('mav: search: the look point is beyond the gimbal limits (az %s el %s)', a and string.format('%+.1f', a.az) or '?', a and string.format('%+.1f', a.el) or '?')
                cant_do_now()
                return
            end
            look_anchor = pt
            AGLog.Info('mav: search at the look point, %.1f NM, %.1f deg %s, %.1f deg %s the boresight', (L.hit.dist or 0) / 1852, math.abs(a.az), a.az >= 0 and 'right' or 'left', math.abs(a.el), a.el >= 0 and 'above' or 'below')
        end
    end
    start_job(nil, nil, false)
    if st.job then
        st.job.search = { variant = variant, anchor = look_anchor }
        Dbg.Notice('Maverick - Searching, Double Press To Cancel', 4)
        AGLog.Info('mav: search requested (variant %s)', tostring(variant))
    end
end

-- The target list. pick = { cursor = slot, t = time of the last press, shown = time the list was last drawn }.
local function pick_list()
    local T = package.loaded['agplus.Targets']
    local slots, n = T and T.Slots and T.Slots(), (T and T.N) or 6
    local L = {}
    if slots then
        for j = 1, n do if slots[j] then L[#L + 1] = j end end
    end
    -- Search Area (0) closes the round after the last slot, before slot 1 again. With an empty Strike List it is the only entry.
    L[#L + 1] = 0
    return L
end

local function pick_step(cur, dir)
    local L = pick_list()
    if #L == 0 then return cur end
    local pos = 1
    for i, j in ipairs(L) do if j == cur then pos = i end end
    pos = ((pos - 1 + dir) % #L) + 1
    return L[pos]
end

local function needs_cage()
    if st.fresh and Config.MAV_ASSUME_CAGED ~= false then return false end
    return true
end

-- Where a target sits, in arrows: one per 5 deg right or left of the nose (6 arrows is the seeker limit), ">^<" for dead ahead, "!!!>" or
-- "<!!!" (and "!!!^" / "!!!v") for a target outside the limit. The note says the same in words, with no numbers.
-- All of it can be changed in Config.lua (every key is optional):
--   MAV_LIST_RIGHT '>'  MAV_LIST_LEFT '<'  MAV_LIST_CENTER '>^<'  MAV_LIST_OUT '!!!'  MAV_LIST_UP '^'  MAV_LIST_DOWN 'v'  MAV_LIST_CURSOR '=> '
--   MAV_LIST_DEG_PER_ARROW 5  MAV_LIST_MAX_ARROWS 6  MAV_LIST_CENTER_DEG 2.5   MAV_LIST_NOTES = false hides the words in brackets.
-- The message hook keeps only letters, digits, spaces and . , : - + ( ) / % | < > = # _ ! ^ ' so other symbols are dropped on screen.
local function lcfg(key, default)
    local v = Config[key]
    if v == nil then return default end
    return v
end

local function dir_glyph(a)
    local R, Lf, C = lcfg('MAV_LIST_RIGHT', '>'), lcfg('MAV_LIST_LEFT', '<'), lcfg('MAV_LIST_CENTER', '>^<')
    local OUT, UP, DOWN = lcfg('MAV_LIST_OUT', '!!!'), lcfg('MAV_LIST_UP', '^'), lcfg('MAV_LIST_DOWN', 'v')
    if not a then return '?', 'no aircraft data' end
    local az = a.az
    local lim = gimbal()
    if not in_gimbal(a) then
        if math.abs(az) > lim - margin() then
            return az > 0 and (OUT .. R) or (Lf .. OUT), 'outside the limit, ' .. (az > 0 and 'right' or 'left')
        end
        return OUT .. (a.body_el > 0 and UP or DOWN), 'outside the limit, ' .. (a.body_el > 0 and 'high' or 'low')
    end
    local glyph, words
    if math.abs(az) < lcfg('MAV_LIST_CENTER_DEG', 2.5) then
        glyph, words = C, 'centered'
    else
        local n = math.max(1, math.min(lcfg('MAV_LIST_MAX_ARROWS', 6), math.ceil(math.abs(az) / lcfg('MAV_LIST_DEG_PER_ARROW', 5))))
        local side = az > 0 and 'right' or 'left'
        glyph = string.rep(az > 0 and R or Lf, n)
        words = (math.abs(az) < 12 and 'slightly ' or '') .. side
    end
    if math.abs(a.el) >= 6 then words = words .. ', ' .. (a.el > 0 and 'high' or 'low') end
    if math.max(math.abs(az), math.abs(a.body_el)) >= lim - 5 then words = words .. ', near the limit' end
    return glyph, words
end

-- Draws the list (a block of lines, replaced as a whole by the message hook; the lines expire after a second, so it is redrawn every 0.5 s while open).
-- The lines come from PickMenu.lua (shared with the Pave Spike list): the cursor line starts with the cursor mark, the current target (the last
-- one slewed to) with an asterisk.
local function pick_show()
    local pk = st.pick
    if not pk then return end
    local L = pick_list()
    local T = package.loaded['agplus.Targets']
    local slots = T and T.Slots and T.Slots() or {}
    local items, ci = {}, 1
    for i, j in ipairs(L) do
        if j == 0 then
            items[#items + 1] = { key = 0, name = 'Search Area', glyph = '', words = 'spiral from the boresight' }
        else
            local e = slots[j]
            local a = e and Maverick.Aim(e)
            local glyph, words = dir_glyph(a)
            items[#items + 1] = { key = j, name = tostring(e and e.alias or '?'), glyph = glyph, words = words }
        end
        if j == pk.cursor then ci = i end
    end
    local hint = (st.job and st.job.cage_only) and 'Caging The Seeker - Slews After The Pause' or 'Press To Step - Pause To Slew'
    local lines = PickMenu.Lines(items, ci, st.idx > 0 and st.idx or nil, hint)
    pk.shown = Util.Now()
    Dbg.Notice('MENU|' .. table.concat(lines, '|'), 1.0)
end

cant_do_now = function() pcall(function() GetJester():AddTask(Task:new():CantDo()) end) end

local function pick_commit(j)
    if j == 0 then
        start_search()
        return
    end
    local T = package.loaded['agplus.Targets']
    local slots = T and T.Slots and T.Slots()
    local e = slots and slots[j]
    if not e then
        Dbg.Notice('Maverick - That Target Is No Longer In The List', 4)
        cant_do_now()
        return
    end
    local variant, station = Maverick.Variant()
    if not variant then
        Dbg.Notice('Maverick - No Mavericks Loaded', 4)
        cant_do_now()
        return
    end
    local Search = package.loaded['agplus.PaveSearch']
    if Search and Search.TouchFeed then Search.TouchFeed(3) end
    st.idx = j
    local a, why = Maverick.Aim(e)
    if not a then
        Dbg.Notice(string.format('Maverick - Slot %d %s: No Aircraft Data', j, e.alias), 5)
        AGLog.Info('mav: slot %d %s: no aim (%s)', j, tostring(e.alias), tostring(why))
        cant_do_now()
        return
    end
    AGLog.Info('mav: slot %d %s: %s (body elevation %.1f deg), variant AGM-65%s station %s', j, tostring(e.alias), aim_text(a), a.body_el, variant, tostring(station))
    if not can_steer(variant) then
        Dbg.Notice(string.format('Maverick - AGM-65%s Steering Not Measured Yet, Dry Run Slot %d: %s', variant, j, aim_text(a)), 6)
        cant_do_now()
        return
    end
    if not in_gimbal(a) then
        Dbg.Notice(string.format('Maverick - Slot %d %s Is Outside The Seeker Limit (%.0f deg, %s)', j, e.alias, gimbal(), aim_text(a)), 7)
        cant_do_now()
        return
    end
    Dbg.Notice(string.format('Maverick - Slewing To Slot %d %s: %s', j, e.alias, aim_text(a)), 5)
    start_job(j, e, false)
end

local function pick_tick()
    local pk = st.pick
    if not pk then return end
    local now = Util.Now()
    if now < pk.t then pk.t = now end
    if now - pk.t >= (Config.MAV_PICK_DWELL_S or 1.5) and not (st.job and st.job.cage_only) then
        st.pick = nil
        st.pick_grace = now + (Config.MAV_PICK_GRACE_S or 1.0)
        pick_commit(pk.cursor)
        return
    end
    if now - pk.shown >= 0.5 or now < pk.shown then pick_show() end
end

function Maverick.OnPress(task, kind)
    if not st.on then return false end
    local ok, err = pcall(function()
        local list = Maverick.Loadout()
        AGLog.Info('mav: context press %s in TV mode (loadout: %s)', tostring(kind), loadout_text(list))
        -- Long press (Oct 21 2026): kept for a seeker search, not built yet. The retry it used to do is gone: Jester gets the seeker close and
        -- hands over, and the pilot finishes the slew and the lock with ARR.
        if st.job and st.job.fovp then
            fovp_press(kind)
            return
        end
        if st.rc and rc_press(kind) then return end
        if st.gc and gc_press(kind) then return end
        if kind == 'LONG' then
            -- Long press (Oct 22 2026): with the target list open it closes the list; otherwise it starts the seeker search (the same as Search Area in
            -- the list). A running search is canceled by a double press, as before.
            if st.pick then
                st.pick = nil
                Dbg.Notice('Maverick - Target List Closed', 3)
                task:Roger()
                return
            end
            if st.job and st.job.search then
                Dbg.Notice('Maverick - Search Running, Double Press To Cancel', 3)
                return
            end
            start_search(true)
            if st.job and st.job.search then task:Roger() end
            return
        end
        if kind ~= 'SHORT' and kind ~= 'DOUBLE' then
            task:CantDo()
            return
        end
        -- Browse, then pause to slew (Oct 21 2026). The first press opens the target list with the cursor on the current target, every further
        -- press moves it (short = next, double = previous), and Config.MAV_PICK_DWELL_S (1.5) after the last press Jester slews to the cursor.
        -- A press during a slew ends it and opens the list on that target. Long press with the list open cancels it.
        -- Invisible protection (Oct 21 2026): a double press just after the list closed (meant as "previous" a moment too late) is swallowed.
        if kind == 'DOUBLE' and not st.pick and st.pick_grace and Util.Now() < st.pick_grace then
            AGLog.Info('mav: double press just after the list closed, ignored')
            return
        end
        if st.job and st.job.fovp then
            fovp_press(kind)
            return
        end
        if st.rc and rc_press(kind) then return end
        if st.gc and gc_press(kind) then return end
        -- A search is running: a double press cancels it (the seeker goes back to the boresight and the next slew counts as boresighted); other presses wait.
        if st.job and st.job.search then
            if kind == 'DOUBLE' then
                end_search('Search Canceled')
            else
                Dbg.Notice('Maverick - Search Running, Double Press To Cancel', 3)
            end
            return
        end
        local picking_cage = st.job and st.job.cage_only and st.pick
        if st.job and not picking_cage then
            stop_job(st.job.tracking and 'Slew Ended By A Press' or 'Slew Canceled', true)
        end
        local variant = Maverick.Variant()
        if not variant then
            Dbg.Notice('Maverick - No Mavericks Loaded', 4)
            task:CantDo()
            return
        end
        local L = pick_list()
        local now = Util.Now()
        if not st.pick then
            local T = package.loaded['agplus.Targets']
            local slots = T and T.Slots and T.Slots()
            local cur = (st.idx > 0 and slots and slots[st.idx]) and st.idx or L[1]
            st.pick = { cursor = cur, t = now, shown = -10 }
            if kind == 'DOUBLE' then st.pick.cursor = pick_step(cur, -1) end
            -- The cage does not depend on the target, so it starts now and runs while the player browses.
            if Config.MAV_PICK_EARLY_CAGE ~= false and can_steer(variant) and needs_cage() and not st.job then
                AGLog.Info('mav: list opened, caging the seeker while the target is picked')
                start_job(nil, nil, true)
            end
        else
            st.pick.cursor = pick_step(st.pick.cursor, kind == 'SHORT' and 1 or -1)
            st.pick.t = now
        end
        AGLog.Detail('mav: list cursor on slot %d', st.pick.cursor)
        pick_show()
    end)
    if not ok then
        AGLog.Info('mav: press handler failed: %s', tostring(err))
        pcall(function() stop_job('Error', true) end)
        pcall(function() task:CantDo() end)
    end
    return true
end

--------------------------------------------------------------------------------
-- Menu
--------------------------------------------------------------------------------

local function leaf(name, value)
    return Wheel.Item:new({ name = name, action = 'agp_mav', action_value = value, reaction = Wheel.Reaction.NOTHING })
end

function Maverick.BuildItem()
    local items = {
        leaf(st.on and 'Jester Maverick: On' or 'Jester Maverick: Off', 'toggle'),
        leaf('FOV: ' .. FOVS[st.fov], 'fov'),
        leaf(st.after_next and 'After Launch: Next' or 'After Launch: Stop', 'after'),
        Wheel.Item:new({ name = 'Seeker', menu = Wheel.Menu:new({ name = 'Seeker', items = {
            leaf(st.hold and 'After Slew: Hold' or 'After Slew: Lock', 'hold'),
            leaf('Lock Now', 'locknow'),
            leaf('Cage Seeker', 'cage'),
        } }) }),
    }
    -- Measuring and training tools (FOV probe, rate and gimbal calibration, the trim trainer) are only on the wheel with Config.MAV_DEV_MENU = true.
    if Config.MAV_DEV_MENU == true then
        items[#items + 1] = Wheel.Item:new({ name = 'Maverick Dev', menu = Wheel.Menu:new({ name = 'Maverick Dev', items = {
            Wheel.Item:new({ name = 'Trim', menu = Wheel.Menu:new({ name = 'Trim', items = {
                leaf(st.train and 'Trim Train: On' or 'Trim Train: Off', 'train'),
                leaf('Save Bump', 'savebump'),
                leaf(st.trim_on and 'Trim Use: On' or 'Trim Use: Off', 'trimuse'),
                leaf(string.format('Bump Size: %.2f', st.bump_deg), 'bumpsize'),
                leaf('Clear Trim', 'cleartrim'),
            } }) }),
            leaf('Loadout Report', 'report'),
            leaf('FOV Probe', 'fovp'),
            leaf('Rate Calibrate', 'ratecal'),
            leaf(string.format('Rate Cal Stick: %.2f', st.rc_stick or Config.MAV_RC_STICK or 0.5), 'rcstick'),
            leaf('Gimbal Calibrate', 'gimbalcal'),
        } }) })
    end
    return Wheel.Item:new({ name = TOP, menu = Wheel.Menu:new({ name = TOP, items = items }) })
end

local function info_text()
    -- The center readout (Oct 21 2026): the current strike target and the Mavericks on the pylons. On/Off is in the menu item.
    local T = package.loaded['agplus.Targets']
    local slots = T and T.Slots and T.Slots()
    local e = (st.idx > 0 and slots) and slots[st.idx] or nil
    return 'Target: ' .. (e and tostring(e.alias) or 'none yet') .. '\n' .. loadout_text(Maverick.Loadout())
end

local function refresh()
    local S = package.loaded['agplus.PaveSearch']
    if S and S.RefreshMenu then pcall(S.RefreshMenu) else pcall(Menu.Rebuild) end
    pcall(Menu.SetInfo, { TOP }, info_text())
    if Config.STRIKE_WHEEL_NAV ~= false then
        AGLog.Info('mav: wheel sent back to the Maverick page')
        pcall(Wheel.NavigateTo, { Config.MENU_PARENT[1], Config.MENU_NAME, TOP })
    end
end

ListenTo('agp_mav', 'AGPlusMaverick', function(task, value)
    local skip_refresh = false
    local ok, err = pcall(function()
        local v = tostring(value)
        if v == 'train' then
            st.train = not st.train
            st.nudge, st.nq = nil, {}
            st.last = nil
            st.bump = { x = 0, y = 0 }
            if st.train then
                Dbg.Notice('Trim Train On - Slew To A Target, Bump With The Hand Control (ARR Released), Then Seeker > Save Bump', 8)
            else
                Dbg.Notice('Trim Train Off', 4)
            end
            AGLog.Info('mav-trim: training %s', st.train and 'on' or 'off')
            task:Roger()
        elseif v == 'savebump' then
            skip_refresh = true
            if save_sample() then task:Roger() else task:CantDo() end
        elseif v == 'trimuse' then
            if not st.trim_on and #cur_samples() == 0 then
                Dbg.Notice('Seeker Trim - No Samples Yet, Train And Save Bumps First', 5)
                task:CantDo()
            else
                st.trim_on = not st.trim_on
                if st.trim_on then show_trim() else Dbg.Notice('Seeker Trim Off', 4) end
                AGLog.Info('mav-trim: use %s', st.trim_on and 'on' or 'off')
                task:Roger()
            end
        elseif v == 'bumpsize' then
            local nxt = BUMP_SIZES[1]
            for i, s in ipairs(BUMP_SIZES) do
                if math.abs(s - st.bump_deg) < 1e-6 then nxt = BUMP_SIZES[i % #BUMP_SIZES + 1] break end
            end
            st.bump_deg = nxt
            Dbg.Notice(string.format('Bump Size: %.2f deg', nxt), 3)
            AGLog.Info('mav-trim: bump size %.2f deg', nxt)
            task:Roger()
        elseif v == 'cleartrim' then
            skip_refresh = true
            trim_clear()
            st.last = nil
            Dbg.Notice('Seeker Trim Cleared', 4)
            task:Roger()
        elseif v == 'toggle' then
            st.on = not st.on
            st.idx = 0
            st.pos = nil
            st.rel = nil
            if not st.on and st.job then stop_job('Slew Stopped', true) end
            Dbg.Notice('Jester Maverick ' .. (st.on and 'On' or 'Off'), 4)
            AGLog.Info('mav: Jester Maverick %s', st.on and 'on' or 'off')
            task:Roger()
        elseif v == 'rcstick' then
            local cur = st.rc_stick or Config.MAV_RC_STICK or 0.5
            st.rc_stick = (cur < 0.6) and 1.0 or 0.5
            Dbg.Notice(string.format('Rate Cal Stick: %.2f', st.rc_stick), 4)
            task:Roger()
        elseif v == 'gimbalcal' then
            skip_refresh = true
            if st.gc then gc_finish('Gimbal Calibration Stopped') else gc_start() end
            task:Roger()
        elseif v == 'ratecal' then
            skip_refresh = true
            if st.rc then rc_finish('Rate Calibration Stopped') else rc_start() end
            task:Roger()
        elseif v == 'fovp' then
            skip_refresh = true
            if st.job and st.job.fovp then fovp_finish('FOV Probe Stopped') else fovp_start() end
            task:Roger()
        elseif v == 'fire' then
            Dbg.Notice('Command Fire - Jester Auto Not Available, Pilot Commanded Only', 5)
            task:CantDo()
        elseif v == 'fov' then
            st.fov = (st.fov % #FOVS) + 1
            Dbg.Notice('Maverick FOV: ' .. FOVS[st.fov], 4)
            AGLog.Info('mav: FOV setting %s', FOVS[st.fov])
            task:Roger()
        elseif v == 'after' then
            st.after_next = not st.after_next
            Dbg.Notice('After Launch: ' .. (st.after_next and 'Next Target' or 'Stop'), 4)
            task:Roger()
        elseif v == 'hold' then
            st.hold = not st.hold
            Dbg.Notice(st.hold and 'After A Slew: Hold The Trigger Half Pressed, No Lock Attempt' or 'After A Slew: Release The Trigger To Lock', 5)
            AGLog.Info('mav: after slew: %s', st.hold and 'hold the trigger' or 'release to lock')
            task:Roger()
        elseif v == 'locknow' then
            if st.job then stop_job('Slew Canceled', true) end
            trigger(0)
            st.pos = nil
            Dbg.Notice('Maverick - Trigger Released, Lock Attempt', 4)
            AGLog.Info('mav: lock now: trigger released by hand, seeker position now unknown')
            task:Roger()
        elseif v == 'cage' then
            if st.job then stop_job('Slew Canceled', true) end
            st.rel = nil
            if st.on and Maverick.ModeActive() then
                Dbg.Notice('Maverick - Caging The Seeker', 4)
                start_job(nil, nil, true)
                task:Roger()
            else
                Dbg.Notice('Maverick - Turn Jester Maverick On And Set DIRECT And TV To Cage', 5)
                task:CantDo()
            end
        elseif v == 'report' then
            local list = Maverick.Loadout()
            local txt = loadout_text(list)
            AGLog.Info('mav: loadout: %s', txt)
            for _, m in ipairs(list) do
                local p = PROFILES[m.variant]
                if p then AGLog.Info('mav: station %s AGM-65%s: %s seeker, %s', m.station, m.variant, p.seeker, p.fovs) end
            end
            Dbg.Notice('Maverick Loadout - ' .. txt, 6)
            task:Roger()
        else
            task:CantDo()
            return
        end
        if not skip_refresh then refresh() end
    end)
    if not ok then
        AGLog.Info('mav: menu action %q failed: %s', tostring(value), tostring(err))
        pcall(function() task:CantDo() end)
    end
end)

--------------------------------------------------------------------------------
-- Debug: fill the target list after spawn (Oct 21 2026)
-- A few seconds after the mission starts (or restarts with Shift+R), every hostile ground unit within 25 NM of the aircraft joins the
-- pod's target list (nearest first, at most 150), so the Strike List and the Maverick tests have targets without a designation.
-- Off by default since Oct 22 2026 (user's request); Config.MAV_DEBUG_AUTOFILL = true turns it on. Range: Config.MAV_DEBUG_AUTOFILL_NM (25). Cap: Config.MAV_DEBUG_AUTOFILL_MAX (150).
-- Structures are left out unless Config.MAV_DEBUG_AUTOFILL_STRUCTS = true.
--------------------------------------------------------------------------------

local fill = { done = false, t_load = Util.Now(), last = 0, given_up = false }

local function autofill()
    if fill.done or fill.given_up or Config.MAV_DEBUG_AUTOFILL ~= true then return end
    local now = Util.Now()
    if now < fill.t_load then fill.t_load = now end          -- mission time went back (restart)
    if now - fill.t_load < 6 or now - fill.last < 0.7 then return end
    fill.last = now
    local Search = package.loaded['agplus.PaveSearch']
    if not (Search and Search.S and Search.TouchFeed and Search.Group and Search.FlatList) then return end
    if Search.Active and Search.Active() then return end
    if now - fill.t_load > 90 then
        fill.given_up = true
        AGLog.Info('mav: debug autofill gave up (no unit feed after 90 s)')
        return
    end
    Search.TouchFeed(3)
    local S = Search.S
    if not (S.units_t and S.coal and S.units) then return end
    local L = Pave.ReadLook()
    if not L then return end
    local range = (Config.MAV_DEBUG_AUTOFILL_NM or 25) * 1852
    local cap = Config.MAV_DEBUG_AUTOFILL_MAX or 150
    local found = {}
    for id, u in pairs(S.units) do
        local coal = tostring(u.coal)
        if coal ~= tostring(S.coal) and coal:lower() ~= 'neutral' and not u.static and (u.cat ~= 'struct' or Config.MAV_DEBUG_AUTOFILL_STRUCTS == true) then
            local d = math.sqrt((u.x - L.self.x) ^ 2 + (u.z - L.self.z) ^ 2)
            if d <= range then found[#found + 1] = { id = u.id, name = u.name, cat = u.cat, x = u.x, y = u.y, z = u.z, d_aim = d } end
        end
    end
    if #found == 0 then
        if now - fill.t_load > 25 then
            fill.done = true
            AGLog.Info('mav: debug autofill found no hostile ground units within %.0f NM', range / 1852)
        end
        return
    end
    table.sort(found, function(a, b) return a.d_aim < b.d_aim end)
    local merged, have = {}, {}
    for _, e in ipairs(Search.FlatList()) do merged[#merged + 1] = e have[e.id] = true end
    local added = 0
    for _, e in ipairs(found) do
        if added >= cap then break end
        if not have[e.id] then merged[#merged + 1] = e have[e.id] = true added = added + 1 end
    end
    S.list = Search.Group(merged)
    if Search.RefreshMenu then pcall(Search.RefreshMenu) end
    fill.done = true
    AGLog.Info('mav: debug autofill added %d of %d hostile ground units within %.0f NM to the target list (%d in the list now)', added, #found, range / 1852, #merged)
    Dbg.Notice(string.format('Debug: %d Hostile Ground Units Within %.0f NM Added To The Target List', added, range / 1852), 6)
end

--------------------------------------------------------------------------------
-- Behavior: keeps the center text current
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Pilot hand-over and fresh seekers (Oct 21 2026)
--   * ARR (the pilot's Air Refueling Release button) pressed: the pilot takes the seeker. Jester lets go of everything at once (stick centered,
--     hand control trigger released, WSO trigger released) and says "You got it". The seeker position is then unknown.
--   * A rifle (the Maverick count drops) or mission start: the next missile's seeker is caged, so the next slew needs no cage wait.
--------------------------------------------------------------------------------

local AAR_PATH = '/Weapons/Pilot Stick Buttons/Air Refueling Release Button'
local TRIG_PATH = '/Weapons/Pilot Stick Buttons/Pilot Trigger'
watch = { aar = false, aar_t = -1, count = nil, count_t = -1, trig = 0, trig_raw = nil, trig_logs = 0 }

-- The property name is found once per path: 'State' first (Heatblur's snapshot), then other names. What each one returned is logged, so a
-- button that reads nil or never changes shows up in agplus.log ("mav-watch ...").
local PROP_NAMES = { 'State', 'Position', 'Output', 'Input', 'Value', 'Pressed', 'Axis' }
local resolved = {}

local function raw_prop(path, name)
    local ok, v = pcall(function() return GetProperty(path, name).value end)
    if not ok or v == nil then return nil end
    return tonumber(v) or tonumber((tostring(v):match('-?%d+%.?%d*')))
end

local function read_num(path)
    local r = resolved[path]
    if r and r.name then return raw_prop(path, r.name) end
    local now = Util.Now()
    if r and now - r.t < 5 and now >= r.t then return nil end
    r = { t = now, n = (r and r.n or 0) + 1 }
    resolved[path] = r
    local seen = {}
    for _, name in ipairs(PROP_NAMES) do
        local v = raw_prop(path, name)
        seen[#seen + 1] = name .. '=' .. tostring(v)
        if v ~= nil and not r.name then r.name = name end
    end
    if r.name or r.n <= 4 then
        AGLog.Info('mav-watch: %s -> %s (%s)', path, r.name and ('property ' .. r.name) or 'NOT READABLE', table.concat(seen, ' '))
    end
    if r.name then return raw_prop(path, r.name) end
    return nil
end

-- The ARR release button comes from the Export feed BombBtnFeed.lua (cockpit argument 2780, the aar=0/1 field of Logs\bombbtn.txt, written at
-- once on a change and at least twice a second). The Jester property path from Heatblur's list reads nothing in the sim (21 Oct 2026 tests), so
-- the same route as the pickle button is used. A missing or old file, or one from the old feed without aar=, gives nil (unknown).
local BTN_FILE = (Config.PAYLOAD_FEED or ''):gsub('agplus_payload%.txt$', 'bombbtn.txt')
local aar_warned = false

local function read_aar()
    local f = io.open(BTN_FILE, 'r')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    local t = tonumber(text and text:match('t=([%d%.]+)'))
    local a = tonumber(text and text:match('aar=(%d)'))
    local now = Util.Now()
    if not t or not a or not (now - t < 1.5 and now - t > -2) then
        if t and not a and not aar_warned then
            aar_warned = true
            AGLog.Info('mav-watch: bombbtn.txt has no aar= field, the Export feed (Scripts\\BombBtnFeed.lua) is the old one, restart DCS after installing the new one')
        end
        return nil
    end
    return a == 1
end

-- Which seeker family is on the jet: the armed Maverick station's variant, else the first one. D and G (IIR) need ARR held for the trigger to cage.
local function seeker_dg()
    local list = Maverick.Loadout()
    local v
    for _, m in ipairs(list) do if m.armed then v = m.variant break end end
    v = v or (list[1] and list[1].variant)
    return v == 'D' or v == 'G'
end

-- why: log text. caged: the pilot's own cage (full trigger), so the seeker is known to be caged afterwards.
local function handover(why, caged, finish_cage)
    local job = st.job
    local had = job ~= nil or st.trig_v == 0.5
    stick(0, 0)
    if job and job.phase == 'cage' then cage_btn(0) end
    if st.trig_v ~= 0 then trigger(0) end
    st.job = nil
    st.pick = nil
    st.restore_fov = nil
    st.pos, st.rel, st.fresh = nil, nil, caged and true or false
    st.arr_tap = nil
    if had then
        AGLog.Info('mav: %s, the pilot has the seeker: Jester let go (%s)', why, job and ('slew to slot ' .. tostring(job.slot) .. ', phase ' .. tostring(job.phase)) or 'trigger held')
        -- The pilot's cage is canceled when Jester lets go of the hand control trigger in the same moment (user tests 21 Oct 2026, with a release
        -- at once and with a held trigger), so in that case Jester cages the seeker himself the way he does for Cage Seeker, instead of the call.
        if finish_cage then
            st.pilot_cage_next, st.pilot_cage_real = true, true
            start_job(nil, nil, true)
        else
            Dbg.Notice('Maverick - Pilot Has The Seeker', 3)
        end
        say_voice('MAV_TAKEOVER_VOICE', 'gotit')
    else
        AGLog.Info('mav: %s, the pilot has the seeker (%s)', why, caged and 'caged by the pilot' or 'seeker position now unknown')
    end
end

-- The pilot's Master Arm switch (pilot-seat manipulator "Master Arm", readable). The pilot trigger rules only apply with it ON (user, Oct 22 2026).
-- The raw state is logged on every change until the values are known; an unreadable switch counts as ON so the mod never goes dead because of it.
local master_raw
local function master_arm_on()
    if Config.MAV_REQUIRE_MASTER_ARM == false then return true end
    local ok, v = pcall(function() return GetJester():GetCockpit():GetManipulator('Master Arm'):GetState() end)
    if not ok or v == nil then return true end
    if tostring(v) ~= master_raw then
        master_raw = tostring(v)
        AGLog.Info('mav: Master Arm State = %s', master_raw)
    end
    local n = tonumber(v)
    if n == nil then
        local u = tostring(v):upper()
        if u:find('OFF') or u:find('SAFE') then return false end
        return true
    end
    return n > 0.5
end

local function watch_tick()
    local now = Util.Now()
    -- Polled every 0.03 s (every tick or two): a tap on ARR lasts only 0.1 to 0.2 s (bombbtn.log, Oct 22 2026), and a 0.1 s poll missed it. The feed writes at 20 Hz.
    if now - watch.aar_t >= 0.03 or now < watch.aar_t then
        watch.aar_t = now
        local down = read_aar()
        if down ~= nil then
            if down and not watch.aar and Config.MAV_AAR_HANDOVER ~= false and not st.train then handover('ARR pressed', false) end
            -- A momentary ARR press (a tap, no stick movement) caged the seeker: that is how the pilot gets rid of the Maverick lock bug
            -- (user, Oct 22 2026). So when it is let go within MAV_AAR_TAP_S (0.6 s) with no slewing, the seeker counts as caged and known.
            if down and not watch.aar then watch.aar_down_t, watch.aar_moved = now, false end
            if not down and watch.aar and watch.aar_down_t and not watch.aar_moved and not st.train
                and now - watch.aar_down_t <= (Config.MAV_AAR_TAP_S or 0.6) and Config.MAV_AAR_HANDOVER ~= false then
                st.fresh, st.pos, st.rel = true, nil, nil
                -- The next full trigger is a re-cage, not a FOV change (user, Nov 10 2026: a trigger press after an ARR press desynced the FOV).
                st.arr_tap = true
                AGLog.Info('mav: ARR tapped (%.2f s), the seeker counts as caged, FOV %s', now - watch.aar_down_t, FOVS[st.fov] or '?')
            end
            watch.aar = down
            if not down then watch.slew_latch = false end
        end
        -- The pilot's weapon release button (the pickle): held for 2 s it launches a Maverick (After Launch, see cap_popped).
        if Pave.ReleaseHeld() then
            watch.rel_t0 = watch.rel_t0 or now
            if not watch.rel_long and now - watch.rel_t0 >= (Config.MAV_LAUNCH_HOLD_S or 1.2) then
                watch.rel_long = true
                st.rel_long_t = now
                AGLog.Info('mav: weapon release held %.1f s (a Maverick launch)', now - watch.rel_t0)
            end
        else
            -- The missile leaves after about 1.5 s of holding, so the button is often let go before any longer limit: a hold that long counts.
            if watch.rel_t0 and not watch.rel_long and now - watch.rel_t0 >= (Config.MAV_LAUNCH_HOLD_S or 1.2) then st.rel_long_t = now end
            watch.rel_t0, watch.rel_long = nil, false
        end
        -- Pilot slew with the forward hand control (ARR held + stick off center): the seeker has left the cage, so its position is unknown and
        -- it is no longer "fresh" (a later full trigger is then a real cage, not an FOV toggle). Pan X / Y are the stick's up-down / right-left.
        if watch.aar and Config.MAV_AAR_HANDOVER ~= false and not st.train and now - (watch.pan_t or -1) >= 0.05 or now < (watch.pan_t or -1) then
            watch.pan_t = now
            if watch.aar then
                local px, py = read_pan('x'), read_pan('y')
                local moved = (px and math.abs(px) >= 0.2) or (py and math.abs(py) >= 0.2)
                if moved then watch.aar_moved = true end
                if moved and not watch.slew_latch then
                    watch.slew_latch = true
                    handover(string.format('pilot slew input with ARR (pan %.2f / %.2f)', px or 0, py or 0), false)
                end
            end
        end
        -- The pilot's trigger at full action cages the seeker: A/B with or without ARR, D/G only with ARR held (Config.MAV_PILOT_FULL = the
        -- State value that counts as full action, 0.75 until measured; every new value is logged for the first 40 changes).
        local t = read_num(TRIG_PATH)
        if t ~= nil then
            if t ~= watch.trig_raw and watch.trig_logs < 40 then
                watch.trig_logs = watch.trig_logs + 1
                AGLog.Detail('mav: pilot trigger State = %s (ARR %s)', tostring(t), tostring(watch.aar))
            end
            if t == 0 and watch.trig_raw ~= 0 then watch.trig_zero_t = now end
            watch.trig_raw = t
            -- Position: 0 released, 1 half action, 2 full action (measured 21 Oct 2026)
            local full = t >= (Config.MAV_PILOT_FULL or 1.5)
            if full and watch.trig < 0.5 and Config.MAV_AAR_HANDOVER ~= false and master_arm_on() then
                local dg = seeker_dg()
                if not dg then
                    -- A/B: the first full action takes the cap off (as on the D/G), so After Launch advances here too (user, Oct 22 2026: it did not on the A).
                    local first_press = not st.dome_open
                    st.dome_open = true
                    handover('pilot trigger full action' .. (watch.aar and ' with ARR' or ''), true, Config.MAV_FINISH_PILOT_CAGE ~= false and not (st.job and st.job.pilot_cage))
                    if first_press then cap_popped('pilot') end
                else
                    -- D/G (user, Oct 21 2026): full trigger with ARR held = FOV change; without ARR it is a re-cage, unless the seeker is already caged. The full trigger action cages the seeker, but on a seeker that is caged or on its way back to the cage, or while the
                    -- hand control half press is held (Jester's slew), the same press switches wide / narrow instead.
                    local job = st.job
                    local first_press = not st.dome_open
                    st.dome_open = true
                    local advanced = first_press and cap_popped('pilot')
                    if first_press and not watch.aar then
                        -- The very first full trigger action on a Maverick that has not been uncaged yet removes the dome and uncages it, and does not
                        -- switch the FOV (user, Oct 22 2026: the FOV menu flipped to Wide on that press while the seeker stayed Narrow).
                        AGLog.Info('mav: seeker uncaged by the pilot, FOV %s', FOVS[st.fov])
                        if not advanced then Dbg.Notice('Maverick - Uncaged, FOV ' .. FOVS[st.fov], 3) end      -- the Next Target notice would be overwritten
                    elseif st.arr_tap and not watch.aar then
                        -- First trigger after an ARR tap: counted as a re-cage, no FOV change (handover clears the flag).
                        AGLog.Info('mav: pilot trigger after an ARR tap, counted as a re-cage, FOV stays %s', FOVS[st.fov] or '?')
                        handover('pilot trigger after ARR tap (D/G re-cage)', true, false)
                    elseif watch.aar or st.fresh or st.trig_v == 0.5 or (job and (job.phase == 'cage' or job.trig)) then
                        st.fov = (st.fov % #FOVS) + 1
                        AGLog.Info('mav: FOV %s (pilot trigger)', FOVS[st.fov])
                        Dbg.Notice('Maverick FOV: ' .. FOVS[st.fov], 3)
                        local S = package.loaded['agplus.PaveSearch']
                        if S and S.RefreshMenu then pcall(S.RefreshMenu) else pcall(Menu.Rebuild) end
                    else
                        handover('pilot trigger full action (D/G cage)', true, false)
                    end
                end
            end
            watch.trig = full and 1 or 0
        end
    end
    if now - watch.count_t >= 1.0 or now < watch.count_t then
        watch.count_t = now
        local n = 0
        local armed = false
        local list = Maverick.Loadout()
        for _, m in ipairs(list) do n = n + (m.count or 0) if m.armed then armed = true end end
        -- Auto on (Oct 21 2026): Mavericks armed, DIRECT and TV turn Jester Maverick on once. Switching it off in the menu keeps it off until
        -- the three have stopped being true and become true again. Config.MAV_AUTO_ON = false turns this off.
        local ready = armed and Maverick.ModeActive()
        if ready and not watch.ready and not st.on and Config.MAV_AUTO_ON ~= false then
            st.on = true
            st.idx = 0
            st.pos, st.rel = nil, nil
            Dbg.Notice('Jester Maverick On', 4)
            AGLog.Info('mav: Jester Maverick on by itself (Mavericks armed, DIRECT and TV)')
            local S = package.loaded['agplus.PaveSearch']
            if S and S.RefreshMenu then pcall(S.RefreshMenu) else pcall(Menu.Rebuild) end
            pcall(Menu.SetInfo, { TOP }, info_text())
        end
        watch.ready = ready
        if watch.count and n < watch.count then
            st.fresh, st.pos, st.rel = true, nil, nil
            AGLog.Info('mav: rifle (Mavericks %d -> %d), the next seeker is caged', watch.count, n)
            -- The last missile of a station leaves the loadout list (count 0), so the per-station drop below never sees it: the total confirms the launch too.
            if (st.rel_long_t and now - st.rel_long_t < 12) or (watch.rel_t0 and now - watch.rel_t0 >= (Config.MAV_LAUNCH_HOLD_S or 1.2)) then
                st.advance_pending = true
                AGLog.Info('mav: launch confirmed by the total count (After Launch: %s)', st.after_next and 'Next' or 'Stop')
            end
        end
        watch.count = n
        -- Each missile has its own cap and its own FOV (user, Oct 22 2026): a fresh D/G starts in WIDE when the cap comes off, and popping the cap
        -- does not change the FOV. So per station: a missile not yet uncaged is Wide; when one is fired (the station's count drops) the next one on
        -- that station is fresh again; changing the armed station restores the FOV and cap state that station had.
        st.stn = st.stn or {}
        local cur_ast
        for _, m in ipairs(list) do
            local rec = st.stn[m.station]
            if not rec then
                rec = { dome = false, fov = 1, count = m.count or 0 }
                st.stn[m.station] = rec
            elseif (m.count or 0) < rec.count then
                rec.dome, rec.fov = false, 1
                if m.station == st.cur_stn then st.dome_open, st.fov = false, 1 end
                AGLog.Info('mav: station %s fired (%d -> %d), the next missile there is fresh: cap on, FOV Wide', tostring(m.station), rec.count, m.count or 0)
                st.fov_dirty = true
                if (st.rel_long_t and now - st.rel_long_t < 12) or (watch.rel_t0 and now - watch.rel_t0 >= (Config.MAV_LAUNCH_HOLD_S or 1.2)) then
                    st.advance_pending = true
                    AGLog.Info('mav: launch confirmed (release held, count dropped), the next cap pop advances the target (After Launch: %s)', st.after_next and 'Next' or 'Stop')
                end
            end
            rec.count = m.count or 0
            if m.armed and not cur_ast then cur_ast = m.station end
        end
        if cur_ast and cur_ast ~= st.cur_stn then
            local old = st.cur_stn and st.stn[st.cur_stn]
            if old then old.dome, old.fov = st.dome_open and true or false, st.fov end
            local nw = st.stn[cur_ast]
            st.cur_stn = cur_ast
            if nw then
                st.dome_open, st.fov = nw.dome, nw.fov
                AGLog.Info('mav: armed station %s, cap %s, FOV %s', tostring(cur_ast), nw.dome and 'off' or 'on', FOVS[st.fov])
                st.fov_dirty = true
            end
        elseif cur_ast then
            local rec = st.stn[cur_ast]
            if rec then rec.dome, rec.fov = st.dome_open and true or false, st.fov end
        end
        if st.fov_dirty then
            st.fov_dirty = false
            local S = package.loaded['agplus.PaveSearch']
            if S and S.RefreshMenu then pcall(S.RefreshMenu) else pcall(Menu.Rebuild) end
        end
    end
end

pcall(trim_load)

local MavBehavior = Class(Behavior)
Maverick.Behavior = MavBehavior

function MavBehavior:Constructor()
    Behavior.Constructor(self)
    self.last = -10
end

-- The FOV the pilot had before a D/G search is put back once the seeker has been caged again: a full press of the stick trigger on a caged
-- seeker switches the FOV. Dropped after 25 s (the seeker was taken, or a new slew started first).
local function fov_restore_tick()
    local r = st.restore_fov
    if not r then return end
    local now = Util.Now()
    if r.press then
        if now - r.press >= 0.4 then
            cage_btn(0)
            st.fov = r.fov
            st.restore_fov = nil
            AGLog.Info('mav: FOV back to %s after the search', FOVS[st.fov])
            Dbg.Notice('Maverick FOV: ' .. FOVS[st.fov], 3)
            local S = package.loaded['agplus.PaveSearch']
            if S and S.RefreshMenu then pcall(S.RefreshMenu) else pcall(Menu.Rebuild) end
        end
        return
    end
    if now - r.t > 25 then
        st.restore_fov = nil
        AGLog.Info('mav: FOV restore dropped (the seeker was not caged in time), the FOV menu stays %s', FOVS[st.fov])
        return
    end
    if not st.job and st.fresh then
        cage_btn(1)
        r.press = now
    end
end

function MavBehavior:Tick()
    pcall(watch_tick)
    pcall(job_tick)
    pcall(fov_restore_tick)
    pcall(pick_tick)
    pcall(nudge_tick)
    pcall(autofill)
    local now = Util.Now()
    if now - self.last < 1 then return end
    self.last = now
    pcall(Menu.SetInfo, { TOP }, info_text())
end

return Maverick
