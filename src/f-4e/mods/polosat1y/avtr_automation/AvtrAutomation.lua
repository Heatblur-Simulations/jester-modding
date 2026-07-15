-- Enabling the crew contract puts the AVTR in standby and Jester switches it to record
-- while in combat or while the scope shows the TV weapon or Pave Spike
-- video, returning to standby when both are over. Disabling the contract,
-- or setting the AVTR through the Systems menu, stops the management and
-- leaves the AVTR in its current state.

local Class = require('base.Class')
local Behavior = require('base.Behavior')
local Urge = require('base.Urge')
local StressReaction = require('base.StressReaction')
local Task = require('base.Task')
local PrepareDscg = require('behaviors.PrepareDscg')

local AvtrAutomation = Class(Behavior)

AvtrAutomation.is_registered = false
AvtrAutomation.enabled = false

AvtrAutomation.avtr_state = "OFF"

local avtr_mode = {
	off = "OFF",
	standby = "STANDBY",
	record = "RECORD",
}

local function UpdateWheelInfo(avtr_state, enabled)
	Wheel.SetMenuInfo("State: " .. avtr_state .. " | Managing: " .. (enabled and "ON" or "OFF"), { "Crew Contract", "AVTR Automation" })
end

-- Jester decides in PrepareDscg when the scope shows the TV weapon or Pave
-- Spike video, so his own mode already says whether an attack is set up
local function IsTvAttack()
	local dscg = GetJester().behaviors[PrepareDscg]
	local mode = dscg and dscg:GetMode()
	return mode == PrepareDscg.mode.TV_WEAPON or mode == PrepareDscg.mode.PAVE_SPIKE
end

function AvtrAutomation:Constructor()
	Behavior.Constructor(self)

	local behavior = self
	self.check_urge = Urge:new({
		time_to_release = s(5),
		on_release_function = function() behavior:CheckAvtr() end,
		stress_reaction = StressReaction.ignorance,
	})
	self.check_urge:Restart()
end

function AvtrAutomation:SetAvtr(state)
	self.avtr_state = state
	GetJester():AddTask(Task:new():Click("AVTR Mode", state))
	UpdateWheelInfo(state, self.enabled)
end

function AvtrAutomation:CheckAvtr()
	if not self.enabled then return end

	local in_danger = GetJester().awareness:GetInCombatOrDanger() or false
	local tv_attack = not in_danger and IsTvAttack()
	local should_record = in_danger or tv_attack

	if should_record and self.avtr_state == "STANDBY" then
		self:SetAvtr("RECORD")
		Log("AvtrAutomation: " .. (tv_attack and "TV attack set up" or "combat detected") .. ", AVTR to record")
	elseif not should_record and self.avtr_state == "RECORD" then
		self:SetAvtr("STANDBY")
		Log("AvtrAutomation: threat cleared and no TV attack, AVTR to standby")
	end
end

function AvtrAutomation:Register()
	local behavior = self

	ListenTo("avtr_automation_enable", "AvtrAutomation", function(task)
		behavior.enabled = true
		behavior.avtr_state = "STANDBY"
		UpdateWheelInfo("STANDBY", true)
		task:Roger():Click("AVTR Mode", "STANDBY")
	end)

	ListenTo("avtr_automation_disable", "AvtrAutomation", function(task)
		behavior.enabled = false
		UpdateWheelInfo(behavior.avtr_state, false)
		task:Roger()
	end)

	-- Setting the AVTR through the Systems menu disables the management,
	-- the pilot's choice wins
	ListenTo("systems_avtr_recorder", "AvtrAutomation", function(_, mode)
		behavior.avtr_state = avtr_mode[mode] or behavior.avtr_state
		if behavior.enabled then
			behavior.enabled = false
			Log("AvtrAutomation: AVTR set manually, auto-management disabled")
		end
		UpdateWheelInfo(behavior.avtr_state, false)
	end)

	Wheel.AddItem(Wheel.Item:new({
		name = "AVTR Automation",
		menu = Wheel.Menu:new({
			name = "AVTR Automation",
			items = {
				Wheel.Item:new({ name = "Enable", action = "avtr_automation_enable", reaction = Wheel.Reaction.CLOSE }),
				Wheel.Item:new({ name = "Disable", action = "avtr_automation_disable", reaction = Wheel.Reaction.CLOSE }),
			},
		}),
	}), { "Crew Contract" })
	UpdateWheelInfo(self.avtr_state, self.enabled)
end

function AvtrAutomation:Tick()
	if not self.is_registered then
		self:Register()
		self.is_registered = true
	end

	if self.check_urge then
		self.check_urge:Tick()
	end
end

AvtrAutomation:Seal()
return AvtrAutomation
