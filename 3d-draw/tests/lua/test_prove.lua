--[[ The proof (scripts/prove.lua) and the programs made from it (scripts/programs.lua), on a small
-- world: a stone floor at y 0, a wild leaf at 8 1 2. The plan: a column with an eave, and a block
-- at 8 3 2 whose only neighbour would be a block on the leaf - leaves do not hold (they decay),
-- so it is proven with a scaffold column under it, taken away after. Run on a mock robot, every
-- block of the plan stands at the end and no scaffold is left. And a plan that would shut the
-- station in - a ring around it and a lid - is not proven: no way back to the station.
-- @date 2026-10-05 ]]

local vc = require("virt_composer")
local planner = require("planner")
local prove = require("prove")
local programs = require("programs")
local machine = require("machine")
local simbot = require("simbot")

local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local function run_test()
    local rows = {}
    for y = 0, 7 do
        local zs = {}
        for z = 0, 15 do
            local xs = {}
            for x = 0, 15 do
                local v = 0
                if y == 0 then v = 1 end
                if y == 1 and x == 8 and z == 2 then v = 2 end
                xs[#xs + 1] = tostring(v)
            end
            zs[#zs + 1] = table.concat(xs, ",")
        end
        rows[#rows + 1] = ("layer %d %s"):format(y, table.concat(zs, ";"))
    end
    write("test_run/c0_0.txt", table.concat({"# 3d-draw map 1", "box x 0 15 y 0 7 z 0 15",
        "palette 1 minecraft:stone 0 1.50 seen", "palette 2 minecraft:leaves 0 0.2 seen",
        table.concat(rows, "\n")}, "\n") .. "\n")
    vc.route_load("test_run", 0, 0, 0, 0, 0, 0, 0, "")
    require("route").loaded = true                  -- the module programs.lua and prove.lua hold

    local wb = {}
    for x = 0, 15 do for z = 0, 15 do wb[x .. ",0," .. z] = {"minecraft:stone", 0} end end
    wb["8,1,2"] = {"minecraft:leaves", 0}
    local function have(x, y, z)
        if x < 0 or x > 15 or z < 0 or z > 15 or y < 0 then return nil end
        local b = wb[x .. "," .. y .. "," .. z]
        if b then return b[1], b[2] end
        return "air"
    end
    local want = {}
    for _, k in ipairs({"2,1,2", "2,2,2", "2,3,2", "3,3,2", "8,3,2"}) do
        want[k] = {"minecraft:planks", 1}
    end
    local result = planner.plan(want, have)
    local stats = prove.run(result, want, have, {entry = {5, 1, 5}})
    if stats.unproven ~= 0 then
        for id, p in pairs(result.packets) do
            if p.unproven then return id .. " unproven: " .. p.unproven end
        end
    end
    if stats.scaffolds < 1 then return "the block over the leaf needed a scaffold" end

    -- the station at 12 1 12 walled in by the plan: the packet that closes it is not proven (the
    -- lid hangs on 11 2 12, so it needs no support)
    local shut = {}
    for _, k in ipairs({"11,1,12", "13,1,12", "12,1,11", "12,1,13", "11,2,12", "12,2,12"}) do
        shut[k] = {"minecraft:planks", 1}
    end
    local res2 = planner.plan(shut, have)
    prove.run(res2, shut, have, {entry = {12, 1, 12}})
    local said = nil
    for _, q in pairs(res2.packets) do
        if q.unproven and q.unproven:find("no way back to the station") then said = q.unproven end
    end
    if not said then return "a plan that shuts the station in was proven" end

    -- the proven packets, in order, on a mock robot
    local w = simbot.world(wb)
    -- the grid follows the world, as sim.lua's on_change does
    w.on_change = function(k)
        local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
        vc.route_set(tonumber(x), tonumber(y), tonumber(z), w.blocks[k] and 2 or 1)
    end
    local r = simbot.robot(w, {x = 5, y = 1, z = 5, facing = "n"})
    local kinds = {}
    local function slot_of(name, meta)
        local kk = name .. ":" .. meta
        if not kinds[kk] then
            local n = 0
            for _ in pairs(kinds) do n = n + 1 end
            kinds[kk] = n + 1
        end
        r.slots[kinds[kk]] = {name = name, meta = meta, count = 1000}
        return kinds[kk]
    end
    for _, id in ipairs(result.order) do
        local p = result.packets[id]
        local text, why = programs.make(p, {pos = {r.x, r.y, r.z}, facing = r.facing,
                                            slot_of = slot_of}, {})
        if not text then return id .. ": " .. tostring(why) end
        local m = machine.new(r.hw, {x = r.x, y = r.y, z = r.z, facing = r.facing})
        local ok, err = m.exec(id, text)
        if not ok then return id .. " does not parse: " .. tostring(err) end
        for _ = 1, 5000 do if m.step() ~= "run" then break end end
        if m.state ~= "done" then return ("%s: %s %s"):format(id, m.state, tostring(m.why)) end
    end
    for k, b in pairs(want) do
        local got = w.blocks[k]
        if not got or got[1] ~= b[1] then return "not built: " .. k end
    end
    for k, b in pairs(w.blocks) do
        if b and b[1] == "minecraft:cobblestone" then return "a scaffold left at " .. k end
    end
    return nil
end

return {run_test = run_test}
