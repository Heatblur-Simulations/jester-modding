---// Copyright (c) 2023 Heatblur Simulations. All rights reserved.

local Class = require('base.class')
local Task = require('base.Task')
local SayTask = require('tasks.common.SayTask')
local Interactions = require('base.Interactions')

local StartINS = Class(Task)

local AlignFull = function(task)
	ClickRaw(Interactions.devices.INS_AN_ASN_63, Interactions.device_commands.INS_WSO_ALIGN_MODE_COVER, 0) -- Needs to disable the hdg mem switch in case it would be on
	GetJester():AddTask(SayTask:new('phrases/StartingFullAlignment'))
	GetJester().memory:SetFullAlignment(true)
	GetJester().memory:SetAlignmentTypeChosen(true)
end

local AlignFullSilent = function(task)
	ClickRaw(Interactions.devices.INS_AN_ASN_63, Interactions.device_commands.INS_WSO_ALIGN_MODE_COVER, 0) -- Needs to disable the hdg mem switch in case it would be on
	GetJester().memory:SetFullAlignment(true)
	GetJester().memory:SetAlignmentTypeChosen(true)
end

local AlignBath = function(task)
	ClickRaw(Interactions.devices.INS_AN_ASN_63, Interactions.device_commands.INS_WSO_ALIGN_MODE_COVER, 0) -- Needs to disable the hdg mem switch in case it would be on
	GetJester():AddTask(SayTask:new('phrases/BathAlignment'))
	GetJester().memory:SetBathAlignment(true)
	GetJester().memory:SetAlignmentTypeChosen(true)
end

local AlignStored = function(task)
	GetJester():AddTask(SayTask:new('phrases/StoredHeading'))
	GetJester().memory:SetHdgMemAlignment(true)
	GetJester().memory:SetAlignmentTypeChosen(true)
end

function StartINS:Constructor()
	Task.Constructor(self)

	local on_activation = function()
		self:RemoveAllActions()

		local ins_stored = spawn_data.ins_alignment_stored;

		if ins_stored then
			GetJester().memory:SetStartAlignmentOption(false)
			local question = Dialog.Question:new({
				name = "Jester",
				content = "What alignment do you want?",
				phrase = "phrases/WhatAlignmentDoYouWant",
				label = "Alignment Type",
				timing = Dialog.Timing:new({
					question = s(10),
					action = s(20),
				}),
				expire_action = "align_expired",
				options = {
					Dialog.Option:new({
						response = "Full alignment",
						action = "full_alignment",
					}),
					Dialog.Option:new({
						response = "BATH alignment",
						action = "bath_alignment",
					}),
					Dialog.Option:new({
						response = "HDG Memory Alignment",
						action = "stored_alignment",
					}),
				},
			})
			Dialog.Push(question)
		elseif not ins_stored then
			local question = Dialog.Question:new({
				name = "Jester",
				content = "What alignment do you want?",
				phrase = "phrases/WhatAlignmentDoYouWant",
				label = "Alignment Type",
				timing = Dialog.Timing:new({
					question = s(10),
					action = s(20),
				}),
				expire_action = "align_expired",
				options = {
					Dialog.Option:new({
						response = "Full alignment",
						action = "full_alignment",
					}),
					Dialog.Option:new({
						response = "BATH alignment",
						action = "bath_alignment",
					}),
				},
			})
			Dialog.Push(question)
		end

		local expired_option
		if ins_stored then
			expired_option = AlignStored
		else
			expired_option = AlignFull
		end

		ListenTo("full_alignment", "StartINS", AlignFull)
		ListenTo("bath_alignment", "StartINS", AlignBath)
		ListenTo("stored_alignment", "StartINS", AlignStored)
		ListenTo("align_expired", "StartINS", expired_option)
	end

	self:AddOnActivationCallback(on_activation)

end

StartINS:Seal()
return StartINS
