---// Copyright (c) 2023 Heatblur Simulations. All rights reserved.

local Class = require('base.Class')
local Behavior = require('base.Behavior')
local Urge = require('base.Urge')
local StressReaction = require('base.StressReaction')
local Task = require('base.Task')
local RadarConfig = require('radar.Config')
local RadarState = require('radar.State')
local RadarApi = require('radar.Api')
local PaveSpike = require('other.PaveSpike')
require('base.Interactions')

local PrepareDscg = Class(Behavior)
PrepareDscg.click_type = {
	SHORT = "SHORT",
	LONG = "LONG",
	DOUBLE = "DOUBLE",
}
PrepareDscg.mode = {
	PAVE_SPIKE = 1,
	TV_WEAPON = 2,
	RADAR = 3,
}
PrepareDscg.context_mode = {
	PAVE_SPIKE_LOCK_UNLOCK_TGT_AHEAD = 1,
	RADAR_A2G_DIVE_TOSS = 2,
	RADAR_A2G_DIVE_LAYDOWN = 3,
	RADAR_A2A = 4,
}
PrepareDscg.current_mode = nil
PrepareDscg.current_context_mode = nil
PrepareDscg.task = nil

function PrepareDscg:Constructor()
	Behavior.Constructor(self)

	self.check_urge = Urge:new({
		time_to_release = s(1),
		on_release_function = function()
			self:Check()
		end,
		stress_reaction = StressReaction.ignorance,
	})
	self.check_urge:Restart()

	ListenTo("context_action_short", "PrepareDscg", function(task)
		self:PilotRequestsContextAction(task, PrepareDscg.click_type.SHORT)
	end)
	ListenTo("context_action_long", "PrepareDscg", function(task)
		self:PilotRequestsContextAction(task, PrepareDscg.click_type.LONG)
	end)
	ListenTo("context_action_double", "PrepareDscg", function(task)
		self:PilotRequestsContextAction(task, PrepareDscg.click_type.DOUBLE)
	end)
end

function PrepareDscg:GetMode()
	return self.current_mode
end

function PrepareDscg:ClearModes()
	self.current_mode = nil
	self.current_context_mode = nil
end

function PrepareDscg:Tick()
	if self.check_urge then
		self.check_urge:Tick()
	end

	RadarState.is_active = self.current_mode == self.mode.RADAR
	if self.current_context_mode == self.context_mode.RADAR_A2A then
		RadarState.current_context_mode = RadarConfig.context_mode.A2A
	elseif self.current_context_mode == self.context_mode.RADAR_A2G_DIVE_TOSS then
		RadarState.current_context_mode = RadarConfig.context_mode.A2G_DIVE_TOSS
	elseif self.current_context_mode == self.context_mode.RADAR_A2G_DIVE_LAYDOWN then
		RadarState.current_context_mode = RadarConfig.context_mode.A2G_DIVE_LAYDOWN
	end

	PaveSpike.is_active = self.current_mode == self.mode.PAVE_SPIKE
end

function PrepareDscg:ComputeModes()
	local is_cage_mode = GetProperty("/Radar/Fire Control System Low Frequency", "caged mode").value
	if is_cage_mode then
		return self.mode.RADAR, self.context_mode.RADAR_A2A
	end

	local delivery_mode = GetJester():GetCockpit():GetManipulator("Delivery Mode"):GetState()
	local weapon_selection = GetJester():GetCockpit():GetManipulator("Weapon Selection"):GetState()

	if delivery_mode == "TGT_FIND" then
		return self.mode.PAVE_SPIKE, self.context_mode.PAVE_SPIKE_LOCK_UNLOCK_TGT_AHEAD
	end
	if weapon_selection == "TV" then
		return self.mode.TV_WEAPON, nil
	end

	local radar_context
	if delivery_mode == "DT" then
		radar_context = self.context_mode.RADAR_A2G_DIVE_TOSS
	elseif delivery_mode == "DL" then
		radar_context = self.context_mode.RADAR_A2G_DIVE_LAYDOWN
	else
		radar_context = self.context_mode.RADAR_A2A
	end
	return self.mode.RADAR, radar_context
end

function PrepareDscg:PrepareCurrentSetting()
	local task = Task:new()

	if self.current_mode == self.mode.PAVE_SPIKE then
		PaveSpike.SetOperatingMode(task, "ready")
		PaveSpike.SelectTvScreen(task)
	elseif self.current_mode == self.mode.TV_WEAPON then
		PaveSpike.SelectVideoSource(task, PaveSpike.video_source.weapons)
		PaveSpike.SelectTvScreen(task)
	elseif self.current_mode == self.mode.RADAR then
		RadarApi.SetOperatingMode(task, "ready")

		if self.current_context_mode == self.context_mode.RADAR_A2G_DIVE_TOSS then
			RadarApi.PrepareDiveToss(task)
		elseif self.current_context_mode == self.context_mode.RADAR_A2G_DIVE_LAYDOWN then
			-- NOTE Works in the same way
			RadarApi.PrepareDiveToss(task)
		end
	else
		if self.task ~= nil then
			self.task:Cancel()
		end
		return
	end

	-- Ensure no overlapping tasks that could mess up each other
	task:AddOnActivationCallback(function()
		self.task = task
	end)
	task:AddOnFinishedCallback(function()
		self.task = nil
	end)

	if self.task ~= nil then
		self.task:Cancel()
	end

	GetJester():AddTask(task)
end

function PrepareDscg:Check()
	-- The WSO DSCG can either operate the Radar or Pave Spike.
	-- Also, when the pilot wants to operate TV weapons, the WSO cannot use the Pave Spike anymore.
	-- This behavior makes sure to switch between these and ready up the respective systems based on pilot selection with the weapon mode knobs.
	-- * Pave Spike: TGT FIND release mode
	-- * TV weapons: TV weapon mode
	-- * Radar: all other cases or CAGE mode
	-- Further, it prepares the systems for context actions, such as:
	-- * Pave Spike:
	--   * Lock/Unlock TGT ahead - always
	-- * Radar:
	--   * A2G Dive Toss lock - DT mode
	--   * A2G Dive Laydown lock - DL mode
	--   * A2A Lock TGT ahead - all other cases or CAGE mode
	local next_mode, next_context_mode = self:ComputeModes()
	if next_mode == self.current_mode and next_context_mode == self.current_context_mode then
		return
	end

	self.current_mode = next_mode
	self.current_context_mode = next_context_mode
	self:PrepareCurrentSetting()
end

function PrepareDscg:PilotRequestsContextAction(task, type)
	local action
	if self.current_mode == self.mode.PAVE_SPIKE and self.current_context_mode == self.context_mode.PAVE_SPIKE_LOCK_UNLOCK_TGT_AHEAD then
		action = function()
			Dispatch("pave_spike_lock_unlock_tgt_ahead")
		end
	elseif self.current_mode == self.mode.RADAR then
		if self.current_context_mode == self.context_mode.RADAR_A2A then
			action = function()
				if type == PrepareDscg.click_type.SHORT then
					Dispatch("radar_context_a2a_short")
				elseif type == PrepareDscg.click_type.LONG then
					Dispatch("radar_context_a2a_long")
				else
					Dispatch("radar_context_a2a_double")
				end
			end
		elseif self.current_context_mode == self.context_mode.RADAR_A2G_DIVE_TOSS then
			action = function()
				Dispatch("radar_context_a2g_dive_toss")
			end
		elseif self.current_context_mode == self.context_mode.RADAR_A2G_DIVE_LAYDOWN then
			action = function()
				Dispatch("radar_context_a2g_dive_laydown")
			end
		end
	end

	if action == nil then
		GetJester():AddTask(Task:new():CantDo())
		Log("CantDo: Execute ContextAction - Unknown Context")
		return
	end

	if self.task ~= nil then
		-- Still preparing the current selection
		self.task:AddOnFinishedCallback(action)
	else
		action()
	end
end

PrepareDscg:Seal()
return PrepareDscg
