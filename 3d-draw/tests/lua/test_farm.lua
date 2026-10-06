--[[ The field (redesign/13-farm.md): equip, till and the check that it took on a simulated robot;
-- seeds only onto farmland; a water bucket poured into a sealed cell, refused into an open one;
-- and a little field, three by two, two deep, its water sealed beside it - planned (its dirt built,
-- its work a packet of its own), proven (down through an exit cell, tilled from below, the dirt
-- filled back, the wheat from two above), made into programs and run: five farmland with wheat,
-- the exit left dirt, the dirt under the field back, no robot ever right above farmland.
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
    -- dirt in front, air above it, water 3 away: the mattock in hand, the till, the check, the
    -- mattock back
    local w = simbot.world({["1,0,0"] = {"minecraft:dirt", 0}, ["1,-1,0"] = {"minecraft:stone", 0},
                            ["4,0,0"] = {"minecraft:water", 0}})
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
    -- no water within 4: Hunger Overhaul keeps the dirt dirt, and the check stops it
    w = simbot.world({["1,0,0"] = {"minecraft:dirt", 0}, ["6,0,0"] = {"minecraft:water", 0}})
    r = simbot.robot(w, {facing = "e", slots = {[2] = {name = MATTOCK.name, meta = 0, count = 1}}})
    m = machine.new(r.hw, {x = 0, y = 0, z = 0, facing = "e"})
    m.exec("f2b", "$0 {minecraft:farmland:*} e2 u>/+ ?>1 e2")
    if run(m) ~= "stop" then return "a till with no water near was not stopped" end
    -- a water bucket poured down into a sealed cell: water there, the bucket back empty; into a
    -- cell with a side open, the copy refuses and the check stops it
    local pit = {["0,-2,0"] = {"minecraft:stone", 0}, ["1,-1,0"] = {"minecraft:stone", 0},
                 ["-1,-1,0"] = {"minecraft:stone", 0}, ["0,-1,1"] = {"minecraft:stone", 0},
                 ["0,-1,-1"] = {"minecraft:stone", 0}}
    w = simbot.world(pit)
    r = simbot.robot(w, {slots = {[3] = {name = "minecraft:water_bucket", meta = 0, count = 1}}})
    m = machine.new(r.hw, {x = 0, y = 0, z = 0, facing = "n"})
    m.exec("w1", "$0 {minecraft:water:0} u-3 ?-1")
    if run(m) ~= "done" then return "the pour: " .. m.state .. " " .. tostring(m.why) end
    if (w:get(0, -1, 0) or {})[1] ~= "minecraft:water" then return "no water poured" end
    if not r.slots[3] or r.slots[3].name ~= "minecraft:bucket" then return "the bucket not back" end
    local open = {}                          -- the same pit, its north side open, dry again
    for k, b in pairs(pit) do open[k] = b end
    open["0,-1,0"], open["0,-1,-1"] = nil, nil
    w = simbot.world(open)
    r = simbot.robot(w, {slots = {[3] = {name = "minecraft:water_bucket", meta = 0, count = 1}}})
    m = machine.new(r.hw, {x = 0, y = 0, z = 0, facing = "n"})
    m.exec("w2", "$0 {minecraft:water:0} u-3 ?-1")
    if run(m) ~= "stop" then return "a pour into an open cell was not stopped" end
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
    -- the world: a stone floor at y 0; dirt at y 1 under the field (x 6..8, z 6..7) and under
    -- the water cell; the water's cell walled by stone; the field's own cells, at y 2, air - the
    -- build packets put their dirt, the field's work tills them from below
    local wb = {}
    for x = 0, 15 do for z = 0, 15 do wb[x .. ",0," .. z] = {"minecraft:stone", 0} end end
    for x = 6, 9 do for z = 6, 7 do wb[x .. ",1," .. z] = {"minecraft:dirt", 0} end end
    -- and a stone two above 8,2,7, where its wheat would be planted from: it comes from beside,
    -- from over the stone at 9,2,7 (a scarecrow's fence there, 2026-10-06)
    -- and over 7,2,7 a stone two above with farmland on all its sides at its level: its wheat
    -- cannot be planted from anywhere, so it is the exit (the scarecrow's arm, -22,5,21)
    -- and over 6,2,7 the same: one of the two is the exit; the other's wheat is planted from
    -- over the exit (dirt, not farmland) or left for the user - never missing unsaid
    for _, c in ipairs({{10, 2, 6}, {9, 2, 5}, {9, 2, 7}, {8, 4, 7}, {7, 4, 7}, {6, 4, 7}}) do
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
    local want = {}
    for x = 6, 8 do
        for z = 6, 7 do
            want[x .. ",2," .. z] = {"minecraft:farmland", 0}
            want[x .. ",3," .. z] = {"minecraft:wheat", 0}
        end
    end
    want["9,2,6"] = {"minecraft:water", 0}
    -- a fence of the village in the same 5 x 5 box as the field's dirt: not the field's to wait on
    want["5,1,9"] = {"minecraft:fence", 0}
    -- tall grass two above 8,2,6, on its wheat's stand: dug first, the field waiting on that dig
    wb["8,4,6"] = {"minecraft:tallgrass", 1}
    vc.route_set(8, 4, 6, 2)
    -- a fence planned two above 7,2,6, on its wheat's stand, on a stone post: after the field
    want["7,4,6"] = {"minecraft:fence", 0}
    wb["7,5,6"] = {"minecraft:stone", 0}
    vc.route_set(7, 5, 6, 2)
    want["9,2,7"] = nil
    local result = planner.plan(want, have)
    local stats = prove.run(result, want, have, {entry = {2, 1, 2}})
    if stats.unproven ~= 0 then
        for id, p in pairs(result.packets) do
            if p.unproven then return "field " .. id .. " unproven: " .. p.unproven end
        end
    end
    local field
    for _, p in pairs(result.packets) do if p.field then field = p end end
    if not field or not field.exit then return "no field work, or no exit" end
    -- its waits: its own build packet (its dirt, the dirt under it, its water) and its own dig
    -- packet (the grass on a stand), nothing of the village's
    local dug = false
    for q in pairs(field.waits) do
        if q == field.id .. " dig" then
            for _, k in ipairs(result.packets[q].cells) do
                if k == "8,4,6" then dug = true end
            end
            goto next_wait
        end
        if q ~= field.id .. " build" then return "the field waits on " .. q end
        for _, k in ipairs(result.packets[q].cells) do
            if k == "5,1,9" then return "the village's fence in the field's build" end
        end
        ::next_wait::
    end
    if not dug then return "the grass on a stand not in the field's own dig" end
    if field.exit ~= "7,2,7" and field.exit ~= "6,2,7" then
        return "the exit is " .. field.exit .. ", not a cell whose wheat cannot be planted"
    end

    -- every cell over its farmland kept off the routes, but the exit's (it goes down that way)
    local locked = {}
    for _, k in ipairs(field.lock or {}) do locked[k] = true end
    for x = 6, 8 do
        for z = 6, 7 do
            local over, below = x .. ",3," .. z, x .. ",2," .. z
            if (below == field.exit) == (locked[over] or false) then
                return "the lock over the field at " .. over .. " wrong"
            end
        end
    end

    -- the programs, on a simulated robot holding dirt, seeds, a water bucket and its mattock
    local w = simbot.world(wb)
    w.on_change = function(k)
        local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
        vc.route_set(tonumber(x), tonumber(y), tonumber(z), w.blocks[k] and 2 or 1)
    end
    local r = simbot.robot(w, {x = 2, y = 1, z = 2, facing = "n", slots = {
        [1] = {name = "minecraft:dirt", meta = 0, count = 64},
        [2] = {name = "minecraft:wheat_seeds", meta = 0, count = 64},
        [3] = {name = "minecraft:water_bucket", meta = 0, count = 1},
        [4] = {name = "minecraft:fence", meta = 0, count = 8},
        [5] = {name = MATTOCK.name, meta = 0, count = 1}}})
    local function slot_of(name)
        if name == "minecraft:dirt" then return 1 end
        if name == "minecraft:wheat" then return 2 end
        if name == "minecraft:water" then return 3 end
        if name == "minecraft:fence" then return 4 end
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
    -- five farmland with wheat, the exit left dirt with nothing on it, the dirt under all back
    for x = 6, 8 do
        for z = 6, 7 do
            local k = x .. ",2," .. z
            local f, c, u = w:get(x, 2, z), w:get(x, 3, z), w:get(x, 1, z)
            if not u or u[1] ~= "minecraft:dirt" then
                return "the dirt under " .. k .. " not back"
            end
            if k == field.exit then
                if not f or f[1] ~= "minecraft:dirt" then return "the exit " .. k .. " not dirt" end
                if c then return "something on the exit " .. k end
            else
                if not f or f[1] ~= "minecraft:farmland" then
                    return ("not farmland at %s (%s): a robot over it, or not tilled"):format(k,
                            f and f[1] or "air")
                end
                local wk = x .. ",3," .. z
                if (not c or c[1] ~= "minecraft:wheat") and not (result.field_exit or {})[wk] then
                    return "no wheat on " .. k .. ", and not left for the user"
                end
            end
        end
    end
    local fence_after = false
    for _, p in pairs(result.packets) do
        for _, k in ipairs(p.cells) do
            if k == "7,4,6" and p ~= field and p.waits[field.id] then fence_after = true end
        end
    end
    if not fence_after then return "the fence on a wheat's stand does not wait on the field" end
    local beside = false
    for _, st in ipairs(field.steps) do
        if st.k == "8,3,7" and st.face == "d" and st.from[2] == 3 then beside = true end
    end
    if not beside then return "the wheat at 8,3,7 not planted from beside" end
    if not result.field_exit or not next(result.field_exit) then
        return "the exit's wheat not listed for the user"
    end
    if (w:get(9, 2, 6) or {})[1] ~= "minecraft:water" then return "no water at 9,2,6" end
    if not r.slots[5] or r.slots[5].name ~= MATTOCK.name then return "the mattock not back" end
    return nil
end

-- The simulated crew's robots (sim.lua) hold what the live crew would take from the ME: a water
-- cell's water bucket, wheat's seeds, farmland's dirt - and a mattock in their last slot. Without
-- them the first field run would have poured nothing and tilled nothing (2026-10-05).
local function sim_case()
    local sim = require("sim")
    local rob = {kinds = {}, b = {slots = {}}}
    local slot_of = sim.slot_of(rob)
    local want = {{"minecraft:water", 0, "minecraft:water_bucket"},
                  {"minecraft:wheat", 0, "minecraft:wheat_seeds"},
                  {"minecraft:farmland", 0, "minecraft:dirt"}}
    for _, w in ipairs(want) do
        local s = slot_of(w[1], w[2])
        if not s or rob.b.slots[s].name ~= w[3] then
            return ("the sim's robot holds %s for %s"):format(
                    tostring(s and rob.b.slots[s].name), w[1])
        end
        if s == sim.MATTOCK_SLOT then return "a block's item in the mattock's slot" end
    end
    return nil
end

-- A program keeps off the cells its packet locks: the straight way along x crosses them, the
-- way made goes round (a field's cells over its farmland, 13-farm.md).
local function lock_case()
    local p = {lock = {"4,2,2", "5,2,2"}, steps = {{k = "7,1,2", act = "place",
               block = {"minecraft:dirt", 0}, from = {7, 2, 2}, dir = "d"}}}
    local text = programs.make(p, {pos = {2, 2, 2}, facing = "e",
                                   slot_of = function() return 1 end}, {})
    if not text then return "no program past the locked cells" end
    local x, y, z = 2, 2, 2
    local STEP = {["^"] = {0, 0, -1}, v = {0, 0, 1}, [">"] = {1, 0, 0}, ["<"] = {-1, 0, 0},
                  ["+"] = {0, 1, 0}, ["-"] = {0, -1, 0}}
    for ch, n in text:gsub("^%$%S+%s*", ""):gmatch("([%^v<>%+%-])(%d*)") do
        for _ = 1, tonumber(n) or 1 do
            local d = STEP[ch]
            if not d then break end
            x, y, z = x + d[1], y + d[2], z + d[3]
            if y == 2 and z == 2 and (x == 4 or x == 5) then
                return "the way runs through a locked cell: " .. text
            end
        end
    end
    if vc.route_get(4, 2, 2) ~= 1 then return "a locked cell left walled in the grid" end
    return nil
end

-- A field worked already - all farmland but its exit - is no work: no packet for it, and the wheat
-- still unplanted over it goes to the user's list (the upper field came back for its exit's wheat
-- and one boxed in, 2026-10-06).
local function worked_case()
    local function have(x, y, z)
        if y == 0 then return "minecraft:stone", 0, false, true end
        if y == 1 then return "minecraft:dirt", 0, false, true end
        if y == 2 and z == 6 and x >= 6 and x <= 8 then
            if x == 6 then return "minecraft:dirt", 0, false, true end     -- the exit
            return "minecraft:farmland", 0, false, true
        end
        if y == 3 and z == 6 and x >= 7 and x <= 8 then return "minecraft:wheat", 0 end
        if y < 0 then return nil end
        return "air"
    end
    local want = {}
    for x = 6, 8 do
        want[x .. ",2,6"] = {"minecraft:farmland", 0}
        want[x .. ",3,6"] = {"minecraft:wheat", 0}
    end
    local result = planner.plan(want, have)
    for id, p in pairs(result.packets) do
        if p.field then return "a worked field made a packet: " .. id end
        for _, k in ipairs(p.cells) do
            if k == "6,3,6" then return "the exit's wheat left in packet " .. id end
        end
    end
    if not (result.field_exit or {})["6,3,6"] then return "the exit's wheat not listed" end
    return nil
end

local function run_test()
    return ops_cases() or field_case() or lock_case() or worked_case() or sim_case()
end

return {run_test = run_test}
