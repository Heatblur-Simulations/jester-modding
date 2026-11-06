---// BST Range - Jester enters Boresight at the selected range (F-4E Jester V2).
--
-- BEHAVIOUR: when you ask JESTER to enter Boresight (wheel: Radar > Boresight > Enter BST, or the
-- "Jester Command" Enter BST keybind), he enters it at 10nm instead of the stock 25nm.
-- Overrides the stock radar_enter_bst handler (same event + handler name replaces the stock one).
-- If you are already in boresight when you ask, he just sets the range.
--
-- NOT COVERED: switching to BST yourself with the cockpit radar-mode control does not involve Jester,
-- so the range stays where it was (confirmed in-sim on DCS 2.9.31). To get both speed and 10nm, bind
-- one key to the cockpit BST switch AND the Jester Enter BST command.
--
-- WHEEL: ONE item "BST Range: 10nm" under the stock "Crew Contract" menu (root item 6). Selecting it
-- cycles the entry range 10 -> 25 -> 50 -> 10 and relabels in place. It is pushed at load and again
-- on HB's native "is_wheel_ready" event, so it also appears when the wheel page loads late
-- (multiplayer spawns) or reloads.

local Class    = require('base.Class')
local Behavior = require('base.Behavior')

local BstRange = Class(Behavior)

-- BST entry range options, cycled from the wheel. Keys from Config.range.
local BST_RANGES = { "nm_10", "nm_25", "nm_50" }
local bst_index  = 1

local function bst_key()   return BST_RANGES[bst_index] end
local function bst_label() return (bst_key():gsub("nm_", "")) .. "nm" end

-- HB's native wheel-ready event (July 2026 module update, base/Interactions.lua): fires when the wheel
-- page is up. Wheel calls made before that are silently dropped (late-loading wheel on MP spawns).
local WHEEL_READY_EVENT = "is_wheel_ready"

-- Wheel location: our item nests under the stock "Crew Contract" menu (root item 6), not Systems. The
-- display name must match the stock menu EXACTLY or Wheel.AddItem makes a DUPLICATE at root - confirm
-- in-sim on first run and fix here in one place.
local MENU_LOC = { "Crew Contract" }

BstRange.is_registered = false

function BstRange:Constructor()
	Behavior.Constructor(self)
	self.current_item_name = nil   -- the wheel-item name we last added (for safe remove/replace)
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

-- The single BST Range item under Crew Contract; its name carries the live entry range.
local function item_name_for_state() return "BST Range: " .. bst_label() end

function BstRange:BuildWheelItem()
	return Wheel.Item:new({
		name     = item_name_for_state(),
		action   = "bstrange_cycle",
		reaction = Wheel.Reaction.NOTHING,
	})
end

-- Push (or re-push) our own item to Crew Contract. Touches only our named item, never the menu itself.
function BstRange:ReseedWheel()
	remove_item_protected(self.current_item_name, MENU_LOC)
	Wheel.AddItem(self:BuildWheelItem(), MENU_LOC)
	self.current_item_name = item_name_for_state()
end

-- In-place relabel when the entry range cycles (10 -> 25 -> 50). Falls back to a full re-push.
function BstRange:RelabelWheel()
	local new_item = self:BuildWheelItem()
	local new_name = item_name_for_state()
	local ok = false
	if self.current_item_name then
		if pcalls_disabled then
			Wheel.ReplaceItem(new_item, self.current_item_name, MENU_LOC)
			ok = true
		else
			ok = pcall(Wheel.ReplaceItem, new_item, self.current_item_name, MENU_LOC)
		end
	end
	if ok then
		self.current_item_name = new_name
	else
		self:ReseedWheel()
	end
end

function BstRange:Register()
	require('radar.UserActions') -- stock registers its handler first, so ours always replaces it
	local Config = require('radar.Config')
	local State  = require('radar.State')
	local Api    = require('radar.Api')

	-- Override the stock radar_enter_bst handler. Mirror of the stock logic, with our range, and
	-- setting the range even if we are already in boresight.
	ListenTo("radar_enter_bst", "RadarUserActions", function(task)
		State.SetEventTask(task)

		if Api.IsBoresightMode() then
			-- Already in boresight: just set our range.
			task:Roger()
			    :ClickFast("Radar Range", Config.range[bst_key()])
			return
		end

		if Api.IsRegularCageMode() then
			task:Roger()
			return
		end

		local can_operate_radar = State.is_active and Api.IsPowered()
		local is_regular_a2a_behavior = State.current_context_mode == Config.context_mode.A2A and not Api.IsInDogfightMode()
		if not can_operate_radar or not is_regular_a2a_behavior or Api.IsInTrackState() then
			task:CantDo()
			return
		end

		task:Roger()
		    :Click("Radar Mode", Config.mode.boresight)
		    :ClickFast("Radar Range", Config.range[bst_key()])
		    :ClickFast("Radar Target Aspect", "nose")
	end)

	-- Wheel item handler: cycle the BST entry range (10 -> 25 -> 50 -> 10).
	ListenTo("bstrange_cycle", "BstRange", function(task)
		bst_index = (bst_index % #BST_RANGES) + 1
		task:Roger()
	end)

	-- Re-push when the wheel page reports ready (covers late MP spawns and UI reloads). Silent: no Roger.
	ListenTo(WHEEL_READY_EVENT, "BstRange", function() self:ReseedWheel() end)

	self:ReseedWheel()

	Log("[BstRange] loaded - boresight entry range " .. bst_label() .. ", BST Range item under Crew Contract")
end

function BstRange:Tick()
	if not self.is_registered then
		self:Register()
		self.is_registered = true
		return
	end

	-- Keep the item label in sync when the entry range cycles (in place, position-preserving).
	if self.current_item_name ~= item_name_for_state() then
		self:RelabelWheel()
	end
end

BstRange:Seal()
return BstRange
