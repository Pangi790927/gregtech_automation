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
    -- every support put carries the stand and face that hold it (a support with none had its
    -- program's face meet nothing - place -1 1 5's -2,7,26, 2026-10-06)
    for _, id in ipairs(result.order) do
        for _, st in ipairs(result.packets[id].steps or {}) do
            if st.scaffold and st.act == "place" and not (st.dir and st.face) then
                return "a support put with no stand and face: " .. st.k
            end
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
    -- placed: the item's damage with the no-decay bit (ItemLeaves, d | 4) - the copies had put
    -- leaves:1 where the plan wants leaves:5, and every dry run of place -1 0 7 stopped
    -- "not-expected minecraft:leaves:1" (2026-10-06); the program's own checks pass on it
    if orient.item_meta("minecraft:leaves", 1) ~= 5 or orient.item_meta("minecraft:wool", 1) ~= 1
            then
        return "orient.item_meta"
    end
    w = simbot.world({["3,0,3"] = {"minecraft:dirt", 0}})
    r = simbot.robot(w, {x = 3, y = 2, z = 3, facing = "n",
                         slots = {[1] = {name = "minecraft:leaves", meta = 1, count = 1}}})
    p = {steps = {{k = "3,1,3", act = "place", block = {"minecraft:leaves", 5}}}}
    text, why = programs.make(p, {pos = {3, 2, 3}, facing = "n",
                                  slot_of = function() return 1 end}, {want = {}})
    if not text then return "no program placing the leaves: " .. tostring(why) end
    m = machine.new(r.hw, {x = 3, y = 2, z = 3, facing = "n"})
    m.exec("lp", text)
    for _ = 1, 100 do if m.step() ~= "run" then break end end
    local b = w:get(3, 1, 3)
    if m.state ~= "done" or not b or b[2] ~= 5 then
        return ("leaves:1 placed as %s, not leaves:5: %s %s"):format(b and tostring(b[2]) or "air",
                m.state, tostring(m.why))
    end
    return nil
end

-- What holds a place is where its ray meets a block's own shape (orient.holds). Live, Cortana,
-- 2026-10-06: planks:1 into -9,7,33, a bottom slab its only neighbour (north) - from above,
-- "nothing-placed", every face; from the west facing east, placed. The copies had placed both,
-- and the proof had chosen the stand above: every packet like it stopped "nothing-placed".
local function slab_case()
    local SLAB, PLANKS = "minecraft:wooden_slab", "minecraft:planks"
    -- the ray's geometry, the two live results first
    if orient.holds("d", "n", SLAB, 1) then return "holds: a bottom slab from above" end
    if not orient.holds("e", "n", SLAB, 1) then return "holds: a bottom slab from the side" end
    if not orient.holds("d", "n", PLANKS, 1) then return "holds: a full block from above" end
    if not orient.holds("d", "n", SLAB, 9) then return "holds: a top slab beside, from above" end
    if orient.holds("d", "d", SLAB, 1) then return "holds: a bottom slab beyond, from above" end
    if not orient.holds("d", "d", SLAB, 9) then return "holds: a top slab beyond, from above" end
    if orient.holds("d", "n", "minecraft:fence", 0) then return "holds: a fence's post" end
    -- the copies: the place from above refused, from the side made
    local wb = {["5,2,5"] = {SLAB, 1}}
    local w = simbot.world(wb)
    local above = simbot.robot(w, {x = 5, y = 3, z = 6, facing = "n",
                                   slots = {[1] = {name = PLANKS, meta = 1, count = 2}}})
    if above.hw.place("d", 1) then return "the copy placed it from above" end
    local beside = simbot.robot(w, {x = 4, y = 2, z = 6, facing = "e",
                                    slots = {[1] = {name = PLANKS, meta = 1, count = 2}}})
    if not beside.hw.place("e", 1) then return "the copy did not place it from the side" end
    -- the proof: the stand and face it writes hold (not the stand above)
    local function have(x, y, z)
        if y == 0 then return "minecraft:stone", 0, false, true end
        if y < 0 then return nil end
        if x == 5 and y == 2 and z == 5 then return SLAB, 1, false, true end
        return "air"
    end
    local want = {["5,2,6"] = {PLANKS, 1}}
    local rows = {}
    for y = 0, 7 do
        local zs = {}
        for z = 0, 15 do
            local xs = {}
            for x = 0, 15 do
                xs[#xs + 1] = (y == 0 or (x == 5 and y == 2 and z == 5)) and "1" or "0"
            end
            zs[#zs + 1] = table.concat(xs, ",")
        end
        rows[#rows + 1] = ("layer %d %s"):format(y, table.concat(zs, ";"))
    end
    write("test_run/c0_0.txt", table.concat({"# 3d-draw map 1", "box x 0 15 y 0 7 z 0 15",
        "palette 1 minecraft:stone 0 1.50 seen", table.concat(rows, "\n")}, "\n") .. "\n")
    vc.route_load("test_run", 0, 0, 0, 0, 0, 0, 0, "")
    require("route").loaded = true
    local result = planner.plan(want, have)
    prove.run(result, want, have, {entry = {2, 3, 10}})
    for _, q in pairs(result.packets) do
        for _, st in ipairs(q.steps or {}) do
            if st.k == "5,2,6" and st.act == "place" then
                if not st.dir or not st.face then return "the proof wrote no stand and face" end
                local o = orient.click(st.dir, st.face)
                local nk = (5 + o[1]) .. "," .. (2 + o[2]) .. "," .. (6 + o[3])
                local name, meta = have(5 + o[1], 2 + o[2], 6 + o[3])
                if nk ~= "5,2,5" and name == "air" then
                    -- clicking something the proof put there first (a support) is fine too
                    return nil
                end
                if not orient.holds(st.dir, st.face, name, meta) then
                    return ("the proof placed it %s/%s, which does not hold"):format(st.dir,
                                                                                    st.face)
                end
                return nil
            end
        end
    end
    return "the planks never placed by the proof"
end

-- A door placed fills the cell above it too: the packet's later ways keep off it. A way through
-- it had the copy's dry run refused, "blocked minecraft:wooden_door" (ASIMO, place -5 0 6's
-- door at -25,6,31, 2026-10-06).
local function door_way_case()
    -- a corridor along z 5: the door at 5,1,5 east of the robot (4,1,5), the stone's stand at
    -- 6,1,5 beyond it; the only way over the door is its top, 5,2,5 - no way at all is right,
    -- a way through the top is the fault
    local open = {["4,1,5"] = true, ["5,1,5"] = true, ["6,1,5"] = true, ["7,1,5"] = true,
                  ["4,2,5"] = true, ["5,2,5"] = true, ["6,2,5"] = true}
    local function solid(x, y, z) return not open[x .. "," .. y .. "," .. z] end
    local rows = {}
    for y = 0, 7 do
        local zs = {}
        for z = 0, 15 do
            local xs = {}
            for x = 0, 15 do xs[#xs + 1] = solid(x, y, z) and "1" or "0" end
            zs[#zs + 1] = table.concat(xs, ",")
        end
        rows[#rows + 1] = ("layer %d %s"):format(y, table.concat(zs, ";"))
    end
    write("test_run/c0_0.txt", table.concat({"# 3d-draw map 1", "box x 0 15 y 0 7 z 0 15",
        "palette 1 minecraft:stone 0 1.50 seen", table.concat(rows, "\n")}, "\n") .. "\n")
    vc.route_load("test_run", 0, 0, 0, 0, 0, 0, 0, "")
    require("route").loaded = true
    local wb = {}
    for x = 0, 15 do
        for y = 0, 7 do
            for z = 0, 15 do
                if solid(x, y, z) then wb[x .. "," .. y .. "," .. z] = {"minecraft:stone", 0} end
            end
        end
    end
    local w = simbot.world(wb)
    local DOOR = "minecraft:wooden_door"
    local dm = orient.meta(DOOR, 0, "e", "d")
    local r = simbot.robot(w, {x = 4, y = 1, z = 5, facing = "e", slots = {
        [1] = {name = DOOR, meta = 0, count = 1},
        [2] = {name = "minecraft:stone", meta = 0, count = 1}}})
    local p = {steps = {{k = "5,1,5", act = "place", block = {DOOR, dm}, dir = "e", face = "d"},
                        {k = "7,1,5", act = "place", block = {"minecraft:stone", 0},
                         dir = "e", face = "e"}}}
    local text, why = programs.make(p, {pos = {4, 1, 5}, facing = "e",
        slot_of = function(name) return name == DOOR and 1 or 2 end}, {})
    if not text then
        if tostring(why):find("no way", 1, true) then return nil end    -- kept off the top
        return "door way: no program: " .. tostring(why)
    end
    local m = machine.new(r.hw, {x = 4, y = 1, z = 5, facing = "e"})
    m.exec("dw", text)
    for _ = 1, 400 do if m.step() ~= "run" then break end end
    if m.state ~= "done" then
        return ("door way: %s %s - the way crossed the door's top: %s"):format(m.state,
                tostring(m.why), text)
    end
    return nil
end

-- A plant stands only on soil: lavender planned over real lavender (-19,8,51, the map's grass
-- wrong) stopped three robots "nothing-placed" - the copies refuse it, the proof leaves it
-- unproven, saying what is under it (2026-10-06).
local function soil_case()
    local LAV = "BiomesOPlenty:flowers2"
    if not orient.plant(LAV) or orient.plant("minecraft:planks") then return "orient.plant" end
    if not orient.soil("minecraft:grass") or orient.soil(LAV) or orient.soil("minecraft:tallgrass")
            then
        return "orient.soil"
    end
    local w = simbot.world({["5,1,5"] = {LAV, 3}, ["5,1,4"] = {"minecraft:planks", 2}})
    local r = simbot.robot(w, {x = 5, y = 3, z = 5, facing = "n",
                               slots = {[1] = {name = LAV, meta = 3, count = 2}}})
    if r.hw.place("d", 1) then return "the copy put a plant on a plant" end
    local function have(x, y, z)
        if y == 0 then return "minecraft:grass", 0, false, true end
        if y < 0 then return nil end
        if x == 5 and y == 1 and z == 5 then return LAV, 3, false, true end
        if x == 5 and y == 2 and z == 4 then return "minecraft:planks", 2, false, true end
        return "air"
    end
    local want = {["5,2,5"] = {LAV, 3}}
    local result = planner.plan(want, have)
    prove.run(result, want, have, {entry = {2, 3, 10}})
    for _, q in pairs(result.packets) do
        if q.unproven and tostring(q.unproven):find("needs soil under it", 1, true) then
            return nil
        end
        for _, st in ipairs(q.steps or {}) do
            if st.k == "5,2,5" then return "the proof placed a plant on a plant" end
        end
    end
    return "the plant on a plant neither placed nor said unproven"
end

-- A stair whose every stand is taken, the user's way (2026-10-06: "dig and put back for the
-- stairs"): what fills a stand dug, the stair placed from that cell, the block put back from
-- outside it - grass back as grass. Ten of the village's stairs had no other (-2,0,24 ...). Leaves
-- drop nothing, so a stair whose stands are all leaves stays unproven. And the design's rule for
-- plants (the user, 2026-10-06): dirt, sand or farmland under them.
local function dig_back_case()
    if not orient.design_ground("minecraft:sand") or not orient.design_ground("minecraft:grass")
            or orient.design_ground("minecraft:stone")
            or orient.design_ground("minecraft:sandstone")
            or orient.design_ground("BiomesOPlenty:flowers2") then
        return "orient.design_ground"
    end
    local STAIR, GRASS = "minecraft:dark_oak_stairs", "minecraft:grass"
    -- the floor stone; `extra`: the blocks over it. -> the world's blocks, have
    local function ground(extra)
        local wb = {}
        for x = 0, 15 do for z = 0, 15 do wb[x .. ",0," .. z] = {"minecraft:stone", 0} end end
        for k, b in pairs(extra) do wb[k] = b end
        local rows = {}
        for y = 0, 3 do
            local zs = {}
            for z = 0, 15 do
                local xs = {}
                for x = 0, 15 do xs[#xs + 1] = wb[x .. "," .. y .. "," .. z] and "1" or "0" end
                zs[#zs + 1] = table.concat(xs, ",")
            end
            rows[#rows + 1] = ("layer %d %s"):format(y, table.concat(zs, ";"))
        end
        write("test_run/c0_0.txt", table.concat({"# 3d-draw map 1", "box x 0 15 y 0 3 z 0 15",
            "palette 1 minecraft:stone 0 1.50 seen", table.concat(rows, "\n")}, "\n") .. "\n")
        vc.route_load("test_run", 0, 0, 0, 0, 0, 0, 0, "")
        require("route").loaded = true
        return wb, function(x, y, z)
            if x < 0 or x > 15 or z < 0 or z > 15 or y < 0 then return nil end
            local b = wb[x .. "," .. y .. "," .. z]
            if b then return b[1], b[2], false, true end
            return "air"
        end
    end
    -- rising east (meta 0): stood west of it (grass there) or under it (the floor, stone);
    -- clicked beyond it (stone at 9,1,8) - every stand taken
    local wb, have = ground({["7,1,8"] = {GRASS, 0}, ["9,1,8"] = {"minecraft:stone", 0}})
    local want = {["8,1,8"] = {STAIR, 0}}
    local result = planner.plan(want, have)
    prove.run(result, want, have, {entry = {2, 1, 2}})
    local p = result.packets[result.order[1]]
    if not p.steps then return "dig and put back not proven: " .. tostring(p.unproven) end
    local seq = {}
    for _, st in ipairs(p.steps) do seq[#seq + 1] = st.act .. " " .. st.k end
    local s = table.concat(seq, ", ")
    if #p.steps ~= 3 or p.steps[1].act ~= "dig" or p.steps[2].k ~= "8,1,8"
            or p.steps[3].act ~= "place" or p.steps[3].k ~= p.steps[1].k
            or not (p.steps[3].dir and p.steps[3].face) then
        return "dig and put back's steps: " .. s
    end
    -- run on the copy: the stair the plan's way, the stand's block back as it was
    local w = simbot.world(wb)
    w.on_change = function(k)
        local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
        vc.route_set(tonumber(x), tonumber(y), tonumber(z), w.blocks[k] and 2 or 1)
    end
    local SLOT = {[STAIR] = 1, [GRASS] = 2, ["minecraft:stone"] = 3}
    local r = simbot.robot(w, {x = 2, y = 1, z = 2, facing = "n", slots = {
        [1] = {name = STAIR, meta = 0, count = 4}, [2] = {name = GRASS, meta = 0, count = 4},
        [3] = {name = "minecraft:stone", meta = 0, count = 4}}})
    local text, why = programs.make(p, {pos = {2, 1, 2}, facing = "n",
                                        slot_of = function(name) return SLOT[name] end}, {})
    if not text then return "dig and put back's program: " .. tostring(why) end
    local m = machine.new(r.hw, {x = 2, y = 1, z = 2, facing = "n"})
    m.exec("db", text)
    for _ = 1, 3000 do if m.step() ~= "run" then break end end
    local bx, by, bz = p.steps[1].k:match("^(-?%d+),(-?%d+),(-?%d+)$")
    local stair, back = w:get(8, 1, 8), w:get(tonumber(bx), tonumber(by), tonumber(bz))
    if m.state ~= "done" or not stair or stair[1] ~= STAIR or stair[2] ~= 0 or not back
            or back[1] ~= p.steps[1].block[1] then
        return ("dig and put back on the copy: %s %s; stair %s, stand %s - %s"):format(m.state,
                tostring(m.why), stair and (stair[1] .. ":" .. stair[2]) or "air",
                back and back[1] or "air", s)
    end
    -- put back from a stand with a way home: a stair at 8,2,8 placed from under it (leaves west
    -- of it), the planks there put back - not from the pocket north of them, walled in once they
    -- are back (the attic at -16,14,7, place -4 1 1, 2026-10-06), but from the south
    local extra = {["7,2,8"] = {"minecraft:chest", 0}, ["8,1,8"] = {"minecraft:planks", 1},
                   ["9,2,8"] = {"minecraft:stone", 0}}
    for _, k in ipairs({"7,1,7", "9,1,7", "8,1,6", "8,2,7"}) do
        extra[k] = {"minecraft:stone", 0}
    end
    _, have = ground(extra)
    want = {["8,2,8"] = {STAIR, 0}}
    result = planner.plan(want, have)
    prove.run(result, want, have, {entry = {2, 1, 2}})
    p = result.packets[result.order[1]]
    if not p.steps then return "put back into an attic: " .. tostring(p.unproven) end
    -- a log in the stand under it (leaves west): dug, put back by a way of its own - upright,
    -- its click the floor's top (a ridge's log under its stairs, place 0 1 7, 2026-10-06)
    _, have = ground({["7,2,8"] = {"minecraft:chest", 0}, ["8,1,8"] = {"minecraft:log", 0},
                      ["9,2,8"] = {"minecraft:stone", 0}})
    want = {["8,2,8"] = {STAIR, 0}}
    result = planner.plan(want, have)
    prove.run(result, want, have, {entry = {2, 1, 2}})
    p = result.packets[result.order[1]]
    local last = p.steps and p.steps[#p.steps]
    if not last or not last.putback or last.block[1] ~= "minecraft:log"
            or orient.meta("minecraft:log", 0, last.dir, last.face) ~= 0 then
        return "a log put back its own way: " .. tostring(p.unproven)
    end
    -- wild leaves in every stand: nothing comes back from them - dug and left empty, as the
    -- user let them go (2026-10-06, the stairs at -15,6,47 and -28,6,35: "yes")
    local wild = {["7,1,8"] = {"minecraft:leaves", 0}, ["8,0,8"] = {"minecraft:leaves", 0},
                  ["9,1,8"] = {"minecraft:stone", 0}}
    _, have = ground(wild)
    want = {["8,1,8"] = {STAIR, 0}}
    result = planner.plan(want, have)
    prove.run(result, want, have, {entry = {2, 1, 2}})
    p = result.packets[result.order[1]]
    if not p.steps or #p.steps ~= 2 or p.steps[1].act ~= "dig" or p.steps[1].putback
            or not p.steps[1].block[1]:find("leaves", 1, true) then
        return "a stair whose stands are wild leaves: " .. tostring(p.unproven)
    end
    -- ... but never into a pocket: wild leaves in the floor under it, the west stand a chest -
    -- dug, the stair placed from under it, and the robot shut in the floor (place -3 0 10's
    -- -14,5,50, 2026-10-06: the proof let it, the program had no way on)
    _, have = ground({["7,1,8"] = {"minecraft:chest", 0}, ["8,0,8"] = {"minecraft:leaves", 0},
                      ["9,1,8"] = {"minecraft:stone", 0}})
    want = {["8,1,8"] = {STAIR, 0}}
    result = planner.plan(want, have)
    prove.run(result, want, have, {entry = {2, 1, 2}})
    p = result.packets[result.order[1]]
    if p.steps then
        local seq = {}
        for _, st in ipairs(p.steps) do seq[#seq + 1] = st.act .. " " .. st.k end
        return "a stair placed from a pocket it cannot leave: " .. table.concat(seq, ", ")
    end
    -- ... but leaves the plan has (a hedge) are never dug for it
    _, have = ground(wild)
    want = {["8,1,8"] = {STAIR, 0}, ["7,1,8"] = {"minecraft:leaves", 0},
            ["8,0,8"] = {"minecraft:leaves", 0}}
    result = planner.plan(want, have)
    prove.run(result, want, have, {entry = {2, 1, 2}})
    for _, q in pairs(result.packets) do
        for _, st in ipairs(q.steps or {}) do
            if st.act == "dig" and (st.k == "7,1,8" or st.k == "8,0,8") then
                return "the plan's own leaves dug for a stair"
            end
        end
    end
    -- a plant over stone: the design's rule says so first
    _, have = ground({})
    want = {["4,1,4"] = {"BiomesOPlenty:flowers2", 3}}
    result = planner.plan(want, have)
    prove.run(result, want, have, {entry = {2, 1, 2}})
    p = result.packets[result.order[1]]
    if p.steps or not tostring(p.unproven):find("dirt, sand or farmland", 1, true) then
        return "a plant over stone: " .. tostring(p.unproven)
    end
    return nil
end

-- A planned block whose cell holds water: placed into it, the water replaced - no dig (water is
-- none to dig; the planner had made one, "no way to dig 3,-2,7"), and the proof and the copy let
-- the place go (the cabin's stilts, burned out and flooded, 2026-10-06).
local function water_case()
    local wb = {}
    for x = 0, 15 do for z = 0, 15 do wb[x .. ",0," .. z] = {"minecraft:stone", 0} end end
    wb["5,1,5"] = {"minecraft:water", 0}
    local rows = {}
    for y = 0, 3 do
        local zs = {}
        for z = 0, 15 do
            local xs = {}
            for x = 0, 15 do
                local b = wb[x .. "," .. y .. "," .. z]
                xs[#xs + 1] = b and b[1] ~= "minecraft:water" and "1" or "0"
            end
            zs[#zs + 1] = table.concat(xs, ",")
        end
        rows[#rows + 1] = ("layer %d %s"):format(y, table.concat(zs, ";"))
    end
    write("test_run/c0_0.txt", table.concat({"# 3d-draw map 1", "box x 0 15 y 0 3 z 0 15",
        "palette 1 minecraft:stone 0 1.50 seen", table.concat(rows, "\n")}, "\n") .. "\n")
    vc.route_load("test_run", 0, 0, 0, 0, 0, 0, 0, "")
    require("route").loaded = true
    local function have(x, y, z)
        if x < 0 or x > 15 or z < 0 or z > 15 or y < 0 then return nil end
        local b = wb[x .. "," .. y .. "," .. z]
        if b then return b[1], b[2], false, true end
        return "air"
    end
    local want = {["5,1,5"] = {"minecraft:cobblestone", 0}}
    local result = planner.plan(want, have)
    for id, p in pairs(result.packets) do
        if p.kind == "dig" then return "a dig planned for the water: " .. id end
    end
    prove.run(result, want, have, {entry = {2, 1, 2}})
    local p = result.packets[result.order[1]]
    if not p or not p.steps then return "the place into water: " .. tostring(p and p.unproven) end
    local w = simbot.world(wb)
    local r = simbot.robot(w, {x = 2, y = 1, z = 2, facing = "n",
                               slots = {[1] = {name = "minecraft:cobblestone", meta = 0,
                                               count = 2}}})
    local text, why = programs.make(p, {pos = {2, 1, 2}, facing = "n",
                                        slot_of = function() return 1 end}, {})
    if not text then return "the place into water, no program: " .. tostring(why) end
    local m = machine.new(r.hw, {x = 2, y = 1, z = 2, facing = "n"})
    m.exec("wt", text)
    for _ = 1, 500 do if m.step() ~= "run" then break end end
    local b = w:get(5, 1, 5)
    if m.state ~= "done" or not b or b[1] ~= "minecraft:cobblestone" then
        return ("the copy's place into water: %s %s, %s there"):format(m.state, tostring(m.why),
                b and b[1] or "air")
    end
    return nil
end

-- An ExtraTrees fence keeps its wood in a tile entity: the block is meta 0 whatever the item
-- (ASIMO's ExtraTrees:fence:1 read back as :0, its check stopped it - the cabin, 2026-10-06). The
-- copy places it so, the check expects it, the planner counts it built.
local function extratrees_case()
    if orient.item_meta("ExtraTrees:fence", 1) ~= 0
            or orient.placed_meta("ExtraTrees:fence", 1) ~= 0 then
        return "ExtraTrees:fence's placed meta"
    end
    local w = simbot.world({["5,0,5"] = {"minecraft:stone", 0}})
    local r = simbot.robot(w, {x = 5, y = 2, z = 5, facing = "n",
                               slots = {[1] = {name = "ExtraTrees:fence", meta = 1, count = 1}}})
    if not r.hw.place("d", 1) then return "the copy did not place the ExtraTrees fence" end
    local b = w:get(5, 1, 5)
    if not b or b[2] ~= 0 then
        return "the copy's ExtraTrees fence: meta " .. tostring(b and b[2])
    end
    local want = {["5,1,5"] = {"ExtraTrees:fence", 1}}
    local function have(x, y, z)
        if x == 5 and y == 1 and z == 5 then return "ExtraTrees:fence", 0, false, true end
        if y <= 0 then return "minecraft:stone", 0, false, true end
        return "air"
    end
    if next(planner.plan(want, have).packets) then
        return "an ExtraTrees fence read back as :0 planned again"
    end
    return nil
end

local function run_test()
    return rules() or set_case() or wait_case() or stand_case() or plant_case() or double_case()
        or leaves_case() or slab_case() or door_way_case() or soil_case() or dig_back_case()
        or water_case() or extratrees_case()
end

return {run_test = run_test}
