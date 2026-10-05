--[[ The live crew (scripts/crew.lua) on a stand-in robot record: what a packet needs, as items,
-- every refusal 10-live.md and 11-me.md list - not proven, waits not done, the robot moving, its
-- slots unknown, a block that needs the robot turned, no room, the ME not linked - and a
-- packet's end writing its cells into built.txt and the done list, in world coordinates.
-- @date 2026-10-05 ]]

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
    crew.paths = {done = "test_run/crew-done.txt", built = "test_run/crew-built.txt"}
    for _, p in pairs(crew.paths) do io.open(p, "w"):close() end
    crew.done, crew.jobs = {}, {}
    view.anchor = view.anchor or {0, 0, 0}
    local a = view.anchor

    local place = {id = "place 9 0 9", kind = "place", cells = {"45,1,45", "46,1,45"}, waits = {},
                   steps = {{k = "45,1,45", act = "place", block = {"minecraft:planks", 1}},
                            {k = "46,1,45", act = "place", block = {"minecraft:planks", 1}}}}
    local dig = {id = "dig 9 0 9", kind = "dig", cells = {"45,0,45"}, waits = {},
                 steps = {{k = "45,0,45", act = "dig", block = {"minecraft:dirt", 0}}}}
    local later = {id = "place 9 1 9", kind = "place", cells = {}, waits = {["place 9 0 9"] = true},
                   steps = {}}
    local unproven = {id = "dig 8 0 8", kind = "dig", cells = {}, waits = {}, unproven = "walled"}
    local stairs = {id = "place 7 0 7", kind = "place", cells = {"35,1,35"}, waits = {},
                    steps = {{k = "35,1,35", act = "place",
                              block = {"minecraft:spruce_stairs", 3}}}}
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
    local built = lines_of(crew.paths.built)
    local first = ("%d %d %d minecraft:planks 1"):format(45 + a[1], 1 + a[2], 45 + a[3])
    if #built ~= 2 or built[1]:sub(1, #first) ~= first then
        return "built.txt after the place: " .. table.concat(built, " | ")
    end
    if not crew.done[place.id] or lines_of(crew.paths.done)[1] ~= place.id then
        return "the done list after the place"
    end
    r.sf.op = 1
    crew.finish(r, {p = dig, opstep = {[2] = 1}, t0 = 0}, "stop blocked")
    if #lines_of(crew.paths.built) ~= 2 or crew.done[dig.id] then
        return "a stop at op 1 wrote steps or marked the packet done"
    end
    robots.by[r.name] = nil
    table.remove(robots.order)
    return nil
end

return {run_test = run_test}
