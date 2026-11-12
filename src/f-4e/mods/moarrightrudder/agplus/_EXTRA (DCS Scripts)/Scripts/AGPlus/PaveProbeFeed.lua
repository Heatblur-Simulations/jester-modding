-- Jester A/G+ Pave Spike view and unit feed (DCS Export environment). Production, read-only: it changes nothing in the sim.
--   Logs\pavespike_probe_view.txt  10 times a second: V1 time, SELF (own position, heading, pitch, bank, height above ground),
--                                  CAM (the player's view camera position and direction), CAMANG. Read by PaveProbeHook.lua
--                                  (look there, ground spot).
--   Logs\pavespike_units.txt       once a second, only while the Jester side asks (pavespike_units_req.txt): ground units
--                                  with position, side, type, name and heading. Used by search, hold and laser masking.
do
    if PAVEPROBE_FEED_LOADED then return end
    PAVEPROBE_FEED_LOADED = true

    local PATH = lfs.writedir() .. [[Logs\pavespike_probe_view.txt]]
    local PERIOD = 0.1
    local START_DELAY = 8.0

    local function w(msg) pcall(function() log.write('PAVEPROBE', log.INFO, msg) end) end
    w('loaded, writing ' .. PATH)

    local last_t = -1

    local function v3(v)
        if type(v) ~= 'table' then return 'nil' end
        return string.format('%.1f,%.1f,%.1f', v.x or 0, v.y or 0, v.z or 0)
    end

    local function dir3(v)
        if type(v) ~= 'table' then return 'nil' end
        return string.format('%.5f,%.5f,%.5f', v.x or 0, v.y or 0, v.z or 0)
    end

    local function build(t)
        local out = {}
        out[#out + 1] = string.format('V1 t=%.2f', t)

        local cam = LoGetCameraPosition and LoGetCameraPosition()
        local self_data = LoGetSelfData and LoGetSelfData()
        local sp = self_data and self_data.Position
        if sp then
            out[#out + 1] = string.format('SELF pos=%s heading=%.1f pitch=%.1f bank=%.1f agl=%s', v3(sp),
                math.deg(self_data.Heading or 0), math.deg(self_data.Pitch or 0), math.deg(self_data.Bank or 0),
                tostring(LoGetAltitudeAboveGroundLevel and LoGetAltitudeAboveGroundLevel()))
        else
            out[#out + 1] = 'SELF none'
        end
        if type(cam) ~= 'table' or type(cam.p) ~= 'table' or type(cam.x) ~= 'table' then
            out[#out + 1] = 'CAM none'
            return out
        end
        local p, f = cam.p, cam.x
        out[#out + 1] = string.format('CAM p=%s fwd=%s up=%s', v3(p), dir3(f), dir3(cam.y))
        local az = math.deg(math.atan2(f.z or 0, f.x or 0)) % 360
        local el = math.deg(math.asin(math.max(-1, math.min(1, f.y or 0))))
        out[#out + 1] = string.format('CAMANG azimuth_true=%.1f elevation=%.1f', az, el)

        return out
    end


    -- Ground unit list for the Pave Spike area search. Written once a second, and only while the Jester side keeps
    -- asking for it (it rewrites Logs\pavespike_units_req.txt with the model time while a search or slew needs it).
    local UNITS_PATH = lfs.writedir() .. [[Logs\pavespike_units.txt]]
    local REQ_PATH = lfs.writedir() .. [[Logs\pavespike_units_req.txt]]
    local UNITS_PERIOD = 1.0
    local UNITS_MAX, UNITS_RANGE = 400, 45000
    local last_units = -10

    local function units_wanted(t)
        local f = io.open(REQ_PATH, 'r')
        if not f then return false end
        local txt = f:read('*a')
        f:close()
        local rt = tonumber(txt and txt:match('REQ ([%d%.]+)'))
        return rt ~= nil and t - rt < 4 and rt - t < 10
    end

    local function write_units(t)
        local sd = LoGetSelfData and LoGetSelfData()
        local sp = sd and sd.Position
        local objs = LoGetWorldObjects and LoGetWorldObjects()
        if not (sp and objs) then return end
        local list = {}
        local classes, other_seen = {}, 0
        for id, o in pairs(objs) do
            local ty = o.Type or {}
            local op = o.Position
            -- Class census (Oct 27 2026): how many objects of each Export class, so the log shows whether statics or ships come through on a server.
            local c1 = tostring(ty.level1)
            classes[c1] = (classes[c1] or 0) + 1
            if ty.level1 ~= 1 and ty.level1 ~= 2 and ty.level1 ~= 3 and ty.level1 ~= 4 and other_seen < 6 and not PAVEPROBE_OTHER_LOGGED then
                other_seen = other_seen + 1
                w(string.format('object class %s/%s/%s/%s name=%s', c1, tostring(ty.level2), tostring(ty.level3), tostring(ty.level4), tostring(o.Name)))
            end
            -- Ground (2) and navy (3): ships were left out before.
            if (ty.level1 == 2 or ty.level1 == 3) and type(op) == 'table' then
                local dx, dz = op.x - sp.x, op.z - sp.z
                local d = math.sqrt(dx * dx + dz * dz)
                if d <= UNITS_RANGE then list[#list + 1] = { id = id, o = o, ty = ty, op = op, d = d } end
            end
        end
        if other_seen > 0 then PAVEPROBE_OTHER_LOGGED = true end
        if not PAVEPROBE_CENSUS_LOGGED then
            PAVEPROBE_CENSUS_LOGGED = true
            local keys = {}
            for k, n in pairs(classes) do keys[#keys + 1] = k .. ':' .. n end
            table.sort(keys)
            w('object census (level1:count) ' .. table.concat(keys, ' '))
        end
        table.sort(list, function(a, b) return a.d < b.d end)
        local out = { string.format('U1 t=%.2f', t),
            string.format('SELF %.1f %.1f %.1f', sp.x, sp.y, sp.z),
            'SELFCOAL ' .. tostring(sd.Coalition):gsub('%s', '_'),
            'COUNT ' .. #list }
        for i = 1, math.min(UNITS_MAX, #list) do
            local g = list[i]
            -- Last field: the unit's own heading in degrees true (-1 when the object has none). Older readers ignore it.
            local hdg = tonumber(g.o.Heading)
            hdg = hdg and ((math.deg(hdg) % 360)) or -1
            out[#out + 1] = string.format('U %s %.1f %.1f %.1f %s %s/%s/%s/%s %s hdg=%.1f', tostring(g.id), g.op.x, g.op.y, g.op.z,
                (tostring(g.o.Coalition):gsub('%s', '_')), tostring(g.ty.level1), tostring(g.ty.level2), tostring(g.ty.level3),
                tostring(g.ty.level4), (tostring(g.o.Name or '?'):gsub('%s', '_')), hdg)
        end
        out[#out + 1] = 'END'
        local f = io.open(UNITS_PATH, 'w')
        if f then f:write(table.concat(out, '\n') .. '\n') f:close() end
    end

    local function tick()
        local t = LoGetModelTime and LoGetModelTime() or 0
        if t < START_DELAY then return end
        if t - last_units >= UNITS_PERIOD or t < last_units then
            last_units = t
            if units_wanted(t) then pcall(write_units, t) end
        end
        if t - last_t < PERIOD and t >= last_t then return end
        last_t = t
        local out = build(t)
        out[#out + 1] = 'END'
        local f = io.open(PATH, 'w')
        if f then f:write(table.concat(out, '\n') .. '\n') f:close() end
    end

    local prev_after = LuaExportAfterNextFrame
    LuaExportAfterNextFrame = function()
        if prev_after then prev_after() end
        local ok, err = pcall(tick)
        if not ok and not PAVEPROBE_FEED_ERR then
            PAVEPROBE_FEED_ERR = true
            w('error: ' .. tostring(err))
        end
    end
end
