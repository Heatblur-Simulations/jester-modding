-- Pave Spike area search (TODO item 4, Phase 2).
-- With the pod in TRACK, a long context press starts a search around the spot the pod is on. Jester works out which
-- hostile ground units he could plausibly pick out there: inside the search area, in terrain line of sight from the
-- aircraft, and close enough for that kind of target to be recognizable. The result is sorted into the Pave Spike Targets
-- submenu of A/G Plus (Anti Air, Armor, Combat Vehicles, Soft Vehicles, Infantry, Structures, each with its count). Choosing
-- a target type slews the pod to the nearest one; choosing it again goes to the next.
--
-- Units come from the optional Export + hook pair (PaveProbeFeed.lua, PaveProbeHook.lua): Logs\pavespike_units.txt (what
-- exists) and Logs\pavespike_targets.txt (terrain line of sight). Both are produced only while this module keeps asking by
-- rewriting Logs\pavespike_units_req.txt.
local Class = require('base.Class')
local Behavior = require('base.Behavior')
local Config = require('agplus.Config')
local Dbg = require('agplus.PaveDebug')
local AGLog = require('agplus.Log')
local Util = require('agplus.Util')
local Menu = require('agplus.Menu')
local Pave = require('agplus.Pave')
local Ins = require('agplus.Ins')

local Search = {}

local FOLDER = (Config.PAYLOAD_FEED or ''):gsub('agplus_payload%.txt$', '')
local UNITS_FILE = FOLDER .. 'pavespike_units.txt'
local TARGETS_FILE = FOLDER .. 'pavespike_targets.txt'
local REQ_FILE = FOLDER .. 'pavespike_units_req.txt'
local STATICS_FILE = FOLDER .. 'pavespike_statics.txt'

local RADIUS = Config.PAVE_SEARCH_RADIUS_M or 2500
local SEARCH_S = Config.PAVE_SEARCH_S or 30            -- how long Jester searches before he reports
local MIN_S = Config.PAVE_SEARCH_MIN_S or 4
local MAX_S = Config.PAVE_SEARCH_MAX_S or 45
local STEP_S = Config.PAVE_SEARCH_STEP_S or 0.4
local refresh_menu
local refresh_units_cache

local R0 = Config.PAVE_SWEEP_START_M or 100
local FOV_NARROW = Config.PAVE_FOV_NARROW or 0.0395   -- measured, radians across the picture
local FOV_FILL = Config.PAVE_RECOG_FILL or 1.0         -- reach of the 'in view' circle in picture half widths: 1.0 = the picture's edge, above 1 = outside the picture
local ZOOM_NARROW = Config.PAVE_ZOOM_NARROW or 2.608
local SPIRAL_GAP = Config.PAVE_SPIRAL_GAP or 0.8     -- turns of the spiral are this many picture widths apart
local DWELL_S = Config.PAVE_SEARCH_DWELL_S or 0.3   -- a vehicle must stay inside the picture this long to count as spotted
local SPIRAL_ASPECT = Config.PAVE_SPIRAL_MIN_ASPECT or 0.6   -- the spiral is at least this tall compared with its width in the pod's picture (1 = round)
local ZOOM_IN_M = (Config.PAVE_SEARCH_ZOOM_IN_NM or 7) * 1852    -- search area farther than this: zoom in
local ZOOM_OUT_M = (Config.PAVE_SEARCH_ZOOM_OUT_NM or 4) * 1852  -- search area closer than this: zoom out
local SWEEP_RATE = Config.PAVE_SWEEP_RATE_RAD or 0.027   -- rad/s the view moves along the spiral (about 1.5 deg/s; 60% of the first 0.045)
local ZOOM_PAUSE_S = Config.PAVE_SEARCH_ZOOM_PAUSE_S or 1.2   -- the pod holds still this long after a zoom change before the spiral starts
local PODPATH = '/EO TGT Designator System/Pave Spike/Pave Spike (Local)'
local FEED_WAIT_S = Config.PAVE_SEARCH_FEED_WAIT_S or 4
local VISIBILITY = Config.PAVE_VISIBILITY or 1     -- multiplies every see-range (0.5 = haze, half the range)
local SEE = Config.PAVE_SEE_RANGE_M or { aa = 30000, armor = 30000, cv = 30000, soft = 26000, inf = 20000, struct = 30000 }

local CATS = {
    { key = 'aa',     label = 'Anti Air' },
    { key = 'armor',  label = 'Armor' },
    { key = 'cv',     label = 'Vehicles' },   -- combat and soft vehicles together (a 'soft' unit falls into this group)
    { key = 'inf',    label = 'Infantry' },
    { key = 'struct', label = 'Structures' },
}
local MAX_TYPE_ITEMS = 7

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local S = {
    state = 'idle',        -- idle | wait | reveal
    started = 0,
    aim = nil,             -- world point the pod was on
    found = {},            -- entries in reveal order
    shown = 0,
    list = {},             -- { [catkey] = { total = n, types = { { name, entries = {...} } } } }
    cursor = {},           -- per catkey|type, which entry the next press goes to
    units = {},            -- id -> latest { x, y, z } from the unit feed
    units_t = -1,
    keepalive_until = 0,
    auto_lase = (Config.PAVE_AUTO_LASE ~= false),   -- Jester switches the laser on and off by himself (menu: Laser)
    last_req = -100,
    last_read = -100,
    status = 'No search yet',
}
Search.S = S

--------------------------------------------------------------------------------
-- Pure helpers (exercised by the offline test)
--------------------------------------------------------------------------------

local INFANTRY = { 'infantry', 'soldier', 'paratrooper', 'insurgent', 'rifleman', 'manpad_crew' }
local STRUCTURE = { 'bunker', 'fortification', 'hangar', 'tower', 'building', 'barracks', 'depot', 'warehouse', 'shelter', 'pillbox', 'command_post', 'comms' }

local function has(name, words)
    local n = name:lower()
    for _, w in ipairs(words) do
        if n:find(w, 1, true) then return true end
    end
    return false
end

-- Category key from the Export type levels and the unit name. Anti Air covers everything of an air defense site, radars
-- and command vehicles included.
function Search.Classify(name, l1, l2, l3, l4)
    l2, l3 = tonumber(l2), tonumber(l3)
    if has(name, STRUCTURE) and l2 ~= 16 then return 'struct' end
    if l2 == 16 then return 'aa' end
    if has(name, INFANTRY) then return 'inf' end
    if l3 == 25 then return 'soft' end
    if l3 == 26 then return 'armor' end
    return 'cv'
end

function Search.Pretty(name)
    return (name:gsub('_', ' '))
end

local function dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function dist2(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

-- units: array of { id, x, y, z, coal, name, cat }; los: id -> true / false / nil (not known)
-- Returns the entries Jester can pick out, nearest to the aim point first, and the counts that explain what was left out.
function Search.Evaluate(units, los, selfpos, selfcoal, aim)
    local found, stat = {}, { friendly = 0, outside = 0, masked = 0, far = 0, no_los = 0, far_cats = {}, nearest_far = nil }
    for _, u in ipairs(units) do
        if u.coal == selfcoal then
            stat.friendly = stat.friendly + 1
        elseif dist2(u, aim) > RADIUS then
            stat.outside = stat.outside + 1
        elseif los[u.id] == false then
            stat.masked = stat.masked + 1
        elseif dist3(u, selfpos) > (SEE[u.cat] or 15000) * VISIBILITY then
            stat.far = stat.far + 1
            stat.far_cats[u.cat] = (stat.far_cats[u.cat] or 0) + 1
            local dd = dist3(u, selfpos)
            if not stat.nearest_far or dd < stat.nearest_far then stat.nearest_far = dd end
        else
            if los[u.id] == nil then stat.no_los = stat.no_los + 1 end
            found[#found + 1] = { id = u.id, name = u.name, cat = u.cat, x = u.x, y = u.y, z = u.z, d_aim = dist2(u, aim) }
        end
    end
    table.sort(found, function(a, b) return a.d_aim < b.d_aim end)
    return found, stat
end

-- Group entries by category and type for the wheel.
function Search.Group(entries)
    local groups = {}
    for _, c in ipairs(CATS) do groups[c.key] = { total = 0, types = {}, by = {} } end
    for _, e in ipairs(entries) do
        local g = groups[e.cat] or groups.cv
        g.total = g.total + 1
        local t = g.by[e.name]
        if not t then
            t = { name = e.name, entries = {} }
            g.by[e.name] = t
            g.types[#g.types + 1] = t
        end
        t.entries[#t.entries + 1] = e
    end
    for _, g in pairs(groups) do
        table.sort(g.types, function(a, b)
            if #a.entries ~= #b.entries then return #a.entries > #b.entries end
            return a.name < b.name
        end)
        -- Every unit gets its own name in the menu: the type and its number among the units of that type, nearest the search
        -- point first ("BTR-80 2"). A type with one unit keeps its plain name.
        for _, t in ipairs(g.types) do
            local many = #t.entries > 1
            for i, e in ipairs(t.entries) do
                e.alias = Search.Pretty(e.name) .. (many and (' ' .. i) or '')
            end
        end
    end
    return groups
end

--------------------------------------------------------------------------------
-- Files
--------------------------------------------------------------------------------

local function write_request()
    local f = io.open(REQ_FILE, 'w')
    if f then f:write(string.format('REQ %.2f\n', Util.Now())) f:close() end
    S.last_req = Util.Now()
end

-- Parsed unit feed, or nil. Returns { t, self = {x,y,z}, coal, units = { ... } }.
local function read_units()
    local f = io.open(UNITS_FILE, 'r')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    if not text or not text:find('\nEND') then return nil end
    local t = tonumber(text:match('U1 t=([%d%.]+)'))
    local sx, sy, sz = text:match('\nSELF ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)')
    if not t or not sx then return nil end
    local R = { t = t, self = { x = tonumber(sx), y = tonumber(sy), z = tonumber(sz) }, coal = text:match('\nSELFCOAL (%S+)'), units = {} }
    for id, x, y, z, coal, l1, l2, l3, l4, name, hdg in text:gmatch('\nU (%d+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) (%S+) (%S+)/(%S+)/(%S+)/(%S+) (%S+) ?h?d?g?=?([%-%d%.]*)') do
        local h = tonumber(hdg)
        if h and h < 0 then h = nil end
        R.units[#R.units + 1] = { id = tonumber(id), x = tonumber(x), y = tonumber(y), z = tonumber(z), coal = coal, name = name, cat = Search.Classify(name, l1, l2, l3, l4), hdg = h }
    end
    -- Static objects (Oct 19 2026): the Export unit list has none, so the hook half (PaveProbeHook.lua) writes them to their own
    -- file (written a moment after the unit file, about once a second while the search runs). A static on the player's own side counts as friendly (same coalition string as the player);
    -- the other side gets 'Other', so Evaluate treats it as a candidate. All statics are Structures. Off with
    -- Config.PAVE_SEARCH_STATICS = false.
    if Config.PAVE_SEARCH_STATICS ~= false then
        local sf = io.open(STATICS_FILE, 'r')
        if sf then
            local st = sf:read('*a')
            sf:close()
            local stt = st and tonumber(st:match('T1 units_t=([%d%.]+)'))
            if stt and st:find('\nEND') and math.abs(stt - t) < 6 then   -- the hook writes it a moment after the unit file; statics do not move, so a file a few seconds old is fine
                local selfside = tonumber(st:match('\nSELFSIDE (%d)'))
                for sid, x, y, z, sd, name in st:gmatch('\nS (%d+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) (%d) (%S+)') do
                    local mine = selfside ~= nil and tonumber(sd) == selfside
                    R.units[#R.units + 1] = { id = tonumber(sid), x = tonumber(x), y = tonumber(y), z = tonumber(z), coal = mine and R.coal or 'Other', name = name, cat = 'struct', static = true }
                end
            end
        end
    end
    return R
end

local function read_los(units_t)
    local f = io.open(TARGETS_FILE, 'r')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    if not text or not text:find('\nEND') then return nil end
    local t = tonumber(text:match('V3 units_t=([%d%.]+)'))
    if not t or math.abs(t - units_t) > 0.01 then return nil end
    local los = {}
    for id, v in text:gmatch('\nL (%d+) (%S)') do
        if v == '1' then los[tonumber(id)] = true elseif v == '0' then los[tonumber(id)] = false end
    end
    return los
end

--------------------------------------------------------------------------------
-- Terrain ray (Oct 19 2026): where a line from a point meets the ground, asked of the hook half (PaveProbeHook.lua), which
-- answers within a few tenths of a second. cb gets { x, y, z, dist } (y is the terrain height), or nil when the line meets no
-- terrain or nothing answers in 3 s.
--------------------------------------------------------------------------------

local RAY_REQ_FILE = FOLDER .. 'pavespike_ray_req.txt'
local RAY_FILE = FOLDER .. 'pavespike_ray.txt'
local RAY_TIMEOUT_S = 3
local ray_seq = 0
local ray_wait = nil

function Search.Ray(origin, dir, cb)
    if ray_wait then
        local old = ray_wait
        ray_wait = nil
        pcall(old.cb, nil)   -- a newer question replaces the one still waiting
    end
    local len = math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
    if len < 1e-6 then pcall(cb, nil) return end
    ray_seq = ray_seq + 1
    local id = string.format('%d%03d', math.floor(Util.Now() * 10), ray_seq % 1000)
    local f = io.open(RAY_REQ_FILE, 'w')
    if not f then pcall(cb, nil) return end
    f:write(string.format('Q1 id=%s %.2f %.2f %.2f %.6f %.6f %.6f\n', id, origin.x, origin.y, origin.z, dir.x / len, dir.y / len, dir.z / len))
    f:close()
    ray_wait = { id = id, t = Util.Now(), cb = cb }
end

local function ray_tick(now)
    local w = ray_wait
    if not w then return end
    local f = io.open(RAY_FILE, 'r')
    if f then
        local text = f:read('*a')
        f:close()
        if text and text:match('R1 id=(%d+)') == w.id and text:find('\nEND') then
            ray_wait = nil
            local x, y, z, d = text:match('\nHIT ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)')
            local hit = x and { x = tonumber(x), y = tonumber(y), z = tonumber(z), dist = tonumber(d) } or nil
            local ok, err = pcall(w.cb, hit)
            if not ok then AGLog.Info('pave: ray answer failed: %s', tostring(err)) end
            return
        end
    end
    if now - w.t > RAY_TIMEOUT_S then
        ray_wait = nil
        AGLog.Info('pave: terrain ray: no answer from the hook in %.0f s', RAY_TIMEOUT_S)
        pcall(w.cb, nil)
    end
end

--------------------------------------------------------------------------------
-- Aim point: where the pod is on the ground
--------------------------------------------------------------------------------

local function num(v)
    if type(v) == 'number' then return v end
    local ok, s = pcall(tostring, v)
    if not ok then return nil end
    return tonumber(s:match('[%-%d%.eE%+]+'))
end

-- The tracked ground point as a world position. Pod Target (Track) is relative to the aircraft in north / east / down meters.
local function pod_fov()
    local ok, f, z = pcall(function()
        return num(GetProperty(PODPATH, 'Field Of View').value), num(GetProperty(PODPATH, 'Zoom Factor').value)
    end)
    if ok and f and f > 0 and z and z > 0 then return f, z end
    return FOV_NARROW, ZOOM_NARROW
end

local function aim_point(selfpos, y0)
    -- Where the pod's line of sight meets the ground level of the units. The pod's own ground point can sit well short of
    -- that on a shallow look angle, so it is only the fallback.
    local ok, dn, de, dd = pcall(function()
        local p = GetProperty('/EO TGT Designator System/Pave Spike', 'Pod Camera Direction')
        return num(p.x), num(p.y), num(p.z)
    end)
    if ok and dn and de and dd and y0 then
        local dx, dy, dz = dn, -dd, de
        if dy < -0.01 then
            local t = (y0 - selfpos.y) / dy
            if t > 0 and t < 90000 then
                return { x = selfpos.x + dx * t, y = y0, z = selfpos.z + dz * t }
            end
        end
    end
    local ok2, n, e, d = pcall(function()
        local p = GetProperty('/EO TGT Designator System/Pave Spike', 'Pod Target (Track)')
        return num(p.x), num(p.y), num(p.z)
    end)
    if not ok2 or not n or not e or not d then return nil end
    return { x = selfpos.x + n, y = selfpos.y - d, z = selfpos.z + e }
end

local function median_y(units)
    local ys = {}
    for _, u in ipairs(units) do ys[#ys + 1] = u.y end
    if #ys == 0 then return nil end
    table.sort(ys)
    return ys[math.ceil(#ys / 2)]
end

--------------------------------------------------------------------------------
-- Search
--------------------------------------------------------------------------------

function Search.Cancel()
    if S.state == 'sweep' then S.sweep = nil end
    if S.state ~= 'idle' then
        Dbg.Say('Search Canceled')
        AGLog.Info('pave: search canceled')
        S.state = 'idle'
    end
end

local end_sweep

function Search.Active()
    return S.state == 'wait' or S.state == 'sweep'
end

function Search.EndEarly(task)
    if S.state == 'sweep' and S.sweep then
        Dbg.Say('Search Ended Early (pilot)')
        AGLog.Info('pave: search ended by the pilot')
        end_sweep('ended by pilot')
    else
        Search.Cancel()
        task:Roger()
    end
end

function Search.Start(task)
    local PaveSpike = require('other.PaveSpike')
    if not PaveSpike.IsReady() then
        AGLog.Info('pave: search refused: pod is not ready')
        task:CantDo()
        return
    end
    S.state = 'wait'
    S.started = Util.Now()
    S.aim = nil
    S.keepalive_until = S.started + FEED_WAIT_S + 2
    write_request()
    Dbg.Say('Search for Targets - Reading Target List')
    AGLog.Info('pave: search started')
    task:Roger()
end

local function finish_search(found, stat, aim, selfpos)
    S.found = found
    -- Additive like the sweep: targets already known stay, the ones found now join them.
    local merged, have = {}, {}
    for _, g in pairs(S.list or {}) do
        for _, t in ipairs(g.types or {}) do
            for _, e in ipairs(t.entries) do
                merged[#merged + 1] = e
                have[e.id] = true
            end
        end
    end
    for _, e in ipairs(found) do
        if not have[e.id] then merged[#merged + 1] = e end
    end
    S.list = Search.Group(merged)
    S.cursor = {}
    S.shown = 0
    S.state = 'reveal'
    S.reveal_start = Util.Now()
    S.status = string.format('Searching')
    local fc = {}
    for k, v in pairs(stat.far_cats) do fc[#fc + 1] = k .. '=' .. v end
    table.sort(fc)
    AGLog.Info('pave: search: aim %.0f %.0f (%.1f NM from the aircraft), %d found (friendly %d, outside area %d, masked %d, too far %d [%s, nearest %.1f NM], no los data %d)',
        aim.x, aim.z, dist3(aim, selfpos) / 1852, #found, stat.friendly, stat.outside, stat.masked, stat.far, table.concat(fc, ' '), (stat.nearest_far or 0) / 1852, stat.no_los)
end

local function say_roger()
    pcall(function()
        local Task = require('base.Task')
        GetJester():AddTask(Task:new():Roger())
    end)
end

local function say_cant_do()
    pcall(function()
        local Task = require('base.Task')
        GetJester():AddTask(Task:new():CantDo())
    end)
end

local function counts_text()
    local parts, total = {}, 0
    for _, c in ipairs(CATS) do
        local g = S.list[c.key]
        if g and g.total > 0 then
            parts[#parts + 1] = string.format('%s %d', c.label, g.total)
            total = total + g.total
        end
    end
    if total == 0 then return 'Nothing found in the area' end
    return table.concat(parts, ', ')
end

--------------------------------------------------------------------------------
-- Sweep: Jester slews the pod round the area in a spiral that starts small and grows, and a contact joins the list once
-- the spot the pod is on has passed close enough to it.
--------------------------------------------------------------------------------

local NULL_TASK = { Roger = function() end, CantDo = function() end }

local function begin_sweep(found, aim, L)
    if not L then return false end
    local now = Util.Now()
    local sw = { center = { x = aim.x, y = aim.y, z = aim.z }, theta = 0, r = 0, rho = nil, t0 = now, last = now, seen = {}, nseen = 0, maxd = 0, wide0 = Pave.PodIsWide() }
    sw.wp = { x = aim.x, y = aim.y, z = aim.z }
    for _, e in ipairs(found) do
        if e.d_aim > sw.maxd then sw.maxd = e.d_aim end
    end
    S.found, S.sweep, S.state = found, sw, 'sweep'
    -- The list builds as the picture passes over vehicles (sweep_tick), so it starts empty.
    -- A new search adds to the targets already known (Oct 19 2026): they stay in the list and are not counted as found again.
    sw.kept, sw.in_view = {}, {}
    for _, g in pairs(S.list or {}) do
        for _, t in ipairs(g.types or {}) do
            for _, e in ipairs(t.entries) do
                sw.kept[#sw.kept + 1] = e
                sw.seen[e.id] = now
            end
        end
    end
    sw.nknown = #sw.kept
    S.list = Search.Group(sw.kept)
    S.cursor = {}
    S.status = 'Searching'
    pcall(refresh_menu)
    local ok = Pave.StartSlew(NULL_TASK, function() return S.sweep and S.sweep.wp end, 'search sweep', L,
        { continuous = true, quiet = true, timeout = MAX_S + 10, ground = (Config.PAVE_SEARCH_GROUND_STEER ~= false) })
    if ok and S.sweep then S.sweep.ground = (Config.PAVE_SEARCH_GROUND_STEER ~= false) and (Config.PAVE_GROUND_STEER ~= false) end
    if not ok then
        S.sweep = nil
        return false
    end
    return true
end

function end_sweep(why)
    local sw = S.sweep
    S.sweep = nil
    local kept = sw.kept or {}
    local pod_busy = Pave.JobActive()
    Pave.Stop()
    if pod_busy then
        -- Back to where the pod was before the search, so the player's view is where they left it.
        local c = sw.center
        Pave.StartSlew(NULL_TASK, function() return c end, 'search return', nil, { quiet = true })
        -- ... and the zoom the pod had before the search (the search zooms in and out on its own), retried from the tick
        if sw.wide0 ~= nil then S.restore_zoom = { wide = sw.wide0, till = Util.Now() + 10 } end
    end
    S.list = Search.Group(kept)
    S.cursor = {}
    S.state = 'idle'
    S.status = counts_text()
    local new_n = #kept - (sw.nknown or 0)
    Dbg.Notice(string.format('Search Done - %d New Target%s (%d Known)', new_n, new_n == 1 and '' or 's', #kept))
    AGLog.Info('pave: sweep done (%s) after %.1f s: found %d targets (%d were in the search area at the start), spiral radius %.0f ft; %s',
        why, Util.Now() - sw.t0, #kept, #S.found, sw.r * 3.28084, S.status)
    refresh_menu()
    if new_n <= 0 and #kept == 0 then say_cant_do() else say_roger() end
end

local function sweep_tick(now)
    local sw = S.sweep
    local L = Pave.ReadLook()
    if not Pave.JobActive() then end_sweep('pod stopped') return end
    -- Where the pod's line of sight meets the ground at the search height. The pod's own ground point (the fallback inside aim_point) is
    -- tens of thousands of feet off beyond laser range and held the spiral at its start at long range (Oct 20 2026: 15 and 25 NM).
    local actual = L and aim_point(L.self, sw.center and sw.center.y)
    local dt = now - sw.last
    sw.last = now
    local fov, zoom = pod_fov()
    local sp = L and L.self
    if sp then
        -- The spiral is drawn in the pod's own view angles around the original aim direction, as seen from the aircraft.
        local c = sw.center
        local dx, dy, dz = c.x - sp.x, c.y - sp.y, c.z - sp.z
        local hd = math.sqrt(dx * dx + dz * dz)
        local slant = math.sqrt(hd * hd + dy * dy)
        local b0, e0 = math.atan2(dz, dx), math.atan2(dy, hd)
        local graze = math.max(math.abs(e0), 0.05)
        -- Smart zoom: far away the picture is zoomed in so vehicles can be made out, close in it is zoomed out so the area is covered.
        if Config.PAVE_SEARCH_ZOOM ~= false then
            if slant > ZOOM_IN_M then sw.want_wide = false elseif slant < ZOOM_OUT_M then sw.want_wide = true end
            if sw.want_wide ~= nil then
                local zr = Pave.SetZoom(sw.want_wide, string.format('search area %.1f NM away', slant / 1852))
                if zr == false then
                    sw.zwait = sw.zwait or now
                    if now - sw.zwait > 4 then zr = true end   -- a zoom that will not happen (masked, unreadable): carry on
                end
                if zr == false then
                    sw.hold_until = now + ZOOM_PAUSE_S      -- zooming: the pod stays put, and for a moment after
                else
                    sw.zwait = nil
                end
            end
        end
        -- Terrain-referenced spiral (Oct 19 2026): the spiral lies on the ground around the search center and is fixed to the map. Its
        -- axes come from the bearing from the aircraft to the center when the sweep started, and each step is added to the radius
        -- already covered, so the aircraft's own movement no longer drags the pattern around (the angular spiral used before was
        -- redrawn from wherever the aircraft was each tick). The picture's width on the ground sets the turn spacing and the speed.
        local W = math.max(fov * slant, 50)
        if not sw.axis then
            sw.axis = b0
            -- A ground circle is a thin sliver in the picture on a shallow look angle, so the spiral is stretched along the line of
            -- sight until it is at least SPIRAL_ASPECT as tall as wide in the picture (capped).
            sw.stretch = math.min(3, math.max(1, SPIRAL_ASPECT / math.max(math.sin(graze), 0.05)))
        end
        sw.g_theta, sw.g_rho = sw.g_theta or 0, sw.g_rho or 0   -- the spiral starts at the center, the picture the pilot left the pod on
        -- Only advance while the pod's view has caught up with the waypoint.
        local keeping_up = true
        if actual then
            local wx, wy, wz = sw.wp.x - sp.x, sw.wp.y - sp.y, sw.wp.z - sp.z
            local ax, ay, az = actual.x - sp.x, actual.y - sp.y, actual.z - sp.z
            local cs = (wx * ax + wy * ay + wz * az) / math.max(math.sqrt(wx * wx + wy * wy + wz * wz) * math.sqrt(ax * ax + ay * ay + az * az), 1)
            keeping_up = math.acos(math.max(-1, math.min(1, cs))) < math.max(fov, 0.02) * 1.5
            -- Steeply down the angle between two directions hides a large ground error: also require the ground distance to be small.
            if sw.ground and keeping_up then
                keeping_up = math.sqrt((actual.x - sw.wp.x) ^ 2 + (actual.z - sw.wp.z) ^ 2) < 1.5 * W
            end
        end
        local holding = now < (sw.hold_until or 0)
        if holding then sw.t0 = sw.t0 + dt end   -- the pause does not use up the search time
        -- The overhead pass (Oct 19 2026): while the waypoint is within PAVE_SEARCH_NADIR_DEG (7) of straight down from the aircraft,
        -- the pod's azimuth is ill defined and swings half a turn, the picture ran 3000 ft off the spiral and came back as a figure 8
        -- (logged: waypoint 0.2 NM from the aircraft at 20,000 ft, pod ground point 3000 ft away). The spiral stops, the pod is left to
        -- hold the ground point it has (the waypoint is set to it, so no stick is asked for), the pause does not use up the search
        -- time, and the spiral carries on from the same place once the aircraft has flown past. At most PAVE_SEARCH_NADIR_MAX_S (25)
        -- per search. PAVE_SEARCH_NADIR_DEG = 0 switches it off.
        local nadir_deg = Config.PAVE_SEARCH_NADIR_DEG or (sw.ground and 0 or 7)   -- ground-frame steering needs no pause
        local in_pass = false
        if nadir_deg > 0 and actual and sw.wp and (sw.pass_total or 0) < (Config.PAVE_SEARCH_NADIR_MAX_S or 25) then
            local hdw = math.sqrt((sw.wp.x - sp.x) ^ 2 + (sw.wp.z - sp.z) ^ 2)
            local nd = math.deg(math.atan2(hdw, math.max(sp.y - c.y, 1)))
            in_pass = nd < nadir_deg
        end
        if in_pass then
            sw.pass_total = (sw.pass_total or 0) + dt
            sw.t0 = sw.t0 + dt
            if not sw.in_pass then
                AGLog.Info('pave: search: the waypoint is within %.0f deg of straight down, pausing the spiral while the aircraft passes over', nadir_deg)
            end
        elseif sw.in_pass then
            AGLog.Info('pave: search: past the overhead after %.1f s, the spiral carries on', sw.pass_total or 0)
        end
        sw.in_pass = in_pass
        if keeping_up and dt > 0 and not holding and not in_pass then
            local dth = SWEEP_RATE * slant * dt / math.max(sw.g_rho, 0.5 * W)   -- the view moves SWEEP_RATE rad/s along the spiral
            sw.g_theta = sw.g_theta + dth
            sw.g_rho = sw.g_rho + SPIRAL_GAP * W * dth / (2 * math.pi)
            if sw.g_rho >= RADIUS + 0.5 * W then sw.g_theta, sw.g_rho = 0, 0 end   -- start the spiral again from the middle
        end
        local cu = sw.g_rho * math.cos(sw.g_theta)                  -- across the original line of sight (to the right)
        local cv = sw.g_rho * sw.stretch * math.sin(sw.g_theta)     -- along it
        local ca, sa = math.cos(sw.axis), math.sin(sw.axis)
        sw.wp = { x = c.x + cv * ca - cu * sa, y = c.y, z = c.z + cv * sa + cu * ca }
        if in_pass then sw.wp = { x = actual.x, y = actual.y, z = actual.z } end
        sw.r = sw.g_rho   -- for the log
        if now - (sw.spiral_log or -9) >= 2 then
            sw.spiral_log = now
            -- Where the pod's picture actually is on the ground, in the same axes as the waypoint (ahead, right), to compare the two.
            local pa_txt = 'pod ground point unknown'
            if actual then
                local ex, ez = actual.x - c.x, actual.z - c.z
                local pv, pu = ex * ca + ez * sa, -ex * sa + ez * ca
                pa_txt = string.format('pod ground point %.0f ahead / %.0f right, %.0f ft from the waypoint', pv * 3.28084, pu * 3.28084,
                    math.sqrt((actual.x - sw.wp.x) ^ 2 + (actual.z - sw.wp.z) ^ 2) * 3.28084)
            end
            AGLog.Detail('pave: spiral: radius %.0f ft, angle %.0f deg, waypoint %.0f ft ahead / %.0f ft right of the search center axis, %.1f NM from the aircraft; %s; picture %.0f ft wide, zoom %s',
                sw.g_rho * 3.28084, math.deg(sw.g_theta) % 360, cv * 3.28084, cu * 3.28084, math.sqrt((sw.wp.x - sp.x) ^ 2 + (sw.wp.z - sp.z) ^ 2) / 1852, pa_txt,
                W * 3.28084, tostring(Pave.PodIsWide and (Pave.PodIsWide() and 'wide' or 'narrow') or '?'))
        end
    end
    -- The unit feed keeps running for the whole sweep, and every enemy vehicle in it is a candidate: nothing is decided when the
    -- search starts, so a vehicle outside the first picture is found when the picture passes over it. Terrain-masked ones are
    -- skipped (the line-of-sight list comes with each feed).
    S.keepalive_until = now + 3
    if now - (sw.feed_t or -10) >= 0.5 then
        sw.feed_t = now
        local R = refresh_units_cache()
        if R and R.t ~= sw.los_t then
            local l = read_los(R.t)
            if l then sw.los, sw.los_t = l, R.t end
        end
    end
    if actual and L then
        -- A contact is picked out when it lies inside the picture and is near enough for its size at the current zoom.
        local ax, ay, az = actual.x - sp.x, actual.y - sp.y, actual.z - sp.z
        local al = math.sqrt(ax * ax + ay * ay + az * az)
        local half = fov * 0.5 * FOV_FILL
        for id, u in pairs(S.units) do
            if not sw.seen[id] and u.coal ~= S.coal and not (sw.los and sw.los[id] == false) then
                local ux, uy, uz = u.x - sp.x, u.y - sp.y, u.z - sp.z
                local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
                local cosang = (ax * ux + ay * uy + az * uz) / math.max(al * ul, 1)
                local ang = math.acos(math.max(-1, math.min(1, cosang)))
                local reach = (SEE[u.cat] or 15000) * VISIBILITY * zoom / ZOOM_NARROW
                if ang <= half and ul <= reach then
                    sw.in_view[id] = sw.in_view[id] or now
                    if now - sw.in_view[id] >= DWELL_S then
                        sw.seen[id] = now
                        sw.nseen = sw.nseen + 1
                        -- Spotted: it joins the list now, not at the end of the search.
                        local e = { id = id, name = u.name, cat = u.cat, x = u.x, y = u.y, z = u.z, d_aim = dist2(u, sw.center) }
                        sw.kept[#sw.kept + 1] = e
                        S.list = Search.Group(sw.kept)
                        S.status = counts_text()
                        pcall(refresh_menu)
                        Dbg.Say('Spotted - ' .. Search.Pretty(u.name))
                        AGLog.Info('pave: sweep spotted %s after %.1f s (%d found, %.1f NM from the aircraft, %.0f ft from the search center)', Search.Pretty(u.name), now - sw.t0, sw.nseen, ul / 1852, e.d_aim * 3.28084)
                    end
                else
                    sw.in_view[id] = nil
                end
            end
        end
    end
    Dbg.NoticeStatus(string.format('Searching - Found %d - %d s left', sw.nseen, math.max(0, math.ceil(SEARCH_S - (now - sw.t0)))))
    if now - sw.t0 >= SEARCH_S then end_sweep('search time') end
end

--------------------------------------------------------------------------------
-- Wheel
--------------------------------------------------------------------------------

local TOP_NAME = 'Pave Spike'
local FULL_TAIL = { 'Strike List', 'Full Target List' }   -- below A/G Plus
local FULL_PATH = { Config.MENU_PARENT[1], Config.MENU_NAME, 'Strike List', 'Full Target List' }

local function leaf(name, action, value, reaction)
    return Wheel.Item:new({ name = name, action = action, action_value = value, reaction = reaction or Wheel.Reaction.CLOSE_REMEMBER })
end

local function sub(name, items)
    return Wheel.Item:new({ name = name, menu = Wheel.Menu:new({ name = name, items = items }) })
end

local WHEEL_ITEMS = 8        -- Wheel.MAX_MENU_ITEMS
local UNIT_PAGE = 7          -- units on a page that is followed by another: 7 plus the Next Page item
local paged_menus = {}       -- rebuilt with the menu: { tail = path below the target menu, text = center text }

-- The units of a category in menu order: the types as before (most units first, the ones folded into "Other" last, nearest the search area first)
-- The units of a type in numbered order.
local function entries_for_other(catkey)
    local out = {}
    local g = S.list[catkey]
    if not g then return out end
    local n = #g.types
    for i = math.min(MAX_TYPE_ITEMS, n), n do
        for _, e in ipairs(g.types[i].entries) do out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return a.d_aim < b.d_aim end)
    return out
end

-- One leaf per unit. A list longer than the wheel holds is split into pages that are nested submenus: the last item of a page,
-- "Next Page (2 of 3)", opens the next one (the wheel's own back step returns to the one before). All pages are built with the
-- menu, so turning a page needs no rebuild while the wheel is open. tail = the menu's path below the target menu.
local function unit_items(key, entries, tail, title)
    local n = #entries
    local pages = 1
    do
        local r = n
        while r > WHEEL_ITEMS do r = r - UNIT_PAGE pages = pages + 1 end
    end
    local function build(first, page, ptail)
        local items = {}
        local remaining = n - first + 1
        local last = (remaining > WHEEL_ITEMS) and (first + UNIT_PAGE - 1) or n
        for i = first, last do
            local e = entries[i]
            -- Oct 22 2026: each unit opens a two item menu, Select (the old press) and Delete Unit.
            local unit_name = e.alias or Search.Pretty(e.name)
            items[#items + 1] = sub(unit_name, {
                leaf('Select', 'agp_pave_unit', tostring(e.id)),
                leaf('Delete Unit', 'agp_pave_delunit', tostring(e.id), Wheel.Reaction.NOTHING),
            })
        end
        if pages > 1 then
            paged_menus[#paged_menus + 1] = { tail = ptail, text = string.format('%s\nPage %d of %d', title, page, pages) }
        end
        if last < n then
            local nm = string.format('Next Page (%d of %d)', page + 1, pages)
            local ntail = {}
            for _, t in ipairs(ptail) do ntail[#ntail + 1] = t end
            ntail[#ntail + 1] = nm
            items[#items + 1] = sub(nm, build(last + 1, page + 1, ntail))
        end
        return items
    end
    return build(1, 1, tail)
end

-- All the units of a category in menu order: the types as before (most units first, the ones folded into "Other" last,
-- nearest the search area first), the units of a type in numbered order. The same order Next Target steps through.
local function cat_entries(catkey)
    local out = {}
    local g = S.list[catkey]
    if not g or g.total == 0 then return out end
    local n = #g.types
    local last = (n > MAX_TYPE_ITEMS) and (MAX_TYPE_ITEMS - 1) or n
    for i = 1, last do
        for _, e in ipairs(g.types[i].entries) do out[#out + 1] = e end
    end
    if n > MAX_TYPE_ITEMS then
        for _, e in ipairs(entries_for_other(catkey)) do out[#out + 1] = e end
    end
    return out
end

-- The Pave Spike menu (Oct 22 2026, was "Pave Spike Targets"): Search Area, the Laser choices and the acquisition modes. The target list moved to
-- Strike List > Manage > Full Target List (Search.BuildFullListItem); the context press list steps through the Strike List.
local function psmode_item(name, value)
    return Wheel.Item:new({ name = name, action = 'agp_wrcs_psmode', action_value = value, reaction = Wheel.Reaction.NOTHING })
end

function Search.BuildItem()
    local items = {
        leaf('Search Area', 'agp_pave_search'),
        Search.BuildLaserItem(),
        Wheel.Item:new({
            name = 'Mode',
            outer_menu = Wheel.Menu:new({
                name = 'Mode',
                items = {
                    psmode_item('12 Vis', '12VIS'),
                    psmode_item('WRCS', 'WRCS'),
                    psmode_item('9 Vis', '9VIS'),
                },
            }),
        }),
    }
    return sub(TOP_NAME, items)
end

-- Strike List > Full Target List: Refresh Target Data, Purge Targets, and every category with its units (paged). The wheel path
-- of this menu below A/G Plus is FULL_TAIL; the paged menus' page text is set on paths below it.
function Search.BuildFullListItem()
    paged_menus = {}
    local items = {
        leaf('Refresh Target Data', 'agp_pave_refresh', nil, Wheel.Reaction.NOTHING),
        leaf('Purge Targets', 'agp_pave_purge', nil, Wheel.Reaction.NOTHING),
    }
    for _, c in ipairs(CATS) do
        local g = S.list[c.key]
        if g and g.total > 0 then
            local cat_name = string.format('%s: %d', c.label, g.total)
            local tail = {}
            for _, nm in ipairs(FULL_TAIL) do tail[#tail + 1] = nm end
            tail[#tail + 1] = cat_name
            items[#items + 1] = sub(cat_name, unit_items(c.key, cat_entries(c.key), tail, c.label))
        end
    end
    return sub('Full Target List', items)
end

-- 'Target: name' line, also shown in the middle of the A/G+ main menu (Mode.lua adds it).
function Search.TargetName()
    if S.hold then return tostring(S.hold.name) end
    if S.last_hold and S.last_hold.lost then
        return tostring(S.last_hold.name) .. ((S.last_hold.reacq and Config.PAVE_AUTO_REACQUIRE ~= false) and ' (waiting for it to come into view)' or ' (lost)')
    end
    return 'none'
end

function Search.TargetLine()
    local tgt = 'none'
    if S.hold then
        tgt = tostring(S.hold.name)
    elseif S.last_hold and S.last_hold.lost then
        tgt = tostring(S.last_hold.name) .. ((S.last_hold.reacq and Config.PAVE_AUTO_REACQUIRE ~= false) and ' (waiting for it to come into view)' or ' (lost)')
    end
    return 'Target: ' .. tgt
end

-- Center text of the target menu: the weapon (the same line the A/G Plus menu shows), the selected target, and a
-- note while a search runs or when it found nothing.
local function info_text()
    local M = package.loaded['agplus.Mode']
    local weapon = '?'
    if M and M.WeaponText then
        local ok, t = pcall(M.WeaponText)
        if ok and t then weapon = t end
    end
    local drag = 'n/a'
    pcall(function() drag = require('agplus.Lgb').DialText() end)
    local laser = 'Off'
    if Search.AutoLase() then laser = 'Auto' elseif Search.LaserOn and Search.LaserOn() then laser = 'On' end
    local mode = '?'
    pcall(function() mode = require('agplus.Wrcs').AcqText() end)
    local text = string.format('Weapon: %s\n%s\nDrag Coef: %s\nLaser: %s\nMode: %s', weapon, Search.TargetLine(), drag, laser, mode)
    if Search.Active() then
        text = text .. '\nSearching'
    elseif S.status == 'Nothing found in the area' or S.status == 'Search failed' then
        text = text .. '\n' .. S.status
    end
    return text
end

refresh_menu = function()
    Menu.Rebuild()
    Menu.SetInfo({ TOP_NAME }, info_text())
    pcall(function() Menu.SetInfo(FULL_TAIL, string.format('Full Target List\n%d targets', #Search.FlatList())) end)
    -- Paged lists: the page number in the middle of the wheel.
    for _, pm in ipairs(paged_menus) do
        pcall(Menu.SetInfo, pm.tail, pm.text)
    end
end

--------------------------------------------------------------------------------
-- Going to a listed target
--------------------------------------------------------------------------------

local function entries_for(catkey, tname)
    local g = S.list[catkey]
    if not g then return {} end
    if tname ~= '*' then
        local t = g.by and g.by[tname]
        return t and t.entries or {}
    end
    return entries_for_other(catkey)
end

local function current_pos(e)
    local u = S.units[e.id]
    if u then return u end
    return e
end

-- The whole list in menu order: categories as the menu shows them, within one the types as the menu shows them (the ones
-- folded into "Other" last, nearest the search area first), and within a type the entries in the order the menu's own pick
-- cycles through them.
local function flat_list()
    local out = {}
    for _, c in ipairs(CATS) do
        for _, e in ipairs(cat_entries(c.key)) do out[#out + 1] = e end
    end
    return out
end

-- Motion prediction for a held vehicle (Oct 20 2026). The unit feed gives a position once a second, so the aim point used to jump
-- once a second and was on average half a second old. The position is carried forward from the last feed sample by the vehicle's
-- smoothed velocity (from its last few samples, see lead_tick), so the aim point moves steadily and is current. At most 1.5 s of
-- carrying (plus the look-ahead below), so a feed that stops cannot send the pod off after a vehicle that is long gone. Off with Config.PAVE_TARGET_PREDICT = false.
local function predict(id, last)
    if Config.PAVE_TARGET_PREDICT == false then return last end
    local h = S.hold
    if not h or h.id ~= id or not h.vel or not S.units_t then return last end
    local dt = Util.Now() - S.units_t
    if dt <= 0 then return last end
    if dt > 1.5 then dt = 1.5 end
    -- Plus a fixed look-ahead for the pod's own response time: the pod follows its aim point late, so the aim point is put this far
    -- ahead of the vehicle (Config.PAVE_TARGET_LEAD_S, default 1.0 s; 0 for none).
    dt = dt + (Config.PAVE_TARGET_LEAD_S or 1.0)
    return { x = last.x + h.vel.x * dt, y = last.y, z = last.z + h.vel.z * dt }
end

-- Slew to a listed vehicle and then keep the pod on it, the same hold as a context press. The pod zooms out for the slew
-- and in again once it is within a few meters of the vehicle (Pave.lua, zoom_slew). A new pick takes over from the last.
local function go_to_entry(task, e, what)
    S.keepalive_until = Util.Now() + 25
    write_request()
    Pave.Stop()
    S.hold, S.hold_pending = nil, nil
    local id, last = e.id, { x = e.x, y = e.y, z = e.z }
    local function get()
        local q = S.units[id]
        if q then last = { x = q.x, y = q.y, z = q.z } end
        if S.lead and S.lead.id == id then return S.lead.point end   -- lead mode: the pod aims at the point ahead of the vehicle
        return predict(id, last)
    end
    local ok2 = Pave.StartSlew(task, get, what, nil, { continuous = true, timeout = 3600, hold = true, zoom_slew = true, aft_ground = true })
    if ok2 then
        S.hold = { id = id, name = e.alias or Search.Pretty(e.name), get = get, last_log = Util.Now(), lase_tries = 0, last_try = -100, lased = false, spot = e.spot }
        S.last_hold = { id = id, name = S.hold.name, entry = e, lost = false }
    end
    return ok2
end

-- The index in the flat list of the entry with this id, and the list.
local function flat_index(id)
    local flat = flat_list()
    for i, e in ipairs(flat) do
        if e.id == id then return i, flat end
    end
    return nil, flat
end

ListenTo('agp_pave_goto', 'AGPlusPaveGoto', function(task, value)
    local ok, err = pcall(function()
        local raw = tostring(value)
        local catkey, tname = raw:match('^([^;]+);(.+)$')
        if not catkey then
            AGLog.Info('pave: go to refused: unreadable value %q (%s)', raw, type(value))
            task:CantDo()
            return
        end
        local entries = entries_for(catkey, tname)
        if #entries == 0 then
            local g = S.list[catkey]
            AGLog.Info('pave: go to refused: no entries for %s / %s (category total %s)', catkey, tname, g and tostring(g.total) or 'none')
            task:CantDo()
            return
        end
        local ckey = tostring(value)
        local idx = ((S.cursor[ckey] or 0) % #entries) + 1
        S.cursor[ckey] = idx
        local e = entries[idx]
        local what = string.format('go to %s %d of %d', Search.Pretty(e.name), idx, #entries)
        Dbg.Notice(string.format('Change Target - %s (%d of %d)', Search.Pretty(e.name), idx, #entries), 4)
        if go_to_entry(task, e, what) then
            -- A context press goes on from here down the list.
            local fi = flat_index(e.id)
            S.step_ref, S.step_idx = S.list, fi or 0
        end
    end)
    if not ok then
        AGLog.Info('pave: go to failed: %s', tostring(err))
        task:CantDo()
    end
end)

-- A unit picked by name from the menu (every unit has its own entry).
ListenTo('agp_pave_unit', 'AGPlusPaveUnit', function(task, value)
    local ok, err = pcall(function()
        local id = tonumber(tostring(value))
        local fi, flat = flat_index(id)
        local e = fi and flat[fi]
        if not e then
            AGLog.Info('pave: unit pick refused: id %s is not in the list', tostring(value))
            task:CantDo()
            return
        end
        Dbg.Notice(string.format('Change Target - %s (%d of %d)', e.alias or Search.Pretty(e.name), fi, #flat), 4)
        if go_to_entry(task, e, string.format('go to %s (%d of %d)', e.alias or Search.Pretty(e.name), fi, #flat)) then
            S.step_ref, S.step_idx = S.list, fi
        end
    end)
    if not ok then
        AGLog.Info('pave: unit pick failed: %s', tostring(err))
        task:CantDo()
    end
end)

-- Delete Unit from the Full Target List: the unit leaves the target list and the strike list, the menu is rebuilt and the wheel goes back to the
-- category page the unit was on (the Full Target List page when that category is now empty).
ListenTo('agp_pave_delunit', 'AGPlusPaveDelUnit', function(task, value)
    local ok, err = pcall(function()
        local id = tonumber(tostring(value))
        local fi, flat = flat_index(id)
        local e = fi and flat[fi]
        if not e then task:CantDo() return end
        local catkey
        for _, c in ipairs(CATS) do
            for _, x in ipairs(cat_entries(c.key)) do
                if x.id == id then catkey = c.key break end
            end
            if catkey then break end
        end
        local name = e.alias or Search.Pretty(e.name)
        local T = package.loaded['agplus.Targets']
        if T and T.DeleteId then pcall(T.DeleteId, id) end
        Search.RemoveUnit(id)
        Dbg.Notice('Deleted - ' .. tostring(name), 4)
        task:Roger()
        pcall(refresh_menu)
        local path = FULL_PATH
        local g = catkey and S.list[catkey]
        if g and g.total > 0 then
            local label
            for _, c in ipairs(CATS) do if c.key == catkey then label = c.label end end
            path = {}
            for _, nm in ipairs(FULL_PATH) do path[#path + 1] = nm end
            path[#path + 1] = string.format('%s: %d', label, g.total)
        end
        local okn, errn = pcall(Wheel.NavigateTo, path)
        if not okn then AGLog.Info('pave: delete unit: Wheel.NavigateTo failed: %s', tostring(errn)) end
    end)
    if not ok then
        AGLog.Info('pave: delete unit failed: %s', tostring(err))
        pcall(function() task:CantDo() end)
    end
end)

function Search.HasList()
    return #flat_list() > 0
end

-- For Targets.lua (Strike List, Oct 21 2026): the list in menu order, the entry the pod holds now, a way to send the pod to an
-- entry without a task, and a menu refresh that also re-sends the page text.
function Search.FlatList()
    return flat_list()
end

function Search.CurrentEntry()
    local lh = S.last_hold
    if S.hold and lh and lh.entry and lh.id == S.hold.id then return lh.entry end
    return nil
end

function Search.GoToEntry(e, what)
    return go_to_entry(NULL_TASK, e, what or ('go to ' .. tostring(e.alias or e.name)))
end

-- Marks the hold that was just started as one the Strike List chose: its laser cue waits until the aircraft is closing on it.
function Search.FlagHold(key)
    if S.hold then S.hold[key] = true end
end

-- Keeps the unit feed running for a few seconds (Maverick dry run reads live positions).
function Search.TouchFeed(seconds)
    S.keepalive_until = math.max(S.keepalive_until or 0, Util.Now() + (seconds or 3))
    write_request()
end

function Search.Cats()
    return CATS
end

function Search.RefreshMenu()
    if refresh_menu then refresh_menu() end
end

-- Short context press with a target list: the next vehicle in the list, and round to the first after the last. Returns false
-- (the press is then handled as before) when there is no list, a search is running, or the pod is not in track.
function Search.StepTarget(task, from_id, dir)
    dir = dir or 1
    local handled = false
    local ok, err = pcall(function()
        if Search.Active() then return end
        local flat = flat_list()
        if #flat == 0 then return end
        if S.step_ref ~= S.list then S.step_ref, S.step_idx = S.list, 0 end
        -- Carry on from the vehicle that was held, wherever it is in the list.
        if from_id then
            local fi = flat_index(from_id)
            if fi then S.step_idx = fi end
        end
        local idx
        if dir < 0 then
            if (S.step_idx or 0) < 1 then S.step_idx = 1 end   -- nothing selected yet: back from the first is the last
            idx = ((S.step_idx - 2) % #flat) + 1
        else
            idx = ((S.step_idx or 0) % #flat) + 1
        end
        handled = true
        S.step_idx = idx
        local e = flat[idx]
        Dbg.Notice(string.format('Change Target - %s In List: %s (%d of %d)', dir < 0 and 'Previous' or 'Next', e.alias or Search.Pretty(e.name), idx, #flat), 4)
        AGLog.Info('pave: %s target %d of %d in the list', dir < 0 and 'stepping back to' or 'stepping on to', idx, #flat)
        go_to_entry(task, e, string.format('%s %s %d of %d', dir < 0 and 'step back to' or 'step to', Search.Pretty(e.name), idx, #flat))
    end)
    if not ok then
        AGLog.Info('pave: step failed: %s', tostring(err))
        if not handled then return false end
        task:CantDo()
    end
    return handled
end

ListenTo('agp_pave_search', 'AGPlusPaveSearch', function(task)
    local ok, err = pcall(function()
        if not Pave.PodInTrackIdle() then
            AGLog.Info('pave: search refused: pod is not in track')
            task:CantDo()
            return
        end
        Search.Start(task)
    end)
    if not ok then
        AGLog.Info('pave: search failed: %s', tostring(err))
        task:CantDo()
    end
end)

-- Menu: Search Area; Reacquire/Next Target; Previous Target. After a hold was lost the first Reacquire/Next press goes back to that
-- target and the next ones step back through the list.
-- The wheel only redraws the center text and the page when it is told to navigate (the same trick as Refresh Target Data), so a step
-- that changes the target redraws the page too (Oct 20 2026: the Target line did not change after Next / Previous Target).
local function redraw_wheel()
    -- Live update: send the center text again straight away (the cache is cleared so it goes out even if the text looks unchanged).
    -- The page redraw (NavigateTo) is only a fallback, Config.PAVE_WHEEL_REDRAW = true.
    pcall(function() Menu.ClearInfoCache(); Menu.SetInfo({ TOP_NAME }, info_text()) end)
    if Config.PAVE_WHEEL_REDRAW == true then
        pcall(refresh_menu)
        pcall(Wheel.NavigateTo, { Config.MENU_PARENT[1], Config.MENU_NAME, TOP_NAME })
    end
end

-- Next / Previous Target (menu) go from the current target: the one held, else the one Jester is waiting to reacquire, else there is no
-- current target and Next goes to the first in the list and Previous to the last. While the pod sits in memory with a reacquire pending
-- the new target only becomes the one to reacquire (Jester goes to it by himself when it is inside the pod limits).
local function step_from_current(task, dir)
    local lh = S.last_hold
    local ref
    if S.hold then
        ref = S.hold.id
    elseif lh and lh.lost and not Search.Active() then
        ref = lh.id
        local pm
        pcall(function() pm = num(GetProperty('/EO TGT Designator System/Pave Spike', 'Operation Mode').value) end)
        if lh.reacq and Search.ReacquirePending() and pm == 2 and Config.PAVE_AUTO_REACQUIRE ~= false then
            -- Pod in memory, reacquire pending: only the target to reacquire changes (Jester goes to it when it is inside the pod limits).
            local ok = Search.SwitchPending(task, dir)
            redraw_wheel()
            return ok
        end
        if dir > 0 and lh.entry then
            -- A hold the player dropped on purpose (double press), or lost with the pod out of memory: Reacquire / Next goes back to it first.
            Dbg.Say('Reacquire - ' .. tostring(lh.name))
            AGLog.Info('pave: reacquiring the last target %s', tostring(lh.name))
            local ok = go_to_entry(task, lh.entry, 'reacquire ' .. tostring(lh.name))
            redraw_wheel()
            return ok
        end
    elseif lh and lh.reacq and Search.ReacquirePending() then
        ref = lh.id
    end
    if ref == nil then S.step_idx = 0 end
    local ok = Search.StepTarget(task, ref, dir)
    redraw_wheel()
    return ok
end

ListenTo('agp_pave_next', 'AGPlusPaveNext', function(task)
    local ok, handled = pcall(step_from_current, task, 1)
    if not ok or not handled then
        if not ok then AGLog.Info('pave: next target failed: %s', tostring(handled)) end
        task:CantDo()
    end
end)

ListenTo('agp_pave_prev', 'AGPlusPavePrev', function(task)
    local ok, handled = pcall(step_from_current, task, -1)
    if not ok or not handled then
        if not ok then AGLog.Info('pave: previous target failed: %s', tostring(handled)) end
        task:CantDo()
    end
end)

Menu.Provide(TOP_NAME, Search.BuildItem)

--------------------------------------------------------------------------------
-- Behavior
--------------------------------------------------------------------------------

local SearchBehavior = Class(Behavior)
Search.Behavior = SearchBehavior

function SearchBehavior:Constructor()
    Behavior.Constructor(self)
end

-- Dead targets (Nov 11 2026). The unit feed lists every live ground and ship unit within 45 km (400 at most, nearest first), so a listed
-- unit that stays out of fresh samples while it is well inside that range has been destroyed (or has despawned). It leaves the target list
-- and the Strike List, and Auto Fill refills the freed slot. A unit that is out of the feed's reach cannot be judged and stays. Statics are
-- never judged (the statics file can be missing and a destroyed static stays listed). The unit being held is left until the hold ends.
-- Off with Config.PAVE_REMOVE_DEAD = false.
local FEED_RANGE_M, FEED_MAX = 45000, 400   -- PaveProbeFeed.lua: UNITS_RANGE, UNITS_MAX
local DEAD_MARGIN_M = 5000                  -- only units this far inside the feed range are judged
local DEAD_MISSES, DEAD_MIN_S = 3, 2.0      -- samples without the unit, and the time over which they were missed
local DEAD_PULSE_S, DEAD_PULSE_ON_S = 8, 3.5   -- while idle, ask the unit feed for 3.5 s every 8 s (it then writes once a second and lingers about 4 s)
local dead = { miss = {}, last = {}, statics = {}, t = -1 }

local function check_dead(R)
    if Config.PAVE_REMOVE_DEAD == false then return end
    if R.t < dead.t then dead.miss, dead.last = {}, {} end   -- the mission was restarted
    dead.t = R.t
    local ground, farthest = 0, 0
    for _, u in ipairs(R.units) do
        if u.static then
            dead.statics[u.id] = true
        else
            ground = ground + 1
            local d = dist2(u, R.self)
            if d > farthest then farthest = d end
        end
    end
    -- No ground units at all is a feed glitch, not a wiped-out target list. During a search the list is being rebuilt, so wait.
    if ground == 0 or S.state ~= 'idle' then dead.miss = {} return end
    local range = FEED_RANGE_M - DEAD_MARGIN_M
    if ground >= FEED_MAX then range = math.min(range, farthest - 2000) end   -- a full feed stops at its farthest unit
    local T = package.loaded['agplus.Targets']
    local watch = {}
    for _, e in ipairs(flat_list()) do
        if e.id and e.id >= 0 and not e.spot then watch[e.id] = e end
    end
    if T and T.Slots then
        for _, e in pairs(T.Slots()) do
            if e and e.id and e.id >= 0 and not e.spot and not watch[e.id] then watch[e.id] = e end
        end
    end
    local gone, ngone = {}, 0
    for id, e in pairs(watch) do
        local u = S.units[id]
        if u then
            dead.last[id] = { x = u.x, z = u.z }
            dead.miss[id] = nil
        elseif not dead.statics[id] then
            local p = dead.last[id] or e
            if p.x and p.z and dist2(p, R.self) <= range then
                local m = dead.miss[id]
                if not m then m = { n = 0, t0 = R.t } dead.miss[id] = m end
                m.n = m.n + 1
                -- A hold on a destroyed target never ends by itself (the pod keeps holding the last position), so the held unit is judged like any other;
                -- only a hold that is still being designated waits.
                if m.n >= DEAD_MISSES and R.t - m.t0 >= DEAD_MIN_S and not S.hold_pending then
                    gone[id] = e
                    ngone = ngone + 1
                end
            else
                dead.miss[id] = nil   -- out of the feed's reach: no way to tell
            end
        end
    end
    if ngone == 0 then return end

    local flat = flat_list()
    local out = {}
    for _, e in ipairs(flat) do
        if not gone[e.id] then out[#out + 1] = e end
    end
    if #out < #flat then
        S.list = Search.Group(out)
        S.af_ref = S.list   -- the refill below is called directly
        S.step_ref, S.step_idx = nil, 0
        S.status = counts_text()
    end
    local freed, first, current = 0, nil, nil
    local cur_id = (S.last_hold and S.last_hold.id) or (S.hold and S.hold.id)
    local advance_at   -- Strike List slot the destroyed held unit sat in (Auto Advance on)
    if S.hold and gone[S.hold.id] then
        cur_id = S.hold.id
        -- Auto Advance: the slot is noted before it is cleared; the next slot is picked after every destroyed unit is out (two can die together).
        if T and T.AdvanceSlotOf then
            local okn, at = pcall(T.AdvanceSlotOf, S.hold.id)
            if okn then advance_at = at end
        end
        if Search.EndDeadHold then pcall(Search.EndDeadHold) end   -- the pod lets go of the destroyed target, the laser goes off
    end
    for id, e in pairs(gone) do
        if T and T.RemoveDead then freed = freed + T.RemoveDead(id) end
        local lh = S.last_hold
        if lh and lh.id == id then S.last_hold = nil end   -- ends the reacquire of a target that no longer exists
        if cur_id ~= nil and id == cur_id then current = e end
        dead.miss[id], dead.last[id] = nil, nil
        first = first or e
    end
    AGLog.Info('pave: %d destroyed target(s) removed (%s), %d strike list slot(s) freed, %d targets left%s', ngone, tostring(first.name), freed, #out,
        current and ' (the current target)' or '')
    -- Only the current target (the one held or last held) is announced; any other unit leaving the list, whoever destroyed it, goes quietly.
    if current then
        Dbg.Notice('Target Destroyed - ' .. tostring(current.alias or Search.Pretty(current.name or '?')), 4)
    end
    local advance_to
    if advance_at and T and T.NextSlotFrom then
        local okn, nxt = pcall(T.NextSlotFrom, advance_at)   -- before the refill, so a refilled slot is not preferred over the ones already there
        if okn then advance_to = nxt end
    end
    if T and T.AutoFill then pcall(T.AutoFill, true) end   -- quiet: the menu is rebuilt next
    if advance_at and not advance_to and T and T.NextSlotFrom then
        local okn, nxt = pcall(T.NextSlotFrom, advance_at)   -- nothing was left, the refill may have put a unit in
        if okn then advance_to = nxt end
        if not advance_to and T.Slots then
            local oks, sl = pcall(T.Slots)
            if oks and sl and sl[advance_at] then advance_to = advance_at end
        end
    end
    if advance_at then
        if advance_to then
            AGLog.Info('pave: the held target was destroyed (slot %d), going on to slot %d', advance_at, advance_to)
        else
            AGLog.Info('pave: the held target was destroyed (slot %d), no other slot is filled', advance_at)
            Dbg.Notice('Strike List Complete', 3)
        end
    end
    if advance_to then S.adv_kill = { slot = advance_to, t = Util.Now() } end
    pcall(refresh_menu)
    -- The wheel only redraws its pages when told to navigate (what Refresh Target Data does), so the lists are sent back to the Strike List page.
    -- Config.PAVE_DEAD_REDRAW = false skips this (the lists then show the change the next time the wheel is opened or refreshed).
    if Config.PAVE_DEAD_REDRAW ~= false then
        pcall(Wheel.NavigateTo, { Config.MENU_PARENT[1], Config.MENU_NAME, 'Strike List' })
    end
end

refresh_units_cache = function()
    local R = read_units()
    if R and R.t ~= S.units_t then
        S.units_t = R.t
        S.coal = R.coal
        local fresh = {}
        for _, u in ipairs(R.units) do fresh[u.id] = u end
        S.units = fresh
        local okd, errd = pcall(check_dead, R)
        if not okd then AGLog.Info('pave: dead target check failed: %s', tostring(errd)) end
    end
    return R
end

--------------------------------------------------------------------------------
-- Hold: the player puts the crosshair on something and presses short; Jester keeps it there.
--------------------------------------------------------------------------------

local LIST_MATCH_DEG = Config.PAVE_LIST_MATCH_DEG or 0.5   -- with a target list, how close to the crosshair counts as "under" it
local HOLD_MATCH_DEG = Config.PAVE_HOLD_MATCH_DEG or 0.5     -- how far from the crosshair a unit may be and still be the one meant
local HOLD_LOG_S = 3
local LASE_RANGE_M = (Config.PAVE_LASE_RANGE_FT or 70000) * 0.3048   -- the pod ranges with the laser inside this slant range
local LASE_STOP_M = (Config.PAVE_LASE_STOP_FT or 25000) * 0.3048     -- after the pass, the laser goes off at this slant range
local LASE_LEAD_S = Config.PAVE_LASE_LEAD_S or 4                     -- the trigger sequence takes a few seconds, so start it this long before the range limit
local PASS_MARGIN_M = 300                                             -- the range has grown this much past its minimum: passed

local function laser_raw()
    local ok, v = pcall(function() return GetProperty('/EO TGT Designator System/Pave Spike', 'Fire Laser').value end)
    if not ok then return 'err' end
    return tostring(v):lower()
end

-- true / false, or nil when the value can't be read or isn't recognized
local function laser_on()
    local t = laser_raw()
    if t == 'true' or t == '1' or t == '1.0' then return true end
    if t == 'false' or t == '0' or t == '0.0' then return false end
    return nil
end

function Search.LaserOn() return laser_on() end

-- Two-stage click and release toggles the laser; with the pod already in TRACK it leaves the mode alone.
local function laser_toggle()
    pcall(function()
        local Task = require('base.Task')
        GetJester():AddTask(Task:new():ClickSequenceFast('Antenna Trigger', 'RELEASED', 'HALF_ACTION', 'FULL_ACTION', 'HALF_ACTION', 'RELEASED'))
    end)
end

local function pod_dir()
    local ok, n, e, d = pcall(function()
        local p = GetProperty('/EO TGT Designator System/Pave Spike', 'Pod Camera Direction')
        return num(p.x), num(p.y), num(p.z)
    end)
    if not ok or not n or not e or not d then return nil end
    return { x = n, y = -d, z = e }   -- world: x north, y up, z east
end

local function angle_between(a, b)
    local la = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
    local lb = math.sqrt(b.x * b.x + b.y * b.y + b.z * b.z)
    local c = (a.x * b.x + a.y * b.y + a.z * b.z) / math.max(la * lb, 1e-9)
    return math.deg(math.acos(math.max(-1, math.min(1, c))))
end

local function pod_ground_dist(sp, u)
    local d
    pcall(function()
        local p = GetProperty('/EO TGT Designator System/Pave Spike', 'Pod Target (Track)')
        local n, e, dd = num(p.x), num(p.y), num(p.z)
        d = dist3({ x = sp.x + n, y = sp.y - dd, z = sp.z + e }, u)
    end)
    return d
end

-- Offset between where the pod says it looks and the true direction to the unit, in aircraft-frame degrees.
local function offset_to(sp, dir, u)
    local paz = math.deg(math.atan2(dir.z, dir.x)) % 360
    local pel = math.deg(math.asin(math.max(-1, math.min(1, dir.y / math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)))))
    local uaz, uel = Pave.Direction(sp, u)
    local haz, hel = Pave.ToBody(paz, pel, sp.heading, sp.pitch, sp.bank)
    local waz, wel = Pave.ToBody(uaz, uel, sp.heading, sp.pitch, sp.bank)
    return ((haz - waz + 180) % 360) - 180, hel - wel, ((paz - uaz + 180) % 360) - 180, pel - uel
end

-- Purge Targets: forget every target. Any search stops, the hold ends (the pod stays where it is), the laser goes off with a hold
-- and the list, the last hold and the reacquire request are cleared.
ListenTo('agp_pave_refresh', 'AGPlusPaveRefresh', function(task)
    pcall(function()
        pcall(refresh_menu)
        local okn, errn = pcall(Wheel.NavigateTo, FULL_PATH)
        if not okn then AGLog.Info('pave: refresh: Wheel.NavigateTo failed: %s', tostring(errn)) end
        Dbg.Say('Target Data Refreshed')
        task:Roger()
    end)
end)

ListenTo('agp_pave_purge', 'AGPlusPavePurge', function(task)
    local ok, err = pcall(function()
        if Search.Active() then Search.Cancel() end
        local h = S.hold
        S.hold_pending = nil
        if h then
            if Pave.JobActive() then Pave.Stop() end
            if laser_on() then laser_toggle() end
        end
        S.hold = nil
        S.last_hold = nil
        S.list = Search.Group({})
        S.step_ref, S.step_idx = nil, 0
        S.status = counts_text()
        local T = package.loaded['agplus.Targets']
        if T and T.PurgeAll then pcall(T.PurgeAll) end
        AGLog.Info('pave: targets purged')
        Dbg.Say('Targets Purged')
        -- Heatblur's own menus do this after changing a menu: rebuild it, then Wheel.NavigateTo its path from an item that keeps the
        -- wheel open. The open wheel is redrawn at the target menu with the new contents (the menu is not redrawn by a rebuild alone).
        pcall(refresh_menu)
        local okn, errn = pcall(Wheel.NavigateTo, FULL_PATH)
        if not okn then AGLog.Info('pave: purge: Wheel.NavigateTo failed: %s', tostring(errn)) end
        task:Roger()
    end)
    if not ok then
        AGLog.Info('pave: purge failed: %s', tostring(err))
        task:CantDo()
    end
end)

-- First double press: let go of whatever Jester is doing with the pod without caging it. A running search is canceled; a hold
-- (or a watch, or a look-there slew) is stopped, the laser goes off and the pod stays in track where it is, free for the
-- player to slew or to start another search (the last hold stays reacquirable from the menu). Returns true if something
-- was released; false means Jester was idle, so the caller cages the pod.
function Search.ReleaseHold()
    -- Any double press ends a pending reacquire request, whether or not a hold is active (the hold may already be lost).
    if S.last_hold then S.last_hold.reacq = nil end
    if Search.Active() then
        Search.Cancel()
        AGLog.Info('pave: double press: search canceled, pod left as it is')
        return true
    end
    local h = S.hold
    if not h and not S.hold_pending and not Pave.JobActive() then return false end
    S.hold_pending = nil
    if Pave.JobActive() then Pave.Stop() end
    if h then
        if laser_on() then laser_toggle(); AGLog.Info('pave: laser off with the hold released') end
        if S.last_hold and S.last_hold.id == h.id then S.last_hold.lost = true S.last_hold.reacq = nil end   -- a double press ends the reacquire request
        Dbg.Notice('Hold Released - You Have The Pod', 4)
        AGLog.Info('pave: double press: hold on %s released, pod left in track', tostring(h.name))
    else
        Dbg.Notice('Pod Released - You Have The Pod', 4)
        AGLog.Info('pave: double press: pod job stopped, pod left in track')
    end
    S.hold = nil
    pcall(refresh_menu)
    return true
end

-- The held target was destroyed (check_dead): the hold ends, the laser goes off and the pod stays in track where it is. No reacquire is wanted
-- (the target no longer exists); the caller removes it from the lists and announces it.
function Search.EndDeadHold()
    local h = S.hold
    if not h then return end
    S.hold_pending = nil
    if Pave.JobActive() then Pave.Stop() end
    if laser_on() then laser_toggle(); AGLog.Info('pave: laser off, the held target was destroyed') end
    if S.last_hold and S.last_hold.id == h.id then S.last_hold.lost = true S.last_hold.reacq = nil end
    AGLog.Info('pave: hold on %s ended, the target was destroyed', tostring(h.name))
    S.hold = nil
end

-- The vehicle's own heading in degrees true from the unit feed (nil when the feed has none).
function Search.UnitHeading(id)
    local u = S.units and S.units[id]
    return u and u.hdg or nil
end

-- True while Jester or the player is holding something (a vehicle or a ground spot), including a watch.
function Search.HoldActive()
    return S.hold ~= nil
end

-- Laser menu (Oct 21 2026): A/G Plus > Laser has three pie slices: Auto Lase Off / Auto Lase On (the label is the action, it follows the
-- state), Laser On, Laser Off. Auto Lase Off means Jester no longer switches the laser on at the range cue, off when the target is masked
-- or off after the pass; the pilot does it all. Laser Off also keeps the automatic cue away for the rest of the hold; Laser On clears that.
function Search.AutoLase()
    return S.auto_lase ~= false
end

local function set_laser(task, want)
    local h = S.hold
    local on = laser_on()
    if on == nil then
        Dbg.Notice('Laser Unable - State Unreadable', 4)
        task:CantDo()
        return
    end
    if Pave.ReleaseHeld() or (Pave.TriggerBusy and Pave.TriggerBusy()) then
        Dbg.Notice('Laser Unable - Weapon Release Held Or Pod Busy', 4)
        task:CantDo()
        return
    end
    if h then
        h.laser_pilot_off = (not want) or nil
        if want then h.lase_tries = 0 end
        h.last_try = Util.Now() + 3
    end
    if on == want then
        Dbg.Notice(want and 'Laser Already On' or 'Laser Already Off', 4)
        task:Roger()
        return
    end
    laser_toggle()
    Dbg.Notice(want and 'Laser On - Pilot' or 'Laser Off - Pilot', 4)
    AGLog.Info('pave: laser switched %s from the menu%s', want and 'on' or 'off', h and (' (hold on ' .. tostring(h.name) .. ')') or '')
    task:Roger()
end

ListenTo('agp_pave_laser', 'AGPlusPaveLaser', function(task, value)
    local ok, err = pcall(function()
        local v = tostring(value)
        -- Laser: Auto (Jester switches it on and off by himself), On or Off (Oct 22 2026). On and Off end Auto, as the center text shows one of the three.
        if v == 'auto' then
            S.auto_lase = true
            if S.hold then S.hold.laser_pilot_off = nil end
            Dbg.Notice('Laser Auto', 4)
            AGLog.Info('pave: laser auto')
            task:Roger()
        elseif v == 'on' then
            S.auto_lase = false
            set_laser(task, true)
        elseif v == 'off' then
            S.auto_lase = false
            set_laser(task, false)
        else
            task:CantDo()
        end
    end)
    if not ok then
        AGLog.Info('pave: laser menu failed: %s', tostring(err))
        task:CantDo()
    end
    Search.RedrawInfo()
end)

-- Sends the Pave Spike center text again straight away (after a menu action), without rebuilding the menu.
function Search.RedrawInfo()
    pcall(function() Menu.ClearInfoCache(); Menu.SetInfo({ TOP_NAME }, info_text()) end)
end

function Search.BuildLaserItem()
    local function item(name, value)
        return Wheel.Item:new({ name = name, action = 'agp_pave_laser', action_value = value, reaction = Wheel.Reaction.NOTHING })
    end
    return Wheel.Item:new({
        name = 'Laser',
        outer_menu = Wheel.Menu:new({
            name = 'Laser',
            items = {
                item('Auto', 'auto'),
                item('On', 'on'),
                item('Off', 'off'),
            },
        }),
    })
end

-- The Laser item sits inside the Pave Spike menu now (Search.BuildItem).

-- A hold that was lost (the vehicle was not seen any more, or the pod left track) stays the target of a short press until a hold is
-- established again, or the player double presses or long presses (Oct 19 2026). A double press that releases a hold does not
-- start one: the last hold stays reacquirable from the menu only.
function Search.ReacquirePending()
    local lh = S.last_hold
    if not (lh ~= nil and lh.reacq == true and not S.hold and not Search.Active() and not S.hold_pending) then return false end
    return true
end

function Search.ClearReacquire()
    if S.last_hold then S.last_hold.reacq = nil end
end

function Search.Reacquire(task)
    local lh = S.last_hold
    Dbg.Say('Reacquire - ' .. tostring(lh.name))
    AGLog.Info('pave: short press: reacquiring the lost target %s', tostring(lh.name))
    if not go_to_entry(task, lh.entry, 'reacquire ' .. tostring(lh.name)) then return false end
    return true
end

-- A short press while the pod sits in MEMORY with a reacquire pending (Oct 20 2026). Jester reacquires by himself once the target is back
-- inside the pod's limits, so the press no longer asks for that: it picks the next target in the list as the one to reacquire, and Jester
-- goes to it when he can (the same 3 s inside the limits). Returns false when there is no other target.
function Search.SwitchPending(task, dir)
    dir = dir or 1
    local lh = S.last_hold
    local flat = flat_list()
    if not lh or #flat == 0 then task:CantDo() return false end
    local fi = flat_index(lh.id)
    local idx
    if fi then idx = ((fi - 1 + dir) % #flat) + 1 else idx = (dir < 0) and #flat or 1 end
    local e = flat[idx]
    if #flat == 1 and e.id == lh.id then
        Dbg.Say('No Other Target To Switch To')
        task:CantDo()
        return false
    end
    S.step_ref, S.step_idx = S.list, idx
    S.last_hold = { id = e.id, name = e.alias or Search.Pretty(e.name), entry = e, lost = true, reacq = true }
    S.auto, S.auto_hist = nil, {}
    Dbg.Say(string.format('Switch Target - %s (%d of %d), reacquiring when it is in view', S.last_hold.name, idx, #flat))
    AGLog.Info('pave: short press in memory: switching the pending reacquire to %s (%d of %d); Jester goes to it when it is inside the pod limits', tostring(S.last_hold.name), idx, #flat)
    task:Roger()
    return true
end

function Search.Holding()
    return S.hold ~= nil and Pave.JobActive()
end

-- Short press again while holding: Jester lets go of the stick and only records (the player flies the pod); once more and he
-- takes it back.
function Search.HoldStart(task, with_list)
    -- First press: hold the vehicle nearest the crosshair. A press while Jester is holding hands the pod back to the player
    -- ("watching"). A press after that designates afresh, from wherever the crosshair is now (it used to go back to the
    -- vehicle held before, so slewing onto another vehicle and pressing took the pod back).
    -- With a target list (with_list) the press instead holds a vehicle under the crosshair that is not the one already held,
    -- and otherwise goes to the next target in the list.
    -- Oct 19 2026: with a target list, a press while something is held (a vehicle, or a ground spot) goes on down the list: the
    -- first target after a ground spot, the next one after a vehicle. Nothing held: the pod's own view is designated (below).
    local prev = S.hold and S.hold.id or nil
    if with_list and S.hold then
        local spot = S.hold.spot
        if spot then S.step_ref, S.step_idx = S.list, 0 end
        if Search.StepTarget(task, (not spot) and S.hold.id or nil) then return end
    end
    -- Oct 20 2026: the hand-over to the player by a short press ("Player Has The Pod") is gone; a double press releases the hold.
    Pave.Stop()
    S.hold = nil
    local L = Pave.ReadLook()
    local dir = pod_dir()
    if not L or not dir then
        AGLog.Info('pave: hold refused: %s', not L and 'no look file' or 'pod direction unreadable')
        task:CantDo()
        return
    end
    S.hold_pending = { t = Util.Now(), self = L.self, dir = dir, with_list = with_list, prev = prev }
    S.keepalive_until = Util.Now() + FEED_WAIT_S + 2
    write_request()
    AGLog.Info('pave: hold requested')
end

-- A vehicle the player put the crosshair on that the search did not list joins the list. With no list yet (no search, or a
-- search that found nothing) it starts one, so the menu has it and Next / Previous / Reacquire work from the first pick.
local function list_add(u)
    local flat = flat_list()
    for _, x in ipairs(flat) do
        if x.id == u.id then return false end
    end
    flat[#flat + 1] = { id = u.id, name = u.name, cat = u.cat, x = u.x, y = u.y, z = u.z, d_aim = S.aim and dist2(u, S.aim) or 0 }
    S.list = Search.Group(flat)
    S.status = counts_text()
    refresh_menu()
    Dbg.Say('Added To Target List - ' .. Search.Pretty(u.name))
    AGLog.Info('pave: %s was not in the target list, added (%d targets now)', Search.Pretty(u.name), #flat)
    return true
end

-- Everything else the pod can see when the pilot designates: each enemy vehicle inside the pod's picture, near enough for its
-- size at the current zoom (the same reach test the search sweep uses: see range by category, scaled by the zoom and
-- Config.PAVE_VISIBILITY) and not hidden by terrain, joins the target list as if Jester had seen it too.
local function view_add(R, sp, dir, held_id)
    if Config.PAVE_VIEW_ADD == false then return end
    local fov, zoom = pod_fov()
    local half = fov * 0.5 * FOV_FILL
    local los = read_los(R.t or S.units_t or -1)
    local flat = flat_list()
    local have = {}
    for _, x in ipairs(flat) do have[x.id] = true end
    local added, seen_n = {}, 0
    local dl = math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
    for _, u in ipairs(R.units) do
        if u.coal ~= R.coal and u.id ~= held_id and not have[u.id] and not (los and los[u.id] == false) then
            local ux, uy, uz = u.x - sp.x, u.y - sp.y, u.z - sp.z
            local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
            local ang = math.acos(math.max(-1, math.min(1, (dir.x * ux + dir.y * uy + dir.z * uz) / math.max(dl * ul, 1))))
            local reach = (SEE[u.cat] or 15000) * VISIBILITY * zoom / ZOOM_NARROW
            if ang <= half and ul <= reach then
                seen_n = seen_n + 1
                added[#added + 1] = { id = u.id, name = u.name, cat = u.cat, x = u.x, y = u.y, z = u.z, d_aim = 0 }
            end
        end
    end
    AGLog.Info('pave: pod view at the designation: picture %.2f deg wide (zoom %.2f), reach scale %.2f, %d more vehicles in view', math.deg(fov), zoom, VISIBILITY * zoom / ZOOM_NARROW, #added)
    if #added == 0 then return end
    for _, e in ipairs(added) do flat[#flat + 1] = e end
    S.list = Search.Group(flat)
    S.status = counts_text()
    refresh_menu()
    Dbg.Say(string.format('Added %d More Targets Seen In The Pod View', #added))
    for _, e in ipairs(added) do AGLog.Info('pave: in the pod view, added to the target list: %s', Search.Pretty(e.name)) end
end

-- A ground spot as a target: the point where the pod's line of sight meets the terrain, held like a vehicle (the pod keeps
-- aiming at the fixed point, the laser comes on at range, and the Tgt Alt dial follows its terrain height). It is not in the
-- target list; the next press goes to the first target in the list.
local function hold_ground_spot(P)
    local sp, dir = P.self, P.dir
    Search.Ray(sp, dir, function(hit)
        if not hit then
            AGLog.Info('pave: ground spot refused: the pod line of sight meets no terrain')
            Dbg.Notice('Ground Spot Refused - Pod Not Looking At The Ground', 4)
            say_cant_do()
            return
        end
        if S.hold then return end   -- something else was held while the answer was on its way
        local spot = { x = hit.x, y = hit.y, z = hit.z }
        local function get() return spot end
        local ok = Pave.StartSlew(NULL_TASK, get, 'hold ground spot', nil, { continuous = true, quiet = true, timeout = 3600, hold = true })
        if not ok then say_cant_do() return end
        local rng = dist3(sp, spot)
        S.hold = { id = -1, spot = true, name = 'Ground Spot', get = get, last_log = Util.Now(), lase_tries = 0, last_try = -100, lased = false }
        S.last_hold = { id = -1, name = 'Ground Spot', lost = false,
            entry = { id = -1, name = 'Ground Spot', alias = 'Ground Spot', cat = 'struct', x = spot.x, y = spot.y, z = spot.z, d_aim = 0, spot = true } }
        AGLog.Info('pave: HOLD ground spot at %.1f NM, terrain height %.0f ft', rng / 1852, spot.y / 0.3048)
        Dbg.Notice('Holding Ground Spot', 4)
        S.hold.said = true
        pcall(function()
            local Task = require('base.Task')
            GetJester():AddTask(Task:new():Say('Lantirn/captured'))
        end)
        pcall(refresh_menu)
    end)
end

local function hold_designate(R)
    local P = S.hold_pending
    S.hold_pending = nil
    local sp, dir = P.self, P.dir
    local best = {}
    for _, u in ipairs(R.units) do
        if u.coal ~= R.coal then
            local a = angle_between(dir, { x = u.x - sp.x, y = u.y - sp.y, z = u.z - sp.z })
            best[#best + 1] = { u = u, a = a }
        end
    end
    table.sort(best, function(a, b) return a.a < b.a end)
    for i = 1, math.min(4, #best) do
        local b = best[i]
        local baz, bel, waz, wel = offset_to(sp, dir, b.u)
        AGLog.Info('pave: hold candidate %d: %s %.2f deg from the crosshair (aircraft frame az %+.2f el %+.2f, world az %+.2f el %+.2f), %.1f NM',
            i, Search.Pretty(b.u.name), b.a, baz, bel, waz, wel, dist3(sp, b.u) / 1852)
    end
    local match = HOLD_MATCH_DEG
    local pick = best[1]
    if not pick or pick.a > match then
        -- No unit within the match angle of the crosshair: the ground spot the pod looks at becomes the target.
        AGLog.Info('pave: hold: no unit within %.1f deg of the crosshair, designating the ground spot', match)
        hold_ground_spot(P)
        return
    end
    local u = pick.u
    local off_az, off_el = offset_to(sp, dir, u)
    local id, last = u.id, { x = u.x, y = u.y, z = u.z }
    local function get()
        local q = S.units[id]
        if q then last = { x = q.x, y = q.y, z = q.z } end
        if S.lead and S.lead.id == id then return S.lead.point end   -- lead mode: the pod aims at the point ahead of the vehicle
        return predict(id, last)
    end
    local rng = dist3(sp, u)
    local graze = math.deg(math.asin(math.min(1, (sp.y - u.y) / rng)))
    local gd = pod_ground_dist(sp, u)
    AGLog.Info('pave: HOLD %s at %.1f NM, look angle %.1f deg below horizontal, offset az %+.2f el %+.2f deg (aircraft frame), pod ground point %s from it',
        Search.Pretty(u.name), rng / 1852, graze, off_az, off_el, gd and string.format('%.0f ft', gd * 3.28084) or 'n/a')
    local ok = Pave.StartSlew(NULL_TASK, get, 'hold ' .. Search.Pretty(u.name), nil,
        { continuous = true, quiet = true, timeout = 3600, off_az = off_az, off_el = off_el, hold = true })
    if not ok then say_cant_do() return end
    Dbg.Notice('Holding Track - ' .. Search.Pretty(u.name), 4)
    S.hold = { id = id, name = Search.Pretty(u.name), get = get, last_log = Util.Now(), lase_tries = 0, last_try = -100, lased = false }
    S.last_hold = { id = id, name = S.hold.name, lost = false,
        entry = { id = id, name = u.name, cat = u.cat, x = u.x, y = u.y, z = u.z, d_aim = S.aim and dist2(u, S.aim) or 0 } }
    pcall(list_add, u)
    pcall(view_add, R, sp, dir, id)
    do
        -- A vehicle in the list: the next press carries on from it.
        local fi = flat_index(id)
        if fi then S.step_ref, S.step_idx = S.list, fi end
    end
    if S.hold then S.hold.said = true end
    pcall(function()
        local Task = require('base.Task')
        GetJester():AddTask(Task:new():Say('Lantirn/captured'))
    end)
end

local PSP = '/EO TGT Designator System/Pave Spike'

local function op_mode_rec()
    local m
    pcall(function() m = num(GetProperty(PSP, 'Operation Mode').value) end)
    return m
end

-- Lead point (Oct 20 2026). A moving held vehicle: the long press that sets the drag coefficient also moves the aim point to where the
-- vehicle will be when the bomb captures the laser, and the pod stays there (the pod cannot move while weapon release is held). When
-- release is let go the pod goes back to the vehicle and the laser paints it for the terminal guidance. If release is not pressed
-- within PAVE_LEAD_TIMEOUT_S (20) of the press, the pod goes back too.
--   lead time = time from the press to the release (worked out below, 15 s when unknown) + PAVE_LEAD_CAPTURE_FRAC (0.5) * time of fall
-- The time of fall comes from the height above the vehicle at the expected release and the aircraft's vertical speed now. The
-- drag coefficient uses the altitude expected at the release (altitude now + vertical speed * the time to release).
-- Off with Config.PAVE_LEAD = false; vehicles slower than PAVE_LEAD_MIN_KT (3) get no lead.
local lead_tick
lead_tick = function(now)
    local h = S.hold
    if not h then S.lead = nil return end
    if S.lead and S.lead.hold ~= h then S.lead = nil end
    if not h.spot then
        -- The vehicle's recent positions (about 8 s), and the aircraft's height (5 s), for the speed and the vertical speed.
        local u = S.units and S.units[h.id]
        if u and S.units_t and S.units_t ~= h.tr_t then
            h.tr_t = S.units_t
            h.track = h.track or {}
            h.track[#h.track + 1] = { t = S.units_t, x = u.x, z = u.z }
            while #h.track > 1 and S.units_t - h.track[1].t > 8 do table.remove(h.track, 1) end
            -- Velocity over the last 4 s of samples (at least 1.5 s apart), smoothed from sample to sample.
            local tr, n = h.track, #h.track
            local i0 = n
            while i0 > 1 and tr[n].t - tr[i0 - 1].t <= 4 do i0 = i0 - 1 end
            local span = tr[n].t - tr[i0].t
            if span >= 1.5 then
                local vx, vz = (tr[n].x - tr[i0].x) / span, (tr[n].z - tr[i0].z) / span
                if vx * vx + vz * vz < 0.25 then
                    h.vel = nil   -- under 0.5 m/s: standing
                elseif h.vel then
                    h.vel = { x = h.vel.x + 0.5 * (vx - h.vel.x), z = h.vel.z + 0.5 * (vz - h.vel.z) }
                else
                    h.vel = { x = vx, z = vz }
                end
            end
        end
        if now - (h.sy_t or -10) >= 0.5 then
            local L = Pave.ReadLook()
            if L and L.self and L.self.y then
                h.sy_t = now
                h.selfy = h.selfy or {}
                local uu = S.units and S.units[h.id]
                local dd = uu and L.self.x and math.sqrt((L.self.x - uu.x) ^ 2 + (L.self.z - uu.z) ^ 2) or nil   -- flat distance to the vehicle
                h.selfy[#h.selfy + 1] = { t = now, y = L.self.y, d = dd }
                while #h.selfy > 1 and now - h.selfy[1].t > 5 do table.remove(h.selfy, 1) end
            end
        end
    end
    local ld = S.lead
    if not ld then return end
    if Pave.ReleaseHeld() then ld.held, ld.held_t = true, now end
    if ld.held and now - ld.held_t > 0.5 then
        AGLog.Info('pave: lead point ended: weapon release let go, the pod goes back to %s', tostring(h.name))
        S.lead = nil
    elseif not ld.held and now > ld.expire then
        AGLog.Info('pave: lead point ended: no weapon release within %.0f s, the pod goes back to %s', ld.expire - ld.t0, tostring(h.name))
        S.lead = nil
    end
end

-- The numbers for a lead point from the held vehicle's movement and the aircraft's vertical speed, or nil (no lead wanted or possible).
-- Used by the long press before it sets the drag coefficient, so the coefficient can use the altitude expected at the release.
function Search.LeadPlan()
    if Config.PAVE_LEAD == false then return nil end
    local h = S.hold
    if not h or h.spot or not h.id or h.id < 0 then return nil end
    local tr = h.track
    if not tr or #tr < 2 then return nil end
    local a, b = tr[1], tr[#tr]
    local dt = b.t - a.t
    if dt < 3 then return nil end
    local vx, vz = (b.x - a.x) / dt, (b.z - a.z) / dt
    local spd = math.sqrt(vx * vx + vz * vz)
    if spd < (Config.PAVE_LEAD_MIN_KT or 3) / 1.94384 then return nil end
    local L = Pave.ReadLook()
    local u = S.units and S.units[h.id]
    if not (L and L.self and L.self.y and u) then return nil end
    local vs = 0   -- aircraft vertical speed, m/s, up positive
    local sy = h.selfy
    if sy and #sy >= 2 and sy[#sy].t - sy[1].t >= 2 then vs = (sy[#sy].y - sy[1].y) / (sy[#sy].t - sy[1].t) end
    local frac = Config.PAVE_LEAD_CAPTURE_FRAC or 0.5
    -- Time to the release, worked out: the bomb leaves when
    -- the flat distance to the vehicle has closed to the bomb's own flat travel, so
    --     t_release = (flat distance now - travel) / closing speed,   travel = k * closing speed * fall time (k about 0.75 to 0.9, see rg_factor below)
    -- and the fall time depends on the height at the release (height now + vertical speed * t_release): a few passes settle it.
    -- Measured Oct 20 2026 (GBU-10, dive 11 to 8 deg, 480 kt, 31,800 ft slant): released 25 to 26 s after the press, flat travel
    -- about 0.76 of closing speed * fall time. With less than 2 s of distance history, or closing under 100 kt, 15 s is used.
    local dh, cl = nil, nil
    if sy and #sy >= 2 and sy[#sy].d and sy[1].d and sy[#sy].t - sy[1].t >= 2 then
        dh = sy[#sy].d
        cl = (sy[1].d - sy[#sy].d) / (sy[#sy].t - sy[1].t)
    end
    -- The bomb's flat travel as a share of (speed * fall time). From Wrcs.lua's calibrated level-flight release ranges (GBU-10, -12 and
    -- -24): 0.92 at 3,000 ft and 400 kt down to 0.84 at 30,000 ft and 500 kt, so k_level = 0.91 - 1.5e-6 * (height - 3000) - 0.0002 * (kt - 400).
    -- Diving it is smaller: the one measured release (Oct 20 2026, dive 8 to 11 deg) came out at 0.84 of the level value, so the
    -- level value is scaled down by up to 16 percent over the first 8 deg of dive (a guess for steeper dives).
    local function rg_factor(h_ft, kt, dive_deg)
        local k = 0.91 - 1.5e-6 * (h_ft - 3000) - 0.0002 * (kt - 400)
        k = math.max(0.8, math.min(0.93, k))
        return k * (1 - 0.16 * math.max(0, math.min(1, dive_deg / 8)))
    end
    local vd = -vs * 3.28084                                   -- ft/s downwards
    local agl0_ft = (L.self.y - u.y) * 3.28084
    local function fall_from(t)
        local h_ft = math.max(100, agl0_ft + vs * 3.28084 * t)
        return ((-vd + math.sqrt(vd * vd + 4 * 16.087 * h_ft)) / (2 * 16.087)) * 1.05, h_ft   -- a little longer than a vacuum fall
    end
    local rel, how
    if dh and cl and cl > 51.4 then   -- 100 kt
        rel = 15
        for _ = 1, 5 do
            local fl, hf = fall_from(rel)
            local dive = math.deg(math.atan2(math.max(vd, 0), cl * 3.28084))
            rel = math.max(3, math.min(90, (dh - rg_factor(hf, cl * 1.94384, dive) * cl * fl) / cl))
        end
        how = 'worked out'
    else
        rel, how = 15, 'default'
    end
    local tof, agl_ft = fall_from(rel)
    local delta_ft = math.max(-20000, math.min(20000, vs * rel * 3.28084))
    return { hold = h, id = h.id, vx = vx, vz = vz, spd = spd, rel = rel, rel_how = how, flat_ft = dh and dh * 3.28084, closing_kt = cl and cl * 1.94384, tof = tof, lead_s = rel + frac * tof, alt_delta_ft = delta_ft, agl_ft = agl_ft, vs = vs }
end

-- Sets the lead point from a plan (after the drag coefficient was set).
function Search.LeadStart(plan)
    local h = S.hold
    if not plan or not h or h ~= plan.hold then return end
    local u = S.units and S.units[h.id]
    if not u then return end
    local now = Util.Now()
    S.lead = { hold = h, id = h.id, t0 = now, expire = now + (Config.PAVE_LEAD_TIMEOUT_S or 20),
               point = { x = u.x + plan.vx * plan.lead_s, y = u.y, z = u.z + plan.vz * plan.lead_s } }
    AGLog.Info('pave: lead point set on %s: %.0f kt, track %03.0f, %.0f s ahead (%.0f s to release (%s; %.0f ft flat distance, closing %.0f kt) + %.1f x %.0f s fall from %.0f ft above it, aircraft %+.0f ft/min), %.0f ft from the vehicle; ends at release or after %.0f s',
        tostring(h.name), plan.spd * 1.94384, (math.deg(math.atan2(plan.vz, plan.vx)) + 360) % 360, plan.lead_s, plan.rel, plan.rel_how, plan.flat_ft or 0, plan.closing_kt or 0, Config.PAVE_LEAD_CAPTURE_FRAC or 0.5, plan.tof, plan.agl_ft, plan.vs * 196.85,
        plan.spd * plan.lead_s * 3.28084, Config.PAVE_LEAD_TIMEOUT_S or 20)
    return true
end

-- Release watch (Oct 22 2026), for the Strike List advance: a hold counts as "released on" when the number of weapons on the aircraft dropped
-- while it was held (the payload feed, read once a second), or, with no payload feed, when the weapon release button was pressed during it.
local function release_watch(h, now)
    if now - (h.stores_t or -10) >= 1 then
        h.stores_t = now
        pcall(function()
            local St = require('agplus.Stores')
            St.ReadFeed()
            h.stores_avail = St.available
            local n = St.WeaponCount()
            if n then
                if h.stores0 == nil then h.stores0 = n end
                if n < h.stores0 and not h.released then
                    h.released = true
                    AGLog.Info('pave: hold %s: ordnance released during the attack run (%d weapons before, %d now)', tostring(h.name), h.stores0, n)
                end
            end
        end)
    end
    if not h.pickled and Pave.ReleaseHeld() then h.pickled = true end
end

local function hold_tick(now)
    if S.hold_pending then
        local R = refresh_units_cache()
        if R and R.t >= S.hold_pending.t - 0.05 then
            local ok, err = pcall(hold_designate, R)
            if not ok then
                S.hold_pending = nil
                AGLog.Info('pave: hold failed: %s', tostring(err))
                say_cant_do()
            end
        elseif now - S.hold_pending.t > FEED_WAIT_S then
            S.hold_pending = nil
            AGLog.Info('pave: hold: no unit feed')
            say_cant_do()
        end
        return
    end
    if not S.hold then return end
    if not Pave.JobActive() then
        AGLog.Info('pave: hold on %s ended', S.hold.name)
        if laser_on() then laser_toggle(); AGLog.Info('pave: laser off with the hold') end
        local will_reacq = false
        if S.last_hold and S.last_hold.id == S.hold.id then
            S.last_hold.lost = true S.last_hold.reacq = true
            will_reacq = Config.PAVE_AUTO_REACQUIRE ~= false
        end
        if will_reacq then
            Dbg.Notice('Pod Lost Track - Will Reacquire ' .. tostring(S.hold.name), 5)
        else
            Dbg.Notice('Hold Ended - Pod Left Track', 4)
        end
        S.hold = nil
        return
    end
    S.keepalive_until = now + 3
    release_watch(S.hold, now)
    -- "Captured" when a hold that came from the menu, the list or a reacquire is on its target (a designation said it at once).
    -- Config.PAVE_CAPTURED_CALL = false switches it off.
    if not S.hold.said and Pave.HoldOnTarget and Pave.HoldOnTarget() then
        S.hold.said = true
        if Config.PAVE_CAPTURED_CALL ~= false then
            AGLog.Info('pave: hold on %s is on target, captured', tostring(S.hold.name))
            pcall(function()
                local Task = require('base.Task')
                GetJester():AddTask(Task:new():Say('Lantirn/captured'))
            end)
        end
    end
    pcall(lead_tick, now)
    -- Terrain masking of the held vehicle, from the line-of-sight list that comes with each unit feed (about once a second).
    if S.units_t and S.units_t ~= S.hold.los_t then
        local los = read_los(S.units_t)
        if los then
            S.hold.los_t = S.units_t
            local v = los[S.hold.id]
            if v ~= nil then Pave.SetMasked(v == false) end
        end
    end
    do
        -- Range with the laser once close enough, so the pod stabilizes on the real ground point.
        local L0 = Pave.ReadLook()
        local u0 = S.hold.get()
        if L0 and u0 then
            local rng0 = dist3(L0.self, u0)
            local on = laser_on()
            local h = S.hold
            -- Closing speed (m/s) from how the slant range changes, smoothed; the laser press is started early by LASE_LEAD_S of
            -- it so the laser is already on when the range reaches the limit (the pod only ranges inside it).
            if h.rng_t and now - h.rng_t > 0.2 then
                local v = (h.rng_prev - rng0) / (now - h.rng_t)
                h.closure = h.closure and (h.closure + 0.3 * (v - h.closure)) or v
                h.rng_prev, h.rng_t = rng0, now
            elseif not h.rng_t then
                h.rng_prev, h.rng_t = rng0, now
            end
            local lase_at = LASE_RANGE_M + math.max(h.closure or 0, 0) * LASE_LEAD_S
            -- Passed the target: the aircraft came inside the laser-off range and the slant range is growing again (a turn away
            -- from a target still far off is not a pass).
            if not h.min_rng or rng0 < h.min_rng then h.min_rng = rng0 end
            if not h.passed and h.min_rng < LASE_STOP_M and rng0 > h.min_rng + PASS_MARGIN_M then
                h.passed = true
                AGLog.Info('pave: hold %s: passed (closest slant range %.0f ft, now %.0f ft), laser goes off at %.0f ft', h.name, h.min_rng / 0.3048, rng0 / 0.3048, LASE_STOP_M / 0.3048)
            end
            -- Close in the pod goes wide so the vehicle stays in the picture as the angles change fast: inside 9,000 ft wide, back
            -- to the earlier zoom only once the slant range has stayed beyond 13,000 ft for 4 s (the 4,000 ft gap and the time
            -- keep it from flipping in and out), and never within 8 s of the last change. Off with Config.PAVE_CLOSE_WIDE = false.
            if Config.PAVE_CLOSE_WIDE ~= false and Pave.ZoomSettled and Pave.ZoomSettled() then
                local near_m = (Config.PAVE_CLOSE_WIDE_FT or 9000) * 0.3048   -- wide inside 9,000 ft, narrow again beyond 13,000 ft (was 10,000 / 14,000 until Oct 21 2026)
                local far_m = near_m + (Config.PAVE_CLOSE_WIDE_MARGIN_FT or 4000) * 0.3048
                local wide = Pave.PodIsWide()
                if wide ~= nil then
                    if rng0 < near_m then
                        h.cw_far_since = nil
                        if not wide and now - (h.cw_change or -100) > 8 then
                            h.cw_active = true
                            h.cw_change = now
                            Pave.SetZoom(true, string.format('inside %.0f ft, %.0f ft slant range', near_m / 0.3048, rng0 / 0.3048))
                        end
                    elseif rng0 > far_m and h.cw_active then
                        h.cw_far_since = h.cw_far_since or now
                        if now - h.cw_far_since >= 4 and now - (h.cw_change or -100) > 8 then
                            if wide then
                                h.cw_change = now
                                Pave.SetZoom(false, string.format('beyond %.0f ft again, %.0f ft slant range', far_m / 0.3048, rng0 / 0.3048))
                            end
                            h.cw_active, h.cw_far_since = false, nil
                        end
                    else
                        h.cw_far_since = nil
                    end
                end
            end
            -- Turned back in: after a pass the slant range is shrinking fast again (closing faster than PAVE_REATTACK_CLOSURE_KT, 300 (was 150 until Oct 21 2026)
            -- by default, for PAVE_REATTACK_HOLD_S, 2 s by default) and the vehicle is inside the laser range: the pass is forgotten,
            -- so the laser cue below switches the laser on again and a later pass switches it off again.
            if h.passed then
                local thr = (Config.PAVE_REATTACK_CLOSURE_KT or 300) / 1.94384
                if (h.closure or 0) > thr and rng0 <= LASE_RANGE_M then
                    h.reatk_since = h.reatk_since or now
                    if now - h.reatk_since >= (Config.PAVE_REATTACK_HOLD_S or 2) then
                        AGLog.Info('pave: hold %s: turned back in (closing %.0f kt at %.0f ft), laser armed again', tostring(h.name), (h.closure or 0) * 1.94384, rng0 / 0.3048)
                        h.passed, h.reatk_since = false, nil
                        h.min_rng = rng0
                        h.lase_tries, h.stop_tries, h.stop_try = 0, 0, nil
                        h.last_try = now - 10
                        Dbg.Notice('Target Re-engaged - Laser Ready', 4)
                    end
                else
                    h.reatk_since = nil
                end
            end
            -- A retry waits until the first press has had time to take effect (the trigger sequence takes a few seconds and the
            -- property flickers meanwhile): the reading must have stayed false for 2 s and 6 s must have passed. Oct 15 2026:
            -- a retry 2.8 s after a press that had worked toggled the laser straight back off, and the pod left track after it.
            if on == true then S.hold.off_since = nil else S.hold.off_since = S.hold.off_since or now end
            local retry_ok = (S.hold.lase_tries or 0) < 1 or ((now - S.hold.last_try > 6) and S.hold.off_since and now - S.hold.off_since >= 2)
            local rel_held = Pave.ReleaseHeld() or Pave.IsMasked()   -- no laser toggles while the player holds weapon release, or while the target is masked
            local trig_busy = Pave.TriggerBusy and Pave.TriggerBusy()   -- the laser shares the trigger with the track-entry sequence: wait for it
            -- Terrain masks the held vehicle (the line-of-sight feed says so): the laser would only hit the ground in the way, so
            -- Jester switches it off, once the masking has lasted 1.5 s so a flicker in the feed does nothing. When the vehicle is
            -- visible again the normal laser cue below puts it back on (the try count starts afresh). Off with
            -- Config.PAVE_LASER_OFF_MASKED = false.
            if Config.PAVE_LASER_OFF_MASKED ~= false and Search.AutoLase() then
                if Pave.IsMasked() then
                    h.mask_since = h.mask_since or now
                    if on == true and not h.passed and not Pave.ReleaseHeld() and not trig_busy and now - h.mask_since >= 1.5
                        and (h.mask_tries or 0) < 3 and now - (h.mask_try or -100) > ((h.mask_tries or 0) < 1 and 3 or 6) then
                        h.mask_try = now
                        h.mask_tries = (h.mask_tries or 0) + 1
                        h.mask_laser_off = true
                        h.last_try = now + 3   -- the laser cue below waits at least 6 s after this press
                        laser_toggle()
                        Dbg.Notice('Laser Off - Target Masked By Terrain', 4)
                        AGLog.Info('pave: hold: laser off, the target is masked by terrain (%.0f ft slant range, try %d, Fire Laser read %s)', rng0 / 0.3048, h.mask_tries, laser_raw())
                    end
                else
                    if h.mask_since or h.mask_laser_off then
                        if h.mask_laser_off then
                            h.lase_tries = 0   -- the normal cue may switch the laser on again
                            AGLog.Info('pave: hold: target visible again, the laser may come back on at the usual range')
                        end
                        h.mask_since, h.mask_tries, h.mask_try, h.mask_laser_off = nil, nil, nil, nil
                    end
                end
            end
            if h.passed then
                -- Both the on and the off are the full action trigger sequence (released, half, full, half, released).
                if Search.AutoLase() and not rel_held and not trig_busy and on == true and rng0 >= LASE_STOP_M and (h.stop_tries or 0) < 3 and now - (h.stop_try or -100) > ((h.stop_tries or 0) < 1 and 3 or 6) then
                    h.stop_try = now
                    h.stop_tries = (h.stop_tries or 0) + 1
                    laser_toggle()
                    Dbg.Notice('Laser Off - Target Passed', 4)
                    AGLog.Info('pave: hold: laser off at %.0f ft slant range after the pass (try %d, Fire Laser read %s)', rng0 / 0.3048, h.stop_tries, laser_raw())
                end
                -- Strike List (Oct 21 2026): once the target has passed and the laser has been off for a few seconds, with no weapon release
                -- held, the pod goes on to the next target in the Strike List. Targets.OnPassed does nothing when the held vehicle is not in
                -- the list, it is the last one, or Auto Advance is off.
                if on == true or rel_held or trig_busy then
                    h.adv_since = nil
                elseif not h.advanced and Config.STRIKE_ADVANCE_NEEDS_RELEASE ~= false
                    and not (h.released or ((not h.stores_avail) and h.pickled)) then
                    -- Passed without releasing anything: the pod stays on this target (a later release or a turn back in carries on).
                    h.adv_since = nil
                    if not h.norel_logged then
                        h.norel_logged = true
                        AGLog.Info('pave: hold %s: passed with no weapon released, not advancing the Strike List', tostring(h.name))
                    end
                elseif not h.advanced then
                    h.adv_since = h.adv_since or now
                    if now - h.adv_since >= (Config.STRIKE_ADVANCE_DELAY_S or 3) then
                        local T = package.loaded['agplus.Targets']
                        if T and T.OnPassed then
                            local okT, errT = pcall(T.OnPassed, h)
                            if not okT then
                                h.advanced = true
                                AGLog.Info('pave: strike list advance failed: %s', tostring(errT))
                            end
                        else
                            h.advanced = true
                        end
                    end
                end
            elseif not rel_held and not trig_busy and on ~= true and rng0 <= lase_at and S.hold.lase_tries < 3 and now - S.hold.last_try > 3 and retry_ok
                and (not h.from_strike or (h.closure or 0) > (Config.STRIKE_LASER_CLOSURE_KT or 300) / 1.94384)
                and not h.laser_pilot_off and Search.AutoLase() then   -- a hold the Strike List started waits until the aircraft closes on it at 300 kt or more (no laser while holding or facing away); a laser the pilot switched off stays off
                S.hold.last_try = now
                S.hold.lase_tries = S.hold.lase_tries + 1
                laser_toggle()
                Dbg.Notice('Laser On', 4)
                AGLog.Info('pave: hold: laser toggle at %.0f ft slant range, closing %.0f kt, started %.0f ft early so it is on at %.0f ft (try %d, Fire Laser read %s)', rng0 / 0.3048, (h.closure or 0) * 1.94384, (lase_at - LASE_RANGE_M) / 0.3048, LASE_RANGE_M / 0.3048, S.hold.lase_tries, laser_raw())
            end
        end
    end
    do
        local L0 = Pave.ReadLook()
        local u0 = S.hold.get and S.hold.get()
        if L0 and u0 then
            local rng_nm = dist3(L0.self, u0) / 1852
            local las = laser_on()
            Dbg.Status(string.format('Holding Track %s - %.1f NM - Laser %s%s%s', tostring(S.hold.name), rng_nm,
                las == true and 'ON' or 'OFF', Pave.IsMasked() and ' - MASKED' or '', S.hold.passed and ' - PASSED' or ''))
        end
    end
    if now - S.hold.last_log >= HOLD_LOG_S then
        S.hold.last_log = now
        local L = Pave.ReadLook()
        local dir = pod_dir()
        local u = S.hold.get()
        if L and dir and u then
            local sp = L.self
            local baz, bel = offset_to(sp, dir, u)
            local rng = dist3(sp, u)
            local gd = pod_ground_dist(sp, u)
            if now - (S.hold.last_short or 0) >= 10 then
                S.hold.last_short = now
                AGLog.Info('pave: holding %s at %.0f ft, laser %s', S.hold.name, rng / 0.3048, laser_raw())
            end
            AGLog.Detail('pave: holding %s at %.0f ft, laser %s, look angle %.1f deg, pod vs unit az %+.2f el %+.2f deg, pod ground point %s from it',
                S.hold.name, rng / 0.3048, laser_raw(), math.deg(math.asin(math.min(1, (sp.y - u.y) / rng))), baz, bel, gd and string.format('%.0f ft', gd * 3.28084) or 'n/a')
        end
    end
end

-- Target altitude for TGT FIND. While the Delivery Mode switch is in TGT_FIND, the WRCS Target Alt/Range dial is set to the
-- altitude of the target (feet, the same raw feet the dial takes in Wrcs.lua). The target is the held vehicle when there is
-- one (its height from the unit feed), else the ground point the pod is tracking. The dial is turned once when the switch goes
-- to TGT_FIND and again only when the target's altitude has moved by 100 ft or more from the last value Jester set, so a
-- value the pilot dials by hand stays until the target changes. Config PAVE_AUTO_TGT_ALT = false switches it off.
local TALT_STEP_FT = 100
local function tgt_alt_tick(now)
    if Config.PAVE_AUTO_TGT_ALT == false then return end
    if now - (S.talt_check or -10) < 1.0 then return end
    S.talt_check = now
    if tostring(Util.DeliveryMode()) ~= 'TGT_FIND' then S.talt_sent = nil return end
    local alt_ft, src
    if S.hold and S.hold.get then
        local u = S.hold.get()
        if u and u.y then alt_ft, src = u.y / 0.3048, 'held ' .. tostring(S.hold.name) end
    end
    -- No pod ground point fallback: it read 8810 to 15110 ft while the target sat at 3080 ft and moved the dial every second
    -- through the search (Oct 15 2026 run, pod ran away during the sweep return). Only a held unit's own altitude is used.
    if not alt_ft then return end
    if S.talt_sent and math.abs(alt_ft - S.talt_sent) < TALT_STEP_FT then return end
    local val = math.floor(alt_ft / 10 + 0.5) * 10
    S.talt_sent = alt_ft
    Dbg.Say(string.format('Target Alt Dial - %d ft (%s)', val, src))
    AGLog.Info('pave: TGT FIND target altitude %d ft (%s), setting the Target Alt/Range dial', val, src)
    Dispatch('agp_tgt_alt', val)
end

ListenTo('agp_tgt_alt', 'AGPlus_TgtAlt', function(task, val)
    task:ClickFast('Target Alt/Range', tostring(val))
end)

-- Look there has ended (the pod is on the spot the player looked at): the Tgt Alt dial is set once to the terrain height where the
-- pod is looking now, found with a terrain ray along the pod's own line of sight. Only with Delivery Mode in TGT FIND, and not
-- when Config.PAVE_AUTO_TGT_ALT is false. Called from Pave.lua when a look there finishes.
function Search.TgtAltAtPod()
    if Config.PAVE_AUTO_TGT_ALT == false then return end
    if tostring(Util.DeliveryMode()) ~= 'TGT_FIND' then return end
    local L = Pave.ReadLook()
    local dir = pod_dir()
    if not L or not dir then return end
    Search.Ray(L.self, dir, function(hit)
        if not hit then
            AGLog.Info('pave: look there ended, no terrain under the pod line of sight, dial not set')
            return
        end
        local alt_ft = hit.y / 0.3048
        local val = math.floor(alt_ft / 10 + 0.5) * 10
        S.talt_sent = alt_ft
        Dbg.Say(string.format('Target Alt Dial - %d ft (look there)', val))
        AGLog.Info('pave: look there ended, TGT FIND target altitude %d ft (terrain under the pod), setting the Target Alt/Range dial', val)
        Dispatch('agp_tgt_alt', val)
    end)
end

-- Automatic reacquire (Oct 19 2026). After the pod itself lost a held target (it sits in MEMORY, mode 2, pointing at the last spot, which
-- happens when the target leaves the pod's view: a hard turn puts it above the datum line), Jester goes back to it as soon as the target
-- has been inside the pod's limits for PAVE_AUTO_REACQ_S (3) seconds in a row, with no pilot input. The limit is the datum line limit used for
-- slews (PAVE_DATUM_LIMIT_DEG, 2 deg above the aircraft datum line) less PAVE_AUTO_REACQ_MARGIN_DEG (1) so it does not start at the edge.
-- Not when the pilot ended it (double or long press clear the request), when the pod is in acquisition (the pilot left track on purpose),
-- while weapon release is held, or during a search. At most PAVE_AUTO_REACQ_TRIES (3) tries in 90 s, so a target that is hidden by terrain
-- does not loop. Config.PAVE_AUTO_REACQUIRE = false switches it off; the short press still reacquires by hand.
local function auto_reacq_tick(now)
    if Config.PAVE_AUTO_REACQUIRE == false then S.auto = nil return end
    local lh = S.last_hold
    if not (lh and lh.reacq and lh.entry and Search.ReacquirePending()) then S.auto = nil return end
    if Pave.ReleaseHeld() or Pave.JobActive() or op_mode_rec() ~= 2 then S.auto = nil return end
    local a = S.auto
    if not a or a.id ~= lh.id then
        a = { id = lh.id, since = nil, next_ok = 0 }
        S.auto = a
    end
    S.keepalive_until = math.max(S.keepalive_until or 0, now + 3)   -- keeps the unit feed running so a moving target's position is current
    if now < a.next_ok or now - (a.checked or -1) < 0.25 then return end
    a.checked = now
    pcall(refresh_units_cache)
    local L = Pave.ReadLook()
    if not L then return end
    local p = current_pos(lh.entry)
    local az, el = Pave.Direction(L.self, p)
    local be = Pave.BodyElevation(az, el, L.self.heading, L.self.pitch, L.self.bank)
    local limit = (Config.PAVE_DATUM_LIMIT_DEG or 2) - (Config.PAVE_AUTO_REACQ_MARGIN_DEG or 1)
    if be > limit then
        if a.since then AGLog.Info('pave: auto reacquire: %s is %.1f deg above the datum line again, waiting', tostring(lh.name), be) end
        a.since = nil
        return
    end
    if not a.since then
        a.since = now
        AGLog.Info('pave: auto reacquire: %s is inside the pod limits (%.1f deg against the datum line, limit %.1f), %.0f s to confirm', tostring(lh.name), be, limit, Config.PAVE_AUTO_REACQ_S or 3)
    end
    if now - a.since < (Config.PAVE_AUTO_REACQ_S or 3) then return end
    local keep = {}
    for _, t in ipairs(S.auto_hist or {}) do if now - t < 90 then keep[#keep + 1] = t end end
    S.auto_hist = keep   -- survives the pod being busy between tries
    if #keep >= (Config.PAVE_AUTO_REACQ_TRIES or 3) then
        a.next_ok = now + 5
        if not a.gave_up then
            a.gave_up = true
            AGLog.Info('pave: auto reacquire: %d tries in the last 90 s, leaving %s to a short press', #keep, tostring(lh.name))
        end
        return
    end
    keep[#keep + 1] = now
    a.since, a.next_ok, a.gave_up = nil, now + 8, nil
    Dbg.Notice('Auto Reacquire - ' .. tostring(lh.name), 4)
    AGLog.Info('pave: auto reacquire: %s has been inside the pod limits for %.0f s, reacquiring without a press (try %d)', tostring(lh.name), Config.PAVE_AUTO_REACQ_S or 3, #keep)
    local ok = pcall(go_to_entry, NULL_TASK, lh.entry, 'reacquire ' .. tostring(lh.name))
    if not ok then AGLog.Info('pave: auto reacquire failed to start') end
end

function SearchBehavior:Tick()
    local now = Util.Now()
    if now - (S.info_t or -10) >= 0.5 then
        S.info_t = now
        -- Resent every 2 s even when unchanged, in case the wheel dropped the text when the page was opened.
        if now - (S.info_force_t or -10) >= 2 then S.info_force_t = now; pcall(Menu.ClearInfoCache) end
        pcall(function() Menu.SetInfo({ TOP_NAME }, info_text()) end)
    end
    if S.refresh_at and now >= S.refresh_at then
        S.refresh_at = nil
        pcall(refresh_menu)
    end
    -- Auto Fill (Oct 22 2026): when the target list changes (a search, a designation, a spotted unit), the Strike List takes the new units.
    if S.list ~= S.af_ref then
        S.af_ref = S.list
        local T = package.loaded['agplus.Targets']
        if T and T.AutoFill then pcall(T.AutoFill) end
    end
    -- Leaving Tgt Find (Oct 22 2026): the pod is the player's again. A hold, a lost hold waiting to be reacquired, a search and the automatic
    -- reacquire all end half a second after the mode changes, and none of them runs while another mode is selected (Jester kept trying to
    -- reacquire and saying unable). The laser and the pod are left as they are.
    local spike = (not Pave.SpikeActive) or Pave.SpikeActive()
    if spike then
        S.left_t = nil
        pcall(hold_tick, now)
        pcall(auto_reacq_tick, now)
    else
        S.left_t = S.left_t or now
        if now - S.left_t >= 0.5 then
            local lh = S.last_hold
            if S.hold or S.hold_pending or S.auto or Search.Active() or (lh and lh.reacq) then
                AGLog.Info('pave: Tgt Find left, hold %s, reacquire %s, search %s: all ended', tostring(S.hold and S.hold.name or 'none'), tostring(lh and lh.reacq or false), tostring(Search.Active()))
                pcall(Pave.Stop)
                S.hold, S.hold_pending, S.auto = nil, nil, nil
                if lh then lh.reacq = nil end
                if Search.Active() then pcall(Search.Cancel) end
            end
        end
    end
    pcall(ray_tick, now)
    pcall(tgt_alt_tick, now)
    -- Advance after a kill (Nov 11 2026): the held target was destroyed, so once the laser is off and no weapon release or trigger sequence is going,
    -- the pod goes on to the next Strike List slot. Gives up after 15 s (a new hold or a search in between cancels it).
    local ak = S.adv_kill
    if ak then
        if now < ak.t then ak.t = now end
        if now - ak.t > 15 or S.hold or S.hold_pending or Search.Active() then
            S.adv_kill = nil
            AGLog.Info('pave: advance after the kill dropped (%s)', (now - ak.t > 15) and 'timeout' or 'the pod is busy again')
        elseif now - ak.t >= 1.5 and laser_on() ~= true and not Pave.ReleaseHeld() and not (Pave.TriggerBusy and Pave.TriggerBusy()) then
            S.adv_kill = nil
            local T = package.loaded['agplus.Targets']
            if T and T.AdvanceTo then
                local okt, errt = pcall(T.AdvanceTo, ak.slot)
                if not okt then AGLog.Info('pave: advance after the kill failed: %s', tostring(errt)) end
            end
        end
    end
    -- Dead target pulses (Nov 11 2026): the unit feed only runs while something asks for it (a search, a hold, a go-to), so a target destroyed
    -- while the pod sits idle was never noticed. While any list holds a target the feed is asked for a few seconds every DEAD_PULSE_S.
    if Config.PAVE_REMOVE_DEAD ~= false and S.state == 'idle' then
        if S.dead_next and S.dead_next - now > DEAD_PULSE_S then S.dead_next = nil end   -- the mission was restarted
        if not S.dead_next or now >= S.dead_next then
            local T = package.loaded['agplus.Targets']
            if (T and T.Count and T.Count() > 0) or #flat_list() > 0 then
                S.dead_next = now + DEAD_PULSE_S
                S.keepalive_until = math.max(S.keepalive_until or 0, now + DEAD_PULSE_ON_S)
            else
                S.dead_next = now + 2
            end
        end
    end
    if now < S.keepalive_until and now - S.last_req >= 1.0 then write_request() end
    if S.restore_zoom then
        local rz = S.restore_zoom
        if now > rz.till or Pave.SetZoom(rz.wide, 'back to the zoom from before the search') then S.restore_zoom = nil end
    end
    if S.state == 'idle' and now >= S.keepalive_until then return end

    if S.state == 'wait' then
        if now - S.started > FEED_WAIT_S then
            AGLog.Info('pave: search: no unit feed (is the Export script and hook installed?)')
            S.state = 'idle'
            S.status = 'Search failed'
            say_cant_do()
            return
        end
        if now - S.last_read < 0.3 then return end
        S.last_read = now
        local R = refresh_units_cache()
        if not R or R.t < S.started - 0.05 then return end
        local los = read_los(R.t)
        if not los then return end
        local L = Pave.ReadLook()
        local aim = aim_point(L and L.self or R.self, median_y(R.units))
        if not aim then
            AGLog.Info('pave: search: pod target point unreadable')
            S.state = 'idle'
            say_cant_do()
            return
        end
        local found, stat = Search.Evaluate(R.units, los, R.self, R.coal, aim)
        S.aim = aim
        local fc = {}
        for k, v in pairs(stat.far_cats) do fc[#fc + 1] = k .. '=' .. v end
        table.sort(fc)
        AGLog.Info('pave: search: aim %.0f %.0f (%.1f NM from the aircraft), %d candidates (friendly %d, outside area %d, masked %d, too far %d [%s, nearest %.1f NM], no los data %d)',
            aim.x, aim.z, dist3(aim, L and L.self or R.self) / 1852, #found, stat.friendly, stat.outside, stat.masked, stat.far,
            table.concat(fc, ' '), (stat.nearest_far or 0) / 1852, stat.no_los)
        if not begin_sweep(found, aim, L) then
            AGLog.Info('pave: sweep could not start, listing without moving the pod')
            finish_search(found, stat, aim, L and L.self or R.self)
        end
        return
    end

    if S.state == 'sweep' then
        local ok, err = pcall(sweep_tick, now)
        if not ok then
            AGLog.Info('pave: sweep failed: %s', tostring(err))
            S.sweep = nil
            S.state = 'idle'
            Pave.Stop()
        end
        return
    end

    if S.state == 'reveal' then
        local elapsed = now - S.reveal_start
        local want = math.min(#S.found, math.floor(elapsed / STEP_S))
        S.shown = want
        local done = elapsed >= MIN_S and (S.shown >= #S.found or elapsed >= MAX_S)
        if done then
            S.state = 'idle'
            S.status = counts_text()
            AGLog.Info('pave: search done: %s', S.status)
            refresh_menu()
            if #S.found == 0 and S.list and S.status == 'Nothing found in the area' then say_cant_do() else say_roger() end
        end
        return
    end

    -- Idle with a keepalive running (a go-to is under way): keep the position cache fresh.
    if now - S.last_read >= 0.5 then
        S.last_read = now
        refresh_units_cache()
    end
end

-- Pod target list (Oct 21 2026), for the context press menu in Pave.lua. The list is the same flat list a short press steps through.
-- The id the list opens on, the mode ('hold': something is held; 'lost': a lost hold waits to be reacquired) and the list length, or nil when the
-- menu does not apply (nothing held and nothing lost, or no list).
function Search.PodPickStart()
    local flat = flat_list()
    if #flat == 0 then return nil end
    if S.hold then
        local cur = Search.CurrentEntry()
        local id = cur and flat_index(cur.id) and cur.id or flat[1].id
        return id, 'hold', #flat
    end
    if Search.ReacquirePending() and S.last_hold then
        local id = flat_index(S.last_hold.id) and S.last_hold.id or flat[1].id
        return id, 'lost', #flat
    end
    return nil
end

-- What the pod holds for the context list: 'hold' with the held id (nil for a ground spot), 'lost' with the id of the lost one that waits,
-- or nil. No target list needed (the list is the Strike List now).
function Search.PodPickState()
    if S.hold then return 'hold', (not S.hold.spot) and S.hold.id or nil end
    if Search.ReacquirePending() and S.last_hold then return 'lost', S.last_hold.id end
    return nil
end

function Search.PodLastHeldId()
    local lh = S.last_hold
    if lh and lh.id and lh.id ~= -1 then return lh.id end
    return nil
end

function Search.PodLastHeldName()
    local lh = S.last_hold
    return lh and lh.name and Search.Pretty(lh.name) or nil
end

-- Reacquire the lost target now (chosen from the pick list).
function Search.PodReacquire()
    if S.hold or not (Search.ReacquirePending() and S.last_hold) then return false end
    return Search.Reacquire(NULL_TASK)
end

function Search.InFlat(id) return flat_index(id) ~= nil end

-- Search Area chosen in the context list. The pod must be in track and idle, as for the wheel item: a hold is let go first and the search
-- starts when the pod is idle (up to 3 s), a caged pod is refused (nothing to search around yet: long press looks there first).
local area_until = nil
function Search.PodAreaSearch()
    if Search.Active() then return false end
    if Pave.PodInTrackIdle() then
        Search.Start(NULL_TASK)
        say_roger()
        return true
    end
    if S.hold and Search.ReleaseHold() then
        area_until = Util.Now() + 3
        return true
    end
    Dbg.Notice('Search Area - Pod Is Caged, Long Press To Look There First', 5)
    AGLog.Info('pave: search area from the list refused: pod is not in track')
    say_cant_do()
    return false
end

function Search.PodAreaTick()
    if not area_until then return end
    if Util.Now() > area_until then area_until = nil return end
    if Pave.PodInTrackIdle() then
        area_until = nil
        Search.Start(NULL_TASK)
        say_roger()
    end
end

-- The id marked as the current target in the list: the one held, or the lost one that waits.
function Search.PodCurrentId()
    if S.hold then return S.hold.id end
    if Search.ReacquirePending() and S.last_hold then return S.last_hold.id end
    return nil
end

-- Where the vehicle is now (the unit feed), for the direction arrows.
function Search.EntryPoint(e)
    local q = S.units and S.units[e.id]
    if q then return { x = q.x, y = q.y, z = q.z } end
    return { x = e.x, y = e.y, z = e.z }
end

-- The pause after the last press is over: go to the entry the cursor is on. memory_auto: the pod is in memory with the automatic reacquire on,
-- so a lost hold only switches the target Jester reacquires (as a short press did); otherwise the pod goes to it now.
function Search.PodPickCommit(id, memory_auto)
    local fi, flat = flat_index(id)
    local e = fi and flat[fi]
    if not e then
        Dbg.Notice('That Target Is No Longer In The List', 4)
        return false
    end
    local name = e.alias or Search.Pretty(e.name)
    if S.hold and S.hold.id == id then
        AGLog.Info('pave: list: already holding %s', tostring(name))
        return true
    end
    if not S.hold and Search.ReacquirePending() and memory_auto then
        S.step_ref, S.step_idx = S.list, fi
        S.last_hold = { id = e.id, name = name, entry = e, lost = true, reacq = true }
        S.auto, S.auto_hist = nil, {}
        Dbg.Say(string.format('Switch Target - %s (%d of %d), reacquiring when it is in view', name, fi, #flat))
        AGLog.Info('pave: list: the pending reacquire is switched to %s (%d of %d); Jester goes to it when it is inside the pod limits', tostring(name), fi, #flat)
        return true
    end
    Dbg.Notice(string.format('Change Target - %s (%d of %d)', name, fi, #flat), 4)
    AGLog.Info('pave: list: going to %s (%d of %d)', tostring(name), fi, #flat)
    local ok = go_to_entry(NULL_TASK, e, string.format('list pick %s %d of %d', Search.Pretty(e.name), fi, #flat))
    if ok then S.step_ref, S.step_idx = S.list, fi end
    return ok
end

-- Maverick search (Oct 22 2026), the units a seeker can see: every hostile unit from the unit feed whose direction (aim_fn gives az / el above the
-- boresight and the range) lies inside 'half' degrees of (cx, cy), closer than range_fn(category) meters and not hidden by terrain.
-- Returns { id =, u =, rng = } entries; the caller does the dwell and calls Search.AddSpotted.
local mav_los_t, mav_los = nil, nil
function Search.MavScan(aim_fn, cx, cy, half, range_fn)
    local out = {}
    if not S.units or S.coal == nil then return out end
    if S.units_t ~= mav_los_t then
        mav_los_t = S.units_t
        mav_los = S.units_t and read_los(S.units_t) or nil
    end
    for id, u in pairs(S.units) do
        if u.coal ~= S.coal and not (mav_los and mav_los[id] == false) then
            local a = aim_fn({ id = id, x = u.x, y = u.y, z = u.z })
            if a then
                local d = math.sqrt((a.az - cx) ^ 2 + (a.el - cy) ^ 2)
                if d <= half and a.rng <= range_fn(u.cat) then out[#out + 1] = { id = id, u = u, rng = a.rng } end
            end
        end
    end
    return out
end

-- Delete Unit: the unit leaves the target list (the strike list slot is cleared by Targets). Returns true when it was listed.
function Search.RemoveUnit(id)
    local flat = flat_list()
    local out, removed = {}, false
    for _, e in ipairs(flat) do
        if e.id == id then removed = true else out[#out + 1] = e end
    end
    if not removed then return false end
    S.list = Search.Group(out)
    S.af_ref = S.list
    S.step_ref, S.step_idx = nil, 0
    S.status = counts_text()
    AGLog.Info('pave: unit %s deleted from the target list (%d targets now)', tostring(id), #out)
    return true
end

-- A unit the Maverick search spotted joins the target list (the same list the pod's search fills). Returns true when it was new.
function Search.AddSpotted(u)
    return list_add({ id = u.id, name = u.name, cat = u.cat, x = u.x, y = u.y, z = u.z })
end

return Search
