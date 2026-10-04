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
    return nil
end

return {run_test = run_test}
