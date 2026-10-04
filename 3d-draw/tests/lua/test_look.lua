--[[ The block looks (scripts/look.lua), moved from the old viewer: it loads beside the
-- simulator's blocks.lua, and a few blocks of the harbour come out as the old viewer drew them.
-- @date 2026-10-05 ]]

local look = require("look")

local function run_test()
    local key, _, shape = look.look("minecraft:planks", 1)
    if key ~= "minecraft:planks_spruce" or shape ~= look.CUBE then
        return "spruce planks: " .. tostring(key) .. " " .. tostring(shape)
    end
    local s, facing = look.map_shape("minecraft:spruce_stairs", 2, look.CUBE)
    if s ~= 5 or not facing then return "stairs facing south: " .. tostring(s) end
    s = look.map_shape("minecraft:stone_slab", 8, look.CUBE)
    if s ~= 4 then return "a top slab: " .. tostring(s) end
    s = look.map_shape("minecraft:fence", 0, look.CUBE)
    if s ~= 7 then return "a fence: " .. tostring(s) end
    -- the station's blocks, by the jars' file names (2026-10-05); the tiles were found in a run
    local key2, _, shape2 = look.look("OpenComputers:charger", 0)
    if key2 ~= "opencomputers:ChargerSide" or shape2 ~= look.CUBE then return "the charger" end
    _, _, shape2 = look.look("appliedenergistics2:tile.BlockCableBus", 0)
    if shape2 ~= 7 then return "an AE2 cable is not drawn as a cable" end
    _, _, shape2 = look.look("minecraft:lever", 9)
    if shape2 ~= look.CROSS then return "a lever is drawn as a cube" end
    if type(look.colour_of("gregtech:gt.blockmachines", 0)) ~= "number" then
        return "no colour for a machine"
    end
    return nil
end

return {run_test = run_test}
