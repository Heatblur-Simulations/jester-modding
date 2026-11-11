-- Live pod debug messages. Jester writes one line to Logs\pavedebug.txt each time he does something with the Pave Spike
-- ("Debug: JPod Zoom In", "Debug: Holding Track T-90 ...", "Debug: Search for Targets 9 s" ...). The hook
-- Scripts\Hooks\PaveDebugHook.lua picks the line up within a frame and shows it as an on-screen DCS message.
-- Line format: DBG <seq> <mission time> <seconds to show> <text>
-- Say    = an event, shown at once (the same text again within 1.5 s is dropped).
-- Status = a repeating status (hold, countdown); shown only when no event has been shown in the last 2.5 s and at most once a second,
--          so events are never buried by the status line.
-- Config.PAVE_DEBUG = false switches the Debug: lines off (Say and Status); Notice and NoticeStatus are the player messages.
local Config = require('agplus.Config')
local Util = require('agplus.Util')

local D = {}
local FILE = (Config.PAYLOAD_FEED or ''):gsub('agplus_payload%.txt$', 'pavedebug.txt')
local seq, last_text, last_t, last_event_t, last_status_t = 0, nil, -100, -100, -100

local function put(text, dur, plain)
    local ok = pcall(function()
        seq = seq + 1
        local f = io.open(FILE, 'w')
        if f then
            f:write(string.format('DBG %d %.2f %.1f %s%s\n', seq, Util.Now(), dur, plain and '' or 'Debug: ', (tostring(text):gsub('[\r\n]', ' '))))
            f:close()
        end
    end)
    return ok
end

function D.Enabled() return Config.PAVE_DEBUG ~= false end

-- Player messages (Oct 19 2026): shown with no "Debug:" prefix and whether or not PAVE_DEBUG is on, so the player always sees
-- that the search is finding something. Config.PAVE_SEARCH_MESSAGES = false switches them off.
-- Notice = an event, shown at once. NoticeStatus = a repeating line (the running count), at most once a second.
local last_notice_t, last_notice_status_t = -100, -100
function D.Notice(text, dur)
    if Config.PAVE_SEARCH_MESSAGES == false then return end
    last_notice_t = Util.Now()
    put(text, dur or 4, true)
end

function D.NoticeStatus(text)
    if Config.PAVE_SEARCH_MESSAGES == false then return end
    local now = Util.Now()
    if now - last_notice_status_t < 1.0 or now - last_notice_t < 2.5 then return end
    last_notice_status_t = now
    put(text, 2.0, true)
end

function D.Say(text, dur)
    if Config.PAVE_DEBUG == false then return end
    local now = Util.Now()
    if text == last_text and now - last_t < 1.5 then return end
    last_text, last_t, last_event_t = text, now, now
    put(text, dur or 2.5)
end

function D.Status(text)
    if Config.PAVE_DEBUG == false then return end
    local now = Util.Now()
    if now - last_event_t < 2.5 or now - last_status_t < 1.0 then return end
    last_text, last_t, last_status_t = text, now, now
    put(text, 2.0)
end

return D
