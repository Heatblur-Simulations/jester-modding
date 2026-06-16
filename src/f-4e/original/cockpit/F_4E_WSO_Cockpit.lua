---// F-4E_WSO_Cockpit.lua
---// Copyright (c) 2023 Heatblur Simulations. All rights reserved.
---
local Class = require('base.Class')
local Cockpit = require('cockpit.Cockpit')

local F_4E_WSO_Cockpit = Class(Cockpit)

local default_simple_gauge_time_to_read = s(0.25)

function F_4E_WSO_Cockpit:AddGauges()
	self:AddGauge("Airspeed Indicator",
			{
				observation_name = 'IAS',
				connector = Connector:new('PNT_RIO_MACHANDAIRSPEED_KNOB'),
				property = GetProperty('/WSO Mach And Airspeed Indicator/Gauge/Airspeed Needle Friction Component', 'Output'),
				precision = kt(5),
				time_to_read = default_simple_gauge_time_to_read
			})
	self:AddGauge("True Airspeed Indicator",
			{
				observation_name = 'TAS',
				connector = Connector:new('PNT_WSO_COOLING_RESET_BUTTON'),
				property = GetProperty('/WSO True Airspeed Indicator', 'Target TAS'),
				precision = kt(2),
				time_to_read = default_simple_gauge_time_to_read
			})
	-- DefaultThreePositionSwitchEnum: positive, zero, negative
	self:AddGauge("Generator Switch Left",
			{
				observation_name = 'gen_switch_left',
				connector = Connector:new('PNT_PITOT_HEAT_SWITCH'),
				property = GetProperty('/Pilot Cockpit/Pilot Right Console/Generator Control Switches/Left Generator Switch', 'State'),
				time_to_read = default_simple_gauge_time_to_read
			})
	self:AddGauge("Generator Switch Right",
			{
				observation_name = 'gen_switch_right',
				connector = Connector:new('PNT_PITOT_HEAT_SWITCH'),
				property = GetProperty('/Pilot Cockpit/Pilot Right Console/Generator Control Switches/Right Generator Switch', 'State'),
				time_to_read = default_simple_gauge_time_to_read
			})
	self:AddGauge("Pilot Canopy",
			{
				observation_name = 'pilot_canopy_open',
				connector = Connector:new('PNT_PILOT_CANOPY_HANDLE'),
				property = GetProperty('/Canopies/Pilot Canopy', 'Canopy Control Handle Position'),
				time_to_read = default_simple_gauge_time_to_read
			})
	self:AddGauge("WSO Canopy",
			{
				observation_name = 'wso_canopy_open',
				connector = Connector:new('PNT_PILOT_CANOPY_HANDLE'),
				property = GetProperty('/Canopies/Copilot Canopy', 'Canopy Control Handle Position'),
				time_to_read = default_simple_gauge_time_to_read
			})
	-- Hacky way to detect that the ins is aligned
	self:AddGauge("INS aligned",
			{
				observation_name = 'ins_alignment_state',
				connector = Connector:new('PNT_INS_ALIGN_MODE_SWITCH'),
				property = GetProperty('/INS ASN-63/Mode Logic', 'INS State'),
				time_to_read = default_simple_gauge_time_to_read
			})
	--INS Damaged
	self:AddGauge("INS damaged",
			{
				observation_name = 'ins_damaged',
				connector = Connector:new('PNT_INS_ALIGN_MODE_SWITCH'),
				property = GetProperty('/INS ASN-63/Mode Logic', 'Damaged'),
				time_to_read = default_simple_gauge_time_to_read
			})
	self:AddGauge("WSO RWR System Power",
			{
				observation_name = 'wso_rwr_system_power',
				connector = Connector:new('PNT_INS_ALIGN_MODE_SWITCH'),
				property = GetProperty('/RWR AN_ALR_46/WSO Lights/System Power Lamp', 'Powered'),
				time_to_read = default_simple_gauge_time_to_read
			})
	-- External Ground Power connection (a bit hacky)
	self:AddGauge("Ground Crew Power",
			{
				observation_name = 'ground_crew_external_power',
				connector = Connector:new('PNT_WSO_GROUND_POWER_SWITCH'),
				property = GetProperty('/Ground Crew/Ground Power Unit', 'Powered'),
				time_to_read = default_simple_gauge_time_to_read
			})
	self:AddGauge("Bus Power",
			{
				observation_name = 'bus_power',
				connector = Connector:new('PNT_PITOT_HEAT_SWITCH'),
				property = GetProperty('/TACAN/Power Supply', 'Is Enough Power'),
				time_to_read = default_simple_gauge_time_to_read
			})
	self:AddGauge("Left Engine Master Switch",
			{
				observation_name = 'left_engine_master_switch',
				connector = Connector:new('PNT_PITOT_HEAT_SWITCH'),
				property = GetProperty('/Pilot Cockpit/Pilot Left Console/Engine Control Panel/Left Engine Master Switch', 'State'),
				time_to_read = default_simple_gauge_time_to_read
			})
	self:AddGauge("Right Engine Master Switch",
			{
				observation_name = 'right_engine_master_switch',
				connector = Connector:new('PNT_PITOT_HEAT_SWITCH'),
				property = GetProperty('/Pilot Cockpit/Pilot Left Console/Engine Control Panel/Right Engine Master Switch', 'State'),
				time_to_read = default_simple_gauge_time_to_read
			})
	self:AddGauge("Chaff Counter",
			{
				observation_name = 'chaff_counter',
				connector = Connector:new('WSO_Ale40_Chaff_knob_help'),
				property = GetProperty('/WSO Cockpit/WSO Left Console/AN_ALE-40 CCU', 'Chaff Counter'),
				time_to_read = default_simple_gauge_time_to_read
			})
	self:AddGauge("Flare Counter",
			{
				observation_name = 'flare_counter',
				connector = Connector:new('WSO_Ale40_Flare_knob_help'),
				property = GetProperty('/WSO Cockpit/WSO Left Console/AN_ALE-40 CCU', 'Flare Counter'),
				time_to_read = default_simple_gauge_time_to_read
			})

	self:AddGauge("Flaps Indicator",
			{
				observation_name = 'flaps_indicator',
				connector = Connector:new('WSO_Ale40_Flare_knob_help'),
				property = GetProperty('/WSO Cockpit/WSO Front Panel/Landing Gear Slats Flaps Indicator Panel/Flaps Indicator', 'Indicator Position'),
				time_to_read = default_simple_gauge_time_to_read
			})
end

function F_4E_WSO_Cockpit:AddManipulators()
	-- radar_panel::State::Mode: BST, RDR, MAP, AIR_GND, BEACON, TV
	self:AddManipulator("Radar Mode", {component_path = "/Radar Panel/Radar Mode Knob"})
	-- radar_panel::State::Power: OFF, TEST, STBY, OPER, EMER
	self:AddManipulator("Radar Power", {component_path = "/Radar Panel/Radar Power Knob"})
	-- radar_panel::State::Aspect: tail, aft, fwd, nose, wide
	self:AddManipulator("Radar Target Aspect", {component_path = "/Radar Panel/Radar Aspect Knob"})
	-- radar_panel::State::ScanType: VI, B_NAR, B_WIDE, PPI_WIDE, PPI_NAR
	self:AddManipulator("Radar Scan Type", {component_path = "/Radar Panel/Radar Scan Type Knob"})
	-- radar_panel::State::Range: RNG_5_NM, RNG_10_NM, RNG_25_NM, RNG_50_NM, RNG_100_NM, RNG_200_NM
	self:AddManipulator("Radar Range", {component_path = "/Radar Panel/Radar Range Knob"})
	-- radar_panel::State::Maneuver: low, high
	self:AddManipulator("Radar Maneuver", {component_path = "/Radar Panel/Radar Maneuver Knob"})
	-- radar_panel::State::Bars: BARS_2, BARS_1
	self:AddManipulator("Radar Bars", {component_path = "/Radar Panel/Radar Bars Knob"})
	-- float: 0.0 to 0.01
	self:AddManipulator("Radar Gain Fine", {component_path = "/Radar Panel/Radar Gain Fine Knob"})
	-- float: 0.0 to 1.0
	self:AddManipulator("Radar Gain Coarse", {component_path = "/Radar Panel/Radar Gain Course Knob"})
	-- DefaultSwitchEnum: ON, OFF
	self:AddManipulator("A2A Button", {component_path = "/Radar Panel/Air to Air Button Lamp/Button"})

	-- DefaultSwitchEnum: ON, OFF
	self:AddManipulator("RWR BIT Button", {component_path = "/RWR AN_ALR_46/WSO Buttons/System Test"})

	-- DefaultSwitchEnum: ON, OFF
	self:AddManipulator("Ejection Command Selector", {component_path = "/Ejection Seat System/Command Selector Valve"})

	-- ChaffMode: OFF, SGL, MULT, PROG
	self:AddManipulator("Chaff Mode", {component_path = "/WSO Cockpit/WSO Left Console/AN_ALE-40 CCU/Chaff Mode Knob"})
	-- FlareMode: OFF, SGL, PROG
	self:AddManipulator("Flare Mode", {component_path = "/WSO Cockpit/WSO Left Console/AN_ALE-40 CCU/Flare Mode Knob"})
	-- DefaultSwitchEnum: ON, OFF
	self:AddManipulator("Ripple Switch", {component_path = "/WSO Cockpit/WSO Left Console/AN_ALE-40 CCU/Ripple Switch"})
	-- DefaultSwitchEnum: ON, OFF
	self:AddManipulator("Dispense Button", {component_path = "/WSO Cockpit/WSO Left Console/AN_ALE-40 CCU/Dispense Button"})

	-- DefaultSwitchEnum: ON, OFF
	self:AddManipulator("Comm Command", {component_path = "/WSO Cockpit/WSO Left Console/Comm Nav CMD Panel/COMM CMD Pushbutton"})
	-- HundredsKnobMode: T, TWO, THREE, A
	self:AddManipulator("Radio Freq 1xx.xxx", {component_path = "/WSO Cockpit/WSO Left Console/Radio Panel/Frequency Selector/Frequency Hundreds and Mode Knob"})
	-- short: 0 to 9
	self:AddManipulator("Radio Freq x1x.xxx", {component_path = "/WSO Cockpit/WSO Left Console/Radio Panel/Frequency Selector/Frequency Tens Knob"})
	self:AddManipulator("Radio Freq xx1.xxx", {component_path = "/WSO Cockpit/WSO Left Console/Radio Panel/Frequency Selector/Frequency Ones Knob"})
	self:AddManipulator("Radio Freq xxx.1xx", {component_path = "/WSO Cockpit/WSO Left Console/Radio Panel/Frequency Selector/Frequency Decimal Ones Knob"})
	-- DecHundredsKnobMode: ZERO, TWENTY_FIVE, FIFTY, SEVENTY_FIVE
	self:AddManipulator("Radio Freq xxx.x11", {component_path = "/WSO Cockpit/WSO Left Console/Radio Panel/Frequency Selector/Frequency Decimal Hundreds Knob"})
	-- OperationMode: OFF, TR_ADF, TR_G_ADF, ADF_G_CMD, ADF_G, GUARD_ADF
	self:AddManipulator("Radio Mode", {component_path = "/WSO Cockpit/WSO Left Console/Radio Panel/Mode Selector Knob"})
	-- FrequencyMode: PRESET, MANUAL
	self:AddManipulator("Radio Freq Mode", {component_path = "/WSO Cockpit/WSO Left Console/Radio Panel/Frequency Mode Knob"})
	self:AddManipulator("Radio Comm Chan", {component_path = "/WSO Cockpit/WSO Left Console/Radio Panel/COMM Channel Knob"})
	--from 1 to 18
	self:AddManipulator("Radio Aux Chan", {component_path = "/WSO Cockpit/WSO Left Console/Radio Panel/AUX Channel Knob"})
	--from 1 to 20

	--PositionUpdateSwitchState: FIX, NORMAL, SET
	self:AddManipulator("Nav Panel Position Update", {component_path = "/Navigation Computer/Navigation Computer ASN 46A Mechanical Panel/Navigation Computer Position Update Switch"})
	-- FunctionSelectorKnobMode: OFF, STBY, TARGET_1, TARGET_2, RESET
	self:AddManipulator("Nav Panel Function", {component_path = "/Navigation Computer/Navigation Computer ASN 46A Mechanical Panel/Navigation Computer Function Selector Knob"})
	-- Degree: -180 to 180
	self:AddManipulator("Nav Panel Target Longitude", {component_path = "/Navigation Computer/Navigation Computer ASN 46A Mechanical Panel/Navigation Computer Target Longitude Knob"})
	self:AddManipulator("Nav Panel Position Longitude", {component_path = "/Navigation Computer/Navigation Computer ASN 46A Mechanical Panel/Navigation Computer Longitude Set Mechanical System"})
	-- Degree: -90 to 90
	self:AddManipulator("Nav Panel Target Latitude", {component_path = "/Navigation Computer/Navigation Computer ASN 46A Mechanical Panel/Navigation Computer Target Latitude Knob"})
	self:AddManipulator("Nav Panel Position Latitude", {component_path = "/Navigation Computer/Navigation Computer ASN 46A Mechanical Panel/Navigation Computer Lattitude Set Mechanical System"})

	-- OperationMode: OFF, REC, TR, AA_REC, AA_TR
	self:AddManipulator("TACAN Function", {component_path = "/WSO Cockpit/WSO Left Console/TACAN Panel/Function Selector Knob"})
	-- from 0 to 12
	self:AddManipulator("TACAN Channel Tens", {component_path = "/WSO Cockpit/WSO Left Console/TACAN Panel/Channel Knob Tens"})
	-- from 0 to 9
	self:AddManipulator("TACAN Channel Ones", {component_path = "/WSO Cockpit/WSO Left Console/TACAN Panel/Channel Knob Ones"})
	-- XYMode: X, Y
	self:AddManipulator("TACAN Band", {component_path = "/WSO Cockpit/WSO Left Console/TACAN Panel/Channel Knob XY"})

	-- SwitchState: NAV_COMP, VOR_TAC, UHF_ADF_TACAN
	self:AddManipulator("BDHI Mode", {component_path = "/Navigation Mode Selector Switch/Navigation Mode Selector Switch"})

	-- EcmSystem::Mode: OFF, STBY, XMIT_1, XMIT_2, BOTH
	self:AddManipulator("ECM Mode Left", {component_path = "/WSO Cockpit/WSO Front Panel/ECM System Left/ECM Mode Knob"})
	self:AddManipulator("ECM Mode Right", {component_path = "/WSO Cockpit/WSO Front Panel/ECM System Right/ECM Mode Knob"})

	-- DefaultSwitchEnum: ON, OFF
	self:AddManipulator("Allowed to Talk", {component_path = "/Jester/Allowed to Talk"})

	-- DefaultSwitchEnum: ON, OFF
	self:AddManipulator("Laser Code 1xxx Button", {component_path = "/EO TGT Designator System/Laser Coder Control/Laser Code Thousands Button"})
	self:AddManipulator("Laser Code x1xx Button", {component_path = "/EO TGT Designator System/Laser Coder Control/Laser Code Hundreds Button"})
	self:AddManipulator("Laser Code xx1x Button", {component_path = "/EO TGT Designator System/Laser Coder Control/Laser Code Tens Button"})
	self:AddManipulator("Laser Code xxx1 Button", {component_path = "/EO TGT Designator System/Laser Coder Control/Laser Code Ones Button"})
	self:AddManipulator("Laser Code Enter", {component_path = "/EO TGT Designator System/Laser Coder Control/Enter No Go Button Lamp/Button"})

	-- INSModeKnob: OFF, STBY, ALIGN, NAV
	self:AddManipulator("INS Mode Knob", {component_path = "/INS ASN-63/Control Set/Power Control Knob"})
	-- INSAlignModeSwitch: DefaultSwitchEnum: ON, OFF
	self:AddManipulator("Align Mode Knob", {component_path = "/INS ASN-63/Control Set/Align Mode Switch"})

	self:AddManipulator("Equip Helmet", {component_path = "/WSO Character Input/Helmet On or Off Switch"})

	-- WSO Canopy: ON, OFF (Off is closing the canopy, ON is opening it)
	self:AddManipulator("WSO Canopy Handle", {component_path = "/Canopies/Copilot Canopy/Canopy Control Handle"})

	--WSO RWR System Power Button: ON, OFF
	self:AddManipulator("WSO RWR System Power Button", {component_path = "/RWR AN_ALR_46/WSO Buttons/System Power"})
	-- DefaultSwitchEnum: ON, OFF
	self:AddManipulator("Video Select", {component_path = "/WSO Cockpit/WSO Front Panel/Video Selector/Video Select Button Lamp/Button"})

	-- DefaultSwitchEnum: ON, OFF
	self:AddManipulator("TGP Stow", {component_path = "/EO TGT Designator System/Target Designator Set Control/Stow Button Lamp/Button"})
	self:AddManipulator("TGP Laser Ready", {component_path = "/EO TGT Designator System/Target Designator Set Control/Laser Ready Button Lamp/Button"})
	self:AddManipulator("TGP Power On", {component_path = "/EO TGT Designator System/Target Designator Set Control/Power On Button Lamp/Button"})
	self:AddManipulator("TGP BIT", {component_path = "/EO TGT Designator System/Target Designator Set Control/Bit Button"})
	self:AddManipulator("TGP WRCS Out", {component_path = "/EO TGT Designator System/Target Designator Set Control/WRCS Out Button Lamp/Button"})
	self:AddManipulator("TGP INS Out", {component_path = "/EO TGT Designator System/Target Designator Set Control/Overheat INS Out Button Lamp/Button"})
	-- AcquisitionMode: VIS_9, WRCS, VIS_12
	self:AddManipulator("TGP Acquisition Mode", {component_path = "/EO TGT Designator System/Target Designator Set Control/Acquisition Mode Switch"})

	-- Mode: OFF, STANDBY, RECORD
	self:AddManipulator("AVTR Mode", {component_path = "/Airborne Video Tape Recorder (AVTR)/Mode Switch"})

	-- dscg_panel::WSO_Mode: off, standby, dscg_test, radar_bit, radar, tv
	self:AddManipulator("Screen Mode", {component_path = "/Radar/DSCG Group (Screens and Controls)/WSO Knobs/Mode Knob"})

	-- radar_stick::State::Trigger: RELEASED, HALF_ACTION, FULL_ACTION
	self:AddManipulator("Antenna Trigger", {component_path = "/Radar Stick Knobs/Trigger Knob"})
	-- float: -1.0 to 1.0 (moves it in either direction, check properties "TDC X" and "TDC Azimuth" to evaluate)
	self:AddManipulator("Antenna Stick X", {component_path = "/Radar Stick Knobs/Slew X Knob"})
	-- float: -1.0 to 1.0 (moves it in either direction, check properties "TDC Y" and "TDC Range" to evaluate)
	self:AddManipulator("Antenna Stick Y", {component_path = "/Radar Stick Knobs/Slew Y Knob"})
	-- float: -1.0 to 1.0 (moves it in either direction until clamped by -60° to +60°)
	self:AddManipulator("Antenna Elevation Knob", {component_path = "/Radar Stick Knobs/Elevation Knob"})
	-- DefaultSwitchEnum: ON, OFF
	self:AddManipulator("Antenna Challenge", {component_path = "/Radar Stick Knobs/Challenge Switch"})

	-- DefaultThreePositionSwitchEnum: positive, zero, negative
	self:AddManipulator("Combat-Tree Mode 2", {component_path = "/IFF Interrogator System/Combat-Tree Mode 2 Switch"})
	self:AddManipulator("Combat-Tree Mode 3", {component_path = "/IFF Interrogator System/Combat-Tree Mode 3 Switch"})
	self:AddManipulator("APX-76 Test Challenge", {component_path = "/IFF Interrogator System/Test Challenge Switch"})

	--WSO Instrument Ground Power Switch, DefaultSwitchEnum: ON, OFF
	self:AddManipulator("WSO Ground Power Switch", {component_path = "/WSO Cockpit/CB Panel 2/Instrument Ground Power Switch/Solenoid Switch"})

	--WSO WRCS Inputs
	--Drag Coefficient Unitless (float) 0.0_f, 999.0_f
	self:AddManipulator("Drag Coefficient", {component_path = "/Weapons/WRCS System/WRCS Knobs/WRCS Drag Coefficient Knob"})
	--Target Altitude Feet 0.0_f_ft, 99900.0_f_ft
	self:AddManipulator("Target Alt/Range", {component_path = "/Weapons/WRCS System/WRCS Knobs/WRCS Alt Range Knob"})
	--Release Range Feet 0.0_f_ft, 9990.0_f_ft
	self:AddManipulator("Release Range", {component_path = "/Weapons/WRCS System/WRCS Knobs/WRCS Range Knob"})
	--Advance Knob Milliseconds 0.0_f_s, 999.0_f_s
	self:AddManipulator("Release Advance", {component_path = "/Weapons/WRCS System/WRCS Knobs/WRCS Advance Knob"})
	--North South offset Input 0.0_f_ft, 99900.0_f_ft
	self:AddManipulator("North/South Offset", {component_path = "/Weapons/WRCS System/WRCS Knobs/WRCS North South Distance Knob"})
	--East West offset Input 0.0_f_ft, 99900.0_f_ft
	self:AddManipulator("East/West Offset", {component_path = "/Weapons/WRCS System/WRCS Knobs/WRCS East West Distance Knob"})

	--WSO LABS Inputs
	--Bombing Pull-Up Timer Seconds 0.0_f_s, 99.9_f_s
	self:AddManipulator("Pullup Timer", {component_path = "/Weapons/ARBCS System/ARBCS Knobs/ARBCS Pullup Time"})
	--Release Timer Seconds 0.0_f_s, 99.9_f_s
	self:AddManipulator("Release Timer", {component_path = "/Weapons/ARBCS System/ARBCS Knobs/ARBCS Release Time"})
	--High Angle Knob Degree 70.0_f_deg, 179.9_f_deg
	self:AddManipulator("High Angle Knob", {component_path = "/Weapons/ARBCS System/ARBCS Knobs/ARBCS High Angle Knob"})
	--Low Angle Knob Degree 0.0_f_deg, 89.9_f_deg
	self:AddManipulator("Low Angle Knob", {component_path = "/Weapons/ARBCS System/ARBCS Knobs/ARBCS Low Angle Knob"})
end

-- Switches in Pilot-Pit. Mostly meant for reading only.
function F_4E_WSO_Cockpit:AddManipulatorsPilot()
	-- DefaultSwitchEnum: ON, OFF
	self:AddManipulator("Master Arm", {component_path = "/Weapons/Weapons Control Panel Buttons/Master Arm Switch"})

	-- DeliveryModeSelection: INST_OS, LOFT, OS, TLAD, TL, OFF, DIRECT, TGT_FIND, DT, DL, L, OFFSET, AGM45
	self:AddManipulator("Delivery Mode", {component_path = "/Weapons/Weapons Control Panel Knobs/Delivery Mode Knob"})
	-- KnobWeaponSelection: RCKTS_DISP, ARM, TV, C, B, A, AGM_12, BOMBS
	self:AddManipulator("Weapon Selection", {component_path = "/Weapons/Weapons Control Panel Knobs/Weapon Selection Knob"})
end

function F_4E_WSO_Cockpit:Constructor()
	self:AddGauges()
	self:AddManipulators()
	self:AddManipulatorsPilot()
end

F_4E_WSO_Cockpit:Seal()

return F_4E_WSO_Cockpit
