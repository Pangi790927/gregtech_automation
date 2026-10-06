--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The crew, simulated (stage 5 of 3d-draw/redesign/08-order.md): the builders as copies on
-- | robot/machine.lua and scripts/simbot.lua, each taking the next packet of the plan that is
-- | ready, its program made from where it stands (programs.lua), all at once on the server's
-- | clock, sped up. The user, 2026-10-05: "I want to see a simulated run, the whole building at the
-- | end, but for now, see them do at least a zone each, in paralel".
-- |
-- |     sim.start(focus)     the plan of the packets panel, the five builders at their parks;
-- |                          with a packet id, only it and what it waits on (the rest as done)
-- |     sim.update(dt)       the robots' ops up to the clock; true when the view is to be drawn
-- |     sim.cells()          the view's overlay: robots, blocks placed and dug, and with J what is
-- |                          left of the packets being worked, see-through
-- |     sim.draw(), sim.panel()
-- |     sim.clear()          the run gone, the pathfinder's grid as it was
-- |
-- | This first crew has no ME: a robot holds every block it needs (slots filled as its program is
-- | made). The world is the chunks under the plan and the station, read at the start; it changes
-- | only as the robots dig and place. The pathfinder's grid runs ahead of them - each program marks
-- | its cells as it is made - and is put back when the run is cleared.
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local spawn = require("spawn")         -- spawns that keep their handle
local blocks = require("blocks")
local chunks = require("chunks")
local live = require("live")
local machine = live("machine")       -- by name: `reload programs` mid-run takes at once
local simbot = live("simbot")
local programs = live("programs")
local route = require("route")
local packets = live("packets")
local view = require("view")

local sim = {on = false, running = false, speed = 16, clock = 0, robots = {}, done = {},
             taken = {}, failed = {}, over = {}, note = "", ndone = 0}

local TPS = 13
local MATTOCK_SLOT = 32                 -- the builders' last slot
local STEP_MAX = TPS * 20               -- server ticks the sim clock may move in one frame
sim.FOCUS_ROBOT = "Pintsize"            -- the one builder of a focused run
local CREW = {                          -- robots.lua's builders, at their parks
    {"G.U.N.T.E.R.", {0, 0, 0}, 0xff2090ff}, {"ASIMO", {2, 0, -2}, 0xff40d040},
    {"Pintsize", {0, 0, -2}, 0xffd04080}, {"Baymax", {1, -1, -2}, 0xff40c0e0},
    {"Dalek_Sec", {1, 1, -2}, 0xff20d0f0},
}
local FACE = {n = blocks.FACE.ZNEG, s = blocks.FACE.ZPOS, e = blocks.FACE.XPOS,
              w = blocks.FACE.XNEG}
local ROBOT = "OpenComputers:robot"

local function unkey(k)
    local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
    return tonumber(x), tonumber(y), tonumber(z)
end

-- the plan's map, for the program maker: what the plan wants, what the world has
local map = {want = {}, have = nil}

-- The overlay kept as the world changes: a cell's entry renewed when the world says it changed.
local dirty = {}
local function refresh(k)
    local w = sim.w
    local b = w.blocks[k]
    if b and b[1] == ROBOT then
        local who
        for _, r in ipairs(sim.robots) do
            if r.b.x .. "," .. r.b.y .. "," .. r.b.z == k then who = r end
        end
        sim.over[k] = {ROBOT, 0, nil, who and FACE[who.b.facing]}
    elseif w.placed[k] and b then
        sim.over[k] = {b[1], b[2]}
    elseif w.dug[k] or (b == false and sim.base[k]) then
        sim.over[k] = {"minecraft:air", 0}
    elseif view.j and sim.ghost[k] then
        local g = map.want[k]
        sim.over[k] = {g[1], g[2], nil, nil, 2}
    else
        sim.over[k] = nil
    end
end

function sim.start(focus)
    -- never beside the real robots: they share the one grid (redesign/10-live.md)
    local crew = package.loaded["crew"]
    if crew and next(crew.jobs) then
        sim.note = "real robots are at work: the sim waits until their packets end"
        return
    end
    -- The grid read again from the chunk files, then planned and proven afresh. A snapshot kept
    -- across runs had saved one run's changes as the map - grass dug in a run came back as air
    -- in the next (2026-10-05) - so each run starts from the files.
    route.load()
    if packets.result then packets.run() end
    local r = packets.result
    if not r then sim.note = "plan first (packets: plan it)"; return end
    map.want = packets.want
    -- why robots stood idle, robot-ticks by reason (idle_reason)
    sim.idle_why = {}
    -- the world: the chunks under the plan and the station, robot coordinates
    local a = view.anchor
    local x0, x1, z0, z1 = 0, 2, -2, 0
    for k in pairs(map.want) do
        local x, _, z = unkey(k)
        x0, x1, z0, z1 = math.min(x0, x), math.max(x1, x), math.min(z0, z), math.max(z1, z)
    end
    local area = chunks.read_area("data/chunks", (x0 + a[1]) // 16, (x1 + a[1]) // 16,
            (z0 + a[3]) // 16, (z1 + a[3]) // 16,
            chunks.LAYERS)
    local wb, base = {}, {}
    for _, c in pairs(area.cells) do
        local k = (c[1] - a[1]) .. "," .. (c[2] - a[2]) .. "," .. (c[3] - a[3])
        wb[k] = {c[4], c[5]}
        base[k] = true
    end
    sim.base = base
    local w = simbot.world(wb)
    sim.w = w
    map.have = function(x, y, z)
        local b = w.blocks[x .. "," .. y .. "," .. z]
        if b then return b[1], b[2] end
        return "air"
    end
    map.placed = function(k) return w.placed[k] end         -- leaves the robots placed
    sim.robots, sim.done, sim.taken, sim.failed, sim.over, sim.ghost = {}, {}, {}, {}, {}, {}
    for id, p in pairs(r.packets) do
        if p.unproven then sim.failed[id] = "unproven: " .. p.unproven end
    end
    sim.clock, sim.ndone, sim.note = 0, 0, ""
    -- a focus: that packet and, through its waits, what it needs; the rest counts as done, so a
    -- field is tried before the whole village (the upper field, 2026-10-05)
    if focus and focus ~= "" then
        if not r.packets[focus] then
            sim.note = "no packet " .. focus
            return
        end
        local need, todo = {}, {focus}
        while #todo > 0 do
            local id = table.remove(todo)
            if not need[id] and r.packets[id] then
                need[id] = true
                for w in pairs(r.packets[id].waits) do todo[#todo + 1] = w end
            end
        end
        for id in pairs(r.packets) do if not need[id] then sim.done[id] = true end end
        sim.note = "focus: " .. focus
    end
    -- a focus is one builder's work, as it runs live (the user, 2026-10-05: "one builder builds
    -- the field"): Pintsize works it, the others stand in their parks as robots do - idle sim
    -- robots stay where their last packet ended, on a field's stands (-26,6,22, 2026-10-06)
    for _, c in ipairs(CREW) do
        if focus and focus ~= "" and c[1] ~= sim.FOCUS_ROBOT then
            w:set(c[2][1], c[2][2], c[2][3], {ROBOT, 0})
            goto next_robot
        end
        local b = simbot.robot(w, {x = c[2][1], y = c[2][2], z = c[2][3], facing = "n",
                                   name = c[1], energy = 40500, max = 40500})
        local rob = {name = c[1], colour = c[3], b = b, kinds = {}, trail = {{b.x, b.y, b.z}},
                     packet = nil, work = 0, idle = 0, waits = 0}
        rob.m = machine.new(b.hw, {x = b.x, y = b.y, z = b.z, facing = "n"})
        -- each builder carries a mattock (the user, 2026-10-05), kept apart from the kinds' slots
        b.slots[MATTOCK_SLOT] = {name = "TConstruct:mattock", meta = 0, count = 1}
        sim.robots[#sim.robots + 1] = rob
        ::next_robot::
    end
    -- the pathfinder's grid follows the world as the robots change it: a cell dug or left is air,
    -- a block placed or a robot standing is a block
    sim.changes = 0
    w.on_change = function(k)
        dirty[k] = true
        -- a block placed or dug, not a robot passing: what may make a packet left for now doable
        local b0 = w.blocks[k]
        if (b0 and w.placed[k]) or (not b0 and w.dug[k]) then sim.changes = sim.changes + 1 end
        local x, y, z = unkey(k)
        local b = w.blocks[k]
        if b then
            vc.route_set(x, y, z, 2)
        else
            vc.route_set(x, y, z, 1)
        end
    end
    for _, rob in ipairs(sim.robots) do
        dirty[rob.b.x .. "," .. rob.b.y .. "," .. rob.b.z] = true
    end
    sim.on, sim.running = true, true
end

-- before `reload sim`: the grid put back, as a clear does
function sim.unload() sim.clear() end

function sim.clear()
    if sim.on then route.load() end                -- the grid from the files again
    sim.on, sim.running, sim.over, sim.robots = false, false, {}, {}
    dirty, sim.cleared = {}, true
end

-- The next packet a robot may take: the first in the plan's order not done nor taken whose waits
-- are done; a place packet only once every dig is done.
local function next_packet(skip)
    local r = packets.result
    -- a packet that waits on one that failed fails too, saying so: else the digs under a treetop
    -- that cannot be dug waited for ever, and with them every place (2026-10-05)
    local more = true
    while more do
        more = false
        for _, id in ipairs(r.order) do
            if not sim.done[id] and not sim.failed[id] and not sim.taken[id] then
                for wid in pairs(r.packets[id].waits) do
                    if sim.failed[wid] then
                        sim.failed[id] = "waits on " .. wid .. ", which failed"
                        more = true
                        break
                    end
                end
            end
        end
    end
    local digs_left = false
    for _, id in ipairs(r.order) do
        if r.packets[id].kind == "dig" and not sim.done[id] and not sim.failed[id] then
            digs_left = true
        end
    end
    -- of the ready packets, the earliest in the order whose box is not next to one being worked:
    -- robots spread over the site and do not wait on each other (the user, 2026-10-05: "the
    -- planner should dictate an order that keeps the least ammount of robots waiting"); only
    -- when none is apart, the earliest ready
    local active = {}
    for _, rob in ipairs(sim.robots) do
        if rob.packet then active[#active + 1] = rob.packet.box end
    end
    local function apart(b)
        for _, a in ipairs(active) do
            if math.abs(a[1] - b[1]) <= 1 and math.abs(a[2] - b[2]) <= 1
                    and math.abs(a[3] - b[3]) <= 1 then
                return false
            end
        end
        return true
    end
    local first
    for _, id in ipairs(r.order) do
        local p = r.packets[id]
        if not sim.done[id] and not sim.taken[id] and not sim.failed[id]
                and not (skip and skip[id])
                and not (p.notnow and p.notnow == sim.changes)
                and not (p.kind == "place" and digs_left) then
            local ready = true
            for wid in pairs(p.waits) do
                if not sim.done[wid] then ready = false break end
            end
            if ready then
                if apart(p.box) then return p end
                first = first or p
            end
        end
    end
    return first
end

-- Why a robot found nothing to take, for the idle accounting: nothing left to start; ready but
-- left for now (no way yet); ready but a place, and digs are left; or every packet left waits on
-- one being worked (the user, 2026-10-05: "robots shouldn't be idle").
local function idle_reason()
    local r = packets.result
    local left, notnow, barrier, digs_left = 0, 0, 0, false
    for _, id in ipairs(r.order) do
        local p = r.packets[id]
        if p.kind == "dig" and not sim.done[id] and not sim.failed[id] then digs_left = true end
    end
    for _, id in ipairs(r.order) do
        local p = r.packets[id]
        if not sim.done[id] and not sim.failed[id] and not sim.taken[id] then
            left = left + 1
            local ready = true
            for wid in pairs(p.waits) do
                if not sim.done[wid] then ready = false break end
            end
            if ready and p.kind == "place" and digs_left then barrier = barrier + 1
            elseif ready and p.notnow then notnow = notnow + 1 end
        end
    end
    if left == 0 then return "nothing left to start" end
    if notnow > 0 then return "ready, left for now (no way yet)" end
    if barrier > 0 then return "places wait for the last digs" end
    return "all left wait on packets being worked"
end

-- A slot for a kind of block, filled without end: this crew has no ME yet.
-- A slot holding what a block is put with, as the live crew takes it from the ME (crew.item): a
-- water cell's water bucket, wheat's seeds, farmland's dirt.
local function slot_of(rob)
    return function(name, meta)
        name, meta = require("crew").item(name, meta)
        local kk = name .. ":" .. meta
        if not rob.kinds[kk] then
            local n = 0
            for _ in pairs(rob.kinds) do n = n + 1 end
            if n >= MATTOCK_SLOT - 1 then return nil end  -- the builders' inventory
            rob.kinds[kk] = n + 1
        end
        local s = rob.kinds[kk]
        rob.b.slots[s] = {name = name, meta = meta, count = 1000000}
        return s
    end
end

sim.slot_of, sim.MATTOCK_SLOT = slot_of, MATTOCK_SLOT

--[[ A robot stopped by something in its way - a block another robot placed across its route since
-- the program was made, a cell taken by a robot passing - has the rest of its proven steps made
-- again from where it stands, REROUTES times at most; only then the packet fails. Two such stops
-- had failed 35 packets after them in the village's run (2026-10-05). ]]
local REROUTES = 3
-- The cells of the packets the other robots are working, to dig and to place, supports with
-- them: kept off by this robot's routes (programs.lua, `avoid`; redesign/09-paths.md).
-- Where each other robot's program ends too: where it comes to rest (a robot is a block in the
-- grid where it stands already; the user, 2026-10-05: "same for the final resting place for a
-- robot that runs").
local function others_work(rob)
    local avoid = {}
    for _, o in ipairs(sim.robots) do
        if o ~= rob and o.packet then
            for _, k in ipairs(o.packet.cells or {}) do avoid[k] = true end
            for _, st in ipairs(o.packet.steps or {}) do avoid[st.k] = true end
        end
        if o ~= rob and o.dest and (o.m.state == "run" or o.m.state == "wait") then
            avoid[o.dest[1] .. "," .. o.dest[2] .. "," .. o.dest[3]] = true
        end
    end
    return avoid
end
sim.others_work = others_work

local function reroute(rob)
    local m, why = rob.m, tostring(rob.m.why)
    if not (why:find("^blocked") or why:find("taken")) or not rob.opstep then return false end
    if rob.reroutes >= REROUTES then return false end
    rob.reroutes = rob.reroutes + 1
    local last = 0                                 -- the last step its ops finished
    for i = 1, m.pc - 1 do
        if rob.opstep[i] and rob.opstep[i] > last then last = rob.opstep[i] end
    end
    local rest = {}
    for i = last + 1, #rob.steps do rest[#rest + 1] = rob.steps[i] end
    if #rest == 0 then return false end
    local text, dest, _, opstep = programs.make({steps = rest}, {pos = {rob.b.x, rob.b.y,
            rob.b.z}, facing = rob.b.facing, slot_of = slot_of(rob), avoid = others_work(rob),
            tool_slot = MATTOCK_SLOT}, map)
    if not text then return false end
    rob.opstep, rob.steps, rob.dest = opstep, rest, dest
    m.exec(rob.packet.id, text)
    sim.log_line(("%s: %s re-routed after %s"):format(rob.name, rob.packet.id, why))
    return true
end

local take_one

--[[ The next packet a robot can do now. One whose program cannot be made now - in parallel,
-- another packet's supports, fresh blocks or a robot stand where its proof had free cells - is
-- not failed and not paused: it is left for now (`notnow`, until the world changes) and the next
-- ready packet is taken instead (the user, 2026-10-05: "if the grid work can't be done now, take
-- another work that can be done"). ]]
local function take(rob)
    local tried = {}
    while true do
        local p = next_packet(tried)
        if not p then return false end
        local r = take_one(rob, p)
        if r ~= "notnow" then return r end
        tried[p.id] = true
    end
end

function take_one(rob, p)
    rob.kinds = {}
    local t_make = vc.app_time()
    local text, a2, _, opstep = programs.make(p, {pos = {rob.b.x, rob.b.y, rob.b.z},
                                                  facing = rob.b.facing,
                                                  slot_of = slot_of(rob),
                                                  tool_slot = MATTOCK_SLOT,
                                                  avoid = others_work(rob)}, map)
    rob.opstep, rob.steps, rob.reroutes = opstep, p.steps, 0
    local tm = vc.app_time() - t_make
    sim.timing.makes, sim.timing.make_sum = sim.timing.makes + 1, sim.timing.make_sum + tm
    if tm > sim.timing.make_max then sim.timing.make_max = tm end
    if not text then
        if tostring(a2):find("^no way") then
            p.notnow, p.notnow_why = sim.changes, a2
            return "notnow"
        end
        sim.failed[p.id] = a2
        sim.log_line(rob.name .. ": " .. p.id .. " cannot be made: " .. tostring(a2))
        return true
    end
    local ok, err = rob.m.exec(p.id, text)
    if not ok then
        sim.failed[p.id] = err
        return true
    end
    rob.dest = a2                                  -- where it comes to rest: kept off by others
    sim.taken[p.id], rob.packet = true, p
    p.t_start, p.t_by = rob.b.ticks, rob.name
    -- no cells kept out of others' ways: the proof let a packet's robot stand in cells another
    -- would fill later, and kept-out cells left "no way" (2026-10-05); a robot that meets
    -- something in its way is re-routed (reroute)
    if p.kind == "place" then
        for _, k in ipairs(p.cells) do sim.ghost[k], dirty[k] = true, true end
    end
    return true
end

--[[ Robots that meet (03-exec.md, "Creatures, and robots that meet"): a robot that has waited on
-- another for WAIT_GIVE seconds has the other moved. One standing idle steps aside - up, else to a
-- free side - and stays there; of two at work, the later in the crew gives way, `give_way $0 + -`:
-- up, and back down once the other has passed (its step down waits until then), then back to the
-- op it was waiting at. Pintsize and Baymax met head on and waited 390 times (2026-10-05). ]]
local WAIT_GIVE = 3
local AROUND = {{"+", 0, 1, 0}, {"^", 0, 0, -1}, {"v", 0, 0, 1}, {">", 1, 0, 0}, {"<", -1, 0, 0}}
local BACK = {["+"] = "-", ["^"] = "v", v = "^", [">"] = "<", ["<"] = ">"}

local function aside(b)
    for _, a in ipairs(AROUND) do
        local x, y, z = b.x + a[2], b.y + a[3], b.z + a[4]
        if not sim.w.blocks[x .. "," .. y .. "," .. z] and vc.route_get(x, y, z) == 1 then
            return a[1]
        end
    end
end

local function unjam(rob, i)
    local m = rob.m
    if m.state ~= "wait" or m.why ~= "robot" then
        rob.stuck = 0
        return
    end
    rob.stuck = (rob.stuck or 0) + 1
    if rob.stuck < WAIT_GIVE then return end
    -- the robot in the way: the cell of the step it waits to take
    local op = m.prog.ops[m.pc]
    local d = op and machine.STEP_OF[op.dir]
    if not d then return end
    local x, y, z = rob.b.x + d[1], rob.b.y + d[2], rob.b.z + d[3]
    for j, other in ipairs(sim.robots) do
        local ob = other.b
        if j ~= i and ob.x == x and ob.y == y and ob.z == z then
            local step = aside(ob)
            if not step then return end
            if not other.packet then
                other.m.exec("aside", "$0 " .. step)              -- idle: out of the way, stays
                other.aside = true
            elseif other.m.state == "wait" and j > i then
                other.m.give_way("gw", "$0 " .. step .. " " .. BACK[step])
            elseif other.m.state == "wait" then
                local mine = aside(rob.b)
                if mine then m.give_way("gw", "$0 " .. mine .. " " .. BACK[mine]) end
            end
            rob.stuck = 0
            sim.log_line(("%s waited on %s: it gave way"):format(rob.name, other.name))
            return
        end
    end
end

sim.lines = {}
function sim.log_line(s)
    sim.lines[#sim.lines + 1] = s
    if #sim.lines > 8 then table.remove(sim.lines, 1) end
end

sim.timing = {frame_max = 0, make_max = 0, make_sum = 0, makes = 0, routes = 0}
function sim.update(dt)
    local t_frame = vc.app_time()
    local changed, result = sim.update_(dt)
    local t = vc.app_time() - t_frame
    if t > sim.timing.frame_max then sim.timing.frame_max = t end
    return changed, result
end

function sim.update_(dt)
    local changed = sim.cleared or false
    sim.cleared = false
    if sim.j_seen ~= view.j then
        sim.j_seen = view.j
        for k in pairs(sim.ghost or {}) do dirty[k] = true end
    end
    if sim.on and sim.running then
        -- One time for all: the clock moves at most STEP_MAX a frame and never past a robot at
        -- work (below). A slow frame - a program made in 0.8 s, at x256 some 270 s of server
        -- time - had let the clock run 2300 s ahead of the robots digging; the idle ones, set
        -- to the clock, found every place locked behind digs still running in the past, and
        -- four of five stood idle while one built alone (2026-10-05: "robots shouldn't be idle").
        sim.clock = sim.clock + math.min(dt * TPS * sim.speed, STEP_MAX)
        local busy = false
        for _, rob in ipairs(sim.robots) do
            local guard = 0
            while rob.b.ticks < sim.clock and guard < 400 do
                guard = guard + 1
                local m = rob.m
                if rob.packet and m.state == "done" then
                    sim.done[rob.packet.id], sim.taken[rob.packet.id] = true, nil
                    rob.packet.t_end = rob.b.ticks
                    for _, k in ipairs(rob.packet.cells) do sim.ghost[k] = nil end
                    sim.ndone = sim.ndone + 1
                    rob.packet = nil
                end
                if not rob.packet and rob.aside and m.state == "run" then
                    local before = rob.b.ticks
                    m.step()
                    if rob.b.ticks == before then rob.b.ticks = rob.b.ticks + 1 end
                    if m.state ~= "run" then rob.aside = nil end
                elseif not rob.packet then
                    if not take(rob) then
                        local dt_idle = sim.clock - rob.b.ticks
                        rob.idle = rob.idle + dt_idle
                        if sim.idle_why and dt_idle > 0 then
                            local why = idle_reason()
                            sim.idle_why[why] = (sim.idle_why[why] or 0) + dt_idle
                        end
                        rob.b.ticks = sim.clock                   -- nothing ready: it waits
                        break
                    end
                end
                if rob.packet then
                    busy = true
                    local before = rob.b.ticks
                    local st = m.step()
                    rob.work = rob.work + (rob.b.ticks - before)
                    if st == "wait" then
                        rob.waits = rob.waits + 1
                        rob.b.ticks = rob.b.ticks + TPS                 -- again in a second
                        for i, rr in ipairs(sim.robots) do
                            if rr == rob then unjam(rob, i) end
                        end
                    elseif st == "stop" and reroute(rob) then
                        -- something got in the way: the rest of its steps, from where it is
                    elseif st == "stop" then
                        sim.failed[rob.packet.id] = m.why
                        sim.log_line(("%s: %s stopped: %s"):format(rob.name, rob.packet.id,
                                tostring(m.why)))
                        sim.taken[rob.packet.id] = nil
                        rob.packet = nil
                    end
                    local last = rob.trail[#rob.trail]
                    local b = rob.b
                    if last[1] ~= b.x or last[2] ~= b.y or last[3] ~= b.z then
                        rob.trail[#rob.trail + 1] = {b.x, b.y, b.z}
                        if #rob.trail > 300 then table.remove(rob.trail, 1) end
                    end
                end
            end
        end
        -- a robot at work that could not keep up (its 400 ops a frame) holds the clock back
        for _, rob in ipairs(sim.robots) do
            if (rob.packet or rob.aside) and rob.b.ticks < sim.clock then
                sim.clock = rob.b.ticks
            end
        end
        if not busy and not next_packet() then
            local any = false
            for _, rob in ipairs(sim.robots) do if rob.packet then any = true end end
            if not any then
                -- nobody at work: what was left for now will not become doable by waiting
                for id, p in pairs(packets.result.packets) do
                    if p.notnow and not sim.done[id] and not sim.failed[id] then
                        sim.failed[id] = tostring(p.notnow_why)
                    end
                end
            end
            if not any then
                sim.running = false
                sim.log_line(("the build ends: %d packets done, %d failed, %.0f s of server time")
                        :format(sim.ndone, (function() local n = 0 for _ in pairs(sim.failed)
                        do n = n + 1 end return n end)(), sim.clock / TPS))
                -- plan cells in no packet: the map never saw them, so the planner could not
                -- tell a dig from a place (the wool at -23,19,29, 2026-10-05: left out unsaid)
                local unknown = packets.result.problems.unknown
                if #unknown > 0 then
                    sim.log_line(("never scanned, so not built: %d cells, %s%s"):format(#unknown,
                            table.concat(unknown, " ", 1, math.min(8, #unknown)),
                            #unknown > 8 and " ..." or ""))
                end
            end
        end
    end
    for k in pairs(dirty) do
        refresh(k)
        changed = true
    end
    dirty = {}
    return changed
end

function sim.cells()
    if not sim.on then return nil end
    return sim.over
end

local function polyline(cells, colour)
    local disp = vc.ImGui_GetDisplaySize()
    local W, H = math.floor(disp.x), math.floor(disp.y)
    local prev
    for _, c in ipairs(cells) do
        local x, y, z = view.to_cell(c[1], c[2], c[3])
        local at = x and vc.render_project(x + 0.5, y + 0.5, z + 0.5, W, H)
        if at and at[3] > 0 then
            if prev then
                vc.ImGui_AddLine({x = prev[1], y = prev[2]}, {x = at[1], y = at[2]}, colour, 2)
            end
            prev = at
        else
            prev = nil
        end
    end
end

function sim.draw()
    if not sim.on then return end
    local disp = vc.ImGui_GetDisplaySize()
    local W, H = math.floor(disp.x), math.floor(disp.y)
    vc.ImGui_SetDrawForeground(true)
    for _, rob in ipairs(sim.robots) do
        if view.paths then polyline(rob.trail, rob.colour) end
        local b = rob.b
        local x, y, z = view.to_cell(b.x, b.y, b.z)
        local at = x and vc.render_project(x + 0.5, y + 1.2, z + 0.5, W, H)
        if at and at[3] > 0 then
            local text = ("%s  %s"):format(rob.name, rob.packet and rob.packet.id or "idle")
            local size = vc.ImGui_CalcTextSize(text)
            local x0, y0 = at[1] - size.x / 2 - 4, at[2] - size.y - 6
            vc.ImGui_AddRectFilled({x = x0, y = y0}, {x = x0 + size.x + 8, y = y0 + size.y + 4},
                    0xc0202020, 3)
            vc.ImGui_AddText({x = x0 + 4, y = y0 + 2}, rob.colour, text)
        end
    end
    vc.ImGui_SetDrawForeground(false)
end

function sim.panel()
    local r = packets.result
    local total = r and #r.order or 0
    local nfail = 0
    for _ in pairs(sim.failed) do nfail = nfail + 1 end
    vc.ImGui_Text(("simulated crew: %s   %d of %d packets done, %d failed   %.0f s of server time")
            :format(sim.on and (sim.running and "building" or "stopped") or "none", sim.ndone,
            total, nfail, sim.clock / TPS))
    if vc.ImGui_Button(sim.on and "start again" or "simulate the build", {x = 0, y = 0}) then
        spawn(sim.start)               -- it plans and proves first: not in a frame
    end
    if sim.on then
        vc.ImGui_SameLine(0, -1)
        if vc.ImGui_Button(sim.running and "pause" or "go on", {x = 0, y = 0}) then
            sim.running = not sim.running
        end
        vc.ImGui_SameLine(0, -1)
        if vc.ImGui_Button("clear##sim", {x = 0, y = 0}) then sim.clear() end
    end
    for _, s in ipairs({1, 16, 64, 256}) do
        vc.ImGui_SameLine(0, -1)
        if vc.ImGui_SmallButton((s == sim.speed and "[x%d]" or "x%d"):format(s)) then
            sim.speed = s
        end
    end
    for _, rob in ipairs(sim.robots) do
        local all = rob.work + rob.idle
        vc.ImGui_Text(("  %-13s %-18s %s  working %d%%  waits %d"):format(rob.name,
                rob.packet and rob.packet.id or "idle", rob.m.state,
                all > 0 and math.floor(100 * rob.work / all) or 0, rob.waits))
    end
    for _, l in ipairs(sim.lines) do vc.ImGui_Text("  " .. l) end
    if sim.note ~= "" then vc.ImGui_Text(sim.note) end
end

return sim
