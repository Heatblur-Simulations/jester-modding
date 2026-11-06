local BstRange = require 'BstRange'

mod_init[#mod_init + 1] = function(jester)
	jester.behaviors[BstRange] = BstRange:new()
end
