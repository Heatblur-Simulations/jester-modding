-- Jester A/A+ configuration. Edit values here; nothing else needs to change.
local Config = {}

-- Mode on spawn. Set this to the mode you want Jester to start in:
--   "UNIFIED"  Jester searches and focuses on his own; slewing the cursor gives you control; a context
--              double-press (or 90 s of inactivity) gives it back  (default)
--   "PILOT"    you control the cursor and the scan; Jester only follows a contact you focus
--   "OFF"      full stock pass-through
Config.DEFAULT_MODE = "UNIFIED"

-- Logging. LOG_TO_CONSOLE uses Jester's Log(); LOG_TO_FILE appends to LOG_PATH.
-- Shipped with LOG_TO_FILE = false. For a test run set it true: the file is aaplus\aaplus.log (LOG_PATH).
Config.LOG_TO_CONSOLE = true
Config.LOG_TO_FILE = false
Config.LOG_MAX_BYTES = 200000   -- the log is appended across missions and restarted past this size
-- PATH TO EDIT: the only path you need to change. Set it to your Saved Games folder (no trailing backslash),
-- for example [[C:\Users\Pat\Saved Games]] or [[A:\Saved Games]]. The log path and the AWACS file path below build on it.
Config.SAVED_GAMES = [[C:\Users\YOURNAME\Saved Games]]
-- The log needs Jester's Lua to have io, see README.
Config.LOG_PATH = Config.SAVED_GAMES .. [[\DCS_F4E\jester\mods\aaplus\aaplus.log]]

-- Sub-system run periods in seconds (mission time).
Config.PERIOD_ENGAGEMENT = 0.5
Config.PERIOD_UI = 1.0

-- Wheel placement: item added into this stock menu.
Config.MENU_PARENT = { "Radar" }
Config.MENU_NAME = "A/A Plus"
-- Ticks to wait after a (re)spawn before registering the menu a second time.
Config.MENU_SETTLE_TICKS = 25

-- Stock bug fixes (Phase 2). Each can be switched off on its own; all are inactive when mode is OFF.
Config.ADOPT_PLAYER_LOCK = true  -- keep a lock the player made with the HCU instead of unlocking and returning to scan
Config.RELEASE_HOLD_S = 4        -- after a context press in the lock state, a lock is not adopted again for this long (lets the unlock go through)
Config.FAST_LOCK = true          -- context-button lock starts silently and outranks scan tasks; the stable-lock call follows the lock
Config.LOCK_PRIORITY = 1.5       -- task priority of the lock phase (scan work is 1, countermeasures 2, missile calls 3)
Config.FIX_NEXT_BANDIT = true    -- short press cycles bandits in priority order, not pairs() order

-- Phase 3: contact picture and threat scoring.
Config.THREAT_SORT = true         -- stock priority comparison follows the threat score
Config.PERIOD_PICTURE = 1.0
Config.HISTORY_SAMPLES = 5        -- radar hits kept per contact
Config.FORGET_AFTER = 120         -- seconds unseen before a track is dropped (stock: 2 minutes)
Config.GROUP_NM = 5               -- same-identity contacts closer than this and ...
Config.GROUP_DEG = 10             -- ... within this azimuth difference form one group
Config.MIN_CLOSURE_KT = 100       -- closing faster than this counts as hot
Config.TTM_REF_S = 300            -- time to merge at which that term reaches zero
Config.RANGE_REF_NM = 80
Config.ALT_REF_FT = 20000
Config.RECENCY_REF_S = 15
Config.LOG_PICTURE_EVERY = 0      -- seconds between picture debug lines; 0 = off
Config.W = {
    IDENT_HOSTILE = 2.0, IDENT_UNKNOWN = 1.0, IDENT_NEUTRAL = 0.0, IDENT_FRIENDLY = -100,
    TTM = 5.0,        -- time to merge, the strongest term
    RANGE = 1.0,
    AZIMUTH = 0.5,    -- off-boresight angle
    ALTITUDE = 2.0,   -- altitude advantage over us (the higher group ranks first)
    RECENCY = 0.5,    -- last radar hit
    CUE = 3.0,        -- boost for a contact that matches a cue
}

-- Phase 4: cues and directed search.
Config.SEARCH_ENABLED = true
Config.LOG_CUE_DEBUG = false        -- log radar_targets every 2 s while any exist (turn off before shipping)
Config.CONTEXT_SEARCH = true        -- context-button short press steps through cues / starts a search
Config.AUTO_SEARCH = true           -- AUTO mode starts a search for RWR and IFF cues by itself
-- Which cue Jester searches first (UNIFIED): the highest threat score. A launch warning does not count (too late
-- by then). An RWR emitter outranks a bare AWACS bogey unless the bogey is close and closing fast. Stock AWACS
-- hot/cold is closure only, so stock gets aspect points only from its measured track (3 reports).
Config.CUE_THREAT = {
    RWR = 3.0,              -- an emitter radiating at us
    IFF = 2.0,              -- a hostile IFF return
    AWACS = 0.0,            -- a bogey from an AWACS/EWRS report (its aspect, speed and time to merge carry it)
    CURSOR = 2.0,           -- a place the pilot pointed at
    TTM = 3.0, TTM_REF_S = 180,             -- time to merge: full weight at 0 s, none at TTM_REF_S or opening
    ASPECT = { HOT = 1.0, FLANKING = 0.3, FLANK = 0.3, BEAMING = -0.5, BEAM = -0.5, COLD = -1.5, DRAG = -1.5 },
    CLASS = { FIGHTER = 1.5, ATTACK = 0.8, OTHER = -0.5, HELO = -2.0 },   -- by EWRS type; unknown type (stock BRAA) 0
    SPEED = 0.5, SPEED_LO_KT = 300, SPEED_HI_KT = 700,   -- measured ground speed (two reports of the same group)
    RWR_RANGE = 2.0,        -- closeness when the only range is the RWR scope's (an emitter has no closure data)
    RANGE = 1.0,            -- closeness (0 at RANGE_REF_NM, full at 0 NM)
    UNKNOWN_RANGE_NM = 40,  -- range assumed for a cue with none (an RWR cue no contact explains)
    ELEVATION = 1.0, ELEVATION_REF_DEG = 5,  -- a contact above us (negative below)
    AZIMUTH = 0.5,          -- near the nose
}
-- Aircraft classes by the type EWRS reports (lower-case substrings; anything else is OTHER).
Config.AWACS_TYPE_CLASSES = {
    FIGHTER = { 'fulcrum', 'flanker', 'foxbat', 'foxhound', 'fishbed', 'flogger', 'fagot', 'farmer', 'fresco', 'felon',
                'fishcan', 'tomcat', 'eagle', 'hornet', 'falcon', 'viper', 'phantom', 'mirage', 'tiger', 'typhoon',
                'gripen', 'rafale', 'raptor', 'lightning', 'thunder', 'kfir', 'mig-', 'su-27', 'su-30', 'su-33', 'su-35',
                'j-11', 'jf-17', 'f-14', 'f-15', 'f-16', 'f-18', 'f/a-18', 'f-4', 'f-5', 'f-86', 'sabre', 'm-2000', 'tornado', 'fencer' },
    ATTACK = { 'frogfoot', 'fitter', 'fullback', 'harrier', 'warthog', 'thunderbolt', 'skyhawk', 'albatros', 'su-25', 'su-17',
               'su-24', 'su-34', 'a-10', 'a-4', 'av-8', 'l-39', 'c-101', 'mb-339' },
    HELO = { 'hip', 'hind', 'havoc', 'hokum', 'helix', 'hook', 'halo', 'hormone', 'haze', 'kiowa', 'apache', 'cobra', 'huey',
             'blackhawk', 'black hawk', 'seahawk', 'chinook', 'gazelle', 'lynx', 'puma', 'sea knight', 'stallion',
             'mi-', 'ka-', 'uh-', 'ah-', 'ch-', 'oh-', 'sh-', 'sa342', 'helicopter' },
}
Config.AWACS_ASSUMED_KT = 450       -- EWRS: contact speed assumed for closure when only the aspect word is known
Config.AWACS_VEL_MIN_DT_S = 8       -- two reports of a group this far apart give its velocity
Config.AWACS_VEL_MIN_REPORTS = 3   -- trust a measured velocity (speed, dead reckoning) after this many reports
Config.AWACS_VEL_SMOOTH = 0.5       -- weight of the newest velocity sample
Config.AWACS_MAX_GS_KT = 1500       -- a velocity above this is a mismatch, not a contact
Config.RWR_RANGE_SCALE_NM = 90      -- the RWR contact's `range` (0 center .. 1 edge of the scope) times this is the emitter's distance (measured: 0.388 at 36 NM, 0.322 at 30 NM, 0.273 at 25 NM)
Config.LOG_RWR_FIELDS = false       -- log every field of each RWR contact every 5 s (diagnostic)
Config.CUE_SWITCH_MARGIN = 1.0      -- a new cue must out-score the cue being searched by this much to interrupt it
Config.CUE_STALL_S = 20             -- a search that has found nothing for this long gives way to any cue that scores higher (by at least CUE_STALL_MARGIN)
Config.CUE_STALL_MARGIN = 0.3        -- small margin so a tie or near-tie does not pull Jester off a close, closing cue
Config.FOCUS_RELEASE_LOST_S = 20       -- stock's focus on a contact that has been off the scope this long is dropped, so the radar returns to its normal scan (the pilot can double-press context sooner)
-- Look-down lock preparation (DESIGN.md, L1): a long press of the context button on a contact below the horizon conditions the gain before the lock
Config.LOCKPREP_MIN_DEPR_DEG = 0.5    -- the contact must be at least this far below the horizon, else stock locks at once
Config.LOCKPREP_STEADY_HITS = 4       -- steady paint = this many paints inside LOCKPREP_STEADY_WINDOW_S ...
Config.LOCKPREP_STEADY_WINDOW_S = 6
Config.LOCKPREP_PAINT_AGE_S = 2.5     -- ... and the newest one no older than this
Config.LOCKPREP_LOST_S = 1.5          -- no paint this long = lost: carry cursor and beam elevation forward
Config.LOCKPREP_EXTRAP_MAX_S = 25    -- a lost contact is carried forward this long (the normal EXTRAP_MAX_S of 10 left the beam 8 NM behind it)
Config.LOCKPREP_ELEV_STEP_DEG = 0.3  -- a lost contact: the beam elevation is re-aimed whenever the extrapolated elevation moves this much (or the range by 3 NM)
Config.LOCKPREP_FOCUS_GRACE_S = 4     -- stock clears the focus for a moment when the paint is lost: the preparation waits this long before treating it as gone
Config.LOCKPREP_LEAD_S = 1.0         -- the cursor is put this far ahead of the contact (closure x seconds) when the lock is fired and while it completes
Config.LOCKPREP_LOCK_HOLD_S = 3      -- ... and kept there this long after the lock is fired
Config.LOCKPREP_MAX_S = 25            -- no steady paint this long: do not lock, Jester says the lock is lost
Config.CUE_TTL = 45                 -- seconds a cue stays valid
Config.CUE_COOLDOWN_S = 20          -- after a search for a cue ends, wait before searching it again
Config.CUE_TRACK_TOL_DEG = 20       -- an RWR cue this close to a real radar track only boosts that track
Config.RWR_CORRELATE_S = 5          -- an RWR-only cue waits this long for an IFF return before searching
Config.IFF_MERGE_DEG = 20           -- an IFF cue within this bearing of an RWR cue replaces it
Config.RWR_CLUSTER_DEG = 30         -- RWR emitters this close in bearing share one cue
Config.CUE_IFF_TRACK_DEG = 8        -- a radar track this close in bearing ...
Config.CUE_IFF_TRACK_NM = 10        -- ... and range ends an IFF cue (so does a track with the same id)
Config.RWR_FORGET_S = 20            -- an emitter gone this long cues again when it returns
Config.SEARCH_RANGE_NM = 40         -- range used when a cue has none (RWR)
Config.IFF_CUES = false             -- IFF-only returns are not visible to Jester; cue code kept but off
Config.SEARCH_STEP_DEG = 3.5        -- elevation bands are antenna angles: 0, then steps of this size (3.7 = minimum coverage without nutation)
Config.SEARCH_DOWN_STEP_DEG = 2.5     -- step between look-down bands (overlap for small targets in clutter); nil = same as SEARCH_STEP_DEG
Config.SEARCH_UP_STEPS = 5          -- bands above center (5 x 3.5 = up to +17.5 deg)
Config.SEARCH_DOWN_STEPS = 4        -- bands below center (4 x 2.5 = down to -10 deg)
Config.SEARCH_BUMP_LAPS = 2         -- cursor search after an up/down bump: level + the bump side only, this many laps (no bump: full pattern, up then down)
Config.SEARCH_CENTER_DEG = 1.0      -- pilot elevation within this of level counts as 'centered' (up first)
Config.SEARCH_HOLD_AUTOFOCUS = true   -- hold off stock's auto-focus while more emitters than tracks remain
Config.SEARCH_AUTOFOCUS_FLOOR_NM = 10  -- ... unless the nearest group is already closer than this
Config.SEARCH_AUTOFOCUS_MAX_S = 45     -- ... and never for longer than this in one search
Config.CUE_START_AZ = 58            -- a search only starts on a cue within this angle of the nose
Config.CUE_MAX_AZ = 62              -- a search ends when the cue swings past this (radar gimbal limit)
Config.TRACK_MEMORY_S = 30          -- a track seen this recently still counts, even when off the scope
Config.SEARCH_RESUMES = 3           -- times a search resumes for more emitters after a catch
Config.SEARCH_DOWN_GAIN = 0.63         -- coarse gain (0-1) on look-down bands, held after a find, restored later; nil = leave gain to stock
Config.SEARCH_UP_GAIN = 0.73  -- TEST 1d (0.73, tuned in look-up flights; the original was 0.75)           -- coarse gain on look-up bands (a faint contact in clear sky), restored after the search; nil = leave gain to stock
Config.SEARCH_UP_GAIN_CLUTTER_FRAC = 0.6   -- the look-up gain is dropped when the beam meets the ground at or beyond this fraction of the band's range
Config.SEARCH_SKIP_CLUTTER = true    -- skip down bands whose beam meets the ground inside the cue range
Config.SEARCH_CLUTTER_MARGIN = 0.5    -- skip a down band only when its beam meets the ground inside this fraction of the cue range
Config.SEARCH_BEAM_HALF_DEG = 3.35   -- half beamwidth for that test: 6.7 deg nutating (RDR, action switch released); use 1.85 for the 3.7 deg non-nutating beam
-- AWACS / EWRS picture (needs io in the Jester Lua state, and the hook Scripts\\Hooks\\AAPlusMessages.lua writing the file)
Config.AWACS_ENABLED = true
Config.AWACS_ELEVATION = true        -- start a search at the elevation of the cue's AWACS/EWRS contact
-- The optional AWACS hook writes this file (folder DCS under your Saved Games; change it if your folder has another name, e.g. DCS.openbeta).
Config.AWACS_FILE = Config.SAVED_GAMES .. [[\DCS\Logs\aaplus_messages.txt]]
Config.AWACS_DECL = { stock = 4.0, ewrs = 2.5 }   -- magnetic variation per source, degrees east (true = magnetic + this); measured on Caucasus
Config.AWACS_RWR_TOL_DEG = 15         -- an RWR cue (clock position only) matches a contact within this bearing
Config.AWACS_CUE_RANGE = true        -- a matched RWR cue takes the contact's range: the search sets the radar range and cursor there
Config.AWACS_REFINE_AZ = true         -- a matched cue takes the contact's bearing (the cursor is held there)
Config.AWACS_CURSOR_SNAP_DEG = 10    -- a pilot cursor cue snaps to a contact only when it is this close in bearing
Config.AWACS_QUANT_NM = 3            -- position slack for rounding (EWRS rounds bearing to 5 deg and range to 5 NM)
Config.AWACS_SPEED_KT = 350          -- how far a contact may have moved, per second of message age
Config.AWACS_MAX_AGE_S = 90          -- a contact older than this is dropped
Config.AWACS_SAME_GROUP_NM = 8       -- a new stock AWACS answer within this of an old one is the same group
Config.AWACS_DWELL = 3.5              -- seconds per band while searching for an AWACS/EWRS contact (normal SEARCH_DWELL is 2.5)
Config.AWACS_BARS = 1                -- bands either side of the contact's elevation (1 = center, +3, center, -3 per pass)
Config.AWACS_PASSES = 3              -- the pattern (center, up, center, down) is scanned this many times
Config.AWACS_FALLBACK = false        -- after the passes, also scan the normal full elevation grid (guards against a wrong match)
Config.AWACS_RECENTER_DEG = nil        -- a new report moving the contact this far (deg) re-centers the pattern (nil = the band spacing)
Config.AWACS_MAX_ELEV_DEG = nil        -- contacts above this elevation get no AWACS search (nil = the top band, 17.5)
Config.AWACS_STEP_DEG = 2.0           -- spacing of the bands around a contact's elevation
Config.AWACS_SPAN_DEG = nil           -- when set, bands further than this from the contact's elevation are dropped (nil = keep all, nearest first)
Config.SEARCH_UP_GAIN_HOLD = true      -- keep the look-up gain after the contact is found, for as long as the contact is worked, until it is gone for SEARCH_UP_GAIN_LOST_S
Config.SEARCH_UP_GAIN_LOST_S = 15     -- released once the contact has been off the scope this long
Config.CUE_NEEDS_HELD = { RWR = true, AWACS = true }  -- these cues end only when stock holds the track (focus / lock / called out), not when it is merely painted
Config.CUE_TRACK_MAX_AGE_S = 30      -- a radar return older than this (last hit) no longer satisfies a cue
Config.AWACS_NEAR_HOLD_S = 45        -- a stock report for a FARTHER group, far from the current cue, is ignored while that cue was refreshed this recently
Config.SEARCH_STALE_TRACK_S = 12     -- a track near the cue seen this recently steers the cursor's bearing during the sweep
Config.AWACS_NEW_CUE_NM = 8          -- a new BRA report this far from the one being searched restarts the search there
Config.AWACS_ONE_GAIN = true         -- a search on a reported contact keeps one gain (up if the contact is above you, down if below) on every bar
Config.SEARCH_SKIP_AUTOGAIN = true    -- experiment: stock's auto-gain / clutter-range phase is skipped for the whole search while our gain is set (not only after the handover)
Config.SEARCH_FOCUS_FOUND = true      -- a contact the search found is focused at any range (stock focuses only inside about 30 NM)
Config.AWACS_CUES = true             -- a stock BRA reply becomes a search cue: radar range and cursor go to the contact
Config.AWACS_GROUP_ALT_DEG = 2.0       -- contacts further apart vertically than this many degrees (one radar bar) at their range are separate groups
Config.AWACS_GROUP_ALT_MIN_FT = 3000    -- ... but never closer than this (altitude reports are in 1000 ft steps)
Config.AWACS_GROUP_ALT_MAX_FT = 12000   -- ... or further than this
Config.STEP_FREEZE_S = 6            -- the context-button stepping order stays fixed this long after each press
Config.STEP_UNID_MIN_HITS = 3       -- stepping also reaches radar contacts stock has not identified yet, once they have this many hits
Config.STEP_MAX_AGE_S = 15          -- stepping only reaches contacts the radar painted within this many seconds (the highlighted one always counts)
Config.EWRS_MAX_CUES = 5            -- EWRS cues kept at once (one per group, highest threat first)
Config.AWACS_EWRS_CUES = true       -- the same for the EWRS picture: one cue per group of contacts, so the context button steps through them like RWR cues
Config.AWACS_CUE_MAX_NM = 60        -- ignore reports farther than this
Config.AWACS_LOG = false             -- log each batch of contacts read (only reaches the log file when LOG_TO_FILE is on)
Config.FORGET_LOST_LOCK = true       -- forget a contact when a lock attempt is abandoned or a lock is lost
Config.FORGET_QUIET_S = 20           -- ... and keep it quiet this long if the radar finds it again
Config.LOCK_STALE_S = nil            -- refuse a lock on a contact with no radar hit for this long (nil = off; low flyers are painted only now and then)
Config.SEARCH_DWELL = 2.5             -- seconds per band
Config.SEARCH_DOWN_DWELL = 3.5        -- seconds per look-down band (low targets in clutter paint intermittently); nil = same as SEARCH_DWELL
Config.SEARCH_TIMEOUT = 0           -- extra seconds on the last band before giving up (0 = the last band dwells like the others; was 3)
Config.PILOT_OVERRIDE_S = 30        -- after the pilot breaks a search, no new search starts for this long
Config.PILOT_SLEW_DIFF = 0.06       -- cursor held this far (-1..1 units) from the cue for 1.5 s = pilot override
Config.SEARCH_AZ_TOLERANCE = 15     -- a new contact this close to the cue bearing ends the search
Config.SEARCH_RECENTER_DEG = 1.5    -- a contact found on a bar this far (deg) from its real elevation gets the beam pointed at it before the handover
Config.SEARCH_RECENTER_HOLD_S = 3.5 -- ... and waits up to this long for a fresh paint
Config.SEARCH_HOLD_S = 120               -- sideways cursor bump (the last movement before the cursor stops): the first pauses the elevation scan where it is, the next centers the elevation; held this long, no up/down scan. A vertical bump resumes scanning.
Config.EXTRAP_MAX_S = 10             -- a held contact's position is carried forward (bearing drift, closure) for at most this long between paints
Config.SEARCH_HOLD_LONG_NM = 20     -- a find farther than this gets the long hold (beam and cursor kept on it, focus at SEARCH_FOCUS_HITS or on the call-out)
Config.SEARCH_HOLD_FAR_S = 60       -- contact beyond STOCK_FOCUS_NM (stock will not focus it yet): keep the beam on it this long for stock to call it out and focus it; then Jester focuses it
Config.SEARCH_FOCUS_HITS = 5          -- a far contact with this many hits and on the scope now is focused at once, ahead of stock's call-out
Config.SEARCH_CANDIDATE_HOLD_S = 12   -- a contact painted once near the cue (not yet a two-hit track): keep the beam on its elevation this much longer for the second hit

-- Phase 5: modes.
Config.SWITCH_MARGIN = 1.0          -- a focused group keeps focus unless a rival scores this much higher
Config.STICK_EPS = 0.05             -- the stick knob differing from Jester's last command by this much = the pilot is on the stick
Config.HANDBACK_IDLE_S = 90         -- UNIFIED: pilot control returns to Jester after this long with no slew, scan or target
Config.DOUBLE_HOLDOFF_S = 20        -- UNIFIED: after a context double-press releases a focus, auto-focus stays off this long
Config.CURSOR_HOLD = true           -- PILOT: do not recenter the cursor while Jester is idle
Config.PERIOD_CURSOR = 0.1          -- seconds between cursor checks (PILOT)
Config.CURSOR_MOVE_EPS = 0.01       -- cursor movement smaller than this (-1..1 units) counts as still
Config.CURSOR_SETTLE_S = 0.3        -- the pilot let go of the cursor this long ago = they have pointed at something
Config.CURSOR_HOLD_S = 0.5          -- after the cursor stops, the interrupted scan's elevation is held this long (time for a manual lock) before the bump scan starts
Config.PILOT_SLEW_PARK_EPS = 0.015  -- idle cursor moved this far from where it was left = the pilot
Config.PILOT_SLEW_EPS = 0.02        -- cursor moved this far in one check, with no Jester move, = the pilot is slewing
Config.BUMP_EPS = 0.004             -- vertical cursor movement (per 0.15 s) that counts as a bump up or down
Config.CARRY_S = 8                  -- an interrupted scan nobody continued is dropped after this long
Config.PILOT_SLEW_FRAME_EPS = 0.003 -- per-frame cursor change that counts as the pilot slewing
Config.RANGE_BUMP_EDGE = 0.88        -- the pilot moves the cursor beyond this (0..1, scope top/bottom): Jester steps the radar range up/down once; the cursor must leave and re-enter the region for the next step
Config.RANGE_BUMP_HOLD_S = 0.1        -- ... for this long
Config.SEARCH_HOLD_S = 120               -- a sideways cursor bump (the last movement before the cursor stops) centers the elevation and holds it this long, no up/down scan
Config.PILOT_SLEW_QUIET_S = 0.7      -- no pilot-slew call within this long of Jester's own cursor move
Config.CURSOR_FOCUS = false         -- PILOT: a settled cursor always starts a search; focusing is left to the context button (true = focus a contact at the cursor instead)
Config.CURSOR_TRACK_DEG = 6         -- a contact on the scope this close to the cursor (bearing) is the one the pilot pointed at ...
Config.CURSOR_TRACK_NM = 8          -- ... if it is also this close in range
Config.PILOT_SLEW_FAR = 0.1         -- cursor further than this (-1..1 units) from where Jester wants it ...
Config.PILOT_SLEW_STALL_S = 0.5     -- ... and not getting any closer for this long = the pilot is holding it
Config.CURSOR_CENTER = 0.05         -- cursor this close to center (x, -1..1) cancels a cursor cue

-- Lock latency probe: logs each step Jester waits on after a lock request.

-- Engagement bands, nautical miles of the closest air threat.
-- BFM entry is Heatblur's own dogfight distance (JesterConstants.dogfight_distance).
Config.TRANSITION_NM = 5.0

-- Phase 7: BFM mode. Once the pilot cages / selects boresight and the fight closes to the merge,
-- Jester drops everything except lookout, threat calls, countermeasures, damage and speed calls.
Config.BFM_ENABLED = true
Config.BFM_RANGE_NM = 3.0           -- boresight/CAGE selected and a bandit inside this range = BFM
Config.BFM_EXIT_NM = 5.0            -- no bandit inside this range for BFM_EXIT_S = back to normal (gap avoids flicker)
Config.BFM_EXIT_S = 8
Config.BFM_CAGE_LOST_S = 2          -- the pilot left boresight/CAGE for this long (and the fight is not a merge) = back to normal
-- Stock behaviors silenced while in BFM (module names). Their Tick is skipped until BFM ends.
Config.BFM_MUTE = {
    'behaviors.NFO.navigation.Navigate',
    'behaviors.NFO.common.ReportTraffic',
    'behaviors.OperatePaveSpike',
    'behaviors.PrepareDscg',
}
Config.BFM_IFF_ON_LOCK = true       -- press the IFF challenge as soon as a lock is made in BFM
Config.BFM_IFF_SAY = true           -- also say "checking IFF" (the answer shows on the scope)
-- Periodic IFF challenge (Iff.lua). Not in BFM (BFM_IFF_ON_LOCK above covers a lock there); not in OFF mode.
Config.IFF_PERIODIC = true          -- Jester presses the IFF challenge button on his own while the radar is the screen in use
Config.IFF_PERIOD_S = 15            -- seconds between periodic challenges (with or without radar contacts)
Config.IFF_ON_NEW_CONTACT = true    -- challenge at once when a contact appears that has not been on the radar for IFF_NEW_FORGET_S
Config.IFF_ON_LOCK = true           -- challenge at once when a lock is made
Config.IFF_NEW_FORGET_S = 60
Config.IFF_MIN_HITS = 2             -- a radar contact counts once it has this many hits (stock ignores fewer than 2)
Config.IFF_MIN_GAP_S = 5            -- never two challenges closer together than this
Config.IFF_PRIORITY = 1.5          -- task priority of the challenge (the radar scan tasks run at 1)
Config.IFF_SAY = false              -- also say "checking IFF" on each challenge
-- Radar mode knob positions that count as off or standby (no challenges). Video Select positions that mean the scope shows the radar;
-- any other position (Pave Spike, Maverick, ...) = no challenges. An empty list turns the video check off.
Config.IFF_RADAR_OFF_STATES = { 'OFF', 'STBY', 'STANDBY' }
Config.IFF_VIDEO_RADAR_STATES = { 'OFF' }     -- read off the log, Nov 11 2026: Video Select reads OFF with the radar on the scope
Config.IFF_SCREEN_RADAR_STATES = { 'radar' }  -- Screen Mode reads radar with the radar on the scope
Config.IFF_LOG_KNOBS = false        -- log Video Select, Screen Mode and Radar Mode whenever they change (to read the real positions)
Config.SPEED_CALLS = true           -- BFM speed calls around STR speed (see below)
Config.SPEED_STR_MACH = 0.8         -- best sustained turn rate
Config.SPEED_STR_BAND_KT = 50       -- 50 kt or more above/below STR speed = the speed is called
Config.SPEED_BAND_HYST = 10         -- back inside the band by this many kt before it counts as recovered
Config.SPEED_REPEAT_S = 10          -- repeat the call this often while the speed stays outside the band
Config.SPEED_CALL_MIN_S = 5         -- never closer together than this

Config.SEARCH_UNKNOWN_GAIN = 0.73  -- TEST 1d (0.73, original 0.75)   -- gain on level/up bars of a search with no known contact elevation (nil = use the up/down rule)

return Config
