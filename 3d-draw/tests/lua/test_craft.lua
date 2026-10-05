--[[ Crafting (redesign/12-craft.md): the recipes match what is laid, the plan makes ingredients
-- first, and a robot's craft program - the takes into the grid, the saw in and back, the craft,
-- what it made given back - runs on a simulated robot at a stocked interface.
-- @date 2026-10-05 ]]

local recipes = require("recipes")
local machine = require("machine")
local simbot = require("simbot")

local function run(m)
    for _ = 1, 500 do if m.step() ~= "run" then break end end
    return m.state
end

local function run_test()
    -- the matcher: the stairs' shape, cell for cell
    local P = "minecraft:planks:1"
    local item, y = recipes.match({P, false, false, P, P, false, P, P, P})
    if item ~= "minecraft:spruce_stairs:0" or y ~= 4 then return "stairs not matched" end
    if recipes.match({P, P, false, false, false, false, false, false, false}) then
        return "two planks side by side matched something"
    end

    -- the plan: dark oak stairs from logs, the planks first; the door has no recipe
    local order, none = recipes.plan({["minecraft:dark_oak_stairs:0"] = 100,
                                      ["minecraft:wooden_door:0"] = 3},
                                     {["minecraft:log2:1"] = 200})
    if #order ~= 2 or order[1].item ~= "minecraft:planks:5"
            or order[2].item ~= "minecraft:dark_oak_stairs:0" then
        return "the plan's order: " .. tostring(order[1] and order[1].item)
    end
    if order[2].crafts ~= 25 or order[1].crafts * 2 < 150 then
        return ("the plan's counts: %d stairs crafts, %d planks crafts"):format(order[2].crafts,
                                                                                order[1].crafts)
    end
    if none["minecraft:wooden_door:0"] ~= 3 then return "the door was not named as lacking" end

    -- stairs: 6 cells of planks taken from two interface slots, 16 crafts, 64 stairs given back
    local w = simbot.world({})
    local iface = {[1] = {name = "minecraft:planks", meta = 1, count = 64},
                   [2] = {name = "minecraft:planks", meta = 1, count = 32}, sink = {[9] = true}}
    w:add_container(1, 0, 0, iface)
    local r = simbot.robot(w, {facing = "e", slots = {[4] = {name = "gregtech:gt.metatool.01",
                                                              meta = 10, count = 1}}})
    local m = machine.new(r.hw, {x = 0, y = 0, z = 0, facing = "e"})
    m.exec("c1", "$0 t>1.1*16 t>1.5*16 t>1.6*16 t>1.9*16 t>2.10*16 t>2.11*16 c8*64 g>8.9")
    if run(m) ~= "done" then return "the stairs program: " .. m.state .. " " .. tostring(m.why) end
    for _, s in ipairs(recipes.GRID) do
        if r.slots[s] then return "the grid not empty after the craft: slot " .. s end
    end
    if r.slots[8] or not r.slots[4] then return "the stairs not given back, or the saw gone" end

    -- glass panes: the saw shifted into the grid and back
    iface[1] = {name = "minecraft:glass", meta = 0, count = 32}
    m.exec("c2", "$0 t>1.2*32 s4.1 c8*64 s1.4 g>8.9")
    if run(m) ~= "done" then return "the panes program: " .. m.state .. " " .. tostring(m.why) end
    if not r.slots[4] or r.slots[4].name ~= "gregtech:gt.metatool.01" or r.slots[1] then
        return "the saw did not go back to slot 4"
    end
    -- a grid no recipe knows makes nothing: the craft stops the program
    r.slots[1] = {name = "minecraft:dirt", meta = 0, count = 3}
    m.exec("c3", "$0 c8*3")
    if run(m) ~= "stop" or m.why ~= "nothing-crafted" then return "an unknown grid crafted" end
    return nil
end

return {run_test = run_test}
