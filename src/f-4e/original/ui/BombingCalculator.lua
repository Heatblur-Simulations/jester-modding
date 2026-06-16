ListenTo("enter_bombing_solution", "BombingCalculator", function(task, args)

	--Format: hb_send_proxy(delivery_mode, tgt_alt_dist, release_range, drag_coefficient, pullup_timer, loft_angle)
	local startIndex, endIndex, delivery_mode_raw, tgt_alt_dist_raw, release_range_raw, drag_coefficient_raw, pullup_timer_raw, loft_angle_raw = string.find(args, "(.+);(.+);(.+);(.+);(.+);(.+)")
	if not startIndex then
		-- Invalid format
		Log("CantDo: Enter Bombing Solution - Invalid data format")
		task:CantDo()
		return
	end


	local pullup_timer = s(tonumber(pullup_timer_raw))
	local loft_angle = deg(tonumber(loft_angle_raw))
	local is_pullup_invalid = pullup_timer < s(0) or pullup_timer > s(99.9)
	local is_low_loft_angle_invalid = (loft_angle < deg(0) or loft_angle > deg(89.9)) and delivery_mode_raw == "LOFT"
	local is_high_loft_angle_invalid = (loft_angle < deg(70) or loft_angle > deg(179.9)) and (delivery_mode_raw == "O-S" or delivery_mode_raw == "O-S-INST")
	local tgt_alt_dist = ft(tonumber(tgt_alt_dist_raw))
	local release_range = ft(tonumber(release_range_raw))
	local drag_coefficient = 100 * tonumber(drag_coefficient_raw) -- multiplication needed to convert to input

	if (is_pullup_invalid and not delivery_mode_raw == "Offset")
			or (is_low_loft_angle_invalid and not delivery_mode_raw == "Offset")
			or (is_high_loft_angle_invalid and not delivery_mode_raw == "Offset")
			or (drag_coefficient_raw == "" and delivery_mode_raw == "DT")
			or (drag_coefficient_raw == "" and delivery_mode_raw == "TGT-Find")
	then
		Log("CantDo: Enter Bombing Solution - Data has invalid values")
		task:CantDo()
		return
	end
	task:Roger()

	if delivery_mode_raw == "Loft" then
		task:Click("Pullup Timer", pullup_timer_raw)
		    :Click("Low Angle Knob", loft_angle_raw)
		    :Click("Target Alt/Range", tostring(tgt_alt_dist))
	elseif delivery_mode_raw == "O-S" or delivery_mode_raw == "O-S-INST" then
		task:Click("Pullup Timer", pullup_timer_raw)
		    :Click("High Angle Knob", loft_angle_raw)
		    :Click("Release Range", tostring(release_range))
		    :Click("Target Alt/Range", tostring(tgt_alt_dist))
	elseif delivery_mode_raw == "L" or delivery_mode_raw == "DL" then
		task:Click("Release Range", tostring(release_range))
		    :Click("Target Alt/Range", tostring(tgt_alt_dist))
	elseif delivery_mode_raw == "Offset" then
		local north_south_offset = ft(tonumber(pullup_timer_raw)) -- in case of Offset the last two sent values are the offset values therefore
		local east_west_offset = ft(tonumber(loft_angle_raw))
		task:Click("Release Range", tostring(release_range))
		    :Click("Target Alt/Range", tostring(tgt_alt_dist))
		    :Click("North/South Offset", tostring(north_south_offset))
		    :Click("East/West Offset", tostring(east_west_offset))
	elseif delivery_mode_raw == "DT" then
		task:Click("Drag Coefficient", drag_coefficient)
	elseif delivery_mode_raw == "TGT-Find" then
		task:Click("Drag Coefficient", drag_coefficient)
		    :Click("Target Alt/Range", tostring(tgt_alt_dist))
	end
end)

ListenTo("enter_release_advance", "BombingCalculator", function(task, release_advance_raw)
	if release_advance_raw == "" then
		Log("CantDo: Enter Release Advance - No Release Advance given")
		task:CantDo()
		return
	end
	local release_advance = s(tonumber(release_advance_raw))

	if release_advance > s(999) or release_advance < s(0) then
		Log("CantDo: Enter Release Advance - Value out of valid range")
		task:CantDo()
		return
	end

	task:Roger():Click("Release Advance", tostring(release_advance))

end)

ListenTo("enter_wrcs_agm", "BombingCalculator", function(task, target_alt)
	if target_alt == "" then
		Log("CantDo: Enter WRCS AGM - No value given")
		task:CantDo()
		return
	end
	local target_alt = ft(tonumber(target_alt))

	if target_alt < ft(0) then
		Log("CantDo: Enter WRCS AGM - Negative value")
		task:CantDo()
	end
	task:Roger():Click("Target Alt/Range", tostring(target_alt))
end)

ListenTo("jester_set_wrcs_drag", "BombingCalculator", function( task, drag )
    if drag == "" then
        return
    end

    local drag_number = tonumber( drag )

    task:Click("Drag Coefficient", tostring( drag_number ))
 end)

ListenTo("jester_set_wrcs_alt_range", "BombingCalculator", function( task, alt_range )
     if alt_range == "" then
         return
     end

     local tgt_alt_dist_number = tonumber( alt_range )

     task:Click("Target Alt/Range", tostring( tgt_alt_dist_number ))

end)

ListenTo("jester_set_wrcs_ew_dist", "BombingCalculator", function( task, dist )
     if dist == "" then
        return
     end

    local dist_number = tonumber( dist )

     task:Click("East/West Offset", tostring( dist_number ))

end)

ListenTo("jester_set_wrcs_ns_dist", "BombingCalculator", function( task, dist )
    if dist == "" then
         return
    end

    local dist_number = tonumber( dist )

    task:Click("North/South Offset", tostring( dist_number ))
end)

ListenTo("jester_set_wrcs_advance", "BombingCalculator", function( task, release_advance )
   if release_advance == "" then
       return
   end

    local release_advance_number = tonumber( release_advance )

    task:Click("Release Advance", tostring( release_advance_number ))

end)

ListenTo("jester_set_wrcs_range", "BombingCalculator", function( task, release_range )
    if release_range == "" then
        return
    end

    local release_range_number = tonumber( release_range )

    task:Click("Release Range", tostring( release_range_number ))
end)
