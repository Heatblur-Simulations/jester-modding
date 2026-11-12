-- Jester A/G+ target list lines, shared by the Maverick list (Maverick.lua) and the Pave Spike list (Pave.lua). Oct 21 2026.
-- Only the drawing lives here: each system keeps its own cursor, pause and "go". Every key is optional in Config.lua:
--   MAV_LIST_NOTES (true)    false = arrows only, no words in brackets
--   MAV_LIST_CURSOR ('=> ')  marks the cursor line
--   MAV_LIST_CURRENT ('*')   marks the current target (the one held, or last slewed to), to the left of its name
--   MAV_LIST_RIGHT '>'  MAV_LIST_LEFT '<'  MAV_LIST_CENTER '>^<'  MAV_LIST_OUT '!!!'  MAV_LIST_UP '^'  MAV_LIST_DOWN 'v'
-- The message hook keeps letters, digits, spaces and . , : - + ( ) / % | < > = # _ ! ^ * ' only.
local Config = require('agplus.Config')

local PM = {}

function PM.Cfg(key, default)
    local v = Config[key]
    if v == nil then return default end
    return v
end

-- Arrows for a bearing right (+) or left (-) of the nose: one per deg_per_arrow, at most max_arrows. Returns glyph, 'slightly '/'' prefix.
function PM.Arrows(az, deg_per_arrow, max_arrows, center_deg)
    local R, L, C = PM.Cfg('MAV_LIST_RIGHT', '>'), PM.Cfg('MAV_LIST_LEFT', '<'), PM.Cfg('MAV_LIST_CENTER', '>^<')
    if math.abs(az) < center_deg then return C, true end
    local n = math.max(1, math.min(max_arrows, math.ceil(math.abs(az) / deg_per_arrow)))
    return string.rep(az > 0 and R or L, n), false
end

-- items: array of { key, name, glyph, words }. ci: index of the cursor line. current_key: the key of the current target (or nil).
-- hint: the last line. Returns the lines (a window of four items around the cursor, then the hint).
function PM.Lines(items, ci, current_key, hint)
    local size = math.min(4, #items)
    local first = math.max(1, math.min(ci - 1, #items - size + 1))
    local cur = PM.Cfg('MAV_LIST_CURSOR', '=> ')
    local pad = string.rep(' ', #cur)
    local mark = PM.Cfg('MAV_LIST_CURRENT', '*')
    local nomark = string.rep(' ', #mark > 0 and #mark + 1 or 0)
    local notes = PM.Cfg('MAV_LIST_NOTES', true) ~= false
    local lines = {}
    for i = first, first + size - 1 do
        local it = items[i]
        local star = (current_key ~= nil and it.key == current_key and #mark > 0) and (mark .. ' ') or nomark
        local text = string.format('%s%s%s  %s', i == ci and cur or pad, star, tostring(it.name), tostring(it.glyph))
        if notes and it.words and it.words ~= '' then text = text .. '  (' .. it.words .. ')' end
        lines[#lines + 1] = text
    end
    if hint then lines[#lines + 1] = hint end
    return lines
end

return PM
