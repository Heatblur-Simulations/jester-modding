-- Jester Survivability feed (DCS Export environment).
-- Every 0.1 s: reads the world object list (LoGetWorldObjects), finds missiles other coalitions fired, and writes one
-- line per missile (range, closing speed, miss distance, bearing off the nose, shooter) to Logs\surv_feed.txt.
-- The Jester suite (mods\survivability) reads that file. Pure read-only: it changes nothing in the sim.
-- Needs the server to allow object export; with it off the list is empty and the suite simply sees no feed.
-- Remove the dofile line for this file from Scripts\Export.lua to disable.
do
    if SURV_FEED_LOADED then return end
    SURV_FEED_LOADED = true

    local PATH = lfs.writedir() .. [[Logs\surv_feed.txt]]
    local PERIOD = 0.1          -- seconds between writes
    local MAX_NM = 80           -- missiles beyond this are ignored
    local SHOOTER_M = 3000      -- the shooter is the nearest enemy aircraft within this of the missile when first seen
    local MAX_LINES = 16

    local function w(msg) pcall(function() log.write('SURVFEED', log.INFO, msg) end) end
    w('loaded, writing ' .. PATH)

    local tracks = {}   -- id -> { first, px, py, pz, pt, vx, vy, vz, shooter, lnm }
    local last_t = -1
    local logged_types = {}

    local function norm(v) return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3]) end

    local function write_feed()
        local t = LoGetModelTime and LoGetModelTime() or 0
        if t - last_t < PERIOD and t >= last_t then return end
        last_t = t

        local self_data = LoGetSelfData and LoGetSelfData()
        local objs = LoGetWorldObjects and LoGetWorldObjects()
        local out = {}
        if not self_data or not self_data.Position then
            out[#out + 1] = string.format('V1 t=%.2f noself=1', t)
            out[#out + 1] = 'END'
            local f = io.open(PATH, 'w'); if f then f:write(table.concat(out, '\n')); f:close() end
            return
        end
        local sp = self_data.Position
        local sv = LoGetVectorVelocity and LoGetVectorVelocity() or { x = 0, y = 0, z = 0 }
        local heading = self_data.Heading or 0
        local my_coal = self_data.Coalition or self_data.CoalitionID

        local counts, nobj = {}, 0
        local aircraft, weapons = {}, {}
        if objs then
            for id, o in pairs(objs) do
                nobj = nobj + 1
                local l1 = o.Type and o.Type.level1 or -1
                counts[l1] = (counts[l1] or 0) + 1
                if l1 == 1 then
                    aircraft[#aircraft + 1] = { id = id, o = o }
                elseif l1 == 4 then
                    weapons[#weapons + 1] = { id = id, o = o }
                end
            end
        end
        local cstr = {}
        for k, v in pairs(counts) do cstr[#cstr + 1] = tostring(k) .. ':' .. tostring(v) end
        table.sort(cstr)
        out[#out + 1] = string.format('V1 t=%.2f obj=%d weapons=%d L1=%s', t, nobj, #weapons, table.concat(cstr, ','))

        local seen = {}
        local lines = {}
        for _, wp in ipairs(weapons) do
            local o, id = wp.o, wp.id
            local p = o.Position
            if p and o.Coalition ~= my_coal then
                local name = tostring(o.Name or '?'):gsub('%s', '_')
                if not logged_types[name] then
                    logged_types[name] = true
                    local ty = o.Type or {}
                    out[#out + 1] = string.format('W n=%s coal=%s mine=%s type=%s/%s/%s/%s', name, tostring(o.Coalition), tostring(my_coal), tostring(ty.level1), tostring(ty.level2), tostring(ty.level3), tostring(ty.level4))
                    w('weapon ' .. name .. ' type=' .. tostring(ty.level1) .. '/' .. tostring(ty.level2) .. '/' .. tostring(ty.level3) .. '/' .. tostring(ty.level4))
                end
                seen[id] = true
                local tr = tracks[id]
                if not tr then
                    tr = { first = t, px = p.x, py = p.y, pz = p.z, pt = t }
                    -- shooter: nearest enemy aircraft right at the missile when first seen
                    local best, bd
                    for _, a in ipairs(aircraft) do
                        local ap = a.o.Position
                        if ap and a.o.Coalition == o.Coalition then
                            local d = math.sqrt((ap.x - p.x) ^ 2 + (ap.y - p.y) ^ 2 + (ap.z - p.z) ^ 2)
                            if d < SHOOTER_M and (not bd or d < bd) then best, bd = a, d end
                        end
                    end
                    if best then
                        local ap = best.o.Position
                        tr.shooter = tostring(best.o.Name or '?'):gsub('%s', '_')
                        tr.lnm = math.sqrt((ap.x - sp.x) ^ 2 + (ap.y - sp.y) ^ 2 + (ap.z - sp.z) ^ 2) / 1852
                    end
                    tracks[id] = tr
                else
                    local dt = t - tr.pt
                    if dt >= 0.05 then
                        tr.vx, tr.vy, tr.vz = (p.x - tr.px) / dt, (p.y - tr.py) / dt, (p.z - tr.pz) / dt
                        tr.px, tr.py, tr.pz, tr.pt = p.x, p.y, p.z, t
                    end
                end
                if tr.vx then
                    local rel = { p.x - sp.x, p.y - sp.y, p.z - sp.z }
                    local vrel = { tr.vx - sv.x, tr.vy - sv.y, tr.vz - sv.z }
                    local range = norm(rel)
                    local v2 = vrel[1] ^ 2 + vrel[2] ^ 2 + vrel[3] ^ 2
                    if range > 1 and v2 > 1 and range < MAX_NM * 1852 then
                        local dot = rel[1] * vrel[1] + rel[2] * vrel[2] + rel[3] * vrel[3]
                        local closing = -dot / range
                        local miss = math.sqrt(math.max(range * range - dot * dot / v2, 0))
                        local bearing = math.deg(math.atan2(rel[3], rel[1]))
                        local az = (bearing - math.deg(heading)) % 360
                        lines[#lines + 1] = { range = range, text = string.format(
                            'M id=%s n=%s rng=%.0f cls=%.0f miss=%.0f az=%.1f alt=%.0f age=%.1f sh=%s lnm=%.1f spd=%.0f', tostring(id), tostring(o.Name or '?'):gsub('%s', '_'),
                            range, closing, miss, az, rel[2], t - tr.first, tr.shooter or '-', tr.lnm or -1, math.sqrt(tr.vx ^ 2 + tr.vy ^ 2 + tr.vz ^ 2)) }
                    end
                end
            end
        end
        for id in pairs(tracks) do if not seen[id] then tracks[id] = nil end end
        table.sort(lines, function(a, b) return a.range < b.range end)
        for i = 1, math.min(#lines, MAX_LINES) do out[#out + 1] = lines[i].text end
        out[#out + 1] = 'END'
        local f = io.open(PATH, 'w')
        if f then f:write(table.concat(out, '\n')); f:close() end
    end

    local prev_after = LuaExportAfterNextFrame
    LuaExportAfterNextFrame = function()
        if prev_after then prev_after() end
        local ok, err = pcall(write_feed)
        if not ok and not SURV_FEED_ERR then
            SURV_FEED_ERR = true
            w('error: ' .. tostring(err))
        end
    end
end
