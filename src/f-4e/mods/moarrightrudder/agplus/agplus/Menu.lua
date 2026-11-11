-- The one A/G+ wheel item. Everything A/G+ offers sits inside it, so the item keeps its place on the
-- Air To Ground wheel. After the first registration it is only ever updated in place with
-- Wheel.ReplaceItem (never Remove + Add), which keeps its position. Remove + Add is used only when a
-- (re)spawn has wiped the wheel.
local Class = require('base.Class')
local Behavior = require('base.Behavior')
local Config = require('agplus.Config')
local AGLog = require('agplus.Log')

local Menu = {}

local providers = {}      -- { name, build } in the order they were provided
local roots = {}          -- items that live on another native wheel menu: { parent, name, build }
local info_cache = {}     -- last center text sent per menu path
Menu.registered = false

-- A provider returns a fresh Wheel.Item (static name) each time it is called.
function Menu.Provide(name, build)
    providers[#providers + 1] = { name = name, build = build }
end

-- An item that sits on a native wheel menu of its own, for example INS Update under Navigation. parent is the native path,
-- e.g. { "Navigation" }. It is registered, refreshed and given its center text like the A/G Plus item.
function Menu.ProvideAt(parent, name, build)
    roots[#roots + 1] = { parent = parent, name = name, build = build }
end

local function root_for(name)
    for _, r in ipairs(roots) do
        if r.name == name then return r end
    end
    return nil
end

local function register_roots(replace)
    for _, r in ipairs(roots) do
        local ok, item = pcall(r.build)
        if ok and item then
            local ok2, err
            if replace then
                ok2, err = pcall(function() Wheel.ReplaceItem(item, r.name, r.parent) end)
            else
                pcall(function() Wheel.RemoveItem(r.name, r.parent) end)
                ok2, err = pcall(function() Wheel.AddItem(item, r.parent) end)
            end
            if not ok2 then AGLog.Info('menu: %s on %s failed: %s', r.name, table.concat(r.parent, '/'), tostring(err)) end
        else
            AGLog.Info('menu: %s failed to build: %s', r.name, tostring(item))
        end
    end
end

-- The order of the A/G+ wheel (Oct 22 2026): Strike List, Maverick, Pave Spike, WRCS Integration, Weapon, then anything else (the dev
-- menus) last. Providers that are not listed keep their registration order after these.
local ORDER = { ['Strike List'] = 1, ['Maverick'] = 2, ['Pave Spike'] = 3, ['WRCS Integration'] = 4, ['Weapon'] = 5, ['Dev Tools'] = 99 }

local function build_top()
    local items = {}
    local sorted = {}
    for i, p in ipairs(providers) do sorted[#sorted + 1] = { p = p, i = i, r = ORDER[p.name] or 50 } end
    table.sort(sorted, function(a, b) if a.r ~= b.r then return a.r < b.r end return a.i < b.i end)
    for _, e in ipairs(sorted) do
        local p = e.p
        local ok, item = pcall(p.build)
        if ok and item then
            items[#items + 1] = item
        else
            AGLog.Info('menu: %s failed to build: %s', p.name, tostring(item))
        end
    end
    return Wheel.Item:new({
        name = Config.MENU_NAME,
        menu = Wheel.Menu:new({ name = Config.MENU_NAME, items = items }),
    })
end

-- Fresh registration: used right after a (re)spawn.
function Menu.Register()
    info_cache = {}
    pcall(function() Wheel.RemoveItem(Config.MENU_NAME, Config.MENU_PARENT) end)
    local ok, err = pcall(function() Wheel.AddItem(build_top(), Config.MENU_PARENT) end)
    Menu.registered = ok and true or false
    if not ok then AGLog.Info('menu: AddItem failed: %s', tostring(err)) end
    register_roots(false)
end

-- In-place update: the item keeps its slot. Does nothing until the menu has been registered.
function Menu.Rebuild()
    if not Menu.registered then return end
    info_cache = {}
    local ok, err = pcall(function() Wheel.ReplaceItem(build_top(), Config.MENU_NAME, Config.MENU_PARENT) end)
    if not ok then AGLog.Info('menu: ReplaceItem failed: %s', tostring(err)) end
    register_roots(true)
end

-- Center text of a menu inside A/G+. tail is the path below A/G+, for example { "Weapon", "GP Bombs" }.
-- Only sends when the text changed (the cache is cleared whenever the menu is rebuilt).
function Menu.SetInfo(tail, text)
    local key = table.concat(tail, '/')
    if info_cache[key] == text then return end
    info_cache[key] = text
    local path = { Config.MENU_PARENT[1], Config.MENU_NAME }
    for _, name in ipairs(tail) do path[#path + 1] = name end
    pcall(function() Wheel.SetMenuInfo(text, path) end)
end

-- Center text of an item by its name, wherever it lives: an item provided with ProvideAt uses its own parent path, anything
-- else is looked up inside A/G Plus.
function Menu.SetInfoFor(name, text)
    local r = root_for(name)
    if not r then
        Menu.SetInfo({ name }, text)
        return
    end
    local path = {}
    for _, p in ipairs(r.parent) do path[#path + 1] = p end
    path[#path + 1] = r.name
    local key = table.concat(path, '/')
    if info_cache[key] == text then return end
    info_cache[key] = text
    pcall(function() Wheel.SetMenuInfo(text, path) end)
end

-- Forget what was last sent, so the next SetInfo goes out again.
function Menu.ClearInfoCache()
    info_cache = {}
end

-- Same text on several menus.
function Menu.SetInfoAll(tails, text)
    for _, tail in ipairs(tails) do Menu.SetInfo(tail, text) end
end

-- Detects a new cockpit (spawn or respawn) and registers the menu now and again after the
-- cockpit and wheel have settled, because the C++ side rebuilds the wheel a few seconds after spawn.
local MenuBehavior = Class(Behavior)
Menu.Behavior = MenuBehavior

function MenuBehavior:Constructor()
    Behavior.Constructor(self)
    self.current_cockpit = nil
    self.settle = 0
end

function MenuBehavior:Tick()
    local cockpit = nil
    pcall(function()
        local j = GetJester()
        if j then cockpit = j:GetCockpit() end
    end)
    if not cockpit then
        self.current_cockpit = nil
        self.settle = 0
        Menu.registered = false
        return
    end
    if self.current_cockpit ~= cockpit then
        self.current_cockpit = cockpit
        self.settle = Config.MENU_SETTLE_TICKS
        Menu.Register()
    end
    if self.settle > 0 then
        self.settle = self.settle - 1
        if self.settle == 0 then Menu.Register() end
    end
end

return Menu
