---// Copyright (c) 2023 Heatblur Simulations. All rights reserved.

local Config = require('radar.Config')
local State = require('radar.State')
local Api = require('radar.Api')
local MoveRadarCursor = require('radar.MoveRadarCursor')
local MoveRadarAntenna = require('radar.MoveRadarAntenna')
local BraCalls = require('other.BraCalls')

local UserActions = {}

function UserActions.LockDiveToss(task)
	task:SetPriority(1)
	if Api.IsInTrackState() then
		task:Roger()
		return Api.UnlockTarget(task)
	end

	local ground_return_range = GetRadarMlcRange()
	if not ground_return_range then
		Log("CantDo: Lock DiveToss - No ground return range")
		return task:CantDo()
	end

	local move_radar_cursor = GetJester().behaviors[MoveRadarCursor]
	move_radar_cursor:MoveCursorTo(deg(0), ground_return_range)

	task:WaitUntil(function()
		return move_radar_cursor:IsCursorOverDesired()
	end, s(5))
	return Api.LockTargetUnderCursor(task)
	          :Require({ voice = true, hands = true })
	          :Say("Lantirn/captured")
end

function UserActions.LockDiveLaydown(task)
	-- Works in the same way than DT
	return UserActions.LockDiveToss(task)
end

function UserActions.ScanZone(task, range, altitude, is_relative)
	is_relative = is_relative or false

	if not State.is_active or not Api.IsPowered() then
		Log("CantDo: Scan Radar zone - Radar is not active/powered")
		task:CantDo()
		return
	end

	-- Abort whatever is going on and reset to scan that zone
	State.Reset()
	Log("SCAN " .. tostring(zone))

	if range and altitude then
		task:Roger()
		State.pilot_requested_scan_zone = {
			name = "CUSTOM",
			range = range,
			altitude = altitude,
			is_relative = is_relative,
		}
	else
		task:Say("radar/returningtoscan")
	end
end

function UserActions.HighlightNextTarget(task)
	task:SetPriority(1)
	if not State.is_active or not Api.IsPowered() then
		Log("CantDo: Highlight next Target - Radar is not active/powered")
		task:CantDo()
		return
	end

	local target = Api.GetNextBanditOrNil(State.target_to_highlight)
	if not target then
		Log("CantDo: Highlight next target - There is no other target")
		task:CantDo()
		return
	end

	task:Roger()
	Log("HIGHLIGHT " .. Api.TargetToString(target))
	State.target_to_highlight = target
	State.pilot_requested_target_to_highlight = target

	if target.scan_range:ConvertTo(NM) < Config.FOCUS_BANDIT_CLOSER_THAN then
		State.target_to_focus_on = target
	else
		State.target_to_focus_on = nil
	end

	GetJester().behaviors[MoveRadarCursor]:FollowTarget(target)
	GetJester().behaviors[MoveRadarAntenna]:FollowTarget(target)
end

function UserActions.FocusTarget(task, target_id)
	task:SetPriority(1)
	target_id = tonumber(target_id)
	local target = radar_targets[target_id] or State.all_targets[target_id]

	if not State.is_active or not Api.IsPowered() or not target then
		Log("CantDo: Focus Target - Radar is not active/powered or target unknown")
		task:CantDo()
		return
	end
	Log("FOCUS " .. Api.TargetToString(target))

	-- Abort whatever is going on and reset to scan that zone
	State.Reset()

	task:Say("radar/contextfocus")
	State.target_to_highlight = target
	State.pilot_requested_target_to_highlight = target
	State.target_to_focus_on = target
	GetJester().behaviors[MoveRadarCursor]:FollowTarget(target)
	GetJester().behaviors[MoveRadarAntenna]:FollowTarget(target)
end

function UserActions.LockTarget(task, target_id)
	task:SetPriority(1)
	target_id = tonumber(target_id)
	local target = radar_targets[target_id] or State.all_targets[target_id]

	if not State.is_active or not Api.IsPowered() or not target then
		Log("CantDo: Lock Target - Radar is not active/powered or target is unknown")
		task:CantDo()
		return
	end
	Log("LOCK " .. Api.TargetToString(target))

	-- Abort whatever is going on and reset to start a lock
	State.Reset()

	if target.scan_range:ConvertTo(NM) < Config.SHORT_LOCKED_CALLS_IF_CLOSER_THAN then
		task:Roger()
	else
		-- "I am locking, left 25, 17 miles"
		local phrase = "radar/contextlocking"
		if target.identification == RadarTargetIdentification.FRIENDLY then
			phrase = phrase .. "friend"
		elseif target.identification == RadarTargetIdentification.HOSTILE then
			phrase = phrase .. "bandit"
		else
			phrase = phrase .. "bogey"
		end

		task:Say(phrase,
				BraCalls.RadarBearingPhrase(target.scan_azimuth),
				BraCalls.RangePhrase(target.scan_range)
		)
	end

	State.target_to_highlight = target
	State.pilot_requested_target_to_highlight = target
	State.target_to_focus_on = target
	State.target_to_lock = target
	GetJester().behaviors[MoveRadarCursor]:FollowTarget(target)
	GetJester().behaviors[MoveRadarAntenna]:FollowTarget(target)
end

function UserActions.LockUnlockBoresightOrDogfight(task)
	task:SetPriority(1)
	if Api.IsInTrackState() then
		task:Say("radar/contextbreaklock")
		return Api.UnlockTarget(task)
	end

	if not Api.IsBoresightMode() and not Api.IsRegularCageMode() then
		-- Cant lock in CAA mode
		Log("CantDo: Lock/Unlock Dogfight - Cant lock in CAA, only in BST")
		return task:CantDo()
	end

	State.time_left_trying_to_lock_cage_target = Config.MAX_TRYING_TO_LOCK_CAGE_TARGET_TIME
	return task:Roger()
end

function UserActions.DisengageCage(task)
	task:SetPriority(1)
	if not Api.IsInDogfightMode() then
		Log("CantDo: Disengage CAGE - Not in CAGE mode")
		task:CantDo()
		return
	end

	task:Say("radar/returningtoscan")
	    :ClickShort("A2A Button", "ON")
end

function UserActions.LeaveBoresight(task)
	task:SetPriority(1)
	if not Api.IsBoresightMode() then
		Log("CantDo: Leave Boresight - Not in BST mode")
		task:CantDo()
		return
	end

	task:Say("radar/returningtoscan")
	    :ClickFast("Radar Mode", Config.mode.map)
end

function UserActions.NextAspect(task)
	task:SetPriority(1)
	if not Api.IsBoresightMode() and not Api.IsRegularCageMode() then
		Log("CantDo: Next Aspect - Not in BST mode")
		task:CantDo()
		return
	end

	local current_aspect = GetJester():GetCockpit():GetManipulator("Radar Target Aspect"):GetState() or "wide"
	local aspect_to_next = {
		wide = "nose",
		nose = "fwd",
		fwd = "aft",
		aft = "tail",
		tail = "wide",
	}
	local next_aspect = aspect_to_next[current_aspect]

	local phrase = "radar/aspect"
	if next_aspect == "nose" then
		phrase = phrase .. "nose"
	elseif next_aspect == "fwd" then
		phrase = phrase .. "forward"
	elseif next_aspect == "aft" then
		phrase = phrase .. "aft"
	elseif next_aspect == "tail" then
		phrase = phrase .. "tail"
	else
		phrase = phrase .. "wide"
	end

	task:Say(phrase)
	    :ClickFast("Radar Target Aspect", next_aspect)
end

function UserActions.HandleContextActionDogfight(task, action_type)
	if action_type == Config.context_action_type.SHORT then
		Log("Context dogfight: Next Aspect")
		UserActions.NextAspect(task)
	elseif action_type == Config.context_action_type.LONG then
		Log("Context dogfight: lock/unlock")
		UserActions.LockUnlockBoresightOrDogfight(task)
	elseif action_type == Config.context_action_type.DOUBLE then
		Log("Context dogfight: disengage cage")
		UserActions.DisengageCage(task)
	end
end

function UserActions.HandleContextActionBoresight(task, action_type)
	if action_type == Config.context_action_type.SHORT then
		Log("Context boresight: Next Aspect")
		UserActions.NextAspect(task)
	elseif action_type == Config.context_action_type.LONG then
		Log("Context boresight: lock/unlock")
		UserActions.LockUnlockBoresightOrDogfight(task)
	elseif action_type == Config.context_action_type.DOUBLE then
		Log("Context boresight: leave boresight")
		UserActions.LeaveBoresight(task)
	end
end

function UserActions.HandleContextActionLock(task, action_type)
	if action_type == Config.context_action_type.SHORT then
		Log("Context lock: Unlock but keep focus")
		local target = State.target_to_lock or State.target_currently_locked
		UserActions.FocusTarget(task, target.id)
	elseif action_type == Config.context_action_type.LONG then
		Log("Context lock: Unlock but keep focus")
		local target = State.target_to_lock or State.target_currently_locked
		UserActions.FocusTarget(task, target.id)
	elseif action_type == Config.context_action_type.DOUBLE then
		Log("Context lock: back to scan")
		UserActions.ScanZone(task)
	end
end

function UserActions.HandleContextActionScan(task, action_type)
	if action_type == Config.context_action_type.SHORT then
		Log("Context scan: next target")
		UserActions.HighlightNextTarget(task)
	elseif action_type == Config.context_action_type.LONG then
		local single_target = Api.GetSingleBanditOnScreenOrNil()
		if single_target ~= nil then
			-- directly proceed to lock target
			Log("Context scan: - lock single target")
			UserActions.LockTarget(task, single_target.id)
		else
			if State.target_to_highlight == nil then
				-- If user clicks context action right after spotting the bandit, he was not selected for highlight yet,
				-- attempt to do that now if possible
				State.target_to_highlight = Api.GetHighestPriorityBanditOrNil()
			end

			if State.target_to_highlight == nil then
				Log("Context scan: ambiguous highlight target")
				UserActions.HighlightNextTarget(task)
			else
				Log("Context scan: lock highlighted")
				UserActions.LockTarget(task, State.target_to_highlight.id)
			end
		end
	elseif action_type == Config.context_action_type.DOUBLE then
		Log("Context scan: reset target")
		UserActions.ScanZone(task)
	end
end

function UserActions.HandleA2AContextAction(task, action_type)
	State.SetEventTask(task)

	local is_lock = State.target_to_lock ~= nil or State.target_currently_locked ~= nil
	local is_dogfight = Api.IsInDogfightMode()
	local is_boresight = Api.IsBoresightMode()

	if is_dogfight then
		UserActions.HandleContextActionDogfight(task, action_type)
	elseif is_lock then
		UserActions.HandleContextActionLock(task, action_type)
	elseif is_boresight then
		UserActions.HandleContextActionBoresight(task, action_type)
	else
		UserActions.HandleContextActionScan(task, action_type)
	end
end

ListenTo("radar_context_a2g_dive_toss", "RadarUserActions", function(task)
	State.SetEventTask(task)
	UserActions.LockDiveToss(task)
end)

ListenTo("radar_context_a2g_dive_laydown", "RadarUserActions", function(task)
	State.SetEventTask(task)
	UserActions.LockDiveLaydown(task)
end)

ListenTo("radar_context_a2a_short", "RadarUserActions", function(task)
	UserActions.HandleA2AContextAction(task, Config.context_action_type.SHORT)
end)

ListenTo("radar_context_a2a_long", "RadarUserActions", function(task)
	UserActions.HandleA2AContextAction(task, Config.context_action_type.LONG)
end)

ListenTo("radar_context_a2a_double", "RadarUserActions", function(task)
	UserActions.HandleA2AContextAction(task, Config.context_action_type.DOUBLE)
end)

ListenTo("radar_iff", "RadarUserActions", function(task, system)
	State.SetEventTask(task)
	if not State.is_active or not Api.IsPowered() then
		Log("CantDo: IFF Challenge - Radar is not active/powered")
		task:CantDo()
		return
	end

	task:Say("contacts_iff/checkingiff")
	    :Require({ voice = true, hands = true })

	if system == "both" then
		Api.ClickIffButton(task)
	else
		Api.ClickApx76IffOnly(task)
	end
end)

ListenTo("radar_display_range", "RadarUserActions", function(task, range_and_scan_type)
	State.SetEventTask(task)
	task:Roger()

	-- Range;Scan Type: nm_25;wide
	local range_text, scan_type_text = string.match(range_and_scan_type, "(.+);(.+)")

	State.pilot_requested_range = Config.range[range_text]
	State.pilot_requested_scan_type = Config.scan_type[scan_type_text]
end)

ListenTo("radar_auto_focus", "RadarUserActions", function(task, mode)
	State.SetEventTask(task)
	task:Roger()

	State.is_auto_focus_allowed = mode == "on"
end)

ListenTo("radar_scan_zone", "RadarUserActions", function(task, zone)
	State.SetEventTask(task)

	-- Range;Altitude;Mode: 30;5.250;absolute or 30;-7.5;relative
	local range_text, altitude_text, mode_text = string.match(zone, "(.+);(.+);(.+)")
	local range = NM(tonumber(range_text))
	local altitude = ft(tonumber(altitude_text)) * 1000
	local is_relative = mode_text == "relative"

	UserActions.ScanZone(task, range, altitude, is_relative)
end)

ListenTo("radar_focus_target", "RadarUserActions", function(task, target_id)
	State.SetEventTask(task)
	UserActions.FocusTarget(task, target_id)
end)

ListenTo("radar_lock_target", "RadarUserActions", function(task, target_id)
	State.SetEventTask(task)
	UserActions.LockTarget(task, target_id)
end)

ListenTo("radar_enter_bst", "RadarUserActions", function(task)
	State.SetEventTask(task)

	if Api.IsBoresightMode() or Api.IsRegularCageMode() then
		task:Roger()
		return
	end

	local can_operate_radar = State.is_active and Api.IsPowered()
	local is_regular_a2a_behavior = State.current_context_mode == Config.context_mode.A2A and not Api.IsInDogfightMode()
	if not can_operate_radar or not is_regular_a2a_behavior or Api.IsInTrackState() then
		Log("CantDo: Enter BST - Radar is not active/powered or not in A2A context or in Dogfight context or in TRACK mode")
		task:CantDo()
		return
	end

	task:Roger()
	    :Click("Radar Mode", Config.mode.boresight)
	    :ClickFast("Radar Range", Config.range.nm_25)
	    :ClickFast("Radar Target Aspect", "nose")
end)

ListenTo("radar_bst_aspect", "RadarUserActions", function(task, aspect)
	State.SetEventTask(task)

	if not Api.IsBoresightMode() and not Api.IsRegularCageMode() then
		Log("CantDo: Set BST Aspect - Not in BST mode")
		task:CantDo()
		return
	end

	local phrase = "radar/aspect"
	if aspect == "nose" then
		phrase = phrase .. "nose"
	elseif aspect == "fwd" then
		phrase = phrase .. "forward"
	elseif aspect == "aft" then
		phrase = phrase .. "aft"
	elseif aspect == "tail" then
		phrase = phrase .. "tail"
	else
		phrase = phrase .. "wide"
	end

	task:Say(phrase)
	    :ClickFast("Radar Target Aspect", aspect)
end)

ListenTo("radar_unlock_tgt", "RadarUserActions", function(task)
  task:SetPriority(1)
  if Api.IsInTrackState() then
    return Api.UnlockTarget(task)
  end
end)

return UserActions
