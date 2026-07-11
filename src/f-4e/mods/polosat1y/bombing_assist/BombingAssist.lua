-- Bombing Assist helps the Pilot fly a manual DIRECT-mode dive attack. The pilot
-- sets WSO's QNH and a briefed release altitude from the Jester wheel, then calls
-- "Rolling In!" to arm the pass. On the way down Jester calls the passing
-- altitudes and presses the WSO bomb release at the briefed altitude, holding
-- it long enough to walk off the whole ripple. He aborts with a callout if the
-- dive is abandoned or the bombing setup changes mid-pass.

local Class = require('base.Class')
local Behavior = require('base.Behavior')
local Task = require('base.Task')
local Utilities = require('base.Utilities')
-- conditions.IsBombing defines the global IsBombingCondition(). Non-base
-- modules are required in Register(), they are not safe at mod file scope.

local BombingAssist = Class(Behavior)

BombingAssist.is_registered = false
BombingAssist.target_alt = nil       -- ft, nil until the pilot sets it
BombingAssist.armed = false
BombingAssist.last_alt = nil
BombingAssist.time_since_arm = 0
BombingAssist.next_callout = nil
BombingAssist.climb_time = 0
BombingAssist.button_release_in = nil
BombingAssist.menu_state = "none"    -- none, arm or cancel

local arm_margin = 1000     -- ft, must be this far above target altitude to arm
local lead_time = 0.1       -- s, release lead for frame latency
local hold_min = 0.3        -- s, minimum bomb button hold
local hold_salvo = 5       -- s, hold for a salvo (bomb count not known)
local hold_buffer = 0.5     -- s, extra hold beyond quantity times interval
local hold_fallback = 5     -- s, worst-case hold when the settings can not be read
local callout_delay = 2     -- s, pause after roger before the altitude callouts
local callout_cutoff = 1000 -- ft, no callouts closer than this to the drop
local arm_timeout = 180     -- s, auto-cancel if no release this long after arming
local climb_cancel = 15     -- s, auto-cancel after climbing this long while armed

local altimeter_output = '/WSO Servoed Altimeter/Altitude Meter/Output Calculator'

local qnh_item_name = "Set QNH"
local alt_item_name = "Set Altitude"
local arm_item_name = "Rolling In!"
local cancel_item_name = "Cancel"

-- Bomb Quantity knob positions: 1, 2, 3, 4, 5, 6, 9, 12, 18, C, S, P
local quantity_words = {
	ONE = 1, TWO = 2, THREE = 3, FOUR = 4, FIVE = 5, SIX = 6,
	NINE = 9, TWELVE = 12, EIGHTEEN = 18,
}

local function GetDeltaSeconds()
	local dt = Utilities.GetTime().dt
	return dt and dt:ConvertTo(s).value or 0
end

-- The altimeter is read every tick while armed, so a failure logs only once
-- until a read succeeds again.
local altimeter_fail_logged = false

local function ReadAltimeterNeedle()
	local prop = GetProperty(altimeter_output, 'Altitude Needle')
	if not prop or not prop:IsValid() or not prop.value then
		if not altimeter_fail_logged then
			altimeter_fail_logged = true
			Log("Bombing Assist: altitude needle unreadable at " .. altimeter_output)
		end
		return nil
	end
	altimeter_fail_logged = false
	return prop.value:ConvertTo(ft).value
end

local function ReadReferencePressure()
	local prop = GetProperty(altimeter_output, 'Reference Pressure')
	if not prop or not prop:IsValid() or not prop.value then
		return nil
	end
	return tonumber(tostring(prop.value):match("([%d%.]+)"))
end

-- Numeric reading of a weapons-panel control. The manipulator state is tried
-- first (ON/OFF or numeric text), then the raw component property.
local function ReadNumeric(manipulator_name, component_path, property_name)
	local state = tostring(GetJester():GetCockpit():GetManipulator(manipulator_name):GetState())
	if state == "ON" then return 1 end
	if state == "OFF" then return 0 end
	local num = tonumber(state:match("([%d%.]+)"))
	if num ~= nil then return num end

	local prop = GetProperty(component_path, property_name)
	if prop and prop:IsValid() and prop.value then
		return tonumber(tostring(prop.value):match("([%d%.]+)"))
	end
	return nil
end

-- Returns a bomb count, "salvo_duration" (salvo, hold the longest) or nil
-- (unreadable).
local function ReadQuantity()
	local state = tostring(GetJester():GetCockpit():GetManipulator("Bomb Quantity"):GetState())
	if quantity_words[state] then return quantity_words[state] end
	local num = tonumber(state:match("^(%d+)$"))
	if num then return num end
	-- P (pairs) is a single release pulse
	if state == "P" then return 1 end
	-- S (salvo) has no fixed count, hold for the longest case. C (continuous)
	-- never reaches here, arming is refused while the quantity is continuous.
	if state == "S" then return "salvo_duration" end
	return nil
end

-- Continuous release has no defined end, so the assist can not support it.
local function IsQuantityContinuous()
	local state = tostring(GetJester():GetCockpit():GetManipulator("Bomb Quantity"):GetState())
	return state == "C"
end

-- Return true only if MasterArm is on, ordinance is Bomb/Rockets and delivery mode is Direct
local function ManualBombingReady()
	if not IsBombingCondition() then return false end
	local delivery = GetJester():GetCockpit():GetManipulator("Delivery Mode"):GetState() or "OFF"
	return delivery == "DIRECT"
end

-- One fixed item per setting, its submenu is rebuilt in place after each
-- selection (reaction NOTHING keeps the wheel open), the final step confirms.
local function ReplaceChainItem(item_name, location, menu_name, items)
	Wheel.ReplaceItem(
		Wheel.Item:new({
			name = item_name,
			outer_menu = Wheel.Menu:new({ name = menu_name, items = items }),
		}),
		item_name, location)
end

local function BuildChainItems(action, start, stop, step, label_fn, value_fn, reaction)
	local items = {}
	for n = start, stop, step do
		items[#items + 1] = Wheel.Item:new({
			name = label_fn(n),
			action = action,
			action_value = value_fn(n),
			reaction = reaction or Wheel.Reaction.NOTHING,
		})
	end
	return items
end

local function ResetQnhItem()
	local items = BuildChainItems("bombing_assist_qnh_d1", 2, 3, 1,
		function(n) return tostring(n) .. "_.__" end,
		tostring)
	ReplaceChainItem(qnh_item_name, { "Systems" }, "QNH [__.__]", items)
end

local function ResetAltItem()
	local items = BuildChainItems("bombing_assist_alt_d1", 0, 1, 1,
		function(n) return tostring(n) .. "____" end,
		tostring)
	ReplaceChainItem(alt_item_name, { "Air To Ground", "Bombing Assist" }, "Altitude [_____]", items)
end

function BombingAssist:Constructor()
	Behavior.Constructor(self)
end

function BombingAssist:Disarm(reason)
	if self.armed then
		Log("Bombing Assist: disarmed, " .. reason)
	end
	self.armed = false
	self.last_alt = nil
	self.next_callout = nil
	self.climb_time = 0
end

function BombingAssist:CancelAssist(reason)
	GetJester():AddTask(Task:new():Say('phrases/aborting'))
	self:Disarm(reason)
end

-- A ripple drops quantity times interval worth of bombs while the button is
-- held. The panel is read and salvo_duration assummed if any failure.
function BombingAssist:ComputeHoldTime()
	local qty = ReadQuantity()
	local interval = ReadNumeric("Bomb Interval", "/Weapons/Weapons Control Panel Knobs/Bomb Interval Knob", 'Position')
	local x10 = ReadNumeric("Bomb Interval x10", "/Weapons/Weapons Control Panel Buttons/Bomb Interval Switch", 'State')

	if not qty or not interval then
		Log(string.format("Bombing Assist: release settings unreadable, worst-case hold %ds", hold_fallback))
		return hold_fallback
	end

	if qty == "salvo_duration" then
		return hold_salvo
	end

	-- x10 switch up multiplies the interval knob value by ten (0.1s to 1s)
	if x10 ~= nil and x10 > 0.5 then interval = interval * 10 end
	if qty < 1 then qty = 1 end

	-- Hold for the whole ripple, however long. A short one still needs a
	-- minimum press so the button registers.
	local hold = qty * interval + hold_buffer
	if hold < hold_min then hold = hold_min end
	return hold
end

function BombingAssist:ReleaseBombs(alt)
	GetJester():GetCockpit():GetManipulator("WSO Bomb Release"):SetState("ON")
	self.button_release_in = self:ComputeHoldTime()

	GetJester():AddTask(Task:new():Say('Lantirn/pickle'))
	Log(string.format("Bombing Assist: release at %.0f ft, target %d ft, hold %.1fs",
		alt, self.target_alt, self.button_release_in))
end

-- Releases the bomb button once the hold time elapses. Bypasses the task
-- queue so the release can not be interrupted and left held down.
function BombingAssist:TickButtonRelease()
	if not self.button_release_in then return end

	self.button_release_in = self.button_release_in - GetDeltaSeconds()
	if self.button_release_in > 0 then return end

	self.button_release_in = nil
	GetJester():GetCockpit():GetManipulator("WSO Bomb Release"):SetState("OFF")
end

function BombingAssist:TickCallouts(alt)
	if not self.next_callout or self.time_since_arm < callout_delay then return end

	while self.next_callout and alt <= self.next_callout do
		if self.next_callout >= self.target_alt + callout_cutoff then
			GetJester():AddTask(Task:new():Say('angels/' .. tostring(self.next_callout) .. 'ft'))
		end
		self.next_callout = self.next_callout - 1000
		if self.next_callout < self.target_alt then
			self.next_callout = nil
		end
	end
end

function BombingAssist:Monitor()
	if not self.armed then return end

	if not ManualBombingReady() then
		self:CancelAssist("bombing conditions broken")
		return
	end

	local alt = ReadAltimeterNeedle()
	if not alt then return end

	local dt = GetDeltaSeconds()
	self.time_since_arm = self.time_since_arm + dt

	local descent_rate = 0
	if self.last_alt and dt > 0 then
		descent_rate = (self.last_alt - alt) / dt -- ft/s, positive when descending
	end

	-- Auto-cancel when there is no release within the timeout after arming
	if self.time_since_arm >= arm_timeout then
		self:CancelAssist("arm timeout")
		return
	end

	-- Auto-cancel when a sustained climb means the dive was abandoned
	if descent_rate < 0 then
		self.climb_time = self.climb_time + dt
		if self.climb_time >= climb_cancel then
			self:CancelAssist("sustained climb")
			return
		end
	else
		self.climb_time = 0
	end

	self:TickCallouts(alt)

	-- Only release while descending through the altitude, the dive direction
	if descent_rate > 0 and alt <= self.target_alt + descent_rate * lead_time then
		self:ReleaseBombs(alt)
		self:Disarm("release complete")
		return
	end

	self.last_alt = alt
end

function BombingAssist:UpdateMenuInfo()
	local alt_text = self.target_alt and (tostring(self.target_alt) .. " ft") or "not set"
	local qnh = ReadReferencePressure()
	local qnh_text = qnh and string.format("%.2f", qnh) or "?"
	Wheel.SetMenuInfo(string.format("QNH %s | Release: %s", qnh_text, alt_text), { "Air To Ground", "Bombing Assist" })
end

-- Rolling In! shows only when everything is ready to arm, Cancel only while
function BombingAssist:UpdateAssistMenu()
	local desired
	if self.armed then
		desired = "cancel"
	elseif self.target_alt and ManualBombingReady() and not IsQuantityContinuous() then
		desired = "arm"
	else
		desired = "none"
	end

	if desired == self.menu_state then return end

	if self.menu_state == "arm" then
		Wheel.RemoveItem(arm_item_name, { "Air To Ground", "Bombing Assist" })
	elseif self.menu_state == "cancel" then
		Wheel.RemoveItem(cancel_item_name, { "Air To Ground", "Bombing Assist" })
	end

	if desired == "arm" then
		Wheel.AddItem(Wheel.Item:new({
			name = arm_item_name,
			action = "bombing_assist_arm",
			reaction = Wheel.Reaction.CLOSE_REMEMBER,
		}), { "Air To Ground", "Bombing Assist" })
	elseif desired == "cancel" then
		Wheel.AddItem(Wheel.Item:new({
			name = cancel_item_name,
			action = "bombing_assist_cancel",
			reaction = Wheel.Reaction.CLOSE,
		}), { "Air To Ground", "Bombing Assist" })
	end

	self.menu_state = desired
end

function BombingAssist:RegisterManipulators()
	local cockpit = GetJester():GetCockpit()
	cockpit:AddManipulator("WSO Bomb Release", { component_path = "/Weapons/WSO Stick Buttons/WSO Bomb Release Button" })
	cockpit:AddManipulator("WSO Altimeter Pressure", { component_path = "/WSO Servoed Altimeter/Reference Pressure Knob" })
	cockpit:AddManipulator("Bomb Quantity", { component_path = "/Weapons/Weapons Control Panel Knobs/Bomb Quantity Knob" })
	cockpit:AddManipulator("Bomb Interval", { component_path = "/Weapons/Weapons Control Panel Knobs/Bomb Interval Knob" })
	cockpit:AddManipulator("Bomb Interval x10", { component_path = "/Weapons/Weapons Control Panel Buttons/Bomb Interval Switch" })
end

function BombingAssist:Register()
	local behavior = self

	require('conditions.IsBombing') -- defines the global IsBombingCondition()
	self:RegisterManipulators()

	-- QNH chain: first digit, second digit, tenths, hundredths. The valid
	-- setting range is 28.10 to 31.00 inHg.

	ListenTo("bombing_assist_qnh_d1", "BombingAssist", function(task, value)
		local d2_start, d2_stop
		if value == "2" then
			d2_start, d2_stop = 8, 9
		elseif value == "3" then
			d2_start, d2_stop = 0, 1
		else
			task:CantDo(); return
		end

		local items = BuildChainItems("bombing_assist_qnh_int", d2_start, d2_stop, 1,
			function(d2) return value .. tostring(d2) .. ".__" end,
			function(d2) return value .. tostring(d2) end)
		ReplaceChainItem(qnh_item_name, { "Systems" }, "QNH [" .. value .. "_.__]", items)
	end)

	ListenTo("bombing_assist_qnh_int", "BombingAssist", function(_, value)
		-- Tenths are bounded by the 28.10 to 31.00 valid range
		local t_start, t_stop = 0, 9
		if value == "28" then t_start = 1 end
		if value == "31" then t_stop = 0 end
		local items = BuildChainItems("bombing_assist_qnh_tenth", t_start, t_stop, 1,
			function(n) return value .. "." .. tostring(n) .. "_" end,
			function(n) return value .. ";" .. tostring(n) end)
		ReplaceChainItem(qnh_item_name, { "Systems" }, "QNH [" .. value .. ".__]", items)
	end)

	ListenTo("bombing_assist_qnh_tenth", "BombingAssist", function(task, value)
		local int_s, tenth_s = string.match(value, "(%d+);(%d)")
		if not int_s then task:CantDo(); return end

		-- Hundredths are bounded by the 31.00 upper limit
		local h_stop = (int_s == "31") and 0 or 9
		local items = BuildChainItems("bombing_assist_qnh_confirm", 0, h_stop, 1,
			function(h) return string.format("%s.%s%d", int_s, tenth_s, h) end,
			function(h) return string.format("%s.%s%d", int_s, tenth_s, h) end,
			Wheel.Reaction.CLOSE_REMEMBER)
		ReplaceChainItem(qnh_item_name, { "Systems" },
			"QNH [" .. int_s .. "." .. tenth_s .. "_]", items)
	end)

	ListenTo("bombing_assist_qnh_confirm", "BombingAssist", function(task, value)
		local qnh = tonumber(value)
		-- The Kollsman scale runs 28.10 to 31.00 inHg
		if not qnh or qnh < 28.10 or qnh > 31.00 then task:CantDo(); return end

		-- Same "<value> <unit>" string the Bombing Calculator uses for the
		-- WRCS knobs, here "30.12 inHg".
		task:Roger()
		task:Click("WSO Altimeter Pressure", string.format("%.2f inHg", qnh))

		ResetQnhItem()
		behavior:UpdateMenuInfo()
	end)

	-- Altitude chain: ten-thousands, thousands, hundreds. 1, 14, 14500 gives
	-- 0 to 19,900 ft in 100 ft steps.

	ListenTo("bombing_assist_alt_d1", "BombingAssist", function(task, value)
		if not tonumber(value) then task:CantDo(); return end
		local items = BuildChainItems("bombing_assist_alt_thousands", 0, 9, 1,
			function(d) return value .. tostring(d) .. "___" end,
			function(d) return value .. ";" .. tostring(d) end)
		ReplaceChainItem(alt_item_name, { "Air To Ground", "Bombing Assist" }, "Altitude [" .. value .. "____]", items)
	end)

	ListenTo("bombing_assist_alt_thousands", "BombingAssist", function(task, value)
		local d1, d2 = string.match(value, "(%d);(%d)")
		if not d1 then task:CantDo(); return end

		local base = tonumber(d1) * 10000 + tonumber(d2) * 1000
		local items = BuildChainItems("bombing_assist_alt_confirm", 0, 9, 1,
			function(h) return tostring(base + h * 100) end,
			function(h) return tostring(base + h * 100) end,
			Wheel.Reaction.CLOSE_REMEMBER)
		ReplaceChainItem(alt_item_name, { "Air To Ground", "Bombing Assist" }, "Altitude [" .. d1 .. d2 .. "___]", items)
	end)

	ListenTo("bombing_assist_alt_confirm", "BombingAssist", function(task, value)
		local alt = tonumber(value)
		if not alt or alt < 100 then task:CantDo(); return end

		behavior.target_alt = alt
		task:Roger()

		ResetAltItem()
		behavior:UpdateMenuInfo()
		Wheel.NavigateTo({ "Air To Ground", "Bombing Assist" })
	end)

	ListenTo("bombing_assist_arm", "BombingAssist", function(task)
		if behavior.armed or not behavior.target_alt then
			task:CantDo(); return
		end
		if not ManualBombingReady() or IsQuantityContinuous() then
			task:CantDo(); return
		end

		local alt = ReadAltimeterNeedle()
		if not alt then
			Log("Bombing Assist: arm refused, altimeter unreadable")
			task:CantDo(); return
		end

		-- Refuse to arm from below, a dive starts above the release altitude
		if alt < behavior.target_alt + arm_margin then
			Log(string.format("Bombing Assist: arm refused, alt %.0f ft below target %d + %d ft margin",
				alt, behavior.target_alt, arm_margin))
			task:CantDo(); return
		end

		behavior.armed = true
		behavior.last_alt = alt
		behavior.time_since_arm = 0
		behavior.climb_time = 0
		-- First callout is the next 1000 ft mark below the current altitude
		behavior.next_callout = math.floor((alt - 1) / 1000) * 1000
		if behavior.next_callout < behavior.target_alt then
			behavior.next_callout = nil
		end

		Log(string.format("Bombing Assist: rolling in at %.0f ft, release at %d ft", alt, behavior.target_alt))
		task:Roger()
	end)

	ListenTo("bombing_assist_cancel", "BombingAssist", function(task)
		behavior:Disarm("cancelled by pilot")
		task:Roger()
	end)

	-- QNH entry lives under Systems
	Wheel.AddItem(Wheel.Item:new({ name = qnh_item_name }), { "Systems" })

	-- The assist itself lives under Air To Ground
	Wheel.AddItem(Wheel.Item:new({
		name = "Bombing Assist",
		menu = Wheel.Menu:new({
			name = "Bombing Assist",
			items = { Wheel.Item:new({ name = alt_item_name }) },
		}),
	}), { "Air To Ground" })

	ResetQnhItem()
	ResetAltItem()
	self:UpdateMenuInfo()
end

function BombingAssist:Tick()
	if not self.is_registered then
		self:Register()
		self.is_registered = true
	end

	self:UpdateAssistMenu()
	self:Monitor()
	self:TickButtonRelease()
end

BombingAssist:Seal()
return BombingAssist
