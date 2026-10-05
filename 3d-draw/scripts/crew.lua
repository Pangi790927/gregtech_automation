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
-- |     crew.paths               {done = data/crew-done.txt, built = data/built.txt}
-- |
-- | A packet ended `done`, its robot and copy agreeing, is done: its cells go into the
-- | pathfinder's grid and into built.txt, so the map knows them. A stop or a divergence assumes
-- | nothing: the robot stays, the steps it finished are written, the rest waits for the user.
-- | The robot takes only when told: the PC stocks the interface and waits for its tick.
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local robots = require("robots")
local copy = require("copy")
local route = require("route")
local view = require("view")
local packets = require("live")("packets")
local programs = require("live")("programs")
local me = require("me")

local crew = {jobs = {}, done = {}, log = {},
              paths = {done = "data/crew-done.txt", built = "data/built.txt"}}

local function say(s)
    crew.log[#crew.log + 1] = s
    if #crew.log > 12 then table.remove(crew.log, 1) end
end

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
local TURNED = {"_stairs", "_door", "trapdoor", "torch", "ladder", "fenceGate", "fence_gate",
                "lever", "button", "chest", "pumpkin", "furnace", "hay_block"}
local function turned(name, meta)
    if name:find("slab") and not name:find("double") then return meta & 8 ~= 0 end
    if name:find("log") then return meta & 12 ~= 0 end
    for _, t in ipairs(TURNED) do if name:find(t, 1, true) then return true end end
    return false
end

-- The item a placed block comes from: a stair, a door, a torch is one item whatever its way; a
-- slab's top half, a log's axis, leaves' decay bit fold back (11-me.md, "What the village needs").
function crew.item(name, meta)
    -- wheat is planted as seeds; farmland is dirt, tilled (redesign/13-farm.md)
    if name == "minecraft:wheat" then return "minecraft:wheat_seeds", 0 end
    if name == "minecraft:farmland" then return "minecraft:dirt", 0 end
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
        if st.act == "place" then name, meta = crew.item(name, meta) end
        local kk = name .. ":" .. tostring(meta)
        local t = st.act == "place" and place or st.act == "dig" and dig or nil
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
    if not r.slots then return false, "no full status yet: its slots are not known" end
    return true
end

-- The cells this robot's routes keep off: where every other linked robot stands, and the
-- packets other robots are working (redesign/09-paths.md).
local function avoid_for(r)
    local a = {}
    for _, o in ipairs(robots.order) do
        if o ~= r and o.linked and o.sf then
            a[o.sf.pos[1] .. "," .. o.sf.pos[2] .. "," .. o.sf.pos[3]] = true
        end
    end
    for name, j in pairs(crew.jobs) do
        if name ~= r.name then
            for _, k in ipairs(j.p.cells) do a[k] = true end
            for _, st in ipairs(j.p.steps) do a[st.k] = true end
        end
    end
    return a
end

-- The steps a robot finished, into the grid, the copies' world and built.txt (world
-- coordinates), in order: a support put and taken away again ends as air, the last line for a
-- cell being the one read. The copies' world too: a copy that stopped short of its robot had
-- left the cells it did not dig standing there.
local function write_steps(steps, upto)
    if upto < 1 then return 0 end
    local a = view.anchor
    local plan = (packets.plans[packets.pick] or "plan"):match("([^/\\]+)$")
    local f = io.open(crew.paths.built, "a")
    local w = not vc.app_is_testing() and copy.world() or nil
    for i = 1, upto do
        local st = steps[i]
        local x, y, z = unkey(st.k)
        local name, meta = "minecraft:air", 0
        if st.act == "place" then name, meta = st.block[1], st.block[2] end
        if st.act == "till" then name, meta = "minecraft:farmland", 0 end
        local solid = st.act == "place" or st.act == "till"
        vc.route_set(x, y, z, solid and 2 or 1)
        if w then w:set(x, y, z, solid and {name, meta} or nil) end
        if f then
            f:write(("%d %d %d %s %d 1.0 built %s\n"):format(x + a[1], y + a[2], z + a[3], name,
                                                            meta, plan))
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
        -- the program's ops before the packet's own (to the interface, the takes) shift its count
        local stopped_at = (r.sf and r.sf.op or 1) - (j.op_offset or 0)
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
local function tool(name)
    return name:find("gt.metatool", 1, true) ~= nil or name:find("mattock", 1, true) ~= nil
end

-- The interface in the copies' world, as configured: `stocked` {[slot] = {name, meta, count}},
-- every other slot free - what is given into it goes to the network on the interface's tick.
local function interface_in_copy(stocked)
    local slots = {sink = {}}
    for s = 1, 9 do
        local it = stocked and stocked[s]
        if it then slots[s] = {name = it[1], meta = it[2], count = it[3]}
        elseif not me.stocked[s] then slots.sink[s] = true end
    end
    copy.world():add_container(me.INTERFACE[1], me.INTERFACE[2], me.INTERFACE[3], slots)
end

-- One program: dry-run, sent, and waited for until it ends. True when it ended `done` or `halt`
-- with its copy agreeing; else nil and why.
-- A robot stopped "blocked <name>" on a step learned it: the cell is the step's direction from
-- where it stands - not its facing (a step up or down keeps the facing; that misread put
-- Pintsize's leaf a cell off, 2026-10-05) - and the block goes into the grid, the copies' world
-- and data/scouted.txt, as the robot itself named it.
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
    local f = io.open("data/scouted.txt", "a")
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
local LOOKS = {{"^", "n"}, {"v", "s"}, {">", "e"}, {"<", "w"}, {"+", "u"}, {"-", "d"}}
local function look_around(r)
    local d, sent, pid = robots.run(r.name, "$0 l^ lv l> l< l+ l-")
    if not sent then return nil end
    for _ = 1, 40 do
        vc.net_sleep_ms(500)
        if r.sf and r.sf.id == pid and r.sf.state ~= "run" then break end
    end
    vc.net_sleep_ms(1500)                         -- the full status, with the looks' results
    local a, w = view.anchor, copy.world()
    local step = require("live")("machine").STEP_OF
    local f = io.open("data/scouted.txt", "a")
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

local function leg(r, j, text, what)
    local d, sent, pid = robots.run(r.name, text)
    if not sent then
        return nil, ("%s did not dry-run: %s %s"):format(what, tostring(d and d.state),
                                                         tostring(d and d.why or ""))
    end
    j.pid, j.what = pid, what
    while true do
        vc.net_sleep_ms(1000)
        if not r.linked then return nil, what .. ": its link is gone" end
        local sf = r.sf
        if sf and sf.id == pid then
            if sf.state == "stop" then learn_block(r) end
            if r.diverged then return nil, what .. ": its copy diverged: " .. r.diverged.why end
            if sf.state == "done" or sf.state == "halt" then return true end
            if sf.state == "stop" then return nil, what .. ": stop " .. tostring(sf.why) end
        end
    end
end

-- The way to the interface's spot and the turn to face it, as program text ("" when there).
local function to_spot(r, from, facing)
    local at = me.SPOT
    local path = ""
    if not (from[1] == at[1] and from[2] == at[2] and from[3] == at[3]) then
        path = route_avoiding(from, facing, at, avoid_for(r))
        if path == "" then return nil end
    end
    return path .. " f" .. DIR_CH[me.FACE]
end

local function holds_more_than_tools(r)
    for _, it in pairs(r.slots or {}) do if not tool(it.name) then return true end end
    return false
end

-- To the interface and everything but its tools given back, in rounds: a stack into each free
-- slot of the interface, a halt, the tick that empties them, the next round; the last round ends
-- with `tail` (a halt, or the way home). Pintsize came with 15 stacks from the harbour, and one
-- round of 9 had refused her (2026-10-05). -> true | nil, why
local function give_back_rounds(r, j, tail)
    local go = to_spot(r, r.sf.pos, r.sf.facing)
    if not go then return nil, "no way to the interface" end
    me.flush()                               -- the slots let go of, free for what it gives
    local held = {}                          -- what it holds, counted down round by round
    for slot, it in pairs(r.slots or {}) do
        if not tool(it.name) then held[slot] = it end
    end
    local round = 0
    while true do
        vc.net_sleep_ms(TICK_MS)             -- cleared slots, and the last round's, empty
        interface_in_copy(nil)
        local free = {}
        for s = 1, 9 do if not me.stocked[s] then free[#free + 1] = s end end
        local mine = {}
        for slot in pairs(held) do mine[#mine + 1] = slot end
        table.sort(mine)
        local ops, back = {}, {}
        for i, slot in ipairs(mine) do
            if i > #free then break end
            local it = held[slot]
            ops[#ops + 1] = ("g%s%d.%d"):format(DIR_CH[me.FACE], slot, free[i])
            local kk = it.name .. ":" .. it.meta
            back[kk] = (back[kk] or 0) + it.count
            held[slot] = nil
        end
        local last = next(held) == nil
        round = round + 1
        local ok, why = leg(r, j, ("$0 %s %s %s"):format(go, table.concat(ops, " "),
                                                         last and tail or "h"),
                            "giving back, round " .. round)
        if not ok then return nil, why end
        for kk, n in pairs(back) do me.moved(kk, n) end
        go = ""
        if last then return true end
    end
end

-- The packet's items in rounds of at most 8 stacks (the interface's slots 1-8), each round its
-- own config and takes, the robot slots they go to: {{cfg, stocked, ops, at}, ...}.
local function rounds_for(r, j)
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
        local n = j.place[kk]
        while n > 0 do
            stacks[#stacks + 1] = {kk = kk, name = name, meta = tonumber(meta),
                                   k = math.min(64, n)}
            n = n - 64
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
        cur.ops[#cur.ops + 1] = ("t%s%d.%d*%d"):format(DIR_CH[me.FACE], islot, rs, st.k)
        cur.at[#cur.at + 1] = {kk = st.kk, name = st.name, meta = st.meta, rs = rs, k = st.k}
    end
    return rounds
end

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
            return nil
        end
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
local function trip(r, j)
    local function fail(why, in_packet)
        if j.stocked then
            local s = {}
            for slot in pairs(j.stocked) do s[#s + 1] = slot end
            me.later_clear(s)
            me.flush()
        end
        if in_packet then finish(r, j, why) else
            say(("%s: %s NOT started: %s"):format(r.name, j.p.id, why))
        end
        crew.jobs[r.name] = nil
        packets.finish(j.p.id)
    end
    -- what it carries from before, given back first - only when it has not the room for this
    -- packet's takes and digs (in a chain it comes straight from the last packet, 10-live.md)
    local empty = 0
    for slot = 1, size_of(r) do if not (r.slots or {})[slot] then empty = empty + 1 end end
    if holds_more_than_tools(r) and empty < j.stacks then
        j.phase = "giving back what it held"
        local ok, why = give_back_rounds(r, j, "h")
        if not ok then return fail(why, false) end
        vc.net_sleep_ms(1500)                          -- its full status, the slots now empty
    end
    -- the packet's items, in rounds of 8 stacks: each stocked (one request), the tick let pass,
    -- the takes; the robot halts at the interface between rounds, and the last round's exec goes
    -- on into the packet
    local before, at = "", nil
    if next(j.place) then
        local rounds, why0 = rounds_for(r, j)
        if not rounds then return fail(why0, false) end
        local go = to_spot(r, r.sf.pos, r.sf.facing)
        if not go then return fail("no way to the interface", false) end
        at = {}
        for i, rd in ipairs(rounds) do
            j.phase = ("taking, round %d of %d"):format(i, #rounds)
            if j.stocked then
                local s = {}
                for slot in pairs(j.stocked) do s[#s + 1] = slot end
                me.later_clear(s)
            end
            local ok, why = me.config(rd.cfg)
            if not ok then return fail("the ME's computer: " .. tostring(why), false) end
            j.stocked = rd.stocked
            interface_in_copy(rd.stocked)
            -- a slot (re)configured fills on the interface's next tick: a robot one step away
            -- took 0 of 14 (Gunter, 2026-10-05) - the exe lets the tick pass before the takes
            vc.net_sleep_ms(TICK_MS)
            for _, a in ipairs(rd.at) do at[#at + 1] = a end
            if i < #rounds then
                ok, why = leg(r, j, "$0 " .. go .. " " .. table.concat(rd.ops, " ") .. " h",
                              "taking, round " .. i)
                if not ok then return fail(why, false) end
                for _, a in ipairs(rd.at) do me.moved(a.kk, -a.k) end
                go = ""
            else
                before = go .. " " .. table.concat(rd.ops, " ")
                j.last_round = rd
            end
        end
    end
    local from = next(j.place) and {me.SPOT[1], me.SPOT[2], me.SPOT[3]}
            or {r.sf.pos[1], r.sf.pos[2], r.sf.pos[3]}
    local text, opstep = packet_text(r, j, from, next(j.place) and me.FACE or r.sf.facing, at)
    if not text then return fail(opstep, false) end
    local full, offset = prefixed(text, before)
    j.opstep, j.op_offset = opstep, offset
    j.phase = "the packet"
    local ok, why = leg(r, j, full, "the packet")
    if j.stocked then
        local s = {}
        for slot in pairs(j.stocked) do s[#s + 1] = slot end
        me.later_clear(s)                              -- with the next request, or the flush
        if ok or (r.sf and r.sf.op and r.sf.op > offset) then
            for _, a in ipairs(j.last_round.at) do me.moved(a.kk, -a.k) end
        end
    end
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
    local home = route_avoiding(me.SPOT, me.FACE, r.park, avoid_for(r))
    ok, why = give_back_rounds(r, j, home)
    crew.jobs[r.name] = nil
    packets.finish(j.p.id)
    if not ok then
        say(("%s: after %s, giving back: %s - it stays"):format(r.name, j.p.id, why))
        return
    end
    say(("%s: %s's trip ends at its park, %.0f s"):format(r.name, j.p.id, vc.app_time() - j.t0))
end

function crew.start(name, id, chained)
    local r = robot_named(name)
    if not r then return nil, "no robot " .. tostring(name) end
    local res = packets.result
    if not res then return nil, "no plan: plan it first" end
    local p = res.packets[id]
    if not p then return nil, "no packet " .. tostring(id) end
    if not p.steps then return nil, id .. " is not proven: " .. tostring(p.unproven) end
    if crew.done[id] then return nil, id .. " is done already" end
    for w in pairs(p.waits) do
        if not crew.done[w] then return nil, id .. " waits on " .. w .. ", not done" end
    end
    for other, jo in pairs(crew.jobs) do
        if jo.p.id == id then return nil, id .. " is " .. other .. "'s" end
        if other ~= r.name then
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
    -- what it places, from the exe's view of the ME; room for that and for what it digs
    local place, dig = crew.bill(p)
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
    vc.coroutine_spawn(trip, r, j)
    say(("%s sets off on %s"):format(r.name, id))
    return true, ("%s sets off on %s: %d steps, %d stacks to take"):format(r.name, id, #p.steps,
            (function() local n = 0 for _, k in pairs(place) do n = n + (k + 63) // 64 end
                        return n end)())
end

-- ---- crafting (redesign/12-craft.md) -----------------------------------------------------------

local recipes = require("recipes")
local OUT = {8, 12, 13, 14, 15, 16}          -- Gunter's storage slots, where what he makes goes

-- One batch of `item`, at most `n` made: k crafts, up to 64 in each grid cell; the interface's
-- slots for its ingredients (a cell taking its k from one slot); the stacks it makes. Sized so
-- its slots and the stacks it will give back fit the interface's 9 together.
local function batch_for(item, n)
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
    local k = math.min((n + rec.yield - 1) // rec.yield, 64, #OUT * 64 // rec.yield)
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
            return {item = item, rec = rec, k = k, slots = slots, made = k * rec.yield}
        end
        k = k - 1
    end
    return nil, item .. " cannot be laid from the interface's slots"
end

-- The ops of one batch at the interface: the takes into the grid, the saw in, the crafts into
-- the storage slots until all k are made, the saw back. -> ops, config, stocked, the storage
-- slots filled {slot = n}.
local function batch_ops(b)
    local d = DIR_CH[me.FACE]
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
    for _, slot in ipairs(OUT) do
        if left <= 0 then break end
        local n = math.min(per, left)
        ops[#ops + 1] = ("c%d*%d"):format(slot, n)
        outs[slot] = n
        left = left - n
    end
    if saw_cell then ops[#ops + 1] = ("s%d.%d"):format(saw_cell, recipes.SAW_SLOT) end
    return ops, cfg, stocked, outs
end

-- Gives of the storage slots filled by the last batch into the interface's slots not stocked
-- in `cfg` (cleared with it, emptied on the tick).
local function give_ops(outs, cfg)
    local d = DIR_CH[me.FACE]
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
local function craft_run(r, j, list)
    local function done(why)
        if j.stocked then
            local s = {}
            for slot in pairs(j.stocked) do s[#s + 1] = slot end
            me.later_clear(s)
        end
        crew.jobs[r.name] = nil
        if why then say(("%s: crafting stopped: %s"):format(r.name, why)) end
        return why == nil, why
    end
    if holds_more_than_tools(r) then
        j.phase = "giving back what it held"
        local ok, why = give_back_rounds(r, j, "h")
        if not ok then return done(why) end
        vc.net_sleep_ms(1500)
    end
    local go = to_spot(r, r.sf.pos, r.sf.facing)
    if not go then return done("no way to the interface") end
    local outs, last_item = {}, nil                -- what the last batch made, still in Gunter
    local batches = 0
    for _, want in ipairs(list) do
        local left = want.n
        while left > 0 do
            local b, err = batch_for(want.item, left)
            if not b then return done(err) end
            local ops, cfg, stocked, new_outs = batch_ops(b)
            local gives = give_ops(outs, cfg)
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
                me.later_clear(s)
            end
            local ok, why = me.config(cfg)
            if not ok then return done("the ME's computer: " .. tostring(why)) end
            j.stocked = stocked
            vc.net_sleep_ms(TICK_MS)         -- configured slots fill, cleared ones empty
            interface_in_copy(stocked)
            local text = "$0 " .. go .. " " .. table.concat(gives, " ") .. " "
                    .. table.concat(ops, " ") .. " h"
            go = ""                          -- there from now on, facing it
            ok, why = leg(r, j, text, "crafting " .. want.item)
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
        me.later_clear(s)
    end
    me.flush()
    j.stocked = nil
    vc.net_sleep_ms(TICK_MS)
    interface_in_copy(nil)
    local gives = give_ops(outs, {}) or {}
    local home = route_avoiding(me.SPOT, me.FACE, r.park, avoid_for(r))
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
    if next(crew.jobs) then return nil, "a robot is on a trip: one at the interface at a time" end
    local ok, why = still(r)
    if not ok then return nil, r.name .. ": " .. why end
    if not me.conn then return nil, "the ME is " .. me.phase end
    if not me.view and not me.items() then return nil, "the ME could not be read" end
    local j = {p = {id = "crafting", cells = {}, steps = {}}, phase = "setting off",
               t0 = vc.app_time()}
    crew.jobs[r.name] = j
    if wait then return craft_run(r, j, list) end
    vc.coroutine_spawn(craft_run, r, j, list)
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
        if not crew.done[p.id] then
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
function crew.chain(list)
    for i, it in ipairs(list) do
        -- chained while the same robot has more to do: no trip home between (10-live.md)
        local more = list[i + 1] and list[i + 1][1] == it[1]
        local ok, why = crew.start(it[1], it[2], more)
        if not ok then
            return nil, ("%d of %d, %s: refused: %s"):format(i, #list, it[2], tostring(why))
        end
        local r = robot_named(it[1])
        while crew.jobs[r.name] do vc.net_sleep_ms(500) end
        vc.net_sleep_ms(1500)                    -- its full status: what it holds now
        if not crew.done[it[2]] then
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
            if not q or crew.done[id] or need[id] then return end
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

return crew
