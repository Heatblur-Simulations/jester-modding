-- Jester A/G+ feed loader. Export.lua loads this one file; it loads the three feeds, each inside its own pcall so one
-- failing feed cannot stop the others or DCS. Delete a file name from the list to switch that feed off.
local lfs = require("lfs")
local dir = lfs.writedir() .. [[Scripts\AGPlus\]]
for _, name in ipairs({ "AGPlusFeed.lua", "BombBtnFeed.lua", "PaveProbeFeed.lua" }) do
    pcall(dofile, dir .. name)
end
