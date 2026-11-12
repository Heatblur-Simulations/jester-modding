-- Shared weapon state for A/G+, plus the Weapon wheel menu and the center text.
--
--   Mode.weapon : the weapon entry in use (nil = none), picked from the Weapon menu or followed from the armed stations
--
-- The drag coefficient and the release range are each set once by a long context press (TGT FIND and OFFSET delivery). Mode.mode stays nil, so the other modules (Lgb, Wrcs) never run anything on their own.
-- The center text shows the weapon, the Delivery Mode knob (or J-Mav while Jester Maverick is working) and the target.
local Class = require('base.Class')
local Behavior = require('base.Behavior')
local Config = require('agplus.Config')
local AGLog = require('agplus.Log')
local Util = require('agplus.Util')
local Menu = require('agplus.Menu')
local Stores = require('agplus.Stores')

local Mode = {}

--------------------------------------------------------------------------------
-- Weapons. wrcs = release range table key, lgb = drag coefficient table key (nil = not available for the weapon). ws = wsType level 4 of the
-- store (4/5/36/ws). Weapons with neither table are only named in the center text, they are not in the Weapon menu.
--------------------------------------------------------------------------------

local CATEGORIES = {
    { name = "Guns", weapons = {
        { label = "20mm Vulcan",   ccip = "20mm Vulcan" },
        { label = "GPU-5 Gun Pod", ccip = "GAU-13" },
    } },
    { name = "GP Bombs", weapons = {
        { label = "Mk-82 LD",      ccip = "Mk82 LD",  wrcs = "Mk82 LD",  ws = 31 },
        { label = "Mk-82 Snakeye", ccip = "Mk82 SE",  wrcs = "Mk82 SE",  ws = 79 },
        { label = "Mk-82 AIR",     ccip = "Mk82 AIR", wrcs = "Mk82 AIR", ws = 75 },
        { label = "Mk-83",         ccip = "Mk83",     wrcs = "Mk83",     ws = 32 },
        { label = "Mk-84",         ccip = "Mk84",     wrcs = "Mk84",     ws = 33 },
    } },
    { name = "Precision / LGB", weapons = {
        { label = "GBU-12", ccip = "GBU-12", wrcs = "GBU-12", lgb = "GBU-12", ws = 38 },
        { label = "GBU-10", ccip = "GBU-10", wrcs = "GBU-10", lgb = "GBU-10", ws = 36 },
        { label = "GBU-24", ccip = "GBU-24", wrcs = "GBU-24", lgb = "GBU-24", ws = 41 },
    } },
    { name = "Cluster Munitions", weapons = {
        { label = "Mk20 Rockeye",   ccip = "Mk20 Rockeye",   ws = 45 },
        { label = "CBU-87 (1500')", ccip = "CBU-87 (1500')", wrcs = "CBU-87", ws = 77 },
        { label = "CBU-87 (900')",  ccip = "CBU-87 (900')",  wrcs = "CBU-87" },
    } },
    { name = "Special Pods", weapons = {
        { label = "BLU-49/B", ccip = "BLU-49/B" },
        { label = "BLU-18/B", ccip = "BLU-18/B" },
    } },
    { name = "Rockets", weapons = {
        { label = "Hydra 2.75 FFAR", ccip = "Hydra 2.75 FFAR" },
        { label = "Zuni Rockets",    ccip = "Zuni Rockets" },
    } },
}

local BY_ID = {}      -- wheel id -> weapon
local BY_WS = {}      -- wsType level 4 -> weapon
do
    local n = 0
    for _, cat in ipairs(CATEGORIES) do
        for _, w in ipairs(cat.weapons) do
            n = n + 1
            w.id = tostring(n)
            BY_ID[w.id] = w
            if w.ws then BY_WS[w.ws] = w end
        end
    end
end

-- hidden = true: named in the center text and still usable by the one-shot presses, but not offered in the Weapon menu.
local function usable(w) return (w.wrcs ~= nil or w.lgb ~= nil) and not w.hidden end

Mode.weapon = nil
Mode.mode = nil           -- always nil: Lgb and Wrcs never run on their own
Mode.mixed = nil          -- "GBU-12/GBU-10" while more than one weapon type is armed

--------------------------------------------------------------------------------
-- What the other modules read
--------------------------------------------------------------------------------

function Mode.Resolved() return nil end
function Mode.DragKey() return nil end
function Mode.RrActive() return false end

-- The weapon type on the armed stations, read fresh from the payload feed and the station lamps. Returns the weapon, or nil and
-- a reason: "none" (no armed bomb), "mixed" (more than one type, with the names in the third result) or "unknown".
function Mode.ArmedWeapon()
    Stores.ReadFeed()
    local seen, names, w1, unknown = {}, {}, nil, false
    for _, s in ipairs(Stores.ArmedBombs()) do
        local w = BY_WS[s.l4]
        local key = w and w.label or ("type " .. tostring(s.l4))
        if not seen[key] then
            seen[key] = true
            names[#names + 1] = key
            if w then w1 = w else unknown = true end
        end
    end
    if #names == 0 then return nil, "none" end
    if #names > 1 then table.sort(names) return nil, "mixed", table.concat(names, "/") end
    if unknown then return nil, "unknown", names[1] end
    return w1
end

-- Weapon key for the release range tables (nil = none picked or no table).
function Mode.WrcsKey()
    return Mode.weapon and Mode.weapon.wrcs or nil
end

--------------------------------------------------------------------------------
-- Menu
--------------------------------------------------------------------------------

local WEAPON_TAILS = { { "Weapon" } }
for _, cat in ipairs(CATEGORIES) do
    for _, w in ipairs(cat.weapons) do
        if usable(w) then WEAPON_TAILS[#WEAPON_TAILS + 1] = { "Weapon", cat.name } break end
    end
end

local function leaf(name, action, value)
    return Wheel.Item:new({ name = name, action = action, action_value = value, reaction = Wheel.Reaction.CLOSE_REMEMBER })
end

function Mode.BuildWeaponItem()
    local cats = {}
    for _, cat in ipairs(CATEGORIES) do
        local items = {}
        for _, w in ipairs(cat.weapons) do
            if usable(w) then items[#items + 1] = leaf(w.label, "agp_weapon_pick", w.id) end
        end
        if #items > 0 then
            cats[#cats + 1] = Wheel.Item:new({ name = cat.name, menu = Wheel.Menu:new({ name = cat.name, items = items }) })
        end
    end
    return Wheel.Item:new({ name = "Weapon", menu = Wheel.Menu:new({ name = "Weapon", items = cats }) })
end

ListenTo("agp_weapon_pick", "AGPlus_WeaponPick", function(task, id)
    local w = BY_ID[tostring(id)]
    if not w then task:CantDo() return end
    Mode.weapon = w
    task:Roger()
    AGLog.Info('weapon: %s', w.label)
end)

--------------------------------------------------------------------------------
-- Center text
--------------------------------------------------------------------------------

-- The Mavericks on the armed stations ("AGM-65A", "AGM-65A/D"), or nil.
local function mav_armed_names()
    local M = package.loaded['agplus.Maverick']
    if not (M and M.Loadout) then return nil end
    local ok, list = pcall(M.Loadout)
    if not ok or type(list) ~= 'table' then return nil end
    local seen, names = {}, {}
    for _, m in ipairs(list) do
        if m.armed and not seen[m.variant] then
            seen[m.variant] = true
            names[#names + 1] = 'AGM-65' .. tostring(m.variant)
        end
    end
    table.sort(names)
    return #names > 0 and table.concat(names, '/') or nil
end

-- J-Mav: Jester Maverick is on, Mavericks are armed, and the Delivery Mode and TV conditions for it are met.
local function mav_working()
    local M = package.loaded['agplus.Maverick']
    if not (M and M.State and M.State.on) then return false end
    if M.ModeActive then
        local ok, active = pcall(M.ModeActive)
        if ok and not active then return false end
    end
    return true
end

-- The Delivery Mode knob as the pilot sees it.
local function knob_text()
    local raw = string.upper(tostring(Util.DeliveryMode() or ''))
    if raw == '' or raw == 'NIL' then return 'Unknown' end
    if string.find(raw, 'DIR') then return 'Direct' end
    if string.find(raw, 'TGT') then return 'TGT Find' end
    if string.find(raw, 'OFFSET') then return 'Offset' end
    if raw == 'OFF' then return 'Off' end
    return (raw:gsub('_', ' '):gsub('(%a)(%w*)', function(a, b) return a:upper() .. b:lower() end))
end

local function weapon_text()
    local wname
    if Mode.mixed then
        wname = "MIXED " .. Mode.mixed
    else
        wname = Mode.weapon and Mode.weapon.label or "none"
    end
    local mav = mav_armed_names()
    if mav then wname = (wname == "none") and mav or (wname .. " + " .. mav) end
    return wname
end

local function status_text()
    return string.format("Weapon: %s\nMode: %s", weapon_text(), mav_working() and "J-Mav" or knob_text())
end

-- The same state the A/G Plus menu shows, for other menus (the Pave Spike target menu).
function Mode.StatusText() return status_text() end

-- Just the weapon, for the Pave Spike menu text.
function Mode.WeaponText() return weapon_text() end

local ModeBehavior = Class(Behavior)
Mode.Behavior = ModeBehavior

function ModeBehavior:Constructor()
    Behavior.Constructor(self)
    self.current_cockpit = nil
    self.n = 0
end

function ModeBehavior:Tick()
    local cockpit = Util.Cockpit()
    if not cockpit then
        self.current_cockpit = nil
        return
    end
    if self.current_cockpit ~= cockpit then
        self.current_cockpit = cockpit
        Mode.weapon, Mode.mixed = nil, nil
        self.armed_key = nil
        self.n = 0
    end

    self.n = self.n + 1
    if self.n < 5 then return end            -- about twice a second
    self.n = 0
    if (self.feed_n or 0) <= 0 then
        self.feed_n = 2                       -- re-read the feed file about once a second
        Stores.ReadFeed()
    else
        self.feed_n = self.feed_n - 1
    end

    -- Which weapon types are armed right now?
    local seen, names = {}, {}
    for _, s in ipairs(Stores.ArmedBombs()) do
        local w = BY_WS[s.l4]
        if w and not seen[w] then
            seen[w] = true
            names[#names + 1] = w.label
        end
    end
    if #names > 1 then
        table.sort(names)
        Mode.mixed = table.concat(names, "/")
        self.armed_key = nil                  -- so a return to a single type is picked up again
    else
        Mode.mixed = nil
        -- When the armed stations change to a single known weapon type, that becomes the weapon. A weapon picked from the menu stays
        -- until the armed stations change again.
        local key = names[1]
        if key and key ~= self.armed_key then
            for w in pairs(seen) do
                Mode.weapon = w
                AGLog.Info('weapon follows armed stations -> %s', w.label)
            end
        end
        self.armed_key = key or self.armed_key
    end

    local text = status_text()
    local root = text
    pcall(function()
        local PS = package.loaded['agplus.PaveSearch']
        if PS and PS.TargetLine then root = text .. '\n' .. PS.TargetLine() end
    end)
    Menu.SetInfo({}, root)
    Menu.SetInfoAll(WEAPON_TAILS, text)
end

return Mode
