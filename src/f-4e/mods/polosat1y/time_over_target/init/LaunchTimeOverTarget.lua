local TimeOverTarget = require 'TimeOverTarget'
mod_init[#mod_init + 1] = function(jester)
    jester.behaviors[TimeOverTarget] = TimeOverTarget:new()
end
