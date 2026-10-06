--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | Robots that wait on each other (3d-draw/redesign/16-giveway.md): seen, and one given way -
-- | out of the other's line, halted there, and back once it has passed - on the robot and its
-- | copy both, so the two stay in step. Used by the crew loop through require("live"), so the
-- | control port's `reload giveway` teaches it anew without stopping a trip.
-- |
-- |     giveway.tick(st)         one look at every linked robot (crew.run_all, each pass): a ring
-- |                              of robots waiting on each other, one waiting long on a robot that
-- |                              waits too, or on one standing still - resolved
-- |     giveway.choose(cands)    who of a ring gives way: {r, step, packet, index} each -> one
-- |     giveway.aside(r, avoid)  the step out of everyone's way beside r ("^" ">" "+" ...) or nil
-- |     giveway.catch_up(r)      r's copy stepped to where r stands; true when it is there
-- |     giveway.way_left(r, out) the cells r's program still goes through, into out
-- |
-- | Its state is the crew's (crew.gw, open give-ways by giver; crew.gw_since), so a reload of
-- | this file keeps the give-ways under way.
-- |
-- | @date 2026-10-06
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local spawn = require("spawn")         -- spawns that keep their handle
local robots = require("robots")
local copy = require("copy")
local machine = require("live")("machine")

local giveway = {
    WAIT = 12,              -- s on the same cell before a meeting counts (poll 5 s: seen by ~15)
    PASS_S = 60,            -- s the giver stays aside at most, the other passed or not
    BACK_S = 120,           -- s after the release before a give-way not back is given up on
    REPLY_S = 15,           -- s a robot has to answer a give_way
    REPLY_MS = 100,         -- between looks for its answer
    POLL_MS = 1000,         -- between looks, while a give-way is under way
}

local CH = {n = "^", s = "v", e = ">", w = "<", u = "+", d = "-"}
local BACK = {n = "s", s = "n", e = "w", w = "e", u = "d", d = "u"}
local DIRS = {"n", "s", "e", "w", "u", "d"}

local function crew() return require("crew") end

local function key(x, y, z) return x .. "," .. y .. "," .. z end

-- A line in the crew's log, as crew.lua's own say does (its say, when it offers one).
local function say(s)
    local c = crew()
    if c.say then return c.say(s) end
    c.log[#c.log + 1] = s
    if #c.log > 12 then table.remove(c.log, 1) end
end

local ids = 0
-- A give-way program's id, apart from robots.run's "p<n>": the leg's patch and `still` know a
-- robot giving way by it.
local function next_id()
    ids = ids + 1
    return ("gw%d"):format(ids)
end

local function same(p, q) return p and q and p[1] == q[1] and p[2] == q[2] and p[3] == q[3] end

--[[ r's copy stepped up to where r stands: the same program, the same op, the same cell - within
-- an op of many steps too (copy.follow steps only to the op's start, so a copy lags its robot by
-- up to an op's steps; a give-way stacks the op with its steps left, so they must agree). A copy
-- waiting in the copies' world is tried again as the robot's loop does. -> true when there. ]]
function giveway.catch_up(r)
    local c, sf = r.copy, r.sf
    if not (c and c.m and c.m.prog and sf) or c.m.id ~= sf.id then return false end
    local m = c.m
    for _ = 1, 10000 do
        local here = c.b.x == sf.pos[1] and c.b.y == sf.pos[2] and c.b.z == sf.pos[3]
        if m.pc > sf.op or (m.pc == sf.op and here) then break end
        if m.state == "wait" then m.state = "run" end
        if m.state ~= "run" then break end
        local op = m.prog.ops[m.pc]
        if m.pc == sf.op and op.k ~= "step" then break end    -- not a step: it cannot move on
        m.step()
        if m.state == "wait" then break end
    end
    return m.pc == sf.op and c.b.x == sf.pos[1] and c.b.y == sf.pos[2] and c.b.z == sf.pos[3]
end

--[[ The cells r's program still goes through, from its copy: the ops from its op on, then the
-- programs stacked under a give-way, each from where it was put aside. Into `out` (keys), with
-- where it stands and where it ends. A copy behind its robot gives a few cells already passed
-- too - kept off as well, which is only careful. ]]
function giveway.way_left(r, out)
    out = out or {}
    local sf = r.sf
    if sf then out[key(sf.pos[1], sf.pos[2], sf.pos[3])] = true end
    if r.dest then out[key(r.dest[1], r.dest[2], r.dest[3])] = true end
    local c = r.copy
    if not (c and c.m and c.m.prog and sf) or c.m.id ~= sf.id then return out end
    local m = c.m
    local x, y, z = c.b.x, c.b.y, c.b.z
    local function walk(prog, pc, left)
        for i = pc, #prog.ops do
            local op = prog.ops[i]
            if op.k == "step" then
                local d = machine.STEP_OF[op.dir]
                for _ = 1, (i == pc and left > 0) and left or op.n do
                    x, y, z = x + d[1], y + d[2], z + d[3]
                    out[key(x, y, z)] = true
                end
            end
        end
    end
    if m.state == "run" or m.state == "wait" or m.state == "halt" then
        walk(m.prog, m.pc, m.left)
    end
    for i = #(m.stack or {}), 1, -1 do
        local s = m.stack[i]
        walk(s.prog, s.pc, s.left or 0)
    end
    return out
end

--[[ What every robot but `except` (names) keeps others off: where each linked robot stands and
-- ends, the way its program still goes, and the cells of the packets being worked (crew.jobs);
-- and the interfaces' spots - a robot moved aside stays, and on a spot it shuts that station
-- (17-stations.md). A cell aside taken from this never lies on the way of the one passing, nor
-- of any other. ]]
local function kept_off(except)
    local a = {}
    for _, st in ipairs(require("me").stations or {}) do
        a[key(st.SPOT[1], st.SPOT[2], st.SPOT[3])] = true
    end
    for _, o in ipairs(robots.order) do
        if o.linked and o.sf and not except[o.name] then giveway.way_left(o, a) end
    end
    for name, j in pairs(crew().jobs or {}) do
        if not except[name] and j.p then
            for _, k in ipairs(j.p.cells or {}) do a[k] = true end
            for _, st in ipairs(j.p.steps or {}) do a[st.k] = true end
        end
    end
    return a
end
giveway.kept_off = kept_off                                        -- for the tests

-- Free for a robot to stop in: air in the map (nothing to break), empty in the copies' world,
-- no creature, not kept off, and not right above farmland (a robot stopping there tramples it).
local function free(x, y, z, avoid)
    if avoid[key(x, y, z)] then return false end
    if vc.route_get(x, y, z) ~= 1 then return false end
    local w = copy.world()
    if w:get(x, y, z) or w.entities[key(x, y, z)] then return false end
    local below = w:get(x, y - 1, z)
    if below and below[1] == "minecraft:farmland" then return false end
    return true
end

--[[ The step aside for r, out of everyone's way (`avoid`, kept_off): across its line first (the
-- line being `along`, the direction it or the other moves in, when known), then up, then down,
-- then the rest. -> the direction ("n" ... "d") or nil. ]]
function giveway.aside(r, avoid, along)
    local p = r.sf.pos
    local order = {}
    local function add(d) for _, e in ipairs(order) do if e == d then return end end
                          order[#order + 1] = d end
    if along == "n" or along == "s" then add("e"); add("w")
    elseif along == "e" or along == "w" then add("n"); add("s")
    else add("e"); add("w"); add("n"); add("s") end
    add("u"); add("d")
    for _, d in ipairs(DIRS) do add(d) end
    for _, d in ipairs(order) do
        local s = machine.STEP_OF[d]
        if free(p[1] + s[1], p[2] + s[2], p[3] + s[3], avoid) then return d end
    end
end

--[[ Who of a ring gives way (16-giveway.md): of those with a step aside, the one not on a packet
-- (only moving: home, to the station, giving back); else the later in the roster. `cands`:
-- {r, step (nil: no way aside), packet (true: on its packet's program), index (in the roster)}.
-- -> the chosen one, or nil when none can. ]]
function giveway.choose(cands)
    local best
    for _, c in ipairs(cands) do
        if c.step then
            if not best then best = c
            elseif (best.packet and not c.packet)
                    or (best.packet == c.packet and c.index > best.index) then
                best = c
            end
        end
    end
    return best
end

-- On its packet's own program (crew.trip's leg "the packet"), not only moving.
local function on_packet(r)
    local j = crew().jobs[r.name]
    return j and j.what == "the packet" and j.pid ~= nil and r.sf.id == j.pid or false
end

-- A robot's ticket answered within REPLY_S: true when "ok".
local function answered_ok(t)
    for _ = 1, giveway.REPLY_S * 1000 // giveway.REPLY_MS do
        if t.head then break end
        vc.net_sleep_ms(giveway.REPLY_MS)
    end
    return t.head ~= nil and t.head:match("^%S+ ok") ~= nil, t.head
end

-- The copy run while it runs, at most n ops, and while `more()` says so.
local function run_copy(m, more)
    for _ = 1, 200 do
        if m.state == "wait" then m.state = "run" end
        if m.state ~= "run" or (more and not more()) then break end
        m.step()
        if m.state == "wait" then break end
    end
end

--[[ The copy of a giver brought back into its robot's program after the release: the turn, the
-- step back, then held at the op the robot waited at (it goes on by copy.follow). A step back
-- the copies' world still holds is tried again later (the caller loops). ]]
local function copy_back(g, orig)
    local m = g.copy and g.copy.m
    if not m or m.id == orig then return true end
    run_copy(m, function() return m.id ~= orig end)
    return m.id == orig
end

--[[ One give-way, on a coroutine of its own: g steps `dir` aside and halts there, p (the one
-- waiting on it) passes, g is let go and steps back into its own program (16-giveway.md). The
-- robot first; its copy only once the robot said ok, so a robot that had moved on by then
-- (`err not waiting`) leaves its copy as it was. ]]
local function give_way(g, p, dir)
    local orig, from, pp = g.sf.id, {table.unpack(g.sf.pos)}, {table.unpack(p.sf.pos)}
    local e = {passer = p.name, orig = orig, step = CH[dir], t0 = vc.app_time(), phase = "out"}
    crew().gw[g.name] = e
    -- the end of it: both waits counted anew, so one not passed is not given way again at once
    local function close(why)
        if why then say(("%s: give-way for %s ended: %s"):format(g.name, p.name, why)) end
        local c = crew()
        c.gw[g.name] = nil
        if c.gw_since then c.gw_since[g.name], c.gw_since[p.name] = nil, nil end
    end
    spawn(function()
        local id1 = next_id()
        local text1 = ("$0 %s h %s"):format(CH[dir], CH[BACK[dir]])
        e.id1 = id1
        local ok, head = answered_ok(robots.send(g.name, "give_way " .. id1 .. " " .. text1))
        if not ok then return close("the robot said " .. tostring(head)) end
        say(("%s gives way (%s) to %s"):format(g.name, CH[dir], p.name))
        -- the copy the same: at the op it waited at, as the robot
        local m = g.copy.m
        if m.state == "run" then m.state, m.why = "wait", "robot" end
        local cok, cwhy = m.give_way(id1, text1)
        if cok then run_copy(m) end
        if not cok or m.state ~= "halt" then
            say(("%s: its copy did not step aside with it: %s %s"):format(g.name,
                tostring(cwhy or m.state), tostring(m.why)))
        end
        -- out: until the robot halts aside
        e.phase = "out"
        while true do
            vc.net_sleep_ms(giveway.POLL_MS)
            local sf = g.sf
            if not g.linked then return close("its link went") end
            if sf.id == id1 and sf.state == "halt" then break end
            if sf.id == id1 and sf.state == "stop" then
                return close("stopped stepping aside: " .. tostring(sf.why))
            end
            if sf.id ~= id1 and sf.id ~= orig then return close("sent another program") end
        end
        -- aside: until the other has passed, or PASS_S
        e.phase, e.halted = "aside", vc.app_time()
        while vc.app_time() - e.halted < giveway.PASS_S do
            local q = p.sf
            if not p.linked or not q or (q.state ~= "run" and q.state ~= "wait")
                    or not (same(q.pos, pp) or same(q.pos, from)) then
                break
            end
            vc.net_sleep_ms(giveway.POLL_MS)
        end
        if g.sf.id ~= id1 or g.sf.state ~= "halt" then return close("no longer halted aside") end
        -- back: the one passing has its copy where it stands, so the giver's copy can step back
        giveway.catch_up(p)
        local id2 = next_id()
        local text2 = "$0 f" .. CH[g.sf.facing]
        e.phase, e.id2 = "back", id2
        ok, head = answered_ok(robots.send(g.name, "give_way " .. id2 .. " " .. text2))
        if not ok then return close("the robot, let go, said " .. tostring(head)) end
        -- its copy to its halt aside first, if the copies' world had held it up on the way out
        if m.id == id1 then run_copy(m) end
        if m.state == "halt" and m.id == id1 then m.give_way(id2, text2) end
        local t = vc.app_time()
        while vc.app_time() - t < giveway.BACK_S do
            local back = copy_back(g, orig)
            local sid = g.sf.id
            -- back in its program - or past it, a next program begun before this look
            if back and sid ~= id1 and sid ~= id2 then
                say(("%s back on its way, %s passed"):format(g.name, p.name))
                return close()
            end
            if g.sf.state == "stop" then return close("stopped: " .. tostring(g.sf.why)) end
            vc.net_sleep_ms(giveway.POLL_MS)
        end
        close("not back in its program after " .. giveway.BACK_S .. " s")
    end)
end

--[[ A robot standing still that may be moved for another: on no crew job, or on one only
-- waiting in the interface's queue - not holding the lock (Pintsize, third in the queue at her
-- park, held Baymax's packet up for minutes, 2026-10-06). Its trip reads where it stands once
-- the lock is its own, after giveway.settle. Any other phase of a job (at the spot, taking,
-- giving back, looking round) counts on where it stands: not moved. ]]
local function movable_job(o)
    local j = crew().jobs[o.name]
    if not j then return true end
    return j.phase == "waiting for the interface" and not crew().holds_me(o.name)
end
giveway.movable_job = movable_job

--[[ Called once a robot has the interface's lock (crew.lock_me), before its trip reads where it
-- stands: a move aside sent while it waited is let finish and show in its status first - a
-- status older than the move would plan its way to the spot from the cell it left. 15 s at most. ]]
function giveway.settle(name)
    local mv = (crew().gw_moved or {})[name]
    local r = robots.by[name]
    if not mv or not r then return end
    for _ = 1, 150 do
        local sf = r.sf
        if not r.linked or (sf and sf.id == mv.pid and sf.state ~= "run" and sf.state ~= "wait")
                then
            break
        end
        vc.net_sleep_ms(100)
    end
    crew().gw_moved[name] = nil
end

-- Its index in the roster, for "the later one".
local function index_of(r)
    for i, o in ipairs(robots.order) do if o == r then return i end end
    return 0
end

--[[ One look (crew.run_all, each pass; 16-giveway.md "Seen"). Every linked robot in `wait robot`
-- on the same cell for WAIT s: a ring of them - one gives way; on one waiting long on something
-- else - that one gives way; on one standing still with no crew job - it moves aside and stays.
-- `st`: the crew loop's state (its parked robots are left alone). ]]
function giveway.tick(st)
    local c = crew()
    c.gw = c.gw or {}
    c.gw_since = c.gw_since or {}
    local since, now = c.gw_since, vc.app_time()
    local at, waits, on = {}, {}, {}
    for _, o in ipairs(robots.order) do
        if o.linked and o.sf then
            local p = o.sf.pos
            at[key(p[1], p[2], p[3])] = o
        end
    end
    -- how long each has waited where it is, and on whom (its copy's op: the cell it steps into)
    for _, o in ipairs(robots.order) do
        local sf = o.sf
        if o.linked and sf and sf.state == "wait" then
            local cell
            local cm = o.copy and o.copy.m
            local op = cm and cm.prog and cm.id == sf.id and cm.prog.ops[sf.op]
            local d = op and op.dir and machine.STEP_OF[op.dir]
            if d then cell = key(sf.pos[1] + d[1], sf.pos[2] + d[2], sf.pos[3] + d[3]) end
            local mark = table.concat({sf.id, sf.op, key(sf.pos[1], sf.pos[2], sf.pos[3]),
                                       tostring(sf.why)}, " ")
            local s = since[o.name]
            if not s or s.mark ~= mark then
                s = {mark = mark, t = now}
                since[o.name] = s
            end
            waits[o.name] = now - s.t
            if sf.why == "robot" and cell and at[cell] and at[cell] ~= o then
                on[o.name] = at[cell]
            end
        else
            since[o.name] = nil
        end
    end
    local busy = {}
    for name, e in pairs(c.gw) do busy[name], busy[e.passer] = true, true end
    -- one moved aside is left alone until its status shows the move ended (30 s at most): a
    -- status older than the move had it sent again, from where it no longer stood
    c.gw_moved = c.gw_moved or {}
    for name, mv in pairs(c.gw_moved) do
        local o = robots.by[name]
        local sf = o and o.sf
        local ended = sf and sf.id == mv.pid and sf.state ~= "run" and sf.state ~= "wait"
        if sf and not ended and now - mv.t < 30 then busy[name] = true
        else c.gw_moved[name] = nil end
    end
    for _, a in ipairs(robots.order) do
        local b = on[a.name]
        if b and not busy[a.name] and not busy[b.name] and waits[a.name] >= giveway.WAIT then
            -- the chain from a: a ring when it comes back to one in it
            local chain, seen, cur = {a}, {[a] = 1}, b
            while cur and not seen[cur] and on[cur.name] do
                chain[#chain + 1] = cur
                seen[cur] = #chain
                cur = on[cur.name]
            end
            if cur and seen[cur] then
                local ring = {}
                for i = seen[cur], #chain do ring[#ring + 1] = chain[i] end
                -- every copy of the ring where its robot stands first, so the ways left are
                -- read from where they are
                local taken, cands, there = false, {}, {}
                for _, r in ipairs(ring) do
                    if busy[r.name] then taken = true end
                    there[r] = giveway.catch_up(r)
                end
                for i, r in ipairs(ring) do
                    -- the one waiting on r is the one that passes; kept off: all but r
                    local passer = ring[(i - 2) % #ring + 1]
                    local okc = there[r] and not r.diverged and #r.outbox == 0
                    local step = okc and giveway.aside(r, kept_off({[r.name] = true}),
                                                       passer.sf.facing)
                    cands[#cands + 1] = {r = r, step = step, passer = passer,
                                         packet = on_packet(r), index = index_of(r)}
                end
                local g = not taken and giveway.choose(cands)
                if g then
                    give_way(g.r, g.passer, g.step)
                    for _, r in ipairs(ring) do busy[r.name] = true end
                elseif not taken then
                    local names = {}
                    for _, r in ipairs(ring) do names[#names + 1] = r.name end
                    table.sort(names)               -- one ring, one note, whoever saw it
                    local note = "wait on each other, and none has a free cell aside: "
                            .. table.concat(names, ", ")
                    if c.gw_said ~= note then
                        c.gw_said = note
                        say(note)
                    end
                end
            elseif b.sf.state == "wait" and (waits[b.name] or 0) >= giveway.WAIT
                    and not on[b.name] then
                -- on one that waits on something else (a creature, a charge): it gives way
                local okc = giveway.catch_up(b) and not b.diverged and #b.outbox == 0
                local step = okc and giveway.aside(b, kept_off({[b.name] = true}), a.sf.facing)
                if step then
                    give_way(b, a, step)
                    busy[a.name], busy[b.name] = true, true
                end
            elseif b.sf.state ~= "run" and b.sf.state ~= "wait" and movable_job(b)
                    and not (st and st.parked and st.parked[b.name]) and not b.diverged
                    and #b.outbox == 0 then
                -- on one standing still - no crew job, or only waiting for the interface's
                -- lock: it moves aside, and stays there
                local step = giveway.aside(b, kept_off({[b.name] = true}), a.sf.facing)
                if step then
                    local _, sent, pid = robots.run(b.name, "$0 " .. CH[step])
                    if sent then
                        c.gw_moved[b.name] = {pid = pid, t = now}
                        say(("%s moved aside (%s) for %s"):format(b.name, CH[step], a.name))
                        busy[b.name] = true
                        since[a.name] = nil
                    end
                end
            end
        end
    end
end

return giveway
