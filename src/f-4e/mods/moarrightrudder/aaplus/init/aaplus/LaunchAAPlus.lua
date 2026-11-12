-- Launcher for the Jester A/A+. Delete the mods\init\aaplus folder to disable.
if not mod_init then mod_init = {} end

mod_init[#mod_init + 1] = function(jester)
    local ok, Director = pcall(require, 'aaplus.Director')
    if not ok then
        pcall(Log, '[AA+] failed to load Director: ' .. tostring(Director))
        return
    end
    jester.behaviors[Director] = Director:new()
end
