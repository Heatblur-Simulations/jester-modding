-- Jester A/G+ weapon release button feed (DCS Export environment). Read-only: changes nothing in the sim.
-- The F-4E pilot's bomb (weapon release) button is cockpit argument 2779 (Pilot_Stick_Bomb_Release in the F-4E draw_args.lua);
-- the WSO's grip button is 2786 and the pilot trigger 2776. This file reads them 20 times a second and writes:
--   Logs\bombbtn.txt   one line, rewritten on every change and at least twice a second:
--                      BTN t=<model time> pilot=<0/1> wso=<0/1> raw=<2779 value> aar=<0/1> (argument 2780, the ARR release button)
--                      The Jester side (Pave.lua) treats pilot=1 as "the release button is held" and a file older than 1.5 s as
--                      "not held".
--   Logs\bombbtn.log   a line for every press and release, plus, for finding the right argument if 2779 does not move, any
--                      cockpit argument between 2740 and 2820 that changes value (the first few hundred changes only).
-- Delete the line in Export.lua that loads this file to switch it off.
do
    if BOMBBTN_FEED_LOADED then return end
    BOMBBTN_FEED_LOADED = true

    local DIR = lfs.writedir() .. [[Logs\]]
    local OUT = DIR .. 'bombbtn.txt'
    local LOG = DIR .. 'bombbtn.log'
    local ARG_PILOT, ARG_WSO, ARG_TRIG, ARG_AAR = 2779, 2786, 2776, 2780   -- 2780 = Pilot_Stick_Air_Refueling (the ARR release button)
    local SCAN_LO, SCAN_HI = 2740, 2820
    local PERIOD, HEARTBEAT = 0.05, 0.5
    local START_DELAY = 5.0
    local MAX_SCAN_LINES = 400

    local function w(msg) pcall(function() log.write('BOMBBTN', log.INFO, msg) end) end
    w('loaded, writing ' .. OUT)

    local function append(text)
        local f = io.open(LOG, 'a')
        if f then f:write(text) f:close() end
    end

    local last_poll, last_write = -10, -10
    local last_p, last_w, last_a = -1, -1, -1
    local scan_prev = {}
    local scan_lines = 0
    local warned = false

    local function arg(dev, n)
        local ok, v = pcall(function() return dev:get_argument_value(n) end)
        if ok and type(v) == 'number' then return v end
        return nil
    end

    local function poll()
        local t = LoGetModelTime and LoGetModelTime() or 0
        if t < START_DELAY then return end
        if t - last_poll < PERIOD and t >= last_poll then return end
        last_poll = t
        local dev
        pcall(function() dev = GetDevice(0) end)
        if not dev then
            if not warned then warned = true; w('GetDevice(0) is not available, no button signal') end
            return
        end
        local rp = arg(dev, ARG_PILOT)
        local rw = arg(dev, ARG_WSO)
        local rt = arg(dev, ARG_TRIG)
        local ra = arg(dev, ARG_AAR)
        local av = (ra and ra > 0.5) and 1 or 0
        if not rp then return end
        local p = rp > 0.5 and 1 or 0
        local wv = (rw and rw > 0.5) and 1 or 0
        if av ~= last_a then
            append(string.format('%s t=%.2f aar_raw=%.3f\n', av == 1 and 'ARR PRESS' or 'ARR RELEASE', t, ra or -1))
            last_a = av
            last_write = -10
        end
        if p ~= last_p or wv ~= last_w then
            append(string.format('%s t=%.2f pilot=%d wso=%d raw=%.3f wso_raw=%.3f trig=%.3f\n',
                (p ~= last_p) and (p == 1 and 'PILOT PRESS' or 'PILOT RELEASE') or (wv == 1 and 'WSO PRESS' or 'WSO RELEASE'),
                t, p, wv, rp, rw or -1, rt or -1))
            last_p, last_w = p, wv
            last_write = -10
        end
        -- Scan nearby arguments for changes, so a wrong argument number can still be found from the log.
        if scan_lines < MAX_SCAN_LINES then
            for n = SCAN_LO, SCAN_HI do
                local v = arg(dev, n)
                if v then
                    local pv = scan_prev[n]
                    if pv ~= nil and math.abs(v - pv) > 0.01 then
                        append(string.format('ARG %d %.3f -> %.3f t=%.2f\n', n, pv, v, t))
                        scan_lines = scan_lines + 1
                    end
                    scan_prev[n] = v
                end
            end
        end
        if t - last_write >= HEARTBEAT or t < last_write then
            last_write = t
            local f = io.open(OUT, 'w')
            if f then
                f:write(string.format('BTN t=%.2f pilot=%d wso=%d raw=%.3f aar=%d\n', t, p, wv, rp, av))
                f:close()
            end
        end
    end

    local prev_after = LuaExportAfterNextFrame
    function LuaExportAfterNextFrame()
        if prev_after then pcall(prev_after) end
        pcall(poll)
    end
end
