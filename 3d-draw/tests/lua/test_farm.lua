--[[ The field (redesign/13-farm.md): equip, till and the check that it took on a simulated robot;
-- seeds only onto farmland; and a little field - three farmland cells in a row with wheat on them,
-- on a stone floor - planned, proven (each cell tilled from beside, the farthest first), made
-- into a program and run: farmland and planted wheat at the end, the mattock back in its slot.
-- @date 2026-10-05 ]]

local vc = require("virt_composer")
local machine = require("machine")
local simbot = require("simbot")
local planner = require("planner")
local prove = require("prove")
local programs = require("programs")

local function run(m)
    for _ = 1, 3000 do if m.step() ~= "run" then break end end
    return m.state
end

local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local MATTOCK = {name = "TConstruct:mattock", meta = 0, count = 1}

local function ops_cases()
    -- dirt in front, air above it: the mattock in hand, the till, the check, the mattock back
    local w = simbot.world({["1,0,0"] = {"minecraft:dirt", 0}, ["1,-1,0"] = {"minecraft:stone", 0}})
    local r = simbot.robot(w, {facing = "e", slots = {[2] = {name = MATTOCK.name, meta = 0,
                                                              count = 1}}})
    local m = machine.new(r.hw, {x = 0, y = 0, z = 0, facing = "e"})
    m.exec("f1", "$0 {minecraft:farmland:*} e2 u>/+ ?>1 e2")
    if run(m) ~= "done" then return "the till: " .. m.state .. " " .. tostring(m.why) end
    if w:get(1, 0, 0)[1] ~= "minecraft:farmland" then return "the dirt was not tilled" end
    if not r.slots[2] or r.slots[2].name ~= MATTOCK.name then return "the mattock not back" end
    -- a block above the dirt: the till does not take, and the check stops it
    w = simbot.world({["1,0,0"] = {"minecraft:dirt", 0}, ["1,1,0"] = {"minecraft:stone", 0}})
    r = simbot.robot(w, {facing = "e", slots = {[2] = {name = MATTOCK.name, meta = 0, count = 1}}})
    m = machine.new(r.hw, {x = 0, y = 0, z = 0, facing = "e"})
    m.exec("f2", "$0 {minecraft:farmland:*} e2 u> ?>1 e2")
    if run(m) ~= "stop" or not tostring(m.why):find("not%-expected") then
        return "a till under a block was not stopped: " .. m.state
    end
    -- seeds: onto farmland they plant, onto dirt not
    w = simbot.world({["0,-2,0"] = {"minecraft:farmland", 0}, ["1,-2,0"] = {"minecraft:dirt", 0}})
    r = simbot.robot(w, {slots = {[1] = {name = "minecraft:wheat_seeds", meta = 0, count = 2}}})
    m = machine.new(r.hw, {x = 0, y = 0, z = 0, facing = "n"})
    m.exec("f3", "$0 p-1")
    if run(m) ~= "done" or w:get(0, -1, 0)[1] ~= "minecraft:wheat" then
        return "seeds onto farmland did not plant"
    end
    m.exec("f4", "$0 > p-1")
    if run(m) ~= "stop" then return "seeds onto dirt planted" end
    return nil
end

local function field_case()
    -- the world: a stone floor at y 0, x 0..15, z 0..15
    local rows = {}
    for y = 0, 7 do
        local zs = {}
        for z = 0, 15 do
            local xs = {}
            for x = 0, 15 do xs[#xs + 1] = y == 0 and "1" or "0" end
            zs[#zs + 1] = table.concat(xs, ",")
        end
        rows[#rows + 1] = ("layer %d %s"):format(y, table.concat(zs, ";"))
    end
    write("test_run/c0_0.txt", table.concat({"# 3d-draw map 1", "box x 0 15 y 0 7 z 0 15",
        "palette 1 minecraft:stone 0 1.50 seen", table.concat(rows, "\n")}, "\n") .. "\n")
    vc.route_load("test_run", 0, 0, 0, 0, 0, 0, 0, "")
    require("route").loaded = true
    local wb = {}
    for x = 0, 15 do for z = 0, 15 do wb[x .. ",0," .. z] = {"minecraft:stone", 0} end end
    -- one cell of the field is dirt already: it is only tilled, never dug and placed again
    wb["7,1,6"] = {"minecraft:dirt", 0}
    vc.route_set(7, 1, 6, 2)
    local function have(x, y, z)
        if x < 0 or x > 15 or z < 0 or z > 15 or y < 0 then return nil end
        local b = wb[x .. "," .. y .. "," .. z]
        if b then return b[1], b[2] end
        return "air"
    end
    local want = {}
    for x = 6, 8 do
        want[x .. ",1,6"] = {"minecraft:farmland", 0}
        want[x .. ",2,6"] = {"minecraft:wheat", 0}
    end
    local result = planner.plan(want, have)
    local stats = prove.run(result, want, have, {entry = {2, 1, 2}})
    if stats.unproven ~= 0 then
        for id, p in pairs(result.packets) do
            if p.unproven then return "field " .. id .. " unproven: " .. p.unproven end
        end
    end
    local tills = 0
    for _, p in pairs(result.packets) do
        for _, st in ipairs(p.steps or {}) do if st.act == "till" then tills = tills + 1 end end
    end
    if tills ~= 3 then return ("%d tills proven for 3 farmland cells"):format(tills) end
    local dirt_places, digs = 0, 0
    for _, p in pairs(result.packets) do
        for _, st in ipairs(p.steps or {}) do
            if st.act == "place" and st.block[1] == "minecraft:dirt" then
                dirt_places = dirt_places + 1
            end
            if st.act == "dig" then digs = digs + 1 end
        end
    end
    if dirt_places ~= 2 or digs ~= 0 then
        return ("the dirt already there: %d dirt placed, %d dug"):format(dirt_places, digs)
    end

    -- the programs, on a simulated robot holding dirt, seeds and its mattock
    local w = simbot.world(wb)
    w.on_change = function(k)
        local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
        vc.route_set(tonumber(x), tonumber(y), tonumber(z), w.blocks[k] and 2 or 1)
    end
    local r = simbot.robot(w, {x = 2, y = 1, z = 2, facing = "n", slots = {
        [1] = {name = "minecraft:dirt", meta = 0, count = 64},
        [2] = {name = "minecraft:wheat_seeds", meta = 0, count = 64},
        [5] = {name = MATTOCK.name, meta = 0, count = 1}}})
    local function slot_of(name)
        if name == "minecraft:dirt" then return 1 end
        if name == "minecraft:wheat" then return 2 end
    end
    for _, id in ipairs(result.order) do
        local p = result.packets[id]
        local text, why = programs.make(p, {pos = {r.x, r.y, r.z}, facing = r.facing,
                                            slot_of = slot_of, tool_slot = 5}, {})
        if not text then return id .. ": " .. tostring(why) end
        local m = machine.new(r.hw, {x = r.x, y = r.y, z = r.z, facing = r.facing})
        local ok, err = m.exec(id, text)
        if not ok then return id .. " does not parse: " .. tostring(err) .. " - " .. text end
        if run(m) ~= "done" then
            return ("%s: %s %s - %s"):format(id, m.state, tostring(m.why), text)
        end
    end
    for x = 6, 8 do
        local f, c = w:get(x, 1, 6), w:get(x, 2, 6)
        if not f or f[1] ~= "minecraft:farmland" then return "not farmland at " .. x .. ",1,6" end
        if not c or c[1] ~= "minecraft:wheat" then return "no wheat at " .. x .. ",2,6" end
    end
    if not r.slots[5] or r.slots[5].name ~= MATTOCK.name then return "the mattock not back" end
    return nil
end

local function run_test()
    return ops_cases() or field_case()
end

return {run_test = run_test}
