-- WRCS offset bombing and Pave Spike control.
-- Pick a map marker, press Target Insert, and Jester freezes the cursor, dials the north/south and east/west
-- offsets and the target altitude into the WRCS, presses Insert and slaves the Pave Spike to it. In OFFSET
-- delivery a long context press sets the release range dial and its x10 / x100 switch once for the armed weapon (Wrcs.ProgramRange).
require('base.Interactions')
local Class = require('base.Class')
local Behavior = require('base.Behavior')
local Config = require('agplus.Config')
local AGLog = require('agplus.Log')
local Util = require('agplus.Util')
local Menu = require('agplus.Menu')
local Mode = require('agplus.Mode')

local Wrcs = {}

local PaveSpikeWRCS = Class(Behavior)
Wrcs.Behavior = PaveSpikeWRCS

-- Cockpit device and command ids. These are fallbacks, used only when the global devices and
-- device_commands tables do not carry the name.
local DEV_WEAPONS = 27
local DEV_PAVE_SPIKE = 64
local CMD_FREEZE       = 3044 -- CURSOR_CTRL_PANEL_WSO_FREEZE_BUTTON
local CMD_INSERT       = 3045 -- CURSOR_CTRL_PANEL_WSO_TGT_INSERT_BUTTON
local CMD_RESET        = 3046 -- CURSOR_CTRL_PANEL_WSO_RESET_BUTTON
local CMD_ACQ_SWITCH   = 3011 -- WSO_TGT_DESIGNATOR_ACQUISITION_MODE_SWITCH (0: 12-VIS, 0.5: WRCS, 1: 9-VIS)
local CMD_RANGE_SWITCH = 3041 -- WEAPON_DELIV_PANEL_WSO_RANGE_SWITCH (0: Norm x10, 1: x100)
local CMD_RANGE_DRUM   = 3033 -- WEAPONS_WRCS_Range

-- Conversion constants
local FT_PER_NM = 6076.1155
local RAD_TO_DEG = 180.0 / math.pi
local DEG_TO_RAD = math.pi / 180.0

-- Magnetic declination by DCS map (values from MOOSE UTILS.GetMagneticDeclination),
-- identified by the aircraft's latitude and longitude.
local MAP_DECLINATIONS = {
    { name="Caucasus",       lat_min=41, lat_max=44, lon_min=36, lon_max=46, dec=6   },
    { name="Syria",          lat_min=32, lat_max=37, lon_min=34, lon_max=42, dec=5   },
    { name="PersianGulf",    lat_min=22, lat_max=30, lon_min=50, lon_max=60, dec=2   },
    { name="Sinai",          lat_min=27, lat_max=33, lon_min=30, lon_max=36, dec=4.8 },
    { name="NTTR",           lat_min=34, lat_max=40, lon_min=-120, lon_max=-112, dec=12 },
    { name="Normandy",       lat_min=47, lat_max=51, lon_min=-3, lon_max=3, dec=-10 },
    { name="TheChannel",     lat_min=49, lat_max=53, lon_min=-2, lon_max=5, dec=-10 },
    { name="MarianaIslands", lat_min=10, lat_max=20, lon_min=140, lon_max=150, dec=2  },
    { name="Falklands",      lat_min=-55, lat_max=-48, lon_min=-65, lon_max=-55, dec=12 },
    { name="Kola",           lat_min=65, lat_max=72, lon_min=25, lon_max=42, dec=15 },
    { name="Afghanistan",    lat_min=30, lat_max=38, lon_min=62, lon_max=72, dec=3  },
}

-- Module state
local S = {
    marker = nil,                 -- selected map marker { lat, lon, alt, name }
    weapon = "Mk82 LD",           -- weapon used for the release range
    auto_rr = true,               -- keep the release range dial matched
    last_dial = nil,
    last_mult = nil,
    custom_dec = nil,             -- manual magnetic variation, nil = automatic by map
    var_source = "Auto",
    acq_mode = "WRCS",            -- Pave Spike acquisition mode shown on the wheel
    insert_stage = nil,           -- Target Insert state machine
    dials_settled = false,
    settle_wait = nil,
    tgt_ns = nil, tgt_ew = nil, tgt_alt = nil,
    reset_stage = nil,            -- Reset button hold counter
    last_lat = 0, last_lon = 0, last_fallback = 0,
    nearest = {}, own = {},       -- marker menu entries { label, value }
    last_var_roger = -999,
    diag = 'no markers scanned yet',
}

local function round_1dec(val)
    return math.floor(val * 10.0 + (val >= 0 and 0.5 or -0.5)) / 10.0
end

-- Assigned further down. Declared here (once) so the variation handlers below can refresh the wheel text.
local broadcast_menu_status

local function get_mag_declination()
    if S.custom_dec ~= nil then
        S.var_source = "Custom"
        return S.custom_dec
    end

    local dec = Config.MAG_DECLINATION_FALLBACK
    local map_name = "Unknown"
    pcall(function()
        local j = GetJester()
        if j and j.awareness then
            local obs_lat = j.awareness:GetObservation("latitude")
            local obs_lon = j.awareness:GetObservation("longitude")
            if obs_lat and obs_lon then
                local lat = obs_lat.value * RAD_TO_DEG
                local lon = obs_lon.value * RAD_TO_DEG
                for _, m in ipairs(MAP_DECLINATIONS) do
                    if lat >= m.lat_min and lat <= m.lat_max
                       and lon >= m.lon_min and lon <= m.lon_max then
                        dec = m.dec
                        map_name = m.name
                        break
                    end
                end
            end
        end
    end)
    S.var_source = map_name
    return dec
end

local function set_custom_variation(val)
    S.custom_dec = round_1dec(val)
    S.var_source = "Custom"
    broadcast_menu_status()
    AGLog.Info('WRCS: custom magnetic variation %+.1f deg', S.custom_dec)
end

local function step_custom_variation(delta)
    local base = get_mag_declination()
    local new_val = round_1dec(base + delta)
    new_val = math.max(-45.0, math.min(45.0, new_val))
    set_custom_variation(new_val)
end

local function reset_auto_variation()
    S.custom_dec = nil
    get_mag_declination()
    broadcast_menu_status()
    AGLog.Info('WRCS: magnetic variation back to automatic (map lookup)')
end

-- Weapon Drag Factors (k = 0.5 * rho * Cd * A / m) for level release Rg calculation
local WEAPON_K_FACTORS = {
    ["Mk82 LD"]  = 0.000095, -- Low-drag 500 lb slick
    ["Mk82 SE"]  = 0.000350, -- High-drag Snakeye (fins open)
    ["Mk82 AIR"] = 0.000320, -- High-drag BSU-49 Ballute
    ["Mk83"]     = 0.000085, -- Low-drag 1,000 lb slick
    ["Mk84"]     = 0.000072, -- Low-drag 2,000 lb slick
    ["CBU-87"]   = 0.000115, -- Combined Effects Munition canister
    ["GBU-12"]   = 0.000105, -- 500 lb Paveway II
    ["GBU-10"]   = 0.000080, -- 2,000 lb Paveway II
    ["GBU-24"]   = 0.000078, -- 2,000 lb Paveway III
}

-- Slot for empirical/calibrated Rg functions (Rg in feet from Heatblur calculator)
local WEAPON_CALIBRATED_RG = {}

-- Calibrated regression function for Mk-82 LD (MAE = 10.1 ft across 250 to 35,000 ft envelope)
local function eval_mk82_ld_calibrated_rg(alt_agl, tas_kts)
    local s = math.sqrt(math.max(100.0, alt_agl))
    local h = math.max(0.1, alt_agl / 1000.0)
    local v = math.max(2.0, math.min(7.0, tas_kts / 100.0))
    
    local rg = 1960.05352978
        + 81.60389059 * (s * v)
        - 79.18622154 * s
        - 106.00450618 * (h * v)
        + 153.42566627 * h
        - 824.71214594 * v
        - 3.50016037 * (h * h)
        - 3.35553286 * (s * v * v)
        - 2.31810979 * ((s * v) / math.sqrt(h + 0.5))
        + 1.03307505 * (s * h)
        - 241.84761457 * ((h * v) / (h + 2.0))
        + 80.54225033 * (v * v)
        + 10.49761654 * ((h * h * v * v) / 100.0)
        
    return math.max(500.0, math.min(99900.0, rg))
end

WEAPON_CALIBRATED_RG["Mk82 LD"] = eval_mk82_ld_calibrated_rg

-- Calibrated regression function for Mk-83 (MAE = 8.99 ft across 250 to 35,000 ft envelope)
local function eval_mk83_calibrated_rg(alt_agl, tas_kts)
    local s = math.sqrt(math.max(100.0, alt_agl))
    local h = math.max(0.1, alt_agl / 1000.0)
    local v = math.max(2.0, math.min(7.0, tas_kts / 100.0))
    
    local rg = 1762.33581956
        + 79.53062824 * (s * v)
        - 77.64788117 * s
        - 103.22731433 * (h * v)
        + 193.27403520 * h
        - 730.10578380 * v
        - 3.00825575 * (h * h)
        - 3.09662277 * (s * v * v)
        - 1.97709361 * ((s * v) / math.sqrt(h + 0.5))
        + 0.76895566 * (s * h)
        - 237.38847513 * ((h * v) / (h + 2.0))
        + 69.50420452 * (v * v)
        + 10.53190269 * ((h * h * v * v) / 100.0)
        
    return math.max(500.0, math.min(99900.0, rg))
end

WEAPON_CALIBRATED_RG["Mk83"] = eval_mk83_calibrated_rg

-- Calibrated regression function for Mk-84 (MAE = 4.27 ft across 250 to 35,000 ft envelope)
local function eval_mk84_calibrated_rg(alt_agl, tas_kts)
    local s = math.sqrt(math.max(100.0, alt_agl))
    local h = math.max(0.1, alt_agl / 1000.0)
    local v = math.max(2.0, math.min(7.0, tas_kts / 100.0))
    
    local rg = 1000.70463802
        + 68.79425721 * (s * v)
        - 58.14993819 * s
        - 86.24262278 * (h * v)
        + 254.61145437 * h
        - 426.89879657 * v
        - 1.53384463 * (h * h)
        - 2.50301171 * (s * v * v)
        - 0.38806994 * ((s * v) / math.sqrt(h + 0.5))
        + 0.04667430 * (s * h)
        - 118.30245040 * ((h * v) / (h + 2.0))
        + 41.72500662 * (v * v)
        + 11.08577790 * ((h * h * v * v) / 100.0)
        
    return math.max(500.0, math.min(99900.0, rg))
end

WEAPON_CALIBRATED_RG["Mk84"] = eval_mk84_calibrated_rg

-- Calibrated regression function for Mk-82 AIR (MAE = 1.68 ft across 250 to 3,000+ ft tactical envelope)
local function eval_mk82_air_calibrated_rg(alt_agl, tas_kts)
    local a = math.max(100.0, alt_agl)
    local s = math.sqrt(a)
    local h = a / 1000.0
    local v = math.max(2.0, math.min(7.0, tas_kts / 100.0))
    local l = math.log(a)
    
    local rg = -828.45483031
        + 67.34360367 * s
        - 541.71360580 * h
        + 184.36964443 * v
        - 4.77126994 * (s * v)
        + 34.59770908 * (h * v)
        - 27.70028376 * (v * v)
        + 11.81661772 * (h * h)
        + 1.02615585 * l
        + 70.79746822 * (l * v)
        
    return math.max(200.0, math.min(99900.0, rg))
end

WEAPON_CALIBRATED_RG["Mk82 AIR"] = eval_mk82_air_calibrated_rg

-- Calibrated regression function for Mk-82 SE (Snakeye) (MAE = 1.69 ft across 250 to 3,000+ ft tactical envelope)
local function eval_mk82_se_calibrated_rg(alt_agl, tas_kts)
    local a = math.max(100.0, alt_agl)
    local s = math.sqrt(a)
    local h = a / 1000.0
    local v = math.max(2.0, math.min(7.0, tas_kts / 100.0))
    local l = math.log(a)
    
    local rg = -802.81893150
        + 70.32744266 * s
        - 561.17405969 * h
        + 183.20136732 * v
        - 4.89727724 * (s * v)
        + 35.68129873 * (h * v)
        - 28.22304600 * (v * v)
        + 12.29122741 * (h * h)
        - 14.31837848 * l
        + 73.27397620 * (l * v)
        
    return math.max(200.0, math.min(99900.0, rg))
end

WEAPON_CALIBRATED_RG["Mk82 SE"] = eval_mk82_se_calibrated_rg

-- Calibrated regression function for CBU-87 (MAE = 17.57 ft across 250 to 35,000 ft operational ceiling)
local function eval_cbu87_calibrated_rg(alt_agl, tas_kts)
    local a = math.max(100.0, alt_agl)
    local s = math.sqrt(a)
    local h = a / 1000.0
    local v = math.max(2.0, math.min(7.0, tas_kts / 100.0))
    local sq_denom = math.sqrt(h + 0.5)
    local h_denom = h + 2.0
    
    local rg = 2236.57759739
        + 54.75724970 * (s * v)
        - 67.61002572 * s
        + 8.67284936 * (h * v)
        + 355.44111434 * h
        - 852.69637409 * v
        + 3.34751668 * (h * h)
        - 2.41792949 * (s * v * v)
        + 5.39544960 * ((s * v) / sq_denom)
        - 1.69569433 * (s * h)
        + 409.40774267 * ((h * v) / h_denom)
        + 87.28555572 * (v * v)
        - 2.52598103 * ((h * h * v * v) / 100.0)
        
    return math.max(500.0, math.min(99900.0, rg))
end

WEAPON_CALIBRATED_RG["CBU-87"] = eval_cbu87_calibrated_rg

-- Calibrated regression function for GBU-12 (MAE = 5.20 ft across 250 to 35,000 ft operational ceiling)
local function eval_gbu12_calibrated_rg(alt_agl, tas_kts)
    local a = math.max(100.0, alt_agl)
    local s = math.sqrt(a)
    local h = a / 1000.0
    local v = math.max(2.0, math.min(7.0, tas_kts / 100.0))
    local sq_denom = math.sqrt(h + 0.5)
    local h_denom = h + 2.0
    
    local rg = 811.74010801
        + 71.82557102 * (s * v)
        - 64.76627257 * s
        - 97.66972108 * (h * v)
        + 253.77300657 * h
        - 379.75707123 * v
        - 2.10751291 * (h * h)
        - 3.34064825 * (s * v * v)
        + 0.91682839 * ((s * v) / sq_denom)
        + 0.27716320 * (s * h)
        - 54.02536098 * ((h * v) / h_denom)
        + 40.46935394 * (v * v)
        + 12.28081302 * ((h * h * v * v) / 100.0)
        
    return math.max(500.0, math.min(99900.0, rg))
end

WEAPON_CALIBRATED_RG["GBU-12"] = eval_gbu12_calibrated_rg

-- Calibrated regression function for GBU-10 (MAE = 5.87 ft across 250 to 35,000 ft operational ceiling)
local function eval_gbu10_calibrated_rg(alt_agl, tas_kts)
    local a = math.max(100.0, alt_agl)
    local s = math.sqrt(a)
    local h = a / 1000.0
    local v = math.max(2.0, math.min(7.0, tas_kts / 100.0))
    local sq_denom = math.sqrt(h + 0.5)
    local h_denom = h + 2.0
    
    local rg = 860.87957845
        + 75.24555729 * (s * v)
        - 69.76227427 * s
        - 106.15654377 * (h * v)
        + 275.15205197 * h
        - 400.46403074 * v
        - 2.32766669 * (h * h)
        - 3.47319571 * (s * v * v)
        + 0.22854152 * ((s * v) / sq_denom)
        + 0.29052768 * (s * h)
        - 112.14843218 * ((h * v) / h_denom)
        + 41.57848269 * (v * v)
        + 12.71448741 * ((h * h * v * v) / 100.0)
        
    return math.max(500.0, math.min(99900.0, rg))
end

WEAPON_CALIBRATED_RG["GBU-10"] = eval_gbu10_calibrated_rg

-- Calibrated regression function for GBU-24 (MAE = 14.22 ft across 250 to 35,000 ft operational ceiling)
local function eval_gbu24_calibrated_rg(alt_agl, tas_kts)
    local a = math.max(100.0, alt_agl)
    local s = math.sqrt(a)
    local h = a / 1000.0
    local v = math.max(2.0, math.min(7.0, tas_kts / 100.0))
    local sq_denom = math.sqrt(h + 0.5)
    local h_denom = h + 2.0
    
    local rg = -828.91139973
        + 23.62747830 * (s * v)
        + 30.80148451 * s
        + 92.06571779 * (h * v)
        - 195.32838486 * h
        + 320.04630355 * v
        - 4.21079699 * (h * h)
        + 0.68378769 * (s * v * v)
        + 3.46252002 * ((s * v) / sq_denom)
        + 0.08054087 * (s * h)
        + 321.63947402 * ((h * v) / h_denom)
        - 25.24518576 * (v * v)
        - 30.74081254 * ((h * h * v * v) / 100.0)
        + 20.77550907 * ((h * h * v) / 10.0)
        - 54.07852401 * ((h * v * v) / 10.0)
        
    return math.max(500.0, math.min(99900.0, rg))
end

WEAPON_CALIBRATED_RG["GBU-24"] = eval_gbu24_calibrated_rg

--------------------------------------------------------------------------------
-- Mathematical and geodesic helpers
--------------------------------------------------------------------------------

-- Flat-earth local tangent plane projection (WRCS coordinate frame)
local function compute_marker_geometry(acft_lat, acft_lon, tgt_lat, tgt_lon)
    local delta_lat_deg = tgt_lat - acft_lat
    local delta_lon_deg = tgt_lon - acft_lon
    local mean_lat_rad = ((acft_lat + tgt_lat) * 0.5) * DEG_TO_RAD

    local delta_n_ft = delta_lat_deg * 60.0 * FT_PER_NM
    local delta_e_ft = delta_lon_deg * 60.0 * math.cos(mean_lat_rad) * FT_PER_NM

    local dist_ft = math.sqrt(delta_n_ft * delta_n_ft + delta_e_ft * delta_e_ft)
    local dist_nm = dist_ft / FT_PER_NM

    local brg_rad = math.atan2(delta_e_ft, delta_n_ft)
    local brg_deg = (brg_rad * RAD_TO_DEG) % 360.0

    return delta_n_ft, delta_e_ft, dist_ft, dist_nm, brg_deg
end

local function safe_get_alt(val)
    if not val then return 0 end
    local ok, res = pcall(function()
        if type(val) == "number" then return val end
        if type(val) == "string" then return tonumber(val) or 0 end
        if type(val) == "table" or type(val) == "userdata" then
            if val.ConvertTo and ft then
                local ok_ft, v_ft = pcall(function() return val:ConvertTo(ft).value end)
                if ok_ft and type(v_ft) == "number" and v_ft ~= 0 then return v_ft end
            end
            if val.value ~= nil then
                local v = val.value
                if type(v) == "number" then return v end
                if type(v) == "string" then return tonumber(v) or 0 end
            end
        end
        return tonumber(val) or 0
    end)
    if ok and type(res) == "number" then return res end
    return 0
end

-- Robust Target Elevation Extractor
local function extract_marker_altitude(m, fallback_ground_alt)
    local alt_ft = 0

    if not m then return fallback_ground_alt or 0 end

    -- 1. Check direct marker 3D position (DCS pos table: y is altitude in meters)
    pcall(function()
        if m.pos then
            local py = (type(m.pos) == "table" and (m.pos.y or m.pos[2])) or (type(m.pos) == "userdata" and m.pos.y)
            if py and type(py) == "number" and py ~= 0 then
                alt_ft = py * 3.2808399
            end
        elseif m.y and type(m.y) == "number" then
            alt_ft = m.y * 3.2808399
        end
    end)

    -- 2. Check explicit altitude or elevation properties (Observation/Distance/number)
    if alt_ft <= 0 then
        if m.altitude ~= nil then
            alt_ft = safe_get_alt(m.altitude)
        elseif m.elevation ~= nil then
            alt_ft = safe_get_alt(m.elevation)
        elseif m.alt ~= nil then
            alt_ft = safe_get_alt(m.alt)
        end
    end

    -- 3. Check custom text annotations (e.g. "TGT 1200", "STAKE 850FT", "EL: 450", "ALT: 1200")
    if alt_ft <= 0 and m.text then
        local txt = string.upper(tostring(m.text))
        local parsed = string.match(txt, "(%d+)%s*FT")
            or string.match(txt, "ALT%s*[:=]?%s*(%d+)")
            or string.match(txt, "EL%s*[:=]?%s*(%d+)")
            or string.match(txt, "ELEV%s*[:=]?%s*(%d+)")
            or string.match(txt, "[%s_-](%d+)%s*$")  -- e.g. "TGT 1200", "BRIDGE_450"
        if parsed then
            alt_ft = tonumber(parsed) or 0
        end
    end

    -- 4. Check terrain height at marker position via DCS Terrain module or land table (safe _G only)
    if alt_ft <= 0 and m.pos then
        local px = (type(m.pos) == "table" and (m.pos.x or m.pos[1])) or (type(m.pos) == "userdata" and m.pos.x)
        local pz = (type(m.pos) == "table" and (m.pos.z or m.pos[3])) or (type(m.pos) == "userdata" and m.pos.z)
        if px and pz then
            pcall(function()
                local t = _G.terrain or _G.Terrain
                if t and t.GetHeight then
                    local h_m = t.GetHeight(px, pz)
                    if h_m and h_m > 0 then alt_ft = h_m * 3.2808399 end
                elseif t and t.GetSurfaceHeightWithSeabed then
                    local h_m = t.GetSurfaceHeightWithSeabed(px, pz)
                    if h_m and h_m > 0 then alt_ft = h_m * 3.2808399 end
                end
            end)
            if alt_ft <= 0 then
                pcall(function()
                    local l = _G.land
                    if l and l.getHeight then
                        local h_m = l.getHeight({x = px, y = pz})
                        if h_m and h_m > 0 then alt_ft = h_m * 3.2808399 end
                    end
                end)
            end
        end
    end

    -- 5. Fallback to estimated local terrain elevation from aircraft sensors
    if alt_ft <= 0 and fallback_ground_alt and fallback_ground_alt > 0 then
        alt_ft = fallback_ground_alt
    end

    return math.max(0.0, alt_ft)
end

-- Ballistic Forward Release Range Rg (ft) for unguided munitions in level flight
local function calculate_ballistic_release_range(h_agl, v_tas, weapon_type)
    local h = math.max(100.0, math.min(35000.0, h_agl))
    local v0 = math.max(200.0, math.min(700.0, v_tas)) * 1.68781 -- ft/s
    local w = weapon_type or "Mk82 LD"

    -- 1. Check if dedicated calibrated model is available
    if WEAPON_CALIBRATED_RG[w] then
        local ok, res = pcall(WEAPON_CALIBRATED_RG[w], h, v_tas)
        if ok and res and res > 0 then
            return math.max(500.0, math.min(99900.0, res))
        end
    end

    -- 2. Analytical aerodynamic solution: Rg = (1/k) * ln(1 + k * V0 * t_vac)
    local t_vac = math.sqrt(h / 16.087)
    local k = WEAPON_K_FACTORS[w] or 0.000095

    local rg_ft = (1.0 / k) * math.log(1.0 + k * v0 * t_vac)
    return math.max(500.0, math.min(99900.0, rg_ft))
end

local function safe_get_coord(val)
    if not val then return 0 end
    local ok, res = pcall(function()
        if type(val) == "number" then return val end
        if type(val) == "string" then return tonumber(val) or 0 end
        if type(val) == "table" or type(val) == "userdata" then
            if val.ConvertTo and deg then
                local ok_deg, v_deg = pcall(function() return val:ConvertTo(deg).value end)
                if ok_deg and type(v_deg) == "number" and v_deg ~= 0 then
                    return v_deg
                end
            end
            if val.value ~= nil then
                local v = val.value
                if type(v) == "number" then
                    if math.abs(v) <= 1.6 then return v * RAD_TO_DEG end
                    return v
                end
                if type(v) == "string" then return tonumber(v) or 0 end
            end
        end
        return tonumber(val) or 0
    end)
    if ok and type(res) == "number" then return res end
    return 0
end

local function safe_get_name(m, fallback)
    if not m then return fallback or "(No Name)" end
    local raw = ""
    pcall(function()
        if m.text and type(m.text) == "string" and m.text ~= "" then
            raw = m.text
        elseif m.name and type(m.name) == "string" and m.name ~= "" then
            raw = m.name
        elseif m.text then
            raw = tostring(m.text)
        elseif m.name then
            raw = tostring(m.name)
        end
    end)
    raw = tostring(raw or "")
    raw = string.gsub(raw, "[\r\n]+", " ")
    raw = string.gsub(raw, "^%s*(.-)%s*$", "%1")
    if raw == "" then raw = fallback or "(No Name)" end
    return raw
end

-- Marker menu entries (nearest first), as plain data: { label, value }. value is what the wheel
-- sends back when the entry is chosen: "lat;lon;alt;name".
local function build_marker_entries(m_list, acft_lat, acft_lon, fallback_ground)
    local sorted = {}
    if m_list then
        for idx, m in ipairs(m_list) do
            if m then
                local m_lat = safe_get_coord(m.latitude or m.lat)
                local m_lon = safe_get_coord(m.longitude or m.lon)
                if m_lat ~= 0 and m_lon ~= 0 then
                    local dist_nm = 0
                    if acft_lat and acft_lat ~= 0 and acft_lon and acft_lon ~= 0 then
                        local _, _, _, d_nm = compute_marker_geometry(acft_lat, acft_lon, m_lat, m_lon)
                        dist_nm = d_nm
                    end
                    sorted[#sorted + 1] = {
                        lat = m_lat,
                        lon = m_lon,
                        alt = extract_marker_altitude(m, fallback_ground),
                        dist_nm = dist_nm,
                        name = safe_get_name(m, "Marker " .. tostring(idx)),
                    }
                end
            end
        end
    end

    table.sort(sorted, function(a, b) return a.dist_nm < b.dist_nm end)

    local entries = {}
    for i = 1, math.min(Config.MARKER_MENU_MAX, #sorted) do
        local e = sorted[i]
        local label = e.name
        if string.len(label) > 28 then label = string.sub(label, 1, 28) end
        entries[#entries + 1] = {
            label = label,
            value = string.format("%.6f;%.6f;%.0f;%s", e.lat, e.lon, e.alt, e.name),
        }
    end
    return entries
end

local function collect_markers_src(src, dest, seen)
    if type(src) ~= "table" and type(src) ~= "userdata" then return end
    
    local count = 0
    local function add_m(m)
        if m and not seen[m] then
            seen[m] = true
            dest[#dest + 1] = m
            count = count + 1
        end
    end

    pcall(function()
        for _, m in ipairs(src) do add_m(m) end
    end)
    if count == 0 then
        local len = 0
        pcall(function() len = #src end)
        if len and len > 0 then
            for i = 1, len do
                local m = nil
                pcall(function() m = src[i] end)
                add_m(m)
            end
        end
    end
    if count == 0 then
        pcall(function()
            for _, m in pairs(src) do add_m(m) end
        end)
    end
end

--------------------------------------------------------------------------------
-- Cockpit clicks
--------------------------------------------------------------------------------

-- The pod's acquisition mode as text ('12 Vis', '9 Vis', 'WRCS') for the Pave Spike menu: read from the cockpit switch when its state can be
-- told, otherwise the last mode Jester set from the menu.
local acq_logged = false
function Wrcs.AcqText()
    local raw
    pcall(function() raw = GetJester():GetCockpit():GetManipulator('TGP Acquisition Mode'):GetState() end)
    if raw ~= nil and not acq_logged then
        acq_logged = true
        AGLog.Info('wrcs: TGP Acquisition Mode reads %s (%s)', tostring(raw), type(raw))
    end
    local t = string.upper(tostring(raw or ''))
    if t:find('WRCS') then return 'WRCS' end
    if t:find('12') then return '12 Vis' end
    if t:find('9') then return '9 Vis' end
    local n = tonumber(raw)
    if n then
        if n < 0.25 then return '12 Vis' elseif n > 0.75 then return '9 Vis' else return 'WRCS' end
    end
    local m = S.acq_mode or 'WRCS'
    return (m == '12-VIS' and '12 Vis') or (m == '9-VIS' and '9 Vis') or 'WRCS'
end

local function set_acq_switch(value)
    pcall(function()
        ClickRaw((devices and devices.EO_TGT_DESIGNATOR_SYSTEM_AN_ASQ_153) or DEV_PAVE_SPIKE,
                 (device_commands and device_commands.WSO_TGT_DESIGNATOR_ACQUISITION_MODE_SWITCH) or CMD_ACQ_SWITCH, value)
    end)
end

local function click_weapons(command_name, fallback_id, value)
    pcall(function()
        ClickRaw((devices and devices.WEAPONS) or DEV_WEAPONS,
                 (device_commands and device_commands[command_name]) or fallback_id, value)
    end)
end

--------------------------------------------------------------------------------
-- Wheel status text
--------------------------------------------------------------------------------

local STATUS_TAILS = {
    { "WRCS Integration" },
}
local MARK_TAILS = {
    { "WRCS Integration", "Map Marks" },
    { "WRCS Integration", "Map Marks", "Nearest Markers" },
    { "WRCS Integration", "Map Marks", "Own Markers" },
}
local VARIATION_TAILS = {
    { "WRCS Integration", "Mag Variation" },
    { "WRCS Integration", "Mag Variation", "Fine Adjust" },
    { "WRCS Integration", "Mag Variation", "Coarse Adjust" },
    { "WRCS Integration", "Mag Variation", "Presets" },
}

-- Center-of-wheel status across all WRCS Integration menus. active_rg_ft / active_mult are given while the
-- release range is being tracked.
broadcast_menu_status = function(active_rg_ft, active_mult)
    local active_weapon = S.weapon or "Mk82 LD"
    local tgt_lbl = "NONE"
    if S.marker then
        local s_name = S.marker.name or "TGT"
        if string.len(s_name) > 8 then s_name = string.sub(s_name, 1, 8) end

        local acft_lat, acft_lon = S.last_lat, S.last_lon
        if acft_lat == 0 and acft_lon == 0 then
            pcall(function()
                local j = GetJester()
                if j and j.awareness then
                    local o_lat = j.awareness:GetObservation("latitude")
                    local o_lon = j.awareness:GetObservation("longitude")
                    if o_lat and o_lon then
                        acft_lat = o_lat.value * RAD_TO_DEG
                        acft_lon = o_lon.value * RAD_TO_DEG
                    end
                end
            end)
        end

        if acft_lat ~= 0 and acft_lon ~= 0 and S.marker.lat and S.marker.lon then
            local dn_ft, de_ft, _, d_nm = compute_marker_geometry(acft_lat, acft_lon, S.marker.lat, S.marker.lon)
            if math.abs(dn_ft) > 99900.0 or math.abs(de_ft) > 99900.0 then
                tgt_lbl = string.format("[TOO FAR] %s (%.1fNM)", s_name, d_nm)
            else
                tgt_lbl = string.format("%s (%dft | %.1fNM)", s_name, math.floor(S.marker.alt or 0), d_nm)
            end
        else
            tgt_lbl = string.format("%s (%dft)", s_name, math.floor(S.marker.alt or 0))
        end
    end

    local cur_var = get_mag_declination()
    local var_src = S.var_source or "Auto"
    local var_tag = (S.custom_dec ~= nil) and string.format("Var: %+.1f deg [C]", cur_var) or string.format("Var: %+.1f deg", cur_var)
    local ps_tag = string.format("Mode: %s", S.acq_mode or "WRCS")

    local status_str
    if S.auto_rr then
        if active_rg_ft and active_mult then
            local mult_lbl = (active_mult == 1.0) and "x100" or "x10"
            status_str = string.format("[%s] Tgt: %s | %s | %s | Rg: %d ft (%s) | Auto RR: ON", active_weapon, tgt_lbl, var_tag, ps_tag, math.floor(active_rg_ft + 0.5), mult_lbl)
        else
            status_str = string.format("[%s] Tgt: %s | %s | %s | ARMED | Auto RR: ON", active_weapon, tgt_lbl, var_tag, ps_tag)
        end
    else
        status_str = string.format("[%s] Tgt: %s | %s | %s | Auto RR: OFF", active_weapon, tgt_lbl, var_tag, ps_tag)
    end

    local var_menu_hdr
    if S.custom_dec ~= nil then
        var_menu_hdr = string.format("Mag Variation: %+.1f deg (Custom Override)", cur_var)
    else
        var_menu_hdr = string.format("Mag Variation: %+.1f deg (Auto: %s)", cur_var, var_src)
    end

    Menu.SetInfoAll(STATUS_TAILS, status_str)
    local marks_text = S.diag .. '\n' .. status_str
    Menu.SetInfoAll(MARK_TAILS, marks_text)
    Menu.SetInfoAll(VARIATION_TAILS, var_menu_hdr)
end

--------------------------------------------------------------------------------
-- Wheel menu
--------------------------------------------------------------------------------

-- Pave Spike acquisition modes. value is the switch position.
local PS_MODES = {
    -- Oct 22 2026: the 12 and 9 values were the wrong way round (the menu's 12 Vis put the switch at 9 Vis and the reverse, seen in the cockpit).
    ["12VIS"] = { label = "12-VIS", value = 1.0, note = "12-VIS (12 o'clock)" },
    ["WRCS"]  = { label = "WRCS",   value = 0.5, note = "WRCS (slaved)" },
    ["9VIS"]  = { label = "9-VIS",  value = 0.0, note = "9-VIS (9 o'clock)" },
}

local function leaf(name, action, value, reaction)
    return Wheel.Item:new({ name = name, action = action, action_value = value, reaction = reaction or Wheel.Reaction.CLOSE_REMEMBER })
end

local function sub(name, items)
    return Wheel.Item:new({ name = name, menu = Wheel.Menu:new({ name = name, items = items }) })
end

local function marker_items(entries)
    local items = {}
    for _, e in ipairs(entries) do
        items[#items + 1] = leaf(e.label, "agp_wrcs_marker", e.value)
    end
    if #items == 0 then
        items[1] = leaf("No Map Markers", "agp_wrcs_no_markers", nil, Wheel.Reaction.NOTHING)
    end
    return items
end

local function step_items(steps)
    local items = {}
    for _, v in ipairs(steps) do
        items[#items + 1] = leaf(string.format("%+.1f deg", v), "agp_wrcs_var_step", tostring(v), Wheel.Reaction.NOTHING)
    end
    return items
end

function Wrcs.BuildItem()
    local markers = sub("Map Marks", {
        leaf("Refresh Markers", "agp_wrcs_refresh"),
        sub("Nearest Markers", marker_items(S.nearest)),
        sub("Own Markers", marker_items(S.own)),
    })

    -- The Pave Spike acquisition modes moved to the Pave Spike menu (Oct 22 2026): PaveSearch.lua builds them, this file still handles them.
    local mag_var = sub("Mag Variation", {
        leaf("Auto (Map Lookup)", "agp_wrcs_var_auto"),
        sub("Fine Adjust", step_items({ -0.5, -0.2, -0.1, 0.1, 0.2, 0.5 })),
        sub("Coarse Adjust", step_items({ -2.0, -1.0, 1.0, 2.0 })),
        sub("Presets", {
            leaf("Normandy (-10.0 deg)",    "agp_wrcs_var_preset", "-10.0"),
            leaf("True North (0.0 deg)",    "agp_wrcs_var_preset", "0.0"),
            leaf("Persian Gulf (+2.0 deg)", "agp_wrcs_var_preset", "2.0"),
            leaf("Syria (+5.0 deg)",        "agp_wrcs_var_preset", "5.0"),
            leaf("Caucasus (+6.0 deg)",     "agp_wrcs_var_preset", "6.0"),
            leaf("NTTR (+12.0 deg)",        "agp_wrcs_var_preset", "12.0"),
            leaf("Kola (+15.0 deg)",        "agp_wrcs_var_preset", "15.0"),
        }),
    })

    return sub("WRCS Integration", {
        leaf("Target Insert", "agp_wrcs_insert"),
        markers,
        leaf("Reset Target Data", "agp_wrcs_reset"),
        mag_var,
    })
end

--------------------------------------------------------------------------------
-- Map markers
--------------------------------------------------------------------------------

local refresh_dynamic_map_markers

refresh_dynamic_map_markers = function(acft_lat, acft_lon, fallback_ground, force)
    local all_m, own_m = {}, {}
    local seen_all, seen_own = {}, {}
    local scanned = {}

    -- The host keeps the markers in the globals own_map_markers and all_map_markers. Look in every
    -- environment Jester's code runs in, once each.
    local function scan_env(e)
        if not e or scanned[e] then return end
        scanned[e] = true
        pcall(function() if e.own_map_markers then collect_markers_src(e.own_map_markers, own_m, seen_own) end end)
        pcall(function() if e.all_map_markers then collect_markers_src(e.all_map_markers, all_m, seen_all) end end)
        pcall(function() if e.map_markers then collect_markers_src(e.map_markers, all_m, seen_all) end end)
    end

    pcall(function() scan_env(getfenv and getfenv()) end)
    pcall(function() scan_env(_G) end)
    -- Stock UpdateJesterWheel reads these as bare globals; do the same.
    pcall(function() if own_map_markers then collect_markers_src(own_map_markers, own_m, seen_own) end end)
    pcall(function() if all_map_markers then collect_markers_src(all_map_markers, all_m, seen_all) end end)

    pcall(function()
        local jester = GetJester()
        if not jester then return end
        scan_env(jester)
        pcall(function() if jester.awareness then scan_env(jester.awareness) end end)
        pcall(function() if jester.memory then scan_env(jester.memory) end end)
        if jester.behaviors and type(jester.behaviors) == "table" then
            for _, inst in pairs(jester.behaviors) do
                pcall(function()
                    if type(inst) ~= "table" then return end
                    for _, v in pairs(inst) do
                        if type(v) == "function" then pcall(function() scan_env(getfenv(v)) end) end
                    end
                    local mt = getmetatable(inst)
                    if mt and type(mt.__index) == "table" then
                        for _, v in pairs(mt.__index) do
                            if type(v) == "function" then pcall(function() scan_env(getfenv(v)) end) end
                        end
                    end
                end)
            end
        end
    end)

    pcall(function()
        local get_panels = (world and world.getMarkPanels) or (_G and _G.world and _G.world.getMarkPanels)
        if get_panels then
            local panels = get_panels()
            if panels then
                collect_markers_src(panels, all_m, seen_all)
                collect_markers_src(panels, own_m, seen_own)
            end
        end
    end)

    pcall(function()
        local get_export_panels = (Export and Export.LoGetMarkPanels) or (_G and _G.Export and _G.Export.LoGetMarkPanels) or (_G and _G.LoGetMarkPanels)
        if get_export_panels then
            local e_panels = get_export_panels()
            if e_panels then
                collect_markers_src(e_panels, all_m, seen_all)
                collect_markers_src(e_panels, own_m, seen_own)
            end
        end
    end)

    -- If only one list was found, use it for both.
    pcall(function()
        if #own_m == 0 and #all_m > 0 then
            for _, m in ipairs(all_m) do
                if not seen_own[m] then seen_own[m] = true own_m[#own_m + 1] = m end
            end
        elseif #all_m == 0 and #own_m > 0 then
            for _, m in ipairs(own_m) do
                if not seen_all[m] then seen_all[m] = true all_m[#all_m + 1] = m end
            end
        end
    end)

    local raw_own, raw_all = #own_m, #all_m
    local g_own, g_all = type(_G.own_map_markers), type(_G.all_map_markers)
    local first = ''
    pcall(function()
        local m = all_m[1] or own_m[1]
        if m then
            local f = {}
            for _, k in ipairs({ 'latitude', 'longitude', 'text', 'name', 'creation_time' }) do
                local v = m[k]
                if v ~= nil then f[#f + 1] = k .. ':' .. type(v) end
            end
            first = ' fields ' .. table.concat(f, ',')
            first = first .. string.format(' lat=%.3f lon=%.3f', safe_get_coord(m.latitude or m.lat), safe_get_coord(m.longitude or m.lon))
        end
    end)
    local ok_b, err_b = pcall(function()
        S.nearest = build_marker_entries(all_m, acft_lat, acft_lon, fallback_ground)
        S.own = build_marker_entries(own_m, acft_lat, acft_lon, fallback_ground)
    end)
    -- How the bare global (what stock reads) looks to ipairs, # and pairs, and the names in it.
    local function describe(label, src)
        local ip, ln, pr, names = 0, -1, 0, {}
        if type(src) ~= 'table' and type(src) ~= 'userdata' then return label .. '=' .. type(src) end
        pcall(function() for _, m in ipairs(src) do ip = ip + 1 end end)
        pcall(function() ln = #src end)
        pcall(function() for k, m in pairs(src) do pr = pr + 1 if #names < 4 then names[#names + 1] = tostring(m.text) end end end)
        return string.format('%s ip=%d len=%d pairs=%d [%s]', label, ip, ln, pr, table.concat(names, ','))
    end
    S.refresh_n = (S.refresh_n or 0) + 1
    local d_own, d_all = 'own=nil', 'all=nil'
    pcall(function() d_own = describe('own', own_map_markers) end)
    pcall(function() d_all = describe('all', all_map_markers) end)
    local detail = string.format('refresh #%d t=%d | found own %d all %d, listed own %d near %d | %s | %s | globals %s/%s%s%s',
        S.refresh_n, math.floor(Util.Now()), raw_own, raw_all, #S.own, #S.nearest, d_own, d_all, g_own, g_all, first, ok_b and '' or (' BUILD ERROR ' .. tostring(err_b)))
    S.diag = string.format('%d marker%s', #S.nearest, #S.nearest == 1 and '' or 's')
    AGLog.Detail('WRCS: %s', detail)

    -- Rebuild the wheel only when the lists changed (or when asked to).
    local sig = {}
    for _, e in ipairs(S.nearest) do sig[#sig + 1] = e.value end
    sig[#sig + 1] = '|'
    for _, e in ipairs(S.own) do sig[#sig + 1] = e.value end
    sig = table.concat(sig, '\n')
    local changed = force or (sig ~= S.marker_sig)
    S.marker_sig = sig
    if changed then
        Menu.Rebuild()
        S.resend = 6    -- send the center text again once the replaced menu is in place
    end
    broadcast_menu_status()
end

--------------------------------------------------------------------------------
-- Action listeners
--------------------------------------------------------------------------------

ListenTo("agp_wrcs_marker", "AGPlus_WrcsMarker", function(task, data_str)
    if not data_str or data_str == "" then
        task:CantDo()
        return
    end

    -- Format: "lat;lon;alt;name"
    local lat_str, lon_str, alt_str, name_str = string.match(data_str, "([^;]+);([^;]+);([^;]+);(.*)")
    if not lat_str or not lon_str then
        task:CantDo()
        return
    end

    S.marker = {
        lat = tonumber(lat_str),
        lon = tonumber(lon_str),
        alt = tonumber(alt_str) or 0,
        name = (name_str and name_str ~= "") and name_str or "Target Stake"
    }

    broadcast_menu_status()
    task:Roger()
    AGLog.Info('WRCS: marker selected -> %s (alt %d ft)', S.marker.name, math.floor(S.marker.alt + 0.5))
end)

-- Target Insert: freeze, dial the offsets, insert, slave the Pave Spike. The button presses and the
-- wait for the dials are done by the state machine in Tick.
ListenTo("agp_wrcs_insert", "AGPlus_WrcsInsert", function(task)
    local jester = GetJester()
    if not jester or not jester.awareness then
        task:CantDo()
        return
    end

    -- Jester answers in the negative when no marker is selected.
    if not S.marker then
        task:CantDo()
        return
    end

    local obs_lat = jester.awareness:GetObservation("latitude")
    local obs_lon = jester.awareness:GetObservation("longitude")
    local acft_lat = obs_lat and (obs_lat.value * RAD_TO_DEG) or 0
    local acft_lon = obs_lon and (obs_lon.value * RAD_TO_DEG) or 0
    if acft_lat == 0 or acft_lon == 0 then
        -- No usable position: refuse rather than insert offsets measured from a made-up point.
        task:CantDo()
        AGLog.Info('WRCS: Target Insert refused, aircraft position unavailable')
        return
    end

    local delta_n_ft, delta_e_ft, _, dist_nm = compute_marker_geometry(acft_lat, acft_lon, S.marker.lat, S.marker.lon)

    -- Physical WRCS offset dial range limit (+/- 99,900 ft)
    if math.abs(delta_n_ft) > 99900.0 or math.abs(delta_e_ft) > 99900.0 then
        local spoken = false
        if task and type(task.Say) == "function" then
            spoken = pcall(function() task:Say("Lantirn/toofar") end)
        end
        if not spoken then task:CantDo() end

        pcall(function()
            if PrintMessage then
                PrintMessage(string.format("WRCS: target '%s' is too far (%.1f NM). Maximum WRCS offset is 16.4 NM.", S.marker.name or "TGT", dist_nm))
            end
        end)

        broadcast_menu_status()
        AGLog.Info('WRCS: Target Insert rejected, target out of range (%.1f NM > 16.4 NM)', dist_nm)
        return
    end

    -- Rotate the true north / east offsets into the magnetic frame: the WRCS applies its own variation
    -- correction, so it expects magnetic-referenced offsets.
    local mag_dec_deg = get_mag_declination()
    local dec_rad = mag_dec_deg * DEG_TO_RAD
    local cos_dec = math.cos(dec_rad)
    local sin_dec = math.sin(dec_rad)
    local mag_n_ft = delta_n_ft * cos_dec + delta_e_ft * sin_dec
    local mag_e_ft = -delta_n_ft * sin_dec + delta_e_ft * cos_dec

    -- Dial values: raw feet (the knob handles the x100 scaling itself).
    local ns_val = math.floor(mag_n_ft + 0.5)
    local ew_val = math.floor(mag_e_ft + 0.5)
    local alt_val = math.floor(S.marker.alt + 0.5)

    -- Slave the Pave Spike to the WRCS.
    set_acq_switch(0.5)
    S.acq_mode = "WRCS"

    -- Freeze button: pressed here, released by the state machine.
    click_weapons("CURSOR_CTRL_PANEL_WSO_FREEZE_BUTTON", CMD_FREEZE, 1)

    -- Dial offsets (queued, they run after this handler returns).
    task:Click("North/South Offset", tostring(ns_val))
    task:Click("East/West Offset", tostring(ew_val))
    task:Click("Target Alt/Range", tostring(alt_val))

    S.tgt_ns, S.tgt_ew, S.tgt_alt = ns_val, ew_val, alt_val
    S.insert_stage = 60            -- freeze press, counts down
    S.dials_settled = false

    task:Roger()
    AGLog.Info('WRCS: Target Insert NS=%d EW=%d ALT=%d dist=%.1f NM var=%.1f (%s)', ns_val, ew_val, alt_val, dist_nm, mag_dec_deg, S.var_source or "?")
end)

ListenTo("agp_wrcs_refresh", "AGPlus_WrcsRefresh", function(task)
    local ok, err = pcall(refresh_dynamic_map_markers, S.last_lat, S.last_lon, S.last_fallback, true)
    if not ok then
        S.diag = 'REFRESH ERROR ' .. tostring(err)
        pcall(broadcast_menu_status)
        AGLog.Info('WRCS: refresh error: %s', tostring(err))
    end
    task:Roger()
end)

-- Reset Target Data: press the Reset button, hold it a few ticks (Tick releases it), clear the insert
-- sequence. The selected marker is kept for a quick re-insert.
ListenTo("agp_wrcs_reset", "AGPlus_WrcsReset", function(task)
    S.insert_stage = nil
    S.dials_settled = false
    S.settle_wait = nil
    S.tgt_ns, S.tgt_ew, S.tgt_alt = nil, nil, nil

    click_weapons("CURSOR_CTRL_PANEL_WSO_RESET_BUTTON", CMD_RESET, 1)
    S.reset_stage = 4

    S.last_dial = nil
    S.last_mult = nil

    broadcast_menu_status()
    task:Roger()
    if S.marker then
        AGLog.Info('WRCS: Reset Target Data (kept marker %s)', tostring(S.marker.name))
    else
        AGLog.Info('WRCS: Reset Target Data')
    end
end)

ListenTo("agp_wrcs_var_auto", "AGPlus_WrcsVarAuto", function(task)
    reset_auto_variation()
    task:Roger()
end)

-- Steps repeat while the wheel stays open, so Jester only acknowledges about once every 1.2 seconds.
ListenTo("agp_wrcs_var_step", "AGPlus_WrcsVarStep", function(task, delta_str)
    local delta = tonumber(delta_str)
    if delta then step_custom_variation(delta) end
    local now = Util.Now()
    if (now - S.last_var_roger) > 1.2 then
        S.last_var_roger = now
        task:Roger()
    end
end)

ListenTo("agp_wrcs_var_preset", "AGPlus_WrcsVarPreset", function(task, val_str)
    local val = tonumber(val_str)
    if val then set_custom_variation(val) end
    task:Roger()
end)

ListenTo("agp_wrcs_psmode", "AGPlus_WrcsPsMode", function(task, mode_id)
    local mode = PS_MODES[tostring(mode_id)]
    if not mode then task:CantDo() return end
    set_acq_switch(mode.value)
    S.acq_mode = mode.label
    broadcast_menu_status()
    pcall(function()
        local Sr = package.loaded['agplus.PaveSearch']
        if Sr and Sr.RedrawInfo then Sr.RedrawInfo() end
    end)
    task:Roger()
    AGLog.Info('WRCS: Pave Spike mode -> %s', mode.note)
end)

--------------------------------------------------------------------------------
-- Behavior
--------------------------------------------------------------------------------

function PaveSpikeWRCS:Constructor()
    Behavior.Constructor(self)
    self.current_cockpit = nil
    self.settle = 0
    self.tick_counter = 0
end

-- Target Insert state machine.
--   stage 60-58: freeze pressed, released at 58
--   stage 57-3:  wait for the dials to show the target values (stops waiting at stage 3)
--   stage 2-0:   insert pressed, released
local function run_insert(cockpit)
    local stage = S.insert_stage
    if not stage then return end

    if stage == 58 then
        click_weapons("CURSOR_CTRL_PANEL_WSO_FREEZE_BUTTON", CMD_FREEZE, 0)
        S.insert_stage = stage - 1

    elseif stage > 2 and not S.dials_settled then
        -- Do the dials show the target values? (50 ft tolerance, the dials step in 100 ft)
        local settled = false
        pcall(function()
            local m_ns = cockpit:GetManipulator("North/South Offset")
            local m_ew = cockpit:GetManipulator("East/West Offset")
            local m_alt = cockpit:GetManipulator("Target Alt/Range")
            if m_ns and m_ew and m_alt then
                local s_ns = m_ns:GetState()
                local s_ew = m_ew:GetState()
                local s_alt = m_alt:GetState()
                if math.abs(s_ns - (S.tgt_ns or 0)) < 50
                   and math.abs(s_ew - (S.tgt_ew or 0)) < 50
                   and math.abs(s_alt - (S.tgt_alt or 0)) < 50 then
                    settled = true
                end
            end
        end)
        if settled then
            S.dials_settled = true
            S.settle_wait = 10  -- 10 extra ticks after settling
        else
            S.insert_stage = stage - 1
        end

    elseif S.dials_settled and S.settle_wait and S.settle_wait > 0 then
        S.settle_wait = S.settle_wait - 1
        if S.settle_wait <= 0 then S.insert_stage = 2 end

    elseif stage == 2 then
        click_weapons("CURSOR_CTRL_PANEL_WSO_TGT_INSERT_BUTTON", CMD_INSERT, 1)
        S.insert_stage = stage - 1

    elseif stage <= 0 then
        click_weapons("CURSOR_CTRL_PANEL_WSO_TGT_INSERT_BUTTON", CMD_INSERT, 0)
        S.insert_stage = nil
        S.dials_settled = false
        S.settle_wait = nil
        S.tgt_ns, S.tgt_ew, S.tgt_alt = nil, nil, nil

    else
        S.insert_stage = stage - 1
    end
end

-- Reset button: held for a few ticks, then released.
local function run_reset()
    local r_stage = S.reset_stage
    if not r_stage then return end
    if r_stage <= 1 then
        click_weapons("CURSOR_CTRL_PANEL_WSO_RESET_BUTTON", CMD_RESET, 0)
        S.reset_stage = nil
    else
        S.reset_stage = r_stage - 1
    end
end

function PaveSpikeWRCS:Tick()
    S.tick_n = (S.tick_n or 0) + 1
    local ok, err = pcall(self.TickInner, self)
    if not ok then
        if S.last_err ~= tostring(err) then AGLog.Info('WRCS: tick error: %s', tostring(err)) end
        S.last_err = tostring(err)
    end
end

function PaveSpikeWRCS:TickInner()
    local cockpit = Util.Cockpit()
    if not cockpit then
        self.current_cockpit = nil
        self.settle = 0
        return
    end

    run_insert(cockpit)
    run_reset()

    if S.resend and S.resend > 0 then
        S.resend = S.resend - 1
        if S.resend == 0 then
            Menu.ClearInfoCache()
            broadcast_menu_status()
        end
    end

    local jester = GetJester()
    local obs_lat = jester and jester.awareness and jester.awareness:GetObservation("latitude")
    local obs_lon = jester and jester.awareness and jester.awareness:GetObservation("longitude")
    local acft_lat = obs_lat and (obs_lat.value * RAD_TO_DEG) or 0
    local acft_lon = obs_lon and (obs_lon.value * RAD_TO_DEG) or 0

    -- Height of the ground under the aircraft, from barometric minus radar altitude.
    local fallback_ground = 0
    local acft_baro_alt = 10000
    pcall(function()
        local obs_baro = jester and jester.awareness and jester.awareness:GetObservation("barometric_altitude")
        local obs_ralt = jester and jester.awareness and jester.awareness:GetObservation("radar_altitude")
        local acft_radar_alt = 0
        if obs_baro then
            if obs_baro.ConvertTo and ft then
                local ok_c, v_c = pcall(function() return obs_baro:ConvertTo(ft).value end)
                if ok_c and v_c then acft_baro_alt = v_c end
            elseif obs_baro.value then
                acft_baro_alt = obs_baro.value
            end
        end
        if obs_ralt then
            if obs_ralt.ConvertTo and ft then
                local ok_r, v_r = pcall(function() return obs_ralt:ConvertTo(ft).value end)
                if ok_r and v_r then acft_radar_alt = v_r end
            elseif obs_ralt.value then
                acft_radar_alt = obs_ralt.value
            end
        end
        if acft_baro_alt > 0 and acft_radar_alt > 0 and acft_baro_alt > acft_radar_alt then
            fallback_ground = acft_baro_alt - acft_radar_alt
        end
    end)

    -- Cached for the Refresh Markers button.
    S.last_lat, S.last_lon, S.last_fallback = acft_lat, acft_lon, fallback_ground

    -- Weapon and auto release range come from agplus.Mode (the Weapon menu).
    local wkey = Mode.WrcsKey() or "Mk82 LD"
    if wkey ~= S.weapon then
        S.weapon = wkey
        S.last_dial = nil
    end
    S.auto_rr = Mode.RrActive()

    -- New cockpit (spawn or respawn): read the markers now and again once the wheel has settled.
    if self.current_cockpit ~= cockpit then
        self.current_cockpit = cockpit
        self.settle = Config.MENU_SETTLE_TICKS
        S.last_dial = nil
        S.last_mult = nil
        refresh_dynamic_map_markers(acft_lat, acft_lon, fallback_ground)
    end
    if self.settle > 0 then
        self.settle = self.settle - 1
        if self.settle == 0 then
            refresh_dynamic_map_markers(acft_lat, acft_lon, fallback_ground)
        end
    end

    -- Periodic updates at about 2 Hz.
    self.tick_counter = (self.tick_counter or 0) + 1
    if self.tick_counter < 5 then return end
    self.tick_counter = 0

    -- Re-read the map markers about every 10 seconds, so a new marker shows up on its own.
    self.mark_cycles = (self.mark_cycles or 0) + 1
    if self.mark_cycles >= 20 then
        self.mark_cycles = 0
        refresh_dynamic_map_markers(acft_lat, acft_lon, fallback_ground)
    end

    if not jester or not jester.awareness then return end

    -- Auto release range in OFFSET delivery.
    local delivery_mode = Util.DeliveryMode()
    local is_offset_delivery = false
    if type(delivery_mode) == "string" then
        local upper = string.upper(delivery_mode)
        if string.find(upper, "OFFSET") or string.find(upper, "O/S") or string.find(upper, "LAYDOWN") then
            is_offset_delivery = true
        end
    elseif type(delivery_mode) == "number" then
        if delivery_mode > 0.05 then is_offset_delivery = true end
    end

    if S.auto_rr and is_offset_delivery then
        local obs_tas = jester.awareness:GetObservation("TAS")
        local tas_kts = 450
        if obs_tas then
            if obs_tas.ConvertTo and kt then
                local ok_t, v_t = pcall(function() return obs_tas:ConvertTo(kt).value end)
                if ok_t and v_t then tas_kts = v_t end
            elseif obs_tas.value then
                tas_kts = obs_tas.value
            end
        end

        local tgt_alt = (S.marker and S.marker.alt) or fallback_ground
        local h_agl = math.max(200.0, acft_baro_alt - tgt_alt)

        local rg_ft = calculate_ballistic_release_range(h_agl, tas_kts, S.weapon or "Mk82 LD")

        -- Range multiplier switch (0.0: NORM x10, 1.0: x100). The drum shows three digits (000 to 999):
        -- NORM shows Rg/10 (450 is 4,500 ft), x100 shows Rg/100 (287 is 28,700 ft).
        local target_mult, desired_drum
        if rg_ft > 9990.0 then
            target_mult = 1.0
            desired_drum = math.floor((rg_ft / 100.0) + 0.5)
        else
            target_mult = 0.0
            desired_drum = math.floor((rg_ft / 10.0) + 0.5)
        end
        local norm_axis = math.max(0.0, math.min(1.0, desired_drum / 1000.0))

        local mult_changed = (target_mult ~= S.last_mult)
        local val_changed = (S.last_dial == nil) or (math.abs(desired_drum - S.last_dial) >= 2)

        if mult_changed or val_changed then
            S.last_dial = desired_drum
            S.last_mult = target_mult
            click_weapons("WEAPON_DELIV_PANEL_WSO_RANGE_SWITCH", CMD_RANGE_SWITCH, target_mult)
            click_weapons("WEAPONS_WRCS_Range", CMD_RANGE_DRUM, norm_axis)
        end

        broadcast_menu_status(rg_ft, target_mult)
    else
        S.last_dial = nil
        S.last_mult = nil
        broadcast_menu_status(nil, nil)
    end
end

-- One-shot release range (Oct 22 2026): a LONG context press in OFFSET delivery sets the release range dial (and its x10 / x100 switch) once from
-- the armed weapon, the aircraft's true airspeed and its height above the target (the selected map marker's altitude, else the ground under the
-- aircraft), the way a long press programs the drag coefficient in TGT FIND.
function Wrcs.ProgramRange(task)
    local Dbg = require('agplus.PaveDebug')
    local function unable(why)
        Dbg.Notice('Release Range Unable - ' .. why, 4)
        AGLog.Info('wrcs: release range request refused: %s', why)
        task:CantDo()
    end
    local ok, err = pcall(function()
        local key, label
        local w, reason, names = Mode.ArmedWeapon()
        if w then
            key, label = w.wrcs, w.label
            if not key then unable(tostring(w.label) .. ' Has No Release Range Table') return end
        elseif reason == 'mixed' then unable('Mixed Stations Armed (' .. tostring(names) .. ')') return
        elseif reason == 'unknown' then unable('Unknown Weapon ' .. tostring(names)) return
        else
            key = Mode.WrcsKey()
            label = Mode.weapon and Mode.weapon.label
            if not key then unable('No Bomb Armed') return end
        end
        local jester = GetJester()
        local function obs_num(name, unit)
            local o = jester and jester.awareness and jester.awareness:GetObservation(name)
            if not o then return nil end
            if o.ConvertTo and unit then
                local okc, v = pcall(function() return o:ConvertTo(unit).value end)
                if okc and v then return v end
            end
            return o.value
        end
        local baro = obs_num('barometric_altitude', ft)
        local tas = obs_num('TAS', kt)
        if not baro or not tas then unable('No Aircraft Data') return end
        local tgt_alt = (S.marker and S.marker.alt) or S.last_fallback or 0
        local h_agl = math.max(200.0, baro - tgt_alt)
        local rg_ft = calculate_ballistic_release_range(h_agl, tas, key)
        local mult, drum
        if rg_ft > 9990.0 then mult, drum = 1.0, math.floor(rg_ft / 100.0 + 0.5)
        else mult, drum = 0.0, math.floor(rg_ft / 10.0 + 0.5) end
        S.last_dial, S.last_mult = drum, mult
        click_weapons("WEAPON_DELIV_PANEL_WSO_RANGE_SWITCH", CMD_RANGE_SWITCH, mult)
        click_weapons("WEAPONS_WRCS_Range", CMD_RANGE_DRUM, math.max(0.0, math.min(1.0, drum / 1000.0)))
        Dbg.Notice(string.format('Release Range %.0f ft Set - %s (%.0f ft above the target, %.0f kt)', rg_ft, tostring(label or key), h_agl, tas), 5)
        AGLog.Info('wrcs: release range one shot %.0f ft (%s, %.0f ft AGL, %.0f kt TAS, target alt %.0f ft)', rg_ft, tostring(key), h_agl, tas, tgt_alt)
        task:Roger()
    end)
    if not ok then
        AGLog.Info('wrcs: release range request failed: %s', tostring(err))
        task:CantDo()
    end
end

return Wrcs
