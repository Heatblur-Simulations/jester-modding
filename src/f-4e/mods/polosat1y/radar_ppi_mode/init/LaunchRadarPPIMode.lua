local RadarPPIMode = require 'RadarPPIMode'

mod_init[#mod_init + 1] = function(jester)
    jester.behaviors[RadarPPIMode] = RadarPPIMode:new()
end
