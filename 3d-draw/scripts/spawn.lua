--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | vc.coroutine_spawn with its handle kept until the coroutine ends. A spawn whose handle nobody
-- | keeps can be collected before the pool first runs it: start() only queues run(), and run()
-- | takes its own reference only once it begins, so a collection in between ran the destructor -
-- | close() emptied the thread - and run() found "Nothing to call, set_call() first", the
-- | function never run and nobody told (three crew trips that never began, 2026-10-06;
-- | ../utils/virt_composer_coroutines). The utils' own tests (homeauto/core/tests) keep every
-- | handle; so do we (the user, 2026-10-06: "the core/tests keep a reference, then so should we").
-- |
-- |     local spawn = require("spawn")
-- |     spawn(f, ...)                  as vc.coroutine_spawn(f, ...): the coroutine, answered;
-- |                                    held in spawn.live until f returns or throws
-- |
-- | @date 2026-10-06
-- | ===============================================================================================
--]]

local vc = require("virt_composer")

local spawn = {live = {}}               -- token -> the coroutine's handle, while it runs

setmetatable(spawn, {__call = function(_, f, ...)
    local token = {}
    -- the token is let go when f ends, however it ends; an error goes on as it did unwrapped
    local co = vc.coroutine_spawn(function(...)
        local res = table.pack(pcall(f, ...))
        spawn.live[token] = nil
        if not res[1] then error(res[2], 0) end
        return table.unpack(res, 2, res.n)
    end, ...)
    -- kept before the pool can run it: spawn only queues it, so f has not begun yet
    spawn.live[token] = co
    return co
end})

return spawn
