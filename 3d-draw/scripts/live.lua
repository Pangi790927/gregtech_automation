--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | A module held by name, not by value: every use looks it up in package.loaded, so a module
-- | read again from its file (the control port's `reload <name>`) is the one used from then on,
-- | with no restart of the program (the user, 2026-10-05: "why can't you hot swap the algo? such
-- | that a restart can be done without restarting the app?").
-- |
-- |     local live = require("live")
-- |     local planner = live("planner")      used as the module itself
-- |
-- | Not for modules that hold sockets or coroutines across a swap (robots, control).
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

return function(name)
    return setmetatable({}, {__index = function(_, k) return require(name)[k] end,
                             __newindex = function(_, k, v) require(name)[k] = v end})
end
