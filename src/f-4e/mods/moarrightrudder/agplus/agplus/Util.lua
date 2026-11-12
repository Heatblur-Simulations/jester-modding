-- Small helpers shared by the A/G+ modules.
local Utilities = require('base.Utilities')

local Util = {}

-- Mission time in seconds. os is not available in Jester's Lua; mission_time is a unit-typed value.
function Util.Now()
    local ok, t = pcall(function() return Utilities.GetTime().mission_time:ConvertTo(s).value end)
    if ok and type(t) == 'number' then return t end
    return 0
end

-- The cockpit object, or nil when there is none (between spawns).
function Util.Cockpit()
    local cockpit = nil
    pcall(function()
        local j = GetJester()
        if j then cockpit = j:GetCockpit() end
    end)
    return cockpit
end

-- Delivery Mode switch position as the manipulator reports it ("OFF" when unreadable).
function Util.DeliveryMode()
    local mode = "OFF"
    pcall(function()
        local c = GetJester():GetCockpit()
        if c then
            local manip = c:GetManipulator("Delivery Mode")
            if manip then mode = manip:GetState() or "OFF" end
        end
    end)
    return mode
end

return Util
