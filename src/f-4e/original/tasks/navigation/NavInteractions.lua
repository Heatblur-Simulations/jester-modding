---// Copyright (c) 2024 Heatblur Simulations. All rights reserved.
local Class = require 'base.Class'
require('base.Interactions')
local UpdateJesterWheel = require('behaviors.UpdateJesterWheel')

local NavInteractions = Class()
local Navigate = nil

local nav_function = {
	off = "OFF",
	stdby = "STBY",
	tgt_1 = "TARGET_1",
	tgt_2 = "TARGET_2",
	reset = "RESET",
}

local position_update_mode = {
	fix = "FIX",
	normal = "NORMAL",
	set = "SET",
}

local UpdateFlightPlans = function()
	local update_wheel_behaviour = GetJester().behaviors[UpdateJesterWheel]
	if update_wheel_behaviour ~= nil then
		update_wheel_behaviour:UpdateNavWheelInfo()
	end
end

function NavInteractions:SetNavigateInstance( navigate_in )
	if navigate_in ~= nil then
		Navigate = navigate_in
	else
		io.stderr:write("Nav instance is NIL\n")
	end
end

function NavInteractions.SelectNavCompMode(task, mode)
	return task:Click("Nav Panel Function", nav_function[mode], s(0.1), true )
end

function NavInteractions.SetPositionUpdateSwitch(task, mode)
	return task:Click("Nav Panel Position Update", position_update_mode[mode], s(0.1), true )
end

function NavInteractions.SetPositionCoords(task, latitude, longitude)
	return task:Click("Nav Panel Position Latitude", tostring(latitude))
			   :Click("Nav Panel Position Longitude", tostring(longitude))
end

function NavInteractions.SetTargetCoords(task, latitude, longitude)
	return task:Click("Nav Panel Target Latitude", tostring(latitude))
	           :Click("Nav Panel Target Longitude", tostring(longitude))
end

function NavInteractions.DivertWithTGT1(task, lat_long, silent)
	silent = silent or false
	if lat_long ~= nil then
		local delimiter = ";"
		local lat, lon = string.match(lat_long, "([^" .. delimiter .. "]+)" .. delimiter .. "([^" .. delimiter .. "]+)")
		if lat ~= nil and lon ~= nil then
			NavInteractions.SteerWithTGT1(task, lat, lon, silent)
			local memory = GetJester().memory
			memory:DisactivateFlightplan()
			if Navigate ~= nil then
				Navigate:ResetNavigationVariables()
			end
			local update_wheel_behaviour = GetJester().behaviors[UpdateJesterWheel]
			if update_wheel_behaviour ~= nil then
				update_wheel_behaviour:UpdateFlightplans()
			end
			UpdateFlightPlans()
			return task
		end
	end

	Log("CantDo: Divert TGT1 - LAT or LONG invalid")
	if not silent then
		task:CantDo()
	end
	return task
end

function NavInteractions.SteerWithTGT1(task, latitude, longitude, silent)
	silent = silent or false
	if not silent then
		task:Roger()
	end
	if Navigate ~= nil then
		Navigate:ResetNavigationVariables()
	end
	local update_wheel_behaviour = GetJester().behaviors[UpdateJesterWheel]
	if update_wheel_behaviour ~= nil then
		update_wheel_behaviour:UpdateFlightplans()
	end
	NavInteractions.SelectNavCompMode(task, "tgt_1")
	NavInteractions.SetTargetCoords(task, latitude, longitude)
	return task:Wait(s(0.1), { hands = true, voice = true })
	           :Say('misc/diversionsteeringset')
end

function NavInteractions.SetNewActiveTGT2Coords(task, latitude, longitude)
	NavInteractions.SetPositionUpdateSwitch(task, "normal")
	NavInteractions.SelectNavCompMode(task, "tgt_2")
	NavInteractions.SetTargetCoords(task, latitude, longitude)
	NavInteractions.SelectNavCompMode(task, "reset")
	task:Wait( s(0.2), { hands = true })
	NavInteractions.SelectNavCompMode(task, "tgt_2")

	if Navigate ~= nil then
		Navigate:ResetFlyoverVariables()
	end

	return task
end

function NavInteractions.PrepareNavFix(task, latitude, longitude)
	Log( "Preparing Nav Fix" )
	NavInteractions.SetPositionUpdateSwitch(task, "set")
	task:Wait( s(0.2), { hands = true })
	NavInteractions.SetPositionCoords(task, latitude, longitude)
	task:Wait( s(0.2), { hands = true })
	NavInteractions.SetPositionUpdateSwitch(task, "fix")
	return task
end

function NavInteractions.ReleaseNavFix(task)
	Log( "Releasing Nav Fix" )
	task:Wait( s(0.5), { voice = true })
	NavInteractions.SetPositionUpdateSwitch(task, "normal")
	task:Wait( s(0.2), { hands = true })
	return task
end

NavInteractions:Seal()
return NavInteractions
