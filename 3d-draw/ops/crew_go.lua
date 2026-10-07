-- The crew loop started on the app as it is (crew.run_all over crew.BUILDERS), for the plan the
-- packets panel has picked (packets.plans[packets.pick]). LEAVE: packet ids kept out of it from
-- its first pass ("left for later"), set as a global before the dofile if wanted. Its progress in
-- RESTART, its end in crew.run_result. (redesign/19-ops.md)
local spawn = require("spawn")
local c = require("crew")
local leave = LEAVE or {}
RESTART = "starting the loop"
spawn(function()
    c.run_result = nil
    local ok, st = xpcall(function()
        -- the left-out packets set on the loop's state as soon as it exists
        spawn(function()
            for _ = 1, 100 do
                if c.run and c.run.left_out then
                    for _, id in ipairs(leave) do c.run.left_out[id] = "left for later" end
                    return
                end
                require("virt_composer").net_sleep_ms(50)
            end
        end)
        RESTART = "the loop running"
        return c.run_all(c.BUILDERS)
    end, debug.traceback)
    c.run_result = ok and "ended" or ("ERROR " .. tostring(st))
end)
return "started"
