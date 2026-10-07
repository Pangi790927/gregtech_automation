-- Each builder linked anew once it is idle, so its zone gets robot/machine.lua as it is now (a
-- relink restarts the zone: never under a program). A job of its own while it relinks, so the
-- crew loop hands it nothing meanwhile. The copies' machine read again first. RELINKED says how
-- far it got.
local vc = require("virt_composer")
local robots, crew = require("robots"), require("crew")
package.loaded["machine"] = nil
require("machine")
RELINKED = "waiting"
local left = {}
for _, n in ipairs(crew.BUILDERS) do left[n] = true end
require("spawn")(function()
    local t0 = vc.app_time()
    while next(left) and vc.app_time() - t0 < 3600 do
        for n in pairs(left) do
            local r = robots.by[n]
            local busy = crew.jobs[n] or (crew.run and crew.run.working and crew.run.working[n])
                    or not r.sf or r.sf.state == "run" or r.sf.state == "wait"
                    or robots.in_flight(r) or #r.outbox > 0
            if not busy then
                crew.jobs[n] = {p = {id = "relink", cells = {}, steps = {}},
                                phase = "linked anew", t0 = vc.app_time()}
                robots.link(n, false)
                robots.link(n, true)
                for _ = 1, 60 do
                    vc.net_sleep_ms(1000)
                    if r.phase == "linked" and r.slots then break end
                end
                vc.net_sleep_ms(2000)
                crew.resync(n)
                crew.jobs[n] = nil
                left[n] = nil
                RELINKED = RELINKED .. "; " .. n .. " " .. tostring(r.phase)
            end
        end
        vc.net_sleep_ms(1000)
    end
    RELINKED = RELINKED .. " | done"
end)
return "armed"
