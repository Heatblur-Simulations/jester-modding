-- Jester A/G+ - configuration.
-- Edit values here; nothing else needs to change. Every key is optional: delete a line and the built-in default applies.
local Config = {}

Config.VERSION = '1.0.0'   -- see CHANGELOG.md

-- 1. YOUR PATHS (edit these first) -------------------------------------------------------------------------
-- Your Saved Games folder, no trailing backslash. Example: [[C:\Users\Pat\Saved Games]] or [[D:\Saved Games]].
Config.SAVED_GAMES = [[C:\Users\YourName\Saved Games]]
-- The DCS folder inside Saved Games: DCS for the stable version, DCS.openbeta for the open beta.
Config.DCS_SAVED_FOLDER = 'DCS'
-- The DCS install folder, no trailing backslash. Used to read each map's TACAN list (Mods\terrains\<map>\beacons.lua).
Config.DCS_INSTALL = [[C:\Program Files\Eagle Dynamics\DCS World]]

-- Written by the payload feed (feeds\Scripts\AGPlusFeed.lua, see INSTALL.md). The other feed files sit in the same Logs folder.
Config.PAYLOAD_FEED = Config.SAVED_GAMES .. '\\' .. Config.DCS_SAVED_FOLDER .. [[\Logs\agplus_payload.txt]]

-- 2. LOGGING -----------------------------------------------------------------------------------------------
-- LOG_TO_CONSOLE uses Jester's Log(); LOG_TO_FILE appends to LOG_PATH. The file log is off by default; turn it on when
-- reporting a problem.
Config.LOG_TO_CONSOLE = true
Config.LOG_TO_FILE = false
Config.LOG_MAX_BYTES = 200000   -- the log is appended across missions and restarted past this size
Config.LOG_PATH = Config.SAVED_GAMES .. [[\DCS_F4E\jester\mods\agplus\agplus.log]]

-- 3. INS UPDATE FROM TACAN (Navigation menu) --------------------------------------------------------------
-- INS update from TACAN: how far away (NM) Jester will look for a station. He tries the nearest stations first, so
-- this only matters when nothing is closer. A TACAN bearing is good to about a degree, so a far station gives a
-- position good to about 1.7 NM per 100 NM, which can be worse than the INS error being fixed.
Config.INS_MAX_RANGE_NM = 120

-- Front bearing/distance selector positions that give TACAN range: 0 = VOR/TAC, 1 = TAC, 2 = ADF/TAC (3 = Nav Comp, which is not).
-- While the selector is anywhere else the INS update items show *UNABLE*.
Config.FRONT_TACAN_POSITIONS = { 0, 1, 2 }

-- INS update: seconds Jester waits for a TACAN reading from each station before trying the next.
Config.INS_LOCK_TIMEOUT_S = 12
-- INS Fix By Bearing only uses stations nearer than this (NM); a bearing is good to about a degree.
Config.INS_BEARING_MAX_RANGE_NM = 20
-- INS update (overfly): give up and put everything back after this many seconds without an overfly.
Config.INS_OVERFLY_TIMEOUT_S = 600

-- INS Fix By Bearing: seconds Jester takes to work the position out before the fix goes in (7 minimum). The reading is
-- projected to the end of this time, so it does not change the accuracy.
Config.INS_FIX_DELAY_S = 10
Config.INS_FIX_JUMP_S = 1.7   -- INS takes the entered position this long after the FIX flip (1.73 s in two runs)

-- INS update: seconds to project the fix ahead along the ground track, to cover the time it takes to key in (the INS jumped about 3.2 s after the command in testing). 0 = off.
Config.INS_FIX_LEAD_S = 3.2

-- 4. WHEEL -----------------------------------------------------------------------------------------------------
-- Wheel placement: ONE item is added into this stock menu. Everything else lives inside it.
Config.MENU_PARENT = { "Air To Ground" }
Config.MENU_NAME = "A/G Plus"
-- Ticks to wait after a (re)spawn before registering the menu a second time.
Config.MENU_SETTLE_TICKS = 25

-- 5. WRCS OFFSET BOMBING AND PAVE SPIKE ---------------------------------------------------------------------
-- Magnetic variation used when the map is not recognized (degrees, east positive).
Config.MAG_DECLINATION_FALLBACK = 0.0
-- Longest marker list shown in a Map Marks submenu (the wheel shows at most 8 items per menu).
Config.MARKER_MENU_MAX = 7
-- Pave Spike hold aim offset: where the pod aims relative to a moving vehicle, so the laser lands on the vehicle itself.
-- RIGHT / AHEAD are in the aircraft frame (they turn with the heading). All in METERS.
Config.PAVE_AIM_OFFSET_RIGHT = 0.8   -- meters right of the aircraft heading; negative = left
Config.PAVE_AIM_OFFSET_AHEAD = -2.0  -- meters along the heading; negative = behind the target
Config.PAVE_AIM_OFFSET_RIGHT_REGULAR = 0.5   -- same, for the regular Pave Spike (no Smart/Fast-Track upgrade)
Config.PAVE_AIM_OFFSET_AHEAD_REGULAR = -1.3
-- Pave Spike on-screen debug messages ("Debug: ..."). Off for normal use.
Config.PAVE_DEBUG = false
-- Pave Spike hold on the steep part of the approach: error filter, higher = quicker but twitchier (0.25 oscillates).
Config.PAVE_HOLD_STEEP_SMOOTH = 0.55
-- 6. MAVERICK TARGET LIST (the context button opens it) ---------------------------------------------------------
-- Pause after the last press before Jester slews to the cursor (seconds).
Config.MAV_PICK_DWELL_S = 1.5
-- Start caging the seeker as soon as the list opens, while you browse. false = cage only after the pause.
Config.MAV_PICK_EARLY_CAGE = true
-- The words in brackets after each target ("slightly left, near the limit"). false = arrows only.
Config.MAV_LIST_NOTES = true
-- Symbols. Only letters, digits, spaces and . , : - + ( ) / % | < > = # _ ! ^ ' reach the screen; other symbols are dropped.
Config.MAV_LIST_RIGHT = '>'       -- repeated, one per MAV_LIST_DEG_PER_ARROW degrees right of the nose
Config.MAV_LIST_LEFT = '<'        -- repeated, left of the nose
Config.MAV_LIST_CENTER = '>^<'    -- within MAV_LIST_CENTER_DEG degrees of dead ahead
Config.MAV_LIST_OUT = '!!!'       -- outside the seeker limit (shown with an arrow: !!!> or <!!!, or !!!^ / !!!v above / below)
Config.MAV_LIST_UP = '^'
Config.MAV_LIST_DOWN = 'v'
Config.MAV_LIST_CURSOR = '=> '    -- marks the selected line
Config.MAV_LIST_DEG_PER_ARROW = 5
Config.MAV_LIST_MAX_ARROWS = 6
Config.MAV_LIST_CENTER_DEG = 2.5

-- 7. MAVERICK (AGM-65) ---------------------------------------------------------------------------------------
-- The values below are the built-in defaults, measured in the sim. Deleting a line changes nothing.
-- The A and B seekers are separate: a key ending _A applies to the A only, the plain key (or _B) to the B.
-- Set to true to show the Maverick Dev menu (trim trainer, FOV probe, rate and gimbal calibration) in the wheel.
Config.MAV_DEV_MENU = false
-- Seeker geometry and slew rate: rate (deg/s) = K x stick^2. The D/G wide rate is twice the narrow rate.
Config.MAV_GIMBAL_DEG = 30              -- gimbal limit from the aircraft datum line, all four directions
Config.MAV_GIMBAL_MARGIN = 1.0          -- Jester stays this far inside the limit
Config.MAV_RATE_K = 3.75                -- B (TV)
Config.MAV_RATE_K_A = 7.37              -- A seeker
Config.MAV_GIMBAL_DEG_A = 29.4          -- A seeker gimbal limit
Config.MAV_FOV_A_DEG = 4.34             -- A seeker picture width
Config.MAV_RATE_K_IR_NARROW = 3.75      -- D, G narrow
Config.MAV_RATE_K_IR_WIDE = 7.5         -- D, G wide
Config.MAV_RATE_P_IR = 2.0
Config.MAV_FAST_STICK_IR = 1.0
Config.MAV_MIN_RATE = 0.23              -- slowest slew Jester uses (deg/s); sets the smallest stick for every seeker
-- Picture sizes (degrees, width) used by the search
Config.MAV_FOV_B_DEG = 2.26             -- B
Config.MAV_FOV_NARROW_DEG = 2.25        -- D, G narrow (measured 2.20 x 2.30)
Config.MAV_FOV_WIDE_DEG = 4.46          -- D, G wide (measured 4.40 x 4.52)
-- Search
Config.MAV_SEARCH_SPEED = 1.5           -- deg/s along the spiral
Config.MAV_SEARCH_S = 360               -- time cap (s)
Config.MAV_SEARCH_MAX_DEG = 20          -- spiral radius cap
Config.MAV_SEARCH_GAP = 0.8             -- distance between turns, in picture widths
Config.MAV_SEARCH_DWELL_S = 0.3         -- a unit must stay in the picture this long to be added
Config.MAV_SEARCH_LOOK = true           -- long press searches where you look (false = from the boresight)
Config.MAV_SEARCH_ANCHOR = true         -- hold the pattern on a fixed ground point (false = on the boresight)
-- Detection range: the share of the pod's see range (PAVE_SEE_RANGE_M per category), large units seen at about 12 NM (TV) and 8 NM (IR wide)
Config.MAV_SEE_SCALE_TV = 0.74
Config.MAV_SEE_SCALE_INF = 0.62         -- infantry, TV
Config.MAV_SEE_SCALE_IR = 0.494         -- D, G wide
Config.MAV_SEE_SCALE_IR_NARROW = 1.0    -- D, G narrow = the pod's ranges
-- Slew, track and lock
Config.MAV_TRACK_KP = 2.0
Config.MAV_LOCK_ERR_DEG = 0.08
Config.MAV_LOCK_WAIT_S = 4.0
Config.MAV_TRACK_MAX_S = 45
Config.MAV_HITCH_S = 0.6                -- a frame hitch longer than this loses the seeker position
-- Cage and unlock timing (s)
Config.MAV_UNLOCK_S = 1.0
Config.MAV_UNLOCK_HOLD_S = 0.2
Config.MAV_CAGE_UNKNOWN_S = 6.5
Config.MAV_PILOT_CAGE_S = 4.5
Config.MAV_AAR_TAP_S = 0.75
-- Pilot actions
Config.MAV_PILOT_FULL = 1.5             -- pilot trigger Position that counts as full action (0 released, 1 half, 2 full)
Config.MAV_AAR_HANDOVER = true          -- Jester lets go when the pilot presses ARR, slews or cages
Config.MAV_REQUIRE_MASTER_ARM = true    -- the pilot trigger rules only apply with Master Arm ON
Config.MAV_AUTO_ON = true               -- Jester Maverick turns itself on once when Mavericks are armed, DIRECT and TV
Config.MAV_STEER_DG = true              -- false refuses the D and G
Config.MAV_TRIM_START_ON = true         -- the saved trim is applied from the start
-- Pave Spike and Strike List switches (defaults shown; each is read as "~= false")
Config.PAVE_AUTO_REACQUIRE = true       -- a lost hold is reacquired by Jester once the target is back inside the pod limits
Config.PAVE_LEAD = true                 -- a lead point on moving vehicles after the drag coefficient one-shot
Config.STRIKE_AUTO_FILL = true          -- units that join the target list go into empty Strike List slots
Config.STRIKE_AUTO_ADVANCE = true       -- after a release on the held Strike List target the pod moves to the next slot
Config.CONTEXT_LIST_SOURCE = 'strike'   -- what the pod's Context List steps through: 'strike' (the Strike List slots) or 'full' (the whole target list); changeable in Strike List > Manage
Config.PAVE_REMOVE_DEAD = true         -- a destroyed target leaves the target list and the Strike List (Auto Fill refills the slot)
Config.PAVE_DEAD_REDRAW = true          -- after a destroyed target is removed, send the wheel back to the Strike List page so the lists redraw (false = they update when the wheel is next opened)
return Config
