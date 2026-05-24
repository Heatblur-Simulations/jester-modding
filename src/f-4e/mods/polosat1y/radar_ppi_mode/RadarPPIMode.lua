-- RadarPPIMode.lua
-- Adds a "PPI Scan" submenu to the Jester Wheel under "Radar -> PPI Scan".

local Class    = require('base.Class')
local Behavior = require('base.Behavior')

local RadarPPIMode = Class(Behavior)

local GAIN_PPI = 0.68  -- lower gain for PPI ground mapping, best between 0.6 to 0.7

-- Module-level state
RadarPPIMode.is_registered = false
RadarPPIMode.is_ppi_active = false

-- Set in Register(); read in Tick() (require() is cached, but storing avoids
-- the call overhead and makes the dependency explicit).
local RadarState = nil

function RadarPPIMode:Constructor()
    Behavior.Constructor(self)
end

function RadarPPIMode:Register()
    local State  = require('radar.State')
    local Config = require('radar.Config')
    local Phases = require('radar.Phases')
    local Api    = require('radar.Api')
    RadarState   = State

    -- Patch Api.ClickIffButton so the routine check_iff urge is suppressed during PPI
    local original_click_iff = Api.ClickIffButton
    Api.ClickIffButton = function(task)
        if self.is_ppi_active then
            Log("[PPI] Suppressed IFF button press")
            return task
        end
        return original_click_iff(task)
    end

    -- Patch Phases.IdentifyTargets so Jester stops detecting/announcing contacts
    local original_identify_targets = Phases.IdentifyTargets
    Phases.IdentifyTargets = function()
        if self.is_ppi_active then
            Log("[PPI] Suppressed IdentifyTargets")
            return nil
        end
        return original_identify_targets()
    end

    -- Patch Phases.AdjustGain so the RadarAdjustGain() call is skipped
    local original_adjust_gain = Phases.AdjustGain
    Phases.AdjustGain = function()
        if self.is_ppi_active then
            Log("[PPI] Suppressed AdjustGain (keeping GAIN_PPI=" .. tostring(GAIN_PPI) .. ")")
            if State.pilot_requested_scan_zone == State.current_scan_zone then
                State.pilot_requested_scan_zone = nil
            end
            return nil
        end
        Log("[PPI] AdjustGain running (PPI inactive)")
        return original_adjust_gain()
    end

    local function enter_ppi(task, scan_type, range_text)
        Log("[PPI] Entering PPI: " .. scan_type .. " " .. range_text)
        State.SetEventTask(task)
        self.is_ppi_active = true

        -- Clear any A2A target focus so Jester stops tracking air targets.
        State.target_to_focus_on                  = nil
        State.target_to_highlight                 = nil
        State.target_to_lock                      = nil
        State.pilot_requested_target_to_highlight = nil
        State.is_auto_focus_allowed = false
        -- Depress the scan zone to ground level. Scale range with display
        -- range so the antenna points at the correct angle.
        local scan_zone_ranges = { nm_50 = NM(30), nm_25 = NM(15), nm_10 = NM(5) }
        State.pilot_requested_scan_zone = {
            name        = "CUSTOM",
            range       = scan_zone_ranges[range_text],
            altitude    = ft(0),
            is_relative = false,
        }

        task:Roger()
            :ClickFast("Radar Scan Type",   scan_type)
            :ClickFast("Radar Range",        Config.range[range_text])
            :ClickFast("Radar Gain Coarse",  GAIN_PPI)

        State.pilot_requested_scan_type = scan_type
        State.pilot_requested_range     = Config.range[range_text]
    end

    local function exit_ppi()
        Log("[PPI] Exiting PPI")
        self.is_ppi_active = false
        State.is_auto_focus_allowed = true
        State.pilot_requested_scan_zone = nil
    end

    ListenTo("radar_ppi_wide", "RadarPPIMode", function(task, range_text)
        enter_ppi(task, "PPI_WIDE", range_text)
    end)

    ListenTo("radar_ppi_nar", "RadarPPIMode", function(task, range_text)
        enter_ppi(task, "PPI_NAR", range_text)
    end)

    -- Exit PPI when the pilot picks a standard B_WIDE/B_NAR range via Wheel.
    ListenTo("radar_display_range", "RadarPPIModeExit", function()
        if not self.is_ppi_active then return end
        exit_ppi()
    end)

    -- Exit PPI when the pilot double-clicks the Jester context action button.
    ListenTo("radar_context_a2a_double", "RadarPPIModeContextExit", function()
        if not self.is_ppi_active then return end
        exit_ppi()
        State.pilot_requested_scan_type = Config.scan_type.wide
        State.pilot_requested_range = Config.range.nm_50
    end)

    Wheel.AddItem(Wheel.Item:new({
        name = "PPI Scan",
        menu = Wheel.Menu:new({
            name  = "PPI Scan",
            items = {
                Wheel.Item:new({ name = "50nm Wide",   action = "radar_ppi_wide", action_value = "nm_50", reaction = Wheel.Reaction.CLOSE_REMEMBER }),
                Wheel.Item:new({ name = "50nm Narrow", action = "radar_ppi_nar",  action_value = "nm_50", reaction = Wheel.Reaction.CLOSE_REMEMBER }),
                Wheel.Item:new({ name = "25nm Wide",   action = "radar_ppi_wide", action_value = "nm_25", reaction = Wheel.Reaction.CLOSE_REMEMBER }),
                Wheel.Item:new({ name = "25nm Narrow", action = "radar_ppi_nar",  action_value = "nm_25", reaction = Wheel.Reaction.CLOSE_REMEMBER }),
                Wheel.Item:new({ name = "10nm Wide",   action = "radar_ppi_wide", action_value = "nm_10", reaction = Wheel.Reaction.CLOSE_REMEMBER }),
                Wheel.Item:new({ name = "10nm Narrow", action = "radar_ppi_nar",  action_value = "nm_10", reaction = Wheel.Reaction.CLOSE_REMEMBER }),
            },
        }),
    }), { "Radar" })
end

function RadarPPIMode:Tick()
    if not self.is_registered then
        self:Register()
        self.is_registered = true
    end

    -- Prevent the A2A zone-rotation timeout from triggering while in PPI. Prevent Jester from
    -- saying "Going to regular scan" and trying to set default scan elevation etc.
    if self.is_ppi_active then
        RadarState.time_spent_scanning_zone_no_bandits = s(0)
    end
end

RadarPPIMode:Seal()
return RadarPPIMode
