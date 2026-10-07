--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The real robots, linked through the relay: each runs robot/machine.lua as the zone
-- | `rmachine`, and a coroutine of its own here asks it `status_fast` every 5 s, `status` when it
-- | links and when a program ends, and sends it what is queued for it. Drawn where it really is,
-- | in its colour, with its name, state and the way it came. Stage 2 of 08-order.md.
-- |
-- |     robots.ROSTER               the robots by name: address prefix, park
-- |     robots.link(name, on)       starts or ends a robot's link; nothing links by itself
-- |     robots.send(name, command)  a command queued for it: "exec <id> <program>", "geo ...", ...;
-- |                                 a ticket, which gets the reply (head, lines) when it comes
-- |     robots.update(dt)           true when a robot moved or changed: the view to draw again
-- |     robots.cells()              the view's overlay: each linked robot where it stands
-- |     robots.draw(), robots.panel()
-- |     robots.net                  vc's sockets (net_composer.h), or a test's stand-in
-- |
-- | A robot that does not answer within SILENT seconds has its link closed and opened again, and
-- | the panel says so at once (the user's rule: robot silence is urgent).
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local spawn = require("spawn")         -- spawns that keep their handle
local blocks = require("blocks")
local relay = require("relay")
local view = require("view")
local copy = require("copy")

local robots = {by = {}, order = {}, changed = false}

robots.ROSTER = {                       -- 3d-draw/docs/robots.md, "The roster"
    {name = "G.U.N.T.E.R.", prefix = "858fde4e", park = {0, 0, 0}},
    {name = "ASIMO", prefix = "f4470a27", park = {2, 0, -2}},
    {name = "Pintsize", prefix = "a77c49f1", park = {0, 0, -2}},
    {name = "Baymax", prefix = "a4c330bf", park = {1, -1, -2}},
    {name = "Dalek_Sec", prefix = "1bf71bda", park = {1, 1, -2}},
    -- back as the 6th builder (the user, 2026-10-05: found again, "some other bot broke her and
    -- I couldn't find her"): was 082fe759; parked under the cell in front of ASIMO
    {name = "Cortana", prefix = "c0385d94", park = {2, -1, -1}},
    -- the scouts came back with new addresses, picked up and placed again (2026-10-05): Tom was
    -- 0511bc18, Cairol 956b836d
    -- and the user put them back at the station the other way round: Tom on top of the charger,
    -- Cairol under it
    {name = "Tom_Servo", prefix = "cfbf2408", park = {1, 1, 0}},
    {name = "Cairol", prefix = "44ffaded", park = {1, -1, 0}},
}

local ZONE, PORT, SILENT, TRAIL = "rmachine", 7778, 15, 400
local POLL = 5000                       -- ms between status_fast asks
local CODE_PATH = "robot/machine.lua"
local COLOURS = {0xff2090ff, 0xff40d040, 0xffd04080, 0xff40c0e0, 0xff20d0f0, 0xffc060f0,
                 0xfff07030, 0xffe0e040}
local FACE = {n = blocks.FACE.ZNEG, s = blocks.FACE.ZPOS, e = blocks.FACE.XPOS,
              w = blocks.FACE.XNEG}

robots.net = {connect = function(...) return vc.net_connect(...) end,
              send = function(...) return vc.net_send(...) end,
              recv = function(...) return vc.net_recv(...) end,
              close = function(...) return vc.net_close(...) end,
              sleep = function(ms) return vc.net_sleep_ms(ms) end,
              now = function() return vc.app_time() end}

for i, r in ipairs(robots.ROSTER) do
    local rec = {name = r.name, prefix = r.prefix, park = r.park, colour = COLOURS[i],
                 linked = false, phase = "not linked", outbox = {}, trail = {}, rid = 0,
                 sf = nil, status = {}, results = {}}
    robots.by[r.name] = rec
    robots.order[i] = rec
end
-- where each was last seen: read from robots.POS_FILE once the functions are defined, below

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local t = f:read("a")
    f:close()
    return t
end

-- status_fast: "<id> <state> <op> <x> <y> <z> <facing> <energy> [why]"
local function parse_sf(r, line)
    local id, st, op, x, y, z, f, e, why =
        line:match("^(%S+) (%S+) (%d+) (-?%d+) (-?%d+) (-?%d+) (%a) (%d+)%s*(.*)$")
    if not id then return end
    local p = {tonumber(x), tonumber(y), tonumber(z)}
    local old = r.sf
    r.sf = {id = id, state = st, op = tonumber(op), pos = p, facing = f, energy = tonumber(e),
            why = why ~= "" and why or nil}
    if not old or old.pos[1] ~= p[1] or old.pos[2] ~= p[2] or old.pos[3] ~= p[3]
            or old.facing ~= f then
        r.trail[#r.trail + 1] = p
        if #r.trail > TRAIL then table.remove(r.trail, 1) end
        robots.changed = true
    end
    r.seen = robots.net.now()
    if r.copy then
        local was = r.diverged
        copy.follow(r)
        if r.diverged and not was then
            -- the first op where field and copy part is in the robot's own record
            r.div_hist = robots.send(r.name, "history")
            robots.changed = true
        end
    end
end

-- Why a robot's link went, kept on it (r.dropped = {t, why}): the zone's own end ("the zone
-- ended: error: ..."), or the link closed - by the watchdog, or the relay. A leg that saw its
-- machine begin again names it, instead of guessing (place -3 0 2, 2026-10-06).
function robots.dropped(r, why)
    r.dropped = {t = robots.net.now(), why = tostring(why), phase = r.phase}
end

-- One command and its reply: the head ("<rid> ok <n> [value]" or "<rid> err <why>") and the n
-- lines after it. nil when the link went.
local function ask(r, c, cmd)
    r.rid = r.rid + 1
    local rid = tostring(r.rid)
    c:send_line(rid .. " " .. cmd)
    r.asked = robots.net.now()
    while true do
        local line, why = c:read_line()
        if not line then
            r.asked = nil
            return nil, why
        end
        if line:sub(1, #rid + 1) == rid .. " " then
            local ok, n, value = line:match("^%S+ (%S+) ?(%d*) ?(.*)$")
            local lines = {}
            if ok == "ok" then
                for i = 1, tonumber(n) or 0 do lines[i] = c:read_line() end
            end
            r.asked = nil
            return line, lines, ok == "ok" and value or nil
        end
    end
end

-- A robot's whole link: connect, attach, open the machine, then ask and send until unlinked or
-- the link goes; then again, after a pause, while it is still meant to be linked.
-- `gen`: the link this life belongs to. Unlinked and linked again before this one ended, a
-- second life began, and the two opened the zone in turn, each ending the other's ("the zone
-- ended: terminated", Tom and Cairol, 2026-10-05): a life whose link was replaced stops.
local function life(r, gen)
    local net = robots.net
    local function mine() return r.linked and r.gen == gen end
    -- One link, from connecting to its end. An error inside it ends that link only, as a link
    -- lost: it had ended the robot's whole life - ASIMO never linked again, the watchdog closing
    -- its dead link every second (relay.lua's cut frame, 2026-10-06).
    local cur
    local function one_link()
        r.phase = "connecting"
        local c, why = relay.open(net, relay.host(), PORT)
        cur = c
        if c then
            local addr
            for _, a in ipairs(c:computers() or {}) do
                if a:sub(1, #r.prefix) == r.prefix then addr = a end
            end
            if not addr then
                r.phase, why = "not on the relay", nil
            elseif not c:attach(addr) then
                r.phase = "could not attach"
            else
                local ok, err = c:open_zone(ZONE, read_file(CODE_PATH) or "")
                local ready = ok and c:read_line()
                if not ready then
                    r.phase = "zone: " .. tostring(err or "no ready")
                else
                    parse_sf(r, ready:gsub("^ready ", ""))
                    r.phase, r.conn = "linked", c
                    -- status_fast every POLL; the full status at the link (the copy needs the
                    -- slots) and when a program ends, never in between (the user, 2026-10-05:
                    -- "ask them every 5s, no need for faster updates ... full status only after
                    -- finishing an exec"); a queued command goes at once
                    local function full_status()
                        local h2, lines = ask(r, c, "status")
                        if not h2 then return end
                        r.status = lines
                        copy.inventory(r, (lines[3] or ""):gsub("^inv ", ""))
                        if r.sf and r.sf.state == "done" and r.matched_check then
                            r.matched_check = nil
                            copy.compare_inventory(r)
                        end
                    end
                    full_status()
                    while mine() and not c.closed do
                        while #r.outbox > 0 do
                            local t = table.remove(r.outbox, 1)
                            local head, lines = ask(r, c, t.cmd)
                            t.head, t.lines = head or ("link lost: " .. tostring(lines)), lines
                            if not head then robots.dropped(r, lines) end
                            r.results[#r.results + 1] = t.cmd:sub(1, 40) .. " -> " .. tostring(head)
                            if #r.results > 6 then table.remove(r.results, 1) end
                        end
                        local was = r.sf and r.sf.state
                        local head, why_lost, value = ask(r, c, "status_fast")
                        if not head then
                            robots.dropped(r, why_lost)
                            break
                        end
                        if value then parse_sf(r, value) end
                        local now_state = r.sf and r.sf.state
                        if (was == "run" or was == "wait") and now_state ~= was then
                            full_status()
                            local _, lines = ask(r, c, "history")
                            robots.timings(r, lines)
                        end
                        for _ = 1, POLL // 250 do
                            if #r.outbox > 0 or not mine() then break end
                            net.sleep(250)
                        end
                    end
                    if mine() then r.phase = "the link went; again in 5 s" end
                end
            end
            c:close()
            if r.conn == c then r.conn = nil end
        else
            r.phase = "no relay: " .. tostring(why)
        end
        robots.changed = true
        if mine() then net.sleep(5000) end
    end
    while mine() do
        local ok, err = pcall(one_link)
        if not ok then
            r.phase = "the link broke: " .. tostring(err)
            robots.dropped(r, err)
            if cur then
                cur:close()
                if r.conn == cur then r.conn = nil end
            end
            r.asked = nil
            robots.changed = true
            if mine() then net.sleep(5000) end
        end
    end
    if r.gen == gen then
        r.phase = "not linked"
        robots.changed = true
    end
end

--[[ A program's timings, from its history (each op's line ends "@<uptime>", the robot's own
-- clock): appended to data/timings.txt as `robot program op src seconds`, beside the copy's
-- estimate for the whole program, so the simulation's costs can be fitted to the field (the user,
-- 2026-10-05: "you simulate them and also figure out the timings to get better at simulating
-- them"). ]]
function robots.timings(r, lines)
    if not lines or #lines == 0 then return end
    local f = io.open("data/timings.txt", "a")
    if not f then return end
    local last
    f:write(("# at %.0f s: %s %s, the copy's estimate %s ticks\n"):format(vc.app_time(),
            r.name, r.sf and r.sf.id or "-", tostring(r.estimate)))
    for _, l in ipairs(lines) do
        local i, src, t = l:match("^(%d+) (%S+) .*@([%d%.]+)$")
        t = tonumber(t)
        if t then
            if last then
                f:write(("%s %s %s %s %.2f\n"):format(r.name, r.sf and r.sf.id or "-", i,
                        src, t - last))
            end
            last = t
        end
    end
    f:close()
end

--[[ Closes the link of a robot that has not answered in SILENT seconds; its life opens it again.
-- Time this program itself stood still is not the robot's silence: a coroutine planning (a plan
-- made again took 36 s, programs.make and the dry run of a long packet many seconds) runs alone,
-- the answers wait unread, and the watchdog had closed the links of robots that had answered -
-- their zones ended with their connector ("its connector left", octerm_ext.lua) and came back
-- "- idle", the packet just sent lost (place -3 0 2, 77 steps, twice; place -1 0 7, 74 steps,
-- 2026-10-06). A round late by more than a second counts that much less against every ask. ]]
robots.closes = {}                      -- the links the watchdog closed: {t, name, silent}

-- One round of the watchdog at `now`, the last round at `last` (rounds a second apart): the time
-- this program stood still beyond that second moved off every ask, then each link silent longer
-- than SILENT closed and kept in robots.closes. Apart from the loop, for the tests.
function robots.watch_round(now, last)
    local stood = now - last - 1
    for _, r in ipairs(robots.order) do
        if r.asked and stood > 1 then r.asked = r.asked + stood end
    end
    for _, r in ipairs(robots.order) do
        if r.asked and now - r.asked > SILENT and r.conn then
            r.phase = ("SILENT %d s: link closed"):format(math.floor(now - r.asked))
            robots.closes[#robots.closes + 1] = {t = now, name = r.name, silent = now - r.asked}
            if #robots.closes > 50 then table.remove(robots.closes, 1) end
            r.conn:close()
        end
    end
end

-- Where every robot was last seen, kept on disk (POS_FILE): a robot that is not linked - off the
-- relay, its computer down - still stands where it was, a block in every way. Gunter, off the
-- relay at 0,1,0, was invisible to the routes, and two robots waited on him for good
-- (2026-10-06). `name x y z` a line.
-- The tests' own copy: a test's robots saved over the live file had dropped Gunter from it.
robots.POS_FILE = vc.app_is_testing() and "test_run/robots-pos.txt" or "data/robots-pos.txt"

function robots.load_positions(path)
    local f = io.open(path or robots.POS_FILE, "r")
    if not f then return 0 end
    local n = 0
    for line in f:lines() do
        local name, x, y, z = line:match("^(%S+) (-?%d+) (-?%d+) (-?%d+)")
        local r = name and robots.by[name]
        if r then
            r.last_pos = {tonumber(x), tonumber(y), tonumber(z)}
            n = n + 1
        end
    end
    f:close()
    return n
end

if not vc.app_is_testing() then robots.load_positions() end

local saved = ""
function robots.save_positions(path)
    local out = {}
    for _, r in ipairs(robots.order) do
        if r.linked and r.sf and r.sf.pos then r.last_pos = r.sf.pos end
        local p = r.last_pos
        if p then out[#out + 1] = ("%s %d %d %d"):format(r.name, p[1], p[2], p[3]) end
    end
    local text = table.concat(out, "\n") .. "\n"
    if text == saved then return false end
    local f = io.open(path or robots.POS_FILE, "w")
    if not f then return false end
    f:write(text)
    f:close()
    saved = text
    return true
end

-- A robot not linked, where last seen: solid in the pathfinder's grid and a robot in the copies'
-- world, so no way is planned through it; let go when it links again (or is seen elsewhere).
-- `world`: the copies' world (copy.world() by default). -> how many robots are marked.
function robots.keep_offline(world)
    local n = 0
    for _, r in ipairs(robots.order) do
        local offline = not (r.linked and r.sf)
        local p = r.last_pos
        if offline and p then
            -- set again every round: the grid loaded (or loaded again) after a mark forgets it
            local w = world or copy.world()
            r.offline_mark = r.offline_mark or {p[1], p[2], p[3], vc.route_get(p[1], p[2], p[3])}
            if vc.route_get(p[1], p[2], p[3]) ~= 2 then vc.route_set(p[1], p[2], p[3], 2) end
            local b = w:get(p[1], p[2], p[3])
            if not (b and b[1] == "OpenComputers:robot") then
                w:set(p[1], p[2], p[3], {"OpenComputers:robot", 0})
            end
        elseif not offline and r.offline_mark then
            -- linked: the mark let go always, wherever it stands now - a linked robot is kept
            -- off by its live place (crew.robot_cells) and its copy's block, not the grid; kept
            -- for one linked on its own mark, every park stayed solid after its robot left
            -- (every robot is unlinked a moment at the start: Baymax's park, "no way", 2026-10-06)
            local m, w = r.offline_mark, world or copy.world()
            vc.route_set(m[1], m[2], m[3], 1)
            local here = r.sf.pos
            if not (here[1] == m[1] and here[2] == m[2] and here[3] == m[3]) then
                w:set(m[1], m[2], m[3], nil)
            end
            r.offline_mark = nil
        end
        if r.offline_mark then n = n + 1 end
    end
    return n
end

local function watchdog()
    local last = robots.net.now()
    local beat = 0
    while true do
        local now = robots.net.now()
        robots.watch_round(now, last)
        last = now
        beat = beat + 1
        if beat % 5 == 0 then
            pcall(robots.save_positions)
            pcall(robots.keep_offline)
        end
        robots.net.sleep(1000)
    end
end

local watching = false
function robots.link(name, on)
    local r = robots.by[name]
    if not r or r.linked == on then return end
    r.linked = on
    if not watching then
        watching = true
        spawn(watchdog)
    end
    r.gen = (r.gen or 0) + 1
    if on then
        spawn(life, r, r.gen)
    elseif r.conn then
        r.conn:close()
    end
end

-- A command queued for a robot; the ticket answered gets `head` (the reply's first line) and
-- `lines` once the robot has answered.
function robots.send(name, command)
    local r = robots.by[name]
    local t = {cmd = command}
    if r then r.outbox[#r.outbox + 1] = t end
    return t
end

--[[ Whether a program sent to r is still on its way: queued, or answered but not yet seen in a
-- status_fast. Meanwhile r.sf is the robot as it was before it - its place, its state "done" - and
-- a second program planned from it ran from a cell the robot had left: a way home and a way to
-- the station sent within a second, the robot did a few steps of the first and the whole second
-- from there, its copy the second only (Dalek_Sec 1 2 -3, Pintsize 0 0 -5 and 0 0 -4, Baymax
-- 2 -2 -5 against copies at their parks, 2026-10-06; machine.lua's exec replaces a program after
-- its current op). Over once the robot shows it, its exec is refused, or after IN_FLIGHT_S (the
-- link went: the watchdog closes it after SILENT). Read lazily, from r.sent. ]]
robots.IN_FLIGHT_S = 30
function robots.in_flight(r)
    local s = r and r.sent
    if not s then return false end
    local head = s.ticket and s.ticket.head
    if (r.sf and r.sf.id == s.id) or (head and not head:match("^%S+ ok"))
            or robots.net.now() - s.t > robots.IN_FLIGHT_S then
        r.sent = nil
        return false
    end
    return true
end

--[[ A program for a robot, the way every program goes from now on: run first start to end on a
-- throwaway copy of the robot and the world (copy.dry), sent only when that copy ends `done` - or
-- `halt`, a program that ends waiting for the PC on purpose (at the ME's interface, 11-me.md);
-- then its copy runs it beside the robot. Answers the dry run, and whether it was sent. Never
-- over a program still on its way (robots.in_flight): refused, state "busy". ]]
local runs = 0
function robots.run(name, text)
    local r = robots.by[name]
    if not r or not r.linked or not r.sf then return nil, "not linked" end
    if not r.slots then return nil, "no status yet: its slots are not known" end
    if robots.in_flight(r) then
        return {state = "busy", why = "program " .. r.sent.id .. " is still on its way to it"},
               false
    end
    -- nor over one it runs: machine.lua's exec replaces a running program after its op, the
    -- robot and its copy apart from there (a give-way goes by its own command, give_way)
    if r.sf.state == "run" or r.sf.state == "wait" then
        return {state = "busy", why = "it still runs " .. tostring(r.sf.id)}, false
    end
    local d = copy.dry(r, text)
    if d.state ~= "done" and d.state ~= "halt" then return d, false end
    runs = runs + 1
    local id = ("p%d"):format(runs)
    local ok, why = copy.start(r, id, text)
    if not ok then d.state, d.why = "refused", why; return d, false end
    r.matched, r.matched_check, r.div_hist, r.estimate = nil, true, nil, d.ticks
    r.dest = d.pos                       -- where it will stand: kept off by the others' ways
    local t = robots.send(name, "exec " .. id .. " " .. text)
    r.sent = {id = id, t = robots.net.now(), ticket = t}
    return d, true, id
end

function robots.update(dt)
    local c = robots.changed
    robots.changed = false
    return c
end

local shown = {}
function robots.cells()
    local out = {}
    -- a copy that stands elsewhere than its robot, see-through, so the two are seen apart
    for _, r in ipairs(robots.order) do
        local c = r.linked and r.copy and r.sf
        if c then
            local b = r.copy.b
            local p = r.sf.pos
            if b.x ~= p[1] or b.y ~= p[2] or b.z ~= p[3] then
                out[b.x .. "," .. b.y .. "," .. b.z] = {"OpenComputers:robot", 0, nil,
                                                        FACE[b.facing], 2}
            end
        end
    end
    for _, r in ipairs(robots.order) do
        if r.linked and r.sf then
            local p = r.sf.pos
            local k = p[1] .. "," .. p[2] .. "," .. p[3]
            local old = shown[r.name]
            if old and old.k == k and old.b[4] == FACE[r.sf.facing] then
                out[k] = old.b
            else
                local b = {"OpenComputers:robot", 0, nil, FACE[r.sf.facing]}
                shown[r.name] = {k = k, b = b}
                out[k] = b
            end
        end
    end
    return out
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
                vc.ImGui_AddLine({x = prev[1], y = prev[2]}, {x = at[1], y = at[2]}, colour, 3)
            end
            prev = at
        else
            prev = nil
        end
    end
end

function robots.draw()
    local disp = vc.ImGui_GetDisplaySize()
    local W, H = math.floor(disp.x), math.floor(disp.y)
    vc.ImGui_SetDrawForeground(true)
    for _, r in ipairs(robots.order) do
        if r.linked and r.sf then
            if view.paths then polyline(r.trail, r.colour) end
            local p = r.sf.pos
            local x, y, z = view.to_cell(p[1], p[2], p[3])
            local at = x and vc.render_project(x + 0.5, y + 1.2, z + 0.5, W, H)
            if at and at[3] > 0 then
                local text = ("%s  %s%s  energy %d"):format(r.name, r.sf.state,
                        r.sf.why and (" " .. r.sf.why) or "", r.sf.energy)
                local size = vc.ImGui_CalcTextSize(text)
                local x0, y0 = at[1] - size.x / 2 - 4, at[2] - size.y - 6
                vc.ImGui_AddRectFilled({x = x0, y = y0}, {x = x0 + size.x + 8, y = y0 + size.y + 4},
                        0xc0202020, 3)
                vc.ImGui_AddText({x = x0 + 4, y = y0 + 2}, r.colour, text)
            end
        end
    end
    vc.ImGui_SetDrawForeground(false)
end

function robots.panel()
    -- at the right edge, sized to what it holds: it opened on top of the 3d-draw panel
    local disp = vc.ImGui_GetDisplaySize()
    vc.ImGui_SetNextWindowPos({x = math.max(10, disp.x - 720), y = 10}, 2)
    vc.ImGui_Begin("robots", 64)
    vc.ImGui_Text("linked through the relay, running robot/machine.lua; nothing links by itself")
    local now = robots.net.now()
    for _, r in ipairs(robots.order) do
        local label = (r.linked and "[x] " or "[ ] ") .. r.name
        if vc.ImGui_SmallButton(label) then robots.link(r.name, not r.linked) end
        vc.ImGui_SameLine(0, -1)
        local sf = r.sf
        vc.ImGui_Text(("%-14s %s"):format(r.phase, sf and r.linked and
                ("%s %s op %d at %d %d %d %s  energy %d%s  (%.0f s ago)"):format(sf.id, sf.state,
                sf.op, sf.pos[1], sf.pos[2], sf.pos[3], sf.facing, sf.energy,
                sf.why and (" " .. sf.why) or "", now - (r.seen or now)) or ""))
        if r.linked and r.sf then
            vc.ImGui_SameLine(0, -1)
            -- a step up and back: the robot stops, digging nothing, if the cell above is taken
            if vc.ImGui_SmallButton("up and back##" .. r.name) then
                robots.send(r.name, "exec t" .. math.floor(now) .. " $0 + -")
            end
        end
        if r.linked and r.status[3] then vc.ImGui_Text("      " .. r.status[3]:sub(1, 110)) end
        if r.diverged then
            vc.ImGui_Text("   !! DIVERGED: " .. r.diverged.why)
            for _, l in ipairs(r.div_hist and r.div_hist.lines or {}) do
                vc.ImGui_Text("        " .. l)
            end
        elseif r.matched then
            vc.ImGui_Text("      " .. r.matched)
        end
        for _, res in ipairs(r.results) do vc.ImGui_Text("      " .. res) end
    end
    vc.ImGui_End()
end

return robots
