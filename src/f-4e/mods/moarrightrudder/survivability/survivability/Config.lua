-- Jester Survivability settings. Everything tunable lives here.
-- The suite is additive: it changes no stock files. Delete mods\init\survivability to remove it.

local Config = {}

-- Features
Config.COUNTERMEASURES = true   -- missile detection, warning calls and countermeasure programs
Config.ALE40_SETUP = true       -- "Setup ALE-40" entry on the Jester wheel (Systems): programs the dispenser, hands chaff to Jester

-- Logging: timing of every step goes to survivability.log ("CM:" lines) and the Jester console.
Config.LOG_TO_FILE = false      -- set true to write survivability.log (needed to send logs for a bug report)
Config.LOG_TO_CONSOLE = true
Config.LOG_MAX_BYTES = 200000
-- PATH TO EDIT: the only path you need to change. Set it to your Saved Games folder (no trailing backslash),
-- for example [[C:\Users\Pat\Saved Games]] or [[A:\Saved Games]]. The log path and the feed path below build on it.
Config.SAVED_GAMES = [[C:\Users\YOURNAME\Saved Games]]
-- The log is off by default; it needs io, see README.
Config.LOG_PATH = Config.SAVED_GAMES .. [[\DCS_F4E\jester\mods\survivability\survivability.log]]


-- Programs: press count, seconds between press starts, seconds the button is held.
Config.PROGRAMS = {
    flare   = { count = 5, interval = 0.1, hold = 0.07 },
    chaff   = { count = 6, interval = 0.5, hold = 0.10 },
    both    = { count = 5, interval = 0.3, hold = 0.10 },
}
-- Jester ticks every 0.03 to 0.1 s, so an interval or a hold is rounded up to a whole tick. At most one knob or
-- button change runs per tick, so a 0.1 s flare interval is really about 0.1 to 0.2 s in the cockpit.
-- Knob positions the programs use while they run (the WSO control unit's own knob settings are put back afterwards).
-- A program is a series of button presses, so the knobs go to single-dispense: one press, one dispense.
-- Chaff Mode knob: OFF, SGL, MULT, PROG. Flare Mode knob: OFF, SGL, PROG.
-- (Your ALE-40 setup leaves Flare Mode OFF, so without this a flare program dispenses nothing.)
Config.CHAFF_MODE = 'SGL'
Config.FLARE_MODE = 'SGL'
Config.MODE_GAP_S = 0.08       -- after switching the chaff/flare mode, before the first press

-- Which missiles Jester's eyes always see inside the ranges below:
--   'all'    every missile contact, whatever its size or plume, even behind the cockpit structure
--   'plume'  only a missile with its motor burning (and not hidden by the cockpit)
--   'off'    leave the stock random roll alone
Config.MISSILE_VISION = 'all'

-- Reaction delay: the time Jester takes to notice a missile once it is inside visibility range. far_s at far_nm, falling in a straight
-- line to near_s at near_nm and closer (BFM: seen at once). Applies to missiles seen by the object feed and by Jester's eyes.
Config.REACT = { far_nm = 30, far_s = 10, near_nm = 3, near_s = 0.5 }
-- SAM plumes: same shape, shorter times (a SAM launch is easier to pick out, and this leaves a chance against MANPADS).
Config.REACT_SAM = { far_nm = 30, far_s = 5, near_nm = 5, near_s = 3 }

-- Fighter (air-to-air) missiles are close and fast: act at once, by range.
Config.AIR = {
    visible_nm = 30,        -- a missile inside this range is seen at once (stock: random roll). 30: smoke plumes were first seen at 27 NM (R-33, in a contrail) and 31 NM (AIM-54, clear sky), tests 14 Oct 2026
    -- A launch is matched to a hostile aircraft on the missile's track (the shooter). A missile with no shooter behind it is a ground launch (SAM).
    long_tti_s = 10,        -- a missile that is further than this from impact (time) when first seen is a long-range shot Jester watches ...
    warn_tti_s = 14,        -- ... spoken "missile missile missile, <clock>" at this time to impact (only if the dump will follow) ...
    dispense_tti_s = 10,    -- ... and the countermeasure program at this time to impact. Shorter launches dispense at once, from any direction.
    rear_skip = true,       -- a watched long-range shot is NOT dispensed against while the missile is in the rear sector below
    rear_from_deg = 120,    -- (4 o'clock) the missile is behind you: you turned away, it has run out of energy; checked again every tick
    rear_to_deg = 240,      -- (8 o'clock)
    -- Which program: a launch from this close with no RWR emitter at the shooter's bearing is probably an IR missile (flares only);
    -- anything else could be either, so both are dispensed. (Lock/spike cannot be read from the RWR feed.)
    ir_range_nm = 7,
    ir_needs_quiet_rwr = true,   -- false = every launch inside ir_range_nm is treated as IR
    rwr_hour_tol = 1,            -- an RWR emitter within this many clock hours of the shooter counts as "radar on"
    shooter_lateral_m = 1500,       -- the shooter is within this (plus the fraction below of the distance flown) of the missile's track line
    shooter_lateral_frac = 0.15,
    shooter_behind_m = 400,         -- ... and not further than this ahead of the missile
    sustain_nm = 3,         -- (only used if max_bursts is above 1)
    sustain_s = 1.5,        -- (only used if max_bursts is above 1)
    max_bursts = 1,         -- one program per missile; raise for repeating bursts
}
-- SAMs are seen from far away but take a long time to arrive: warn early, dispense by time to impact.
Config.SAM = {
    visible_nm = 30,        -- seen inside this range (after the reaction delay). 30: an SA-5 plume was first seen at 29.9 NM (test 14 Oct 2026)
    warn_tti_s = 18,        -- spoken "missile missile missile, <clock>" when the time to impact drops below this: turn and notch
    dispense_tti_s = 14,    -- the countermeasure burst when the time to impact drops below this
    sustain_tti_s = 8,      -- (only used if max_bursts is above 1)
    sustain_s = 2.0,        -- (only used if max_bursts is above 1)
    max_bursts = 1,         -- one program per missile; raise for repeating bursts
    miss_growth = 0.1,      -- extra allowed miss distance per meter of range (a far SAM's path is uncertain)
}
-- RWR SAM launch (the stock "singer" call): the receiver knows a SAM is in flight long before the eyes see it.
-- If no SAM missile is being tracked visually, chaff starts RWR.first_s after the launch, then repeats while the RWR still shows the launch.
Config.RWR = { first_s = 10, repeat_s = 4, max_bursts = 1, warn = true }
-- "Singer" call for ground launches the RWR does not report (it does so only for SA-2, SA-3, SA-15 and a few others), made when the
-- missile is first seen (object feed or eyes). NEEDS THE OBJECT FEED (Config.FEED) FOR AN EARLY CALL: the feed lists the missile from
-- the launch; without it the call waits for Jester's eyes (inside SAM.visible_nm, typically some seconds after the launch) and a missile
-- that is never seen gets no call. same_site_s: no second call for the same site (same clock +-1) within this long;
-- and_s: a call this soon after another is spoken as "and singer"; rwr_cover_s: no call while the RWR itself shows a launch.
-- types: spoken system type by lower-case missile name, used when no RWR surface emitter is near that clock (the RWR's own type wins).
-- A phrase is a voice file under Sounds\Jester (SAM\sasix = "SA-6"). Add names as they appear in the log ("missile ..." in the call line).
Config.SINGER = { same_site_s = 30, and_s = 5, rwr_cover_s = 10,
    types = { ['sa3m9m'] = 'SAM/sasix' } }
-- Time to impact = range / closing speed, but a missile just off the rail is still slow, so the closing speed is never taken
-- below this (about Mach 1.5). Without it a missile launched 2 NM away looks 13 s from impact instead of about 4 s.
Config.MIN_CLOSING_MPS = 650
Config.DISPENSE_MISS_NM = 3    -- a closing missile that would pass within this of you gets countermeasures
Config.THREAT_MISS_NM = 1.5    -- warning call: closing and passing within this (stock: sign test on x and y)
Config.HORIZONTAL_MPS = 0      -- warning call: horizontal speed needed (stock 20; 0 = none, so a missile climbing straight up at you counts)
-- Task priority of the spoken warnings. Jester plays queued tasks highest priority first; stock queues every
-- call at 0, so a missile or launch warning can wait behind routine chatter already in the queue. 0 = stock.
-- (Stock scale: routine radar reports 1, countermeasure dispensing / damage 2, eject 3.)
Config.PRIORITY = { missile = 3, launch = 2 }   -- "missile, <clock>" and the SAM heads-up / RWR "singer" call
-- Initial call for a long-range shot Jester watches, and the heads-up that follows (always one of his "missile missile missile" lines:
-- missileHI15, 16 and 17 are the only ones that say it three times). Any Jester phrase names.
Config.PHRASE_LONG_LAUNCH = 'spotting/missile'   -- plain "Missile, <clock>"
Config.PHRASES_HEADSUP = { 'spotting/missileHI15', 'spotting/missileHI16', 'spotting/missileHI17' }
-- One spoken warning per direction: a "missile missile missile" (or a plain "missile") for the same clock, plus or minus one hour, within
-- this many seconds of the last one is not repeated. A salvo of two missiles, or the same missile reported by the feed and then by
-- Jester's eyes, gives one call. A different direction is always called.
Config.CALLS = { gap_s = 8 }
Config.REEVAL_S = 12          -- warning call: a missile that is not a threat yet is judged again for this long

-- Lower-case fragments of the missile's type name.
Config.IR_TYPES = { 'aim-9', 'aim9', 'r-73', 'r-60', 'r-27et', 'r-40td', 'aim-92', 'stinger', 'igla', 'strela', 'sa-7', 'sa-9',
    'sa-13', 'sa-14', 'sa-16', 'sa-18', 'sa-24', 'magic', 'python', 'mistral', 'asraam', 'iris', 'mica_ir', 'mica-ir', 'chaparral', 'rbs-70', 'ah-64' }
Config.SAM_TYPES = { 'sa-2', 'sa-3', 'sa-5', 'sa-6', 'sa-7', 'sa-8', 'sa-9', 'sa-10', 'sa-11', 'sa-13', 'sa-14', 'sa-15', 'sa-16',
    'sa-17', 'sa-18', 'sa-19', 'sa-20', 'sa-24', 'patriot', 'hawk', 'roland', 'rapier', 's-300', 's-200', 'nasams', 'buk', 'kub', 'osa',
    'tor', 'stinger', 'igla', 'strela', 'chaparral', 'rbs-70', 'avenger', 'linebacker', 'mistral', 'fim-92', 'mim-', '5v55', '48n6',
    '9m3', '9m33', '9m38', '9m311', '3m9', '2k22', 'pac-2', 'pac-3', 'aspide' }
Config.RADAR_TYPES = { 'aim-7', 'aim7', 'aim-120', 'aim120', 'aim-54', 'r-27r', 'r-27er', 'r-77', 'r-33', 'r-40tr', 'sa-2', 'sa-3', 'sa-5',
    'sa-6', 'sa-8', 'sa-10', 'sa-11', 'sa-15', 'sa-17', 'sa-19', 'sa-20', 'patriot', 'hawk', 'roland', 'aspide', 'sparrow', 'amraam',
    'sd-10', 'pl-12', 'meteor', 'mica_em', 'mica-em', 'skyflash', 'super_530', 's-300', 's-200', 'nasams', 'buk', 'kub', 'osa', 'tor' }

-- Export feed (optional): SurvFeed.lua, run by DCS's own Export.lua, writes the missiles in flight to Logs\surv_feed.txt, and the
-- suite reads it. It is the only way to see semi-active radar missiles (R-27R/ER, AIM-7, ...): the sim never hands them to Jester.
-- It needs the server to allow object export; without a feed the suite simply behaves as before.
-- The missile's type is never used: the program is chosen from the shooter's distance and the RWR, exactly as for a contact.
Config.FEED = {
    enabled = true,
    path = Config.SAVED_GAMES .. [[\DCS\Logs\surv_feed.txt]],   -- the optional feed script writes this file (folder DCS under your Saved Games; change it if your folder has another name, e.g. DCS.openbeta)
    poll_s = 0.05,          -- how often the file is read
    stale_s = 2.5,          -- the feed counts as dead when its clock has not moved for this long
    -- Dumbing Jester down from omniscient. A feed missile is only reacted to when it is inside max_nm, and react_s after it
    -- first appeared (the time to notice it). 999 / 0 = fully omniscient.
    max_nm = 30,            -- same plume-visibility limit for feed missiles (radar missiles the eyes never see)
    react_s = 0.5,
    -- Plume visibility. max_nm applies while the missile's motor burns. The feed's spd field (the missile's own speed) shows the burnout:
    -- speed falling coast_drop_mps below its peak. A coasting missile not yet sighted is only seen inside coast_nm: a tiny dark missile
    -- with no plume or smoke is hardly visible beyond a couple of NM. (Without the new SurvFeed.lua the closing speed is used instead.)
    coast_nm = 1.5,
    coast_drop_mps = 40,
    smoke_s = 10,           -- the smoke trail stays visible this long after burnout, so the max_nm range still applies
    -- A missile the normal contact path is already tracking (same range within this) is left to that path.
    match_m = 1500,
}

return Config
