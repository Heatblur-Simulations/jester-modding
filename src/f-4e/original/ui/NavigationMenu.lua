---// Copyright (c) 2023 Heatblur Simulations. All rights reserved.

local Interactions = require('base.Interactions')
local Navigate = require ('behaviors.NFO.navigation.Navigate')
local MSFSNavigate = require ('behaviors.NFO.navigation.MSFSNavigate')
local NavInteractions = require('tasks.navigation.NavInteractions')
local UpdateJesterWheel = require('behaviors.UpdateJesterWheel')
local Waypoint = require 'base.Waypoint'

local tacan_function = {
	off = "OFF",
	r = "REC",
	tr = "TR",
	aar = "AA_REC",
	aatr = "AA_TR",
}

local tacan_band = {
	x = "X",
	y = "Y",
}

local ToggleTacanCommand = function()
	ClickRawButton(Interactions.devices.TACAN_AN_ARN_118, Interactions.device_commands.TACAN_RIO_COMMAND)
end

local SetTacanChannel = function(task, channel_text)
	-- e.g. 107x or 068x
	local tens = channel_text:sub(1, 2) -- 10 or 06
	local ones = channel_text:sub(3, 3) -- 7 or 8
	local band = string.lower(channel_text:sub(4, 4)) -- x

	local tens_no = tonumber(channel_text:sub(1, 2)) -- 10 or 06
	local ones_no = tonumber(channel_text:sub(3, 3)) -- 7 or 8

	local isNumTens = tens_no ~= nil and tens_no >= 0 and tens_no <= 12
	local isNumOnes = ones_no ~= nil and ones_no >= 0 and ones_no <= 9
	local isBandCorrect = band == "x" or band == "y"

	if isNumTens and isNumOnes and isBandCorrect then
        task:Click("TACAN Channel Tens", tens)
        task:Click("TACAN Channel Ones", ones)
        task:Click("TACAN Band", tacan_band[band])
	end
end

local SetTacanMode = function(task, mode)
	task:Click("TACAN Function", tacan_function[mode])
end

local UpdateTACANWheelInfo = function()
	local update_wheel_behaviour = GetJester().behaviors[UpdateJesterWheel]
	if update_wheel_behaviour ~= nil then
		update_wheel_behaviour:UpdateTacanWheelInfo()
	end
end

local UpdateFlightPlans = function()
	local update_wheel_behaviour = GetJester().behaviors[UpdateJesterWheel]
	if update_wheel_behaviour ~= nil then
		update_wheel_behaviour:UpdateFlightplans()
	end
end

local function DecimalCoordsToStringFormat(lat, lon)
	local function Convert(coordinate, isLongitude)
		local degrees = math.floor(math.abs(coordinate))
		local minutes = math.floor((math.abs(coordinate) - degrees) * 60)

		local dir
		if isLongitude then
			dir = coordinate >= 0 and "E" or "W"
			return string.format("%s %03d %02d", dir, degrees, minutes)
		else
			dir = coordinate >= 0 and "N" or "S"
			return string.format("%s %02d %02d", dir, degrees, minutes)
		end
	end

	return Convert(lat, false) .. " " .. Convert(lon, true)
end

local GetNextWptPhrase = function(wpt_type)
	--same phrases as inside SwitchToNextTurnpoint
	local phrases = {
		DEFAULT = 'misc/nextturnpointsteeringset',
		CAP = 'misc/newturnpointcapstationset',
		IP = 'misc/newturnpointipset',
		TARGET = 'misc/newturnpointtargetset',
		VIP = 'misc/newturnpointfixset',
		VIP_SILENT = 'misc/nextturnpointsteeringset',
		FENCE_IN = 'misc/newturnpointfenceinset',
		FENCE_OUT = 'misc/newturnpointfenceoutset',
		HOMEBASE = 'misc/newturnpointhomeset',
	}
	local phrase = phrases[wpt_type] or phrases.DEFAULT
	return phrase
end

ListenTo("nav_tgt", "NavigationMenu", function(task, tgt_mode)
	task:Roger()
	NavInteractions.SelectNavCompMode(task, tgt_mode)
end)

ListenTo("nav_tacan_mode", "NavigationMenu", function(task, mode)
	task:Roger()
	SetTacanMode(task, mode)
	task:Then(function()
		UpdateTACANWheelInfo()
	end)
end)

ListenTo("nav_tacan_chan_tens", "NavigationMenu", function(task, tensDigits)
	local tens = tonumber(tensDigits)

	-- Generate items for the ones digit (0-9)
	local onesItems = {}
	for ones = 0, 9 do
		local channel = tens * 10 + ones
		if channel <= 129 then
			onesItems[ones + 1] = Wheel.Item:new({
				name = tostring(ones),
				action = "nav_tacan_chan_ones",
				reaction = Wheel.Reaction.NOTHING,
				action_value = tensDigits .. tostring(ones)
			})
		end
	end

	local wrapping_item = Wheel.Item:new({
		name = "Select Channel",
		outer_menu = Wheel.Menu:new({
			name = "Select Channel",
			items = onesItems,
		}),
	})

	Wheel.ReplaceItem(wrapping_item, "Select Channel", { "Navigation", "TACAN" })
	Wheel.SetMenuInfo("3rd digit [" ..tensDigits.. "Xb]", { "Navigation", "TACAN", "Select Channel" })
end)

ListenTo("nav_tacan_chan_ones", "NavigationMenu", function(task, channel)
	local xyItems = {
		Wheel.Item:new({name = "X Band", action = "nav_tacan_chan_band", action_value = channel .. "x"}),
		Wheel.Item:new({name = "Y Band", action = "nav_tacan_chan_band", action_value = channel .. "y"}),
	}
	local wrapping_item = Wheel.Item:new({
		name = "Select Channel",
		outer_menu = Wheel.Menu:new({
			name = "Select Channel",
			items = xyItems,
		}),
	})

	Wheel.ReplaceItem(wrapping_item, "Select Channel", { "Navigation", "TACAN" })
	Wheel.SetMenuInfo("Band [" ..channel.. "X]", { "Navigation", "TACAN", "Select Channel" })
end)

ListenTo("nav_tacan_chan", "NavigationMenu", function(task, channelWithBand)
	task:Roger()
	SetTacanChannel(task, channelWithBand)
	task:Then(function()
		UpdateTACANWheelInfo()
	end)
end)


ListenTo("nav_tacan_chan_band", "NavigationMenu", function(task, channelWithBand)
	task:Roger()
	SetTacanChannel(task, channelWithBand)
	task:Then(function()
		UpdateTACANWheelInfo()
	end)
	local update_wheel_behaviour = GetJester().behaviors[UpdateJesterWheel]
	if update_wheel_behaviour ~= nil then
		update_wheel_behaviour:GenerateTacanChannelTens()
	end
end)

ListenTo("nav_tacan_chan_proxy", "NavigationMenu", function(task, channelWithBand)
	SetTacanChannel(task, channelWithBand)
	task:Then(function()
		UpdateTACANWheelInfo()
	end)
end)

ListenTo("nav_tacan_mode_proxy", "NavigationMenu", function(task, mode)
	SetTacanMode(task, mode)
	task:Then(function()
		UpdateTACANWheelInfo()
	end)
end)

ListenTo("nav_tacan_tr", "NavigationMenu", function(task, channel)
	task:Roger()
	SetTacanMode(task, "tr")
	SetTacanChannel(task, channel)
	task:Then(function()
		UpdateTACANWheelInfo()
	end)
end)

ListenTo("nav_tacan_aa", "NavigationMenu", function(task, channel)
	task:Roger()
	SetTacanMode(task, "aatr")
    SetTacanChannel(task,channel)
	task:Then(function()
		UpdateTACANWheelInfo()
	end)
end)

ListenTo("nav_enter_tgt_1_lat_long_text", "NavigationMenu", function(task, lat_long)
	-- Lat/Long, H DD MM H DDD MM, N 12 34 E 123 45
	if lat_long == nil then
		Log("CantDo: Enter TGT 1 LAT/LON - No value given")
		task:CantDo()
		return
	end

	local pattern = "^([NSns])%s*(%d%d)%s*(%d%d)%s*([EWew])%s*(%d%d%d)%s*(%d%d)$"
	local north_south, lat_deg, lat_min, east_west, lon_deg, lon_min = lat_long:match(pattern)
	if not north_south then
		-- Invalid format
		task:Say('phrases/InvalidCoordinates')
		return
	end

	local is_north = north_south == "N" or north_south == "n"
	local is_east = east_west == "E" or east_west == "e"

	local lat_full_deg = tonumber(lat_deg) + (tonumber(lat_min) / 60.0)
	if not is_north then
		lat_full_deg = -lat_full_deg
	end
	local lon_full_deg = tonumber(lon_deg) + (tonumber(lon_min) / 60.0)
	if not is_east then
		lon_full_deg = -lon_full_deg
	end

	if lat_full_deg < -90 or lat_full_deg > 90
			or lon_full_deg < -180 or lon_full_deg > 180
			or tonumber(lat_min) > 60 or tonumber(lon_min) > 60 then
		-- Invalid coordinates
		task:Say('phrases/InvalidCoordinates')
		return
	end

	NavInteractions.SteerWithTGT1(task, lat_full_deg, lon_full_deg)
	local memory = GetJester().memory
	memory:DisactivateFlightplan()
	UpdateFlightPlans()
end)

ListenTo("divert_tgt1_lat_lon", "NavigationMenu", function(task, lat_long)
	NavInteractions.DivertWithTGT1(task, lat_long)
end)

ListenTo("proxy_divert_tgt1", "NavigationMenu", function(task, lat_long)
	NavInteractions.DivertWithTGT1(task, lat_long, true)
end)

ListenTo("resume_next_wpt", "NavigationMenu", function( task )
	local memory = GetJester().memory
	local previous_waypoint_no = memory:GetActiveWaypointNumber()
	local next_wpt_flag = memory:SwitchToNextOrFirstTurnPoint()

	if next_wpt_flag and memory:GetActiveWaypoint() ~= nil then
		task:Roger()
		memory:UpdateLastChangedWaypointTime()
		local active_waypoint = memory:GetActiveWaypoint()

		local phrase = 'misc/newturnpointsteering'
		if active_waypoint then
			local wpt_type = active_waypoint:GetSpecialWaypointType()
			if wpt_type then
				phrase = GetNextWptPhrase(wpt_type)
			end

			if wpt_type == "CAP" and previous_waypoint_no then
				local active_flightplan_no = memory:GetActiveFlightPlanNumber()
				local active_waypoint_no = memory:GetActiveWaypointNumber()
				local previous_waypoint = memory:GetWaypoint(active_flightplan_no, previous_waypoint_no)

				if previous_waypoint and previous_waypoint:GetSpecialWaypointType() == "CAP" then
					local cap_counterpart = memory:GetCAPCounterpartWptNo(active_flightplan_no, active_waypoint_no)
					if cap_counterpart and cap_counterpart == previous_waypoint_no then
						-- Current waypoint is part of a CAP pair and the previous waypoint was its counterpart
						-- Do nothing
					else
						-- Current waypoint is not part of a CAP pair or previous waypoint was not its counterpart
						local navigate_behaviour = GetJester().behaviors[Navigate]
						if navigate_behaviour ~= nil then
							navigate_behaviour:ResetCAPVariables()
						end
						memory:SetIsCapping( false )
					end
				end
			else
				local navigate_behaviour = GetJester().behaviors[Navigate]
				if navigate_behaviour ~= nil then
					navigate_behaviour:ResetCAPVariables()
				end
				memory:SetIsCapping( false )
			end

		end

		NavInteractions.SetNewActiveTGT2Coords(task, active_waypoint.latitude, active_waypoint.longitude)
		task:Require({ hands = true, voice = true })
		    :Say(phrase)
		UpdateFlightPlans()
		return
	end

	if memory:GetActiveFlightPlanNumber() == 0 and memory:GetMemorizedLastActiveWptData() ~= nil then
		local memorized = memory:GetMemorizedLastActiveWptData()
		local flightplan_no, waypoint_no = memorized.flightplan, memorized.waypoint

		if flightplan_no and flightplan_no > 0 and waypoint_no then
			local flightplan = memory:GetFlightPlan(flightplan_no)
			if flightplan and flightplan.waypoints and flightplan.waypoints[waypoint_no] then
				local waypoint = flightplan.waypoints[waypoint_no]
				memory:SetActiveWaypoint(flightplan_no, waypoint_no)
				task:Roger()
				memory:UpdateLastChangedWaypointTime()
				NavInteractions.SetNewActiveTGT2Coords(task, waypoint.latitude, waypoint.longitude)
				task:Require({ hands = true, voice = true })
				if (flightplan_no == 1) then
					task:Say('misc/primaryflightplanresume')
				elseif (flightplan_no == 2) then
					task:Say('misc/secondaryflightplanresume')
				end
				UpdateFlightPlans()
				return
			end
		else
			if  memory:GetFlightPlan1().waypoints[1] ~= nil then -- When no wpt active or memorized, initialize WPT1 from Primary Flight Plan
				local wpt = memory:GetFlightPlan1().waypoints[1]
				memory:SetActiveWaypoint(1, 1)
				task:Roger()
				memory:UpdateLastChangedWaypointTime()
				NavInteractions.SetNewActiveTGT2Coords(task, wpt.latitude, wpt.longitude)
				task:Require({ hands = true, voice = true })
				    :Say('misc/primaryflightplanresume')
				UpdateFlightPlans()
				return
			end
		end
	end

	task:CantDo()
end)

ListenTo("proxy_resume_flightplan", "NavigationMenu", function( task, fltpln_wptno )
	if fltpln_wptno ~= nil then
		local delimiter = ";"
		local fltpln_no_str, waypoint_no_str = string.match(fltpln_wptno, "([^" .. delimiter .. "]+)" .. delimiter .. "([^" .. delimiter .. "]+)")
		if fltpln_no_str ~= nil and waypoint_no_str ~= nil then
			local flightplan_no = tonumber(fltpln_no_str)
			local waypoint_no = tonumber(waypoint_no_str)
			if ( flightplan_no == 1 or flightplan_no == 2 ) and waypoint_no then
				local memory = GetJester().memory
				local previous_waypoint_no = memory:GetActiveWaypointNumber()

				local waypoint_exists = memory:GetWaypoint(flightplan_no, waypoint_no)
				if not waypoint_exists then
					Log("Proxy resume flightplan: Desired waypoint does not exist")
					return
				end
				local lat = waypoint_exists.latitude
				local lon = waypoint_exists.longitude

				memory:UpdateLastChangedWaypointTime()
				NavInteractions.SetNewActiveTGT2Coords(task, lat, lon)
				task:Require({ hands = true, voice = true })
				local same_flightplan_active = memory:GetActiveFlightPlanNumber() == flightplan_no
				memory:SetActiveWaypoint(flightplan_no, waypoint_no)
				UpdateFlightPlans()

				local active_waypoint = memory:GetActiveWaypoint()
				local phrase = 'misc/newturnpointsteering'
				if active_waypoint then
					local wpt_type = active_waypoint:GetSpecialWaypointType()
					if wpt_type then
						phrase = GetNextWptPhrase(wpt_type)
					end

					if wpt_type == "CAP" and previous_waypoint_no and same_flightplan_active then
						local active_flightplan_no = memory:GetActiveFlightPlanNumber()
						local active_waypoint_no = memory:GetActiveWaypointNumber()
						local previous_waypoint = memory:GetWaypoint(active_flightplan_no, previous_waypoint_no)

						if previous_waypoint and previous_waypoint:GetSpecialWaypointType() == "CAP" then
							local cap_counterpart = memory:GetCAPCounterpartWptNo(active_flightplan_no, active_waypoint_no)
							if cap_counterpart and cap_counterpart == previous_waypoint_no then
								-- Current waypoint is part of a CAP pair and the previous waypoint was its counterpart
								-- Do nothing
							else
								-- Current waypoint is not part of a CAP pair or previous waypoint was not its counterpart
								local navigate_behaviour = GetJester().behaviors[Navigate]
								if navigate_behaviour ~= nil then
									navigate_behaviour:ResetCAPVariables()
								end
								memory:SetIsCapping( false )
							end
						end
					else
						local navigate_behaviour = GetJester().behaviors[Navigate]
						if navigate_behaviour ~= nil then
							navigate_behaviour:ResetCAPVariables()
						end
						memory:SetIsCapping(false)
					end
				end

				if same_flightplan_active then
					task:Say(phrase)
				else if flightplan_no == 1 then
					task:Say('misc/primaryflightplanresume')
				else
					task:Say('misc/secondaryflightplanresume')
				end
				end
				return
			end
		end
	end
	Log("Proxy resume flightplan: rrg string is nil")
end)

ListenTo("resume_flightplan_1", "NavigationMenu", function( task, lat_long_wpt )
	if lat_long_wpt ~= nil then
		local delimiter = ";"
		local lat, lon, waypoint_no_str = string.match(lat_long_wpt, "([^" .. delimiter .. "]+)" .. delimiter .. "([^" .. delimiter .. "]+)" .. delimiter .. "([^" .. delimiter .. "]+)")
		if lat ~= nil and lon ~= nil and waypoint_no_str ~= nil then
			local waypoint_no = tonumber(waypoint_no_str)
			if waypoint_no then
				task:Roger()
				local memory = GetJester().memory
				local previous_waypoint_no = memory:GetActiveWaypointNumber()
				memory:UpdateLastChangedWaypointTime()
				NavInteractions.SetNewActiveTGT2Coords(task, lat, lon)
				task:Require({ hands = true, voice = true })
				local flightplan1_active = memory:GetActiveFlightPlanNumber() == 1
				memory:SetActiveWaypoint(1, waypoint_no)
				UpdateFlightPlans()

				local active_waypoint = memory:GetActiveWaypoint()
				local phrase = 'misc/newturnpointsteering'
				if active_waypoint then
					local wpt_type = active_waypoint:GetSpecialWaypointType()
					if wpt_type then
						phrase = GetNextWptPhrase(wpt_type)
					end

					if wpt_type == "CAP" and previous_waypoint_no then
						local active_flightplan_no = memory:GetActiveFlightPlanNumber()
						local active_waypoint_no = memory:GetActiveWaypointNumber()
						local previous_waypoint = memory:GetWaypoint(active_flightplan_no, previous_waypoint_no)

						if previous_waypoint and previous_waypoint:GetSpecialWaypointType() == "CAP" then
							local cap_counterpart = memory:GetCAPCounterpartWptNo(active_flightplan_no, active_waypoint_no)
							if cap_counterpart and cap_counterpart == previous_waypoint_no then
								-- Current waypoint is part of a CAP pair and the previous waypoint was its counterpart
								-- Do nothing
							else
								-- Current waypoint is not part of a CAP pair or previous waypoint was not its counterpart
								local navigate_behaviour = GetJester().behaviors[Navigate]
								if navigate_behaviour ~= nil then
									navigate_behaviour:ResetCAPVariables()
								end
								memory:SetIsCapping( false )
							end
						end
					else
						local navigate_behaviour = GetJester().behaviors[Navigate]
						if navigate_behaviour ~= nil then
							navigate_behaviour:ResetCAPVariables()
						end
						memory:SetIsCapping(false)
					end
				end

				if flightplan1_active then
					task:Say(phrase)
				else
					task:Say('misc/primaryflightplanresume')
				end
				return
			end
		end
	end
	task:CantDo()
	Log("CantDo: Resume FLP 1 - Waypoint not found")
end)

ListenTo("resume_flightplan_2", "NavigationMenu", function( task, lat_long_wpt )
	if lat_long_wpt ~= nil then
		local delimiter = ";"
		local lat, lon, waypoint_no_str = string.match(lat_long_wpt, "([^" .. delimiter .. "]+)" .. delimiter .. "([^" .. delimiter .. "]+)" .. delimiter .. "([^" .. delimiter .. "]+)")
		if lat ~= nil and lon ~= nil and waypoint_no_str ~= nil then
			local waypoint_no = tonumber(waypoint_no_str)
			if waypoint_no then
				task:Roger()
				local memory = GetJester().memory
				local previous_waypoint_no = memory:GetActiveWaypointNumber()
				memory:UpdateLastChangedWaypointTime()
				NavInteractions.SetNewActiveTGT2Coords(task, lat, lon)
				task:Require({ hands = true, voice = true })
				local flightplan2_active = memory:GetActiveFlightPlanNumber() == 2
				memory:SetActiveWaypoint(2, waypoint_no)
				UpdateFlightPlans()

				local active_waypoint = memory:GetActiveWaypoint()
				local phrase = 'misc/newturnpointsteering'
				if active_waypoint then
					local wpt_type = active_waypoint:GetSpecialWaypointType()
					if wpt_type then
						phrase = GetNextWptPhrase(wpt_type)
					end

					if wpt_type == "CAP" and previous_waypoint_no then
						local active_flightplan_no = memory:GetActiveFlightPlanNumber()
						local active_waypoint_no = memory:GetActiveWaypointNumber()
						local previous_waypoint = memory:GetWaypoint(active_flightplan_no, previous_waypoint_no)

						if previous_waypoint and previous_waypoint:GetSpecialWaypointType() == "CAP" then
							local cap_counterpart = memory:GetCAPCounterpartWptNo(active_flightplan_no, active_waypoint_no)
							if cap_counterpart and cap_counterpart == previous_waypoint_no then
								-- Current waypoint is part of a CAP pair and the previous waypoint was its counterpart
								-- Do nothing
							else
								-- Current waypoint is not part of a CAP pair or previous waypoint was not its counterpart
								local navigate_behaviour = GetJester().behaviors[Navigate]
								if navigate_behaviour ~= nil then
									navigate_behaviour:ResetCAPVariables()
								end
								memory:SetIsCapping( false )
							end
						end
					else
						local navigate_behaviour = GetJester().behaviors[Navigate]
						if navigate_behaviour ~= nil then
							navigate_behaviour:ResetCAPVariables()
						end
						memory:SetIsCapping(false)
					end
				end

				if flightplan2_active then
					task:Say(phrase)
				else
					task:Say('misc/secondaryflightplanresume')
				end
				return
			end
		end
	end
	task:CantDo()
	Log("CantDo: Resume FLP 2 - Waypoint not found")
end)

ListenTo("resume_backup_flightplan", "NavigationMenu", function(task, ftpln_str)
	local flightplan_no = tonumber(ftpln_str)
	local flightplan = {}
	local items = {}
	local memory = GetJester().memory
	local flightplan_name = ""
	if (ftpln_str == "2") then
		flightplan = memory:GetFlightPlan2()
		flightplan_name = "Secondary Flight Plan"
	else
		flightplan = memory:GetFlightPlan1()
		flightplan_name = "Primary Flight Plan"
	end

	for i, waypoint in ipairs(flightplan.waypoints) do
		if i > Wheel.MAX_OUTER_MENU_ITEMS then
			break
		end

		local update_wheel_behaviour = GetJester().behaviors[UpdateJesterWheel]
		if update_wheel_behaviour ~= nil and waypoint.latitude ~= nil and waypoint.longitude ~= nil then
			local action_value = tostring(waypoint.latitude) .. ";" .. tostring(waypoint.longitude) .. ";" .. tostring(i)
			local name = update_wheel_behaviour:GetWaypointTextToDisplay(flightplan_no, i, waypoint)
			local act_name = "resume_flightplan_" .. ftpln_str

			items[i] = Wheel.Item:new({
				name = name,
				action = act_name,
				action_value = action_value,
			})
		end
	end

	if #items == 0 then
		items[1] = Wheel.Item:new({ name = "No Turn Points in " .. flightplan_name })
	end

	local wrapping_item = Wheel.Item:new({
		name = "Go To / Resume",
		outer_menu = Wheel.Menu:new({
			name = "Go To / Resume",
			items = items,
		}),
	})

	Wheel.ReplaceItem(wrapping_item, "Go To / Resume", { "Navigation" })
	Wheel.SetMenuInfo(flightplan_name, { "Navigation", "Go To / Resume" })
end)

-- Toggles hold depending on the current waypoint hold state
ListenTo("hold_curr_wpt", "NavigationMenu", function( task )
	local memory = GetJester().memory
	local flightplan = memory:GetActiveFlightPlan()
	if not flightplan or not flightplan.waypoints or #flightplan.waypoints == 0 then
		Log("CantDo: Hold Current WPT - No FLP or WPT found")
		task:CantDo()
		return
	end

	local current_waypoint = memory:GetActiveWaypointNumber()
	if current_waypoint and current_waypoint > 0 and current_waypoint <= #flightplan.waypoints then
		local fltpln_no = memory:GetActiveFlightPlanNumber()
		if fltpln_no == 1 or fltpln_no == 2 then
			local is_hold = memory:ToggleHoldAtWaypoint(fltpln_no, current_waypoint)
			if is_hold then
				task:Say('misc/holdsteering')
			else
				task:Roger()
			end
			UpdateFlightPlans()
		end
	else
		task:CantDo()
		Log("CantDo: Hold Current WPT - No current WPT found")
	end
end)

ListenTo("hold_flightplan_1", "NavigationMenu", function( task, wpt_no )
	local memory = GetJester().memory
	memory:SetHoldAtWaypoint(1, tonumber(wpt_no), true)
	local is_current = tonumber(wpt_no) == memory:GetActiveWaypointNumber( ) and 1 == memory:GetActiveFlightPlanNumber( )
	if is_current then
		task:Say('misc/holdsteering')
	else
		task:Roger()
	end
	UpdateFlightPlans()
end)

ListenTo("hold_flightplan_2", "NavigationMenu", function( task, wpt_no )
	local memory = GetJester().memory
	memory:SetHoldAtWaypoint(2, tonumber(wpt_no), true)
	local is_current = tonumber(wpt_no) == memory:GetActiveWaypointNumber( ) and 2 == memory:GetActiveFlightPlanNumber( )
	if is_current then
		task:Say('misc/holdsteering')
	else
		task:Roger()
	end
	UpdateFlightPlans()
end)

ListenTo("deactivate_hold_fp1", "NavigationMenu", function( task, wpt_no )
	local memory = GetJester().memory
	memory:SetHoldAtWaypoint(1, tonumber(wpt_no), false)
	task:Roger()
	UpdateFlightPlans()
end)

ListenTo("deactivate_hold_fp2", "NavigationMenu", function( task, wpt_no )
	local memory = GetJester().memory
	memory:SetHoldAtWaypoint(2, tonumber(wpt_no), false)
	task:Roger()
	UpdateFlightPlans()
end)

ListenTo("delete_wpt", "NavigationMenu", function( task, fltpln_wpt_no )
	local delimiter = ";"
	local fltpln_no, wpt_no = string.match(fltpln_wpt_no, "([^" .. delimiter .. "]+)" .. delimiter .. "([^" .. delimiter .. "]+)")
	if fltpln_no and wpt_no then
		fltpln_no = tonumber(fltpln_no)
		wpt_no = tonumber(wpt_no)

		local memory = GetJester().memory
		if memory and memory.DeleteWaypoint then
			local is_current = wpt_no == memory:GetActiveWaypointNumber( ) and fltpln_no == memory:GetActiveFlightPlanNumber( )
			task:Roger()
			memory:DeleteWaypoint(fltpln_no, wpt_no)
			-- If the deleted waypoint was the current one, update TGT2 coordinates to the new current waypoint
			if is_current then
				local new_active_wpt = memory:GetActiveWaypoint()
				if new_active_wpt then
					memory:UpdateLastChangedWaypointTime()
					NavInteractions.SetNewActiveTGT2Coords(task, new_active_wpt.latitude, new_active_wpt.longitude)
				end
			end
			UpdateFlightPlans()
			Wheel.NavigateTo({ "Navigation", "Edit Flight Plan", memory:GetFlightplanNameString(fltpln_no) })
			return
		else
			io.stderr:write("Error: Unable to delete waypoint. Memory object or DeleteWaypoint function not found.\n")
		end
	end
	task:Say('phrases/InvalidCoordinates')
end)

ListenTo("edit_wpt_lat_long_text", "NavigationMenu", function( task, fltpln_wpt_lat_lon )
	fltpln_wpt_lat_lon = fltpln_wpt_lat_lon or ""
	if fltpln_wpt_lat_lon == "" then
		task:Say('phrases/InvalidCoordinates')
		return
	end
	-- Lat/Long, H DD MM H DDD MM, N 12 34 E 123 45
	local fltpln_no, wpt_no, lat_long = string.match(fltpln_wpt_lat_lon, "(%d+);(%d+);(.+)")
	if not fltpln_no or not wpt_no or not lat_long or lat_long == "" then
		task:Say('phrases/InvalidCoordinates')
		return
	end

	fltpln_no = tonumber(fltpln_no)
	wpt_no = tonumber(wpt_no)

	local pattern = "^([NSns])%s*(%d%d)%s*(%d%d)%s*([EWew])%s*(%d%d%d)%s*(%d%d)$"
	local north_south, lat_deg, lat_min, east_west, lon_deg, lon_min = lat_long:match(pattern)
	if not north_south then
		-- Invalid format
		task:Say('phrases/InvalidCoordinates')
		return
	end

	local is_north = north_south == "N" or north_south == "n"
	local is_east = east_west == "E" or east_west == "e"

	local lat_full_deg = ( tonumber(lat_deg) + (tonumber(lat_min) / 60.0) ) * (is_north and 1 or -1)
	local lon_full_deg = ( tonumber(lon_deg) + (tonumber(lon_min) / 60.0) ) * (is_east and 1 or -1)

	if lat_full_deg < -90 or lat_full_deg > 90
			or lon_full_deg < -180 or lon_full_deg > 180
			or tonumber(lat_min) > 60 or tonumber(lon_min) > 60 then
		-- Invalid coordinates
		task:Say('phrases/InvalidCoordinates')
		return
	end

	local memory = GetJester().memory
	if fltpln_no and memory and wpt_no and lat_full_deg and lon_full_deg then
		memory:EditWaypointCoords(fltpln_no, wpt_no, lat_full_deg, lon_full_deg)
		UpdateFlightPlans()
		Wheel.NavigateTo({ "Navigation", "Edit Flight Plan", memory:GetFlightplanNameString(fltpln_no) })
		task:Roger()
		if fltpln_no == memory:GetActiveFlightPlanNumber() and wpt_no == memory:GetActiveWaypointNumber() then
			NavInteractions.SetNewActiveTGT2Coords(task, lat_full_deg, lon_full_deg)
			task:Require({ hands = true, voice = true })
			    :Say('misc/newturnpointsteering')
		end
	else
		task:CantDo()
		Log("CantDo: Edit WPT LAT/LON TEXT - Invalid data/format")
	end

end)

ListenTo("edit_wpt_lat_long", "NavigationMenu", function( task, fltpln_wpt_lat_lon )
	local fltpln_no, wpt_no, latStr, lonStr, nameStr = fltpln_wpt_lat_lon:match("([^;]+);([^;]+);([^;]+);([^;]+);(.+)")
	local fltpln_no = tonumber(fltpln_no)
	local wpt_no = tonumber(wpt_no)
	local lat = tonumber(latStr)
	local lon = tonumber(lonStr)

	if fltpln_no == nil or wpt_no == nil or lat == nil or lon == nil then
		Log("CantDo: Edit WPT LAT/LON - Invalid data/format")
		task:CantDo()
		return
	end

	local memory = GetJester().memory
	if fltpln_no and memory and wpt_no and lat and lon then
		memory:EditWaypointCoords(fltpln_no, wpt_no, lat, lon)
		local wpt_name = nameStr and nameStr:sub(1, 20):gsub(";", "") or ""
		if wpt_name ~= "" then
			memory:EditWaypointName(fltpln_no, wpt_no, wpt_name)
		end
		UpdateFlightPlans()
		Wheel.NavigateTo({ "Navigation", "Edit Flight Plan", memory:GetFlightplanNameString(fltpln_no) })
		task:Roger()
		if fltpln_no == memory:GetActiveFlightPlanNumber() and wpt_no == memory:GetActiveWaypointNumber() then
			NavInteractions.SetNewActiveTGT2Coords(task, lat, lon)
			task:Require({ hands = true, voice = true })
			    :Say('misc/newturnpointsteering')
		end
	else
		Log("CantDo: Edit WPT LAT/LON - Invalid data/format")
		task:CantDo()
	end

end)

ListenTo("edit_wpt_fltpln", "NavigationMenu", function(task, fltpln_wpt_data)
	local fltpln_edit_no, wpt_edit_no, fltpln_copy_no, wpt_copy_no = string.match(fltpln_wpt_data, "(%d+);(%d+);(%d+);(%d+)")
	fltpln_edit_no = tonumber(fltpln_edit_no)
	wpt_edit_no = tonumber(wpt_edit_no)
	fltpln_copy_no = tonumber(fltpln_copy_no)
	wpt_copy_no = tonumber(wpt_copy_no)

	local memory = GetJester().memory
	if memory and fltpln_edit_no and wpt_edit_no and fltpln_copy_no and wpt_copy_no then
		local copy_wpt = memory:GetWaypoint(fltpln_copy_no, wpt_copy_no)
		if copy_wpt then
			memory:EditWaypointCoords(fltpln_edit_no, wpt_edit_no, copy_wpt.latitude, copy_wpt.longitude)
			memory:EditWaypointName(fltpln_edit_no, wpt_edit_no, copy_wpt.name)
			--memory:EditWaypointDesignation(fltpln_edit_no, wpt_edit_no, copy_wpt.special_type) --not copying those atm
			memory:EditWaypointIsHold(fltpln_edit_no, wpt_edit_no, copy_wpt.hold)
			task:Roger()
			if fltpln_edit_no == memory:GetActiveFlightPlanNumber() and wpt_edit_no == memory:GetActiveWaypointNumber() then
				NavInteractions.SetNewActiveTGT2Coords(task, copy_wpt.latitude, copy_wpt.longitude)
				task:Require({ hands = true, voice = true })
				    :Say('misc/newturnpointsteering')
			end
			UpdateFlightPlans()
			Wheel.NavigateTo({ "Navigation", "Edit Flight Plan", memory:GetFlightplanNameString(fltpln_edit_no) })
		else
			Log("CantDo: Edit WPT FLP - Unable to find waypoint to copy from")
			task:CantDo()
		end
	else
		Log("CantDo: Edit WPT FLP - Invalid input for editing waypoint via flightplan data")
		task:CantDo()
	end
end)

ListenTo("add_wpt_after_lat_long_text", "NavigationMenu", function(task, fltpln_wpt_lat_lon)
	fltpln_wpt_lat_lon = fltpln_wpt_lat_lon or ""
	if fltpln_wpt_lat_lon == "" then
		task:Say('phrases/InvalidCoordinates')
		return
	end

	local fltpln_no, wpt_no, lat_long = string.match(fltpln_wpt_lat_lon, "(%d+);(%d+);(.+)")
	if not fltpln_no or not wpt_no or not lat_long or lat_long == "" then
		task:Say('phrases/InvalidCoordinates')
		return
	end

	fltpln_no = tonumber(fltpln_no)
	wpt_no = tonumber(wpt_no)

	local pattern = "^([NSns])%s*(%d%d)%s*(%d%d)%s*([EWew])%s*(%d%d%d)%s*(%d%d)$"
	local north_south, lat_deg, lat_min, east_west, lon_deg, lon_min = lat_long:match(pattern)
	if not north_south then
		task:Say('phrases/InvalidCoordinates')
		return
	end

	local is_north = north_south == "N" or north_south == "n"
	local is_east = east_west == "E" or east_west == "e"

	local lat_full_deg = ( tonumber(lat_deg) + (tonumber(lat_min) / 60.0) ) * (is_north and 1 or -1)
	local lon_full_deg = ( tonumber(lon_deg) + (tonumber(lon_min) / 60.0) ) * (is_east and 1 or -1)

	if lat_full_deg < -90 or lat_full_deg > 90
			or lon_full_deg < -180 or lon_full_deg > 180
			or tonumber(lat_min) > 60 or tonumber(lon_min) > 60 then
		-- Invalid coordinates
		task:Say('phrases/InvalidCoordinates')
		return
	end

	local memory = GetJester().memory
	if fltpln_no and memory and wpt_no and lat_full_deg and lon_full_deg then
		task:Roger()
		local new_waypoint = Waypoint:new(lat_full_deg, lon_full_deg)
		memory:InsertWaypointAfter(fltpln_no, wpt_no, new_waypoint)
		UpdateFlightPlans()
		Wheel.NavigateTo({ "Navigation", "Edit Flight Plan", memory:GetFlightplanNameString(fltpln_no) })
	else
		Log("CantDo: Add WPT after LAT/LON TEXT - Invalid data/format")
		task:CantDo()
	end
end)

ListenTo("add_wpt_after_lat_long", "NavigationMenu", function(task, fltpln_wpt_lat_lon)
	local fltpln_str, wpt_no_str, latStr, lonStr, nameStr = fltpln_wpt_lat_lon:match("([^;]+);([^;]+);([^;]+);([^;]+);(.+)")
	local fltpln_no = tonumber(fltpln_str)
	local wpt_no = tonumber(wpt_no_str)
	local lat = tonumber(latStr)
	local lon = tonumber(lonStr)

	local memory = GetJester().memory
	if memory == nil or fltpln_no == nil or wpt_no == nil or lat == nil or lon == nil then
		Log("CantDo: Add WPT after LAT/LON - Invalid data/format")
		task:CantDo()
		return
	end

	task:Roger()
	local wpt_name = nameStr and nameStr:sub(1, 20):gsub(";", "") or ""
	local new_waypoint = Waypoint:new( lat, lon, false, wpt_name )
	new_waypoint:SetCoordinates(lat, lon)

	memory:InsertWaypointAfter(fltpln_no, wpt_no, new_waypoint)
	UpdateFlightPlans()
	Wheel.NavigateTo({ "Navigation", "Edit Flight Plan", memory:GetFlightplanNameString(fltpln_no) })
end)

ListenTo("add_wpt_after_proxy", "NavigationMenu", function(task, fltpln_wpt_lat_lon)
	local fltpln_str, wpt_no_str, latStr, lonStr, nameStr = fltpln_wpt_lat_lon:match("([^;]+);([^;]+);([^;]+);([^;]+);(.+)")
	local fltpln_no = tonumber(fltpln_str)
	local wpt_no = tonumber(wpt_no_str)
	local lat = tonumber(latStr)
	local lon = tonumber(lonStr)

	local memory = GetJester().memory
	if memory == nil or fltpln_no == nil or wpt_no == nil or lat == nil or lon == nil then
		return
	end

	local wpt_name = nameStr and nameStr:sub(1, 20):gsub(";", "") or ""
	local new_waypoint = Waypoint:new( lat, lon, false, wpt_name )
	new_waypoint:SetCoordinates(lat, lon)

	memory:InsertWaypointAfter(fltpln_no, wpt_no, new_waypoint)
	UpdateFlightPlans()
end)

ListenTo("add_wpt_after_fltpln", "NavigationMenu", function(task, fltpln_wpt_copy_info)
	local fltpln_to_edit_no, wpt_to_edit_no_str, fltpln_to_copy_no, wpt_to_copy_no_str = string.match(fltpln_wpt_copy_info, "(%d+);(%d+);(%d+);(%d+)")
	fltpln_to_edit_no = tonumber(fltpln_to_edit_no)
	local wpt_to_edit_no = tonumber(wpt_to_edit_no_str)
	fltpln_to_copy_no = tonumber(fltpln_to_copy_no)
	local wpt_to_copy_no = tonumber(wpt_to_copy_no_str)

	local memory = GetJester().memory
	local waypoint_to_copy = memory:GetWaypoint(fltpln_to_copy_no, wpt_to_copy_no)
	if waypoint_to_copy then
		task:Roger()
		memory:InsertWaypointAfter(fltpln_to_edit_no, wpt_to_edit_no, waypoint_to_copy)
		UpdateFlightPlans()
		Wheel.NavigateTo({ "Navigation", "Edit Flight Plan", memory:GetFlightplanNameString(fltpln_to_edit_no) })
	else
		Log("CantDo: Add WPT after FLP - Unable to find the WPT to copy from")
		task:CantDo()
	end
end)

ListenTo("add_wpt_before_lat_long_text", "NavigationMenu", function(task, fltpln_wpt_lat_lon)
	fltpln_wpt_lat_lon = fltpln_wpt_lat_lon or ""
	if fltpln_wpt_lat_lon == "" then
		task:Say('phrases/InvalidCoordinates')
		return
	end

	local fltpln_no_str, wpt_no, lat_long = string.match(fltpln_wpt_lat_lon, "(%d+);(%d+);(.+)")
	if not fltpln_no_str or not wpt_no or not lat_long or lat_long == "" then
		task:Say('phrases/InvalidCoordinates')
		return
	end

	local fltpln_no = tonumber(fltpln_no_str)
	wpt_no = tonumber(wpt_no)

	local pattern = "^([NSns])%s*(%d%d)%s*(%d%d)%s*([EWew])%s*(%d%d%d)%s*(%d%d)$"
	local north_south, lat_deg, lat_min, east_west, lon_deg, lon_min = lat_long:match(pattern)
	if not north_south then
		-- Invalid format
		task:Say('phrases/InvalidCoordinates')
		return
	end

	local is_north = north_south == "N" or north_south == "n"
	local is_east = east_west == "E" or east_west == "e"

	local lat_full_deg = ( tonumber(lat_deg) + (tonumber(lat_min) / 60.0) ) * (is_north and 1 or -1)
	local lon_full_deg = ( tonumber(lon_deg) + (tonumber(lon_min) / 60.0) ) * (is_east and 1 or -1)

	if lat_full_deg < -90 or lat_full_deg > 90
			or lon_full_deg < -180 or lon_full_deg > 180
			or tonumber(lat_min) > 60 or tonumber(lon_min) > 60 then
		-- Invalid coordinates
		task:Say('phrases/InvalidCoordinates')
		return
	end

	local memory = GetJester().memory
	if fltpln_no and memory and wpt_no and lat_full_deg and lon_full_deg then
		task:Roger()
		local new_waypoint = Waypoint:new( lat_full_deg, lon_full_deg )
		memory:InsertWaypointBefore(fltpln_no, wpt_no, new_waypoint)
		UpdateFlightPlans()
		Wheel.NavigateTo({ "Navigation", "Edit Flight Plan", memory:GetFlightplanNameString(fltpln_no) })
	else
		Log("CantDo: Add WPT before LAT/LON TEXT - Invalid data/format")
		task:CantDo()
	end
end)

ListenTo("add_wpt_before_lat_long", "NavigationMenu", function(task, fltpln_wpt_lat_lon)
	local fltpln_str, wpt_no_str, latStr, lonStr, nameStr = fltpln_wpt_lat_lon:match("([^;]+);([^;]+);([^;]+);([^;]+);(.+)")
	local fltpln_no = tonumber(fltpln_str)
	local wpt_no = tonumber(wpt_no_str)
	local lat = tonumber(latStr)
	local lon = tonumber(lonStr)

	local memory = GetJester().memory
	if memory == nil or fltpln_no == nil or wpt_no == nil or lat == nil or lon == nil then
		Log("CantDo: Add WPT before LAT/LON - Invalid data/format")
		task:CantDo()
		return
	end

	task:Roger()
	local wpt_name = nameStr and nameStr:sub(1, 20):gsub(";", "") or ""
	local new_waypoint = Waypoint:new(lat, lon, false, wpt_name)

	memory:InsertWaypointBefore(fltpln_no, wpt_no, new_waypoint)
	UpdateFlightPlans()
	Wheel.NavigateTo({ "Navigation", "Edit Flight Plan", memory:GetFlightplanNameString(fltpln_no) })
end)

ListenTo("add_wpt_before_fltpln", "NavigationMenu", function(task, fltpln_wpt_copy_info)
	local fltpln_to_edit_no_str, wpt_to_edit_no_str, fltpln_to_copy_no, wpt_to_copy_no_str = string.match(fltpln_wpt_copy_info, "(%d+);(%d+);(%d+);(%d+)")
	local fltpln_to_edit_no = tonumber(fltpln_to_edit_no_str)
	local wpt_to_edit_no = tonumber(wpt_to_edit_no_str)
	fltpln_to_copy_no = tonumber(fltpln_to_copy_no)
	local wpt_to_copy_no = tonumber(wpt_to_copy_no_str)

	local memory = GetJester().memory
	local waypoint_to_copy = memory:GetWaypoint(fltpln_to_copy_no, wpt_to_copy_no)
	if waypoint_to_copy then
		task:Roger()
		memory:InsertWaypointBefore(fltpln_to_edit_no, wpt_to_edit_no, waypoint_to_copy)
		UpdateFlightPlans()
		Wheel.NavigateTo({ "Navigation", "Edit Flight Plan", memory:GetFlightplanNameString(fltpln_to_edit_no) })
	else
		Log("CantDo: Add WPT before FLP - Unable to find WPT to copy from")
		task:CantDo()
	end
end)

ListenTo("designate_wpt", "NavigationMenu", function(task, fltpln_wpt_type)
	local fltpln_no_str, wpt_no, type = string.match(fltpln_wpt_type, "(%d+);(%d+);(.+)")
	if not fltpln_no_str or not wpt_no or not Waypoint.SpecialTypes[type] then
		Log("CantDo: Designate WPT - Invalid data format")
		task:CantDo()
		return
	end

	local fltpln_no = tonumber(fltpln_no_str)
	wpt_no = tonumber(wpt_no)
	local memory = GetJester().memory

	local waypoint_to_designate = memory:GetWaypoint(fltpln_no, wpt_no)
	if waypoint_to_designate then
		if type == "CAP" and waypoint_to_designate:GetSpecialWaypointType() == "CAP" then
			Log("CantDo: Designate WPT - Cannot change directly from CAP to CAP")
			task:CantDo()
			return
		end

		if type ~= "CAP" and waypoint_to_designate == memory:GetActiveWaypoint() then --reset the cap variables
			local navigate_behaviour = GetJester().behaviors[Navigate]
			if navigate_behaviour ~= nil then
				navigate_behaviour:ResetCAPVariables()
				memory:SetIsCapping( false )
			end
		end

		task:Roger()
		memory:SetWaypointDesignation(fltpln_no, wpt_no, type)
		UpdateFlightPlans()
		Wheel.NavigateTo({ "Navigation", "Edit Flight Plan", memory:GetFlightplanNameString(fltpln_no) })
	else
		task:CantDo()
	end
end)

ListenTo("msfsnav_holding", "NavigationMenu", function(task)
	local navigate_behaviour = GetJester().behaviors[MSFSNavigate]
	local holding_set = false
	if navigate_behaviour ~= nil then
		holding_set = navigate_behaviour:SetHoldAtNextWpt( )
	end
	if holding_set then
		task:Roger()
	else
		task:CantDo()
	end
end)

ListenTo("msfsnav_resume", "NavigationMenu", function(task)
	local navigate_behaviour = GetJester().behaviors[MSFSNavigate]
	local ok = false
	if navigate_behaviour ~= nil then
		ok = navigate_behaviour:ResumeNav( )
	end
	if ok then
		task:Roger()
	else
		task:CantDo()
	end
end)

ListenTo("msfsnav_navfix", "NavigationMenu", function(task)
	local navigate_behaviour = GetJester().behaviors[MSFSNavigate]
	local nav_fix_set = false
	if navigate_behaviour ~= nil then
		nav_fix_set = navigate_behaviour:SetWptAsNavFix()
	end
	if nav_fix_set then
		task:Roger()
	else
		task:CantDo()
	end
end)

ListenTo("proxy_designate_wpt", "NavigationMenu", function(task, fltpln_wpt_type)
	local fltpln_no_str, wpt_no, type = string.match(fltpln_wpt_type, "(%d+);(%d+);(.+)")
	if not fltpln_no_str or not wpt_no or not Waypoint.SpecialTypes[type] then
		Log("Proxy wpt designation: arg error")
		return
	end

	local fltpln_no = tonumber(fltpln_no_str)
	wpt_no = tonumber(wpt_no)
	local memory = GetJester().memory

	local waypoint_to_designate = memory:GetWaypoint(fltpln_no, wpt_no)
	if waypoint_to_designate then
		if type == "CAP" and waypoint_to_designate:GetSpecialWaypointType() == "CAP" then
			Log("Proxy wpt designation: can't select CAP again")
			return
		end

		if type ~= "CAP" and waypoint_to_designate == memory:GetActiveWaypoint() then --reset the cap variables
			local navigate_behaviour = GetJester().behaviors[Navigate]
			if navigate_behaviour ~= nil then
				navigate_behaviour:ResetCAPVariables()
				memory:SetIsCapping( false )
			end
		end

		memory:SetWaypointDesignation(fltpln_no, wpt_no, type)
		UpdateFlightPlans()
	else
		Log("Proxy wpt designation: Invalid waypoint")
	end
end)

ListenTo("jester_realign_quick", "NavigationMenu", function(task)
	GetJester().memory:SetRealignmentComplete(false)
	GetJester().memory:SetStartRealigning(true)
	task:Roger()

end)
