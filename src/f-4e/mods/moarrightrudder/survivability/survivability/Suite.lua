-- Jester Survivability entry point. Called from the launcher during Jester's init.
local Config = require 'survivability.Config'
local SLog = require 'survivability.Log'

local Suite = {}

function Suite.Install(jester)
    SLog.Info('---- jester survivability starting ----')
    if Config.ALE40_SETUP then
        local ok, err = pcall(function() require('survivability.ALE40').Install(jester) end)
        if not ok then SLog.Info('ALE-40 setup failed to install: ' .. tostring(err)) end
    end
    if Config.COUNTERMEASURES then
        local ok, err = pcall(function() require('survivability.Countermeasures').Install() end)
        if not ok then SLog.Info('countermeasures failed to install: ' .. tostring(err)) end
    end
end

return Suite
