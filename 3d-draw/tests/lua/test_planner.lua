--[[ The planner (scripts/planner.lua) on a small world: stone ground at y -1, a hill block to dig
-- away, a wall two boxes high (y 0..9) to place, one block hanging in the air, one cell never
-- scanned. Digs come first, top down; places bottom up, the upper box after the lower; the hanging
-- block and the unscanned cell are reported, not planned.
-- @date 2026-10-05 ]]

local planner = require("planner")

local function run_test()
    local function have(x, y, z)
        if x == 30 then return nil end                  -- never scanned
        if y < 0 then return "minecraft:stone", 0 end
        if x == 7 and y == 0 and z == 0 then return "minecraft:dirt", 0 end   -- the hill
        if x == 7 and y == 8 and z == 0 then return "minecraft:dirt", 0 end   -- and its top
        return "air"
    end
    local want = {}
    for y = 0, 9 do want["2," .. y .. ",0"] = {"minecraft:stonebrick", 0} end
    want["7,0,0"] = {"minecraft:air", 0}
    want["7,8,0"] = {"minecraft:air", 0}
    want["12,5,0"] = {"minecraft:planks", 1}            -- nothing under it, nothing beside it
    want["30,0,0"] = {"minecraft:planks", 1}
    -- already right: nothing to do
    want["3,-1,0"] = {"minecraft:stone", 0}
    local p = planner.plan(want, have)
    local s = p.stats
    if s.dig_packets ~= 2 or s.dig_cells ~= 2 then return ("digs: %d packets %d cells"):format(
            s.dig_packets, s.dig_cells) end
    if s.place_cells ~= 11 then return ("place cells %d, 11 meant"):format(s.place_cells) end
    if #p.problems.unknown ~= 1 or p.problems.unknown[1] ~= "30,0,0" then return "the unknown" end
    if #p.problems.flying ~= 1 or p.problems.flying[1] ~= "12,5,0" then
        return "the flying block: " .. table.concat(p.problems.flying, " ")
    end
    if #p.problems.cycle ~= 0 then return "a cycle: " .. table.concat(p.problems.cycle, "; ") end
    local o = p.order
    if o[1] ~= "dig 1 1 0" or o[2] ~= "dig 1 0 0" then return "digs not first, top down: " .. o[1] end
    local lo, hi = p.packets["place 0 0 0"].order, p.packets["place 0 1 0"].order
    if not lo or not hi or lo > hi then return "the upper wall box before the lower" end
    if not p.packets["place 0 1 0"].waits["place 0 0 0"] then return "no wait on the box below" end
    return nil
end

return {run_test = run_test}
