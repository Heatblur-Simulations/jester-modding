-- Tagged logging for Jester A/G+.
local Config = require 'agplus.Config'

local engine_log = Log  -- global provided by Jester; keep our own reference

local AGLog = {}

local function write_file(msg)
    if not Config.LOG_TO_FILE then return end
    pcall(function()
        local f = io.open(Config.LOG_PATH, 'a')
        if f then
            f:write(msg .. '\n')
            f:close()
        end
    end)
end

function AGLog.Info(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    msg = '[AG+] ' .. msg
    if Config.LOG_TO_CONSOLE and engine_log then pcall(engine_log, msg) end
    write_file(msg)
end

-- Noisy per-tick diagnostics: written only when Config.PAVE_LOG_DETAIL == true (default off).
function AGLog.Detail(fmt, ...)
    if Config.PAVE_LOG_DETAIL ~= true then return end
    AGLog.Info(fmt, ...)
end

-- Append across missions; start over only when the file grows past LOG_MAX_BYTES.
function AGLog.Reset()
    if not Config.LOG_TO_FILE then return end
    pcall(function()
        local size = 0
        local r = io.open(Config.LOG_PATH, 'r')
        if r then size = r:seek('end') or 0 r:close() end
        local f = io.open(Config.LOG_PATH, size > (Config.LOG_MAX_BYTES or 200000) and 'w' or 'a')
        if f then f:write('---- session start ----\n') f:close() end
    end)
end

return AGLog
