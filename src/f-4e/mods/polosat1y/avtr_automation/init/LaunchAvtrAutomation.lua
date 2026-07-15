local AvtrAutomation = require 'AvtrAutomation'

mod_init[#mod_init + 1] = function(jester)
    jester.behaviors[AvtrAutomation] = AvtrAutomation:new()
end
