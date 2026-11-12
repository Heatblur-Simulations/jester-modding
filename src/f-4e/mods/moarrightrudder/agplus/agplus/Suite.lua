-- Jester A/G+ entry point. Called from the launcher during Jester's init.
local Config = require 'agplus.Config'
local AGLog = require 'agplus.Log'

local Suite = {}

local function try(what, fn)
    local ok, err = pcall(fn)
    if not ok then AGLog.Info('%s failed to load: %s', what, tostring(err)) end
    return ok
end

function Suite.Install(jester)
    AGLog.Reset()
    AGLog.Info('---- jester a/g+ starting ----')

    local Menu = require 'agplus.Menu'
    local Mode, Lgb, Wrcs

    -- Wheel order inside the A/G Plus item: Strike List, Maverick, Pave Spike, WRCS Integration, Weapon (see Menu.lua).
    -- Mode holds the shared weapon state and the center text; Lgb and Wrcs only read it.
    -- The drag coefficient and the release range are set by a long context press.
    if try('Mode', function()
        Mode = require 'agplus.Mode'
        Menu.Provide('Weapon', Mode.BuildWeaponItem)
    end) then
        try('Mode behavior', function() jester.behaviors[Mode.Behavior] = Mode.Behavior:new() end)
    end
    if try('Drag coefficient', function() Lgb = require 'agplus.Lgb' end) then
        try('Drag coefficient behavior', function() jester.behaviors[Lgb.Behavior] = Lgb.Behavior:new() end)
    end
    if try('WRCS', function() Wrcs = require 'agplus.Wrcs' Menu.Provide('WRCS Integration', Wrcs.BuildItem) end) then
        try('WRCS behavior', function() jester.behaviors[Wrcs.Behavior] = Wrcs.Behavior:new() end)
    end

    -- INS update from TACAN. Sits after WRCS Integration.
    local Update
    if try('INS update', function() Update = require('agplus.Update')
        -- Oct 20 2026: INS Update lives under Navigation. Config.INS_UPDATE_IN_NAVIGATION = false puts it back under A/G Plus.
        if Config.INS_UPDATE_IN_NAVIGATION == false then
            Menu.Provide('INS Update', Update.BuildItem)
        else
            Menu.ProvideAt({ 'Navigation' }, 'INS Update', Update.BuildItem)
        end
    end) then
        try('INS update behavior', function() jester.behaviors[Update.Behavior] = Update.Behavior:new() end)
    end

    -- Pave Spike look-there (TODO item 4, Phase 1): long context press in TGT FIND points the pod where the pilot looks.
    local Pave
    if try('Pave Spike look-there', function() Pave = require('agplus.Pave') end) then
        try('Pave Spike look-there behavior', function() jester.behaviors[Pave.Behavior] = Pave.Behavior:new() end)
    end

    -- Pave Spike area search (Phase 2): long press with the pod in track; target list under A/G Plus > Pave Spike Targets.
    local Search
    if try('Pave Spike search', function() Search = require('agplus.PaveSearch') end) then
        try('Pave Spike search behavior', function() jester.behaviors[Search.Behavior] = Search.Behavior:new() end)
    end

    -- Jester Mavericks, Phase 1-2: unified target list and the Strike List (A/G Plus > Strike List). Loaded after the search so the
    -- pod's list is its first source; the pod steps to the next Strike List target after a pass.
    local Targets
    if try('Strike List', function() Targets = require('agplus.Targets') Menu.Provide('Strike List', Targets.BuildItem) end) then
        try('Strike List behavior', function() jester.behaviors[Targets.Behavior] = Targets.Behavior:new() end)
    end

    -- Jester Mavericks scaffolding (Oct 21 2026): settings menu, loadout/variant detection and a dry-run context press. Does not touch the seeker.
    local Mav
    if try('Maverick', function() Mav = require('agplus.Maverick') Menu.Provide('Maverick', Mav.BuildItem) end) then
        try('Maverick behavior', function() jester.behaviors[Mav.Behavior] = Mav.Behavior:new() end)
    end

    -- The menu behavior registers the single A/G Plus item on every (re)spawn.
    try('menu', function() jester.behaviors[Menu.Behavior] = Menu.Behavior:new() end)

    try('speed call fix', function() require('agplus.SpeedFix').Install() end)
end

return Suite
