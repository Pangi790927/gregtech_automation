--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The running program's control port, 127.0.0.1:7790 and nowhere else: a line in, its answer out,
-- | ended by a line holding only ".". So Claude talks to the robots through the program the user
-- | is watching, with no second link to kick the first out, and changes Lua without a restart (the
-- | user, 2026-10-05: "can't you start talking with the robots and ask them things ... so we won't
-- | need to recompile as oftern").
-- |
-- |     control.start(port)     listens, and serves each connection on a coroutine of its own
-- |
-- | The commands:
-- |     robots                      every robot: linked or not, phase, its last status_fast
-- |     link <name> / unlink <name> a robot's link (names by any start, case aside: "pint")
-- |     ask <name> <command>        a robot command - status, status_fast, history, geo ...,
-- |                                 exec <id> <program> - and the robot's whole reply
-- |     lua <code>                  Lua run in the program; what it returns, as text
-- |     run <name> <program>        the program run first on the robot's copy, sent only when the
-- |                                 copy ends done; then followed and compared (copy.lua)
-- |     copy <name>                 the robot's copy: where it is, its state, any divergence
-- |     route <x y z> <x y z>       the way between two cells, over the whole known map
-- |     go <name> <x y z>           a robot to a cell: routed, run on its copy, then sent
-- |     crew [<name> <packet>]      a real robot takes a proven packet (crew.lua); the crew's state
-- |     reload <module>             a module read again from its file and used at once (live.lua):
-- |                                 sim (a new run; the old one's `unload` first), programs,
-- |                                 planner, packets, machine, simbot, plan, marks, ... - not
-- |                                 robots or control, which hold sockets
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local robots = require("robots")

local control = {}

local function find(name)
    local want = (name or ""):lower()
    for _, r in ipairs(robots.order) do
        if r.name:lower():sub(1, #want) == want and #want > 0 then return r end
    end
end

local function show(v, depth)
    depth = depth or 0
    if type(v) ~= "table" or depth > 2 then return tostring(v) end
    local out = {}
    for k, x in pairs(v) do
        out[#out + 1] = tostring(k) .. "=" .. show(x, depth + 1)
        if #out > 60 then out[#out + 1] = "..."; break end
    end
    return "{" .. table.concat(out, ", ") .. "}"
end

-- One command line into the lines of its answer. May wait (ask).
local function run(line)
    local cmd, rest = line:match("^%s*(%S+)%s*(.-)%s*$")
    if cmd == "robots" then
        local out = {}
        for _, r in ipairs(robots.order) do
            local sf = r.sf
            out[#out + 1] = ("%-13s %-3s %-20s %s"):format(r.name, r.linked and "on" or "off",
                    r.phase, sf and ("%s %s op %d at %d %d %d %s energy %d%s"):format(sf.id,
                    sf.state, sf.op, sf.pos[1], sf.pos[2], sf.pos[3], sf.facing, sf.energy,
                    sf.why and (" " .. sf.why) or "") or "")
        end
        return out
    elseif cmd == "link" or cmd == "unlink" then
        local r = find(rest)
        if not r then return {"no robot " .. rest} end
        robots.link(r.name, cmd == "link")
        return {r.name .. (cmd == "link" and " linking" or " unlinked")}
    elseif cmd == "ask" then
        local name, what = rest:match("^(%S+)%s+(.+)$")
        local r = find(name)
        if not r then return {"no robot " .. tostring(name)} end
        if not r.linked then return {r.name .. " is not linked: link " .. r.name} end
        local t = robots.send(r.name, what)
        for _ = 1, 600 do                       -- a minute at most
            if t.head then break end
            vc.net_sleep_ms(100)
        end
        if not t.head then return {"no answer in a minute (" .. r.phase .. ")"} end
        local out = {t.head}
        for _, l in ipairs(t.lines or {}) do out[#out + 1] = l end
        return out
    elseif cmd == "run" then
        local name, text = rest:match("^(%S+)%s+(.+)$")
        local r = find(name)
        if not r then return {"no robot " .. tostring(name)} end
        local d, sent, id = robots.run(r.name, text)
        if not d then return {"not run: " .. tostring(sent)} end
        local out = {("dry run: %s%s, %s ops, %s ticks, ends at %s"):format(d.state,
                d.why and (" " .. d.why) or "", tostring(d.ops), tostring(d.ticks),
                d.pos and table.concat(d.pos, " ") or "-")}
        out[#out + 1] = sent and ("sent as " .. id) or "NOT sent: the copy did not end done"
        return out
    elseif cmd == "copy" then
        local r = find(rest)
        if not r then return {"no robot " .. tostring(rest)} end
        local c = r.copy
        return {c and ("copy at %d %d %d %s, %s op %d %s"):format(c.b.x, c.b.y, c.b.z, c.b.facing,
                c.m.state, c.m.pc, tostring(c.m.why)) or "no copy yet",
                "diverged: " .. tostring(r.diverged and r.diverged.why),
                "matched: " .. tostring(r.matched)}
    elseif cmd == "plan" then
        local pk = require("packets")
        if rest ~= "" then
            for i, path in ipairs(pk.plans) do if path:find(rest, 1, true) then pk.pick = i end end
        end
        pk.run()
        local r = pk.result
        if not r then return {pk.note} end
        local s = r.stats
        return {pk.note, ("%d dig packets (%d blocks), %d place packets (%d blocks), %d ordered")
                :format(s.dig_packets, s.dig_cells, s.place_packets, s.place_cells, #r.order),
                ("never scanned %d, nothing to stand on %d, in a cycle %d"):format(
                #r.problems.unknown, #r.problems.flying, #r.problems.cycle),
                "first: " .. table.concat(r.order, " | ", 1, math.min(5, #r.order))}
    elseif cmd == "route" then
        local n = {}
        for v in rest:gmatch("-?%d+") do n[#n + 1] = tonumber(v) end
        if #n < 6 then return {"route <x y z> <x y z>"} end
        local rt = require("route")
        local t = vc.app_time()
        local p = rt.find({n[1], n[2], n[3]}, "n", {n[4], n[5], n[6]})
        return {(p ~= "" and p or "no way"), ("%.3f s; the grid: %s cells known, loaded in %.2f s")
                :format(vc.app_time() - t, tostring(rt.cells), rt.took)}
    elseif cmd == "go" then
        -- a robot to a cell: the route from where it is, run first on its copy, then sent
        local name, x, y, z = rest:match("^(%S+)%s+(-?%d+)%s+(-?%d+)%s+(-?%d+)")
        local r = find(name)
        if not r or not r.sf then return {"no linked robot " .. tostring(name)} end
        local p = require("route").find(r.sf.pos, r.sf.facing, {tonumber(x), tonumber(y),
                                                               tonumber(z)})
        if p == "" then return {"no way known from " .. table.concat(r.sf.pos, " ")} end
        if p == "." then return {"already there"} end
        local d, sent, id = robots.run(r.name, "$0 " .. p)
        if not d then return {"not run: " .. tostring(sent)} end
        return {"route " .. p, ("dry run: %s%s, %s ticks"):format(d.state,
                d.why and (" " .. d.why) or "", tostring(d.ticks)),
                sent and ("sent as " .. id) or "NOT sent"}
    elseif cmd == "sim" then
        local s = require("sim")
        local what, arg = rest:match("^(%S*)%s*(%S*)")
        if what == "start" then s.start()
        elseif what == "clear" then s.clear()
        elseif what == "pause" then s.running = false
        elseif what == "go" then s.running = true
        elseif what == "speed" then s.speed = tonumber(arg) or s.speed end
        local out = {("sim %s: %d packets done, %.0f s of server time, speed x%d"):format(
                s.on and (s.running and "building" or "stopped") or "off", s.ndone,
                s.clock / 13, s.speed)}
        local tm = s.timing
        if tm then
            out[#out + 1] = ("  longest frame %.3f s; programs made %d, longest %.3f s, mean %.3f s")
                    :format(tm.frame_max, tm.makes, tm.make_max,
                            tm.makes > 0 and tm.make_sum / tm.makes or 0)
        end
        for _, r in ipairs(s.robots) do
            local all = r.work + r.idle
            out[#out + 1] = ("  %-13s %-18s %s at %d %d %d  working %d%%  waits %d"):format(
                    r.name, r.packet and r.packet.id or "idle", r.m.state, r.b.x, r.b.y, r.b.z,
                    all > 0 and math.floor(100 * r.work / all) or 0, r.waits)
        end
        for k, why in pairs(s.failed) do
            out[#out + 1] = "  failed " .. k .. ": " .. tostring(why)
        end
        for why, t in pairs(s.idle_why or {}) do
            out[#out + 1] = ("  idle: %-40s %6.0f robot-s"):format(why, t / 13)
        end
        for _, l in ipairs(s.lines) do out[#out + 1] = "  " .. l end
        return out
    elseif cmd == "crew" then
        -- crew <robot> <packet>: one real robot takes one proven packet (redesign/10-live.md)
        local crew = require("crew")
        local name, id = rest:match("^(%S+)%s+(.+)$")
        local out = {}
        if name then
            local ok, why = crew.start(name, id)
            out[1] = ok and why or ("refused: " .. tostring(why))
        end
        for _, l in ipairs(crew.report()) do out[#out + 1] = l end
        return out
    elseif cmd == "lua" then
        local f, err = load(rest:find("^return ") and rest or ("return " .. rest), "control")
        if not f then f, err = load(rest, "control") end
        if not f then return {"error: " .. tostring(err)} end
        local res = table.pack(pcall(f))
        if not res[1] then return {"error: " .. tostring(res[2])} end
        local out = {}
        for i = 2, res.n do out[#out + 1] = show(res[i]) end
        return #out > 0 and out or {"ok"}
    elseif cmd == "reload" then
        if rest == "robots" or rest == "control" then
            return {rest .. " holds links and sockets: restart the program for it"}
        end
        local old = package.loaded[rest]
        if type(old) == "table" and old.unload then pcall(old.unload) end
        package.loaded[rest] = nil
        local ok, err = pcall(require, rest)
        if ok and reinit and reinit[rest] then reinit[rest]() end
        return {ok and (rest .. " reloaded") or ("error: " .. tostring(err))}
    end
    return {"commands: robots, link <name>, unlink <name>, ask <name> <command>, lua <code>, "
            .. "crew [<name> <packet>], reload <module>"}
end

local function session(h)
    local buf = ""
    while true do
        local got = vc.net_recv(h)
        if got == "" then break end
        buf = buf .. got
        while true do
            local line, rest = buf:match("^([^\n]*)\n(.*)$")
            if not line then break end
            buf = rest
            local ok, out = pcall(run, (line:gsub("\r$", "")))
            if not ok then out = {"error: " .. tostring(out)} end
            vc.net_send(h, table.concat(out, "\n") .. "\n.\n")
        end
    end
    vc.net_close(h)
end

function control.start(port)
    local l = vc.net_listen(port or 7790)
    if l < 0 then return false end
    vc.coroutine_spawn(function()
        while true do
            local h = vc.net_accept(l)
            if h >= 0 then vc.coroutine_spawn(session, h) else vc.net_sleep_ms(500) end
        end
    end)
    return true
end

return control
