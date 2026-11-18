-- Jester Survivability logging.
local Config = require 'survivability.Config'

local engine_log = Log  -- global provided by Jester

local SLog = {}
local started = false

local function write_file(msg)
    if not Config.LOG_TO_FILE then return end
    pcall(function()
        local mode = 'a'
        if not started then
            started = true
            local r = io.open(Config.LOG_PATH, 'r')
            if r then
                local size = r:seek('end') or 0
                r:close()
                if size > (Config.LOG_MAX_BYTES or 200000) then mode = 'w' end
            end
        end
        local f = io.open(Config.LOG_PATH, mode)
        if f then
            f:write(msg .. '\n')
            f:close()
        end
    end)
end

function SLog.Info(msg)
    msg = '[SURV] ' .. tostring(msg)
    if Config.LOG_TO_CONSOLE and engine_log then pcall(engine_log, msg) end
    write_file(msg)
end

return SLog
