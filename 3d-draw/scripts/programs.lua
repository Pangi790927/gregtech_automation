--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The program maker (stage 5 of 3d-draw/redesign/08-order.md): a proven packet into the
-- | program a robot runs (04-notation.md), from where the robot stands. Each move between cells is
-- | routed on the pathfinder's grid as it is at that moment, and each cell done is written back to
-- | the grid, so the next route sees it.
-- |
-- |     programs.make(packet, robot, map)   the program's text, where it ends, and the cells it
-- |                                         does; nil and why when a cell cannot be reached
-- |         packet   the planner's: kind "dig" or "place", cells "x,y,z"
-- |         robot    {pos = {x, y, z}, facing = "n" ..., slot_of = function(name, meta) -> slot,
-- |                   avoid = {["x,y,z"] = true} or nil: other robots' work, kept off (below)}
-- |         map      {want = plan cells by key -> {name, meta}, have = function(x, y, z)}
-- |
-- | Digging goes top down, each block dug from the cell above it (`x-<n>`, the program's palette
-- | naming exactly the block the map has there); placing goes bottom up in rows, back and forth,
-- | each block put down from the cell above (`p-<slot>`), the robot hovering over its work like a
-- | printer (the user, 2026-10-05: "hover place downard like a printer"). Where the cell above is
-- | not free - ground that stays, a block already there - a side cell is tried instead, facing it.
-- |
-- | The cells in `robot.avoid` - the packets other robots are working - count as blocks for the
-- | routes, so a way never runs through ground about to be dug or air about to be filled, where a
-- | robot could be walled in (the user, 2026-10-05; redesign/09-paths.md). The packet's own cells
-- | and the cell the robot stands on stay open.
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local route = require("route")
local machine = require("live")("machine")

local programs = {}

local STEP = machine.STEP_OF
local DIR_CH = {n = "^", s = "v", e = ">", w = "<", u = "+", d = "-"}
local CH_DIR = {["^"] = "n", v = "s", [">"] = "e", ["<"] = "w", ["+"] = "u", ["-"] = "d"}
local SIDES = {{"n", 0, 0, 1}, {"s", 0, 0, -1}, {"e", -1, 0, 0}, {"w", 1, 0, 0}}

local function unkey(k)
    local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
    return tonumber(x), tonumber(y), tonumber(z)
end

-- Where a routed way leads, and the way the robot faces at its end.
local function walk(path, pos, facing)
    local x, y, z, f = pos[1], pos[2], pos[3], facing
    for ch, n in path:gmatch("([%^v<>%+%-])(%d*)") do
        local d = CH_DIR[ch]
        local s = STEP[d]
        local k = tonumber(n) or 1
        x, y, z = x + s[1] * k, y + s[2] * k, z + s[3] * k
        if d ~= "u" and d ~= "d" then f = d end
    end
    return {x, y, z}, f
end

-- Where the robot stands to work a cell, and the direction it works toward: above first (down),
-- else beside it, at its level.
local function stands(c)
    local out = {{c.x, c.y + 1, c.z, "d"}}
    for _, s in ipairs(SIDES) do
        out[#out + 1] = {c.x + s[2], c.y + s[3], c.z + s[4], s[1]}
    end
    return out
end

--[[ The program for a packet, from where the robot stands: its proven steps (prove.lua), in
-- their order - scaffold, blocks, scaffold away - each worked from a free cell next to it, routed
-- from where the robot is by then. Nothing is paused or left over: the proof showed the whole
-- packet can be done; a step with no way to it now is a divergence, and the packet is not made.
-- @return text, end pos, end facing; nil and why ]]
function programs.make(packet, robot, map)
    if not packet.steps then return nil, "not proven: " .. tostring(packet.unproven) end
    local pos, facing = {robot.pos[1], robot.pos[2], robot.pos[3]}, robot.facing
    local ops, palette, pal_ix = {}, {}, {}
    -- which step each of the machine's ops finishes (the program's text parsed: a way "<5v9" is
    -- two ops): for the rest of the steps to be made again after a stop (sim.lua, reroute)
    local opstep, nops = {}, 0
    local marks = {}
    local function unmark()
        for i = #marks, 1, -1 do
            local mk = marks[i]
            vc.route_set(mk[1], mk[2], mk[3], mk[4])
        end
    end
    -- other robots' work walled off while this program is routed; put back with the rest
    if robot.avoid then
        local own = {[pos[1] .. "," .. pos[2] .. "," .. pos[3]] = true}
        for _, st in ipairs(packet.steps) do own[st.k] = true end
        for k in pairs(robot.avoid) do
            if not own[k] then
                local x, y, z = unkey(k)
                local v = vc.route_get(x, y, z)
                if v == 1 then
                    marks[#marks + 1] = {x, y, z, v}
                    vc.route_set(x, y, z, 2)
                end
            end
        end
    end
    local equipped = false                   -- the mattock in hand (13-farm.md)
    for si, st in ipairs(packet.steps) do
        local x, y, z = unkey(st.k)
        local how
        -- a till is done from the one cell the proof chose beside it, facing it
        local cands = st.act == "till" and {{st.from[1], st.from[2], st.from[3], st.dir}}
                or stands({x = x, y = y, z = z})
        for _, sd in ipairs(cands) do
            local at = {sd[1], sd[2], sd[3]}
            local here = at[1] == pos[1] and at[2] == pos[2] and at[3] == pos[3]
            if here or vc.route_get(at[1], at[2], at[3]) == 1 then
                local path = here and "." or route.find(pos, facing, at, LOCAL)
                if path == "" then path = route.find(pos, facing, at) end
                if path ~= "" then how = {path = path, dir = sd[4]} break end
            end
        end
        if not how then
            unmark()
            return nil, "no way to " .. st.act .. " " .. st.k
        end
        if how.path ~= "." then
            ops[#ops + 1] = how.path
            pos, facing = walk(how.path, pos, facing)
            for _ in how.path:gmatch("[%^v<>%+%-]") do nops = nops + 1 end
        end
        if how.dir ~= "u" and how.dir ~= "d" then facing = how.dir end
        if st.act == "till" then
            -- the mattock into the hand once (`e`), the till (`u`), and a look that it took (`?`)
            if not equipped then
                if not robot.tool_slot then
                    unmark()
                    return nil, "no mattock in its slots to till " .. st.k
                end
                ops[#ops + 1] = "e" .. robot.tool_slot
                nops = nops + 1
                equipped = true
            end
            local pk = "minecraft:farmland:*"
            if not pal_ix[pk] then
                palette[#palette + 1] = pk
                pal_ix[pk] = #palette
            end
            ops[#ops + 1] = "u" .. DIR_CH[how.dir]
            ops[#ops + 1] = "?" .. DIR_CH[how.dir] .. pal_ix[pk]
            nops = nops + 2
            opstep[nops] = si
            goto next_step
        end
        nops = nops + 1
        opstep[nops] = si
        if st.act == "dig" then
            local pk = st.block[1] .. ":" .. tostring(st.block[2])
            if not pal_ix[pk] then
                palette[#palette + 1] = pk
                pal_ix[pk] = #palette
            end
            ops[#ops + 1] = "x" .. DIR_CH[how.dir] .. pal_ix[pk]
            -- put back later as it really was, not as it was supposed to be: a re-route's steps
            -- and other robots' work had left blocks the grid called air (2026-10-05)
            marks[#marks + 1] = {x, y, z, vc.route_get(x, y, z)}
            vc.route_set(x, y, z, 1)
        else
            local slot = robot.slot_of(st.block[1], st.block[2])
            if not slot then
                unmark()
                return nil, "no slot left for " .. st.block[1]
            end
            ops[#ops + 1] = "p" .. DIR_CH[how.dir] .. slot
            marks[#marks + 1] = {x, y, z, vc.route_get(x, y, z)}
            vc.route_set(x, y, z, 2)
        end
        ::next_step::
    end
    if equipped then ops[#ops + 1] = "e" .. robot.tool_slot end   -- the pickaxe back in hand
    unmark()
    local head = "$0"
    if #palette > 0 then head = head .. " {" .. table.concat(palette, ",") .. "}" end
    return head .. " " .. table.concat(ops, " "), pos, facing, opstep
end

programs.walk = walk

return programs
