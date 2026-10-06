--[[ The chunk reader (scripts/chunks.lua) on a zone written here: two blocks in a chunk, one
-- guessed; a layer file that adds a block and takes one away; a chunk with no file beside it.
-- @date 2026-10-05 ]]

local chunks = require("chunks")

-- test_run/ itself: main.cpp makes it, and the sandbox has no os.execute to make a folder.
local DIR = "test_run"

local function write(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

--[[ The guesses settled by how trees grow (redesign/09-paths.md, "Guesses"), one row of chunk
-- 20 7 seen from the side, x 320 .. 324 left to right, y 64 at the top (g: guessed):
--     y64   .      .      .     dirt g  .
--     y63   grass  .      log   dirt g  dirt g      the crown's "dirt" beside the log: leaves
--     y62   leaf g .      log   .       .
--     y61   leaf g dirt g log   .       .           buried "leaves" under grass: dirt;
--     y60   dirt   dirt   dirt  dirt    dirt        the dirt on the ground stays dirt ]]
local function settle_case()
    write(DIR .. "/c20_7.txt", table.concat({
        "# 3d-draw map 1",
        "box x 320 324 y 60 64 z 112 112",
        "palette 1 minecraft:dirt 0 0.50 seen",
        "palette 2 BiomesOPlenty:leaves4 1 0.20 seen",
        "palette 3 minecraft:grass 0 0.60 seen",
        "palette 4 minecraft:log 0 2.00 seen",
        "layer 60 1,1,1,1,1",
        "layer 61 2,1,4,0,0",
        "layer 62 2,0,4,0,0",
        "layer 63 3,0,4,1,1",
        "layer 64 0,0,0,1,0",
        "guessed 61 1,1,0,0,0",
        "guessed 62 1,0,0,0,0",
        "guessed 63 0,0,0,1,1",
        "guessed 64 0,0,0,1,0",
    }, "\n") .. "\n")
    local area = chunks.read_area(DIR, 20, 20, 7, 7, {})
    if not area then return "settle: no area read" end
    local function name(x, y) local c = area.cells[x .. "," .. y .. ",112"]; return c and c[4] end
    if name(320, 61) ~= "minecraft:dirt" or name(320, 62) ~= "minecraft:dirt" then
        return "settle: the leaves under the grass are not dirt: " .. tostring(name(320, 62))
    end
    if name(321, 61) ~= "minecraft:dirt" then return "settle: the dirt on the ground moved" end
    for _, xy in ipairs({{323, 63}, {323, 64}, {324, 63}}) do
        local n = name(xy[1], xy[2])
        if not (n and n:find("leaves")) then
            return ("settle: the crown's dirt at %d %d is %s"):format(xy[1], xy[2], tostring(n))
        end
        if area.cells[xy[1] .. "," .. xy[2] .. ",112"][7] then
            return "settle: a settled leaf is still a guess"
        end
    end
    -- ground over a cave, beside a guessed leaf only: dirt still (chunk 21 7, x 336 .. 338)
    write(DIR .. "/c21_7.txt", table.concat({
        "# 3d-draw map 1",
        "box x 336 338 y 60 64 z 112 112",
        "palette 1 minecraft:dirt 0 0.50 seen",
        "palette 2 BiomesOPlenty:leaves4 1 0.20 seen",
        "layer 60 1,1,1",
        "layer 61 0,0,0",
        "layer 62 1,2,1",
        "layer 63 1,1,1",
        "layer 64 1,1,1",
        "guessed 62 1,1,1",
        "guessed 63 1,1,1",
        "guessed 64 1,1,1",
    }, "\n") .. "\n")
    local cave = chunks.read_area(DIR, 21, 21, 7, 7, {})
    for k, c in pairs(cave.cells) do
        if c[4]:find("leaves") then return "settle: ground over a cave became leaves at " .. k end
    end
    if area.settled.leaves ~= 3 or area.settled.dirt ~= 2 then
        return ("settle: %d leaves, %d dirt counted"):format(area.settled.leaves,
                                                             area.settled.dirt)
    end
    return nil
end

-- The newest wins: world.txt read last, everything new written to it (chunks.LAYERS, the user's
-- "go with world.txt", 2026-10-06) - a cell built.txt says was dug, scanned since as dirt, is
-- dirt to the map and to the pathfinder's grid (the upper field's cells, overridden before).
local function world_case()
    if chunks.LAYERS[#chunks.LAYERS] ~= chunks.WORLD then return "world.txt not read last" end
    write(DIR .. "/world.txt", "# world\n240 60 112 minecraft:dirt 0 0.50 scouted Pintsize\n")
    local z = chunks.read_zone(DIR, 15, 7, {DIR .. "/built.txt", DIR .. "/world.txt"})
    local c = z and z.cells["240,60,112"]
    if not c or c[4] ~= "minecraft:dirt" then return "world.txt's dirt lost to built.txt's air" end
    local vc = require("virt_composer")
    vc.route_load(DIR, 15, 15, 7, 7, 0, 0, 0, DIR .. "/built.txt\n" .. DIR .. "/world.txt")
    if vc.route_get(240, 60, 112) ~= 2 then return "the grid kept built.txt's air" end
    return nil
end

local function run_test()
    -- chunk 15 7: x 240..255, z 112..127; two rows of a layer at y 60
    write(DIR .. "/c15_7.txt", table.concat({
        "# 3d-draw map 1",
        "box x 240 255 y 60 61 z 112 127",
        "palette 1 minecraft:stone 0 1.50 seen",
        "palette 2 minecraft:dirt 0 0.50 seen",
        "layer 60 1,0,2;0,1",
        "guessed 60 0,0,1;0,0",
    }, "\n") .. "\n")
    write(DIR .. "/built.txt", table.concat({
        "# built",
        "241 61 112 minecraft:planks 1 2.0 built house.txt",
        "240 60 112 minecraft:air 0 0.0 built house.txt",
        "500 60 112 minecraft:planks 1 2.0 built house.txt",
    }, "\n") .. "\n")
    write(DIR .. "/zone.txt", "zone 15 7\n")

    local cx, cz = chunks.read_pair(DIR .. "/zone.txt", "zone")
    if cx ~= 15 or cz ~= 7 then return "read_pair gave " .. tostring(cx) .. " " .. tostring(cz) end
    local z = chunks.read_zone(DIR, 15, 7, {DIR .. "/built.txt"})
    if not z then return "no zone read" end
    local c = z.cells
    if c["240,60,112"] then return "the layer's air did not take the stone away" end
    local dirt = c["242,60,112"]
    if not dirt or dirt[4] ~= "minecraft:dirt" or not dirt[7] then
        return "the guessed dirt at 242 60 112 is wrong"
    end
    local stone = c["241,60,113"]
    if not stone or stone[4] ~= "minecraft:stone" or stone[7] then
        return "the seen stone at 241 60 113 is wrong"
    end
    local planks = c["241,61,112"]
    if not planks or planks[4] ~= "minecraft:planks" or planks[5] ~= 1 then
        return "the built planks are missing"
    end
    if c["500,60,112"] then return "a layer block outside the zone was taken" end
    local n = 0
    for _ in pairs(c) do n = n + 1 end
    if n ~= 3 then return ("%d cells, 3 meant"):format(n) end
    local b = z.box
    if b[1] ~= 224 or b[2] ~= 271 or b[3] ~= 60 or b[4] ~= 61 then
        return ("box %d %d %d %d"):format(b[1], b[2], b[3], b[4])
    end
    return world_case() or settle_case()
end

return {run_test = run_test}
