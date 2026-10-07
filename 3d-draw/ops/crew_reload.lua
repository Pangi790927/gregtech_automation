-- The crew's code read again WITHOUT waiting for the trips (the user, 2026-10-06: robots idle
-- while a restart waited): the loop stopped (it returns at once, st.reload), then programs,
-- crewfix, planner, prove, orient, simbot and crew read again; the running trips go on in the old
-- crew module, whose state is shared or forwarded to the new one; the new loop takes over at once.
-- Not robots.lua, relay.lua, me.lua or copy.lua's state: they hold sockets and copies - an app
-- restart. Its progress in RESTART. (redesign/19-ops.md)
local vc = require("virt_composer")
RESTART = "reload: stopping the loop"
vc.coroutine_spawn(function()
    local old = require("crew")
    if old.run and not old.run.ended then
        old.run.reload, old.run.stop = true, true
        local t0 = vc.app_time()
        while not old.run.ended and vc.app_time() - t0 < 120 do vc.net_sleep_ms(500) end
    end
    for _, name in ipairs({"programs", "crewfix", "planner", "prove"}) do
        package.loaded[name] = nil              -- held by name (live.lua): read again
        require(name)
    end
    -- orient and simbot read again into their own tables: copy and prove hold them by value
    local old_orient = package.loaded["orient"]
    for k, v in pairs(dofile("scripts/orient.lua")) do old_orient[k] = v end
    local old_simbot = package.loaded["simbot"]
    for k, v in pairs(dofile("scripts/simbot.lua")) do old_simbot[k] = v end
    -- a copy keeps the hw it was made with: the idle ones made anew (a running one is not -
    -- ASIMO's old copy diverged on the leaves fix it never got, 2026-10-06)
    dofile("ops/fresh_copies.lua")
    local old_copy = package.loaded["copy"]
    old_copy.compare_inventory = dofile("scripts/copy.lua").compare_inventory
    package.loaded["crew"] = nil
    local new = require("crew")
    for _, k in ipairs({"jobs", "log", "done", "NO_LOADER_OK"}) do
        if old[k] ~= nil then new[k] = old[k] end
    end
    old.me_queue = old.me_queue or {}
    new.me_queue = old.me_queue
    -- forwarded, not copied: what the old code's trips write after the reload lands in the new
    -- loop's state - a packet a trip begun before it finished had its done mark kept in the old
    -- module's table, and the new loop handed it out again at once (Cortana's 0 1 8)
    local FWD = {me_owner = true, last_learned = true, plan_done = true, plan_done_of = true,
                 finished_at = true}
    for k in pairs(FWD) do
        if rawget(old, k) ~= nil or (k ~= "plan_done" and k ~= "finished_at") then
            new[k] = rawget(old, k)
        end
        rawset(old, k, nil)
    end
    setmetatable(old, {
        __index = function(_, k) if FWD[k] then return new[k] end end,
        __newindex = function(t, k, v) if FWD[k] then new[k] = v else rawset(t, k, v) end end})
    RESTART = "reloaded; the loop again"
    new.run_result = nil
    local ok, st = xpcall(new.run_all, debug.traceback, new.BUILDERS)
    new.run_result = ok and "ended" or ("ERROR " .. tostring(st))
end)
return "reload begun"
