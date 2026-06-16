---// Copyright (c) 2023 Heatblur Simulations. All rights reserved.

require('base.Interactions')
local Task = require('base.Task')
local Urge = require('base.Urge')
local StressReaction = require('base.StressReaction')

local PaveSpike = {}
PaveSpike.is_equipped = nil
PaveSpike.is_active = nil
PaveSpike.current_operation_mode = nil

PaveSpike.video_source = {
    weapons = 0,
    pave_spike = 1,
}

PaveSpike.bit_mode = {
    light_test_0 = 0,
    operation_1 = 1,
    simulate_test_2 = 2,
    laser_test_3 = 3,
    range_test_4 = 4,
}

PaveSpike.screen_mode = {
    off = "off",
    standby = "standby",
    dscg_test = "dscg_test",
    radar_bit = "radar_bit",
    radar = "radar",
    tv = "tv",
}

PaveSpike.operation_mode = {
    ACQUISITION = "acquisition",
    TRACK = "track",
    MEMORY = "memory"
}

PaveSpike.slow_updates = Urge:new({
    time_to_release = s(1),
    on_release_function = function()
        PaveSpike.UpdateSlow()
    end,
    stress_reaction = StressReaction.ignorance,
})
PaveSpike.slow_updates:Restart()

function PaveSpike.IsEquipped()
    return GetProperty("/EO TGT Designator System", "Pod loaded").value or false
end

function PaveSpike.IsPowerOn()
    return GetProperty("/EO TGT Designator System/Target Designator Set Control", "Power On Light").value or false
end

function PaveSpike.GetCurrentBit()
    return GetProperty("/EO TGT Designator System/Target Designator Set Control", "Current BIT").value
end

function PaveSpike.IsStowed()
    return GetProperty("/EO TGT Designator System/Target Designator Set Control", "Stow Light").value or false
end

function PaveSpike.IsReady()
    return PaveSpike.IsEquipped()
            and PaveSpike.IsPowerOn()
            and PaveSpike.GetCurrentBit() == PaveSpike.bit_mode.operation_1
            and not PaveSpike.IsStowed()
end

function PaveSpike.GetOperationMode()
    local mode_index = GetProperty("/EO TGT Designator System/Pave Spike", "Operation Mode").value
    if mode_index == 0 then
        return PaveSpike.operation_mode.ACQUISITION
    elseif mode_index == 1 then
        return PaveSpike.operation_mode.TRACK
    else
        return PaveSpike.operation_mode.MEMORY
    end
end

function PaveSpike.SelectStow(task, should_stow)
    local power_status = PaveSpike.IsPowerOn()

    -- The light cant be trusted without power. But when turning on power,
    -- the pod always starts stowed, so we can assume no action needed without power
    local stow_status = not power_status or PaveSpike.IsStowed()

    if stow_status ~= should_stow then
        return task:ClickShort("TGP Stow", "ON")
    else
        return task
    end
end

function PaveSpike.SelectPower(task, should_power_on)
    local power_status = PaveSpike.IsPowerOn()

    if power_status ~= should_power_on then
        return task:ClickShort("TGP Power On", "ON")
    else
        return task
    end
end

function PaveSpike.SelectTvScreen(task)
    return task:ClickFast("Screen Mode", PaveSpike.screen_mode.tv, true)
end

function PaveSpike.SelectVideoSource(task, desired_source)
    local current_video_source = GetProperty("/WSO Cockpit/WSO Front Panel/Video Selector", "Video Mode").value

    if (current_video_source == PaveSpike.video_source.weapons and desired_source ~= PaveSpike.video_source.weapons)
            or (current_video_source == PaveSpike.video_source.pave_spike and desired_source ~= PaveSpike.video_source.pave_spike) then
        return task:ClickShortFast("Video Select", "ON")
    else
        return task
    end
end

function PaveSpike.SelectBitOne(task)
    local current_bit = PaveSpike.GetCurrentBit()

    local clicks = 0
    if current_bit == PaveSpike.bit_mode.light_test_0 then
        clicks = 1
    elseif current_bit == PaveSpike.bit_mode.operation_1 then
        clicks = 0
    elseif current_bit == PaveSpike.bit_mode.simulate_test_2 then
        clicks = 4
    elseif current_bit == PaveSpike.bit_mode.laser_test_3 then
        clicks = 3
    elseif current_bit == PaveSpike.bit_mode.range_test_4 then
        clicks = 2
    end

    for _ = 1, clicks
    do
        task:ClickShort("TGP BIT", "ON")
    end
    return task
end

function PaveSpike.SetOperatingMode(task, mode)
    local is_equipped = PaveSpike.IsEquipped()
    if not is_equipped then
        return task
    end

    PaveSpike.SelectPower(task, true)
             :ClickFast("TGP Laser Ready", "ON")
             :ClickFast("TGP WRCS Out", "OFF")
             :ClickFast("TGP INS Out", "OFF")
             :ClickFast("TGP Acquisition Mode", "VIS_12")
    PaveSpike.SelectBitOne(task)

    if mode == "ready" then
        PaveSpike.SelectVideoSource(task, PaveSpike.video_source.pave_spike)
        PaveSpike.SelectStow(task, false)
    elseif mode == "standby" then
        PaveSpike.SelectStow(task, true)
    end
    return task
end

function PaveSpike.UpdateSlow()
    local task = Task:new()

    local is_equipped = PaveSpike.IsEquipped()
    if PaveSpike.is_equipped == nil then
        -- On initial spawn, assume the defaults are good
        PaveSpike.is_equipped = is_equipped
    end
    if is_equipped and not PaveSpike.is_equipped then
        -- Equipped during mission
        PaveSpike.SetOperatingMode(task, "standby")
    end

    PaveSpike.is_equipped = is_equipped
    if not PaveSpike.is_equipped then
        GetJester():AddTask(task)
        return
    end
    PaveSpike.current_operation_mode = PaveSpike.GetOperationMode()

    GetJester():AddTask(task)
end

function PaveSpike.Tick(dt)
    -- NOTE Called by behavior OperatePaveSpike.lua
    if PaveSpike.slow_updates then
        PaveSpike.slow_updates:Tick()
    end
    if not PaveSpike.is_active then
        return
    end

    if PaveSpike.current_operation_mode == PaveSpike.operation_mode.TRACK then
        -- TODO Hold it on target, activate laser when LGB dropped, activate laser shortly when lock commanded
    end
    -- TODO Search nearby targets
end

function PaveSpike.PilotRequestsLockUnlockTargetAhead(task)
    if not PaveSpike.IsReady() then
        task:CantDo()
        Log("CantDo: Lock/Unlock Ground TGT - Pave Spike is not ready")
        return
    end

    local current_operation_mode = PaveSpike.GetOperationMode()
    if current_operation_mode == PaveSpike.operation_mode.ACQUISITION then
        GetJester():AddTask(Task:new():Say("Lantirn/captured"))
        return PaveSpike.LockAndLaseFor(task, s(2))
    else
        GetJester():AddTask(Task:new():Roger())
        return PaveSpike.Unlock(task)
    end
end

function PaveSpike.LockAndLaseFor(task, time)
    -- 2-stage click and release toggles laser
    -- so we execute it, wait, and then execute it again
    return task:ClickSequenceFast("Antenna Trigger",
            "RELEASED",
            "HALF_ACTION",
            "FULL_ACTION",
            "HALF_ACTION",
            "RELEASED")
               :Wait(time)
               :ClickSequenceFast("Antenna Trigger",
            "RELEASED",
            "HALF_ACTION",
            "FULL_ACTION",
            "HALF_ACTION",
            "RELEASED")
end

function PaveSpike.Unlock(task)
    -- 1-stage click and release toggles acquisition/track
    return task:ClickSequenceFast("Antenna Trigger",
            "RELEASED",
            "HALF_ACTION",
            "RELEASED")
end

ListenTo("pave_spike_lock_unlock_tgt_ahead", "PaveSpike", function(task)
    PaveSpike.PilotRequestsLockUnlockTargetAhead(task)
end)

return PaveSpike
