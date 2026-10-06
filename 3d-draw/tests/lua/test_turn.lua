--[[ Blocks placed turned the plan's way (redesign/14-turn.md): the rules as read from the jars -
-- the stairs' yaw and half, a pillar's axis, a slab's half, a pumpkin's yaw, the click of a face
-- across the place at 0.61, a side clicked level at 0.5 (the bottom), diagonal looks not chosen;
-- then a little set on a stone floor - a hay block with a pumpkin on it (the upper field's
-- scarecrow), stairs right way up and upside down, a top slab, a log lying east-west, an eave stair
-- with nothing to click but a support put there and taken away - planned, proven, made into
-- programs and run on a simulated robot: each comes out with the plan's meta.
-- @date 2026-10-05 ]]

local vc = require("virt_composer")
local machine = require("machine")
local simbot = require("simbot")
local planner = require("planner")
local prove = require("prove")
local programs = require("programs")
local orient = require("orient")

local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local function rules()
    local S = "minecraft:spruce_stairs"
    local cases = {
        {S, 0, "d", "d", 2},          -- looking straight down: yaw 0, the top of the block below
        {S, 0, "n", "d", 3},          -- from the south, facing north, clicking below: bottom
        {S, 0, "n", "u", 7},          -- clicking the block above's bottom: upside down
        {S, 0, "d", "n", 7},          -- from above, the north neighbour hit at 0.61: upside down
        {S, 0, "n", "e", nil},        -- a diagonal look: right on the line, not chosen
        {"minecraft:hay_block", 0, "d", "d", 0},
        {"minecraft:log", 1, "n", "n", 9},     -- spruce, its axis north-south
        {"minecraft:log", 0, "e", "e", 4},
        {"minecraft:log", 0, "d", "e", 4},
        {"minecraft:pumpkin", 0, "n", "d", 0},
        {"minecraft:pumpkin", 0, "d", "d", 2},
        {"minecraft:stone_slab", 0, "d", "n", 8},
        {"minecraft:stone_slab", 0, "n", "n", 0},     -- a side hit level, at 0.5: the bottom
        {S, 0, "e", "e", 0},          -- from the west, clicking the block beyond: bottom, east
        {S, 0, "u", "e", 0},          -- from below, the east side hit at 0.39: bottom, east
        {"minecraft:fence_gate", 0, "w", "d", 1},
        {"BiomesOPlenty:logs4", 0, "d", "d", nil},    -- a mod's block: no rule read
        {"minecraft:torch", 0, "d", "d", 5},          -- standing, on the block below's top
        {"minecraft:torch", 0, "n", "n", 3},          -- the south face of the block beyond, side 3
        {"minecraft:torch", 0, "e", "e", 2},          -- the west face of the block beyond, side 4
        {"minecraft:torch", 0, "n", "u", nil},        -- the bottom of a block holds none
        {"minecraft:ladder", 0, "s", "s", 2},         -- on the north face of the block south
        {"minecraft:ladder", 0, "d", "d", nil},
        {"minecraft:chest", 0, "n", "d", 3},          -- looking north: it faces south, at us
        {"minecraft:chest", 0, "d", "d", 2},          -- straight down: yaw 0
        {"minecraft:wooden_door", 0, "n", "d", 3},    -- looking north, on the block below's top
        {"minecraft:wooden_door", 0, "e", "d", 0},
        {"minecraft:wooden_door", 0, "n", "n", nil},  -- only on a top: not a side
        {"malisisdoors:trapdoor_spruce", 0, "n", "n", 1},  -- the south face clicked, at 0.5
        {"malisisdoors:trapdoor_spruce", 0, "d", "n", 9},  -- the same face hit at 0.61: on top
        {"malisisdoors:spruceFenceGate", 0, "w", "d", 1},  -- vanilla's gate rule
    }
    for _, c in ipairs(cases) do
        local m = orient.meta(c[1], c[2], c[3], c[4])
        if m ~= c[5] then
            return ("%s item %d placed %s face %s: %s, the game makes %s"):format(c[1], c[2], c[3],
                    c[4], tostring(m), tostring(c[5]))
        end
    end
    local off, side, _, hy = orient.click("d", "n")
    if off[3] ~= -1 or side ~= 3 or math.abs(hy - 0.6077) > 0.001 then
        return "the click from above, face north"
    end
    if orient.click("n", "s") then return "a face opposite the place was not refused" end
    -- the hinge counts normal cubes only: a door beside it is none (-10,6,41)
    if orient.normal_cube("minecraft:wooden_door") or orient.normal_cube("minecraft:glass")
            or not orient.normal_cube("minecraft:planks") then
        return "normal cubes wrong"
    end
    -- a chest planned 0 (no facing): any facing will do; a trapdoor planned open (4): placed shut
    if #orient.ways("minecraft:chest", 0) == 0 then return "no way for a chest planned 0" end
    if #orient.ways("malisisdoors:trapdoor_spruce", 4) == 0 then
        return "no way for a trapdoor planned open"
    end
    for meta = 0, 7 do
        if #orient.ways("minecraft:oak_stairs", meta) == 0 then
            return "no way to place stairs of meta " .. meta
        end
    end
    return nil
end

local function set_case()
    local wb = {}
    for x = 0, 15 do for z = 0, 15 do wb[x .. ",0," .. z] = {"minecraft:stone", 0} end end
    -- stones beside some targets: what their faces click
    -- and a wall north of an eave stair facing west: its ways stand east of it and click west of
    -- it or under it, open air both (the village's -18,18,39)
    -- and a stone wall east of the second door (2,1,14): its hinge goes the other way (9); and
    -- stone north of a third door (11,1,11 and 11,2,11), stone planned south of it in its own
    -- packet: its hinge is the plan's (8) only once both southern stones are there, the upper
    -- one a layer up; and a fourth (6,1,14) whose southern stones are in the next packet (z 15)
    for _, c in ipairs({{10, 1, 4}, {12, 1, 4}, {4, 1, 8}, {14, 1, 9}, {14, 2, 9}, {3, 1, 14},
                        {3, 2, 14}, {11, 1, 11}, {11, 2, 11}, {6, 1, 13}, {6, 2, 13}}) do
        wb[c[1] .. "," .. c[2] .. "," .. c[3]] = {"minecraft:stone", 0}
    end
    local rows = {}
    for y = 0, 7 do
        local zs = {}
        for z = 0, 15 do
            local xs = {}
            for x = 0, 15 do xs[#xs + 1] = wb[x .. "," .. y .. "," .. z] and "1" or "0" end
            zs[#zs + 1] = table.concat(xs, ",")
        end
        rows[#rows + 1] = ("layer %d %s"):format(y, table.concat(zs, ";"))
    end
    write("test_run/c0_0.txt", table.concat({"# 3d-draw map 1", "box x 0 15 y 0 7 z 0 15",
        "palette 1 minecraft:stone 0 1.50 seen", table.concat(rows, "\n")}, "\n") .. "\n")
    vc.route_load("test_run", 0, 0, 0, 0, 0, 0, 0, "")
    require("route").loaded = true
    local function have(x, y, z)
        if x < 0 or x > 15 or z < 0 or z > 15 or y < 0 then return nil end
        local b = wb[x .. "," .. y .. "," .. z]
        if b then return b[1], b[2], false, true end
        return "air"
    end
    local want = {
        ["5,1,5"] = {"minecraft:hay_block", 0},
        ["5,2,5"] = {"minecraft:pumpkin", 0},         -- the scarecrow's head, facing as planned
        ["8,1,5"] = {"minecraft:spruce_stairs", 3},
        ["10,1,5"] = {"minecraft:spruce_stairs", 7},
        ["12,1,5"] = {"minecraft:stone_slab", 8},
        ["3,1,8"] = {"minecraft:log", 4},
        ["14,2,10"] = {"minecraft:spruce_stairs", 1},  -- its ways click west of it or under it
        -- a fence on the only stand of the stair beside it: the stair first (-14,3,18)
        ["6,1,12"] = {"minecraft:spruce_stairs", 1},
        ["7,1,12"] = {"minecraft:fence", 0},
        -- two doors facing north (3), from the south: one with nothing beside it (upper 8), one
        -- with a wall east of it (upper 9, ItemDoor.placeDoorBlock)
        ["2,1,12"] = {"minecraft:wooden_door", 3}, ["2,2,12"] = {"minecraft:wooden_door", 8},
        ["2,1,14"] = {"minecraft:wooden_door", 3}, ["2,2,14"] = {"minecraft:wooden_door", 9},
        ["11,1,12"] = {"minecraft:wooden_door", 2}, ["11,2,12"] = {"minecraft:wooden_door", 8},
        ["11,1,13"] = {"minecraft:stone", 0}, ["11,2,13"] = {"minecraft:stone", 0},
        ["6,1,14"] = {"minecraft:wooden_door", 2}, ["6,2,14"] = {"minecraft:wooden_door", 8},
        ["6,1,15"] = {"minecraft:stone", 0}, ["6,2,15"] = {"minecraft:stone", 0},
    }
    local result = planner.plan(want, have)
    local stats = prove.run(result, want, have, {entry = {2, 1, 2}})
    if stats.unproven ~= 0 then
        for id, p in pairs(result.packets) do
            if p.unproven then return id .. " unproven: " .. p.unproven end
        end
    end
    local w = simbot.world(wb)
    w.on_change = function(k)
        local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
        vc.route_set(tonumber(x), tonumber(y), tonumber(z), w.blocks[k] and 2 or 1)
    end
    local SLOT = {["minecraft:hay_block"] = 1, ["minecraft:pumpkin"] = 2,
                  ["minecraft:spruce_stairs"] = 3, ["minecraft:stone_slab"] = 4,
                  ["minecraft:log"] = 5, ["minecraft:cobblestone"] = 6,   -- 6: supports
                  ["minecraft:fence"] = 7, ["minecraft:wooden_door"] = 8,
                  ["minecraft:stone"] = 9}
    local slots = {}
    for name, s in pairs(SLOT) do slots[s] = {name = name, meta = 0, count = 64} end
    local r = simbot.robot(w, {x = 2, y = 1, z = 2, facing = "n", slots = slots})
    for _, id in ipairs(result.order) do
        local p = result.packets[id]
        local text, why = programs.make(p, {pos = {r.x, r.y, r.z}, facing = r.facing,
                                            slot_of = function(name) return SLOT[name] end}, {})
        if not text then return id .. ": " .. tostring(why) end
        local m = machine.new(r.hw, {x = r.x, y = r.y, z = r.z, facing = r.facing})
        local ok, err = m.exec(id, text)
        if not ok then return id .. " does not parse: " .. tostring(err) .. " - " .. text end
        for _ = 1, 3000 do if m.step() ~= "run" then break end end
        if m.state ~= "done" then
            return ("%s: %s %s - %s"):format(id, m.state, tostring(m.why), text)
        end
    end
    local function support(k) return w.blocks[k] and w.blocks[k][1] == "minecraft:cobblestone" end
    if support("13,1,10") or support("13,2,10") or support("14,1,10") then
        local seq = {}
        for _, id in ipairs(result.order) do
            for _, st in ipairs(result.packets[id].steps) do
                seq[#seq + 1] = st.act .. " " .. st.k .. (st.scaffold and "*" or "")
            end
        end
        return "the eave stair's support was left standing: " .. table.concat(seq, ", ")
    end
    for k, b in pairs(want) do
        local got = w.blocks[k]
        if not got or got[1] ~= b[1] or got[2] ~= b[2] then
            return ("%s: %s:%d planned, %s placed"):format(k, b[1], b[2],
                    got and (got[1] .. ":" .. tostring(got[2])) or "nothing")
        end
    end
    return nil
end

-- A turned block whose ways' clicks are all still to come goes after the packet placing the
-- first - waiting on it, or moved into it when it ranks later: an upside-down stair (its ways
-- click above it, or the stone east of it, a box over) after that stone (-31,17,30, 2026-10-05).
local function wait_case()
    local function have(x, y, z)
        if y == 0 then return "minecraft:stone", 0, false, true end
        if y < 0 then return nil end
        return "air"
    end
    local want = {["9,1,14"] = {"minecraft:spruce_stairs", 4},
                  ["10,1,14"] = {"minecraft:stone", 0}}
    local result = planner.plan(want, have)
    local sp, cp
    for id, p in pairs(result.packets) do
        for _, k in ipairs(p.cells) do
            if k == "9,1,14" then sp = p end
            if k == "10,1,14" then cp = p end
        end
    end
    if not sp or not cp then return "the stair or the stone in no packet" end
    if sp ~= cp and not sp.waits[cp.id] then
        return "the stair's packet neither waits on its click's nor is it"
    end
    -- proven: in one packet the stone first, the stair after it, clicking it
    local stats = prove.run(result, want, have, {entry = {9, 3, 10}})
    if stats.unproven ~= 0 then
        for id, q in pairs(result.packets) do
            if q.unproven then return id .. " unproven: " .. q.unproven end
        end
    end
    return nil
end

-- A turned block whose only stand the plan fills from a packet before its own moves into that
-- packet and goes before it: a stair facing east (stood on from the west) and a fence on that
-- stand, a box west of it (the roof's -1,10,42, 2026-10-05).
local function stand_case()
    local function have(x, y, z)
        if y == 0 then return "minecraft:stone", 0, false, true end
        if y < 0 then return nil end
        return "air"
    end
    local want = {["5,1,12"] = {"minecraft:spruce_stairs", 0},
                  ["4,1,12"] = {"minecraft:fence", 0}}
    local result = planner.plan(want, have)
    local stats = prove.run(result, want, have, {entry = {2, 3, 10}})
    if stats.unproven ~= 0 then
        for id, q in pairs(result.packets) do
            if q.unproven then return id .. " unproven: " .. q.unproven end
        end
    end
    return nil
end

-- A plant holds nothing: a block whose only neighbour is tall grass gets a support (a ray that
-- clicks a replaceable plant puts the block in the plant's cell - the scarecrow's fence beside a
-- bush, 2026-10-05).
local function plant_case()
    local B = {["3,1,4"] = "minecraft:stone", ["3,2,4"] = "minecraft:stone",
               ["3,3,4"] = "minecraft:tallgrass"}
    for k, n in pairs(B) do
        local x, y, z = k:match("(%d+),(%d+),(%d+)")
        vc.route_set(tonumber(x), tonumber(y), tonumber(z), 2)
    end
    local function have(x, y, z)
        if y == 0 then return "minecraft:stone", 0, false, true end
        if y < 0 then return nil end
        local n = B[x .. "," .. y .. "," .. z]
        if n then return n, 0, false, true end
        return "air"
    end
    local want = {["3,3,3"] = {"minecraft:stone", 0}}
    local result = planner.plan(want, have)
    prove.run(result, want, have, {entry = {6, 5, 6}})
    for _, p in pairs(result.packets) do
        if p.unproven then return "the stone by the grass unproven: " .. p.unproven end
        for _, st in ipairs(p.steps) do
            if st.scaffold then return nil end
        end
    end
    return "the stone beside tall grass placed as if the grass held it"
end

-- A double door across two packets (the 5 x 5 grid cuts between x 4 and 5), both upper halves
-- planned 8 as the village's at -11/-10,6,41: the first half goes before the frame beside it,
-- the second beside the first; the door beside is no normal cube, and moves nothing.
local function double_case()
    local function have(x, y, z)
        if y == 0 then return "minecraft:stone", 0, false, true end
        if y < 0 then return nil end
        return "air"
    end
    local want = {
        ["4,1,11"] = {"minecraft:wooden_door", 1}, ["4,2,11"] = {"minecraft:wooden_door", 8},
        ["5,1,11"] = {"minecraft:wooden_door", 1}, ["5,2,11"] = {"minecraft:wooden_door", 8},
        ["3,1,11"] = {"minecraft:planks", 0}, ["3,2,11"] = {"minecraft:planks", 0},
        ["6,1,11"] = {"minecraft:planks", 0}, ["6,2,11"] = {"minecraft:planks", 0},
    }
    local result = planner.plan(want, have)
    local stats = prove.run(result, want, have, {entry = {4, 4, 6}})
    if stats.unproven ~= 0 then
        for id, q in pairs(result.packets) do
            if q.unproven then return "double door: " .. id .. " unproven: " .. q.unproven end
        end
    end
    return nil
end

-- A dig of leaves takes them by any meta: the map's leaves:0 stands in the world as leaves:8 (its
-- decay bit), and the dig's check had stopped Cortana's dry run (dig 0 0 8, 2026-10-06).
local function leaves_case()
    local w = simbot.world({["3,1,3"] = {"minecraft:leaves", 8}, ["3,0,3"] = {"minecraft:dirt", 0}})
    local r = simbot.robot(w, {x = 3, y = 2, z = 3, facing = "n"})
    local p = {steps = {{k = "3,1,3", act = "dig", block = {"minecraft:leaves", 0}}}}
    local text, why = programs.make(p, {pos = {3, 2, 3}, facing = "n",
                                        slot_of = function() return 1 end}, {})
    if not text then return "no program for the leaves: " .. tostring(why) end
    local m = machine.new(r.hw, {x = 3, y = 2, z = 3, facing = "n"})
    m.exec("lv", text)
    for _ = 1, 100 do if m.step() ~= "run" then break end end
    if m.state ~= "done" or w:get(3, 1, 3) then
        return "leaves:8 not dug as the plan's leaves:0: " .. m.state .. " " .. tostring(m.why)
    end
    return nil
end

local function run_test()
    return rules() or set_case() or wait_case() or stand_case() or plant_case() or double_case()
        or leaves_case()
end

return {run_test = run_test}
