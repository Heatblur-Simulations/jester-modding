local BombingAssist = require 'BombingAssist'

mod_init[#mod_init + 1] = function(jester)
    jester.behaviors[BombingAssist] = BombingAssist:new()
end
