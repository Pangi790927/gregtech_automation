--[[ The robot's state machine (robot/machine.lua) on a simulated robot (scripts/simbot.lua): the
-- notation parses one way only, and every op, stop and wait does what 03-exec.md says.
-- @date 2026-10-05 ]]

local machine = require("machine")
local simbot = require("simbot")

-- Runs the machine until it is no longer running, or `limit` steps.
local function run(m, limit)
    for _ = 1, limit or 200 do
        if m.step() ~= "run" then break end
    end
    return m.state
end

local function fresh(blocks, opts)
    local w = simbot.world(blocks or {})
    local r = simbot.robot(w, opts or {})
    local m = machine.new(r.hw, {x = r.x, y = r.y, z = r.z, facing = r.facing})
    return w, r, m
end

local function parse_cases()
    local p = machine.parse("$120 {minecraft:dirt:0} >3^2 f> x-1 p-3/^! u-7/^ t>2.5*64 g>9 "
            .. "s4.1*1 c16*4 l- z90 @1 h")
    if not p then return "the full example did not parse" end
    local kinds = {}
    for i, op in ipairs(p.ops) do kinds[i] = op.k end
    local want = "step step face dig put use take give shift craft look charge chunk halt"
    if table.concat(kinds, " ") ~= want then return "ops: " .. table.concat(kinds, " ") end
    if p.ops[1].n ~= 3 or p.ops[1].dir ~= "e" or p.ops[2].n ~= 2 or p.ops[2].dir ~= "n" then
        return "the steps' counts"
    end
    local put = p.ops[5]
    if put.dir ~= "d" or put.slot ~= 3 or put.face ~= "n" or not put.sneak then return "the put" end
    -- p-3 then a step east: the slot ends at the step's character
    local q = machine.parse("$0 p-3>")
    if not q or #q.ops ~= 2 or q.ops[1].slot ~= 3 or q.ops[2].dir ~= "e" then
        return "p-3> did not read as a put and a step"
    end
    -- a face is only ever after its mark: p>12^ is a put then a step north
    q = machine.parse("$0 p>12^")
    if not q or #q.ops ~= 2 or q.ops[1].face ~= nil then return "p>12^ took ^ as a face" end
    if machine.parse("$0 x-1") then return "a dig with no palette parsed" end
    if machine.parse("$0 q") then return "an unknown op parsed" end
    if machine.parse(">") then return "a program without $ parsed" end
    local h = machine.parse("$home {minecraft:leaves:*} x<1")
    if not h or not h.home or h.palette[1].meta ~= "*" then return "$home and a * meta" end
    return nil
end

local function walk_cases()
    local w, r, m = fresh()
    m.exec("1", "$0 >3 ^2 +")
    if run(m) ~= "done" then return "a free walk did not finish: " .. m.state end
    if r.x ~= 3 or r.z ~= -2 or r.y ~= 1 then
        return ("walked to %d %d %d"):format(r.x, r.y, r.z)
    end
    if m.pos[1] ~= 3 or m.pos[3] ~= -2 then return "the machine lost its position" end
    if #m.hist ~= 6 then return ("%d history lines for 6 steps"):format(#m.hist) end
    -- a block in the way: stopped, named, not dug
    w, r, m = fresh({["2,0,0"] = {"minecraft:stone", 0}})
    m.exec("2", "$0 >3")
    if run(m) ~= "stop" or m.why ~= "blocked minecraft:stone" then
        return "a stone in the way: " .. m.state .. " " .. tostring(m.why)
    end
    if not w:get(2, 0, 0) or r.x ~= 1 then return "the stone was dug or the robot went through" end
    -- a creature: it waits, and goes on when the way is free
    w, r, m = fresh()
    w:add_entity(1, 0, 0)
    m.exec("3", "$0 >2")
    if run(m) ~= "wait" or m.why ~= "entity" then return "no wait for a creature" end
    w:remove_entity(1, 0, 0)
    m.state = "run"
    if run(m) ~= "done" or r.x ~= 2 then return "did not go on after the creature left" end
    -- another robot: it waits too, named a robot
    w, r, m = fresh()
    simbot.robot(w, {x = 1, y = 0, z = 0, name = "other"})
    m.exec("4", "$0 >")
    if run(m) ~= "wait" or m.why ~= "robot" then return "no wait for a robot: " .. m.state end
    return nil
end

local function dig_put_cases()
    -- only the block named: dirt yes, then stone no
    local w, r, m = fresh({["0,-1,0"] = {"minecraft:dirt", 0}, ["1,-1,0"] = {"minecraft:stone", 0}})
    m.exec("5", "$0 {minecraft:dirt:0} x-1 > x-1")
    if run(m) ~= "stop" then return "a dig of the wrong block did not stop" end
    if w:get(0, -1, 0) then return "the dirt was not dug" end
    if not w:get(1, -1, 0) or not m.why:find("not%-expected minecraft:stone") then
        return "the stone was dug, or the stop does not name it: " .. tostring(m.why)
    end
    -- ground is ground: grass where dirt is named is dug; air is done already
    w, r, m = fresh({["0,-1,0"] = {"minecraft:grass", 0}})
    m.exec("5b", "$0 {minecraft:dirt:0} x-1")
    if run(m) ~= "done" or w:get(0, -1, 0) then return "grass under a dirt dig: " .. m.state end
    m.exec("5c", "$0 {minecraft:dirt:0} x-1")
    if run(m) ~= "done" then return "a dig at air: " .. m.state .. " " .. tostring(m.why) end
    -- a guessed cell's dig takes any natural block, never one someone made
    w, r, m = fresh({["0,-1,0"] = {"minecraft:grass", 0}, ["1,-1,0"] = {"minecraft:planks", 1}})
    m.exec("5d", "$0 {natural:*} x-1 > x-1")
    if run(m) ~= "stop" or w:get(0, -1, 0) or not w:get(1, -1, 0) then
        return "a natural dig: grass not dug, or planks dug: " .. m.state
    end
    -- never a robot, even named
    w, r, m = fresh()
    simbot.robot(w, {x = 0, y = -1, z = 0, name = "under"})
    m.exec("6", "$0 {OpenComputers:robot:*} x-1")
    if run(m) ~= "stop" or not w:get(0, -1, 0) then return "a robot was dug" end
    -- the printer: put down from a slot, the slot runs out, the put stops
    local floor = {}                                    -- under the puts: no angel upgrade
    for x = -1, 4 do floor[x .. ",-1,0"] = {"minecraft:stone", 0} end
    w, r, m = fresh(floor, {y = 1, slots = {[1] = {name = "minecraft:cobblestone", meta = 0,
                                                count = 2}}})
    m.exec("7", "$0 p-1 > p-1 > p-1")
    if run(m) ~= "stop" or not m.why:find("nothing%-placed") then
        return "the third put from an empty slot: " .. m.state .. " " .. tostring(m.why)
    end
    if not w:get(0, 0, 0) or not w:get(1, 0, 0) or w:get(2, 0, 0) then return "puts misplaced" end
    -- a put a creature is in the way of waits, and goes on once it left (09-paths.md); a new
    -- floor each time: the world keeps the table it is given, the puts above are in this one
    local function floor_()
        local f = {}
        for x = -1, 4 do f[x .. ",-1,0"] = {"minecraft:stone", 0} end
        return f
    end
    local stone = {name = "minecraft:cobblestone", meta = 0, count = 4}
    w, r, m = fresh(floor_(), {y = 1, slots = {[1] = stone}})
    w:add_entity(0, 0, 0)
    m.exec("7b", "$0 p-1")
    if run(m) ~= "wait" or m.why ~= "entity" then
        return "a put on a creature: " .. m.state .. " " .. tostring(m.why)
    end
    w:remove_entity(0, 0, 0)
    m.state = "run"
    if run(m) ~= "done" or not w:get(0, 0, 0) then
        return "the put did not go on after the creature"
    end
    -- and on a robot: waits, named a robot, nothing dug
    w, r, m = fresh(floor_(), {y = 1, slots = {[1] = {name = "minecraft:cobblestone", meta = 0,
                                                count = 4}}})
    simbot.robot(w, {x = 0, y = 0, z = 0, name = "under"})
    m.exec("7c", "$0 p-1")
    if run(m) ~= "wait" or m.why ~= "robot" then return "a put on a robot: " .. m.state end
    -- a put nothing holds is no creature: it stops, as before
    w, r, m = fresh({}, {y = 1, slots = {[1] = {name = "minecraft:cobblestone", meta = 0,
                                             count = 4}}})
    m.exec("7d", "$0 p-1")
    if run(m) ~= "stop" or not m.why:find("nothing%-placed") then
        return "a put in thin air: " .. m.state .. " " .. tostring(m.why)
    end
    return nil
end

local function items_energy_cases()
    -- take from a chest: all of it, then short - a stop: the robot takes only what it is told,
    -- when told, and the interface's tick is the PC's to wait for (redesign/11-me.md)
    local w, r, m = fresh()
    w:add_container(1, 0, 0, {[1] = {name = "minecraft:planks", meta = 1, count = 40}})
    m.exec("8", "$0 t>1.2*32 t>1.3*16")
    if run(m) ~= "stop" or m.why ~= "took 8 of 16" then return "take: " .. tostring(m.why) end
    if r.slots[2].count ~= 32 or r.slots[3].count ~= 8 then return "take moved the wrong counts" end
    -- give back into the interface's return slot: all of it goes, whatever it is
    w, r, m = fresh()
    local iface = {[1] = {name = "minecraft:glass", meta = 0, count = 64}, sink = {[4] = true}}
    w:add_container(1, 0, 0, iface)
    r.slots[1] = {name = "minecraft:glass", meta = 0, count = 3}
    r.slots[2] = {name = "minecraft:dirt", meta = 0, count = 30}
    m.exec("8c", "$0 g>1.4 g>2.4*30")
    if run(m) ~= "done" or r.slots[1] or r.slots[2] then
        return "give into the return slot: " .. m.state .. " " .. tostring(m.why)
    end
    -- into a stocked slot of another kind: nothing goes, a stop
    r.slots[3] = {name = "minecraft:dirt", meta = 0, count = 5}
    m.exec("8d", "$0 g>3.1*5")
    if run(m) ~= "stop" or m.why ~= "gave 0 of 5" then return "a give that cannot go: " .. m.state end
    if not m.status()[4] then return "the takes' results are not in the status" end
    -- energy: a long walk on little energy stops before the floor, then only $home runs
    w, r, m = fresh({}, {energy = 600})
    m.exec("9", "$50 >20")
    if run(m) ~= "stop" or m.why ~= "no-energy" then return "no energy stop: " .. m.state end
    if m.exec("10", "$0 <") then return "a program not $home ran after no-energy" end
    if not m.exec("11", "$home <") or run(m) ~= "done" then return "the way home did not run" end
    -- give_way: waiting on a robot, step aside and halt; then the rest comes as a new exec
    w, r, m = fresh()
    local other = simbot.robot(w, {x = 1, y = 0, z = 0, name = "other"})
    m.exec("12", "$0 >2")
    run(m)
    if not m.give_way("13", "$0 + h") then return "give_way refused while waiting" end
    if run(m) ~= "halt" or r.y ~= 1 then return "the give-way did not step up and halt" end
    m.exec("14", "$0 - >2")
    w:set(1, 0, 0, nil)                             -- the other has passed
    if run(m) ~= "done" or r.x ~= 2 or r.y ~= 0 then return "did not go on after giving way" end
    -- a give-way without a halt goes back to the op it waited at
    w, r, m = fresh()
    other = simbot.robot(w, {x = 1, y = 0, z = 0, name = "other"})
    m.exec("15", "$0 >2")
    run(m)
    w:set(1, 0, 0, nil)
    m.give_way("16", "$0 + -")
    if run(m) ~= "done" or r.x ~= 2 then return "the give-way did not return to its program" end
    -- the status line, and a history after a stop
    local sf = m.status_fast()
    if not sf:match("^15 done %d+ 2 0 0 e %d+$") then return "status_fast: " .. sf end
    return nil
end

local function run_test()
    package.loaded["machine"] = nil
    for _, f in ipairs({parse_cases, walk_cases, dig_put_cases, items_energy_cases}) do
        local why = f()
        if why then return why end
    end
    return nil
end

return {run_test = run_test}
