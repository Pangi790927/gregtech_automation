--[[ The live crew (scripts/crew.lua) on a stand-in robot record: what a packet needs, as items,
-- every refusal 10-live.md and 11-me.md list - not proven, waits not done, the robot moving, its
-- slots unknown, a block that needs the robot turned, no room, the ME not linked - and a
-- packet's end writing its cells into world.txt and the done list, in world coordinates; a water
-- cell's bucket and its end; and a robot's way kept off another robot standing still in it, or
-- where a running one ends - in the live crew and the simulation.
-- @date 2026-10-05 ]]

local vc = require("virt_composer")
local spawn = require("spawn")         -- spawns that keep their handle
local crew = require("crew")
local robots = require("robots")
local packets = require("packets")
local view = require("view")

local function lines_of(path)
    local out = {}
    local f = io.open(path, "r")
    if not f then return out end
    for l in f:lines() do out[#out + 1] = l end
    f:close()
    return out
end

local function run_test()
    crew.paths = {done = "test_run/crew-done.txt", world = "test_run/crew-world.txt"}
    for _, p in pairs(crew.paths) do io.open(p, "w"):close() end
    crew.done, crew.jobs = {}, {}
    view.anchor = view.anchor or {0, 0, 0}
    local a = view.anchor

    local place = {id = "place 9 0 9", kind = "place", cells = {"45,1,45", "46,1,45"}, waits = {},
                   steps = {{k = "45,1,45", act = "place", block = {"minecraft:planks", 1}},
                            {k = "46,1,45", act = "place", block = {"minecraft:planks", 1}}}}
    local dig = {id = "dig 9 0 9", kind = "dig", cells = {"45,0,45"}, waits = {},
                 steps = {{k = "45,0,45", act = "dig", block = {"minecraft:dirt", 0}}}}
    local later = {id = "place 9 1 9", kind = "place", cells = {"45,2,45"},
                   waits = {["place 9 0 9"] = true},
                   steps = {{k = "45,2,45", act = "place", block = {"minecraft:planks", 1}}}}
    local unproven = {id = "dig 8 0 8", kind = "dig", cells = {}, waits = {}, unproven = "walled"}
    local stairs = {id = "place 7 0 7", kind = "place", cells = {"35,1,35"}, waits = {},
                    steps = {{k = "35,1,35", act = "place",
                              block = {"minecraft:lever", 3}}}}  -- no rule read yet
    local big = {id = "dig 6 0 6", kind = "dig", cells = {}, waits = {}, steps = {}}
    for i = 1, 200 do              -- 20 kinds dug: more stacks than the robot's 16 slots
        big.steps[i] = {k = i .. ",0,0", act = "dig", block = {"minecraft:dirt", i % 20}}
    end
    packets.result = {packets = {[place.id] = place, [dig.id] = dig, [later.id] = later,
                                 [unproven.id] = unproven, [stairs.id] = stairs, [big.id] = big},
                      order = {}}
    packets.want = {}

    local pl, dg = crew.bill(place)
    if pl["minecraft:planks:1"] ~= 2 or next(dg) then return "the bill of the place packet" end
    -- a stair is one item whatever its way; a top slab's item is the slab
    local n, m = crew.item("minecraft:spruce_stairs", 7)
    local n2, m2 = crew.item("minecraft:stone_slab", 11)
    if m ~= 0 or m2 ~= 3 or n ~= "minecraft:spruce_stairs" or n2 ~= "minecraft:stone_slab" then
        return "the items of placed blocks"
    end

    -- a stand-in robot: linked, standing, its machine older at first (no slot count)
    local r = {name = "Testbot", linked = true, outbox = {},
               sf = {id = "-", state = "idle", op = 1, pos = {40, 1, 40}, facing = "n"},
               status = {"- idle", "max 20000 name Testbot"},
               slots = {[1] = {name = "minecraft:planks", meta = 1, count = 1}}}
    robots.by[r.name] = r
    table.insert(robots.order, r)
    local function refused(id, want)
        local ok, why = crew.start("testbot", id)
        if ok or not tostring(why):find(want, 1, true) then
            return ("%s: %s, not %q"):format(id, tostring(why), want)
        end
    end
    local bad = refused(unproven.id, "not proven")
        or refused(later.id, "waits on place 9 0 9")
        or refused(place.id, "older machine")
    if bad then return bad end
    r.status[2] = "max 20000 name Testbot slots 16"
    bad = refused(stairs.id, "needs the robot turned")
        or refused(big.id, "needs 20 slots, Testbot has 16")
        or refused(place.id, "the ME is")
    if bad then return bad end
    -- its chunkloader off: switched on, nothing taken this round - off, ASIMO, Pintsize and
    -- Baymax stopped with their chunks while no player was on, links dropped, programs lost
    -- (2026-10-06)
    r.status[2] = "max 20000 name Testbot slots 16 chunk false"
    bad = refused(dig.id, "chunkloader was off")
    r.status[2] = "max 20000 name Testbot slots 16"
    if bad then return bad end
    local switched = false
    for _, t in ipairs(r.outbox) do
        if tostring(t.cmd):find(" @1 h", 1, true) then switched = true end
    end
    r.outbox, r.sent = {}, nil
    if not switched then return "the chunkloader not switched on" end
    -- still off after that, its status read anew: it has none - kept home, nothing sent again
    r.status[2] = "max 20000 name Testbot slots 16 chunk false"
    local asked_fresh = false
    spawn(function()
        for _ = 1, 50 do
            local t = r.outbox[1]
            if t and t.cmd == "status" then
                table.remove(r.outbox, 1)
                asked_fresh = true
                t.lines = {"- idle", "max 20000 name Testbot slots 16 chunk false",
                           "inv 1:minecraft:planks:1:1"}
                t.head = "1 ok 3"
                return
            end
            vc.net_sleep_ms(20)
        end
    end)
    bad = refused(dig.id, "no chunkloader that switches on")
    if not bad and not asked_fresh then bad = "its status not read anew before it was judged" end
    r.status[2] = "max 20000 name Testbot slots 16"
    if bad then return bad end
    if #r.outbox > 0 then return "@1 sent again to a robot with no chunkloader" end
    -- ... out after all where every chunk of its work stays loaded (the user's map, 2026-10-06:
    -- "maybe hold a chunkloaded map"): past this check, refused for its slots instead
    crew.paths.loaded = "test_run/chunkloaded.txt"
    local function map(rows)
        local f = io.open(crew.paths.loaded, "w")
        f:write("# test\norigin 0 0\n" .. table.concat(rows, "\n") .. "\n")
        f:close()
    end
    r.status[2] = "max 20000 name Testbot slots 16 chunk false"
    map({("L"):rep(13), ("L"):rep(13), "LLS" .. ("L"):rep(10)})
    bad = refused(big.id, "needs 20 slots")
    map({"S"})
    bad = bad or refused(big.id, "is not kept loaded")
    crew.NO_LOADER_OK = true
    bad = bad or refused(big.id, "needs 20 slots")         -- the user on near it
    crew.NO_LOADER_OK = false
    crew.paths.loaded = nil
    r.status[2] = "max 20000 name Testbot slots 16"
    if bad then return bad end
    r.chunk_tried, r.chunk_read = nil, nil
    -- the ME short only by what the robot does not hold: it holds one of the two planks, so one
    -- is short - three builders held the only trapdoors while the ME, empty, refused all five
    -- (place -1 0 7, 2026-10-06)
    local me = require("me")
    local conn, mview, read_at = me.conn, me.view, crew.view_read_at
    me.conn, me.view, crew.view_read_at = true, {}, vc.app_time()
    bad = refused(place.id, "the ME is short: minecraft:planks:1 x1 (ME 0)")
    -- its program made before it flies: no way to a cell now is "not now", no trip (place
    -- -3 0 10, "no way to place -15,7,50", three trips for nothing, 2026-10-06)
    local programs = require("programs")
    local make = programs.make
    programs.make = function() return nil, "no way to place 45,1,45" end
    me.view = {["minecraft:planks:1"] = 10}
    bad = bad or refused(place.id, "not now: no way to place 45,1,45")
    programs.make = make
    if not bad and crew.jobs.Testbot then bad = "a trip set off with no way to its cell" end
    me.conn, me.view, crew.view_read_at = conn, mview, read_at
    if bad then return bad end
    -- where a robot placed back by hand is, by its six looks against the map (Gunter, believing
    -- 0,0,0, saw an adapter east and a fence west: the station's 0,0,2 - 2026-10-06; the user:
    -- "don't wait for me to figure it out")
    local blocks = {["1,0,2"] = "OpenComputers:adapter", ["-1,0,2"] = "ExtraTrees:fence",
                    ["1,0,0"] = "OpenComputers:charger", ["1,0,1"] = "appliedenergistics2:x"}
    local function what(x, y, z) return blocks[x .. "," .. y .. "," .. z] or "air" end
    local seen = {n = "air", s = "air", e = "OpenComputers:adapter", w = "ExtraTrees:fence",
                  u = "air", d = "air"}
    local found = crew.locate_match(seen, what, {0, 0, 0}, 4)
    if #found ~= 1 or found[1][1] ~= 0 or found[1][2] ~= 0 or found[1][3] ~= 2
            or found[1][4] ~= 0 then
        return "locate_match: " .. #found .. " places for Gunter's looks"
    end
    seen.e, seen.w = "minecraft:chest", "minecraft:chest"
    if #crew.locate_match(seen, what, {0, 0, 0}, 4) ~= 0 then
        return "locate_match: a place for looks that fit nowhere"
    end
    -- every other robot's park is kept off its ways, home or away; its own is not (the user,
    -- 2026-10-06: "should not allow going over each-other's stop points")
    local parker = {name = "Parker", park = {50, 1, 50}, linked = false, outbox = {}}
    robots.by.Parker = parker
    table.insert(robots.order, parker)
    r.park = {41, 1, 41}
    local av = crew.avoid_for(r)
    robots.by.Parker = nil
    table.remove(robots.order)
    r.park = nil
    if not av["50,1,50"] then return "another robot's park, it away, not kept off the ways" end
    if av["41,1,41"] then return "a robot's own park kept off its own ways" end
    -- a program on its way to it: not free (Cortana, place -4 2 8, 2026-10-06)
    r.sent = {id = "p99", t = robots.net.now()}
    bad = refused(dig.id, "on its way to it")
    r.sent = nil
    if bad then return bad end
    r.sf.state = "run"
    bad = refused(dig.id, "still at work")
    if bad then return bad end
    r.sf.state = "done"
    r.outbox[1] = {cmd = "status"}
    bad = refused(dig.id, "queued")
    if bad then return bad end
    r.outbox = {}

    -- the end: done writes every step; a stop only those before the op it stopped at
    crew.finish(r, {p = place, opstep = {[1] = 1, [2] = 2}, t0 = 0}, nil)
    local built = lines_of(crew.paths.world)
    local first = ("%d %d %d minecraft:planks 1"):format(45 + a[1], 1 + a[2], 45 + a[3])
    if #built ~= 2 or built[1]:sub(1, #first) ~= first then
        return "world.txt after the place: " .. table.concat(built, " | ")
    end
    if not crew.done[place.id] or lines_of(crew.paths.done)[1] ~= place.id then
        return "the done list after the place"
    end
    r.sf.op = 1
    crew.finish(r, {p = dig, opstep = {[2] = 1}, t0 = 0}, "stop blocked")
    if #lines_of(crew.paths.world) ~= 2 or crew.done[dig.id] then
        return "a stop at op 1 wrote steps or marked the packet done"
    end

    -- a water cell (13-farm.md): its item a water bucket, one to a stack; its end writes water
    local wet = {id = "place 9 0 8", kind = "place", cells = {"45,1,40"}, waits = {},
                 steps = {{k = "45,1,40", act = "water", block = {"minecraft:water", 0}}}}
    pl = crew.bill(wet)
    if pl["minecraft:water_bucket:0"] ~= 1 or crew.STACK["minecraft:water_bucket:0"] ~= 1 then
        return "the bill of a water cell"
    end
    crew.finish(r, {p = wet, opstep = {[1] = 1}, t0 = 0}, nil)
    built = lines_of(crew.paths.world)
    local poured = ("%d %d %d minecraft:water 0"):format(45 + a[1], 1 + a[2], 40 + a[3])
    if built[#built]:sub(1, #poured) ~= poured then
        return "world.txt after a pour: " .. tostring(built[#built])
    end
    -- a door built: its upper half written too, though the plan names none (the planner never
    -- puts one) - left air, the ways went through it (Dalek_Sec, 2026-10-06)
    local door = {id = "place 9 0 7", kind = "place", cells = {"45,1,38"}, waits = {},
                  steps = {{k = "45,1,38", act = "place", block = {"minecraft:wooden_door", 3}}}}
    packets.want = {}
    crew.finish(r, {p = door, opstep = {[1] = 1}, t0 = 0}, nil)
    built = lines_of(crew.paths.world)
    local upper = ("%d %d %d minecraft:wooden_door 8"):format(45 + a[1], 2 + a[2], 38 + a[3])
    if built[#built]:sub(1, #upper) ~= upper then
        return "world.txt after a door: no upper half: " .. tostring(built[#built])
    end

    -- a packet whose dry run refused it never ran: no step of it written, whatever op the robot
    -- stopped at in its takes (place -3 0 0 lost a step a visit, 8 then 7 then 6, 2026-10-06);
    -- sent and stopped at its op 3, the steps of its ops 1 and 2 are written
    local two = {id = "place 9 0 7", kind = "place", cells = {"45,1,30", "46,1,30"}, waits = {},
                 steps = {{k = "45,1,30", act = "place", block = {"minecraft:planks", 1}},
                          {k = "46,1,30", act = "place", block = {"minecraft:planks", 1}}}}
    local had = #lines_of(crew.paths.world)
    r.sf.id, r.sf.op = "p5", 9
    crew.finish(r, {p = two, opstep = {[1] = 1, [2] = 2}, t0 = 0, what = "taking, round 1",
                    pid = "p5"}, "the packet did not dry-run: stop nothing-placed nothing selected")
    if #lines_of(crew.paths.world) ~= had then return "a packet never sent wrote steps" end
    r.sf.id, r.sf.op = "p6", 3
    crew.finish(r, {p = two, opstep = {[1] = 1, [2] = 2}, t0 = 0, what = "the packet",
                    pid = "p6"}, "the packet: stop blocked minecraft:stone")
    if #lines_of(crew.paths.world) ~= had + 2 then return "a packet stopped at op 3 not written" end
    -- a stair's stand dug and its trip stopped before the grass went back: owed, and planned until
    -- a place writes the cell (ASIMO lost over the lavender of place -6 0 9, 2026-10-06)
    local pb = {id = "place 9 0 4", kind = "place", cells = {"45,1,20"}, waits = {}, steps = {
        {k = "44,1,20", act = "dig", block = {"minecraft:grass", 0}, putback = true},
        {k = "45,1,20", act = "place", block = {"minecraft:dark_oak_stairs", 0}, dir = "e",
         face = "d"},
        {k = "44,1,20", act = "place", block = {"minecraft:grass", 0}, dir = "d", face = "d",
         putback = true}}}
    crew.owed = {}
    r.sf.id, r.sf.op = "p8", 3
    crew.finish(r, {p = pb, opstep = {[1] = 1, [2] = 2, [3] = 3}, t0 = 0, what = "the packet",
                    pid = "p8"}, "the packet: stop blocked minecraft:stone")
    local o = crew.owed["44,1,20"]
    if not o or o[1] ~= "minecraft:grass" then return "a put-back cut short not owed" end
    crew.finish(r, {p = {id = "place 9 0 3", kind = "place", cells = {"44,1,20"}, waits = {},
                         steps = {{k = "44,1,20", act = "place", block = {"minecraft:grass", 0}}}},
                    opstep = {[1] = 1}, t0 = 0}, nil)
    if crew.owed["44,1,20"] then return "a put-back placed still owed" end
    -- a plan begun before a packet finished keeps it done - one begun after reads it in the map
    -- (place -6 1 9 handed out again at once, Dalek_Sec, 2026-10-06)
    local keep_res = packets.result
    local q = {id = "place 9 0 2", kind = "place", cells = {"45,1,10"}, waits = {},
               steps = {{k = "45,1,10", act = "place", block = {"minecraft:planks", 1}}}}
    packets.result = {packets = {[q.id] = q}, order = {q.id}}
    crew.finish(r, {p = q, opstep = {[1] = 1}, t0 = 0}, nil)
    packets.result = {packets = {[q.id] = q}, order = {q.id}, t0 = vc.app_time() - 5}
    local kept = crew.is_done(q.id)
    packets.result = {packets = {[q.id] = q}, order = {q.id}, t0 = vc.app_time() + 5}
    local after = crew.is_done(q.id)
    packets.result = keep_res
    if not kept then return "a packet finished after its plan began handed out again" end
    if after then return "a plan begun after a packet ended still counted it done" end
    r.sf.id, r.sf.op = "-", 1

    -- its slots read at a leg's end, by a status of its own (stale slots planned the next leg:
    -- "nothing selected", "took 0 of 3", "no slot left", 2026-10-06)
    local vc0 = require("virt_composer")
    r.outbox = {}
    spawn(function()
        for _ = 1, 50 do
            local t = r.outbox[1]
            if t then
                table.remove(r.outbox, 1)
                t.lines = {"p6 done 3", "max 20000 name Testbot slots 16",
                           "inv 3:minecraft:stonebrick:0:12;16:TConstruct:mattock:0:1"}
                t.head = "1 ok 3"
                return
            end
            vc0.net_sleep_ms(20)
        end
    end)
    if not crew.read_slots(r) or not r.slots[3] or r.slots[3].count ~= 12 or r.slots[1] then
        return "the slots not read at a leg's end"
    end
    r.slots = {[1] = {name = "minecraft:planks", meta = 1, count = 1}}

    -- what a packet's end means to the loop (crewfix): from the robot's own last line
    local fix = require("crewfix")
    local cases = {
        {"P: place 0 -1 3 done, 9 steps in 139 s", "done"},
        {"P: place 0 -1 3 NOT done, 0 of 16 steps: the packet: its copy diverged: the robot ended"
         .. " stop nothing-placed nil, its copy run", "look"},
        {"P: place 0 -1 3 NOT started: taking, round 1 did not dry-run: wait robot", "wait"},
        {"P: place 0 -1 3 NOT done, 1 of 1 steps: the packet did not dry-run: stop not-expected"
         .. " BiomesOPlenty:flowers2:3", "replan"},
        {"P: place 0 -1 3 NOT started: no way to the interface", "notnow"},
        {"P: place 0 -1 3 NOT started: no program: no way to place -30,16,30", "replan"},
        {"P: place 0 -1 3 NOT done: stop blocked minecraft:stone", "look"},   -- learned
        {"P: place 9 9 9 NOT started: no way to the interface", "fail"},   -- another packet
    }
    for _, c in ipairs(cases) do
        local k = fix.classify(c[1], "place 0 -1 3")
        if k ~= c[2] then return ("crewfix: %q is %s, not %s"):format(c[1], k, c[2]) end
    end
    -- a builder on no job, diverged: stopped where no loop saw its end ("pintsize sleeps", the
    -- loop restarted under four builders, 2026-10-06), or idle a slot count apart
    local idle = {
        {"stop", "the robot ended stop nothing-placed nil, its copy run", "look"},
        {"stop", "the robot ended stop not-expected minecraft:dark_oak_stairs:7, its copy run",
         "look"},
        {"stop", "the robot ended stop out-of-energy, its copy run", nil},
        {"done", "slot 4: robot 12, copy 13", "resync"},
        {"done", "the robot ended done, its copy stop", "resync"},   -- the robot the truth
        {"done", "the robot is at op 8, its copy stopped at 4: robot", "resync"},
    }
    for _, c in ipairs(idle) do
        local k = fix.idle({sf = {state = c[1]}, diverged = {why = c[2]}})
        if k ~= c[3] then return ("crewfix.idle: %q is %s, not %s"):format(c[2], k, c[3]) end
    end
    if fix.idle({sf = {state = "stop"}}) ~= nil then return "crewfix.idle: not diverged" end
    if fix.idle({sf = {state = "stop", why = "nothing-placed"},
                 diverged = {why = "the robot is at op 3, its copy stopped at 2: robot"}}) ~= "look"
            then
        return "crewfix.idle: the robot's own stop reason not read"
    end
    -- a leg's robot: a slot count apart is waited out while it works (Dalek_Sec, dropped
    -- mid-packet, built it all unwatched, 2026-10-06)
    local legs = {
        {"run", "slot 14: the robot holds minecraft:planks:2x20, its copy -", "wait"},
        {"done", "slot 14: the robot holds minecraft:planks:2x20, its copy -", "resync"},
        {"run", nil, "wait"}, {"done", nil, "done"}, {"stop", nil, "stop"},
        {"run", "the robot ended stop nothing-placed nil, its copy run", "diverged"},
        {"done", "the robot ended done, its copy stop not-expected minecraft:torch:0", "resync"},
        {"run", "the robot is at op 3, its copy stopped at 2: robot", "wait"},
        {"done", "the robot ended done, its copy wait robot", "resync"},
        {"run", "the robot is at op 21, its copy stopped at 3: blocked solid", "wait"},
        {"done", "the robot is at op 3, its copy stopped at 2: robot", "resync"},
        {"run", "the robot ended done, its copy stop not-expected minecraft:torch:0", "diverged"},
        -- a copy's take short while the robot went on: the robot took them all (it stops
        -- itself on a short take) - waited out, the robot the truth (Baymax, 2026-10-06)
        {"run", "the robot is at op 8, its copy stopped at 5: took 5 of 9", "wait"},
        {"halt", "the robot is at op 8, its copy stopped at 5: took 5 of 9", "resync"},
        {"halt", "the robot ended halt, its copy stop took 5 of 9", "resync"},
        {"run", "the robot is at op 8, its copy stopped at 5: nothing-placed", "diverged"},
    }
    for _, c in ipairs(legs) do
        local k = fix.leg(c[1], c[2])
        if k ~= c[3] then return ("crewfix.leg: %s %s is %s"):format(c[1], c[2], k) end
    end
    -- a trip that breaks lets its job go and says why (three died silently, 2026-10-06)
    local vc = require("virt_composer")
    local broken = {name = "Broken", slots = nil, sf = nil}
    local bj = {p = {id = "place 7 7 7", cells = {}, steps = {}}, phase = "setting off",
                place = {}, stacks = 0}
    crew.jobs.Broken = bj
    crew.spawn_trip(broken, bj)
    for _ = 1, 20 do
        if not crew.jobs.Broken then break end
        vc.net_sleep_ms(50)
    end
    if crew.jobs.Broken then return "spawn_trip: a broken trip kept its job" end
    if not tostring(crew.log[#crew.log]):find("Broken: its trip on place 7 7 7 broke", 1, true)
            then
        return "spawn_trip: no word of the break: " .. tostring(crew.log[#crew.log])
    end
    -- no resync under a program the robot still runs (Pintsize's copy left behind, 2026-10-06)
    local runner = {name = "Runner", linked = true, outbox = {}, slots = {},
                    sf = {id = "p9", state = "run", op = 2, pos = {1, 1, 1}, facing = "n"},
                    copy = {b = {x = 5, y = 1, z = 5}, m = {id = "p9"}}}
    robots.by.Runner = runner
    table.insert(robots.order, runner)
    local ok_rs = crew.resync("Runner")
    table.remove(robots.order)
    robots.by.Runner = nil
    if ok_rs or runner.copy.m.id ~= "p9" or runner.copy.b.x ~= 5 then
        return "crew.resync: a running robot's copy let go of its program"
    end
    -- a spawn keeps its handle until its coroutine ends (spawn.lua): collected before the pool
    -- ran it, a coroutine never ran at all - three trips never began, 2026-10-06
    local ran, n0 = false, 0
    for _ in pairs(spawn.live) do n0 = n0 + 1 end
    spawn(function() ran = true end)
    local held = 0
    for _ in pairs(spawn.live) do held = held + 1 end
    if held ~= n0 + 1 then return "spawn: the handle not kept before it ran" end
    collectgarbage("collect")                -- the moment that had destroyed it
    for _ = 1, 20 do
        if ran then break end
        vc.net_sleep_ms(20)
    end
    local after = 0
    for _ in pairs(spawn.live) do after = after + 1 end
    if not ran then return "spawn: the coroutine never ran" end
    if after ~= n0 then return "spawn: the handle kept after it ended" end
    -- the looks: from where it stands, or from inside the cell a place failed into - read from
    -- the robot's history (Dalek_Sec's from -19,8,51: lavender under it, the map said grass)
    if crew.look_program() ~= "$0 l^ lv l> l< l+ l-"
            or crew.look_program("d") ~= "$0 - l^ lv l> l< l+ l- +" then
        return "crew.look_program"
    end
    local seen = crew.read_looks({"1 - ok -19 8 51 38066 @85915.85",
        "2 l- ok BiomesOPlenty:flowers2:3 @85915.90", "3 l^ ok minecraft:planks:2 @85916.50",
        "4 lv ok air @85917.45", "5 l> ok air @85918.05",
        "6 l< ok BiomesOPlenty:flowers2:3 @85919.05"}, {-19, 8, 51})
    local want = {{-19, 7, 51, "BiomesOPlenty:flowers2", 3}, {-19, 8, 50, "minecraft:planks", 2},
                  {-19, 8, 52, "minecraft:air", 0}, {-18, 8, 51, "minecraft:air", 0},
                  {-20, 8, 51, "BiomesOPlenty:flowers2", 3}}
    if #seen ~= #want then return ("crew.read_looks: %d cells, not 5"):format(#seen) end
    for i, c in ipairs(want) do
        local s2 = seen[i]
        if s2[1] ~= c[1] or s2[2] ~= c[2] or s2[3] ~= c[3] or s2.name ~= c[4]
                or s2.meta ~= c[5] then
            return ("crew.read_looks: look %d is %s at %d,%d,%d"):format(i, s2.name, s2[1],
                                                                         s2[2], s2[3])
        end
    end

    -- the interface's lock (15-crew.md): taken when free, and a holder with no job holds nothing
    -- (a trip that died must not block the interface)
    local me = require("me")
    local flush = me.flush
    me.flush = function() end
    crew.me_owner = nil
    crew.lock_me("A")
    if crew.me_owner ~= "A" then return "the free lock not taken" end
    crew.jobs["A"] = nil
    crew.lock_me("B")                    -- A has no job: B takes it at once, no wait
    if crew.me_owner ~= "B" then return "a lock held by no job not let go" end
    crew.unlock_me("A")
    if crew.me_owner ~= "B" then return "the lock let go by one not holding it" end
    crew.unlock_me("B")
    if crew.me_owner then return "the lock not let go" end
    -- held by its own job, taken again at once: a give-back on the spot keeps it for the takes
    -- (let go between, another took it and could not pass the one on the spot, 2026-10-06)
    crew.jobs.A = {p = {id = "x"}}
    crew.lock_me("A")
    crew.lock_me("A")
    crew.jobs.A = nil
    if crew.me_owner ~= "A" then return "the lock not taken again by its holder" end
    crew.unlock_me("A")
    -- first come first served: C queued before D gets it first (Dalek_Sec starved, 2026-10-06)
    local vc2 = require("virt_composer")
    crew.jobs.H, crew.jobs.C, crew.jobs.D = {p = {id = "h"}}, {p = {id = "c"}}, {p = {id = "d"}}
    crew.lock_me("H")
    local order = {}
    for _, n in ipairs({"C", "D"}) do
        spawn(function()
            crew.lock_me(n)
            order[#order + 1] = n
            vc2.net_sleep_ms(50)
            crew.unlock_me(n)
        end)
        vc2.net_sleep_ms(20)
    end
    crew.unlock_me("H")
    for _ = 1, 60 do
        if #order == 2 then break end
        vc2.net_sleep_ms(100)
    end
    crew.jobs.H, crew.jobs.C, crew.jobs.D = nil, nil, nil
    if order[1] ~= "C" or order[2] ~= "D" then
        return "the lock not first come first served: " .. table.concat(order, ",")
    end
    me.flush = flush

    -- what a robot holds counts against a packet's bill: only the missing is taken (Pintsize
    -- flew to the interface for seeds and dirt she carried, 2026-10-06); tools never count
    local miss = crew.missing({["minecraft:dirt:0"] = 100, ["minecraft:wheat_seeds:0"] = 50,
                               ["minecraft:fence:0"] = 3},
                              {[2] = {name = "minecraft:dirt", meta = 0, count = 26},
                               [6] = {name = "minecraft:dirt", meta = 0, count = 44},
                               [8] = {name = "minecraft:wheat_seeds", meta = 0, count = 54},
                               [16] = {name = "TConstruct:mattock", meta = 1, count = 1}})
    if miss["minecraft:dirt:0"] ~= 30 or miss["minecraft:wheat_seeds:0"]
            or miss["minecraft:fence:0"] ~= 3 then
        return "the bill less what it holds is wrong"
    end

    -- done by the plan now made: an id the done list names but in a fresh plan has work left
    -- (a stand's tall grass in an old "dig -5 0 4", 2026-10-06); not in the plan, or finished
    -- since it was made, is done
    local saved = packets.result
    packets.result = {packets = {["dig 9 9 9"] = {id = "dig 9 9 9", cells = {"1,1,1"}}},
                      order = {"dig 9 9 9"}}
    crew.done["dig 9 9 9"], crew.done["dig 8 8 8"] = true, true
    if crew.is_done("dig 9 9 9") then return "an old id with work in the plan counted done" end
    if not crew.is_done("dig 8 8 8") then return "a packet not in the plan counted not done" end
    crew.plan_done["dig 9 9 9"] = true
    if not crew.is_done("dig 9 9 9") then return "a packet finished in this plan not done" end
    -- proven with nothing to do now (its cells left for the end): done, in every plan
    packets.result = {packets = {["dig 7 7 7"] = {id = "dig 7 7 7", cells = {"2,2,2"}, steps = {}}},
                      order = {"dig 7 7 7"}}
    if not crew.is_done("dig 7 7 7") then return "a packet with no steps not counted done" end
    packets.result = saved
    crew.done["dig 9 9 9"], crew.done["dig 8 8 8"] = nil, nil

    -- its tools the wrong way round - the pickaxe in its slot, the mattock in its hand (a
    -- program stopped mid-till, 2026-10-06): seen, so the trip puts them back; and the pickaxe
    -- is a tool, never given back
    if crew.swapped_tool({[16] = {name = "TConstruct:pickaxe"}, [2] = {name = "minecraft:dirt"}})
            ~= 16 then
        return "the pickaxe in a slot and no mattock not seen"
    end
    local both = {[16] = {name = "TConstruct:mattock"}, [3] = {name = "TConstruct:pickaxe"}}
    if crew.swapped_tool(both) then return "tools seen swapped with the mattock in a slot" end
    if not crew.tool("TConstruct:pickaxe") then return "the pickaxe not counted a tool" end

    -- a robot's way (`go`, crew.way) keeps off another robot standing in it: around it where
    -- there is room, no way where it blocks the only one (Cairol waited on Gunter, 2026-10-05).
    -- A stone floor; at y 1 a corridor along x at z 2, walled at z 1 and 3, open above.
    local rows = {}
    for y = 0, 3 do
        local zs = {}
        for z = 0, 15 do
            local xs = {}
            for x = 0, 15 do
                xs[#xs + 1] = (y == 0 or (y == 1 and (z == 1 or z == 3))) and "1" or "0"
            end
            zs[#zs + 1] = table.concat(xs, ",")
        end
        rows[#rows + 1] = ("layer %d %s"):format(y, table.concat(zs, ";"))
    end
    local f = assert(io.open("test_run/c0_0.txt", "wb"))
    f:write(table.concat({"# 3d-draw map 1", "box x 0 15 y 0 3 z 0 15",
        "palette 1 minecraft:stone 0 1.50 seen", table.concat(rows, "\n")}, "\n") .. "\n")
    f:close()
    vc.route_load("test_run", 0, 0, 0, 0, 0, 0, 0, "")
    require("route").loaded = true
    local other = {name = "Parked", linked = true, outbox = {},
                   sf = {id = "-", state = "idle", op = 1, pos = {5, 1, 2}, facing = "n"}}
    robots.order[#robots.order + 1] = other
    r.sf.pos, r.sf.facing = {2, 1, 2}, "e"
    local function through(path, cell)
        local x, y, z = 2, 1, 2
        local STEP = {["^"] = {0, 0, -1}, v = {0, 0, 1}, [">"] = {1, 0, 0}, ["<"] = {-1, 0, 0},
                      ["+"] = {0, 1, 0}, ["-"] = {0, -1, 0}}
        for ch, n in path:gmatch("([%^v<>%+%-])(%d*)") do
            for _ = 1, tonumber(n) or 1 do
                local d = STEP[ch]
                x, y, z = x + d[1], y + d[2], z + d[3]
                if x == cell[1] and y == cell[2] and z == cell[3] then return true end
            end
        end
        return false
    end
    local way = crew.way(r, {8, 1, 2})
    table.remove(robots.order)
    if way == "" then return "no way round a parked robot, over the corridor's walls" end
    if through(way, other.sf.pos) then return "the way runs through a parked robot: " .. way end
    if vc.route_get(5, 1, 2) ~= 1 then return "the parked robot's cell left walled in the grid" end
    -- walled in above too: the corridor is the only way, and the robot in it shuts it
    for x = 0, 15 do vc.route_set(x, 2, 2, 2) end
    robots.order[#robots.order + 1] = other
    way = crew.way(r, {8, 1, 2})
    table.remove(robots.order)
    if way ~= "" then return "a way through a parked robot in a closed corridor: " .. way end
    -- running, it is no block where it is now, only where its program ends; waiting, it is both
    -- (the user, 2026-10-05)
    other.sf.state, other.dest = "run", {12, 1, 8}
    robots.order[#robots.order + 1] = other
    way = crew.way(r, {8, 1, 2})
    other.dest = {5, 1, 2}
    other.sf.pos = {9, 1, 2}
    local to_its_end = crew.way(r, {8, 1, 2})
    other.sf.state, other.sf.pos, other.dest = "wait", {5, 1, 2}, {12, 1, 8}
    local by_waiting = crew.way(r, {8, 1, 2})
    table.remove(robots.order)
    if way == "" then return "a running robot's cell shut the way" end
    if to_its_end ~= "" then return "a way through where a running robot ends: " .. to_its_end end
    if by_waiting ~= "" then return "a way through a waiting robot: " .. by_waiting end
    -- the simulation likewise: where another simulated robot's program ends, while it runs
    local sim = require("sim")
    local saved = sim.robots
    local a, b = {name = "a"}, {name = "b", dest = {3, 4, 5}, m = {state = "run"}}
    sim.robots = {a, b}
    local avoid = sim.others_work(a)
    b.m.state = "done"
    local after = sim.others_work(a)
    sim.robots = saved
    if not avoid["3,4,5"] then return "the sim's ways not kept off a running robot's end" end
    if after["3,4,5"] then return "the sim kept off the end of a robot that has stopped" end

    robots.by[r.name] = nil
    table.remove(robots.order)
    return nil
end

return {run_test = run_test}
