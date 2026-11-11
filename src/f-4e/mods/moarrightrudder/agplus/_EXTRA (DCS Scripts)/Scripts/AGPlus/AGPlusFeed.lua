-- Jester A/G+ payload feed (DCS Export environment).
-- Once a second: reads the aircraft's stores (LoGetPayloadInfo) and writes one line per station to
-- Logs\agplus_payload.txt, only when something changed. Jester's own Lua cannot reach DCS's payload data, so
-- the A/G+ suite reads this file. Pure read-only: it changes nothing in the sim.
-- Remove this file name from Scripts\AGPlus\AGPlusLoad.lua to disable it.
do
    if AGPLUS_FEED_LOADED then return end
    AGPLUS_FEED_LOADED = true

    local PATH = lfs.writedir() .. [[Logs\agplus_payload.txt]]
    local PERIOD = 1.0        -- seconds between reads
    local START_DELAY = 8.0   -- do not touch the Export API in the first seconds after spawn

    local function w(msg) pcall(function() log.write('AGPLUSFEED', log.INFO, msg) end) end
    w('loaded, writing ' .. PATH)

    local last_t, last_text = -1, nil

    local function clean(v) return (tostring(v == nil and '?' or v):gsub('%s', '_')) end

    local function build()
        local info = LoGetPayloadInfo and LoGetPayloadInfo()
        if type(info) ~= 'table' then return 'V1 nopayload=1' end
        local out = { string.format('V1 cur=%s', clean(info.CurrentStation)) }
        for i, st in pairs(info.Stations or {}) do
            if type(st) == 'table' then
                local wp = st.weapon or {}
                out[#out + 1] = string.format('S %s clsid=%s count=%s type=%s/%s/%s/%s', clean(i), clean(st.CLSID), clean(st.count),
                    clean(wp.level1), clean(wp.level2), clean(wp.level3), clean(wp.level4))
            end
        end
        table.sort(out, function(a, b) return a < b end)
        return table.concat(out, '\n')
    end

    local function tick()
        local t = LoGetModelTime and LoGetModelTime() or 0
        if t < START_DELAY then return end
        if t - last_t < PERIOD and t >= last_t then return end
        last_t = t
        local text = build()
        if text == last_text then return end
        last_text = text
        local f = io.open(PATH, 'w')
        if f then f:write(text .. '\nEND\n') f:close() end
    end

    local prev_after = LuaExportAfterNextFrame
    LuaExportAfterNextFrame = function()
        if prev_after then prev_after() end
        local ok, err = pcall(tick)
        if not ok and not AGPLUS_FEED_ERR then
            AGPLUS_FEED_ERR = true
            w('error: ' .. tostring(err))
        end
    end
end
