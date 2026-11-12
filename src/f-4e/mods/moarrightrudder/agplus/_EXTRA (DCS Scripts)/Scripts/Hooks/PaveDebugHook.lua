-- Jester A/G+ on-screen messages, hook side. Reads Logs\pavedebug.txt (written by agplus\PaveDebug.lua in the Jester Lua state)
-- and shows each new line to the player.
-- Line format: DBG <seq> <mission time> <seconds to show> <text>
--
-- Two ways to show a line (Oct 20 2026):
--   overlay  a small local window drawn by DCS's own GUI library (Scripts\AGPlus\MessageOverlay.dlg, the same method the SRS
--            overlay uses). It is local to this player, needs no server, and leaves every other message (EWRS etc.) alone.
--   server   the old route, trigger.action.outText through net.dostring_in('server'). It only works in single player or when
--            hosting, and it must never clear other messages, so clearView is false.
-- Which one: a file Logs\agp_msg_mode.txt can say "overlay", "server" or "both" (read for every message, so no restart is needed to
-- change it). Without the file the overlay is used everywhere. The overlay falls back to the server route if the window cannot
-- be made.
--
-- Why the window is built once and never resized (Oct 20 2026, found in a multiplayer flight): the first version made the window
-- when the first message arrived and resized or hid it as lines came and went. A message that arrived while the Jester wheel was
-- open left the wheel stuck (could not be closed or reopened). So now the window is made once, a few seconds after the sim starts,
-- at its final size and position; afterwards only the text and the color of the box change. Nothing is resized, moved, shown or
-- hidden while the game runs, and a change is only made when a line is added or expires.
-- Delete this file to switch messages off. Hooks load only at DCS start, so it needs a full restart.
local dir = ((lfs and lfs.writedir and lfs.writedir()) or '')
local REQ = dir .. 'Logs\\pavedebug.txt'
local MODE_PATH = dir .. 'Logs\\agp_msg_mode.txt'
local DLG_PATH = dir .. 'Scripts\\AGPlus\\MessageOverlay.dlg'
local START_AFTER = 8       -- model seconds; nothing is touched in the first seconds after spawn
local CREATE_AFTER = 12     -- model seconds: the window is made once, here, not when the first message arrives
local POLL_S = 0.1
local MAX_LINES = 7
local LINE_H, PAD, WIDTH = 22, 8, 760
local CHAR_PX = 6.8        -- estimated width of one character, to size the dark bar
local TOP_FRACTION = 0.03   -- window top edge as a fraction of the screen height (level with the stock message box)
local RIGHT_FRACTION = 0.675 -- the window's right edge stays left of the stock message box (starts at about 0.677 of the width)
local last_line, primed, last_poll = nil, false, -10

local function wlog(msg) pcall(function() log.write('PAVEDEBUG', log.INFO, msg) end) end

local overlay = { window = nil, box = nil, statics = {}, failed = false, lines = {}, dirty = false, shown_n = -1, shown_text = {},
    skin_dark = nil, skin_clear = nil, size = nil }

local function window_size(gui)
    local sw, sh = 1920, 1080
    local ok, w, h = pcall(gui.GetWindowSize)
    if ok and type(w) == 'number' and type(h) == 'number' and w > 0 and h > 0 then sw, sh = w, h end
    return sw, sh
end

local function create_overlay()
    local DialogLoader = require('DialogLoader')
    local Gui = require('dxgui')
    local Static = require('Static')
    local window = DialogLoader.spawnDialogFromFile(DLG_PATH, nil)
    local box = window.Box
    local hidden = window.pNoVisible
    overlay.skin_dark = hidden.eBox:getSkin()
    overlay.skin_clear = hidden.eClear:getSkin()
    box:setSkin(overlay.skin_clear)
    local text_skin = hidden.eText:getSkin()
    local statics = {}
    for i = 1, MAX_LINES do
        local st = Static.new()
        st:setSkin(text_skin)
        st:setText('')
        st:setBounds(12, PAD + (i - 1) * LINE_H, WIDTH - 24, LINE_H)
        box:insertWidget(st)
        statics[i] = st
        overlay.shown_text[i] = ''
    end
    -- The dialog's own window skin draws a title bar with a close button; the SRS overlay's frameless skin removes it. If that
    -- skin is not available the title bar's height is added so the last line is not clipped.
    local title_h = 30
    local okSkin, Skin = pcall(require, 'Skin')
    if okSkin and type(Skin) == 'table' and type(Skin.windowSkinChatMin) == 'function' then
        if pcall(function() window:setSkin(Skin.windowSkinChatMin()) end) then title_h = 0 end
    end
    local sw, sh = window_size(Gui)
    local full_h = PAD * 2 + LINE_H * MAX_LINES
    window:setHasCursor(false)
    window:setBounds(math.max(0, math.min(math.floor((sw - WIDTH) / 2), math.floor(sw * RIGHT_FRACTION) - WIDTH)), math.floor(sh * TOP_FRACTION), WIDTH, full_h + title_h)
    box:setBounds(0, 0, WIDTH, full_h)
    window:setVisible(true)
    overlay.window, overlay.box, overlay.statics, overlay.gui = window, box, statics, Gui
    overlay.size = sw .. 'x' .. sh
    wlog('message overlay created (' .. overlay.size .. ', title bar ' .. title_h .. ' px)')
end

local function render_overlay()
    local o = overlay
    if not o.dirty then return end
    o.dirty = false
    local n = #o.lines
    -- The dark bar is only as wide as the longest line (about 6.8 px per character in this font); the window stays fixed.
    local longest = 0
    for _, l in ipairs(o.lines) do
        local len = #(l.text:gsub('[\128-\191]', ''))
        if len > longest then longest = len end
    end
    local w = math.max(160, math.min(WIDTH, math.floor(longest * CHAR_PX + 28)))
    if n ~= o.shown_n or (n > 0 and w ~= o.shown_w) then
        if n == 0 then
            o.box:setSkin(o.skin_clear)
        else
            if o.shown_n <= 0 then o.box:setSkin(o.skin_dark) end
            o.box:setBounds(0, 0, w, PAD * 2 + LINE_H * n)
        end
        o.shown_n = n
        o.shown_w = w
    end
    for i = 1, MAX_LINES do
        local want = o.lines[i] and o.lines[i].text or ''
        if o.shown_text[i] ~= want then
            o.statics[i]:setText(want)
            o.shown_text[i] = want
        end
    end
end

local function overlay_add(text, dur, now)
    if not overlay.window then create_overlay() end
    -- A countdown ("Searching - Found 0 - 22 s left") sends a new line every second: a line that differs only in
    -- its numbers replaces the earlier one instead of stacking under it.
    local key = text:gsub('%d+', '#')
    for _, l in ipairs(overlay.lines) do
        if l.key == key then
            l.text, l.expire = text, now + dur
            overlay.dirty = true
            return
        end
    end
    table.insert(overlay.lines, { text = text, key = key, expire = now + dur })
    while #overlay.lines > MAX_LINES do table.remove(overlay.lines, 1) end
    overlay.dirty = true
end

-- A menu block (Oct 21 2026): the Maverick target list sends "MENU|line|line|..." and the lines replace the earlier menu lines as a block
-- (they do not stack), so the cursor can move without the list repeating. "MENU|" alone clears the block.
local function overlay_menu(lines, dur, now)
    if not overlay.window then create_overlay() end
    local keep = {}
    for _, l in ipairs(overlay.lines) do
        if not l.menu then keep[#keep + 1] = l end
    end
    overlay.lines = keep
    for i, t in ipairs(lines) do
        table.insert(overlay.lines, { text = t, key = 'menu' .. i, expire = now + dur, menu = true })
    end
    while #overlay.lines > MAX_LINES do table.remove(overlay.lines, 1) end
    overlay.dirty = true
end

local function overlay_tick(now)
    if not overlay.window then return end
    local keep, changed = {}, false
    for _, l in ipairs(overlay.lines) do
        if l.expire > now then keep[#keep + 1] = l else changed = true end
    end
    if changed then overlay.lines = keep overlay.dirty = true end
    render_overlay()
end

local function read_mode()
    local f = io.open(MODE_PATH, 'r')
    if not f then return nil end
    local m = (f:read('*l') or ''):lower()
    f:close()
    if m:find('both') then return 'both' end
    if m:find('overlay') then return 'overlay' end
    if m:find('server') then return 'server' end
    return nil
end

local function server_message(text, dur)
    local ok, res = pcall(net.dostring_in, 'server', string.format('trigger.action.outText(%q, %.1f, false) return "ok"', text, dur))
    if not ok then wlog('message failed: ' .. tostring(res)) end
end

local function show(text, dur, now)
    local mode = read_mode() or 'overlay'
    local want_overlay = (mode == 'overlay' or mode == 'both') and not overlay.failed
    local want_server = (mode == 'server' or mode == 'both')
    if want_overlay then
        local ok, err = pcall(overlay_add, text, dur, now)
        if not ok then
            overlay.failed = true
            wlog('message overlay failed, using the server route: ' .. tostring(err))
            want_server = true
        end
    elseif mode == 'overlay' then
        want_server = true     -- overlay unusable: better the old route than nothing
    end
    if want_server then server_message(text, dur) end
end

local function show_menu(lines, dur, now)
    local mode = read_mode() or 'overlay'
    local want_overlay = (mode == 'overlay' or mode == 'both') and not overlay.failed
    local want_server = (mode == 'server' or mode == 'both') or (mode == 'overlay' and overlay.failed)
    if want_overlay then
        local ok, err = pcall(overlay_menu, lines, dur, now)
        if not ok then
            overlay.failed = true
            wlog('message overlay failed, using the server route: ' .. tostring(err))
            want_server = true
        end
    end
    if want_server and #lines > 0 then server_message(table.concat(lines, '\n'), dur) end
end

local created_tried = false
local function tick()
    local mt = DCS.getModelTime()
    if mt < START_AFTER then return end
    local rt = DCS.getRealTime()
    -- Make the window once, early, so nothing is created later while the player is using the wheel.
    if not created_tried and mt >= CREATE_AFTER then
        created_tried = true
        local mode = read_mode() or 'overlay'
        if mode ~= 'server' then
            local ok, err = pcall(create_overlay)
            if not ok then overlay.failed = true wlog('message overlay could not be made: ' .. tostring(err)) end
        end
    end
    pcall(overlay_tick, rt)
    if rt - last_poll < POLL_S then return end
    last_poll = rt
    local f = io.open(REQ, 'r')
    if not f then return end
    local line = f:read('*l')
    f:close()
    if not primed then primed, last_line = true, line return end   -- what an earlier run left behind is not a request
    if not line or line == last_line then return end
    last_line = line
    local dur, text = line:match('^DBG %d+ [%d%.]+ ([%d%.]+) (.+)$')
    if not text then return end
    local pattern = '[^%w%s%.%,%:%-%+%(%)%/%%|<>=#_!%^%*\']'
    if text:sub(1, 5) == 'MENU|' then
        local lines = {}
        for part in text:sub(6):gmatch('[^|]+') do lines[#lines + 1] = (part:gsub(pattern, '')) end
        show_menu(lines, tonumber(dur) or 2.5, rt)
        return
    end
    text = text:gsub(pattern, '')
    show(text, tonumber(dur) or 2.5, rt)
end

local cb = {}
function cb.onSimulationFrame()
    local ok, err = pcall(tick)
    if not ok and not cb.failed then cb.failed = true wlog('error: ' .. tostring(err)) end
end
DCS.setUserCallbacks(cb)
wlog('loaded, reading ' .. REQ)
