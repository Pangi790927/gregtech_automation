--[[ Two ME interfaces, a station each (redesign/17-stations.md): the interfaces told apart from
-- an `ifaces` answer, and the ME's computer addressed per station; a lock per station, one queue
-- for both, the nearest free one taken, an older crew's waiter handed only the first; two robots
-- taking at the two interfaces at once in the copies' world; the hop to the spot tried again when
-- its dry run met a robot (26 packets started, 4 finished, 2026-10-06); and no robot moved aside
-- onto a spot.
-- @date 2026-10-06 ]]

local vc = require("virt_composer")
local spawn = require("spawn")         -- spawns that keep their handle
local me = require("me")
local crew = require("crew")
local copy = require("copy")
local robots = require("robots")
local machine = require("machine")
local simbot = require("simbot")
local giveway = require("giveway")

local A1, A2 = "bd5ff0a2", "b375f0fd"

-- What the test changes in the shared modules, kept to be put back at its end.
local function keep()
    local k = {ask = me.ask, ifaces = me.ifaces, why = me.ifaces_why, tries = me.learn_tries,
               owner = crew.me_owner, queue = crew.me_queue, run = robots.run,
               send = robots.send, retry = crew.LEG_RETRY_MS, st = {}}
    for n, st in ipairs(me.stations) do
        local s = {}
        for slot, v in pairs(st.stocked) do s[slot] = v end
        k.st[n] = {addr = st.addr, owner = st.owner, stocked = s}
    end
    local w = copy.world()
    k.cells = {}
    for _, c in ipairs({{0, 0, 1}, {0, 1, 2}, {1, 0, 1}, {1, 1, 2}}) do
        local key = c[1] .. "," .. c[2] .. "," .. c[3]
        k.cells[key] = {block = rawget(w.blocks, key), box = w.containers[key],
                        grid = vc.route_get(c[1], c[2], c[3])}
    end
    return k
end

local function put_back(k)
    me.ask, me.ifaces, me.ifaces_why, me.learn_tries = k.ask, k.ifaces, k.why, k.tries
    crew.me_owner, crew.me_queue = k.owner, k.queue
    robots.run, robots.send, crew.LEG_RETRY_MS = k.run, k.send, k.retry
    for n, st in ipairs(me.stations) do
        st.addr, st.owner = k.st[n].addr, k.st[n].owner
        for slot in pairs(st.stocked) do st.stocked[slot] = nil end
        for slot, v in pairs(k.st[n].stocked) do st.stocked[slot] = v end
        for slot in pairs(st.to_clear) do st.to_clear[slot] = nil end
    end
    local w = copy.world()
    for key, c in pairs(k.cells) do
        rawset(w.blocks, key, c.block)
        w.containers[key] = c.box
        local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
        vc.route_set(tonumber(x), tonumber(y), tonumber(z), c.grid)
    end
end

-- An ME's computer that answers every command ok and remembers them; `ifaces` from `answer`.
local function fake_me(answer)
    local sent = {}
    me.ask = function(cmd)
        sent[#sent + 1] = cmd
        if cmd == "ifaces" then
            if not answer then return nil, "no command ifaces" end
            return true, answer
        end
        return true, ""
    end
    return sent
end

local function telling_apart()
    -- the answer read: the first marked, each slot name:damage or nothing
    local list = me.parse_ifaces(A2 .. " -,-,-,-,-,-,-,-,-;" .. A1 .. " first minecraft:planks:"
                                 .. "1:64,minecraft:dirt:0:30,-,-,-,-,-,-,-")
    if #list ~= 2 or list[2].addr ~= A1 or not list[2].first or list[1].first
            or list[2].slots[1] ~= "minecraft:planks:1" or list[2].slots[3] ~= false
            or #list[2].slots ~= 9 then
        return "parse_ifaces"
    end
    -- the one configured as stocked is the first station's, wherever it stands in the answer
    local stocked = {[1] = "minecraft:planks:1", [2] = "minecraft:dirt:0"}
    local a, b = me.identify(list, stocked)
    if a ~= A1 or b ~= A2 then return "identify: " .. tostring(a) .. " " .. tostring(b) end
    -- not decided: nothing stocked, both alike, neither as stocked, not two
    local empty = me.parse_ifaces(A1 .. " first -,-,-,-,-,-,-,-,-;" .. A2 .. " -,-,-,-,-,-,-,-,-")
    if me.identify(empty, {}) or me.identify(empty, stocked) then return "decided on nothing" end
    local cfg = " minecraft:planks:1:64,minecraft:dirt:0:30,-,-,-,-,-,-,-"
    local alike = me.parse_ifaces(A1 .. cfg .. ";" .. A2 .. cfg)
    if me.identify(alike, stocked) then return "decided on two configured alike" end
    local one = me.parse_ifaces(A1 .. " first -,-,-,-,-,-,-,-,-")
    local o1, o2 = me.identify(one, {})
    if o1 ~= A1 or o2 then return "one interface" end
    -- a slot more on the interface than stocked: not it
    local more = me.parse_ifaces(A1 .. " minecraft:planks:1:64,minecraft:dirt:0:30,minecraft:glass"
                                 .. ":0:5,-,-,-,-,-,-;" .. A2 .. " -,-,-,-,-,-,-,-,-")
    if me.identify(more, stocked) then return "decided on a slot not stocked" end

    -- before it is told apart: the first station only, plain commands; the second refused
    for _, st in ipairs(me.stations) do st.addr = nil end
    local sent = fake_me(A2 .. " -,-,-,-,-,-,-,-,-;" .. A1 .. " first minecraft:planks:1:64,"
                         .. "minecraft:dirt:0:30,-,-,-,-,-,-,-")
    if #me.open() ~= 1 then return "the second station open before it was told apart" end
    me.config({[1] = {"minecraft:planks", 1, 64}, [2] = {"minecraft:dirt", 0, 30}})
    if sent[1] ~= "config 1 minecraft:planks 1 64 2 minecraft:dirt 0 30" then
        return "the first station's plain command: " .. tostring(sent[1])
    end
    if me.config({[1] = {"minecraft:dirt", 0, 1}}, 2) then
        return "a config on the second station with no address"
    end
    -- learnt after the takes: both addressed from then on, and the second open
    me.learn_tries = 0
    if not me.wants_learning() then return "no learning wanted" end
    local ok, note = me.learn()
    if not ok or me.stations[1].addr ~= A1 or me.stations[2].addr ~= A2 or #me.open() ~= 2 then
        return "me.learn: " .. tostring(note)
    end
    if me.wants_learning() then return "learning wanted once told apart" end
    me.later_clear({1, 2}, 1)
    me.config({[3] = {"minecraft:glass", 0, 5}}, me.stations[2])
    me.flush(1)
    if sent[#sent - 1] ~= "at " .. A2 .. " config 3 minecraft:glass 0 5"
            or not sent[#sent]:find("^at " .. A1 .. " config ")
            or not sent[#sent]:find("1 -", 1, true) or not sent[#sent]:find("2 -", 1, true) then
        return "the stations not addressed: " .. table.concat(sent, " | ")
    end
    if me.stations[2].stocked[3] ~= "minecraft:glass:0" or me.stations[1].stocked[1] then
        return "what each station stocks"
    end
    -- an older me_machine.lua (no `ifaces`): the first only, and not asked again
    for _, st in ipairs(me.stations) do st.addr = nil end
    fake_me(nil)
    me.learn_tries = 0
    if me.learn() or me.wants_learning() or #me.open() ~= 1 then
        return "an older ME's computer not left on the first station"
    end
    me.ifaces, me.ifaces_why = nil, nil
    return nil
end

-- A stand-in robot record standing at p.
local function stand_in(name, p)
    local r = {name = name, linked = true, outbox = {}, slots = {},
               sf = {id = "-", state = "idle", op = 1, pos = p, facing = "n"},
               status = {"- idle", "max 20000 name " .. name .. " slots 16"}}
    robots.by[name] = r
    return r
end

local function locks()
    fake_me("")
    me.stations[1].addr, me.stations[2].addr = A1, A2
    crew.me_owner, me.stations[2].owner, crew.me_queue = nil, nil, {}
    if crew.spot_at({0, 1, 2}) ~= me.stations[2] or crew.spot_at({0, 0, 2}) then
        return "crew.spot_at"
    end
    -- the nearest free one: Near stands by the second's spot
    stand_in("StNear", {0, 2, 3})
    stand_in("StFar", {0, 0, -2})
    stand_in("StLate", {2, 0, -2})
    crew.jobs.StNear = {p = {id = "n"}}
    crew.jobs.StFar = {p = {id = "f"}}
    crew.jobs.StLate = {p = {id = "l"}}
    local s1 = crew.lock_me("StNear")
    if s1.n ~= 2 or me.stations[2].owner ~= "StNear" then return "the nearest free not taken" end
    -- the other taken at once by the next: two at a time, no wait
    local s2 = crew.lock_me("StFar")
    if s2.n ~= 1 or crew.me_owner ~= "StFar" then return "the other station not taken at once" end
    if crew.holds_me("StNear") ~= s1 or crew.holds_me("StLate") then return "crew.holds_me" end
    -- a third waits, and gets the first let go of - whichever it is
    local got
    spawn(function() got = crew.lock_me("StLate") end)
    for _ = 1, 5 do vc.net_sleep_ms(20) end
    if got or crew.me_queue[1] ~= "StLate" then return "the third did not wait in the queue" end
    crew.unlock_me("StNear")
    for _ = 1, 20 do
        if got then break end
        vc.net_sleep_ms(100)
    end
    if not got or got.n ~= 2 or me.stations[2].owner ~= "StLate" then
        return "the waiter did not get the second station let go of"
    end
    -- an older crew's waiter (its job not this crew's): handed the first, never the second
    crew.jobs.StOld = {p = {id = "o"}}
    crew.me_queue = {"StOld"}
    crew.unlock_me("StLate")
    if me.stations[2].owner then return "the second handed to an older crew's waiter" end
    crew.unlock_me("StFar")
    if crew.me_owner ~= "StOld" then return "the first not handed to an older crew's waiter" end
    -- a holder with no job holds nothing: its station free for the next
    crew.jobs.StOld = nil
    if crew.pick_station("StFar", {"StFar"}) ~= me.stations[1] then
        return "a station held by no job not free"
    end
    crew.jobs.StNear, crew.jobs.StFar, crew.jobs.StLate = nil, nil, nil
    crew.me_owner, me.stations[2].owner, crew.me_queue = nil, nil, {}
    for _, n in ipairs({"StNear", "StFar", "StLate"}) do robots.by[n] = nil end
    -- only the first while the second is not known
    me.stations[2].addr = nil
    crew.jobs.StNear = {p = {id = "n"}, any = true}
    stand_in("StNear", {0, 2, 3})
    if crew.pick_station("StNear", {"StNear"}) ~= me.stations[1] then
        return "the second station picked before it was known"
    end
    crew.jobs.StNear, robots.by.StNear = nil, nil
    return nil
end

-- Two robots at the two interfaces at once in the copies' world, each its own stock.
local function two_at_once()
    local sent = fake_me("")
    me.stations[1].addr, me.stations[2].addr = A1, A2
    local w = copy.world()
    for _, k in ipairs({"0,0,1", "0,1,2", "1,0,1", "1,1,2"}) do rawset(w.blocks, k, false) end
    crew.stations_in_map()
    if vc.route_get(1, 1, 2) ~= 2 or not w.containers["1,1,2"] then
        return "the second interface not in the grid and the copies"
    end
    local who = {}
    local orders = {{st = me.stations[1], place = {["minecraft:planks:1"] = 100}},
                    {st = me.stations[2], place = {["minecraft:dirt:0"] = 30,
                                                   ["minecraft:glass:0"] = 10}}}
    for i, o in ipairs(orders) do
        local r = stand_in("StTake" .. i, {o.st.SPOT[1], o.st.SPOT[2], o.st.SPOT[3]})
        local rounds = crew.rounds_for(r, {place = o.place}, o.st)
        if not rounds or #rounds ~= 1 then return "rounds_for at station " .. i end
        local ok = me.config(rounds[1].cfg, o.st)
        if not ok then return "config at station " .. i end
        crew.interface_in_copy(rounds[1].stocked, o.st)
        local b = simbot.robot(w, {x = o.st.SPOT[1], y = o.st.SPOT[2], z = o.st.SPOT[3],
                                   facing = o.st.FACE})
        local m = machine.new(b.hw, {x = b.x, y = b.y, z = b.z, facing = b.facing})
        m.exec("t" .. i, "$0 f> " .. table.concat(rounds[1].ops, " ") .. " h")
        who[i] = {b = b, m = m}
        robots.by[r.name] = nil
    end
    if sent[1] ~= "at " .. A1 .. " config 1 minecraft:planks 1 64 2 minecraft:planks 1 36"
            or sent[2] ~= "at " .. A2 .. " config 1 minecraft:dirt 0 30 2 minecraft:glass 0 10" then
        return "the two configs: " .. table.concat(sent, " | ")
    end
    -- stepped in turn, as the two robots take side by side
    for _ = 1, 200 do
        local run = false
        for _, x in ipairs(who) do
            if x.m.state == "run" then x.m.step(); run = true end
        end
        if not run then break end
    end
    for i, x in ipairs(who) do
        if x.m.state ~= "halt" and x.m.state ~= "done" then
            return ("robot %d at its interface: %s %s"):format(i, x.m.state, tostring(x.m.why))
        end
    end
    local a, b = who[1].b.slots, who[2].b.slots
    local planks = (a[1] and a[1].count or 0) + (a[2] and a[2].count or 0)
    if planks ~= 100 or a[1].name ~= "minecraft:planks" then return "the first robot's planks" end
    if not (b[1] and b[1].name == "minecraft:dirt" and b[1].count == 30 and b[2]
            and b[2].name == "minecraft:glass" and b[2].count == 10) then
        return "the second robot's dirt and glass"
    end
    for _, x in ipairs(who) do w:set(x.b.x, x.b.y, x.b.z, nil) end
    return nil
end

-- A dry run that met a robot is tried again with the way planned anew; any other is not.
local function hop_again()
    crew.LEG_RETRY_MS = 10
    local r = stand_in("StHop", {0, 0, -2})
    local tries, texts = 0, {}
    robots.run = function(_, text)
        tries = tries + 1
        texts[#texts + 1] = text
        if tries <= 2 then return {state = "wait", why = "robot"}, false end
        r.sf = {id = "p9", state = "done", op = 3, pos = {0, 0, 1}, facing = "e"}
        return {state = "done"}, true, "p9"
    end
    robots.send = function() return {head = true, lines = {}} end
    local j = {p = {id = "hop"}}
    local n = 0
    local ok, why = crew.leg(r, j, "$0 v3 h", "taking, round 1",
                             function() n = n + 1; return "$0 <v3> h" end)
    if not ok or tries ~= 3 or n ~= 2 or texts[3] ~= "$0 <v3> h" then
        return ("the hop not tried again: %s, %d tries, %d remade"):format(tostring(why), tries, n)
    end
    tries = -10
    ok = crew.leg(r, j, "$0 v3 h", "taking, round 1", function() return "$0 v3 h" end)
    if ok then return "a dry run met a robot given up too soon" end
    tries = 0
    robots.run = function() tries = tries + 1; return {state = "stop", why = "blocked"}, false end
    ok, why = crew.leg(r, j, "$0 v3 h", "taking, round 1", function() return "$0 v3 h" end)
    if ok or tries ~= 1 or not tostring(why):find("did not dry-run: stop blocked", 1, true) then
        return "a dry run refused for a block tried again"
    end
    robots.by.StHop = nil
    return nil
end

-- me.lua read again in place keeps its table and state (the link, the stations, what is
-- stocked), by dofile and by `reload me`; me.relink waits its turn and holds it while the link
-- is opened anew, so an ask waits instead of being cut.
local function me_kept()
    local st, stocked, conn = me.stations, me.stocked, me.conn
    me.stations[2].addr = A2
    local again = dofile("scripts/me.lua")
    if again ~= me or me.stations ~= st or me.stocked ~= stocked or me.stations[1].stocked
            ~= stocked or me.stations[2].addr ~= A2 or me.conn ~= conn then
        return "me.lua read again by dofile lost its state"
    end
    me.unload()
    package.loaded["me"] = nil
    local fresh = require("me")
    package.loaded["me"] = me
    if fresh ~= me or me.stations ~= st then return "`reload me` lost its state" end
    local link, busy, ask_wait = me.link, me.busy, me.ASK_WAIT_MS
    local events = {}
    me.link = function(on)
        events[#events + 1] = on == false and "off" or "on"
        if on == false then me.conn = nil
        else spawn(function() vc.net_sleep_ms(50); me.conn = {} end) end
    end
    me.busy = true                                       -- a request under way
    spawn(function() vc.net_sleep_ms(100); me.busy = false end)
    me.conn = {}
    local ok, why = me.relink()
    local events_s = table.concat(events, ",")
    me.link, me.busy, me.conn, me.ASK_WAIT_MS = link, busy, conn, ask_wait
    if not ok or events_s ~= "off,on" then
        return "me.relink: " .. tostring(why) .. " " .. events_s
    end
    return nil
end

local function run_test()
    local k = keep()
    local why = telling_apart() or locks() or two_at_once() or hop_again() or me_kept()
    -- a robot moved aside never stops on a spot (16-giveway.md)
    if not why then
        local off = giveway.kept_off({})
        if not off["0,0,1"] or not off["0,1,2"] then why = "a spot not kept off by give-way" end
    end
    put_back(k)
    return why
end

return {run_test = run_test}
