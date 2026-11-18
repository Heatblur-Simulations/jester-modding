-- Launcher for the Jester Survivability. Delete the mods\init\survivability folder to disable it.
if not mod_init then mod_init = {} end

mod_init[#mod_init + 1] = function(jester)
    local ok, err = pcall(function() require('survivability.Suite').Install(jester) end)
    if not ok then pcall(Log, '[SURV] failed to load: ' .. tostring(err)) end
end
