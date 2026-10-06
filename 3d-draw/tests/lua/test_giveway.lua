--[[ Robots that wait on each other (scripts/giveway.lua, redesign/16-giveway.md): two robots
-- head on in a corridor, each waiting on the other for good (ASIMO and Dalek_Sec, 2026-10-06),
-- one gives way into a nook, the other passes, it comes back, and both programs end done with
-- their copies agreeing; the one on a packet keeps on, the one only moving gives way. Then one
-- waiting on a creature gives way to one behind it, and an idle one steps aside.
-- The robots are machine.lua on simbot in a world of their own, answering the PC's commands as
-- the robot's loop does; the PC's side is the real one: copies, robots.run, giveway.tick.
-- @date 2026-10-06 ]]

local vc = require("virt_composer")
local spawn = require("spawn")         -- spawns that keep their handle
local robots = require("robots")
local copy = require("copy")
local crew = require("crew")
local machine = require("machine")
local simbot = require("simbot")
local giveway = require("giveway")

-- The map: stone; at y 1 a corridor along z at x 10 (z 0 to 12), nooks beside it at 11 1 6,
-- 9 1 5 and 9 1 6; closed above at y 2.
local function solid(x, y, z)
    if y ~= 1 then return y <= 2 end
    if x == 10 and z >= 0 and z <= 12 then return false end
    if (x == 11 and z == 6) or (x == 9 and z == 5) or (x == 9 and z == 6) then return false end
    return true
end

-- The grid file (as test_crew's): the pathfinder's map of the same.
local function load_grid()
    local rows = {}
    for y = 0, 3 do
        local zs = {}
        for z = 0, 15 do
            local xs = {}
            for x = 0, 15 do xs[#xs + 1] = solid(x, y, z) and "1" or "0" end
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
end

-- The region of the copies' world the test uses: set to the map, and given back after.
local REGION = {x = {8, 12}, y = {0, 2}, z = {0, 13}}
local function each_cell(f)
    for x = REGION.x[1], REGION.x[2] do
        for y = REGION.y[1], REGION.y[2] do
            for z = REGION.z[1], REGION.z[2] do f(x, y, z) end
        end
    end
end

-- The field: real robots stepping in their own world, answering the PC's commands; status_fast
-- read now and then (the poll), each followed by its copy, as robots.lua's parse_sf does.
local function field(specs)
    local blocks = {}
    each_cell(function(x, y, z)
        if solid(x, y, z) then blocks[x .. "," .. y .. "," .. z] = {"minecraft:stone", 0} end
    end)
    local w = simbot.world(blocks)
    local cw = copy.world()
    each_cell(function(x, y, z)
        cw.blocks[x .. "," .. y .. "," .. z] = solid(x, y, z) and {"minecraft:stone", 0} or false
    end)
    local F = {w = w, recs = {}, stop = false}
    for _, s in ipairs(specs) do
        local b = simbot.robot(w, {x = s.pos[1], y = s.pos[2], z = s.pos[3], facing = s.facing,
                                   energy = 40000, max = 40500, name = s.name})
        local m = machine.new(b.hw, {x = b.x, y = b.y, z = b.z, facing = b.facing})
        local rec = {name = s.name, linked = true, outbox = {}, status = {}, results = {},
                     slots = {}, trail = {}, rid = 0, real = m,
                     sf = {id = "-", state = "idle", op = 1, pos = {s.pos[1], s.pos[2], s.pos[3]},
                           facing = s.facing, energy = 40000}}
        robots.by[s.name] = rec
        robots.order[#robots.order + 1] = rec
        F.recs[#F.recs + 1] = rec
    end
    local function poll(rec)
        local id, st, op, x, y, z, f, e, why = rec.real.status_fast():match(
            "^(%S+) (%S+) (%d+) (-?%d+) (-?%d+) (-?%d+) (%a) (%d+)%s*(.*)$")
        rec.sf = {id = id, state = st, op = tonumber(op), pos = {tonumber(x), tonumber(y),
                  tonumber(z)}, facing = f, energy = tonumber(e), why = why ~= "" and why or nil}
        copy.follow(rec)
    end
    spawn(function()
        local n = 0
        while not F.stop do
            n = n + 1
            for _, rec in ipairs(F.recs) do
                -- commands at once, as the robot reads its socket after every op
                while #rec.outbox > 0 do
                    local t = table.remove(rec.outbox, 1)
                    local cmd, id, text = t.cmd:match("^(%S+)%s+(%S+)%s*(.*)$")
                    local ok, why = rec.real[cmd](id, text)
                    t.head = ok and "1 ok 0" or ("1 err " .. tostring(why))
                end
                -- an op a beat; a wait tried again (the robot's loop)
                if n % 2 == 0 then
                    local m = rec.real
                    if m.state == "wait" then m.state = "run" end
                    if m.state == "run" then m.step() end
                end
                if n % 6 == 0 then poll(rec) end
            end
            vc.net_sleep_ms(10)
        end
    end)
    -- a program sent as robots.run sends one, without its dry run (the other is in the way)
    function F.start(rec, id, text, dest)
        assert(copy.start(rec, id, text))
        rec.dest = dest
        rec.outbox[#rec.outbox + 1] = {cmd = "exec " .. id .. " " .. text}
    end
    function F.done()
        F.stop = true
        for _ = 1, 5 do vc.net_sleep_ms(10) end
        for _, rec in ipairs(F.recs) do
            robots.by[rec.name] = nil
            for i = #robots.order, 1, -1 do
                if robots.order[i] == rec then table.remove(robots.order, i) end
            end
        end
    end
    return F
end

-- The PC's looks until `until_()` or `n` looks (600, about 6 s); true when it came, else nil and
-- why (a look that threw says so).
local function run_until(until_, n)
    for _ = 1, n or 600 do
        local ok, err = pcall(giveway.tick, {parked = {}})
        if not ok then return nil, "giveway.tick threw: " .. tostring(err) end
        if until_() then return true end
        vc.net_sleep_ms(10)
    end
    return nil, "not in time"
end

local function at(rec, x, y, z)
    local p = rec.real.pos
    return p[1] == x and p[2] == y and p[3] == z
end

local function logged(s)
    for _, l in ipairs(crew.log) do if l:find(s, 1, true) then return true end end
    return false
end

local function run_test()
    local saved = {giveway.WAIT, giveway.POLL_MS, giveway.PASS_S, giveway.REPLY_S,
                   giveway.REPLY_MS}
    giveway.WAIT, giveway.POLL_MS, giveway.PASS_S, giveway.REPLY_S, giveway.REPLY_MS =
        0, 10, 5, 5, 5
    local cw = copy.world()
    local was = {}
    each_cell(function(x, y, z)
        local k = x .. "," .. y .. "," .. z
        was[k] = rawget(cw.blocks, k)
    end)
    crew.gw, crew.gw_since, crew.log = {}, {}, {}
    load_grid()
    local why

    -- 1. head on: ASIMO's case. A south from 10 1 5 to 10 1 10; B north from 10 1 6 to 10 1 1,
    -- on its packet: A, only moving, gives way into its nook at 9 1 5 though B is later
    local F = field({{name = "GwA", pos = {10, 1, 5}, facing = "s"},
                     {name = "GwB", pos = {10, 1, 6}, facing = "n"}})
    local A, B = F.recs[1], F.recs[2]
    F.start(A, "pa", "$0 v5", {10, 1, 10})
    F.start(B, "pb", "$0 ^5", {10, 1, 1})
    crew.jobs.GwB = {p = {id = "test packet", cells = {}, steps = {}}, what = "the packet",
                     pid = "pb"}
    -- both wait on each other first
    for _ = 1, 30 do vc.net_sleep_ms(10) end
    if A.real.state ~= "wait" or B.real.state ~= "wait" then
        why = "the two did not meet head on: " .. A.real.state .. " " .. B.real.state
    end
    local fine, how
    if not why then
        fine, how = run_until(function()
            return A.sf.state == "done" and B.sf.state == "done" and not next(crew.gw)
        end)
    end
    crew.jobs.GwB = nil
    if not why and not fine then
        why = ("head on not resolved (%s): A %s %s at %s, B %s %s at %s; %s"):format(how,
            A.sf.id,
            A.sf.state, table.concat(A.real.pos, " "), B.sf.id, B.sf.state,
            table.concat(B.real.pos, " "), table.concat(crew.log, " | "))
    end
    if not why and not (at(A, 10, 1, 10) and at(B, 10, 1, 1)) then
        why = "head on: not at their ends"
    end
    if not why and (A.sf.id ~= "pa" or B.sf.id ~= "pb") then
        why = "head on: the programs ended are not their own: " .. A.sf.id .. " " .. B.sf.id
    end
    if not why and (A.diverged or B.diverged) then
        why = "head on: a copy diverged: " .. tostring((A.diverged or B.diverged).why)
    end
    if not why and not (tostring(A.matched):find("^pa:") and tostring(B.matched):find("^pb:")) then
        why = "head on: the copies not agreeing at the end"
    end
    if not why and not logged("GwA gives way (<) to GwB") then
        why = "head on: the one on its packet gave way: " .. table.concat(crew.log, " | ")
    end
    F.done()

    -- 2. B waits on a creature at 10 1 5; A behind it, at 10 1 7, means through B's cell to the
    -- nook at 11 1 6: B gives way (west, off A's way), A passes, B comes back and waits on
    if not why then
        crew.gw, crew.gw_since, crew.log = {}, {}, {}
        F = field({{name = "GwA", pos = {10, 1, 7}, facing = "n"},
                   {name = "GwB", pos = {10, 1, 6}, facing = "n"}})
        A, B = F.recs[1], F.recs[2]
        F.w:add_entity(10, 1, 5)
        cw.entities["10,1,5"] = true
        F.start(B, "pb2", "$0 ^5", {10, 1, 1})
        F.start(A, "pa2", "$0 ^ >", {11, 1, 6})
        fine, how = run_until(function()
            return A.sf.state == "done" and B.sf.id == "pb2" and B.sf.state == "wait"
                and at(B, 10, 1, 6) and not next(crew.gw)
        end)
        if not fine then
            why = ("on a creature: not given way (%s): A %s %s, B %s %s at %s; %s"):format(how,
                A.sf.id,
                A.sf.state, B.sf.id, B.sf.state, table.concat(B.real.pos, " "),
                table.concat(crew.log, " | "))
        end
        F.w:remove_entity(10, 1, 5)
        cw.entities["10,1,5"] = nil
        if not why and not run_until(function() return B.sf.state == "done" end) then
            why = "on a creature: B did not go on once it left"
        end
        if not why and not (at(A, 11, 1, 6) and at(B, 10, 1, 1)) then
            why = "on a creature: not at their ends"
        end
        if not why and (A.diverged or B.diverged) then
            why = "on a creature: a copy diverged: " .. tostring((A.diverged or B.diverged).why)
        end
        F.done()
    end

    -- 3. B idle at 10 1 6 in A's way north: it steps aside into its nook and stays
    if not why then
        crew.gw, crew.gw_since, crew.log = {}, {}, {}
        F = field({{name = "GwA", pos = {10, 1, 8}, facing = "n"},
                   {name = "GwB", pos = {10, 1, 6}, facing = "n"}})
        A, B = F.recs[1], F.recs[2]
        for _ = 1, 10 do vc.net_sleep_ms(10) end
        F.start(A, "pa3", "$0 ^4", {10, 1, 4})
        fine, how = run_until(function() return A.sf.state == "done" end)
        if not fine then
            why = "an idle one in the way: " .. tostring(how) .. "; "
                .. table.concat(crew.log, " | ")
        elseif not at(A, 10, 1, 4) or not at(B, 11, 1, 6) then
            why = ("an idle one in the way not moved: A %s %s, B at %s; %s"):format(A.sf.id,
                A.sf.state, table.concat(B.real.pos, " "), table.concat(crew.log, " | "))
        end
        -- moved once: its status older than the move had it sent again and again, from where
        -- it no longer stood (the first run of this test, 2026-10-06)
        local moves = 0
        for _, l in ipairs(crew.log) do
            if l:find("moved aside", 1, true) then moves = moves + 1 end
        end
        if not why and moves ~= 1 then why = ("an idle one moved aside %d times"):format(moves) end
        F.done()
    end

    -- 4. Baymax's case (2026-10-06): B stands at its park on a crew job only waiting in the
    -- interface's queue; A waits on it - it is moved; when the lock comes to it, lock_me lets
    -- the move end first, so its trip plans from where it stands now. A job in any other phase
    -- (here: taking at the spot) is not moved.
    if not why then
        crew.gw, crew.gw_since, crew.gw_moved, crew.log = {}, {}, {}, {}
        F = field({{name = "GwA", pos = {10, 1, 8}, facing = "n"},
                   {name = "GwB", pos = {10, 1, 6}, facing = "n"}})
        A, B = F.recs[1], F.recs[2]
        local me = require("me")
        local flush = me.flush
        me.flush = function() end
        crew.jobs.GwB = {p = {id = "test packet", cells = {}, steps = {}}, phase = "taking"}
        crew.me_owner, crew.me_queue = "Holder", {}
        crew.jobs.Holder = {p = {id = "held", cells = {}, steps = {}}}
        for _ = 1, 10 do vc.net_sleep_ms(10) end
        F.start(A, "pa4", "$0 ^4", {10, 1, 4})
        run_until(function() return false end, 30)
        if not at(B, 10, 1, 6) then why = "a robot taking at the spot was moved aside" end
        crew.jobs.GwB.phase = "waiting for the interface"
        crew.jobs.Holder = nil                      -- the lock free for B once it asks
        if not why then
            fine, how = run_until(function() return logged("GwB moved aside") end)
            if not fine then
                why = "a robot waiting for the lock not moved: " .. tostring(how) .. "; "
                    .. table.concat(crew.log, " | ")
            end
        end
        if not why then
            crew.lock_me("GwB")
            local p = B.sf.pos
            if not (p[1] == 11 and p[2] == 1 and p[3] == 6 and B.sf.state == "done") then
                why = ("the lock given before the move ended: B %s %s at %s"):format(B.sf.id,
                    B.sf.state, table.concat(p, " "))
            end
            crew.unlock_me("GwB")
        end
        if not why and not run_until(function() return A.sf.state == "done" end) then
            why = "A did not pass the robot moved out of its way"
        end
        crew.jobs.GwB, crew.jobs.Holder, crew.me_owner, crew.me_queue = nil, nil, nil, {}
        me.flush = flush
        F.done()
    end

    -- the rule alone: not on a packet first, then the later in the roster; none without a way
    if not why then
        local c = giveway.choose({{step = "e", packet = false, index = 1},
                                  {step = "w", packet = true, index = 2}})
        local d = giveway.choose({{step = "e", packet = false, index = 1},
                                  {step = "w", packet = false, index = 2}})
        local e = giveway.choose({{step = nil, packet = false, index = 1},
                                  {step = "w", packet = true, index = 2}})
        if c.index ~= 1 or d.index ~= 2 or e.index ~= 2
                or giveway.choose({{packet = false, index = 1}}) then
            why = "giveway.choose: not the rule of 16-giveway.md"
        end
    end

    each_cell(function(x, y, z)
        local k = x .. "," .. y .. "," .. z
        cw.blocks[k] = was[k]
    end)
    crew.gw, crew.gw_since = {}, {}
    giveway.WAIT, giveway.POLL_MS, giveway.PASS_S, giveway.REPLY_S, giveway.REPLY_MS =
        table.unpack(saved)
    return why
end

return {run_test = run_test}
