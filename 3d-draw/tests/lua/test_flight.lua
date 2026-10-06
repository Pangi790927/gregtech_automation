--[[ A robot's programs one at a time, and its link kept through the PC's own stills
-- (redesign/15-crew.md, "What sank the crew"): the watchdog had closed links while a plan held
-- the program still 36 s, killing the robots' programs (ASIMO's place -3 0 2 twice, Baymax's
-- place -1 0 7); and a second program sent while the first was on its way or running replaced
-- it part way, robot and copy apart (Dalek_Sec 1 2 -3, Pintsize 0 0 -5 and 0 0 -4, Baymax
-- 2 -2 -5 against copies at their parks, 2026-10-06).
-- @date 2026-10-06 ]]

local robots = require("robots")

local function run_test()
    -- the watchdog: a round 40 s after the last (the program stood still) moves that off the
    -- ask; a robot truly silent past SILENT is closed
    local closed = {}
    local function rec(name, asked)
        return {name = name, asked = asked, conn = {close = function() closed[name] = true end}}
    end
    local order = robots.order
    local a, b = rec("A", 59), rec("B", 80)
    robots.order = {a, b}
    robots.watch_round(100, 60)                  -- 39 s of the program's own still
    if closed.A then robots.order = order; return "watchdog: closed through the PC's still" end
    if a.asked ~= 98 then robots.order = order; return "watchdog: the still not moved off" end
    robots.watch_round(101, 100)                 -- a second on: B's ask was moved by the
                                                 -- still too (80 + 39 = 119): not silent
    if closed.B then robots.order = order; return "watchdog: B closed though moved" end
    local c = rec("C", 70)
    robots.order = {c}
    robots.watch_round(100, 99)                  -- no still: C silent 30 s
    robots.order = order
    if not closed.C then return "watchdog: a silent robot not closed" end

    -- robots.run: refused over a program running or still on its way, "busy"
    local by = robots.by
    local r = {name = "R", linked = true, slots = {}, outbox = {},
               sf = {id = "p1", state = "run", op = 3, pos = {0, 0, 0}, facing = "n"}}
    robots.by = {R = r}
    local d, sent = robots.run("R", "$0 ^")
    if sent or not d or d.state ~= "busy" then
        robots.by = by
        return "robots.run: a program sent over a running one"
    end
    r.sf.state = "wait"
    d, sent = robots.run("R", "$0 ^")
    if sent or d.state ~= "busy" then robots.by = by; return "robots.run: over a waiting one" end
    r.sf.state, r.sent = "done", {id = "p2", t = robots.net.now(), ticket = {}}
    d, sent = robots.run("R", "$0 ^")
    if sent or d.state ~= "busy" then robots.by = by; return "robots.run: over one on its way" end
    -- seen in its status: no longer on its way
    r.sf.id = "p2"
    if robots.in_flight(r) then robots.by = by; return "in_flight: seen, still on its way" end
    robots.by = by
    return nil
end

return {run_test = run_test}
