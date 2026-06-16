---// Copyright (c) 2023 Heatblur Simulations. All rights reserved.

local Class = require 'base.Class'
local Situation = require 'base.Situation'
local ExtPowerConnected = require 'conditions.ExternalGroundPower'
local LeftGenSwitchExt = require 'conditions.GeneratorSwitches.LeftGeneratorSwitchExt'
local RightGenSwitchExt = require 'conditions.GeneratorSwitches.RightGeneratorSwitchExt'
local Airborne = require 'conditions.Airborne'
local Task = require 'base.Task'
local StartINSTask = require('tasks.start.StartINS')

local GroundPowerConnected = Class(Situation)

GroundPowerConnected:AddActivationConditions(RightGenSwitchExt():And(LeftGenSwitchExt():And(ExtPowerConnected())))

GroundPowerConnected:AddDeactivationConditions(Airborne.True:new())

function GroundPowerConnected:OnActivation()
	local task = Task:new()
			:Wait( s(1.0), { hands = true })
			:Click("WSO Ground Power Switch", "ON")
			:Click("Nav Panel Function", "STBY")
			:Wait( s(1.0), { hands = true })
			:Click("INS Mode Knob", "STBY")
			:Wait( s(2.0), { hands = true })
			:NextTask(StartINSTask:new())

	GetJester():AddTask(task)

end

function GroundPowerConnected:OnDeactivation()
	local task = Task:new():Click("WSO Ground Power Switch", "OFF")
	GetJester():AddTask(task)
end

GroundPowerConnected:Seal()
return GroundPowerConnected
