-- One context item on the Jester root wheel (Nov 2026). It shows what the pilot has set up: Maverick (TV weapon mode), Bombs (any
-- Delivery Mode other than OFF) or A/A Plus (Delivery Mode OFF), with the actions used most often in that case one press from the root.
-- The full A/G Plus item stays where it was (Air To Ground > A/G Plus); every menu here ends with a link to it.
-- Config.ROOT_MENU = false switches the whole item off. Config.ROOT_MENU_NAMES = false keeps one fixed name ("Combat") instead of
-- changing the name with the context.
local Class = require('base.Class')
local Behavior = require('base.Behavior')
local Config = require('agplus.Config')
local AGLog = require('agplus.Log')
local Util = require('agplus.Util')
local Menu = require('agplus.Menu')
local LaserCode = require('agplus.LaserCode')

local RootMenu = {}

local PATH = {}                     -- the root of the Jester wheel
local NAMES = { MAV = 'Maverick', BOMB = 'Bombs', AA = 'A/A Plus' }
local FIXED_NAME = 'Combat'
local CHECK_S = 0.5                 -- how often the context is read
local CONFIRM_SAMPLES = 2           -- the same new context this many reads in a row before the item changes

local shown_name = nil              -- name of the item on the wheel now (nil = none)
local shown_ctx = nil               -- context it was built for: 'MAV', 'BOMB', 'AA' or 'NONE'

local function loaded(name) return package.loaded[name] end

-- The name of the item that is on the root wheel now (nil = none). LaserCode.lua needs it for the center text paths.
function RootMenu.ShownName() return shown_name end

local function name_for(ctx)
    if Config.ROOT_MENU_NAMES == false then return FIXED_NAME end
    return NAMES[ctx]
end

--------------------------------------------------------------------------------
-- Context
--------------------------------------------------------------------------------

-- The pilot's weapon selector knob as the manipulator reports it (nil when unreadable).
local function weapon_select()
    local raw = nil
    pcall(function()
        local c = GetJester():GetCockpit()
        local m = c and c:GetManipulator('Weapon Selection')
        if m then raw = m:GetState() end
    end)
    return raw
end

-- Position B of the weapon selector is the pilot's air-to-air switch: it overrides the Delivery Mode knob and allows A/A weapons.
-- (Position A can also release A/A weapons, but only as a fail-safe, so it does not count.)
local function is_position_b(raw)
    local u = string.upper(tostring(raw or ''))
    return u == 'B' or string.find(u, '[^%a]B$') ~= nil
end

local last_key = nil
local function log_inputs(ws, dm)
    local key = tostring(ws) .. '|' .. tostring(dm)
    if key ~= last_key then
        last_key = key
        AGLog.Info('root menu: Weapon Selection = %s, Delivery Mode = %s', tostring(ws), tostring(dm))
    end
end

-- Returns 'MAV', 'BOMB', 'AA', 'NONE' (nothing to show) or nil (not readable right now, keep what is shown).
local function read_context()
    local ws = weapon_select()
    local dm = string.upper(tostring(Util.DeliveryMode() or ''))
    log_inputs(ws, dm)
    local Mav = loaded('agplus.Maverick')
    if Mav and Mav.ModeActive then
        local ok, active = pcall(Mav.ModeActive)
        if ok and active then return 'MAV' end
    end
    if dm == '' or dm == 'NIL' then return nil end
    if is_position_b(ws) or dm == 'OFF' then
        if not loaded('aaplus.Director') then return 'NONE' end    -- A/A+ is not installed
        return 'AA'
    end
    return 'BOMB'
end

--------------------------------------------------------------------------------
-- Items (the wheel consumes items, so every build makes fresh ones)
--------------------------------------------------------------------------------

local function leaf(name, action, value, reaction)
    return Wheel.Item:new({ name = name, action = action, action_value = value, reaction = reaction or Wheel.Reaction.CLOSE_REMEMBER })
end

local function sub(name, items)
    return Wheel.Item:new({ name = name, menu = Wheel.Menu:new({ name = name, items = items }) })
end

local function built(fn, ...)
    if not fn then return nil end
    local ok, item = pcall(fn, ...)
    if ok then return item end
    AGLog.Info('root menu: an item failed to build: %s', tostring(item))
    return nil
end

local function pave_spike_item()
    local S = loaded('agplus.PaveSearch')
    local items = {}
    if S and S.BuildLaserItem then items[#items + 1] = built(S.BuildLaserItem) end
    items[#items + 1] = built(LaserCode.BuildItem)
    items[#items + 1] = Wheel.Item:new({
        name = 'Acquisition Mode',
        outer_menu = Wheel.Menu:new({
            name = 'Acquisition Mode',
            items = {
                Wheel.Item:new({ name = '12 Vis', action = 'agp_wrcs_psmode', action_value = '12VIS', reaction = Wheel.Reaction.NOTHING }),
                Wheel.Item:new({ name = 'WRCS',   action = 'agp_wrcs_psmode', action_value = 'WRCS',  reaction = Wheel.Reaction.NOTHING }),
                Wheel.Item:new({ name = '9 Vis',  action = 'agp_wrcs_psmode', action_value = '9VIS',  reaction = Wheel.Reaction.NOTHING }),
            },
        }),
    })
    return sub('Pave Spike', items)
end

local function build_items(ctx)
    local items = {}
    local function add(item) if item then items[#items + 1] = item end end
    local T = loaded('agplus.Targets')
    local Mav = loaded('agplus.Maverick')
    local Mode = loaded('agplus.Mode')
    local Wrcs = loaded('agplus.Wrcs')

    if ctx == 'MAV' then
        add(T and built(T.BuildItem, true))
        if Mav and Mav.BuildQuickItems then
            local ok, list = pcall(Mav.BuildQuickItems)
            if ok and list then for _, it in ipairs(list) do add(it) end end
        end
        add(built(Menu.BuildTop))
    elseif ctx == 'BOMB' then
        add(T and built(T.BuildItem, true))
        add(leaf('Search Area', 'agp_pave_search'))
        add(built(pave_spike_item))
        add(Mode and built(Mode.BuildWeaponItem))
        add(Wrcs and built(Wrcs.BuildItem))
        add(built(Menu.BuildTop))
    elseif ctx == 'AA' then
        add(leaf('Unified', 'aad_mode_unified'))
        add(leaf('Pilot', 'aad_mode_pilot'))
        add(leaf('Off', 'aad_mode_off'))
    end
    return items
end

local function build_item(ctx)
    local items = build_items(ctx)
    if #items == 0 then return nil end
    local name = name_for(ctx)
    return Wheel.Item:new({ name = name, menu = Wheel.Menu:new({ name = name, items = items }) })
end

--------------------------------------------------------------------------------
-- Wheel
--------------------------------------------------------------------------------

local function remove(name)
    if name then pcall(function() Wheel.RemoveItem(name, PATH) end) end
end

-- Removes every item this module can have put on the root wheel. Used before each add, so an item left from an earlier context (for
-- example after a respawn, when this module no longer knows it was added) cannot stay next to the new one.
local function remove_all()
    for _, n in pairs(NAMES) do remove(n) end
    remove(FIXED_NAME)
    shown_name = nil
end

local function add_new(ctx, item)
    local ok, err = pcall(function() Wheel.AddItem(item, PATH) end)
    if ok then
        shown_name, shown_ctx = name_for(ctx), ctx
    else
        shown_name, shown_ctx = nil, nil
        AGLog.Info('root menu: AddItem failed: %s', tostring(err))
    end
    return ok
end

-- Puts the item for ctx on the root wheel. Same name as the item that is there: replaced in place (keeps its slot, does not close
-- an open wheel). Different name or nothing there yet: removed and added again.
local function put(ctx)
    if ctx == 'NONE' then
        remove_all()
        shown_ctx = 'NONE'
        AGLog.Info('root menu: nothing to show, item removed')
        return
    end
    local item = build_item(ctx)
    if not item then return end
    local name = name_for(ctx)
    if shown_name and shown_name == name then
        local ok, err = pcall(function() Wheel.ReplaceItem(item, name, PATH) end)
        if ok then
            if shown_ctx ~= ctx then AGLog.Info('root menu: %s -> %s (replaced in place)', tostring(shown_ctx), ctx) end
            shown_ctx = ctx
            pcall(LaserCode.SendInfo)
            return
        end
        AGLog.Info('root menu: ReplaceItem failed (%s), removing and adding again', tostring(err))
        item = build_item(ctx)
        if not item then return end
    end
    remove_all()
    if add_new(ctx, item) then AGLog.Info('root menu: %s shown as "%s"', ctx, name) end
    pcall(LaserCode.SendInfo)
end

-- Called by Menu.lua after the A/G Plus item was rebuilt (a setting changed): the root item shows the same state.
Menu.AfterRebuild = function()
    if Config.ROOT_MENU == false then return end
    if shown_name and shown_ctx and shown_ctx ~= 'NONE' then put(shown_ctx) end
end

-- Called by Menu.lua after a (re)spawn wiped the wheel and the A/G Plus item was registered again.
Menu.AfterRegister = function()
    if Config.ROOT_MENU == false then return end
    remove_all()
    shown_ctx = nil
    local ctx = read_context()
    if ctx then put(ctx) end
end

--------------------------------------------------------------------------------
-- Clicks from the root menu: note where the click came from, then pass it on to the normal handler. Menu.NavPath then sends the wheel
-- back to this menu instead of the A/G Plus page.
--------------------------------------------------------------------------------

local function forward(root_event, real_event, handler_name)
    ListenTo(root_event, handler_name, function(task, value)
        if shown_name then Menu.root_click = { name = shown_name, t = Util.Now() } end
        Dispatch(real_event, value)
    end)
end
forward('agp_root_mav', 'agp_mav', 'AGPlus_RootMav')
forward('agp_root_strike', 'agp_strike', 'AGPlus_RootStrike')
forward('agp_root_pave_refresh', 'agp_pave_refresh', 'AGPlus_RootPaveRefresh')
forward('agp_root_pave_purge', 'agp_pave_purge', 'AGPlus_RootPavePurge')
forward('agp_root_pave_delunit', 'agp_pave_delunit', 'AGPlus_RootPaveDelUnit')

--------------------------------------------------------------------------------
-- Behavior: reads the context twice a second and changes the item when it has changed twice in a row
--------------------------------------------------------------------------------

local B = Class(Behavior)
RootMenu.Behavior = B

function B:Constructor()
    Behavior.Constructor(self)
    self.last_check = 0
    self.cand, self.cand_n = nil, 0
end

function B:Tick()
    local t = Util.Now()
    if Config.ROOT_MENU == false then return end
    if not Util.Cockpit() then
        shown_name, shown_ctx = nil, nil
        self.cand, self.cand_n = nil, 0
        return
    end
    if not Menu.registered then return end
    if t - self.last_check < CHECK_S then return end
    self.last_check = t
    local ctx = read_context()
    if ctx == nil or ctx == shown_ctx then
        self.cand, self.cand_n = nil, 0
        return
    end
    if ctx == self.cand then self.cand_n = self.cand_n + 1 else self.cand, self.cand_n = ctx, 1 end
    if self.cand_n >= CONFIRM_SAMPLES then
        self.cand, self.cand_n = nil, 0
        put(ctx)
    end
end

return RootMenu
