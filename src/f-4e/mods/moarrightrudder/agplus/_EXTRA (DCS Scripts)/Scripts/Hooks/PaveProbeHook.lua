-- Jester A/G+ Pave Spike terrain hook (production). Read-only: changes nothing in the sim.
-- Works from the view and unit files that PaveProbeFeed.lua (Export side) writes, and answers the Jester side with:
--   Logs\pavespike_look.txt     where the player's view line meets the terrain, 10 times a second (look there)
--   Logs\pavespike_ray.txt      a terrain ray on request (ground spot)
--   Logs\pavespike_targets.txt  terrain line of sight to every unit and static (search filter, laser masking)
--   Logs\pavespike_statics.txt  static objects near the aircraft (asked of the server scripting; a client gets none)
-- Terrain comes from the local terrain library, with the server scripting as fallback. Hooks load only at DCS start, so a
-- change here needs a full restart.
local dir = ((lfs and lfs.writedir and lfs.writedir()) or '') .. 'Logs\\'
local IN_PATH = dir .. 'pavespike_probe_view.txt'
local START_AFTER = 12     -- model seconds; the callsign hook taught us not to touch things in the first seconds after spawn
local LOOK_PERIOD = 0.1    -- real seconds (where the pilot is looking)
local LOOK_PATH = dir .. 'pavespike_look.txt'
local last_look = -1

local function wlog(msg) pcall(function() log.write('PAVEPROBEHOOK', log.INFO, msg) end) end

-- Local terrain (Oct 20 2026). On a multiplayer client net.dostring_in('server', ...) returns nothing, because the server's
-- scripting runs on the host's machine. The client still has the terrain library itself (terrain.GetHeight / terrain.isVisible,
-- measured on a client: height under the parked aircraft 40.010 m = altitude 42.094 m - radar height 2.084 m), so the look
-- line, the ground-spot ray and the line of sight are worked out here. The server route stays as the fallback, and wherever
-- the server answers (single player, hosting) both are compared: Logs\agp_terrain_check.txt shows how often they agree.
local function get_terrain()
    local t = rawget(_G, 'terrain')
    if type(t) ~= 'table' and type(package) == 'table' and type(package.loaded) == 'table' then t = package.loaded.terrain end
    if type(t) == 'table' and type(t.GetHeight) == 'function' then return t end
    return nil
end

local function terrain_height(T, x, z)
    local ok, r = pcall(T.GetHeight, x, z)
    if ok and type(r) == 'number' then return r end
    return nil
end

-- The same search the server code does: coarse steps (250 m, then 500 m beyond 20 km) out to 80 km, then 12 bisections.
local function march(T, cx, cy, cz, fx, fy, fz)
    local prev, d = 0, 250
    while d <= 80000 do
        local th = terrain_height(T, cx + fx * d, cz + fz * d)
        if th and cy + fy * d <= th then
            local lo, hi = prev, d
            for _ = 1, 12 do
                local mid = (lo + hi) / 2
                local mh = terrain_height(T, cx + fx * mid, cz + fz * mid)
                if mh and (cy + fy * mid) <= mh then hi = mid else lo = mid end
            end
            local dd = (lo + hi) / 2
            local x, z = cx + fx * dd, cz + fz * dd
            return string.format('HIT %.1f %.1f %.1f %.0f', x, terrain_height(T, x, z) or 0, z, dd)
        end
        prev = d
        d = d + ((d < 20000) and 250 or 500)
    end
    return 'NOHIT'
end

local function los_list(T, sx, sy, sz, ustr)
    local out = {}
    for id, x, y, z in ustr:gmatch('{(%-?%d+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)}') do
        local ok, vis = pcall(T.isVisible, sx, sy, sz, tonumber(x), tonumber(y) + 2, tonumber(z))
        out[#out + 1] = string.format('L %d %s', tonumber(id), ok and (vis and '1' or '0') or 'E')
    end
    return table.concat(out, '\n')
end

-- Agreement between the local and the server answers, for the single-player / host case.
local CHECK_PATH = dir .. 'agp_terrain_check.txt'
local chk = { ray = 0, ray_same = 0, los = 0, los_same = 0, bad = {} }
local last_check_ray = -10
local function write_check()
    local f = io.open(CHECK_PATH, 'w')
    if not f then return end
    f:write(string.format('C1 ray_pairs=%d ray_same=%d los_pairs=%d los_same=%d\n', chk.ray, chk.ray_same, chk.los, chk.los_same))
    for _, b in ipairs(chk.bad) do f:write(b .. '\n') end
    f:write('END\n')
    f:close()
end
local function same_ray(a, b)
    if a == b then return true end
    local ax, ay, az, ad = a:match('^HIT ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)')
    local bx, by, bz, bd = b:match('^HIT ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)')
    if not (ax and bx) then return false end
    return math.abs(tonumber(ax) - tonumber(bx)) < 3 and math.abs(tonumber(az) - tonumber(bz)) < 3 and math.abs(tonumber(ay) - tonumber(by)) < 3
end

-- Terrain ray from (cx,cy,cz) along (fx,fy,fz), all map coordinates. Returns ok, text like the old server call.
local function terrain_ray(code_fmt, cx, cy, cz, fx, fy, fz)
    local T = get_terrain()
    if T then
        local ok, res = pcall(march, T, tonumber(cx), tonumber(cy), tonumber(cz), tonumber(fx), tonumber(fy), tonumber(fz))
        if ok and type(res) == 'string' then
            local rt = DCS.getRealTime()
            if chk.ray < 400 and rt - last_check_ray >= 1.0 then
                last_check_ray = rt
                local sok, sres = pcall(net.dostring_in, 'server', string.format(code_fmt, cx, cy, cz, fx, fy, fz))
                if sok and type(sres) == 'string' and sres:match('^[HN][IO]T') then
                    chk.ray = chk.ray + 1
                    local sr = sres:match('^[HN][IO]T?[^\n]*') or sres
                    if same_ray(res, sr) then chk.ray_same = chk.ray_same + 1
                    elseif #chk.bad < 6 then chk.bad[#chk.bad + 1] = 'RAY local=' .. res .. ' server=' .. sr end
                    write_check()
                end
            end
            return true, res
        end
    end
    return pcall(net.dostring_in, 'server', string.format(code_fmt, cx, cy, cz, fx, fy, fz))
end

local function terrain_los(code_fmt, sx, sy, sz, ustr)
    local T = get_terrain()
    if T then
        local ok, res = pcall(los_list, T, tonumber(sx), tonumber(sy), tonumber(sz), ustr)
        if ok and type(res) == 'string' then
            if chk.los < 20 then
                local sok, sres = pcall(net.dostring_in, 'server', string.format(code_fmt, sx, sy, sz, ustr))
                if sok and type(sres) == 'string' and sres:match('^L ') then
                    local a, b = {}, {}
                    for id, v in res:gmatch('L (%d+) (%S+)') do a[id] = v end
                    for id, v in sres:gmatch('L (%d+) (%S+)') do b[id] = v end
                    for id, v in pairs(b) do
                        chk.los = chk.los + 1
                        if a[id] == v then chk.los_same = chk.los_same + 1
                        elseif #chk.bad < 6 then chk.bad[#chk.bad + 1] = string.format('LOS id=%s local=%s server=%s', id, tostring(a[id]), v) end
                    end
                    write_check()
                end
            end
            return true, res
        end
    end
    return pcall(net.dostring_in, 'server', string.format(code_fmt, sx, sy, sz, ustr))
end

-- Pave Spike "look there": where the view line meets the terrain, ten times a second. Read by agplus\Pave.lua.
local LOOK_CODE = [[
local cx, cy, cz, fx, fy, fz = %s, %s, %s, %s, %s, %s
if not land then return 'NOLAND' end
local function h(x, z) local ok, r = pcall(land.getHeight, { x = x, y = z }) if ok then return r end return nil end
local prev, d = 0, 250
while d <= 80000 do
    local th = h(cx + fx * d, cz + fz * d)
    if th and cy + fy * d <= th then
        local lo, hi = prev, d
        for _ = 1, 12 do
            local mid = (lo + hi) / 2
            local mh = h(cx + fx * mid, cz + fz * mid)
            if mh and (cy + fy * mid) <= mh then hi = mid else lo = mid end
        end
        local dd = (lo + hi) / 2
        local x, z = cx + fx * dd, cz + fz * dd
        return string.format('HIT %%.1f %%.1f %%.1f %%.0f', x, h(x, z) or 0, z, dd)
    end
    prev = d
    d = d + ((d < 20000) and 250 or 500)
end
return 'NOHIT'
]]

local function read_self(txt)
    local s = { txt:match('SELF pos=([%-%d%.]+),([%-%d%.]+),([%-%d%.]+) heading=([%-%d%.]+) pitch=([%-%d%.]+) bank=([%-%d%.]+)') }
    if #s < 6 then return nil end
    return s
end

local function look_tick(mt)
    local f = io.open(IN_PATH, 'r')
    if not f then return end
    local txt = f:read('*a')
    f:close()
    local t = tonumber(txt:match('V1 t=([%d%.]+)'))
    local p = { txt:match('CAM p=([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)') }
    local d = { txt:match('fwd=([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)') }
    local s = read_self(txt)
    if not t or #p < 3 or #d < 3 or not s then return end
    local ok, res = terrain_ray(LOOK_CODE, p[1], p[2], p[3], d[1], d[2], d[3])
    if not ok then res = 'NOHIT' end
    res = tostring(res)
    local out = io.open(LOOK_PATH, 'w')
    if out then
        -- CAM: the head camera's position and direction, so the Jester side can tell whether the player is looking at the panel
        -- (inside) or out of the canopy.
        out:write(string.format('V2 view_t=%.2f hook_t=%.1f\nSELF %s %s %s %s %s %s\nCAM %s %s %s %s %s %s\n%s\nEND\n', t, mt, s[1], s[2], s[3], s[4], s[5], s[6],
            p[1], p[2], p[3], d[1], d[2], d[3], res:match('^[HN][IO]T?[^\n]*') or 'NOHIT'))
        out:close()
    end
end


-- Terrain ray on request (Oct 19 2026): Jester writes Logs\pavespike_ray_req.txt ("Q1 id=N ox oy oz dx dy dz", an origin and a
-- direction in map coordinates) and gets the first terrain hit back in Logs\pavespike_ray.txt ("R1 id=N", then HIT x y z dist
-- or NOHIT). Used for the ground spot the pod looks at and for the terrain height under the pod after a look there.
local RAY_REQ = dir .. 'pavespike_ray_req.txt'
local RAY_OUT = dir .. 'pavespike_ray.txt'
local last_ray_id
local function ray_tick(mt)
    local f = io.open(RAY_REQ, 'r')
    if not f then return end
    local txt = f:read('*a')
    f:close()
    local id, ox, oy, oz, dx, dy, dz = (txt or ''):match('Q1 id=(%d+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)')
    if not id or id == last_ray_id then return end
    last_ray_id = id
    local ok, res = terrain_ray(LOOK_CODE, ox, oy, oz, dx, dy, dz)
    res = ok and tostring(res) or 'NOHIT'
    local out = io.open(RAY_OUT, 'w')
    if out then
        out:write(string.format('R1 id=%s hook_t=%.1f\n%s\nEND\n', id, mt, res:match('^[HN][IO]T?[^\n]*') or 'NOHIT'))
        out:close()
    end
end

-- Pave Spike area search: terrain line of sight from the aircraft to every unit in Logs\pavespike_units.txt (written by
-- PaveProbeFeed.lua only while the Jester side asks for it). Result: Logs\pavespike_targets.txt, one "L id los" line per unit.
local UNITS_PATH = dir .. 'pavespike_units.txt'
local TARGETS_PATH = dir .. 'pavespike_targets.txt'
local LOS_CODE = [[
local sx, sy, sz = %s, %s, %s
local U = { %s }
if not land then return 'NOLAND' end
local out = {}
for _, u in ipairs(U) do
    local ok, vis = pcall(land.isVisible, { x = sx, y = sy, z = sz }, { x = u[2], y = u[3] + 2, z = u[4] })
    out[#out + 1] = string.format('L %%d %%s', u[1], ok and (vis and '1' or '0') or 'E')
end
return table.concat(out, '\n')
]]
local UNITS_CHECK = 0.4

-- Static objects (Oct 19 2026). The Export world-object list (LoGetWorldObjects) carries ground units but not the static
-- objects placed in the mission editor, so the area search never saw them. The mission scripting environment does know them
-- (coalition.getStaticObjects), so this asks it for every static of both sides, keeps the list for a few seconds, and writes the
-- ones near the aircraft to Logs\pavespike_statics.txt for the Jester side, with the same units_t as the unit file they go with.
-- They also get a terrain line of sight below, in the same "L id los" list. Ids are 900000000 + the mission id so they never
-- clash with Export ids. SELFSIDE is the player's own side (1 red, 2 blue) from the human-controlled unit; the Jester side
-- treats the same side as friendly.
local STATICS_PATH = dir .. 'pavespike_statics.txt'
local STATIC_PERIOD = 5.0          -- real seconds between mission-environment queries (statics do not move)
local STATIC_RANGE = 45000         -- meters, horizontal, same as the unit feed
local STATIC_MAX = 250
local STAT_CODE = [[
if not coalition or not coalition.getStaticObjects then return 'NOAPI' end
if AGP_SELFSIDE == nil then
  for _, side in ipairs({1, 2}) do
    local okg, groups = pcall(coalition.getGroups, side)
    if okg and groups then
      for _, g in ipairs(groups) do
        local oku, units = pcall(g.getUnits, g)
        if oku and units then
          for _, u in ipairs(units) do
            local okp, pn = pcall(u.getPlayerName, u)
            if okp and pn then AGP_SELFSIDE = side break end
          end
        end
        if AGP_SELFSIDE then break end
      end
    end
    if AGP_SELFSIDE then break end
  end
end
local out = { 'SELFSIDE ' .. tostring(AGP_SELFSIDE or '?') }
for side = 1, 2 do
  local ok, list = pcall(coalition.getStaticObjects, side)
  if ok and list then
    for _, o in ipairs(list) do
      local oke, ex = pcall(o.isExist, o)
      if oke and ex then
        local okp, p = pcall(o.getPoint, o)
        if okp and p then
          local okn, tn = pcall(o.getTypeName, o)
          local oki, id = pcall(o.getID, o)
          out[#out + 1] = string.format('S %d %.1f %.1f %.1f %d %s', 900000000 + (tonumber(id) or 0), p.x, p.y, p.z, side, (tostring(okn and tn or 'static'):gsub('%s', '_')))
        end
      end
    end
  end
end
return table.concat(out, '\n')
]]
local statics, static_side, static_t, static_counts = {}, nil, -100, ''
local static_err_logged = false

local static_fails = 0

-- Multiplayer fallback (Nov 10 2026). A client cannot reach the server scripting, but it holds the mission it loaded, and the
-- mission lists every static object placed in the editor (type, name, x, y). Those are the starting positions only: a static the
-- mission scripts spawn later is not listed, and one that has been destroyed stays listed. Heights come from the local terrain.
local function my_side()
    local ok, id = pcall(net.get_my_player_id)
    if not ok or id == nil then return nil end
    local ok2, sd = pcall(net.get_player_info, id, 'side')
    if ok2 and tonumber(sd) and tonumber(sd) > 0 then return tonumber(sd) end
    return nil
end

local function load_mission_statics()
    local ok, m = pcall(DCS.getCurrentMission)
    if not ok or type(m) ~= 'table' or type(m.mission) ~= 'table' or type(m.mission.coalition) ~= 'table' then
        wlog('statics: the mission table is not available here (' .. tostring(ok and type(m) or m) .. ')')
        return
    end
    local T = get_terrain()
    local list, red, blue = {}, 0, 0
    for cname, side in pairs({ red = 1, blue = 2 }) do
        local co = m.mission.coalition[cname]
        local countries = (type(co) == 'table' and type(co.country) == 'table') and co.country or {}
        for _, country in ipairs(countries) do
            local st = type(country) == 'table' and country.static
            local groups = (type(st) == 'table' and type(st.group) == 'table') and st.group or {}
            for _, grp in ipairs(groups) do
                local units = (type(grp) == 'table' and type(grp.units) == 'table') and grp.units or {}
                for _, u in ipairs(units) do
                    if type(u) == 'table' and type(u.x) == 'number' and type(u.y) == 'number' then
                        local hgt = (T and terrain_height(T, u.x, u.y)) or 0
                        list[#list + 1] = { id = tostring(900000000 + (tonumber(u.unitId) or #list + 1)), x = u.x, y = hgt, z = u.y, side = side, name = (tostring(u.type or 'static'):gsub('%s', '_')) }
                        if side == 1 then red = red + 1 else blue = blue + 1 end
                    end
                end
            end
        end
    end
    statics = list
    static_side = my_side()
    static_counts = string.format('red=%d blue=%d selfside=%s (from the mission file)', red, blue, tostring(static_side))
    wlog('statics: ' .. static_counts)
end

local function refresh_statics()
    if static_fails >= 3 then return end   -- a client in multiplayer cannot reach the server scripting; stop asking (Oct 27 2026)
    local rt = DCS.getRealTime()
    if rt - static_t < STATIC_PERIOD then return end
    static_t = rt
    local ok, res = pcall(net.dostring_in, 'server', STAT_CODE)
    if not ok or type(res) ~= 'string' then
        static_fails = static_fails + 1
        if not static_err_logged then static_err_logged = true wlog('statics query failed: ' .. tostring(res)) end
        if static_fails >= 3 then
            wlog('statics: the server scripting is not reachable here (a client in multiplayer); using the mission file instead')
            pcall(load_mission_statics)
        end
        return
    end
    static_fails = 0
    if res == 'NOAPI' then
        if not static_err_logged then static_err_logged = true wlog('coalition.getStaticObjects is not available here') end
        return
    end
    local list, red, blue = {}, 0, 0
    local side = res:match('SELFSIDE (%S+)')
    static_side = tonumber(side)
    for id, x, y, z, sd, name in res:gmatch('\nS (%d+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) (%d) (%S+)') do
        list[#list + 1] = { id = id, x = tonumber(x), y = tonumber(y), z = tonumber(z), side = tonumber(sd), name = name }
        if sd == '1' then red = red + 1 else blue = blue + 1 end
    end
    statics = list
    static_counts = string.format('red=%d blue=%d selfside=%s', red, blue, tostring(side))
    if not static_err_logged then
        static_err_logged = true
        wlog('statics: ' .. static_counts)
    end
end
local last_units_check = -1
local last_units_t = -1

local function targets_tick(mt)
    local f = io.open(UNITS_PATH, 'r')
    if not f then return end
    local txt = f:read('*a')
    f:close()
    if not txt or not txt:find('\nEND') then return end
    local t = tonumber(txt:match('U1 t=([%d%.]+)'))
    if not t or t == last_units_t then return end
    local sx, sy, sz = txt:match('\nSELF ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)')
    if not sx then return end
    local u = {}
    for id, x, y, z in txt:gmatch('\nU (%d+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ') do
        u[#u + 1] = string.format('{%s,%s,%s,%s}', id, x, y, z)
    end
    last_units_t = t
    -- statics near the aircraft: into the line of sight list, and into their own file for the Jester side
    pcall(refresh_statics)
    local sl = {}
    local nsx, nsz = tonumber(sx), tonumber(sz)
    for _, s in ipairs(statics) do
        if #sl >= STATIC_MAX then break end
        local dx, dz = s.x - nsx, s.z - nsz
        if dx * dx + dz * dz <= STATIC_RANGE * STATIC_RANGE then
            sl[#sl + 1] = s
            u[#u + 1] = string.format('{%s,%.1f,%.1f,%.1f}', s.id, s.x, s.y, s.z)
        end
    end
    do
        local sf = io.open(STATICS_PATH, 'w')
        if sf then
            local lines = { string.format('T1 units_t=%.2f', t), 'SELFSIDE ' .. tostring(static_side or '?'), 'ALL ' .. static_counts, 'COUNT ' .. #sl }
            for _, s in ipairs(sl) do lines[#lines + 1] = string.format('S %s %.1f %.1f %.1f %d %s', s.id, s.x, s.y, s.z, s.side, s.name) end
            lines[#lines + 1] = 'END'
            sf:write(table.concat(lines, '\n') .. '\n')
            sf:close()
        end
    end
    local ok, res = terrain_los(LOS_CODE, sx, sy, sz, table.concat(u, ','))
    local body = ok and tostring(res) or ('ERROR ' .. tostring(res))
    local out = io.open(TARGETS_PATH, 'w')
    if out then
        out:write(string.format('V3 units_t=%.2f hook_t=%.1f count=%d\n%s\nEND\n', t, mt, #u, body))
        out:close()
    end
end

local function tick()
    local rt = DCS.getRealTime()
    local mt = DCS.getModelTime()
    if mt < START_AFTER then return end
    if rt - last_look >= LOOK_PERIOD then last_look = rt pcall(look_tick, mt) pcall(ray_tick, mt) end
    if rt - last_units_check >= UNITS_CHECK then last_units_check = rt pcall(targets_tick, mt) end
end

local cb = {}
function cb.onSimulationFrame()
    local ok, err = pcall(tick)
    if not ok and not cb.failed then cb.failed = true wlog('error: ' .. tostring(err)) end
end
DCS.setUserCallbacks(cb)
wlog('loaded')
