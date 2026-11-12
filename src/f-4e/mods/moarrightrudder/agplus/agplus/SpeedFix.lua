-- Bombing speed call fix (part of A/G+).
-- Stock AssistBombing speaks the approach speed with the SaySpeed task, which can fall into a rapid
-- repeat loop. This replaces AssistBombing:CalloutSpeed with the same call made through Task:Say,
-- using the same phrases ("awareness/<speed>", "wereslow" below 100 kt, "werefast" above 600 kt).
local Task = require('base.Task')
local Utilities = require('base.Utilities')
local Math = require('base.Math')
local AGLog = require('agplus.Log')

local SpeedFix = {}

local arbcs = '/Weapons/ARBCS System/ARBCS'

local function pull_up_light() return GetProperty(arbcs, 'Pull-Up Light').value or false end
local function labs_tone() return GetProperty(arbcs, 'Pull-Up Tone Playing').value or false end

-- Same conditions as stock.
local function is_approaching()
    local mode = GetJester():GetCockpit():GetManipulator('Delivery Mode'):GetState() or 'OFF'
    if mode == 'LOFT' or mode == 'OS' or mode == 'TLAD' or mode == 'TL' then return pull_up_light() end
    if mode == 'TGT_FIND' or mode == 'L' or mode == 'OFFSET' then return labs_tone() end
    return false
end

local function callout_speed(self)
    if not is_approaching() then return end
    local speed = GetJester().awareness:GetObservation('TAS') or kt(400)
    local tens = Math.RoundTo(speed:ConvertTo(kt), kt(10)).value
    local prev = self.bsf_previous_tens
    if prev and prev == tens then return end   -- do not repeat the previous call
    self.bsf_previous_tens = tens

    local phrase
    if tens < 100 then phrase = 'awareness/wereslow'
    elseif tens > 600 then phrase = 'awareness/werefast'
    else phrase = 'awareness/' .. Utilities.NumberToText(tens) end

    local task = Task:new()
    task:Say(phrase)
    GetJester():AddTask(task)
end

function SpeedFix.Install()
    local AssistBombing = require('behaviors.AssistBombing')
    AssistBombing.CalloutSpeed = function(self)
        local ok, err = pcall(callout_speed, self)
        if not ok then AGLog.Info('speed call error: %s', tostring(err)) end
    end
    AGLog.Info('AssistBombing:CalloutSpeed replaced')
end

return SpeedFix
