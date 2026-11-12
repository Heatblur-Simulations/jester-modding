-- ALE-40 setup wheel item (moved into Jester Survivability). Called from Suite.Install(jester).
require('base.Interactions')
local Class = require('base.Class')
local Behavior = require('base.Behavior')

local ALE40Behavior = Class(Behavior)

function ALE40Behavior:Constructor()
    Behavior.Constructor(self)
    self.current_cockpit = nil
    self.menu_settle_ticks = 0
end

local ale40_item = Wheel.Item:new({
    name = "Setup ALE-40", 
    action = "force_ale40_setup",
    reaction = Wheel.Reaction.CLOSE -- Closes the Jester wheel when clicked
})

local function register_ale40_wheel_menu()
    pcall(function()
        Wheel.RemoveItem("Setup ALE-40", {"Systems"})
    end)
    pcall(function()
        Wheel.AddItem(ale40_item, {"Systems"})
    end)
    Log("Jester ALE-40: Wheel menu registered")
end

-- Listen custom action triggered by the Wheel menu
local function ale40_handler(task)
    
    -- 1. Flip switches 
    
    -- Default CM settings dispense 6 chaff bundles every 0.4 seconds giving 2.4 seconds total. Pilot is responsible for flares, Jester is responsible for chaff.
    -- Pilot can retake control of the chaff by setting the Dispense Program switch to Normal (Note: Flares will only be available when the Dispense Program switch is set to Flares)

    -- (Cockpit Value / Script Value)

    ClickRaw(5, 3014, 0.8) -- Chaff Burst Count: (1 / 0), (2 / 0.2), (3 / 0.4), (4 / 0.6), (6 / 0.8), (8 / 1) - Default 0.8
    ClickRaw(5, 3015, 1)   -- Chaff Burst Interval: (0.1 / 0), (0.2 / 0.33333333333333), (0.3 / 0.66666666666667), (0.4 / 1) - Default 1

    ClickRaw(5, 3016, 0)   -- Chaff Salvo Count: (1 / 0), (2 / 0.25), (4 / 0.5), (8 / 0.75), (C / 1) - Default 0
    ClickRaw(5, 3017, 0)   -- Chaff Salvo Interval: (1 / 0), (2 / 0.16666666666667), (3 / 0.33333333333333), (4 / 0.5), (5 / 0.66666666666667), (8 / 0.83333333333333), (R / 1) - Default 0

    ClickRaw(5, 3018, 0)   -- Flare Burst Count: (1 / 0), (2 / 0.25), (4 / 0.5), (8 / 0.75), (C / 1) - Default 0
    ClickRaw(5, 3019, 0)   -- Flare Burst Interval: (3 / 0), (4 / 0.25), (6 / 0.5), (8 / 0.75), (10 / 1) - Default 0

    ClickRaw(5, 3001, 1)   -- Dispense Program: Flares
    ClickRaw(5, 3021, 0)   -- WSO Seat Flare Mode: OFF
    
    -- 2. Tell Jester he's responsible for dispensing countermeasures
    local jester = GetJester()
    if jester and jester.memory then
        jester.memory:SetJesterCountermeasuresDispensingAllowed(true)
    end
    
    -- 3. Have Jester verbally acknowledge the command
    task:Roger()
end

function ALE40Behavior:Tick()
    local cockpit = nil
    pcall(function()
        local jester = GetJester()
        if jester then
            cockpit = jester:GetCockpit()
        end
    end)

    if not cockpit then
        self.current_cockpit = nil
        self.menu_settle_ticks = 0
        return
    end

    -- Detect initial spawn or respawn into a new cockpit
    if self.current_cockpit ~= cockpit then
        self.current_cockpit = cockpit
        self.menu_settle_ticks = 25
        register_ale40_wheel_menu()
    end

    if self.menu_settle_ticks > 0 then
        self.menu_settle_ticks = self.menu_settle_ticks - 1
        if self.menu_settle_ticks == 0 then
            register_ale40_wheel_menu()
        end
    end
end

local ALE40 = {}

local listening = false

function ALE40.Install(jester)
    if not listening then
        listening = true
        ListenTo("force_ale40_setup", "ALE40_Setup_Handler", ale40_handler)
    end
    jester.behaviors[ALE40Behavior] = ALE40Behavior:new()
end

return ALE40
