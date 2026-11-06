local PvpScan = require 'PvpScan'

mod_init[#mod_init + 1] = function(jester)
	jester.behaviors[PvpScan] = PvpScan:new()
end
