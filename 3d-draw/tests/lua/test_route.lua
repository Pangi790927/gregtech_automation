--[[ The pathfinder (route_composer.h) on a chunk written here: a floor at y 0, a wall across the
-- way with one gap, a pool of water, a cell never scanned. The route goes round through the gap,
-- never through water or the unknown, and a mock robot walking it arrives.
-- @date 2026-10-05 ]]

local vc = require("virt_composer")
local machine = require("machine")
local simbot = require("simbot")

local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local function run_test()
    -- chunk 0 0: x 0..15, z 0..15, y 0..3; 1 stone, 2 water; -1 never scanned
    local rows = {}
    for y = 0, 3 do
        local zs = {}
        for z = 0, 15 do
            local xs = {}
            for x = 0, 15 do
                local v = 0
                if y == 0 then v = 1 end
                if y >= 1 and x == 8 and z ~= 12 then v = 1 end           -- the wall, a gap at 12
                if y == 1 and x == 4 and z >= 2 and z <= 6 then v = 2 end -- water
                if y == 1 and x == 5 and z == 1 then v = -1 end           -- never scanned
                xs[#xs + 1] = tostring(v)
            end
            zs[#zs + 1] = table.concat(xs, ",")
        end
        rows[#rows + 1] = ("layer %d %s"):format(y, table.concat(zs, ";"))
    end
    write("test_run/c0_0.txt", table.concat({"# 3d-draw map 1", "box x 0 15 y 0 3 z 0 15",
        "palette 1 minecraft:stone 0 1.50 seen", "palette 2 minecraft:water 0 100 seen",
        table.concat(rows, "\n")}, "\n") .. "\n")
    local n = vc.route_load("test_run", 0, 0, 0, 0, 0, 0, 0, "")
    if n ~= 16 * 16 * 4 - 1 then return "cells loaded: " .. tostring(n) end
    if vc.route_get(4, 1, 3) ~= 3 or vc.route_get(5, 1, 1) ~= 0 or vc.route_get(8, 2, 2) ~= 2 then
        return "the grid's states"
    end
    if vc.route_get(0, 10, 0) ~= 1 then return "the sky above the chunk is not air" end
    local path = vc.route_find(2, 1, 2, 1, 14, 1, 2, 100000)
    if path == "" then return "no way round the wall" end
    -- walk it on a mock robot over the same world: it must arrive, never in water or the unknown
    local blocks = {}
    for x = 0, 15 do
        for z = 0, 15 do
            for y = 0, 3 do
                local s = vc.route_get(x, y, z)
                if s == 2 or s == 3 or s == 0 then blocks[x .. "," .. y .. "," .. z] = {"x", 0} end
            end
        end
    end
    local w = simbot.world(blocks)
    local r = simbot.robot(w, {x = 2, y = 1, z = 2, facing = "e"})
    local m = machine.new(r.hw, {x = 2, y = 1, z = 2, facing = "e"})
    if not m.exec("r", "$0 " .. path) then return "the route does not parse: " .. path end
    for _ = 1, 1000 do if m.step() ~= "run" then break end end
    if m.state ~= "done" or r.x ~= 14 or r.z ~= 2 then
        return ("walked %s: %s at %d %d %d"):format(path, m.state, r.x, r.y, r.z)
    end
    if vc.route_find(2, 1, 2, 1, 8, 1, 2, 100000) ~= "" then return "a way into the wall" end
    vc.route_set(8, 1, 12, 2)                           -- the gap closed: no way at all
    if vc.route_find(2, 1, 2, 1, 14, 1, 2, 100000) ~= "" then
        -- over the wall is still open: the wall is 3 high, the sky above it
        local p2 = vc.route_find(2, 1, 2, 1, 14, 1, 2, 100000)
        if not p2:find("+", 1, true) then return "with the gap closed, not over the wall: " .. p2 end
    end
    return nil
end

return {run_test = run_test}
