-- Launcher for Jester A/G+. Delete the mods\init\agplus folder to disable it.
if not mod_init then mod_init = {} end

mod_init[#mod_init + 1] = function(jester)
    local ok, err = pcall(function() require('agplus.Suite').Install(jester) end)
    if not ok then pcall(Log, '[AG+] failed to load: ' .. tostring(err)) end
end
