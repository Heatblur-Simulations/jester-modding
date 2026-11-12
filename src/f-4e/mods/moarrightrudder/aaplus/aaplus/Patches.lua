-- Patch registry. Every wrap of stock code goes through here so that
--   * each patch installs once (survives respawns and CTRL+R),
--   * each patch is a pass-through while the Director is OFF,
--   * the list of installed patches is visible in the log.
-- Phase 1 registers nothing; later phases add patches.
local AADLog = require 'aaplus.Log'

local Patches = {}
local installed = {}

-- is_active() must return true when the Director's mode is not OFF.
Patches.is_active = function() return true end

function Patches.SetActiveCheck(fn)
    Patches.is_active = fn
end

-- installer() performs the wrap and may call Patches.is_active() inside it.
function Patches.Install(name, installer)
    -- Installers are idempotent (they wrap through a global trampoline), so they run on every load: that
    -- is what makes a reload pick up edited code. The log line is written once per patch.
    local ok, err = pcall(installer)
    if ok then
        if not installed[name] then
            installed[name] = true
            AADLog.Info('patch installed: %s', name)
        end
    else
        AADLog.Info('patch FAILED: %s (%s)', name, tostring(err))
    end
    return ok
end

function Patches.List()
    local names = {}
    for n in pairs(installed) do names[#names + 1] = n end
    table.sort(names)
    return names
end

-- Detect other radar mods that override stock radar files (e.g. Dawger's package).
function Patches.DetectRadarConflicts()
    local found = {}
    local ok, cfg = pcall(require, 'radar.Config')
    if ok and type(cfg) == 'table' and cfg.JESTER_CONSOLE_LOG ~= nil then
        found[#found + 1] = 'radar.Config has JESTER_CONSOLE_LOG (phantomjestermods radar package)'
    end
    return found
end

return Patches
