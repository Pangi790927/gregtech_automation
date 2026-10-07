--[[ The crew's sim (redesign/18-crewsim.md): the live crew's own code - crew.run_all, its trips,
-- the locks and both stations, the give-way, crewfix, robots.lua's links with their poll, full
-- status and watchdog - driving five robots that are robot/machine.lua's own command loop
-- (M.serve) over simbot bodies, reached through a stand-in for the relay. Time runs WARP times
-- faster; the plan made again holds the whole program still FREEZE_S real seconds, as
-- packets.run does live, while the robots go on working through it, as real ones do. The ME's
-- computer is a stand-in that keeps both interfaces stocked in the simulated world.
-- The user, 2026-10-06, after an hour of live patches: "build the crew sim first" - every crew
-- change passes this before the live robots (the rule: sim before live robots).
-- Passes when the whole plan is built: every packet done, every block in the world, no robot
-- parked, no packet left out, no copy diverged at the end, no link closed by the watchdog.
-- @date 2026-10-06 ]]

local vc = require("virt_composer")
local spawn = require("spawn")         -- spawns that keep their handle
local robots = require("robots")
local relay = require("relay")
local copy = require("copy")
local crew = require("crew")
local me = require("me")
local packets = require("packets")
local machine = require("machine")
local simbot = require("simbot")
local view = require("view")

local WARP = 5                    -- the sim's seconds to one real second
local FREEZE_S = 7.2              -- real seconds the program stands still for each plan: 36 s
                                  -- of the sim's, the longest seen live
local OP_S = 0.5                  -- a robot's op, in the sim's seconds (the field: 0.3 to 1)
local ME_S = 3                    -- an ask of the ME's computer (the field: ~10, one at a time)
local LIMIT_S = 1500              -- the sim's seconds the whole plan may take
local A1, A2 = "bd5ff0a2", "b375f0fd"
local FAR_ONE = "Dalek_Sec"        -- starts out in the village with things to give back
local LOW_ONE = "Cortana"          -- starts under the crew's charge line: sent home to charge
local OFFLINE = "G.U.N.T.E.R."    -- the robot left off the relay, standing in the station's ways

-- ---- time, WARP times faster -------------------------------------------------------------------

-- vc's clock and sleep, warped: every coroutine (the crew, the links, the robots) reads the same
-- clock, so the program's own still (a real busy wait) is WARP times longer in the sim's time.
local function warp(on, kept)
    if not on then
        vc.app_time, vc.net_sleep_ms = kept.time, kept.sleep
        return
    end
    local real_time, real_sleep = vc.app_time, vc.net_sleep_ms
    local t0 = real_time()
    vc.app_time = function() return t0 + (real_time() - t0) * WARP end
    vc.net_sleep_ms = function(ms) return real_sleep(math.max(1, math.floor(ms / WARP))) end
    return {time = real_time, sleep = real_sleep}
end

-- ---- the world ----------------------------------------------------------------------------------

-- Robot coordinates, the station's as the field has them (me.stations, robots.ROSTER's parks):
-- the ground solid up to y -2; the two interfaces; the site, cells to build at y -1 from x 5.
-- And terrain over it: grass in the only stand of a stair (the user, 2026-10-06: "dig and put
-- back for the stairs") - its packet digs it, places the stair from its cell, puts it back.
local TERRAIN = {["11,-1,25"] = {"minecraft:grass", 0}}
local function solid(x, y, z) return y <= -2 or TERRAIN[x .. "," .. y .. "," .. z] ~= nil end
local BOX = {x = {-16, 15}, y = {-4, 6}, z = {-16, 31}}

-- The pathfinder's grid of the same, a chunk file each (test_giveway's format), in world
-- heights: the grid holds none below 0, so the robots' y -4 to 6 go in as AY above (the field's
-- anchor is the same shift, y 63).
local AY = 10
local function load_grid()
    for cx = -1, 0 do
        for cz = -1, 1 do
            local rows = {}
            for y = BOX.y[1], BOX.y[2] do
                local zs = {}
                for z = cz * 16, cz * 16 + 15 do
                    local xs = {}
                    for x = cx * 16, cx * 16 + 15 do xs[#xs + 1] = solid(x, y, z) and "1" or "0" end
                    zs[#zs + 1] = table.concat(xs, ",")
                end
                rows[#rows + 1] = ("layer %d %s"):format(y + AY, table.concat(zs, ";"))
            end
            local f = assert(io.open(("test_run/c%d_%d.txt"):format(cx, cz), "wb"))
            f:write(table.concat({"# 3d-draw map 1", ("box x %d %d y %d %d z %d %d"):format(
                cx * 16, cx * 16 + 15, BOX.y[1] + AY, BOX.y[2] + AY, cz * 16, cz * 16 + 15),
                "palette 1 minecraft:stone 0 1.50 seen", table.concat(rows, "\n")}, "\n") .. "\n")
            f:close()
        end
    end
    vc.route_load("test_run", -1, 0, -1, 1, 0, AY, 0, "")
    require("route").loaded = true
    for _, st in ipairs(me.stations) do
        local i = st.INTERFACE
        vc.route_set(i[1], i[2], i[3], 2)
    end
end

-- The plan: rows of four along x at y -1, z 5 to 5 + 2 * (ROWS / 2 - 1), two sites (x 5 and
-- x -10), cobblestone and stone in turn - every builder and both stations at work.
local ROWS = 16
local KINDS = {{"minecraft:cobblestone", 0}, {"minecraft:stone", 0}}
local function plan()
    local ps, order = {}, {}
    for i = 0, ROWS - 1 do
        local z, x0 = 5 + 2 * (i // 2), i % 2 == 0 and 5 or -10
        local id = ("place %d -1 %d"):format(x0, z)
        local p = {id = id, kind = "place", cells = {}, steps = {}, waits = {}, box = {i % 2, 0, i}}
        for x = x0, x0 + 3 do
            local k = x .. ",-1," .. z
            p.cells[#p.cells + 1] = k
            p.steps[#p.steps + 1] = {k = k, act = "place", block = KINDS[i % 2 + 1]}
        end
        ps[id], order[#order + 1] = p, id
    end
    -- and glass the ME has none of until GLASS_AT, put in by hand then (as the user put chests
    -- and trapdoors in): the crew must see it, and the robots refused meanwhile go home
    local gid = "place 9 -1 21"
    ps[gid] = {id = gid, kind = "place", cells = {"9,-1,21", "10,-1,21"}, waits = {},
               box = {2, 0, 0}, steps = {
                   {k = "9,-1,21", act = "place", block = {"minecraft:glass", 0}},
                   {k = "10,-1,21", act = "place", block = {"minecraft:glass", 0}}}}
    order[#order + 1] = gid
    -- a stair rising east whose one stand, west of it, is grass: dug, the stair placed from
    -- there clicking the ground under it, the grass put back from above
    local sid = "place 12 -1 25"
    ps[sid] = {id = sid, kind = "place", cells = {"12,-1,25"}, waits = {}, box = {3, 0, 0},
               steps = {
                   {k = "11,-1,25", act = "dig", block = {"minecraft:grass", 0}, putback = true},
                   {k = "12,-1,25", act = "place", block = {"minecraft:dark_oak_stairs", 0},
                    dir = "e", face = "d"},
                   {k = "11,-1,25", act = "place", block = {"minecraft:grass", 0}, dir = "d",
                    face = "d", putback = true}}}
    order[#order + 1] = sid
    return {packets = ps, order = order}
end
local GLASS_AT = 150               -- the sim's seconds after the start the glass is put in

-- Blocks the world has and the map does not (the field's map is never whole): on the ways
-- between the station and the sites, at the heights the routes fly.
local HIDDEN = {{-4, 0, 3}, {-4, 1, 4}, {-3, 2, 6}}
for z = 2, 12 do                          -- a wall two high across the way to the east site
    HIDDEN[#HIDDEN + 1] = {3, 0, z}
    HIDDEN[#HIDDEN + 1] = {3, 1, z}
end

-- ---- the ME's computer, a stand-in -------------------------------------------------------------

-- Answers as robot/me_machine.lua: config (plain on the first interface, `at <addr>` on either),
-- items, ifaces; each ask ME_S long, one at a time (me.ask's own turn). A configured slot is kept
-- stocked in the simulated world's interface - the interface pulls from the network every tick.
local function fake_me(w)
    local cfg = {[A1] = {}, [A2] = {}}
    local cell = {[A1] = me.stations[1].INTERFACE, [A2] = me.stations[2].INTERFACE}
    local function restock()
        for addr, slots in pairs(cfg) do
            local i = cell[addr]
            local c = w.containers[i[1] .. "," .. i[2] .. "," .. i[3]]
            for s = 1, 9 do
                local want = slots[s]
                if want then
                    c[s] = {name = want[1], meta = want[2], count = want[3]}
                elseif s ~= me.RETURN then
                    c[s] = nil
                end
            end
        end
    end
    local function ask(cmd)
        vc.net_sleep_ms(ME_S * 1000)
        local addr = A1
        local a, rest = cmd:match("^at (%S+) (.*)$")
        if a then
            for full in pairs(cfg) do if full:sub(1, #a) == a then addr = full end end
            cmd = rest
        end
        local verb, args = cmd:match("^(%S+)%s*(.*)$")
        if verb == "config" then
            local t = {}
            for v in args:gmatch("%S+") do t[#t + 1] = v end
            local i = 1
            while i <= #t do
                local s = tonumber(t[i])
                if t[i + 1] == "-" then
                    cfg[addr][s], i = nil, i + 2
                else
                    cfg[addr][s] = {t[i + 1], tonumber(t[i + 2]), tonumber(t[i + 3])}
                    i = i + 4
                end
            end
            restock()
            return true, ""
        elseif verb == "items" then
            local glass = vc.app_time() >= (GLASS_T0 or math.huge) + GLASS_AT
                    and ";minecraft:glass:0:64" or ""
            return true, "minecraft:cobblestone:0:100000;minecraft:stone:0:100000"
                    .. ";minecraft:dark_oak_stairs:0:64;minecraft:grass:0:64" .. glass
        elseif verb == "ifaces" then
            local out = {}
            for _, ad in ipairs({A2, A1}) do
                local s = {}
                for n = 1, 9 do
                    local c = cfg[ad][n]
                    s[n] = c and ("%s:%d:%d"):format(c[1], c[2], c[3]) or "-"
                end
                out[#out + 1] = ad .. (ad == A1 and " first " or " ") .. table.concat(s, ",")
            end
            return true, table.concat(out, ";")
        end
        return true, ""
    end
    return ask, restock
end

-- ---- the relay, a stand-in ---------------------------------------------------------------------

-- What robots.lua's life asks of a relay connection: the computers, attach, a zone opened (the
-- robot's code: here machine.lua's M.serve over the robot's simbot body), lines both ways,
-- close. A zone's op paces by the sim's clock and catches up after the program stood still -
-- the robot did not stand still with it. Closed, the zone ends and its machine is lost, as when
-- the robot's connector leaves; the body stays where it is.
local function fake_relay(bodies, stats)
    local Conn = {}
    Conn.__index = Conn
    function Conn:computers()
        local out = {}
        for prefix in pairs(bodies) do out[#out + 1] = prefix .. "-0000-sim" end
        return out
    end
    function Conn:attach(addr)
        self.body = bodies[addr:sub(1, 8)]
        return self.body ~= nil
    end
    function Conn:open_zone(name, code)
        local b, c = self.body, self
        c.inbox, c.out = "", {}
        local next_t = vc.app_time()
        local z = {}
        function z.send(text)
            for line in text:gmatch("([^\n]*)\n") do c.out[#c.out + 1] = line end
        end
        function z.wait(t)
            if c.closed then error("closed", 0) end
            -- at its park, beside the chargers, a robot charges (2000 a wait)
            local pk = b.park
            if pk and b.x == pk[1] and b.y == pk[2] and b.z == pk[3] then
                b.energy = math.min(b.max, b.energy + 2000)
            end
            if t == 0 then                       -- an op done: its time, or caught up
                next_t = next_t + OP_S
                local now = vc.app_time()
                if now < next_t then vc.net_sleep_ms((next_t - now) * 1000) else next_t = now end
            else
                local until_t = vc.app_time() + math.min(t, 3600)
                while c.inbox == "" and not c.closed and vc.app_time() < until_t do
                    vc.net_sleep_ms(50)
                end
                next_t = vc.app_time()
            end
            if c.closed then error("closed", 0) end
            local s = c.inbox
            c.inbox = ""
            return s
        end
        local m = machine.new(b.hw, {x = b.x, y = b.y, z = b.z, facing = b.facing})
        spawn(function()
            local ok, err = pcall(machine.serve, z, m)
            if not ok and err ~= "closed" then stats.zone_errors[#stats.zone_errors + 1] = err end
        end)
        return true
    end
    function Conn:send_line(text)
        if self.closed then return nil, "closed" end
        self.inbox = (self.inbox or "") .. text .. "\n"
        return true
    end
    function Conn:read_line()
        while true do
            if self.out and #self.out > 0 then return table.remove(self.out, 1) end
            if self.closed then return nil, "closed" end
            vc.net_sleep_ms(20)
        end
    end
    function Conn:close() self.closed = true end
    return function() return setmetatable({}, Conn) end
end

-- ---- the run ------------------------------------------------------------------------------------

local function run_test()
    local stats = {zone_errors = {}}
    crew.paths = {done = "test_run/crewsim-done.txt", world = "test_run/crewsim-world.txt"}
    for _, p in pairs(crew.paths) do io.open(p, "w"):close() end
    view.anchor = view.anchor or {0, 0, 0}

    -- the world, the copies' world beside it, the grid
    local blocks, cw = {}, copy.world()
    local kept_cells = {}
    for x = BOX.x[1], BOX.x[2] do
        for y = BOX.y[1], BOX.y[2] do
            for z = BOX.z[1], BOX.z[2] do
                local k = x .. "," .. y .. "," .. z
                kept_cells[k] = {rawget(cw.blocks, k), cw.containers[k]}
                local b = TERRAIN[k] or solid(x, y, z) and {"minecraft:stone", 0} or nil
                blocks[k] = b
                cw.blocks[k] = b or false
                cw.containers[k] = nil
            end
        end
    end
    for _, h in ipairs(HIDDEN) do
        blocks[h[1] .. "," .. h[2] .. "," .. h[3]] = {"minecraft:stone", 0}
    end
    local w = simbot.world(blocks)
    -- a robot's afterimage where it just left, a moment - by the sim's clock, read when asked:
    -- the clock is warped after this
    w.afterimages = function() return vc.app_time() end
    for _, st in ipairs(me.stations) do
        local i = st.INTERFACE
        local slots = {sink = {[me.RETURN] = true}}
        w:add_container(i[1], i[2], i[3], slots)
        cw.blocks[i[1] .. "," .. i[2] .. "," .. i[3]] = {"minecraft:chest", 0}
    end
    load_grid()

    -- the robots: a body each at its park, linked through the stand-in relay - but Gunter, off
    -- the relay, standing where he was last seen, 0,1,0, in the station's ways (as he did live,
    -- two robots waiting on him for good, 2026-10-06)
    local bodies, kept_robots = {}, {}
    for _, r in ipairs(robots.order) do
        kept_robots[r.name] = {sf = r.sf, copy = r.copy, slots = r.slots, status = r.status,
                               diverged = r.diverged, linked = r.linked, last_pos = r.last_pos,
                               offline_mark = r.offline_mark}
        -- the low one away from its park: there it would charge while it is located (2000 a
        -- wait), and never be low when the loop first sees it free
        local p = r.name == OFFLINE and {0, 1, 0} or r.name == FAR_ONE and {-8, 0, 20}
                or r.name == LOW_ONE and {4, 0, -3} or r.park
        r.last_pos, r.offline_mark = r.name == OFFLINE and {0, 1, 0} or nil, nil
        bodies[r.prefix] = simbot.robot(w, {x = p[1], y = p[2], z = p[3], facing = "n",
                                           energy = r.name == LOW_ONE and 12000 or 40000,
                                           max = 40500, name = r.name,
                                           slots = r.name == FAR_ONE and {[5] = {
                                               name = "minecraft:cobblestone", meta = 0,
                                               count = 20}} or nil})
        bodies[r.prefix].park = r.park
        r.sf, r.copy, r.slots, r.diverged, r.status = nil, nil, nil, nil, {}
    end
    local kept = {open = relay.open, ask = me.ask, conn = me.conn, phase = me.phase,
                  view = me.view, run = packets.run, result = packets.result,
                  jobs = crew.jobs, owner = crew.me_owner, queue = crew.me_queue,
                  replan = crew.REPLAN_S, st = {}}
    -- the stations' whole state, given back after: what each stocks and has to clear too (left
    -- over, they broke test_stations, which runs after this one)
    local function copy_of(t) local c = {} for k, v in pairs(t or {}) do c[k] = v end return c end
    for n, st in ipairs(me.stations) do
        kept.st[n] = {addr = st.addr, owner = st.owner, stocked = copy_of(st.stocked),
                      to_clear = copy_of(st.to_clear)}
    end
    local clock = warp(true)
    local new_conn = fake_relay(bodies, stats)
    relay.open = function() return new_conn() end
    local ask = fake_me(w)
    me.ask, me.conn, me.phase, me.view = ask, {}, "linked", nil
    for _, st in ipairs(me.stations) do st.addr, st.owner = nil, nil end
    me.learn_tries = 0
    crew.jobs, crew.me_owner, crew.me_queue, crew.done = {}, nil, {}, {}
    crew.plan_done, crew.plan_done_of = {}, nil
    local the_plan = plan()
    packets.result = the_plan
    packets.run = function()               -- the plan made again: the program stands still
        stats.plans = (stats.plans or 0) + 1
        local t = clock.time()                 -- the real clock: a busy wait, not a sleep
        while clock.time() - t < FREEZE_S do end
        packets.result = the_plan
    end

    local function finish(why)
        crew.run.stop = true
        for _ = 1, 300 do
            if crew.run.ended then break end
            vc.net_sleep_ms(1000)
        end
        for _, r in ipairs(robots.order) do robots.link(r.name, false) end
        vc.net_sleep_ms(2000)
        warp(false, clock)
        relay.open, me.ask, me.conn, me.phase, me.view = kept.open, kept.ask, kept.conn,
            kept.phase, kept.view
        packets.run, packets.result = kept.run, kept.result
        crew.jobs, crew.me_owner, crew.me_queue = kept.jobs, kept.owner, kept.queue
        for n, st in ipairs(me.stations) do
            local k = kept.st[n]
            st.addr, st.owner = k.addr, k.owner
            for slot in pairs(st.stocked) do st.stocked[slot] = nil end
            for slot, v in pairs(k.stocked) do st.stocked[slot] = v end
            for slot in pairs(st.to_clear) do st.to_clear[slot] = nil end
            for slot, v in pairs(k.to_clear) do st.to_clear[slot] = v end
        end
        for _, r in ipairs(robots.order) do
            local k = kept_robots[r.name]
            r.sf, r.copy, r.slots, r.status, r.diverged, r.linked = k.sf, k.copy, k.slots,
                k.status, k.diverged, k.linked
            r.last_pos, r.offline_mark = k.last_pos, k.offline_mark
        end
        for k, v in pairs(kept_cells) do
            cw.blocks[k] = v[1]
            cw.containers[k] = v[2]
        end
        return why
    end

    -- the crew's whole log (crew.log keeps only its last 12 lines)
    local full = {}
    setmetatable(crew.log, {__newindex = function(t, k, v)
        full[#full + 1] = ("%6.0f %s"):format(vc.app_time() - (stats.t0 or vc.app_time()), v)
        rawset(t, k, v)
    end})
    -- how many builders on a packet at once, and the stations used
    stats.most, stats.used = 0, {}
    spawn(function()
        while not stats.over do
            local n = 0
            for _, j in pairs(crew.jobs) do if j.phase == "the packet" then n = n + 1 end end
            -- nobody waits for the interface from away from the station (it holds its turn
            -- while it flies; Dalek_Sec's go-home at 0,0,19, 2026-10-06)
            for name, j in pairs(crew.jobs) do
                local r = robots.by[name]
                local q, sp = r and r.sf and r.sf.pos, me.stations[1].SPOT
                if j.phase == "waiting for the interface" and q and math.abs(q[1] - sp[1])
                        + math.abs(q[2] - sp[2]) + math.abs(q[3] - sp[3]) > 8 then
                    stats.far_wait = ("%s at %s"):format(name, table.concat(q, ","))
                end
            end
            stats.most = math.max(stats.most, n)
            for k, st in ipairs(me.stations) do if st.owner then stats.used[k] = true end end
            -- a builder idle away from its park: home, unless it works (Baymax kept at
            -- -6,16,51 while a trapdoor was short, 2026-10-06)
            stats.away = stats.away or {}
            for _, name in ipairs(crew.BUILDERS) do
                local r = robots.by[name]
                local sf = r and r.sf
                local at_park = sf and r.park and sf.pos[1] == r.park[1]
                        and sf.pos[2] == r.park[2] and sf.pos[3] == r.park[3]
                if sf and not crew.jobs[name] and not at_park
                        and (sf.state == "done" or sf.state == "idle") then
                    stats.away[name] = stats.away[name] or vc.app_time()
                    if vc.app_time() - stats.away[name] > 90 then
                        stats.kept_away = ("%s at %s"):format(name, table.concat(sf.pos, ","))
                    end
                else
                    stats.away[name] = nil
                end
            end
            if crew.me_owner then stats.used[1] = true end
            vc.net_sleep_ms(1000)
        end
    end)

    -- linked, every one; the loop
    for _, r in ipairs(robots.order) do
        if r.name ~= OFFLINE then robots.link(r.name, true) end
    end
    for _ = 1, 60 do
        local all = true
        for _, r in ipairs(robots.order) do
            if r.name ~= OFFLINE and not (r.sf and r.slots) then all = false end
        end
        if all then break end
        vc.net_sleep_ms(1000)
    end
    spawn(function()
        local ok, err = xpcall(crew.run_all, debug.traceback, crew.BUILDERS)
        if not ok then stats.loop_error = err end
    end)
    local t0 = vc.app_time()
    stats.t0 = t0
    GLASS_T0 = t0
    while vc.app_time() - t0 < LIMIT_S do
        vc.net_sleep_ms(5000)
        if stats.loop_error or (crew.run and crew.run.ended) then break end
    end

    -- the robots settled: none running (home after the plan)
    for _ = 1, 120 do
        local moving = false
        for _, r in ipairs(robots.order) do
            if r.sf and (r.sf.state == "run" or r.sf.state == "wait") then moving = true end
        end
        for _, r in ipairs(robots.order) do
            if robots.in_flight(r) then moving = true end
        end
        if not moving and not next(crew.jobs) then break end
        vc.net_sleep_ms(1000)
    end
    vc.net_sleep_ms(12000)                   -- the last status read, twice

    -- what came of it
    local st = crew.run or {}
    local problems = {}
    if stats.loop_error then problems[#problems + 1] = "the loop broke: " .. stats.loop_error end
    for _, e in ipairs(stats.zone_errors) do problems[#problems + 1] = "a zone broke: " .. e end
    for _, id in ipairs(the_plan.order) do
        if not crew.is_done(id) then problems[#problems + 1] = id .. " not done" end
    end
    for _, id in ipairs(the_plan.order) do
        for _, s in ipairs(the_plan.packets[id].steps) do
            local x, y, z = s.k:match("^(-?%d+),(-?%d+),(-?%d+)$")
            local b = w:get(tonumber(x), tonumber(y), tonumber(z))
            if not b or b[1] ~= s.block[1] then
                problems[#problems + 1] = "no block at " .. s.k
                break
            end
        end
    end
    -- the dug stand's stair the plan's way, the grass back in its stand
    local stair, back = w:get(12, -1, 25), w:get(11, -1, 25)
    if not (stair and stair[2] == 0 and back and back[1] == "minecraft:grass") then
        problems[#problems + 1] = ("dig and put back: stair %s, stand %s"):format(
            stair and (stair[1] .. ":" .. stair[2]) or "air", back and back[1] or "air")
    end
    for name, why in pairs(st.parked or {}) do
        problems[#problems + 1] = "parked " .. name .. ": " .. why
    end
    for id, why in pairs(st.left_out or {}) do
        problems[#problems + 1] = "left out " .. id .. ": " .. why
    end
    for _, c in ipairs(robots.closes) do
        if c.t >= t0 then problems[#problems + 1] = "the watchdog closed " .. c.name end
    end
    for _, r in ipairs(robots.order) do
        local b = bodies[r.prefix]
        if r.diverged then problems[#problems + 1] = r.name .. " diverged: " .. r.diverged.why end
        if r.sf and (r.sf.pos[1] ~= b.x or r.sf.pos[2] ~= b.y or r.sf.pos[3] ~= b.z) then
            problems[#problems + 1] = r.name .. " is not where its status says"
        end
    end
    stats.over = true
    setmetatable(crew.log, nil)
    if not stats.used[2] then problems[#problems + 1] = "the second station never used" end
    if stats.kept_away then
        problems[#problems + 1] = "idle away from its park over 90 s: " .. stats.kept_away
    end
    if stats.far_wait then
        problems[#problems + 1] = "waited for the interface far from it: " .. stats.far_wait
    end
    local charged = false
    for _, l in ipairs(full) do
        if l:find(LOW_ONE .. ": energy", 1, true) and l:find("home to charge", 1, true) then
            charged = true
        end
    end
    if not charged then problems[#problems + 1] = LOW_ONE .. ", low, never sent to charge" end
    if stats.most < 3 then
        problems[#problems + 1] = ("at most %d builders on a packet at once"):format(stats.most)
    end
    local note = ("%d started, %d finished, %d plans, %.0f s of the sim's time, at most %d"
                  .. " on a packet at once, stations %s %s"):format(st.started or 0,
        st.finished or 0, stats.plans or 0, vc.app_time() - t0, stats.most,
        tostring(stats.used[1]), tostring(stats.used[2]))
    -- the state at the end, for a run that stalls: the loop's note, every job, every robot,
    -- the locks
    local state = {"--- at the end: note " .. tostring(st.note) .. ", ended "
                   .. tostring(st.ended) .. ", loop error " .. tostring(stats.loop_error)}
    for name, j in pairs(crew.jobs) do
        state[#state + 1] = ("job %s: %s, phase %s, pid %s, since %.0f s"):format(name,
            tostring(j.p and j.p.id), tostring(j.phase), tostring(j.pid),
            vc.app_time() - (j.t0 or vc.app_time()))
    end
    for _, r in ipairs(robots.order) do
        local sf = r.sf or {}
        state[#state + 1] = ("robot %s: %s %s %s op %s at %s, div %s, in flight %s"):format(
            r.name, tostring(sf.id), tostring(sf.state), tostring(sf.why), tostring(sf.op),
            table.concat(sf.pos or {}, ","), tostring(r.diverged and r.diverged.why),
            tostring(robots.in_flight(r)))
    end
    state[#state + 1] = ("lock 1 %s, lock 2 %s, queue %s"):format(tostring(crew.me_owner),
        tostring(me.stations[2].owner), table.concat(crew.me_queue or {}, ","))
    -- a robot waiting: the cell its op steps into, and who stands there
    for _, r in ipairs(robots.order) do
        local sf, c = r.sf, r.copy
        local op = sf and sf.state == "wait" and c and c.m.prog and c.m.prog.ops[sf.op]
        local v = op and op.dir and machine.STEP_OF[op.dir]
        if v then
            local cell = {sf.pos[1] + v[1], sf.pos[2] + v[2], sf.pos[3] + v[3]}
            local there = "nobody"
            for _, o in ipairs(robots.order) do
                local p = o.sf and o.sf.pos
                if o ~= r and p and p[1] == cell[1] and p[2] == cell[2] and p[3] == cell[3] then
                    there = o.name .. " (" .. tostring(o.sf.state) .. ", job "
                            .. tostring(crew.jobs[o.name] and crew.jobs[o.name].phase) .. ")"
                end
            end
            local b = w:get(cell[1], cell[2], cell[3])
            state[#state + 1] = ("%s waits on %s: %s; the world has %s there"):format(r.name,
                table.concat(cell, ","), there, b and b[1] or "air")
        end
    end
    local gw = {}
    for name, e in pairs(crew.gw or {}) do gw[#gw + 1] = name .. " for " .. tostring(e.passer) end
    for name in pairs(crew.gw_moved or {}) do gw[#gw + 1] = name .. " moved" end
    state[#state + 1] = "give-way: " .. table.concat(gw, ", ")
    local text = table.concat({note, table.concat(problems, "\n"), table.concat(state, "\n"),
                               "--- the crew's log", table.concat(full, "\n")}, "\n") .. "\n"
    local f = io.open("test_run/crewsim-report.txt", "w")
    if f then f:write(text) f:close() end
    if #problems > 0 then                    -- a failing run's report kept apart
        -- one file a failing run, never written over: crewsim-failed-<n>.txt
        local n = 1
        while io.open(("test_run/crewsim-failed-%d.txt"):format(n), "r") do n = n + 1 end
        local g = io.open(("test_run/crewsim-failed-%d.txt"):format(n), "w")
        if g then g:write(text) g:close() end
    end
    if #problems > 0 then
        return finish(("crew sim (%s): %s"):format(note, table.concat(problems, "; ")))
    end
    return finish(nil)
end

return {run_test = run_test}
