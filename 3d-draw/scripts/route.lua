--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | Routes over the whole known map (route_composer.h, 3d-draw/redesign/09-paths.md).
-- |
-- |     route.load()                   every chunk kept (data/chunks/overview.txt) into the
-- |                                    pathfinder's grid, scouted, built and fixed over them;
-- |                                    the cells known; done once, on the first route
-- |     route.find(from, facing, to)   the way, in the program's notation ("" when none); from
-- |                                    and to robot {x, y, z}, facing "n" "e" "s" "w"
-- |     route.set(x, y, z, state)      a cell changed (0 unknown, 1 air, 2 block, 3 liquid)
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local view = require("view")

local route = {loaded = false, cells = 0, took = 0, box = nil}

local FACING = {n = 0, e = 1, s = 2, w = 3}
local LIMIT = 400000                    -- cells looked at before a route is given up

function route.load()
    local t = vc.app_time()
    local cx0, cx1, cz0, cz1 = math.huge, -math.huge, math.huge, -math.huge
    for line in io.lines("data/chunks/overview.txt") do
        local cx, cz = line:match("^chunk (-?%d+) (-?%d+)")
        if cx then
            cx, cz = tonumber(cx), tonumber(cz)
            cx0, cx1 = math.min(cx0, cx), math.max(cx1, cx)
            cz0, cz1 = math.min(cz0, cz), math.max(cz1, cz)
        end
    end
    if cx0 == math.huge then return false end
    local a = view.anchor
    route.cells = vc.route_load("data/chunks", cx0, cx1, cz0, cz1, a[1], a[2], a[3],
                                "data/scouted.txt\ndata/built.txt\ndata/fixed.txt")
    route.box = {cx0, cx1, cz0, cz1}
    route.loaded = route.cells >= 0
    route.took = vc.app_time() - t
    return route.loaded
end

function route.find(from, facing, to, limit)
    if not route.loaded then route.load() end
    return vc.route_find(from[1], from[2], from[3], FACING[facing] or 0, to[1], to[2], to[3],
                         limit or LIMIT)
end

function route.set(x, y, z, state)
    if route.loaded then vc.route_set(x, y, z, state) end
end

return route
