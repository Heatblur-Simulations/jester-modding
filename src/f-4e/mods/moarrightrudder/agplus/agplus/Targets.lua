-- Jester Mavericks, Phase 1-2 (Oct 21 2026): the unified target list and the Strike List.
--
-- Sources: anything that can list targets registers itself with Targets.AddSource (the Pave Spike search does, a Maverick seeker will).
-- Strike List: up to six slots the player fills and orders, under A/G Plus > Strike List. Each slot keeps its own copy of the target
-- (position and name), so purging the pod's search list does not empty it. Jester can send the pod to a slot, and with Auto Advance on he
-- steps the pod to the next filled slot after the held target has passed and the laser is off (PaveSearch calls Targets.OnPassed).
-- Reads nothing from Config except optional STRIKE_* values with defaults here: STRIKE_AUTO_ADVANCE (true), STRIKE_ADVANCE_DELAY_S (3, read in PaveSearch).
local Class = require('base.Class')
local Behavior = require('base.Behavior')
local Config = require('agplus.Config')
local AGLog = require('agplus.Log')
local Menu = require('agplus.Menu')
local Dbg = require('agplus.PaveDebug')
local Util = require('agplus.Util')

local Targets = {}

local TOP = 'Strike List'
local N = 6                                   -- slots; six slots plus Add Current Target and Manage fill the eight places of a wheel menu
local slots = {}                              -- [i] = snapshot or nil
local cur_slot = nil                          -- the slot the pod was last sent to
local auto_advance = (Config.STRIKE_AUTO_ADVANCE ~= false)
local auto_fill = (Config.STRIKE_AUTO_FILL ~= false)       -- Oct 22 2026: units found by a search fill empty slots as they join the target list
local list_full = (Config.CONTEXT_LIST_SOURCE == 'full')   -- Nov 11 2026: what the pod's Context List steps through: the Strike List slots (false) or the full target list (true)
local af_skip = {}                            -- ids the player cleared or deleted: Auto Fill leaves them alone
local sources = {}                            -- { name, list = function() return entries end }

--------------------------------------------------------------------------------
-- Sources
--------------------------------------------------------------------------------

function Targets.AddSource(name, list_fn)
    for _, s in ipairs(sources) do
        if s.name == name then s.list = list_fn return end
    end
    sources[#sources + 1] = { name = name, list = list_fn }
end

-- Every listed target of every source, each source in its own order, a unit seen by two sources once.
function Targets.All()
    local out, seen = {}, {}
    for _, s in ipairs(sources) do
        local ok, list = pcall(s.list)
        if ok and type(list) == 'table' then
            for _, e in ipairs(list) do
                if e.spot or not seen[e.id] then
                    seen[e.id] = true
                    out[#out + 1] = e
                end
            end
        end
    end
    return out
end

local function Search()
    return package.loaded['agplus.PaveSearch']
end

Targets.AddSource('pod', function()
    local S = Search()
    if S and S.FlatList then return S.FlatList() end
    return {}
end)

--------------------------------------------------------------------------------
-- Slots
--------------------------------------------------------------------------------

local function pretty(name)
    return (tostring(name or '?'):gsub('_', ' '))
end

local function snap(e)
    return { id = e.id, name = e.name, alias = e.alias or pretty(e.name), cat = e.cat, x = e.x, y = e.y, z = e.z, spot = e.spot, d_aim = e.d_aim or 0 }
end

local function slot_name(i)
    local s = slots[i]
    return s and s.alias or 'Empty'
end

local function find_id(e)
    if e.spot then return nil end   -- ground spots are all id -1: each one is its own target
    for i = 1, N do
        if slots[i] and not slots[i].spot and slots[i].id == e.id then return i end
    end
    return nil
end

local function first_empty()
    for i = 1, N do
        if not slots[i] then return i end
    end
    return nil
end

local function count()
    local n = 0
    for i = 1, N do if slots[i] then n = n + 1 end end
    return n
end

--------------------------------------------------------------------------------
-- Menu
--------------------------------------------------------------------------------

-- Every change keeps the wheel open: the menu is rebuilt and the wheel is sent back to the Strike List page (see refresh), so a player
-- can fill and order the list without backing out to the root menu each time. Go To closes it, the pod is on its way.
local function leaf(name, value, reaction)
    return Wheel.Item:new({ name = name, action = 'agp_strike', action_value = value, reaction = reaction or Wheel.Reaction.NOTHING })
end

-- Picking a target from the pod's list for one slot: categories, then the units, paged like the Pave Spike Targets menu.
local PAGE = 7
local function pick_units(slot, entries, title)
    local n = #entries
    local pages, r = 1, n
    while r > 8 do r = r - PAGE pages = pages + 1 end
    local function build(first, page)
        local items = {}
        local last = (n - first + 1 > 8) and (first + PAGE - 1) or n
        for k = first, last do
            local e = entries[k]
            items[#items + 1] = leaf(e.alias or pretty(e.name), string.format('pick;%d;%d', slot, e.id))
        end
        if last < n then
            local nm = string.format('Next Page (%d of %d)', page + 1, pages)
            items[#items + 1] = Wheel.Item:new({ name = nm, menu = Wheel.Menu:new({ name = nm, items = build(last + 1, page + 1) }) })
        end
        return items
    end
    return build(1, 1)
end

local function choose_item(slot)
    local S = Search()
    local flat = (S and S.FlatList) and S.FlatList() or {}
    local cats = (S and S.Cats) and S.Cats() or {}
    local items = {}
    for _, c in ipairs(cats) do
        local list = {}
        for _, e in ipairs(flat) do
            local k = (e.cat == 'soft') and 'cv' or e.cat
            if k == c.key and not e.spot then list[#list + 1] = e end
        end
        if #list > 0 then
            local nm = string.format('%s: %d', c.label, #list)
            items[#items + 1] = Wheel.Item:new({ name = nm, menu = Wheel.Menu:new({ name = nm, items = pick_units(slot, list, c.label) }) })
        end
    end
    if #items == 0 then
        return leaf('List Is Empty', 'noop')
    end
    return Wheel.Item:new({ name = 'Choose From List', menu = Wheel.Menu:new({ name = 'Choose From List', items = items }) })
end

local function slot_item(i)
    local name = string.format('%d: %s', i, slot_name(i))
    local items = {}
    if slots[i] then items[#items + 1] = leaf('Go To', 'go;' .. i, Wheel.Reaction.CLOSE_REMEMBER) end
    items[#items + 1] = choose_item(i)
    items[#items + 1] = leaf('Use Current Target', 'set;' .. i)
    if slots[i] then
        items[#items + 1] = leaf('Move Up', 'up;' .. i)
        items[#items + 1] = leaf('Move Down', 'down;' .. i)
        items[#items + 1] = leaf('Clear Slot', 'clear;' .. i)
        items[#items + 1] = leaf('Delete Unit', 'delete;' .. i)
    end
    return Wheel.Item:new({ name = name, menu = Wheel.Menu:new({ name = name, items = items }) })
end

function Targets.BuildItem()
    local items = {}
    for i = 1, N do items[#items + 1] = slot_item(i) end
    -- Full Target List (Oct 22 2026) takes the place of Add Current Target on the ring: every category with its units, Refresh Target Data and
    -- Purge Targets (built in PaveSearch.lua). Add Current Target moved into Manage.
    local S = Search()
    if S and S.BuildFullListItem then
        local ok, full = pcall(S.BuildFullListItem)
        if ok and full then items[#items + 1] = full end
    end
    items[#items + 1] = Wheel.Item:new({
        name = 'Manage',
        outer_menu = Wheel.Menu:new({
            name = 'Manage',
            items = {
                leaf('Fill From Target List', 'fill'),
                leaf('Add Current Target', 'add'),
                leaf('Clear All', 'clear_all'),
                leaf(auto_fill and 'Auto Fill: On' or 'Auto Fill: Off', 'togglefill'),
                leaf(auto_advance and 'Auto Advance: On' or 'Auto Advance: Off', 'toggle'),
                leaf(list_full and 'Context List: Full List' or 'Context List: Strike List', 'togglesrc'),
            },
        }),
    })
    return Wheel.Item:new({ name = TOP, menu = Wheel.Menu:new({ name = TOP, items = items }) })
end

local function info_text()
    -- Only Auto Advance and the current target (Oct 22 2026); the slots are on the wheel itself.
    local S = Search()
    local tgt = 'none'
    if S and S.TargetName then
        local ok, t = pcall(S.TargetName)
        if ok and t then tgt = t end
    end
    return string.format('Auto Advance: %s\nContext List: %s\nCurrent Target: %s', auto_advance and 'On' or 'Off', list_full and 'Full List' or 'Strike List', tgt)
end

local function refresh(nav)
    local S = Search()
    if S and S.RefreshMenu then
        pcall(S.RefreshMenu)       -- rebuilds the A/G Plus item and re-sends the pod menu's page text
    else
        pcall(Menu.Rebuild)
    end
    pcall(Menu.SetInfo, { TOP }, info_text())
    -- The rebuild can drop the wheel back to the root: send it to the Strike List page again. Config.STRIKE_WHEEL_NAV = false switches this off.
    if Config.STRIKE_WHEEL_NAV ~= false and nav then
        AGLog.Info('strike: wheel sent back to the Strike List page')
        pcall(Wheel.NavigateTo, { Config.MENU_PARENT[1], Config.MENU_NAME, TOP })
    end
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

local function current_entry()
    local S = Search()
    if S and S.CurrentEntry then return S.CurrentEntry() end
    return nil
end

local function note(text) pcall(Dbg.Notice, text, 4) end

local function go_to_slot(i, why)
    local e = slots[i]
    if not e then return false end
    local S = Search()
    if not (S and S.GoToEntry) then return false end
    cur_slot = i
    local ok = S.GoToEntry(e, string.format('%s: strike list %d, %s', why or 'go to', i, e.alias))
    if ok and why == 'next' and S.FlagHold then S.FlagHold('from_strike') end
    if not ok then
        AGLog.Info('strike: could not slew to slot %d (%s)', i, tostring(e.alias))
    end
    return ok
end

local function swap(i, j)
    if j < 1 or j > N then return end
    slots[i], slots[j] = slots[j], slots[i]
    if cur_slot == i then cur_slot = j elseif cur_slot == j then cur_slot = i end
end

local function do_action(task, value)
    local cmd, a1, a2 = tostring(value):match('^([^;]+);?(-?%d*);?(-?%d*)$')
    local i = tonumber(a1)
    if cmd == 'noop' then
        note('Strike List - No Targets Listed, Run A Search')
        return
    elseif cmd == 'pick' then
        local id = tonumber(a2)
        local pick
        if i and id then
            for _, e in ipairs(Targets.All()) do
                if e.id == id and not e.spot then pick = e break end
            end
        end
        if not pick then
            note('Strike List - That Target Is No Longer Listed')
            task:CantDo()
        else
            local at = find_id(pick)
            if at and at ~= i then
                slots[at] = nil
                if cur_slot == at then cur_slot = i end
            end
            slots[i] = snap(pick)
            note(string.format('Strike List %d - %s', i, slots[i].alias))
            AGLog.Info('strike: slot %d = %s (id %s) from the list', i, slots[i].alias, tostring(id))
            task:Roger()
        end
    elseif cmd == 'add' or cmd == 'set' then
        local e = current_entry()
        if not e then
            note('Strike List - No Current Target')
            task:CantDo()
            return
        end
        local at = find_id(e)
        local dest = i
        if cmd == 'add' then
            if at then
                note(string.format('Strike List - %s Already In Slot %d', slot_name(at), at))
                task:Roger()
                return
            end
            dest = first_empty()
            if not dest then
                note('Strike List Full - Clear A Slot')
                task:CantDo()
                return
            end
        elseif at and at ~= dest then
            slots[at] = nil   -- the target moves from its old slot into this one
            if cur_slot == at then cur_slot = dest end
        end
        slots[dest] = snap(e)
        note(string.format('Strike List %d - %s', dest, slots[dest].alias))
        AGLog.Info('strike: slot %d = %s (id %s)', dest, slots[dest].alias, tostring(slots[dest].id))
        task:Roger()
    elseif cmd == 'go' then
        if not (i and slots[i]) then task:CantDo() return end
        note(string.format('Strike List %d - %s', i, slots[i].alias))
        if go_to_slot(i, 'go to') then task:Roger() else task:CantDo() end
    elseif cmd == 'up' or cmd == 'down' then
        if not (i and slots[i]) then task:CantDo() return end
        local j = (cmd == 'up') and (i - 1) or (i + 1)
        if j < 1 or j > N then task:CantDo() return end
        swap(i, j)
        AGLog.Info('strike: slot %d moved to %d', i, j)
        task:Roger()
    elseif cmd == 'clear' then
        if i and slots[i] then
            AGLog.Info('strike: slot %d cleared (%s)', i, tostring(slots[i].alias))
            if not slots[i].spot then af_skip[slots[i].id] = true end
            slots[i] = nil
            if cur_slot == i then cur_slot = nil end
        end
        task:Roger()
    elseif cmd == 'delete' then
        -- Delete Unit (Oct 22 2026): the unit leaves the strike list and the target list; the wheel goes back to the Strike List page rebuilt.
        local e = i and slots[i]
        if not e then task:CantDo() return end
        local name = e.alias
        for j = 1, N do
            if slots[j] and not e.spot and slots[j].id == e.id then
                slots[j] = nil
                if cur_slot == j then cur_slot = nil end
            end
        end
        if e.spot then
            slots[i] = nil
            if cur_slot == i then cur_slot = nil end
        else
            af_skip[e.id] = true
            local S = Search()
            if S and S.RemoveUnit then pcall(S.RemoveUnit, e.id) end
        end
        AGLog.Info('strike: %s deleted from the strike list and the target list', tostring(name))
        note('Deleted - ' .. tostring(name))
        task:Roger()
    elseif cmd == 'clear_all' then
        for j = 1, N do if slots[j] and not slots[j].spot then af_skip[slots[j].id] = true end end
        slots, cur_slot = {}, nil
        AGLog.Info('strike: list cleared')
        note('Strike List Cleared')
        task:Roger()
    elseif cmd == 'fill' then
        local added = 0
        for _, e in ipairs(Targets.All()) do
            local dest = first_empty()
            if not dest then break end
            if not find_id(e) then
                slots[dest] = snap(e)
                added = added + 1
            end
        end
        AGLog.Info('strike: filled %d slot(s) from the target list', added)
        note(added > 0 and string.format('Strike List - %d Added', added) or 'Strike List - Nothing To Add')
        if added > 0 then task:Roger() else task:CantDo() end
    elseif cmd == 'togglefill' then
        auto_fill = not auto_fill
        AGLog.Info('strike: auto fill %s', auto_fill and 'on' or 'off')
        note('Strike List Auto Fill ' .. (auto_fill and 'On' or 'Off'))
        if auto_fill then Targets.AutoFill(true) end
        task:Roger()
    elseif cmd == 'togglesrc' then
        list_full = not list_full
        AGLog.Info('strike: context list source %s', list_full and 'full target list' or 'strike list')
        note('Context List Source: ' .. (list_full and 'Full Target List' or 'Strike List'))
        task:Roger()
    elseif cmd == 'toggle' then
        auto_advance = not auto_advance
        AGLog.Info('strike: auto advance %s', auto_advance and 'on' or 'off')
        note('Strike List Auto Advance ' .. (auto_advance and 'On' or 'Off'))
        task:Roger()
    else
        AGLog.Info('strike: unknown action %q', tostring(value))
        task:CantDo()
        return
    end
    refresh(cmd ~= 'go')
end

-- Delete Unit from the Full Target List (PaveSearch removes it from the target list): clears any slot that holds it and keeps Auto Fill from re-adding it.
function Targets.DeleteId(id)
    af_skip[id] = true
    for j = 1, N do
        if slots[j] and not slots[j].spot and slots[j].id == id then
            slots[j] = nil
            if cur_slot == j then cur_slot = nil end
        end
    end
end

-- A destroyed unit (PaveSearch saw it leave the unit feed): its slots are cleared WITHOUT the Auto Fill skip, so Auto Fill puts another unit in
-- each freed slot and the unit would be taken back if a search ever lists it again. Returns the number of slots cleared.
function Targets.RemoveDead(id)
    local n = 0
    for j = 1, N do
        if slots[j] and not slots[j].spot and slots[j].id == id then
            AGLog.Info('strike: slot %d (%s) cleared, the target was destroyed', j, tostring(slots[j].alias))
            slots[j] = nil
            if cur_slot == j then cur_slot = nil end
            n = n + 1
        end
    end
    return n
end

-- Purge Targets in the Full Target List empties the strike list too (Oct 22 2026), and forgets the Auto Fill skips so units found again fill in.
function Targets.PurgeAll()
    local had = 0
    for j = 1, N do if slots[j] then had = had + 1 end end
    slots, cur_slot = {}, nil
    af_skip = {}
    AGLog.Info('strike: list purged with the target list (%d slots cleared)', had)
    return had
end

-- Auto Fill: every listed unit that is not in the strike list yet goes into the next empty slot, in the target list's order, except the ones the
-- player cleared or deleted. Called by PaveSearch when the target list changes. quiet = no menu rebuild (the caller rebuilds).
function Targets.AutoFill(quiet)
    if not auto_fill then return 0 end
    local added, first = 0, nil
    for _, e in ipairs(Targets.All()) do
        if not e.spot and not af_skip[e.id] and not find_id(e) then
            local dest = first_empty()
            if not dest then break end
            slots[dest] = snap(e)
            added = added + 1
            first = first or dest
        end
    end
    if added > 0 then
        AGLog.Info('strike: auto fill added %d unit(s)', added)
        note(added == 1 and string.format('Strike List %d - %s', first, slots[first].alias) or string.format('Strike List - %d Added', added))
        if not quiet then refresh(false) end
    end
    return added
end

ListenTo('agp_strike', 'AGPlusStrike', function(task, value)
    local ok, err = pcall(do_action, task, value)
    if not ok then
        AGLog.Info('strike: action %q failed: %s', tostring(value), tostring(err))
        pcall(function() task:CantDo() end)
    end
end)

-- Called by PaveSearch once the held target has passed and the laser has been off for a few seconds. h is the pod's hold table.
-- Sets h.advanced so it is called once per hold. Goes to the next filled slot after the held target's slot; nothing after the last.
function Targets.OnPassed(h)
    h.advanced = true
    if not auto_advance then return false end
    local at
    if cur_slot and slots[cur_slot] and slots[cur_slot].id == h.id then
        at = cur_slot
    else
        for i = 1, N do
            if slots[i] and slots[i].id == h.id and not slots[i].spot then at = i break end
        end
    end
    if not at then return false end
    local j = Targets.NextSlotFrom(at)
    if j then
        note(string.format('Strike List - Next: %d %s', j, slots[j].alias))
        AGLog.Info('strike: %s passed, going on to slot %d (%s)%s', tostring(h.name), j, tostring(slots[j].alias), j < at and ' (the list loops back)' or '')
        local ok = go_to_slot(j, 'next')
        refresh()
        return ok
    end
    note('Strike List Complete')
    AGLog.Info('strike: %s passed, no other slot is filled', tostring(h.name))
    return false
end

-- The next filled slot after slot `at`, looping from the last slot back to the first (Nov 11 2026); nil when no other slot is filled.
function Targets.NextSlotFrom(at)
    for j = at + 1, N do
        if slots[j] then return j end
    end
    for j = 1, at - 1 do
        if slots[j] then return j end
    end
    return nil
end

-- A held target was destroyed (PaveSearch.check_dead): the slot the dead unit sits in, or nil when Auto Advance is off or it is in no slot. Asked
-- before the slot is cleared; the next slot is only picked after every destroyed unit is out of the list (two can die together).
function Targets.AdvanceSlotOf(id)
    if not auto_advance then return nil end
    for i = 1, N do
        if slots[i] and not slots[i].spot and slots[i].id == id then return i end
    end
    return nil
end

-- Goes to slot j now (the pod's laser is off). Returns false when the slot has emptied meanwhile.
function Targets.AdvanceTo(j)
    local e = slots[j]
    if not e then
        AGLog.Info('strike: advance after the kill: slot %s is empty now', tostring(j))
        return false
    end
    note(string.format('Strike List - Next: %d %s', j, e.alias))
    AGLog.Info('strike: held target destroyed, going on to slot %d (%s)', j, tostring(e.alias))
    local ok = go_to_slot(j, 'next')
    refresh()
    return ok
end

--------------------------------------------------------------------------------
-- Behavior: keeps the center text of the menu current
--------------------------------------------------------------------------------

local TargetsBehavior = Class(Behavior)
Targets.Behavior = TargetsBehavior

function TargetsBehavior:Constructor()
    Behavior.Constructor(self)
    self.last = -10
end

function TargetsBehavior:Tick()
    local now = Util.Now()
    if now - self.last < 1 then return end
    self.last = now
    pcall(Menu.SetInfo, { TOP }, info_text())
end

Targets.N = N
Targets.Slots = function() return slots end
-- For the context list (Pave.lua, Maverick.lua): go to a slot as the wheel's Go To does, and find the slot a vehicle sits in.
Targets.GoToSlot = function(i, why) return go_to_slot(i, why or 'list') end
Targets.SlotOfId = function(id)
    if id == nil then return nil end
    for i = 1, N do
        if slots[i] and not slots[i].spot and slots[i].id == id then return i end
    end
    return nil
end
Targets.Count = count
-- True when the pod's Context List steps through the full target list instead of the Strike List slots (Strike List > Manage > Context List).
Targets.ListFull = function() return list_full end

return Targets
