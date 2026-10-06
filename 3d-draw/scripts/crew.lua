--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The plan's packets on the real robots, one robot and one packet at a time, by command
-- | (redesign/10-live.md; the user, 2026-10-05: "go ahead with steps 1 and 2").
-- |
-- |     crew.start(name, id)     the robot takes the proven packet `id` on a trip of its own
-- |                              (redesign/11-me.md): to the ME's interface, what it holds given
-- |                              back, what the packet places taken, the packet, back through
-- |                              the interface, home. True and what it set off on, or nil and why
-- |     crew.bill(p)             what a packet places (as items) and digs: {"name:meta" = n} each
-- |     crew.item(name, meta)    the item a placed block comes from: name, meta
-- |     crew.craft(name, item, n)  n of item crafted in one run at the interface (12-craft.md)
-- |     crew.short(name)         what the plan lacks in the ME, crafted in one run
-- |     crew.chain(list)         packets one after another, each trip to its end: {{robot, id}}
-- |     crew.resync(name)        its copy set where the robot is, the divergence cleared - once
-- |                              the user has looked at why
-- |     crew.report()            lines: the packets under way, those done, the last events
-- |     crew.paths               {done = data/crew-done.txt, world = data/world.txt}
-- |
-- | A packet ended `done`, its robot and copy agreeing, is done: its cells go into the
-- | pathfinder's grid and into world.txt, so the map knows them. A stop or a divergence assumes
-- | nothing: the robot stays, the steps it finished are written, the rest waits for the user.
-- | The robot takes only when told: the PC stocks the interface and waits for its tick.
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local spawn = require("spawn")         -- spawns that keep their handle
local robots = require("robots")
local copy = require("copy")
local route = require("route")
local view = require("view")
local packets = require("live")("packets")
local programs = require("live")("programs")
local me = require("me")

local crew = {jobs = {}, done = {}, log = {},
              paths = {done = "data/crew-done.txt", world = "data/world.txt"}}

-- A line in the crew's log, the last 12 kept; offered as crew.say to giveway.lua.
local function say(s)
    crew.log[#crew.log + 1] = s
    if #crew.log > 12 then table.remove(crew.log, 1) end
end
crew.say = say

local function unkey(k)
    local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
    return tonumber(x), tonumber(y), tonumber(z)
end

-- The packets done for real, from before this run of the program.
local function load_done()
    crew.done = {}
    local f = io.open(crew.paths.done, "r")
    if not f then return end
    for line in f:lines() do
        local id = line:match("^([^#].-)%s*$")
        if id and id ~= "" then crew.done[id] = true end
    end
    f:close()
end
load_done()
crew.load_done = load_done

-- Blocks whose way is set by how the robot faces as it places - not yet turned for (step 5 of
-- the way to a real build); a packet with one is not taken.
local TURNED = {"_stairs", "_door", "trapdoor", "torch", "ladder", "fenceGate", "FenceGate",
                "fence_gate", "lever", "button", "chest", "pumpkin", "furnace", "hay_block"}
-- A block whose way the robot cannot choose yet: one with no rule read (orient.lua, 14-turn.md).
local function turned(name, meta)
    if require("orient").has(name) then return false end
    if name:find("slab") and not name:find("double") then return meta & 8 ~= 0 end
    if name:find("log") then return meta & 12 ~= 0 end
    for _, t in ipairs(TURNED) do if name:find(t, 1, true) then return true end end
    return false
end

-- The item a placed block comes from: a stair, a door, a torch is one item whatever its way; a
-- slab's top half, a log's axis, leaves' decay bit fold back (11-me.md, "What the village needs").
-- What stacks to less than 64: a water bucket not at all - one take, one slot each (13-farm.md).
crew.STACK = {["minecraft:water_bucket:0"] = 1, ["minecraft:bucket:0"] = 16}

function crew.item(name, meta)
    -- wheat is planted as seeds; farmland is dirt, tilled (redesign/13-farm.md)
    if name == "minecraft:wheat" then return "minecraft:wheat_seeds", 0 end
    if name == "minecraft:farmland" then return "minecraft:dirt", 0 end
    if name == "minecraft:water" then return "minecraft:water_bucket", 0 end
    if name:find("slab") and not name:find("double") then return name, meta & 7 end
    if name:find("leaves") or name:find("log") then return name, meta & 3 end
    for _, t in ipairs(TURNED) do if name:find(t, 1, true) then return name, 0 end end
    return name, meta
end

function crew.bill(p)
    local place, dig = {}, {}
    for _, st in ipairs(p.steps or {}) do
        if not st.block then goto next_step end           -- a till: no item (13-farm.md)
        local name, meta = st.block[1], st.block[2]
        if st.act == "place" or st.act == "water" then name, meta = crew.item(name, meta) end
        local kk = name .. ":" .. tostring(meta)
        local t = (st.act == "place" or st.act == "water") and place or st.act == "dig" and dig
                  or nil
        if t then t[kk] = (t[kk] or 0) + 1 end
        ::next_step::
    end
    return place, dig
end

-- A robot that may be given a program now: standing still, its position its own and fresh.
local function still(r)
    if not r.linked or not r.sf then return false, "not linked" end
    if r.sf.state == "run" or r.sf.state == "wait" then
        return false, "still at work (" .. r.sf.state .. "): its position is not settled"
    end
    if #r.outbox > 0 then return false, "a command is still queued for it" end
    if r.diverged then return false, "its copy diverged: " .. r.diverged.why end
    if crew.jobs[r.name] then return false, "it is on " .. crew.jobs[r.name].p.id end
    -- halted aside for another, its own program stacked under (16-giveway.md): not free
    if (crew.gw or {})[r.name] or tostring(r.sf.id):find("^gw%d") then
        return false, "giving way to another robot"
    end
    if not r.slots then return false, "no full status yet: its slots are not known" end
    return true
end

-- The cells this robot's routes keep off: where every other linked robot stands, and the
-- packets other robots are working (redesign/09-paths.md).
-- A robot standing still is a block to the others' ways; one running is not where it is but
-- where its program ends (robots.run keeps `dest`); one waiting is both (the user, 2026-10-05: "a
-- standing still robot should be opaque for the path finder ... same for the final resting place
-- for a robot that runs").
local function robot_cells(o, a)
    local st, p = o.sf.state, o.sf.pos
    if st ~= "run" then a[p[1] .. "," .. p[2] .. "," .. p[3]] = true end
    local d = o.dest
    if d and (st == "run" or st == "wait") then a[d[1] .. "," .. d[2] .. "," .. d[3]] = true end
end
crew.robot_cells = robot_cells

local function avoid_for(r)
    local a = {}
    for _, o in ipairs(robots.order) do
        if o ~= r and o.linked and o.sf then robot_cells(o, a) end
    end
    for name, j in pairs(crew.jobs) do
        if name ~= r.name then
            for _, k in ipairs(j.p.cells) do a[k] = true end
            for _, st in ipairs(j.p.steps) do a[st.k] = true end
        end
    end
    return a
end

-- The steps a robot finished, into the grid, the copies' world and world.txt (world
-- coordinates), in order: a support put and taken away again ends as air, the last line for a
-- cell being the one read. The copies' world too: a copy that stopped short of its robot had
-- left the cells it did not dig standing there.
local function write_steps(steps, upto)
    if upto < 1 then return 0 end
    local a = view.anchor
    local plan = (packets.plans[packets.pick] or "plan"):match("([^/\\]+)$")
    local f = io.open(crew.paths.world, "a")
    local w = not vc.app_is_testing() and copy.world() or nil
    for i = 1, upto do
        local st = steps[i]
        local x, y, z = unkey(st.k)
        local name, meta = "minecraft:air", 0
        if st.act == "place" then name, meta = st.block[1], st.block[2] end
        if st.act == "till" then name, meta = "minecraft:farmland", 0 end
        if st.act == "water" then name, meta = "minecraft:water", 0 end
        local solid = st.act == "place" or st.act == "till" or st.act == "water"
        vc.route_set(x, y, z, solid and 2 or 1)
        if w then w:set(x, y, z, solid and {name, meta} or nil) end
        if f then
            f:write(("%d %d %d %s %d 1.0 built %s\n"):format(x + a[1], y + a[2], z + a[3], name,
                                                            meta, plan))
        end
        -- a door's upper half came with it (ItemDoor): written too, as the plan names it
        if st.act == "place" and require("orient").door(name) then
            local up = (packets.want or {})[x .. "," .. (y + 1) .. "," .. z]
            if up then
                vc.route_set(x, y + 1, z, 2)
                if w then w:set(x, y + 1, z, {up[1], up[2]}) end
                if f then
                    f:write(("%d %d %d %s %d 1.0 built %s\n"):format(x + a[1], y + 1 + a[2],
                            z + a[3], up[1], up[2], plan))
                end
            end
        end
    end
    if f then f:close() end
    return upto
end

-- The end of a robot's packet: done (all its steps), or stopped at an op (those before it).
local function finish(r, j, why)
    local upto = #j.p.steps
    if why then
        upto = 0
        -- only the packet's own program, sent, has done steps: one its dry run refused never
        -- ran, and the op the robot stopped at was its takes' - read as the packet's, a step
        -- never placed was written built, a visit at a time (place -3 0 0, 8 steps then 7 then
        -- 6, 2026-10-06)
        local ran = j.what == "the packet" and j.pid and r.sf and r.sf.id == j.pid
        -- the program's ops before the packet's own (to the interface, the takes) shift its count
        local stopped_at = ran and (r.sf.op - (j.op_offset or 0)) or 0
        for i = 1, stopped_at - 1 do
            if j.opstep[i] and j.opstep[i] > upto then upto = j.opstep[i] end
        end
    end
    write_steps(j.p.steps, upto)
    if why then
        say(("%s: %s NOT done, %d of %d steps: %s"):format(r.name, j.p.id, upto, #j.p.steps, why))
        return
    end
    crew.done[j.p.id] = true
    crew.is_done(j.p.id)                         -- the plan's done list made for this plan
    crew.plan_done[j.p.id] = true
    local f = io.open(crew.paths.done, "a")
    if f then f:write(j.p.id .. "\n"); f:close() end
    say(("%s: %s done, %d steps in %.0f s"):format(r.name, j.p.id, #j.p.steps,
                                                    vc.app_time() - j.t0))
end

-- The way from `from` to `to`, kept off the cells of `avoid` (as programs.make does): "" if none.
local function route_avoiding(from, facing, to, avoid)
    local marks = {}
    for k in pairs(avoid) do
        local x, y, z = unkey(k)
        if vc.route_get(x, y, z) == 1 and not (x == from[1] and y == from[2] and z == from[3]) then
            marks[#marks + 1] = {x, y, z}
            vc.route_set(x, y, z, 2)
        end
    end
    local path = route.find(from, facing, to)
    for _, m in ipairs(marks) do vc.route_set(m[1], m[2], m[3], 1) end
    return path
end

-- A robot's way from where it stands to `to`, kept off every other robot and the packets they
-- work: what a `go` sends too - a way through a parked robot left Cairol waiting on Gunter at
-- 0,-1,0 (2026-10-05). "" if none.
function crew.way(r, to)
    return route_avoiding(r.sf.pos, r.sf.facing, to, avoid_for(r))
end

-- A robot whose packet is done, back to its park: once it stands still, routed off the others,
-- dry-run, sent (10-live.md, "Then home").
local function go_home(r)
    for _ = 1, 30 do
        if still(r) and r.sf.state ~= "run" then break end
        vc.net_sleep_ms(1000)
    end
    local park = r.park
    if not park or crew.jobs[r.name] then return end
    local at = r.sf.pos
    if at[1] == park[1] and at[2] == park[2] and at[3] == park[3] then return end
    local path = route_avoiding(at, r.sf.facing, park, avoid_for(r))
    if path == "" then
        say(("%s: NO way home from %s - it waits where it is"):format(r.name,
                table.concat(at, " ")))
        return
    end
    local d, sent, pid = robots.run(r.name, "$0 " .. path)
    if sent then
        say(("%s: home to its park as %s, ~%.0f s"):format(r.name, pid, (d.ticks or 0) / 13))
    else
        say(("%s: the way home did not dry-run: %s %s"):format(r.name, tostring(d and d.state),
                tostring(d and d.why or "")))
    end
end

crew.finish = finish                    -- for the tests, and for a packet the user ends by hand
crew.go_home = go_home

local DIR_CH = {n = "^", s = "v", e = ">", w = "<"}
local TICK_MS = 1500        -- the interface's tick, waited after a config before any take

local function robot_named(name)
    local want = (name or ""):lower()
    for _, r in ipairs(robots.order) do
        if #want > 0 and r.name:lower():sub(1, #want) == want then return r end
    end
end

-- How many slots it has, from its full status (`slots <n>`, 11-me.md).
local function size_of(r)
    return tonumber(((r.status or {})[2] or ""):match("slots (%d+)"))
end

-- Its tools stay in it: the GregTech saw, once given, never comes out of the interface; the
-- mattock each robot was given to till farmland (the user, 2026-10-05).
-- Is packet `id` done, for the plan now made? The plan is made from the world as it is (every
-- step written to world.txt), so a packet in it has work left - even one the done list names: an
-- old id came back with new cells, a stand's tall grass in "dig -5 0 4", and was skipped
-- (2026-10-06). Done: not in the plan, or finished since the plan was made. crew.done stays the
-- record of what was done, by id.
function crew.is_done(id)
    local res = packets.result
    if not res then return crew.done[id] == true end
    if crew.plan_done_of ~= res then crew.plan_done, crew.plan_done_of = {}, res end
    if not res.packets[id] then return true end
    -- proven with nothing to do now (its cells left for the end): done for this plan - it came
    -- back in every plan, and the crew loop parked the robots that finished it (2026-10-06)
    local q = res.packets[id]
    if q.steps and #q.steps == 0 then return true end
    return crew.plan_done[id] == true
end

-- A robot's own tool, never given back: GregTech's metatools, the mattock, the pickaxe (each
-- builder carries a mattock and a pickaxe, the user, 2026-10-05).
local function tool(name)
    return name:find("gt.metatool", 1, true) ~= nil or name:find("mattock", 1, true) ~= nil
        or name:find("pickaxe", 1, true) ~= nil
end
crew.tool = tool

-- The bill less what the robot holds already (tools aside): only what is missing is taken at the
-- interface (the user, 2026-10-06: "she already had them though?" - Pintsize flew back for seeds
-- and dirt she carried). -> a new bill {"name:meta" = n}.
function crew.missing(bill, slots)
    local held = {}
    for _, it in pairs(slots or {}) do
        if not tool(it.name) then
            local kk = it.name .. ":" .. tostring(it.meta)
            held[kk] = (held[kk] or 0) + it.count
        end
    end
    local out = {}
    for kk, n in pairs(bill) do
        local left = n - math.min(n, held[kk] or 0)
        if left > 0 then out[kk] = left end
    end
    return out
end

-- Its tools the wrong way round: the pickaxe in a slot and no mattock in any, so the mattock is
-- in its hand (a program stopped mid-till, Pintsize, 2026-10-06) -> that slot, or nil. `e<slot>`
-- puts them back: the mattock into the slot, the pickaxe into the hand.
function crew.swapped_tool(slots)
    local pick
    for s, it in pairs(slots or {}) do
        if it.name:find("mattock", 1, true) then return nil end
        if it.name:find("pickaxe", 1, true) then pick = s end
    end
    return pick
end

-- The interface of station `st` (the first when nil) in the copies' world, as configured:
-- `stocked` {[slot] = {name, meta, count}}, every other slot free - what is given into it goes
-- to the network on the interface's tick. Each station its own container, so two robots take
-- at the two at once (17-stations.md). Its cell solid in the pathfinder's grid too: the second
-- interface was air there, and Cortana's way to its spot went through it (2026-10-06).
local function interface_in_copy(stocked, st)
    st = st or me.stations[1]
    local slots = {sink = {}}
    for s = 1, 9 do
        local it = stocked and stocked[s]
        if it then slots[s] = {name = it[1], meta = it[2], count = it[3]}
        elseif not st.stocked[s] then slots.sink[s] = true end
    end
    local c = st.INTERFACE
    copy.world():add_container(c[1], c[2], c[3], slots)
    if vc.route_get(c[1], c[2], c[3]) ~= 2 then vc.route_set(c[1], c[2], c[3], 2) end
end
crew.interface_in_copy = interface_in_copy

-- ---- the stations: two interfaces, a lock each (redesign/17-stations.md) ----------------------

-- Who holds a station's lock. The first's is crew.me_owner, as before there were two: a trip of
-- an older crew still running after a reload reads and writes that field. The others' is kept
-- on the station, in me.lua, which a crew reload does not replace.
local function owner(st)
    if st.n == 1 then return crew.me_owner end
    return st.owner
end
local function set_owner(st, name)
    if st.n == 1 then crew.me_owner = name else st.owner = name end
end

-- The station whose lock `name` holds, or nil.
function crew.holds_me(name)
    if not name then return nil end
    for _, st in ipairs(me.stations) do if owner(st) == name then return st end end
end

-- The station whose spot is the cell `p`, or nil: none may wait standing there.
function crew.spot_at(p)
    for _, st in ipairs(me.stations) do
        local s = st.SPOT
        if p and p[1] == s[1] and p[2] == s[2] and p[3] == s[3] then return st end
    end
end

-- Every station in use known to the map: its interface solid in the grid and a container in
-- the copies' world (nothing stocked), before any way to its spot is planned.
function crew.stations_in_map()
    local w = copy.world()
    for _, st in ipairs(me.open()) do
        local c = st.INTERFACE
        if not w.containers[c[1] .. "," .. c[2] .. "," .. c[3]] then
            interface_in_copy(nil, st)
        elseif vc.route_get(c[1], c[2], c[3]) ~= 2 then
            vc.route_set(c[1], c[2], c[3], 2)
        end
    end
end

--[[ The free station `name` may take now, or nil. Free: in use (me.open), held by no one or by
-- one with no job. Of the free ones, the nearest to where it stands first. It takes one when it
-- is the first in the queue of those who may take it: the first station anyone; the others
-- only a robot whose trip runs this crew (j.any, set by lock_me) - an older crew's trip after a
-- reload knows only the first. ]]
local function pick(name, q)
    local r = robots.by[name]
    local p = r and r.sf and r.sf.pos
    local free = {}
    for _, st in ipairs(me.open()) do
        local o = owner(st)
        if not o or o == name or not crew.jobs[o] then free[#free + 1] = st end
    end
    local function dist(st)
        if not p then return st.n end
        local s = st.SPOT
        return math.abs(p[1] - s[1]) + math.abs(p[2] - s[2]) + math.abs(p[3] - s[3]) + st.n / 10
    end
    table.sort(free, function(a, b) return dist(a) < dist(b) end)
    for _, st in ipairs(free) do
        for _, w in ipairs(q) do
            local j = crew.jobs[w]
            if st.n == 1 or (j and j.any) then
                if w == name then return st end
                break
            end
        end
    end
end
crew.pick_station = pick                                           -- for the tests

-- One program: dry-run, sent, and waited for until it ends. True when it ended `done` or `halt`
-- with its copy agreeing; else nil and why.
-- A robot stopped "blocked <name>" on a step learned it: the cell is the step's direction from
-- where it stands - not its facing (a step up or down keeps the facing; that misread put
-- Pintsize's leaf a cell off, 2026-10-05) - and the block goes into the grid, the copies' world
-- and data/world.txt, as the robot itself named it.
local function learn_block(r)
    local sf = r.sf
    local why = sf and tostring(sf.why) or ""
    local name = why:match("^blocked (%S+)") or why:match("^not%-expected (%S+)")
    local c = r.copy
    if not name or not c or not c.m.prog then return nil end
    local op = c.m.prog.ops[sf.op]
    if not op or not op.dir then return nil end
    local meta = 0
    local n2, m2 = name:match("^(.+):(%d+)$")
    if n2 and name:find(":.+:") then name, meta = n2, tonumber(m2) end
    if name == "air" then name = "minecraft:air" end
    local d = require("live")("machine").STEP_OF[op.dir]
    local x, y, z = sf.pos[1] + d[1], sf.pos[2] + d[2], sf.pos[3] + d[3]
    local air = name == "minecraft:air"
    vc.route_set(x, y, z, air and 1 or 2)
    copy.world():set(x, y, z, (not air) and {name, meta} or nil)
    local a = view.anchor
    local f = io.open(crew.paths.world, "a")
    if f then
        f:write(("%d %d %d %s %d 1.0 analyzed %s stopped, its op %s from %d %d %d\n")
                :format(x + a[1], y + a[2], z + a[3], name, meta, r.name, op.dir, sf.pos[1],
                        sf.pos[2], sf.pos[3]))
        f:close()
    end
    crew.last_learned = {robot = r.name, cell = {x, y, z}, name = name}
    say(("%s learned %s at %d,%d,%d"):format(r.name, name, x, y, z))
    return true
end

-- After a stop that taught a cell: the robot looks all round (a program of six looks, read-only)
-- and what it names goes into the map too - a crown mapped wrong is learned a patch at a time,
-- not a leaf a bump (Pintsize in the crown over the field, 2026-10-05).
-- Whether a robot's full status carries the six looks' results of its program `pid`.
function crew.looks_arrived(status, pid)
    status = status or {}
    if not (status[1] or ""):find("^" .. pid .. " ") then return false end
    for _, line in ipairs(status) do if line:find("^res 6 ") then return true end end
    return false
end

local LOOKS = {{"^", "n"}, {"v", "s"}, {">", "e"}, {"<", "w"}, {"+", "u"}, {"-", "d"}}
local function look_around(r)
    local d, sent, pid = robots.run(r.name, "$0 l^ lv l> l< l+ l-")
    if not sent then return nil end
    -- until the full status carries the six looks' results of this program - a fixed 1.5 s had
    -- read the status before them, every look learning nothing (2026-10-06); 30 s at most
    for _ = 1, 60 do
        if crew.looks_arrived(r.status, pid) then break end
        vc.net_sleep_ms(500)
    end
    local a, w = view.anchor, copy.world()
    local step = require("live")("machine").STEP_OF
    local f = io.open(crew.paths.world, "a")
    local n = 0
    for _, line in ipairs(r.status or {}) do
        local i, what = line:match("^res (%d+) l%S (%S+)$")
        local look = i and LOOKS[tonumber(i)]
        if look then
            local dd = step[look[2]]
            local x, y, z = r.sf.pos[1] + dd[1], r.sf.pos[2] + dd[2], r.sf.pos[3] + dd[3]
            local name, meta = what:match("^(.+):(%d+)$")
            if what == "air" then name, meta = "minecraft:air", 0 end
            if name and not name:find("OpenComputers:robot", 1, true) then
                local air = name == "minecraft:air"
                vc.route_set(x, y, z, air and 1 or 2)
                w:set(x, y, z, (not air) and {name, tonumber(meta)} or nil)
                if f then
                    f:write(("%d %d %d %s %s 1.0 analyzed %s looked from %d %d %d" .. "\n")
                            :format(x + a[1], y + a[2], z + a[3], name, meta, r.name,
                                    r.sf.pos[1], r.sf.pos[2], r.sf.pos[3]))
                end
                n = n + 1
            end
        end
    end
    if f then f:close() end
    say(("%s looked round at %s: %d cells into the map"):format(r.name,
            table.concat(r.sf.pos, " "), n))
    return n
end

--[[ The robot's slots read again, now: a `status` of its own, its `inv` line into r.slots. The
-- poll reads them only after a program it saw running, and only after the leg had already seen
-- the end: a program over between two polls left them unread, and the next leg was planned on
-- the old slots - the packet's takes not in them ("nothing selected", Cortana and Dalek_Sec at
-- place -3 0 0), a take into a slot that had filled ("took 0 of 3", Baymax at place -3 0 1), an
-- item counted held that was used up ("no slot left", Baymax at place -3 0 4), 2026-10-06.
-- -> true, or nil when no answer came in 15 s. ]]
local function read_slots(r)
    local t = robots.send(r.name, "status")
    for _ = 1, 150 do
        if t.head then break end
        vc.net_sleep_ms(100)
    end
    local lines = type(t.lines) == "table" and t.lines or {}
    if not (lines[3] or ""):find("^inv") then return nil end
    r.status = lines
    copy.inventory(r, lines[3]:gsub("^inv ?", ""))
    return true
end
crew.read_slots = read_slots

--[[ One program: dry-run, sent, and waited for until it ends. -> true when it ended done or
-- halt with its copy agreeing; else nil and why. With `remake` (a function giving the program
-- anew, its way planned again, or nil), a dry run that met a robot is tried again, 3 s apart,
-- LEG_RETRIES times, before it is given up: the hop to the spot and the takes, refused "wait
-- robot" by the robots by the station, had sent the robot to the back of the queue - 26
-- packets started, 4 finished, Cortana ~30 min waiting (2026-10-06). ]]
local LEG_RETRIES = 10
crew.LEG_RETRY_MS = 3000
local function leg(r, j, text, what, remake)
    -- the robot's last program ended first: one still on its way or running would be replaced
    -- part way (robots.run refuses it, "busy"), so the leg waits for it, a minute at most; the
    -- text was planned from where it stood - moved meanwhile, only a remake plans it again
    local p0 = r.sf and r.sf.pos and table.concat(r.sf.pos, " ")
    local d, sent, pid = robots.run(r.name, text)
    for _ = 1, 60 do
        if sent or not (d and d.state == "busy") then break end
        vc.net_sleep_ms(1000)
        local here = r.sf and r.sf.pos and table.concat(r.sf.pos, " ")
        if here ~= p0 and not remake then
            return nil, ("%s did not dry-run: busy, and it moved meanwhile"):format(what)
        end
        text = remake and remake() or text
        d, sent, pid = robots.run(r.name, text)
    end
    local tries = 0
    while not sent and remake and tries < LEG_RETRIES and d and d.state == "wait"
            and tostring(d.why):find("robot", 1, true) do
        tries = tries + 1
        vc.net_sleep_ms(crew.LEG_RETRY_MS)
        text = remake() or text
        d, sent, pid = robots.run(r.name, text)
    end
    if not sent then
        return nil, ("%s did not dry-run: %s %s"):format(what, tostring(d and d.state),
                                                         tostring(d and d.why or ""))
    end
    j.pid, j.what = pid, what
    local sent_at = vc.app_time()
    while true do
        vc.net_sleep_ms(1000)
        if not r.linked then return nil, what .. ": its link is gone" end
        local sf = r.sf
        -- its machine began again (a relink restarted its zone): the program is gone, not late
        if sf and sf.id == "-" and sf.state == "idle" and vc.app_time() - sent_at > 10 then
            return nil, what .. ": its machine restarted, the program lost"
        end
        -- stopped in a give-way stacked over its program (16-giveway.md): its program will not
        -- go on by itself, so the leg ends here, as at any stop
        if sf and sf.state == "stop" and tostring(sf.id):find("^gw%d") then
            return nil, ("%s: stopped giving way: %s"):format(what, tostring(sf.why))
        end
        if sf and sf.id == pid then
            if sf.state == "stop" then learn_block(r) end
            -- what the state means, by crewfix.leg (swapped by `reload crewfix`): done, only a
            -- slot count apart at its end (resync: the robot is the truth), still at work - a
            -- slot count apart is waited out too - diverged, or stopped
            local k = require("live")("crewfix").leg(sf.state, r.diverged and r.diverged.why)
            -- at its end its slots read again, so what follows is planned on them (read_slots)
            if k == "resync" then
                crew.resync(r.name)
                if not read_slots(r) then vc.net_sleep_ms(1500) end
                return true
            end
            if k == "diverged" then
                return nil, what .. ": its copy diverged: " .. r.diverged.why
            end
            if k == "done" then
                if not read_slots(r) then vc.net_sleep_ms(1500) end
                return true
            end
            if k == "stop" then return nil, what .. ": stop " .. tostring(sf.why) end
        end
    end
end

crew.leg = leg                                                     -- for the tests

-- The way to station st's spot (the first when nil) and the turn to face its interface, as
-- program text (" f>" when there), or nil. Kept off the others as every way is, and off the
-- cells their copies stand in too: the dry run is made in the copies' world, and a copy lagging
-- its robot by the station refused the hop "wait robot" (2026-10-06).
local function to_spot(r, from, facing, st)
    st = st or me.stations[1]
    local at = st.SPOT
    local path = ""
    if not (from[1] == at[1] and from[2] == at[2] and from[3] == at[3]) then
        local avoid = avoid_for(r)
        for _, o in ipairs(robots.order) do
            local b = o ~= r and o.linked and o.copy and o.copy.b
            if b then avoid[b.x .. "," .. b.y .. "," .. b.z] = true end
        end
        path = route_avoiding(from, facing, at, avoid)
        if path == "" then return nil end
    end
    return path .. " f" .. DIR_CH[st.FACE]
end
crew.to_spot = to_spot                                             -- for the tests

local function holds_more_than_tools(r)
    for _, it in pairs(r.slots or {}) do if not tool(it.name) then return true end end
    return false
end

-- To the interface and everything but its tools given back, in rounds: a stack into each free
-- slot of the interface, a halt, the tick that empties them, the next round; the last round ends
-- with `tail` (a halt, or the way home). Pintsize came with 15 stacks from the harbour, and one
-- round of 9 had refused her (2026-10-05). At station st (the first when nil), whose lock it
-- holds. -> true | nil, why
local function give_back_rounds(r, j, tail, st)
    st = st or me.stations[1]
    local go = to_spot(r, r.sf.pos, r.sf.facing, st)
    if not go then return nil, "no way to the interface" end
    me.flush(st)                             -- the slots let go of, free for what it gives
    local held = {}                          -- what it holds, counted down round by round
    for slot, it in pairs(r.slots or {}) do
        if not tool(it.name) then held[slot] = it end
    end
    local round = 0
    while true do
        vc.net_sleep_ms(TICK_MS)             -- cleared slots, and the last round's, empty
        interface_in_copy(nil, st)
        local free = {}
        for s = 1, 9 do if not st.stocked[s] then free[#free + 1] = s end end
        local mine = {}
        for slot in pairs(held) do mine[#mine + 1] = slot end
        table.sort(mine)
        local ops, back = {}, {}
        for i, slot in ipairs(mine) do
            if i > #free then break end
            local it = held[slot]
            ops[#ops + 1] = ("g%s%d.%d"):format(DIR_CH[st.FACE], slot, free[i])
            local kk = it.name .. ":" .. it.meta
            back[kk] = (back[kk] or 0) + it.count
            held[slot] = nil
        end
        local last = next(held) == nil
        round = round + 1
        local function text_of(g)
            return ("$0 %s %s %s"):format(g, table.concat(ops, " "), last and tail or "h")
        end
        -- the first round's hop planned again if its dry run met a robot (leg)
        local remake = go ~= "" and function()
            go = to_spot(r, r.sf.pos, r.sf.facing, st) or go
            return text_of(go)
        end or nil
        local ok, why = leg(r, j, text_of(go), "giving back, round " .. round, remake)
        if not ok then return nil, why end
        for kk, n in pairs(back) do me.moved(kk, n) end
        go = ""
        if last then return true end
    end
end

-- The packet's items in rounds of at most 8 stacks (the interface's slots 1-8), each round its
-- own config and takes, the robot slots they go to: {{cfg, stocked, ops, at}, ...}. The takes
-- face station st's interface (the first when nil).
local function rounds_for(r, j, st)
    local face = (st or me.stations[1]).FACE
    local free = {}
    for slot = 1, size_of(r) do
        if not (r.slots or {})[slot] then free[#free + 1] = slot end   -- empty slots only
    end
    local kinds = {}
    for kk in pairs(j.place) do kinds[#kinds + 1] = kk end
    table.sort(kinds)
    local stacks = {}
    for _, kk in ipairs(kinds) do
        local name, meta = kk:match("^(.+):(%d+)$")
        local n, most = j.place[kk], crew.STACK[kk] or 64
        while n > 0 do
            stacks[#stacks + 1] = {kk = kk, name = name, meta = tonumber(meta),
                                   k = math.min(most, n)}
            n = n - most
        end
    end
    local rounds, cur = {}, nil
    for _, st in ipairs(stacks) do
        if not cur or #cur.ops == #me.STOCK then
            cur = {cfg = {}, stocked = {}, ops = {}, at = {}}
            rounds[#rounds + 1] = cur
        end
        local islot = #cur.ops + 1
        local rs = table.remove(free, 1)
        if not rs then return nil, "no free slot left for " .. st.kk end
        cur.cfg[islot] = {st.name, st.meta, st.k}
        cur.stocked[islot] = {st.name, st.meta, st.k}
        cur.ops[#cur.ops + 1] = ("t%s%d.%d*%d"):format(DIR_CH[face], islot, rs, st.k)
        cur.at[#cur.at + 1] = {kk = st.kk, name = st.name, meta = st.meta, rs = rs, k = st.k}
    end
    return rounds
end
crew.rounds_for = rounds_for                                       -- for the tests

-- The packet's program, from `pos`/`facing`, each put from the slot its kind was taken into.
local function packet_text(r, j, pos, facing, at)
    local left = {}
    local function slot_of(nm, meta)
        local iname, imeta = crew.item(nm, meta)
        if at then
            for _, a in ipairs(at) do
                if a.name == iname and a.meta == imeta then
                    left[a.rs] = left[a.rs] or a.k
                    if left[a.rs] > 0 then left[a.rs] = left[a.rs] - 1; return a.rs end
                end
            end
        end
        -- what it held already (crew.missing left it out of the takes)
        for s, it in pairs(r.slots) do
            if it.name == iname and it.meta == imeta then
                left[s] = left[s] or it.count
                if left[s] > 0 then left[s] = left[s] - 1; return s end
            end
        end
    end
    local mattock
    for s, it in pairs(r.slots or {}) do
        if it.name:find("mattock", 1, true) then mattock = s end
    end
    local text, a2, _, opstep = programs.make(j.p, {pos = pos, facing = facing,
                                                    slot_of = slot_of, avoid = avoid_for(r),
                                                    tool_slot = mattock},
                                              {want = packets.want})
    if not text then return nil, "no program: " .. tostring(a2) end
    return text, opstep
end

-- "$0 {palette} ops" with `before` put in front of its ops: the header kept first.
local function prefixed(text, before)
    if not before or before == "" then return text, 0 end
    local head, rest = text:match("^(%$%S+%s*{[^}]*})%s*(.*)$")
    if not head then head, rest = text:match("^(%$%S+)%s*(.*)$") end
    local n = #require("machine").parse("$0 " .. before).ops
    return head .. " " .. before .. " " .. rest, n
end

-- The whole trip, on a coroutine of its own (11-me.md): what it holds given back first, the
-- packet's items stocked (one request), one exec - to the interface, the takes, the packet - the
-- slots let go, then back through the interface with what it dug, and home.
-- An ME interface holds one robot's stock at a time (15-crew.md): a lock, held from the first
-- config of a robot's takes to its last take, and for its give-back rounds. Two interfaces, two
-- locks (17-stations.md; the user, 2026-10-06: "Two locks, either one"): a robot waits for
-- either and takes the first free. Waited for where the robot stands, never on a spot.
-- One queue for both, first come first served: whoever polled first after a release took it,
-- and the robots parked by the station kept winning - Dalek_Sec waited across the village 7 min
-- (2026-10-06, the user: "how long did it stay still?"). A waiter whose job is gone leaves the
-- queue; a holder takes its own station again at once; a holder with no job holds nothing.
-- -> the station it holds (me.stations).
function crew.lock_me(name)
    crew.me_queue = crew.me_queue or {}
    local q = crew.me_queue
    if crew.jobs[name] then crew.jobs[name].any = true end      -- this crew's trip: either one
    pcall(crew.stations_in_map)
    local got = crew.holds_me(name)
    local queued = false
    for _, n in ipairs(q) do if n == name then queued = true end end
    if not queued and not got then q[#q + 1] = name end
    while not got do
        for i = #q, 1, -1 do
            if q[i] ~= name and not crew.jobs[q[i]] then table.remove(q, i) end
        end
        got = crew.holds_me(name) or pick(name, q)
        if not got then vc.net_sleep_ms(500) end
    end
    for i = #q, 1, -1 do if q[i] == name then table.remove(q, i) end end
    set_owner(got, name)
    -- moved aside for another while it waited (16-giveway.md): that move seen ended first
    require("live")("giveway").settle(name)
    return got
end
-- Let go: its station's slots flushed, the lock handed to the first still waiting (its job
-- alive) who may take it, so no poll can take it out of turn.
function crew.unlock_me(name)
    local st = crew.holds_me(name)
    if not st then return end
    me.flush(st)                                      -- its slots let go of, for the next one
    set_owner(st, nil)
    local q = crew.me_queue or {}
    while q[1] and not crew.jobs[q[1]] do table.remove(q, 1) end
    for i, w in ipairs(q) do
        if crew.jobs[w] and (st.n == 1 or crew.jobs[w].any) then
            set_owner(st, table.remove(q, i))
            break
        end
    end
end

-- Close enough to an interface to take a lock: within 6 cells of a spot in use.
local function near_station(r)
    local p = r.sf.pos
    for _, st in ipairs(me.open()) do
        local sp = st.SPOT
        if math.abs(p[1] - sp[1]) + math.abs(p[2] - sp[2]) + math.abs(p[3] - sp[3]) <= 6 then
            return true
        end
    end
    return false
end

-- To its park by the station before it waits for an interface's lock, without the lock: the
-- lock is held only for the hop to the spot and what it does there, not for a flight across
-- the village (15-crew.md; Dalek_Sec held it from -29 6 30, 2026-10-06); and none waits for it
-- standing on a spot - any station's - where it shuts the station to the one holding it.
-- -> true | nil, why
local function to_park_first(r, j)
    local on = crew.spot_at(r.sf.pos)
    if near_station(r) and not (on and owner(on) ~= r.name) then return true end
    j.phase = "to the station"
    local path = route_avoiding(r.sf.pos, r.sf.facing, r.park, avoid_for(r))
    if path == "" or path == "." then return true end
    return leg(r, j, "$0 " .. path, "to the station")
end

local function trip(r, j)
    local function fail(why, in_packet)
        -- its own program still at work (a leg given up on a copy diverged, the robot going on):
        -- the interface kept until it ends, two minutes at most - let go under it, the next
        -- robot's stock went in while it still took (Baymax "took 5 of 9", 2026-10-06)
        for _ = 1, 120 do
            local sf = r.sf
            if not (sf and j.pid and sf.id == j.pid and (sf.state == "run"
                                                          or sf.state == "wait")) then
                break
            end
            vc.net_sleep_ms(1000)
        end
        if j.stocked then
            local s = {}
            for slot in pairs(j.stocked) do s[#s + 1] = slot end
            me.later_clear(s, j.st)
            me.flush(j.st)
        end
        crew.unlock_me(r.name)
        if in_packet then finish(r, j, why) else
            say(("%s: %s NOT started: %s"):format(r.name, j.p.id, why))
        end
        crew.jobs[r.name] = nil
        packets.finish(j.p.id)
        -- never left on an interface's spot: it closes the station to every other robot
        -- (Baymax, his packet failed after its takes, 2026-10-06)
        local p0 = r.sf and r.sf.pos
        if p0 and crew.spot_at(p0) and r.sf.state ~= "run" then
            local path = route_avoiding(p0, r.sf.facing, r.park, avoid_for(r))
            if path ~= "" and path ~= "." then robots.run(r.name, "$0 " .. path) end
        end
    end
    -- its tools the wrong way round: put back first, or it cannot till nor give back safely
    local swapped = crew.swapped_tool(r.slots)
    if swapped then
        j.phase = "putting its tools back"
        local ok, why = leg(r, j, "$0 e" .. swapped, "its tools put back")
        if not ok then return fail(why, false) end
        vc.net_sleep_ms(1500)                          -- its full status, the mattock in its slot
    end
    -- what it carries from before, given back first - only when it has not the room for this
    -- packet's takes and digs (in a chain it comes straight from the last packet, 10-live.md)
    local empty = 0
    for slot = 1, size_of(r) do if not (r.slots or {})[slot] then empty = empty + 1 end end
    if holds_more_than_tools(r) and empty < j.stacks then
        local ok0, why0 = to_park_first(r, j)
        if not ok0 then return fail(why0, false) end
        j.phase = "waiting for the interface"
        j.st = crew.lock_me(r.name)
        j.phase = "giving back what it held"
        local ok, why = give_back_rounds(r, j, "h", j.st)
        if not ok then return fail(why, false) end
        -- the lock kept: it stands on the spot for its takes - let go here, another took it
        -- and could not reach the spot past it, both waiting (Baymax and Cortana, 2026-10-06)
        vc.net_sleep_ms(1500)                          -- its full status, the slots now empty
    end
    -- what it holds counts: only the missing items are taken; none missing, no interface. The
    -- whole bill kept (j.bill): the missing is counted again on the slots read at the station
    j.bill = j.bill or j.place
    j.place = crew.missing(j.bill, r.slots)
    -- the packet's items, in rounds of 8 stacks: each stocked (one request), the tick let pass,
    -- the takes, the robot halting at the interface after each - all under the interface's
    -- lock, let go before the packet, which runs from there (15-crew.md)
    local before, at = "", nil
    if next(j.place) then
        local rounds, why0 = rounds_for(r, j)
        if not rounds then return fail(why0, false) end
        -- to its park by the station first, without the lock (to_park_first)
        local ok0, why1 = to_park_first(r, j)
        if not ok0 then return fail(why1, false) end
        j.phase = "waiting for the interface"
        local st = crew.lock_me(r.name)
        j.st = st
        -- its slots read again under the lock, and the missing and the rounds made on them,
        -- facing the station it got: the slots counted at the start had changed since ("took
        -- 0 of 3", 2026-10-06)
        if read_slots(r) then j.place = crew.missing(j.bill, r.slots) end
        rounds, why0 = rounds_for(r, j, st)
        if not rounds then return fail(why0, false) end
        -- the one before it may still stand on the spot, its packet just sent: its way there
        -- tried again for half a minute (the crew's "no way to the interface", 2026-10-06)
        local go
        for _ = 1, 15 do
            go = to_spot(r, r.sf.pos, r.sf.facing, st)
            if go then break end
            vc.net_sleep_ms(2000)
        end
        if not go then
            -- said with what stood in the way: the spot's robot and the copies by it
            local by = {}
            for _, o in ipairs(robots.order) do
                local b = o ~= r and o.copy and o.copy.b
                if b and math.abs(b.x - st.SPOT[1]) + math.abs(b.y - st.SPOT[2])
                        + math.abs(b.z - st.SPOT[3]) <= 2 then
                    by[#by + 1] = ("%s %d,%d,%d"):format(o.name, b.x, b.y, b.z)
                end
            end
            return fail(("no way to the interface (station %d, from %s; by it: %s)"):format(
                st.n or 1, table.concat(r.sf.pos, ","), table.concat(by, ", ")), false)
        end
        at = {}
        for i, rd in ipairs(rounds) do
            j.phase = ("taking, round %d of %d"):format(i, #rounds)
            if j.stocked then
                local s = {}
                for slot in pairs(j.stocked) do s[#s + 1] = slot end
                me.later_clear(s, st)
            end
            local ok, why = me.config(rd.cfg, st)
            if not ok then return fail("the ME's computer: " .. tostring(why), false) end
            j.stocked = rd.stocked
            interface_in_copy(rd.stocked, st)
            -- a slot (re)configured fills on the interface's next tick: a robot one step away
            -- took 0 of 14 (Gunter, 2026-10-05) - the exe lets the tick pass before the takes
            vc.net_sleep_ms(TICK_MS)
            for _, a in ipairs(rd.at) do at[#at + 1] = a end
            local function text_of(g)
                return "$0 " .. g .. " " .. table.concat(rd.ops, " ") .. " h"
            end
            -- the hop planned again if its dry run met a robot, under the lock (leg)
            local remake = go ~= "" and function()
                go = to_spot(r, r.sf.pos, r.sf.facing, st) or go
                return text_of(go)
            end or nil
            ok, why = leg(r, j, text_of(go), "taking, round " .. i, remake)
            if not ok then return fail(why, false) end
            for _, a in ipairs(rd.at) do me.moved(a.kk, -a.k) end
            go = ""
            -- it took at the first station what was stocked there, still configured: the
            -- two interfaces told apart by it, once (me.learn, 17-stations.md)
            if st.n == 1 and me.wants_learning() then
                local okl, note = me.learn()
                say("the ME: " .. tostring(note))
                if okl then pcall(crew.stations_in_map) end
            end
        end
        if j.stocked then
            local s = {}
            for slot in pairs(j.stocked) do s[#s + 1] = slot end
            me.later_clear(s, st)
            j.stocked = nil
        end
        crew.unlock_me(r.name)
    end
    crew.unlock_me(r.name)                             -- held from a give-back with no takes
    local took = next(j.place) and j.st                -- the packet runs from its spot
    local from = took and {took.SPOT[1], took.SPOT[2], took.SPOT[3]}
            or {r.sf.pos[1], r.sf.pos[2], r.sf.pos[3]}
    local text, opstep = packet_text(r, j, from, took and took.FACE or r.sf.facing, at)
    if not text then return fail(opstep, false) end
    local full, offset = prefixed(text, before)
    j.opstep, j.op_offset = opstep, offset
    j.phase = "the packet"
    local ok, why = leg(r, j, full, "the packet")
    if not ok then return fail(why, true) end
    finish(r, j, nil)
    if j.chained then
        -- another packet follows: no home, no interface now - the next trip goes there itself
        -- if it needs to (10-live.md, "Then home - only when nothing follows")
        crew.jobs[r.name] = nil
        packets.finish(j.p.id)
        return
    end
    -- back through the interface with what it dug and what is left, then home
    j.phase = "giving back"
    vc.net_sleep_ms(1500)                              -- its full status: what it holds now
    j.phase = "waiting for the interface"
    local st = crew.lock_me(r.name)
    j.st = st
    j.phase = "giving back"
    local home = route_avoiding(st.SPOT, st.FACE, r.park, avoid_for(r))
    ok, why = give_back_rounds(r, j, home, st)
    crew.unlock_me(r.name)
    crew.jobs[r.name] = nil
    packets.finish(j.p.id)
    if not ok then
        say(("%s: after %s, giving back: %s - it stays"):format(r.name, j.p.id, why))
        return
    end
    say(("%s: %s's trip ends at its park, %.0f s"):format(r.name, j.p.id, vc.app_time() - j.t0))
end

-- A trip in a coroutine of its own, an error in it said and its job let go. Its handle kept
-- (spawn.lua): three trips that never began, their robots "setting off" for minutes, were
-- coroutines collected before they ran (2026-10-06) - the restart of them that stood here, a
-- workaround over that, is gone with its cause.
function crew.spawn_trip(r, j)
    spawn(function()
        local ok, e = xpcall(trip, debug.traceback, r, j)
        if not ok then
            say(("%s: its trip on %s broke: %s"):format(r.name, j.p.id, tostring(e)))
            crew.unlock_me(r.name)
            if crew.jobs[r.name] == j then crew.jobs[r.name] = nil end
            packets.finish(j.p.id)
        end
    end)
end

function crew.start(name, id, chained, also)
    local r = robot_named(name)
    if not r then return nil, "no robot " .. tostring(name) end
    local res = packets.result
    if not res then return nil, "no plan: plan it first" end
    local p = res.packets[id]
    if not p then return nil, "no packet " .. tostring(id) end
    if not p.steps then return nil, id .. " is not proven: " .. tostring(p.unproven) end
    if crew.is_done(id) then return nil, id .. " is done already" end
    for w in pairs(p.waits) do
        if not crew.is_done(w) then return nil, id .. " waits on " .. w .. ", not done" end
    end
    for other, jo in pairs(crew.jobs) do
        if jo.p.id == id then return nil, id .. " is " .. other .. "'s" end
        if other ~= r.name and not crew.parallel then
            return nil, other .. " is on a trip: one robot at the interface at a time"
        end
    end
    if require("sim").on then
        return nil, "the simulation is on: it holds the grid the robots route on - "
                .. "`sim clear` first"
    end
    local ok, why = still(r)
    if not ok then return nil, r.name .. ": " .. why end
    local size = size_of(r)
    if not size then return nil, r.name .. " runs an older machine (no slot count): relink it" end
    for _, st in ipairs(p.steps) do
        if st.act == "place" and turned(st.block[1], st.block[2]) then
            return nil, ("%s places %s:%d, whose way needs the robot turned - not yet (step 5)")
                    :format(id, st.block[1], st.block[2])
        end
    end
    -- what it places, from the exe's view of the ME; room for that and for what it digs - and
    -- for the packets `also` it will do next, their items taken in the same visit (15-crew.md)
    local place, dig = crew.bill(p)
    for _, aid in ipairs(also or {}) do
        local q = res.packets[aid]
        if q then
            local pl, dg = crew.bill(q)
            for kk, n in pairs(pl) do place[kk] = (place[kk] or 0) + n end
            for kk, n in pairs(dg) do dig[kk] = (dig[kk] or 0) + n end
        end
    end
    local stacks, tools = 0, 0
    for _, n in pairs(place) do stacks = stacks + (n + 63) // 64 end
    for _, n in pairs(dig) do stacks = stacks + (n + 63) // 64 end
    for _, it in pairs(r.slots) do if tool(it.name) then tools = tools + 1 end end
    if stacks > size - tools then
        return nil, ("%s needs %d slots, %s has %d free of tools"):format(id, stacks, r.name,
                                                                         size - tools)
    end
    if next(place) then
        if not me.conn then
            return nil, "the ME is " .. me.phase .. ": `lua require('me').link()`"
        end
        if not me.view and not me.items() then return nil, "the ME could not be read" end
        local short = {}
        for kk, n in pairs(place) do
            if (me.view[kk] or 0) < n then
                short[#short + 1] = ("%s x%d (ME %d)"):format(kk, n, me.view[kk] or 0)
            end
        end
        table.sort(short)
        if #short > 0 then return nil, "the ME is short: " .. table.concat(short, ", ") end
    end
    local j = {p = p, place = place, phase = "setting off", t0 = vc.app_time(),
               stacks = stacks, chained = chained}
    crew.jobs[r.name] = j
    packets.activate(id)
    crew.spawn_trip(r, j)
    say(("%s sets off on %s"):format(r.name, id))
    return true, ("%s sets off on %s: %d steps, %d stacks to take"):format(r.name, id, #p.steps,
            (function() local n = 0 for _, k in pairs(place) do n = n + (k + 63) // 64 end
                        return n end)())
end

-- ---- crafting (redesign/12-craft.md) -----------------------------------------------------------

local recipes = require("recipes")
local OUT = {8, 12, 13, 14, 15, 16}          -- Gunter's storage slots, where what he makes goes

-- The storage slots a run crafts into: OUT's and on past 16 to the robot's last slot, the
-- empty ones only, six at most - a craft into a slot holding another item makes nothing, in
-- the game (OC's craft counts what grew in the selected slot) and in the copy: Gunter's mattock
-- in slot 8 stopped every craft, "nothing-crafted" (the gate, 2026-10-06). And what holds a
-- grid cell, which no give-back clears (a tool): named. -> outs | nil, why
function crew.out_slots(slots, size)
    for _, s in ipairs(recipes.GRID) do
        if slots[s] then
            return nil, ("%s:%d in grid slot %d: the grid must be empty"):format(slots[s].name,
                    slots[s].meta, s)
        end
    end
    local outs = {}
    local all = {table.unpack(OUT)}
    for s = 17, size or 16 do all[#all + 1] = s end
    for _, s in ipairs(all) do
        if not slots[s] and #outs < #OUT then outs[#outs + 1] = s end
    end
    if #outs == 0 then return nil, "no empty storage slot to craft into" end
    return outs
end

-- One batch of `item`, at most `n` made: k crafts, up to 64 in each grid cell; the interface's
-- slots for its ingredients (a cell taking its k from one slot); the stacks it makes, into the
-- storage slots `outs` (crew.out_slots). Sized so its slots and the stacks it will give back
-- fit the interface's 9 together.
local function batch_for(item, n, outs)
    local rec = recipes.BY[item]
    if not rec then return nil, "no recipe for " .. item end
    local cells = {}
    for i, c in ipairs(rec.pattern) do
        if c and c ~= "saw" then
            cells[c] = cells[c] or {}
            table.insert(cells[c], i)
        end
    end
    local names = {}
    for c in pairs(cells) do names[#names + 1] = c end
    table.sort(names)
    local k = math.min((n + rec.yield - 1) // rec.yield, 64, #outs * 64 // rec.yield)
    while k > 0 do
        local slots = {}
        for _, c in ipairs(names) do
            local fit = 64 // k
            for a = 1, #cells[c], fit do
                local group = {}
                for b = a, math.min(a + fit - 1, #cells[c]) do group[#group + 1] = cells[c][b] end
                slots[#slots + 1] = {item = c, cells = group, count = #group * k}
            end
        end
        local stacks = (k * rec.yield + 63) // 64
        if #slots <= #me.STOCK and #slots + stacks <= 9 then
            return {item = item, rec = rec, k = k, slots = slots, made = k * rec.yield,
                    outs = outs}
        end
        k = k - 1
    end
    return nil, item .. " cannot be laid from the interface's slots"
end

-- The ops of one batch at the interface: the takes into the grid, the saw in, the crafts into
-- the storage slots until all k are made, the saw back. `face`: the station's (the first's when
-- nil). -> ops, config, stocked, the storage slots filled {slot = n}.
local function batch_ops(b, face)
    local d = DIR_CH[face or me.FACE]
    local ops, cfg, stocked = {}, {}, {}
    for islot, s in ipairs(b.slots) do
        local name, meta = s.item:match("^(.+):(%d+)$")
        cfg[islot] = {name, tonumber(meta), s.count}
        stocked[islot] = {name, tonumber(meta), s.count}
        for _, cell in ipairs(s.cells) do
            ops[#ops + 1] = ("t%s%d.%d*%d"):format(d, islot, recipes.GRID[cell], b.k)
        end
    end
    local saw_cell
    for i, c in ipairs(b.rec.pattern) do if c == "saw" then saw_cell = recipes.GRID[i] end end
    if saw_cell then ops[#ops + 1] = ("s%d.%d"):format(recipes.SAW_SLOT, saw_cell) end
    local left, outs = b.made, {}
    local per = 64 // b.rec.yield * b.rec.yield
    for _, slot in ipairs(b.outs) do
        if left <= 0 then break end
        local n = math.min(per, left)
        ops[#ops + 1] = ("c%d*%d"):format(slot, n)
        outs[slot] = n
        left = left - n
    end
    if saw_cell then ops[#ops + 1] = ("s%d.%d"):format(saw_cell, recipes.SAW_SLOT) end
    return ops, cfg, stocked, outs
end
crew.batch_for, crew.batch_ops = batch_for, batch_ops          -- for the tests

-- Gives of the storage slots filled by the last batch into the interface's slots not stocked
-- in `cfg` (cleared with it, emptied on the tick), facing `face` (the first station's if nil).
local function give_ops(outs, cfg, face)
    local d = DIR_CH[face or me.FACE]
    local free = {}
    for s = 1, 9 do if not cfg[s] then free[#free + 1] = s end end
    local ops, i = {}, 0
    local slots = {}
    for slot in pairs(outs) do slots[#slots + 1] = slot end
    table.sort(slots)
    for _, slot in ipairs(slots) do
        i = i + 1
        if not free[i] then return nil end
        ops[#ops + 1] = ("g%s%d.%d"):format(d, slot, free[i])
    end
    return ops
end

-- A crafting run (12-craft.md): to the interface, then for each batch one config (its
-- ingredients stocked, the last batch's slots cleared) and, after the tick, one exec - the last
-- batch's stacks given back, the takes, the crafts, a halt there; at the end, the slots cleared,
-- the last stacks given back, home. `list`: {{item, n}, ...} in order (ingredients first).
-- At whichever station is free first, as a builder (17-stations.md).
local function craft_run(r, j, list)
    local st
    local function done(why)
        if j.stocked then
            local s = {}
            for slot in pairs(j.stocked) do s[#s + 1] = slot end
            me.later_clear(s, st)
        end
        crew.unlock_me(r.name)
        crew.jobs[r.name] = nil
        if why then say(("%s: crafting stopped: %s"):format(r.name, why)) end
        return why == nil, why
    end
    j.phase = "waiting for the interface"
    st = crew.lock_me(r.name)
    j.st = st
    if holds_more_than_tools(r) then
        j.phase = "giving back what it held"
        local ok, why = give_back_rounds(r, j, "h", st)
        if not ok then return done(why) end
        vc.net_sleep_ms(1500)
    end
    -- the slots it crafts into: the empty ones, on its slots read now (crew.out_slots)
    read_slots(r)
    local outs_free, why_out = crew.out_slots(r.slots or {}, size_of(r))
    if not outs_free then return done(why_out) end
    local go = to_spot(r, r.sf.pos, r.sf.facing, st)
    if not go then return done("no way to the interface") end
    local outs, last_item = {}, nil                -- what the last batch made, still in Gunter
    local batches = 0
    for _, want in ipairs(list) do
        local left = want.n
        while left > 0 do
            local b, err = batch_for(want.item, left, outs_free)
            if not b then return done(err) end
            local ops, cfg, stocked, new_outs = batch_ops(b, st.FACE)
            local gives = give_ops(outs, cfg, st.FACE)
            if not gives then return done("no free slot to give the last batch back") end
            -- the ME has the ingredients? (the exe's view)
            local need = {}
            for _, s in ipairs(b.slots) do need[s.item] = (need[s.item] or 0) + s.count end
            for kk, n in pairs(need) do
                if (me.view[kk] or 0) < n then
                    return done(("the ME has %d %s, a batch of %s needs %d"):format(
                            me.view[kk] or 0, kk, want.item, n))
                end
            end
            j.phase = ("%s: batch of %d"):format(want.item, b.made)
            if j.stocked then
                local s = {}
                for slot in pairs(j.stocked) do s[#s + 1] = slot end
                me.later_clear(s, st)
            end
            local ok, why = me.config(cfg, st)
            if not ok then return done("the ME's computer: " .. tostring(why)) end
            j.stocked = stocked
            vc.net_sleep_ms(TICK_MS)         -- configured slots fill, cleared ones empty
            interface_in_copy(stocked, st)
            local function text_of(g)
                return "$0 " .. g .. " " .. table.concat(gives, " ") .. " "
                        .. table.concat(ops, " ") .. " h"
            end
            -- the hop planned again if its dry run met a robot, under the lock (leg)
            local remake = go ~= "" and function()
                go = to_spot(r, r.sf.pos, r.sf.facing, st) or go
                return text_of(go)
            end or nil
            local text = text_of(go)
            ok, why = leg(r, j, text, "crafting " .. want.item, remake)
            go = ""                          -- there from now on, facing it
            if not ok then return done(why) end
            for kk, n in pairs(need) do me.moved(kk, -n) end
            if last_item then
                for _, n in pairs(outs) do me.moved(last_item, n) end
            end
            outs, last_item = new_outs, want.item
            left = left - b.made
            batches = batches + 1
            say(("%s: made %d %s (batch %d)"):format(r.name, b.made, want.item, batches))
        end
    end
    -- the end: the slots cleared, the last stacks given back, home
    j.phase = "giving back the last, home"
    if j.stocked then
        local s = {}
        for slot in pairs(j.stocked) do s[#s + 1] = slot end
        me.later_clear(s, st)
    end
    me.flush(st)
    j.stocked = nil
    vc.net_sleep_ms(TICK_MS)
    interface_in_copy(nil, st)
    local gives = give_ops(outs, {}, st.FACE) or {}
    local home = route_avoiding(st.SPOT, st.FACE, r.park, avoid_for(r))
    local ok, why = leg(r, j, "$0 " .. go .. " " .. table.concat(gives, " ") .. " " .. home,
                        "giving back, home")
    if not ok then return done(why) end
    if last_item then for _, n in pairs(outs) do me.moved(last_item, n) end end
    say(("%s: crafting run done, %d batches, %.0f s"):format(r.name, batches,
                                                            vc.app_time() - j.t0))
    return done(nil)
end

local function start_run(name, list, wait)
    local r = robot_named(name)
    if not r then return nil, "no robot " .. tostring(name) end
    -- with the crew at work it waits its turn at the interface's lock, as a builder does (a
    -- fence gate short, refused while any trip ran, 2026-10-06)
    if next(crew.jobs) and not crew.parallel then
        return nil, "a robot is on a trip: one at the interface at a time"
    end
    local ok, why = still(r)
    if not ok then return nil, r.name .. ": " .. why end
    if not me.conn then return nil, "the ME is " .. me.phase end
    if not me.view and not me.items() then return nil, "the ME could not be read" end
    local j = {p = {id = "crafting", cells = {}, steps = {}}, phase = "setting off",
               t0 = vc.app_time()}
    crew.jobs[r.name] = j
    if wait then return craft_run(r, j, list) end
    spawn(craft_run, r, j, list)
    return true, ("%s sets off crafting %d kinds"):format(r.name, #list)
end

-- n of `item` crafted, in batches, at the interface (one run).
function crew.craft(name, item, n, wait)
    return start_run(name, {{item = item, n = n or recipes.BATCH}}, wait)
end

-- What the plan needs that the ME is short of, crafted in one run at the interface, ingredients
-- first (recipes.plan); what has no recipe is said, for the user to put into the ME.
function crew.short(name)
    if not me.view and not me.items() then return nil, "the ME could not be read" end
    local need = {}
    for _, p in pairs(packets.result.packets) do
        if not crew.is_done(p.id) then
            for kk, n in pairs((crew.bill(p))) do need[kk] = (need[kk] or 0) + n end
        end
    end
    local order, none = recipes.plan(need, me.view)
    local list = {}
    for _, s in ipairs(order) do
        list[#list + 1] = {item = s.item, n = s.crafts * recipes.BY[s.item].yield}
    end
    local out = {}
    for item, n in pairs(none) do out[#out + 1] = ("no recipe: %s, %d short"):format(item, n) end
    table.sort(out)
    if #list == 0 then return true, "nothing to craft\n" .. table.concat(out, "\n") end
    local ok, why = start_run(name, list, true)
    table.insert(out, 1, ok and ("%d kinds crafted"):format(#list)
                             or ("stopped: " .. tostring(why)))
    return ok, table.concat(out, "\n")
end

-- Packets one after another, each a whole trip to its end: {{robot, packet id}, ...}. Stops at
-- the first one refused or not done. Blocks until then (run it on a coroutine of its own).
-- Below half its energy, a robot goes home to its park - at a charger of the station - and
-- waits there until full (Pintsize at 14,455 under the field, 2026-10-05; step 4 in full is
-- still to come: the cost of each program against the way home).
local LOW, FULL = 20000, 38000
local function charge(r)
    if not (r.sf and r.sf.energy and r.sf.energy < LOW) then return end
    say(("%s: energy %d - home to charge"):format(r.name, r.sf.energy))
    go_home(r)
    local t0 = vc.app_time()
    while vc.app_time() - t0 < 600 and r.sf.energy < FULL do vc.net_sleep_ms(1000) end
    say(("%s: charged to %d"):format(r.name, r.sf.energy))
end

function crew.chain(list)
    for i, it in ipairs(list) do
        charge(robot_named(it[1]))
        -- chained while the same robot has more to do: no trip home between (10-live.md)
        local more = list[i + 1] and list[i + 1][1] == it[1]
        local ok, why = crew.start(it[1], it[2], more)
        if not ok then
            return nil, ("%d of %d, %s: refused: %s"):format(i, #list, it[2], tostring(why))
        end
        local r = robot_named(it[1])
        while crew.jobs[r.name] do vc.net_sleep_ms(500) end
        vc.net_sleep_ms(1500)                    -- its full status: what it holds now
        if not crew.is_done(it[2]) then
            return nil, ("%d of %d, %s: not done - the log says why"):format(i, #list, it[2])
        end
    end
    return true, ("%d packets done"):format(#list)
end

-- The packets `targets` need, and they themselves, by `name` one after another, in the plan's
-- order (crew.chain). A robot stopped on a block it learned (learn_block): its copy set right,
-- the plan made again on the corrected map, and on with what is still needed - `tries` times.
function crew.chain_to(name, targets, tries)
    tries = tries or 5
    local again = 0
    while true do
        local r = packets.result
        local need = {}
        local function walk(id)
            local q = r.packets[id]
            if not q or crew.is_done(id) or need[id] then return end
            need[id] = true
            for w in pairs(q.waits) do walk(w) end
        end
        for _, id in ipairs(targets) do walk(id) end
        local list = {}
        for _, id in ipairs(r.order) do if need[id] then list[#list + 1] = {name, id} end end
        if #list == 0 then return true, "all done" end
        crew.last_learned = nil
        local ok, why = crew.chain(list)
        if ok then return true, why end
        if not crew.last_learned or again >= tries then return nil, why end
        again = again + 1
        local ll = crew.last_learned
        say(("%s: re-planning after %s at %d,%d,%d (%d of %d)"):format(name, ll.name, ll.cell[1],
                ll.cell[2], ll.cell[3], again, tries))
        crew.resync(name)
        look_around(robot_named(name))
        crew.resync(name)
        packets.run()
    end
end

function crew.resync(name)
    local r = robot_named(name)
    if not r or not r.sf then return nil, "no linked robot " .. tostring(name) end
    if r.copy then
        local w, c = copy.world(), r.copy
        w:set(c.b.x, c.b.y, c.b.z, nil)
        c.b.x, c.b.y, c.b.z = r.sf.pos[1], r.sf.pos[2], r.sf.pos[3]
        w:set(c.b.x, c.b.y, c.b.z, {"OpenComputers:robot", 0})
        c.b.facing, c.m.pos, c.m.facing = r.sf.facing, {c.b.x, c.b.y, c.b.z}, r.sf.facing
        -- off the program it diverged on: else the next status_fast of it diverged it again
        c.m.id = nil
    end
    r.diverged = nil
    say(("%s: copy set at %s, divergence cleared"):format(r.name, table.concat(r.sf.pos, " ")))
    return true
end

function crew.report()
    local out = {}
    for name, j in pairs(crew.jobs) do
        local r = robots.by[name]
        out[#out + 1] = ("  %s on %s, %s (%s): %s op %s at %s"):format(name, j.p.id,
                tostring(j.phase), tostring(j.pid), r.sf and r.sf.state or "?",
                r.sf and tostring(r.sf.op) or "?", r.sf and table.concat(r.sf.pos, " ") or "?")
    end
    local n = 0
    for _ in pairs(crew.done) do n = n + 1 end
    out[#out + 1] = ("  %d packets done for real"):format(n)
    for _, l in ipairs(crew.log) do out[#out + 1] = "  " .. l end
    return out
end

-- ---- the crew at once (redesign/15-crew.md) -------------------------------------------------

crew.BUILDERS = {"ASIMO", "Pintsize", "Baymax", "Dalek_Sec", "Cortana"}   -- Gunter crafts
crew.BATCH = 4                    -- packets whose items a robot takes in one visit (15-crew.md)
crew.run = {}                                     -- the loop's state, for its report

-- A builder home with what it holds given back first (under the interface's lock), a job of its
-- own so the others' routes keep off it.
local function come_home(r)
    local j = {p = {id = "home", cells = {}, steps = {}}, phase = "home", t0 = vc.app_time()}
    if holds_more_than_tools(r) then
        crew.jobs[r.name] = j
        j.phase = "waiting for the interface"
        local st = crew.lock_me(r.name)
        j.st = st
        j.phase = "giving back"
        local home = route_avoiding(st.SPOT, st.FACE, r.park, avoid_for(r))
        local ok, why = give_back_rounds(r, j, home, st)
        crew.unlock_me(r.name)
        crew.jobs[r.name] = nil
        if not ok then say(("%s: giving back, going home: %s"):format(r.name, why)) end
    else
        go_home(r)
    end
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--[[ Every builder at work until the plan is built (15-crew.md): a free builder takes the next
-- ready packet (proven, its waits done, nobody on it, its box apart from the boxes worked, the
-- digs before the places); charges under the floor; goes home with nothing ready. A packet that
-- stopped on a block learned: the plan made again, tried again; anything else: that robot
-- parked as it is, named for inspection; a packet failed three times left out. Runs until
-- crew.run.stop, or nothing is left that can be done. `names`: the builders (crew.BUILDERS). ]]
crew.REPLAN_S = 180                 -- the plan made again at most this often while robots work

function crew.run_all(names)
    names = names or crew.BUILDERS
    local st = {fails = {}, left_out = {}, parked = {}, working = {}, started = 0, finished = 0,
                since = {}, t0 = vc.app_time(), note = "starting", reserved = {}}
    crew.run = st
    crew.parallel = true
    local replan = true
    while not st.stop do
        -- every station in use known to the grid and the copies (17-stations.md)
        pcall(crew.stations_in_map)
        -- the plan made again as soon as the world changed - robots mid-packet keep their own
        -- packets; waiting for them had let another robot take the old plan's dig of a cell
        -- already right (lavender, dig 0 0 4, 2026-10-06)
        -- ... but at most every REPLAN_S while robots work: a plan holds the whole program
        -- still (36 s seen), every link unread, the robots' programs killed by the watchdog and
        -- overlapped - made after every look, it had stopped the crew more than it served it
        -- (2026-10-06); a stale packet costs only its dry run, refused, set aside
        local due = not st.planned_at or vc.app_time() - st.planned_at >= crew.REPLAN_S
                    or not next(st.working)
        if (replan or st.looked) and due then
            st.note = "making the plan again"
            st.looked = nil
            local t0 = vc.app_time()
            packets.run()
            st.planned_at, st.plan_s = vc.app_time(), vc.app_time() - t0
            replan = false
        end
        local r0 = packets.result
        -- the robots whose packet ended: done, or why not - by its own last line in the log, not
        -- the log's last (ASIMO parked with Baymax's words, 2026-10-06)
        for name, id in pairs(st.working) do
            if not crew.jobs[name] then
                st.working[name] = nil
                local last = ""
                for i = #crew.log, 1, -1 do
                    if crew.log[i]:sub(1, #name + 1) == name .. ":" then
                        last = crew.log[i]
                        break
                    end
                end
                -- what the end means: crewfix (taught by `reload crewfix`, no restart)
                local kind = crew.is_done(id) and "done"
                        or require("live")("crewfix").classify(last, id)
                st.notnow = st.notnow or {}
                if kind == "done" then
                    st.finished = st.finished + 1
                elseif kind == "look" then
                    local rr = robot_named(name)
                    if rr then look_around(rr) end
                    crew.resync(name)
                    st.notnow[id] = vc.app_time() + 60
                    replan = true
                elseif kind == "wait" then
                    st.notnow[id] = vc.app_time() + 30
                    crew.resync(name)
                elseif kind == "replan" then
                    st.notnow[id] = vc.app_time() + 60
                    crew.resync(name)
                    replan = true
                elseif kind == "notnow" then
                    st.notnow[id] = vc.app_time() + 60
                else
                    st.fails[id] = (st.fails[id] or 0) + 1
                    st.reserved[name] = nil                -- its next ones back to the others
                    local learned = crew.last_learned and crew.last_learned.robot == name
                    if st.fails[id] >= 3 then
                        st.left_out[id] = last ~= "" and last or "failed three times"
                        say(("%s left out: failed three times"):format(id))
                    end
                    if learned then
                        crew.last_learned = nil
                        crew.resync(name)
                        replan = true
                    else
                        st.parked[name] = ("on %s: %s"):format(id, last ~= "" and last or "?")
                        say(("%s parked as it is, for inspection: %s"):format(name,
                            st.parked[name]))
                    end
                end
            end
        end
        -- what is being worked - by every crew job, not only this loop's (a trip begun before
        -- it, ASIMO's dig -1 0 8, had every robot picking it and refused, 2026-10-06) - and
        -- whether any dig is left
        local working_ids, boxes = {}, {}
        for _, ids in pairs(st.reserved) do
            for _, id in ipairs(ids) do working_ids[id] = true end
        end
        for _, j in pairs(crew.jobs) do
            local id = j.p and j.p.id
            if id then
                working_ids[id] = true
                local q = r0.packets[id]
                if q then boxes[#boxes + 1] = q.box end
            end
        end
        local digs_left = false
        for _, id in ipairs(r0.order) do
            local q = r0.packets[id]
            if q.kind == "dig" and not crew.is_done(id) and not st.left_out[id]
                    and not q.unproven then
                digs_left = true
            end
        end
        -- ready: proven, not done, nobody's, its waits done; the boxes beside one worked are no
        -- longer kept apart - the plan proved the packets side by side (the user, 2026-10-06:
        -- "they should not bother much with each-other ... the planner made sure that is ok")
        local function ready(id, own)
            local q = r0.packets[id]
            if not q or q.unproven or not q.steps or crew.is_done(id) or st.left_out[id]
                    or (working_ids[id] and not own) then
                return false
            end
            if q.kind == "place" and digs_left then return false end
            if st.notnow and st.notnow[id] and vc.app_time() < st.notnow[id] then return false end
            for w in pairs(q.waits) do if not crew.is_done(w) then return false end end
            return true
        end
        -- the stacks a packet's items and digs take in a robot's slots
        local function stacks_of(id)
            local pl, dg = crew.bill(r0.packets[id])
            local n = 0
            for kk, c in pairs(pl) do
                local most = crew.STACK[kk] or 64
                n = n + (c + most - 1) // most
            end
            for _, c in pairs(dg) do n = n + (c + 63) // 64 end
            return n
        end
        -- a packet for each free builder
        local any_ready = false
        for _, name in ipairs(names) do
            local r = robot_named(name)
            -- on no job, yet diverged: idle with only a slot count apart (Cortana and Dalek_Sec,
            -- skipped as diverged), or stopped where no loop saw its end (four builders stopped
            -- while the loop restarted, "pintsize sleeps", 2026-10-06) - crewfix.idle says which
            local act = r and not crew.jobs[name] and not st.working[name]
                    and require("live")("crewfix").idle(r)
            if act == "resync" then
                crew.resync(name)
            elseif act == "look" then
                crew.jobs[name] = {p = {id = "looking", cells = {}, steps = {}},
                                   phase = "looking round", t0 = vc.app_time()}
                spawn(function()
                    look_around(r)
                    crew.resync(name)
                    crew.jobs[name] = nil
                    st.looked = true                  -- the plan again, with what it saw
                end)
            end
            if r and not st.parked[name] and not crew.jobs[name] and not st.working[name]
                    and still(r) then
                if r.sf.energy and r.sf.energy < LOW then
                    crew.jobs[name] = {p = {id = "charging", cells = {}, steps = {}},
                                       phase = "charging", t0 = vc.app_time()}
                    spawn(function()
                        crew.jobs[name] = nil
                        charge(r)
                    end)
                else
                    -- its own reserved packets first, their items already taken
                    local took, tried = false, false
                    local mine = st.reserved[name] or {}
                    while #mine > 0 and not took do
                        local id = table.remove(mine, 1)
                        if ready(id, true) then
                            tried, any_ready = true, true
                            local ok = crew.start(name, id, true)
                            if ok then
                                st.working[name] = id
                                working_ids[id] = true
                                st.started = st.started + 1
                                took = true
                            end
                        end
                    end
                    if #mine == 0 then st.reserved[name] = nil end
                    -- else the first ready packet it can take, and up to BATCH-1 more ready
                    -- ones whose items fit its free slots, taken in the same visit
                    local free = 0
                    for slot = 1, size_of(r) or 0 do
                        if not (r.slots or {})[slot] then free = free + 1 end
                    end
                    for _, id in ipairs(took and {} or r0.order) do
                        if ready(id) then
                            tried, any_ready = true, true
                            local also, room = {}, free - stacks_of(id) - 1
                            for _, id2 in ipairs(r0.order) do
                                if #also >= crew.BATCH - 1 then break end
                                if id2 ~= id and ready(id2) and r0.packets[id2].kind == "place" then
                                    local n2 = stacks_of(id2)
                                    if n2 <= room then
                                        also[#also + 1] = id2
                                        room = room - n2
                                    end
                                end
                            end
                            local ok, why = crew.start(name, id, true, also)
                            if ok and #also > 0 then
                                st.reserved[name] = also
                                for _, a in ipairs(also) do working_ids[a] = true end
                            end
                            if ok then
                                st.working[name] = id
                                working_ids[id] = true
                                boxes[#boxes + 1] = r0.packets[id].box
                                st.started = st.started + 1
                                took = true
                                break
                            end
                            st.refused = st.refused or {}
                            if st.refused[name .. id] ~= why then
                                st.refused[name .. id] = why
                                say(("%s could not take %s: %s"):format(name, id, why))
                            end
                        end
                    end
                    if took or tried then
                        -- working, or packets ready but none it could take: it stays
                    elseif r.park and (r.sf.pos[1] ~= r.park[1] or r.sf.pos[2] ~= r.park[2]
                            or r.sf.pos[3] ~= r.park[3]) then
                        spawn(come_home, r)
                    end
                end
            end
        end
        -- robots waiting on robots, whatever they run (16-giveway.md): a ring of them, one gives
        -- way and comes back; one waiting long on another gives way; one idle steps aside -
        -- ASIMO and Dalek_Sec waited head on for good, 2026-10-06. Kept from ending the loop.
        local gok, gwhy = pcall(function() require("live")("giveway").tick(st) end)
        if not gok and st.gw_err ~= tostring(gwhy) then
            st.gw_err = tostring(gwhy)
            say("giving way broke: " .. st.gw_err)
        end
        -- the end: nothing worked, nothing ready - not while a builder is on a job of its own
        -- (looking round, charging, going home) or a packet is only set aside a while (the loop
        -- ended under four builders looking round, 2026-10-06)
        local busy = st.looked
        for _, name in ipairs(names) do if crew.jobs[name] then busy = true end end
        for _, t in pairs(st.notnow or {}) do if vc.app_time() < t then busy = true end end
        if not next(st.working) and not any_ready and not replan and not busy then
            local left = 0
            for _, id in ipairs(r0.order) do
                if not crew.is_done(id) then left = left + 1 end
            end
            st.note = ("nothing more can be done now: %d packets left (unproven, left out or"
                       .. " waiting on them)"):format(left)
            say(st.note)
            break
        end
        st.note = ("%d working, %d started, %d finished, %d left out, %d robots parked"):format(
            count(st.working), st.started, st.finished, count(st.left_out), count(st.parked))
        vc.net_sleep_ms(3000)
    end
    crew.parallel = false
    -- everyone home - not when the loop only stops to be read again (crew_reload: its trips go
    -- on, the new loop takes over at once)
    if st.reload then
        st.ended = true
        return st
    end
    for _, name in ipairs(names) do
        local r = robot_named(name)
        -- one on its way home already (sent by a pass of the loop) is let be: a second would
        -- go over it (robots.run refuses it, "busy")
        if r and not st.parked[name] and not crew.jobs[name] and still(r)
                and not robots.in_flight(r) then
            come_home(r)
        end
    end
    st.ended = true
    return st
end

-- The loop's report: one line of where it stands, the robots, the parked and left out.
function crew.run_report()
    local st = crew.run or {}
    local out = {tostring(st.note) .. (st.ended and " (ended)" or "")}
    for name, id in pairs(st.working or {}) do
        local r = robot_named(name)
        local j = crew.jobs[name]
        out[#out + 1] = ("  %s on %s: %s (%s op %s at %s)"):format(name, id,
            tostring(j and j.phase), r and r.sf and r.sf.state or "?",
            r and r.sf and tostring(r.sf.op) or "?",
            r and r.sf and table.concat(r.sf.pos, " ") or "?")
    end
    for name, why in pairs(st.parked or {}) do
        out[#out + 1] = "  PARKED " .. name .. ": " .. why
    end
    for id, why in pairs(st.left_out or {}) do
        out[#out + 1] = "  LEFT OUT " .. id .. ": " .. why
    end
    return table.concat(out, "\n")
end

return crew
