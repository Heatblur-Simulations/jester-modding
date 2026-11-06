---// PvP Scan - steep, short-range antenna elevation presets for the F-4E Jester (V2).
--
-- Adds a "PvP Scan" menu at the ROOT of the Jester Wheel (next to Radar, Navigation, etc.),
-- so it is one press away (press 7 by default) for a faster VoiceAttack macro.
-- Each preset asks Jester for a scan zone at a SHORT assumed range. Because the
-- antenna angle is atan(altitude / range) (see radar/MoveRadarAntenna.lua), a shorter
-- assumed range produces a STEEPER angle for the same altitude. That is exactly what
-- you want to catch high or low, close targets in PvP fights, and steeper than either the
-- stock keybinds (built-in ~30 nm) or the stock wheel.
--
-- WHEEL: the menu is pushed at load and again on HB's native "is_wheel_ready" event, so it also
-- appears when the wheel page loads late (multiplayer spawns) or reloads.
--
-- DO NO HARM: this mod only issues a normal pilot scan-zone request (the same mechanism
-- as the stock wheel, via UserActions.ScanZone). It does NOT patch gain, clutter
-- discrimination, auto-focus, IdentifyTargets, or target tracking. Jester's strength at
-- picking a moving bandit out of clutter is untouched.

local Class    = require('base.Class')
local Behavior = require('base.Behavior')

local PvpScan = Class(Behavior)

-- Assumed slant range used to compute the antenna angle.
-- Shorter = steeper for a given altitude. Tune to your typical engagement range.
-- Examples at +25,000 ft look-up: NM(10) ~= 22 deg, NM(5) ~= 39 deg, NM(15) ~= 15 deg.
local SCAN_RANGE = NM(10)

-- HB's native wheel-ready event (July 2026 module update, base/Interactions.lua): fires when the wheel
-- page is up. Wheel calls made before that are silently dropped (late-loading wheel on MP spawns).
local WHEEL_READY_EVENT = "is_wheel_ready"

PvpScan.is_registered = false

function PvpScan:Constructor()
	Behavior.Constructor(self)
end

-- Remove our item without letting a missing item abort the mod. Mirrors the engine's own
-- pcall handling (see base/Interactions.lua pcalls_disabled).
local function remove_item_protected(item_name, menu_location)
	if pcalls_disabled then
		Wheel.RemoveItem(item_name, menu_location)
	else
		pcall(Wheel.RemoveItem, item_name, menu_location)
	end
end

-- Build a fresh copy of our root menu item.
function PvpScan:BuildWheelItem()
	-- Range label shown after each option so the current search range is visible by the options.
	local rng = string.format(" (%gnm)", SCAN_RANGE:ConvertTo(NM).value)

	-- 8 items, each selectable by the existing "Jester UI Option 1..8" binds.
	return Wheel.Item:new({
		name = "PvP Scan",
		menu = Wheel.Menu:new({
			name  = "PvP Scan",
			items = {
				Wheel.Item:new({ name = "0-10k" .. rng,      action = "pvp_scan_abs", action_value = "5000",   reaction = Wheel.Reaction.CLOSE_REMEMBER }),
				Wheel.Item:new({ name = "10-20k" .. rng,     action = "pvp_scan_abs", action_value = "15000",  reaction = Wheel.Reaction.CLOSE_REMEMBER }),
				Wheel.Item:new({ name = "20-30k" .. rng,     action = "pvp_scan_abs", action_value = "25000",  reaction = Wheel.Reaction.CLOSE_REMEMBER }),
				Wheel.Item:new({ name = "30-40k" .. rng,     action = "pvp_scan_abs", action_value = "35000",  reaction = Wheel.Reaction.CLOSE_REMEMBER }),
				Wheel.Item:new({ name = "40-50k" .. rng,     action = "pvp_scan_abs", action_value = "45000",  reaction = Wheel.Reaction.CLOSE_REMEMBER }),
				Wheel.Item:new({ name = "50-60k" .. rng,     action = "pvp_scan_abs", action_value = "55000",  reaction = Wheel.Reaction.CLOSE_REMEMBER }),
				Wheel.Item:new({ name = "+25k Above" .. rng, action = "pvp_scan_rel", action_value = "25000",  reaction = Wheel.Reaction.CLOSE_REMEMBER }),
				Wheel.Item:new({ name = "-25k Below" .. rng, action = "pvp_scan_rel", action_value = "-25000", reaction = Wheel.Reaction.CLOSE_REMEMBER }),
			},
		}),
	})
end

-- Push (or re-push) our menu to the wheel: remove any existing copy, add a fresh one,
-- re-assert the caption. Safe to call repeatedly.
function PvpScan:ReseedWheel()
	remove_item_protected("PvP Scan", {})
	Wheel.AddItem(self:BuildWheelItem(), {})  -- {} = root (main) menu, next to Radar / Navigation
	Wheel.SetMenuInfo(self.info_caption, { "PvP Scan" })
end

function PvpScan:Register()
	local State       = require('radar.State')
	local UserActions = require('radar.UserActions')

	-- absolute = aim at a specific MSL altitude band; relative = look N ft above own jet.
	-- altitude_ft is passed as the wheel item's action_value (in actual feet).
	ListenTo("pvp_scan_abs", "PvpScan", function(task, altitude_ft)
		State.SetEventTask(task)
		UserActions.ScanZone(task, SCAN_RANGE, ft(tonumber(altitude_ft)), false)
	end)

	ListenTo("pvp_scan_rel", "PvpScan", function(task, altitude_ft)
		State.SetEventTask(task)
		UserActions.ScanZone(task, SCAN_RANGE, ft(tonumber(altitude_ft)), true)
	end)

	-- Re-push when the wheel page reports ready (covers late MP spawns and UI reloads). Silent: no Roger.
	ListenTo(WHEEL_READY_EVENT, "PvpScan", function() self:ReseedWheel() end)

	-- Centre caption, the supported equivalent of the stock menu's "(N NM, Altitude MSL)" line.
	-- The per-option blue range labels in the stock menu come from the module's built-in category
	-- captions, which the Lua mod API does not expose (Wheel.Category is a fixed enum).
	self.info_caption = string.format("(%g NM, Altitude MSL)", SCAN_RANGE:ConvertTo(NM).value)

	self:ReseedWheel()
end

function PvpScan:Tick()
	if not self.is_registered then
		self:Register()
		self.is_registered = true
		return
	end

	-- Re-assert the caption so it survives Jester's periodic wheel rebuilds.
	Wheel.SetMenuInfo(self.info_caption, { "PvP Scan" })

end

PvpScan:Seal()
return PvpScan
