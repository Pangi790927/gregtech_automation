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
local function solid(x, y, z) return y <= -2 end
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
    return {packets = ps, order = order}
end

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
            return true, "minecraft:cobblestone:0:100000;minecraft:stone:0:100000"
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
                local b = solid(x, y, z) and {"minecraft:stone", 0} or nil
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
    for _, st in ipairs(me.stations) do
        local i = st.INTERFACE
        local slots = {sink = {[me.RETURN] = true}}
        w:add_container(i[1], i[2], i[3], slots)
        cw.blocks[i[1] .. "," .. i[2] .. "," .. i[3]] = {"minecraft:chest", 0}
    end
    load_grid()

    -- the robots: a body each at its park, linked through the stand-in relay
    local bodies, kept_robots = {}, {}
    for _, r in ipairs(robots.order) do
        kept_robots[r.name] = {sf = r.sf, copy = r.copy, slots = r.slots, status = r.status,
                               diverged = r.diverged, linked = r.linked}
        local p = r.park
        bodies[r.prefix] = simbot.robot(w, {x = p[1], y = p[2], z = p[3], facing = "n",
                                           energy = 40000, max = 40500, name = r.name})
        r.sf, r.copy, r.slots, r.diverged, r.status = nil, nil, nil, nil, {}
    end
    local kept = {open = relay.open, ask = me.ask, conn = me.conn, phase = me.phase,
                  view = me.view, run = packets.run, result = packets.result,
                  jobs = crew.jobs, owner = crew.me_owner, queue = crew.me_queue,
                  replan = crew.REPLAN_S, st = {}}
    for n, st in ipairs(me.stations) do kept.st[n] = {addr = st.addr, owner = st.owner} end
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
            st.addr, st.owner = kept.st[n].addr, kept.st[n].owner
        end
        for _, r in ipairs(robots.order) do
            local k = kept_robots[r.name]
            r.sf, r.copy, r.slots, r.status, r.diverged, r.linked = k.sf, k.copy, k.slots,
                k.status, k.diverged, k.linked
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
            stats.most = math.max(stats.most, n)
            for k, st in ipairs(me.stations) do if st.owner then stats.used[k] = true end end
            if crew.me_owner then stats.used[1] = true end
            vc.net_sleep_ms(1000)
        end
    end)

    -- linked, every one; the loop
    for _, r in ipairs(robots.order) do robots.link(r.name, true) end
    for _ = 1, 60 do
        local all = true
        for _, r in ipairs(robots.order) do if not (r.sf and r.slots) then all = false end end
        if all then break end
        vc.net_sleep_ms(1000)
    end
    spawn(function()
        local ok, err = xpcall(crew.run_all, debug.traceback, crew.BUILDERS)
        if not ok then stats.loop_error = err end
    end)
    local t0 = vc.app_time()
    stats.t0 = t0
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
    if stats.most < 3 then
        problems[#problems + 1] = ("at most %d builders on a packet at once"):format(stats.most)
    end
    local note = ("%d started, %d finished, %d plans, %.0f s of the sim's time, at most %d"
                  .. " on a packet at once, stations %s %s"):format(st.started or 0,
        st.finished or 0, stats.plans or 0, vc.app_time() - t0, stats.most,
        tostring(stats.used[1]), tostring(stats.used[2]))
    local f = io.open("test_run/crewsim-report.txt", "w")
    if f then
        f:write(note, "\n", table.concat(problems, "\n"), "\n--- the crew's log\n",
                table.concat(full, "\n"), "\n")
        f:close()
    end
    if #problems > 0 then
        return finish(("crew sim (%s): %s"):format(note, table.concat(problems, "; ")))
    end
    return finish(nil)
end

return {run_test = run_test}
