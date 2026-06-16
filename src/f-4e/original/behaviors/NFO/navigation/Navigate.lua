---// Copyright (c) 2024 Heatblur Simulations. All rights reserved.

local CapTimeDialog = require('tasks.navigation.CapTimeDialog')
local Class = require('base.Class')
local Behavior = require('base.Behavior')
local Urge = require('base.Urge')
local NavInteractions = require('tasks.navigation.NavInteractions')
local PerformNavFix = require('tasks.navigation.PerformNavFix')
local SwitchToNextTurnPoint = require('tasks.navigation.SwitchToNextTurnPoint')
local StressReaction = require('base.StressReaction')
local SayTask = require('tasks.common.SayTask')
local SwitchTask = require('tasks.common.SwitchTask')
local Task = require('base.Task')
local Utilities = require('base.Utilities')
local Waypoint = require('base.Waypoint')

local default_distance = NM(20)
local default_change_threshold = NM(2)
local default_interval = s(30)
local bdhi_distance_meter = '/Bearing Distance Heading Indicator/BDHI Meter'
local nav_comp_relay = '/Navigation Computer Relay'

local Navigate = Class(Behavior)
Navigate.distance = default_distance
Navigate.flying_towards_wpt = true
Navigate.waypoint = nil
Navigate.reported_15NM = false
Navigate.reported_10NM = false
Navigate.reported_5NM = false
Navigate.reported_2NM = false

Navigate.cap_arrive_reported = false
Navigate.cap_10min_left_reported = false
Navigate.cap_5min_left_reported = false
Navigate.cap_time_left = s(0) --0->not initialized, minus values->time left
Navigate.cap_time_set = false
Navigate.cap_qa_asked_time = s(-1000)

Navigate.position_fix_awaiting = false
Navigate.min_flyover_distance = NM(10)
Navigate.fix_awaiting_time = s(0)
Navigate.observing_flyover = false
Navigate.flyover_timer = s(0)
Navigate.flyover_time_threshold = s(20)

local last_change_waypoint_threshold_time = s(10)
local last_change_waypoint_prepare_fix_threshold_time = s(4)
local fix_awaiting_time_threshold = s(2)
local fix_successful_distance_threshold = NM(0.15)
local resetting_flags_distance_threshold = NM(2)

local cap_time_low_reporting_threshold = s(30)
local cap_qe_time_interval = min(2)

function Navigate:GetDistance()
	local memory = GetJester().memory
	local waypoint = memory:GetActiveWaypoint()
	if waypoint == nil then
		return m(0)
	end
	local wpt_type = waypoint:GetSpecialWaypointType()

	if not wpt_type then
		io.stderr:write("Invalid WPT Type\n")
	end

	if wpt_type == "VIP" or wpt_type == "VIP_SILENT" then
		local function CalculateDistance(lat1, lon1, lat2, lon2)
			local radius = 6371 * 1000 -- Earth's radius in meters
			local dLat = lat2 - lat1
			local dLon = lon2 - lon1
			local lLat = dLat * radius
			local lLon = dLon * radius * math.cos(lat2)
			local distance = math.sqrt( lLat * lLat + lLon * lLon )
			return m( distance )
		end

		local latitude = jester.awareness:GetObservation("latitude")
		local longitude = jester.awareness:GetObservation("longitude")
		if latitude and latitude.value and longitude and longitude.value then
			local distance = CalculateDistance(latitude.value, longitude.value, math.rad(waypoint.latitude), math.rad(waypoint.longitude))
			return distance
		else
			io.stderr:write("Failed to retrieve latitude or longitude observations\n")
			return m(0)
		end
	else
		local property = GetProperty(bdhi_distance_meter, 'Distance Indication')
		if property and property:IsValid() then
			return property.value
		else
			io.stderr:write("Navigate BDHI Distance property invalid\n")
		end
	end
end

function Navigate:GetFlyingTowardsWpt()
	return self.flying_towards_wpt
end

function Navigate:GetIsInOffsetMode()
	local property = GetProperty(nav_comp_relay, 'Target Insert Signal')
	if property and property:IsValid() then
		return property.value
	else
		io.stderr:write("Navigate Target Insert Signal property invalid\n")
		return false
	end
end

function Navigate:TrySwitchingWaypoint()
	if self.waypoint and self.waypoint:GetHoldAt() == false then
		local task = SwitchToNextTurnPoint:new()
		GetJester():AddTask(task)
		GetJester().memory:UpdateLastChangedWaypointTime()
		return { task }
	end
end

function Navigate:Constructor()
	Behavior.Constructor(self)
	NavInteractions:SetNavigateInstance(self)
	SwitchToNextTurnPoint:SetNavigateInstance(self)

	self.initialized = false

	local check_distance = function()
		local cockpit = GetJester():GetCockpit()
		local memory = GetJester().memory

		local bdhi_mode = cockpit:GetManipulator("BDHI Mode"):GetState()
		if bdhi_mode ~= nil then
			if bdhi_mode ~= "NAV_COMP" then
				memory:UpdateLastChangedWaypointTime()
				local task = SwitchTask:new("BDHI Mode", "NAV_COMP")
				GetJester():AddTask(task)
				return { task }
			end
		end

		self.waypoint = memory:GetActiveWaypoint()
		local new_distance = self:GetDistance()
		self.flying_towards_wpt = new_distance < self.distance
		self.distance = new_distance

		local function CheckWaypointForSwitchingAndReporting( )
			--Log("Check WPT for switching") left for debugging
			local current_time = Utilities.GetTime().mission_time:ConvertTo(s)

			if self.waypoint and current_time then
				local wpt_type = self.waypoint:GetSpecialWaypointType()
				local is_change_before_wpt = wpt_type == "DEFAULT" or ( wpt_type == "CAP" and not memory:GetActiveWaypointHasCAPCounterpart() )
				local is_change_at_flyover_wpt = self:GetIsChangeWptAtFlyoverWptType( wpt_type )
				local is_report_at_wpt = self:GetIsReportAtFlyoverWptType( wpt_type )

				if ( (current_time - memory:GetLastChangedWaypointTime()) > last_change_waypoint_threshold_time and self.distance < default_change_threshold ) then
					if is_change_before_wpt then
						return self:TrySwitchingWaypoint( )
					elseif ( is_change_at_flyover_wpt or is_report_at_wpt ) and not self.observing_flyover and self.flying_towards_wpt then
						self.observing_flyover = true
						--Log( "Observing Flyover" )
						local ground_speed = jester.awareness:GetObservation("ground_speed")
						if ground_speed and ground_speed > kt(0) then
							self.flyover_time_threshold = default_change_threshold / ground_speed;
							--Log( string.format( "Flyover Time: %.2f s", self.flyover_time_threshold.value ) )
						end
					end
				end
			end
		end

		local function MonitorPrepareNavFix( )
			local current_time = Utilities.GetTime().mission_time:ConvertTo(s)

			if self.distance < default_change_threshold and not self.position_fix_awaiting
					and self.flying_towards_wpt
					and (current_time - memory:GetLastChangedWaypointTime()) > last_change_waypoint_prepare_fix_threshold_time then
				local active_waypoint = memory:GetActiveWaypoint()
				if active_waypoint ~= nil then
					local task = Task:new()
					GetJester():AddTask(NavInteractions.PrepareNavFix( task, active_waypoint.latitude, active_waypoint.longitude ))
					self.position_fix_awaiting = true
					return { task }
				end
			end
		end

		local function CheckForCAPStateUpdate( is_cap )
			local is_capping = memory:GetIsCapping()
			if is_cap then
				if memory:GetActiveWaypointHasCAPCounterpart() then
					if not is_capping then
						memory:SetIsCapping( true )
					end
				elseif is_capping then
					memory:SetIsCapping( false )
				end
			else
				if is_capping then
					memory:SetIsCapping( false )
				end
			end
		end

		local function CheckReportingDistanceToWaypoint(  )
			local current_time = Utilities.GetTime().mission_time:ConvertTo(s)

			if self.waypoint then
				local wpt_type = self.waypoint:GetSpecialWaypointType()

				local phrases = {
					IP = { ['15'] = 'misc/ipfifteenmiles', ['10'] = 'misc/iptenmiles', ['5'] = 'misc/ipfivemiles', ['2'] = 'misc/iptwomiles' },
					VIP = { ['10'] = 'misc/fixtenmiles', ['5'] = 'misc/fixfivemiles' },
					TARGET = { ['10'] = 'misc/targettenmiles', ['5'] = 'misc/targetfivemiles', ['2'] = 'misc/targettwomiles' },
					FENCE_IN = { ['5'] = 'misc/fenceinfivemiles' },
					FENCE_OUT = { ['5'] = 'misc/fenceoutfivemiles' },
					HOMEBASE = { ['2'] = 'misc/homebase' },
					CAP = { ['2'] = 'misc/capstationarrive' },--report just once when capping
				}

				for distance, phrase in pairs(phrases[wpt_type] or {}) do
					if self.distance < NM(tonumber(distance) + 0.6) and self.distance >= NM(tonumber(distance) - 0.5)
							and self.flying_towards_wpt
							and not self['reported_' .. distance .. 'NM']
							and (current_time - memory:GetLastChangedWaypointTime()) > last_change_waypoint_threshold_time then
						if wpt_type == "CAP" then
							if self.cap_arrive_reported then
								return
							else
								self.cap_arrive_reported = true
							end
						end
						self['reported_' .. distance .. 'NM'] = true
						local report_task = SayTask:new(phrase)
						GetJester():AddTask(report_task)
						return { report_task }
					end
				end

				-- Resetting flags
				local all_distances = {'15', '10', '5', '2'}
				for _, distance in ipairs(all_distances) do
					local nm_distance = NM(tonumber(distance))
					if self.distance > nm_distance + resetting_flags_distance_threshold or self.distance < nm_distance - resetting_flags_distance_threshold then
						local flag_key = 'reported_' .. distance .. 'NM'
						if self[flag_key] then
							self[flag_key] = false
						end
					end
				end

			end
		end

		if self.distance and self.waypoint and not self:GetIsInOffsetMode() then
			local wpt_type = self.waypoint:GetSpecialWaypointType()
			local report_task = CheckReportingDistanceToWaypoint()
			if report_task then return report_task end
			CheckForCAPStateUpdate( wpt_type == "CAP" )
			if wpt_type == "VIP" or wpt_type == "VIP_SILENT" then
				return MonitorPrepareNavFix( )
			else
				return CheckWaypointForSwitchingAndReporting(  )
			end
		end
	end

	self.check_distance_urge = Urge:new({
		time_to_release = s(10),
		on_release_function = check_distance,
		stress_reaction = StressReaction.ignorance,
	})
	self.check_distance_urge:Restart()
end

function Navigate:Tick()
	local memory = GetJester().memory

	if not self.initialized then
		self:Initialize()
	end

	if self.check_distance_urge and memory:GetActiveWaypoint() ~= nil then
		if self.distance < NM(5) then
			self.check_distance_urge:SetGainRateMultiplier(5)
		elseif self.distance < default_distance then
			self.check_distance_urge:SetGainRateMultiplier(2)
		else
			self.check_distance_urge:SetGainRateMultiplier(0.5)
		end

		self.check_distance_urge:Tick()
	end

	if self.waypoint then
		local wpt_type = self.waypoint:GetSpecialWaypointType()
		if ( wpt_type == "VIP" or wpt_type == "VIP_SILENT" ) and self.position_fix_awaiting then
			self:MonitorNavFix( )
		end
		if memory:GetIsCapping() then
			self:UpdateCapTime( )
		end

		if self.observing_flyover then
			self:ObserveFlyover( )
		end
	end
end

function Navigate:Initialize()
	--Initialize nav2 coords as active TGT
	-- todo move this initialization to the checklist or somewhere
	local memory = GetJester().memory
	local active_waypoint = memory:GetActiveWaypoint()
	if active_waypoint ~= nil then
		GetJester():AddTask(NavInteractions.SetNewActiveTGT2Coords( Task:new(), active_waypoint.latitude, active_waypoint.longitude ))
		self.initialized = true
		memory:UpdateLastChangedWaypointTime()
	end
end

function Navigate:MonitorNavFix()
	self.fix_awaiting_time = self.fix_awaiting_time + Utilities.GetTime().dt
	self:ObserveClosing()

	if not self.flying_towards_wpt and self.fix_awaiting_time > fix_awaiting_time_threshold then
		local fix_successful = self.min_flyover_distance < fix_successful_distance_threshold
		self.position_fix_awaiting = false
		Log( string.format( "Finishing Nav fix. Distance: %.2f m", self.min_flyover_distance.value ) )
		self:ResetFlyoverMinDistance()
		self.fix_awaiting_time = s(0)

		local finish_fix_task = PerformNavFix:new( fix_successful )
		GetJester():AddTask(finish_fix_task)
		if fix_successful then
			local switch_wpt_task = self:TrySwitchingWaypoint( )
		end
	end
end

function Navigate:UpdateCapTime()
	local current_time = Utilities.GetTime().mission_time:ConvertTo(s)
	local memory = GetJester().memory
	if self.cap_time_set then
		--Log("CAP Time left: " .. tostring(self.cap_time_left.value))
		self.cap_time_left = self.cap_time_left - Utilities.GetTime().dt
		if current_time and (current_time - memory:GetLastChangedWaypointTime()) > last_change_waypoint_threshold_time then
			-- report 10min and 5 min CAP left
			if self.cap_time_left < min(10) and self.cap_time_left > min(10) - cap_time_low_reporting_threshold and not self.cap_10min_left_reported then
				local task = SayTask:new("misc/captenminremain")
				GetJester():AddTask(task)
				self.cap_10min_left_reported = true
			end
			if self.cap_time_left < min(5) and self.cap_time_left > min(5) - cap_time_low_reporting_threshold and not self.cap_5min_left_reported then
				local task = SayTask:new("misc/capfiveminremain")
				GetJester():AddTask(task)
				self.cap_5min_left_reported = true
			end
		end
	elseif current_time
		and current_time > self.cap_qa_asked_time + cap_qe_time_interval
		and (current_time - memory:GetLastChangedWaypointTime()) > last_change_waypoint_threshold_time
		and self.flying_towards_wpt
		and self:GetDistance() < NM(5) then --ask QA
			local task = CapTimeDialog:new()
			GetJester():AddTask(task)
			self.cap_qa_asked_time = current_time
	end
end

function Navigate:ObserveClosing()
	local new_distance = self:GetDistance()
	self.flying_towards_wpt = new_distance <= self.distance
	self.distance = new_distance

	if self.distance < self.min_flyover_distance then
		self.min_flyover_distance = self.distance
		--Log( string.format( "Closing. Distance: %.2f", self.distance.value ) )
	end
end

function Navigate:ObserveFlyover()
	self.flyover_timer = self.flyover_timer + Utilities.GetTime().dt --is actually needed? test it
	self:ObserveClosing()
	if not self.flying_towards_wpt then
		self:ResetFlyoverMinDistance()
		self.flyover_timer = s(0)
		self.observing_flyover = false
		--Log( "Finish flyover- change wpt" )
		self.flyover_time_threshold = s(20)

		local wpt_type = self.waypoint:GetSpecialWaypointType()

		if self:GetIsReportAtFlyoverWptType( wpt_type ) then
			local report_phrase = {
				["FENCE_IN"] = "misc/fencein",
				["FENCE_OUT"] = "misc/fenceout"
			}
			local task = SayTask:new(report_phrase[wpt_type])
			task:Wait(s(0.5), { voice = true })
			GetJester():AddTask(task)
		end

		if self:GetIsChangeWptAtFlyoverWptType( wpt_type ) then
			local switch_wpt_task = self:TrySwitchingWaypoint( )
		end

	end
end

function Navigate:ResetFlyoverMinDistance()
	self.min_flyover_distance = NM(10)
end

function Navigate:ResetFlyoverVariables()
	self.position_fix_awaiting = false
	self.min_flyover_distance = NM(10)
	self.fix_awaiting_time = s(0)
	self.observing_flyover = false
	self.flyover_timer = s(0)
	self.flyover_time_threshold = s(20)
	Log("Flyover Variables reset")
end

function Navigate:ResetNavigationVariables()
	self:ResetFlyoverVariables()
	self:ResetCAPVariables()
end

function Navigate:ResetCAPVariables()
	Navigate.cap_arrive_reported = false
	self.cap_time_left = s(0)
	self.cap_time_set = false
	self.cap_5min_left_reported = false
	self.cap_10min_left_reported = false
	self.cap_qa_asked_time = s(-1000)
	Log("CAP Variables reset")
end

function Navigate:GetIsReportAtFlyoverWptType(type)
	return type == "FENCE_IN" or type == "FENCE_OUT"
end

function Navigate:GetIsChangeWptAtFlyoverWptType(type)
	local memory = GetJester().memory
	if type == "CAP" then
		return memory:GetActiveWaypointHasCAPCounterpart()
	else
		return type == "IP" or type == "TARGET" or type == "FENCE_IN" or type == "FENCE_OUT"
	end
end

function Navigate:SetCAPTimeLeft(time)
	self.cap_time_left = time
	self.cap_time_set = true
	Log("CAP time set: " .. tostring(self.cap_time_left.value))
end

function Navigate:GetCAPTimeHasLeft()
	return self.cap_time_left < s(0)
end

local SetJesterCapTime = function(minutes, phraseKey)
	local navigate_behaviour = GetJester().behaviors[Navigate]
	if navigate_behaviour ~= nil then
		navigate_behaviour:SetCAPTimeLeft( min(minutes) )
		local task = SayTask:new(phraseKey)
		GetJester():AddTask(task)
	else
		local task = Task:new():CantDo()
		GetJester():AddTask(task)
		Log("CantDo: set CAP Time - we are not navigating")
	end
end

ListenTo("cap_15min", "Navigate", function() SetJesterCapTime(15, 'misc/capfifteenminutes') end)
ListenTo("cap_30min", "Navigate", function() SetJesterCapTime(30, 'misc/capthirtyminutes') end)
ListenTo("cap_45min", "Navigate", function() SetJesterCapTime(45, 'misc/capfortyfiveminutes') end)
ListenTo("cap_60min", "Navigate", function() SetJesterCapTime(60, 'misc/capsixtyminutes') end)

ListenTo("proxy_cap_time", "Navigate", function(task, time)
	local time_as_number = tonumber(time)
	if time_as_number == nil then
		Log("Proxy CAP time error: Invalid time provided")
		return
	end

	local navigate_behaviour = GetJester().behaviors[Navigate]
	if navigate_behaviour == nil then
		Log("Proxy CAP time error: Navigate behavior not found")
		return
	end

	-- Check if the active waypoint is a CAP waypoint and has a CAP pair
	local memory = GetJester().memory
	local active_waypoint = memory:GetActiveWaypoint()

	if active_waypoint and active_waypoint:GetSpecialWaypointType() == "CAP" then
		local active_flightplan_no = memory:GetActiveFlightPlanNumber()
		local active_waypoint_no = memory:GetActiveWaypointNumber()
		local cap_counterpart = memory:GetCAPCounterpartWptNo(active_flightplan_no, active_waypoint_no)

		if cap_counterpart then
			-- Set CAP time if the CAP pair exists
			navigate_behaviour:SetCAPTimeLeft( min( time_as_number ) )
		else
			Log("Proxy CAP time error: CAP waypoint does not have a CAP pair")
		end
	else
		Log("Proxy CAP time error: Current waypoint is not a CAP waypoint")
	end
end)

Navigate:Seal()
return Navigate
