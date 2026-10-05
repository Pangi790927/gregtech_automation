--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The planner's proof (3d-draw/redesign/05-packets.md, "Proven at planning"): every packet
-- | filled on a planning copy of the world, in the order robots take them, before it may become
-- | work. The user, 2026-10-05: "try to fill the 5x5x8 and only when successful (maybe even with
-- | scafolding, but prove you can remove them) and only then can you queue this work".
-- |
-- |     prove.run(result, want, have, opts)
-- |         result   the planner's (planner.lua): its packets get `steps` or `unproven`
-- |         want     the plan: "x,y,z" -> {name, meta}
-- |         have     the map: function(x, y, z) -> name, meta, guessed | "air" | nil
-- |         opts     {entry = {x, y, z}, yield = function() or nil}: where robots come from (a
-- |                  park); yield, called now and then, lets the program draw while it proves
-- |     -> {proven, unproven, steps, scaffolds, took}
-- |
-- | A packet's steps: {k = "x,y,z", act = "place" | "dig", block = {name, meta}, scaffold}. A
-- | block is placed only where something holds it - a block there that stays (not wild leaves,
-- | which decay; not a robot) or one placed before it - and only from a free cell next to it that
-- | a robot can reach from the last one, or from `entry`. Placing goes layer by layer; a block
-- | nothing holds gets a support chain - scaffold through air from a block that holds, never in a
-- | cell the plan fills - and a layer's supports are dug away once the layer above is done,
-- | proven the same way (the user's algorithm, 2026-10-05). A packet that cannot be
-- | filled is `unproven`, with why, and so is every packet that waits on it; it never becomes work.
-- | Proving a packet on a block placed or a cell dug by an earlier one adds a wait on that one.
-- | A packet is proven only if, once done, its robot still has a way back to `entry`, the station.
-- |
-- | The pathfinder's grid is changed as the proof goes and put back at the end
-- | (route_snapshot / route_restore).
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local route = require("route")
local planner = require("live")("planner")

local prove = {}

local AIR, ROBOT = "minecraft:air", "OpenComputers:robot"
local SCAFFOLD = {"minecraft:cobblestone", 0}
local CHAIN_FAR = 24                    -- how far a support chain reaches from its block
local CHAIN_LOOK = 60000                -- cells looked at for a chain
local LOCAL = 20000                     -- cells looked at for a way inside a packet
local AROUND6 = {{0, -1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}, {0, 1, 0}}
local STANDS = {{0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {1, 0, 0}, {-1, 0, 0}}

local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function unkey(k)
    local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
    return tonumber(x), tonumber(y), tonumber(z)
end

function prove.run(result, want, have, opts)
    opts = opts or {}
    local t0 = vc.app_time()
    if not route.loaded then route.load() end
    vc.route_snapshot()
    local entry = opts.entry or {0, 0, -2}

    -- the planning world: what the proof changed over the map
    local changed, owner, mine = {}, {}, {}      -- k -> {name, meta} | false; k -> packet id
    -- the cells packets were worked from: a later packet that fills one waits for them, else in
    -- parallel it walled the earlier one's work off (the windmill top, 2026-10-05)
    local stood = {}                              -- k -> {packet id = true}
    local function state(x, y, z)
        local k = key(x, y, z)
        local c = changed[k]
        if c ~= nil then
            if c then return c[1], c[2] end
            return "air"
        end
        return have(x, y, z)
    end
    local placed_by_us = {}                      -- leaves the robots placed hold; wild ones don't

    -- the plan's cells still to place, which no scaffold may take
    local to_place = {}
    for id, p in pairs(result.packets) do
        if p.kind == "place" then for _, k in ipairs(p.cells) do to_place[k] = id end end
    end

    local stats = {proven = 0, unproven = 0, steps = 0, scaffolds = 0}
    -- leaves left for the end: cells out of reach to dig, and blocks whose cell still held leaves
    result.leaves, result.after_leaves = {}, {}
    local finished = {}                           -- place packets proven, by box id
    local pos = {entry[1], entry[2], entry[3]}

    -- the cell a step is worked from, reached from `from` (else from entry): its stand, or nil
    local function reach(x, y, z, from)
        for _, d in ipairs(STANDS) do
            local sx, sy, sz = x + d[1], y + d[2], z + d[3]
            if vc.route_get(sx, sy, sz) == 1 then
                local at = {sx, sy, sz}
                if (from[1] == sx and from[2] == sy and from[3] == sz)
                        or route.find(from, "n", at, LOCAL) ~= ""
                        or route.find(entry, "n", at) ~= "" then
                    return at
                end
            end
        end
    end

    -- does something hold a block put at x y z? `extra`: cells this packet placed already
    local function held(x, y, z, p)
        for _, d in ipairs(AROUND6) do
            local nx, ny, nz = x + d[1], y + d[2], z + d[3]
            local name = state(nx, ny, nz)
            if name and name ~= "air" and name ~= ROBOT then
                local nk = key(nx, ny, nz)
                if not name:find("leaves") or placed_by_us[nk] then
                    return true, owner[nk]
                end
            end
        end
        return false
    end

    for n, id in ipairs(result.order) do
        local p = result.packets[id]
        local steps, undo, waits, why = {}, {}, {}, nil
        local function waits_on(q) if q and q ~= p.id then waits[q] = true end end
        local function set(k, block)
            local x, y, z = unkey(k)
            undo[#undo + 1] = {k, changed[k], owner[k], vc.route_get(x, y, z), placed_by_us[k]}
            if block then
                for q in pairs(stood[k] or {}) do waits_on(q) end
            end
            changed[k], owner[k] = block or false, p.id
            vc.route_set(x, y, z, block and 2 or 1)
            if block and block[1]:find("leaves") then placed_by_us[k] = true end
        end
        local here = {pos[1], pos[2], pos[3]}
        local stood_here = {}                     -- this packet's stands, kept if it is proven
        local function stand(at)
            stood_here[#stood_here + 1] = key(at[1], at[2], at[3])
            return at
        end

        -- a block of the plan cannot wait on one that failed
        for w in pairs(p.waits) do
            if result.packets[w] and result.packets[w].unproven then
                why = "waits on " .. w .. ", unproven"
            end
        end

        if not why and p.kind == "dig" then
            -- One cell: dug from a stand reached now. Out of reach, it waits for a later round;
            -- in the last (`last`), one in a tree is left for the end. False: not done.
            local function dig_one(c, last)
                local name, meta, guessed = state(c[1], c[2], c[3])
                if not name or name == "air" then return true end
                local at = reach(c[1], c[2], c[3], here)
                if not at then
                    if not last then return false end
                    -- out of reach in a tree: leaves, or what the leaves wall in - a log, or the
                    -- dirt the first survey guessed inside the crowns (-25,15,13, 2026-10-05).
                    -- Only leaves seen, or guessed and settled by how trees grow (chunks.lua),
                    -- are a tree (redesign/09-paths.md, "Guesses")
                    local in_tree = name:find("leaves") and not guessed
                    if not in_tree then
                        for _, d in ipairs(AROUND6) do
                            local n, _, ng = state(c[1] + d[1], c[2] + d[2], c[3] + d[3])
                            if n and n:find("leaves") and not ng then in_tree = true break end
                        end
                    end
                    if not in_tree then return false end
                    -- leaves out of reach are no reason to stop: they decay once their tree is
                    -- gone, and are looked at again at the end (the user, 2026-10-05:
                    -- "remember leaves and geo scan for them at the end, no bigie")
                    result.leaves[#result.leaves + 1] = key(c[1], c[2], c[3])
                    return true
                end
                waits_on(owner[key(at[1], at[2], at[3])])
                steps[#steps + 1] = {k = key(c[1], c[2], c[3]), act = "dig", block = {name, meta}}
                set(key(c[1], c[2], c[3]), nil)
                here = stand(at)
                return true
            end
            -- a layer at a time, top down; in a layer, a cell not reachable yet is tried again
            -- after the others, while each round digs something (05-packets.md)
            local layers, ys = {}, {}
            for _, k in ipairs(p.cells) do
                local c = {unkey(k)}
                if not layers[c[2]] then layers[c[2]] = {}; ys[#ys + 1] = c[2] end
                table.insert(layers[c[2]], c)
            end
            table.sort(ys, function(a, b) return a > b end)
            for _, y in ipairs(ys) do
                local left = layers[y]
                table.sort(left, function(a, b)
                    if a[3] ~= b[3] then return a[3] < b[3] end
                    return a[1] < b[1]
                end)
                local last = false
                while #left > 0 do
                    local later = {}
                    for _, c in ipairs(left) do
                        if not dig_one(c, last) then later[#later + 1] = c end
                    end
                    if #later == #left then
                        if last then
                            local c = later[1]
                            why = "no way to dig " .. key(c[1], c[2], c[3])
                            break
                        end
                        last = true                  -- nothing more opens: trees left for the end
                    end
                    left = later
                end
                if why then break end
            end
        elseif not why then
            -- Placing, as the user laid it out (2026-10-05): layer by layer, bottom up; in a
            -- layer, the blocks something holds, from a free cell next to them; a block nothing
            -- holds gets a support chain - "find first anchor in the outside world ... build a
            -- road with supports from the support point to the work zone" - scaffold through air
            -- from a block that holds, the shortest, never in a cell the plan fills; the layer
            -- done, the supports of the layer under it are dug away ("remove all supports that
            -- where used ... place a scafold block (if needed) on the next layer and do that
            -- again"); whatever support is left goes at the packet's end.
            local by_y, ys = {}, {}
            for _, k in ipairs(p.cells) do
                local x, y, z = unkey(k)
                if not by_y[y] then by_y[y] = {}; ys[#ys + 1] = y end
                by_y[y][#by_y[y] + 1] = {k = k, x = x, y = y, z = z}
            end
            table.sort(ys)
            local prev, all = {}, {}                 -- supports of the layer below; every one
            local function put_support(k)
                local x, y, z = unkey(k)
                local at = reach(x, y, z, here)
                if not at then return false end
                steps[#steps + 1] = {k = k, act = "place", block = SCAFFOLD, scaffold = true}
                set(k, SCAFFOLD)
                here = stand(at)
                return true
            end
            local function take_away(list)
                table.sort(list, function(a, b)
                    local _, ay = unkey(a)
                    local _, by = unkey(b)
                    return ay > by
                end)
                for _, k in ipairs(list) do
                    if changed[k] and changed[k][1] == SCAFFOLD[1] and owner[k] == p.id then
                        local x, y, z = unkey(k)
                        local at = reach(x, y, z, here)
                        if not at then return "the support at " .. k .. " cannot be taken away" end
                        steps[#steps + 1] = {k = k, act = "dig", block = SCAFFOLD,
                                             scaffold = true}
                        set(k, nil)
                        here = stand(at)
                        stats.scaffolds = stats.scaffolds + 1
                    end
                end
            end
            -- the shortest chain of free cells from a block that holds to the cell c, in the
            -- order it is placed: the anchor's end first
            local function chain_to(c)
                local seen, queue, head = {[c.k] = true}, {}, 1
                local function add(x, y, z, from)
                    local k = key(x, y, z)
                    if not seen[k] and vc.route_get(x, y, z) == 1 and not to_place[k] then
                        seen[k] = true
                        queue[#queue + 1] = {x, y, z, from}
                    end
                end
                for _, d in ipairs(AROUND6) do add(c.x + d[1], c.y + d[2], c.z + d[3], nil) end
                while head <= #queue and head <= CHAIN_LOOK do
                    local n = queue[head]
                    head = head + 1
                    if held(n[1], n[2], n[3], p) then
                        local out, m = {}, n
                        while m do
                            out[#out + 1] = key(m[1], m[2], m[3])
                            m = m[4]
                        end
                        return out
                    end
                    if math.abs(n[1] - c.x) + math.abs(n[2] - c.y) + math.abs(n[3] - c.z)
                            < CHAIN_FAR then
                        for _, d in ipairs(AROUND6) do
                            add(n[1] + d[1], n[2] + d[2], n[3] + d[3], n)
                        end
                    end
                end
            end
            -- The layer's farmland first (redesign/13-farm.md): a hoe tills only with air right
            -- above and not from below, and a robot is a block - so each cell is tilled from
            -- beside, at its level, from a cell still air. Placed (dirt, from above) and tilled at
            -- once, in an order grown as a tree from cells outside the field (its open edge), the
            -- farthest first: each tilled from its parent, placed after it.
            local FARM, DIRT = "minecraft:farmland", {"minecraft:dirt", 0}
            local SIDE4 = {{1, 0, "e"}, {-1, 0, "w"}, {0, 1, "s"}, {0, -1, "n"}}
            local function farm_layer(left)
                local F = {}
                for _, c in ipairs(left) do
                    if want[c.k] and want[c.k][1] == FARM then F[c.k] = c end
                end
                if not next(F) then return nil end
                local parent, order, queue, head = {}, {}, {}, 1
                -- an edge must still be reachable when the field around it is full: its cells
                -- count as blocks while the edges are looked for (a water cell, a plant above it,
                -- reachable only through the empty field, -24,3,14, 2026-10-05)
                local walled = {}
                for k, c in pairs(F) do
                    if vc.route_get(c.x, c.y, c.z) == 1 then
                        walled[#walled + 1] = c
                        vc.route_set(c.x, c.y, c.z, 2)
                    end
                end
                for k, c in pairs(F) do
                    for _, d in ipairs(SIDE4) do
                        local nx, nz = c.x + d[1], c.z + d[2]
                        local nk = key(nx, c.y, nz)
                        -- an open edge: a cell outside the field, air, and a robot can get
                        -- there (an air pocket under a roof or a fence is no edge)
                        if not parent[k] and not F[nk] and state(nx, c.y, nz) == "air"
                                and vc.route_get(nx, c.y, nz) == 1
                                and route.find(entry, "n", {nx, c.y, nz}) ~= "" then
                            parent[k] = {nx, c.y, nz}
                            queue[#queue + 1] = c
                        end
                    end
                end
                for _, c in ipairs(walled) do vc.route_set(c.x, c.y, c.z, 1) end
                while queue[head] do
                    local c = queue[head]
                    head = head + 1
                    order[#order + 1] = c
                    for _, d in ipairs(SIDE4) do
                        local nk = key(c.x + d[1], c.y, c.z + d[2])
                        if F[nk] and not parent[nk] then
                            parent[nk] = {c.x, c.y, c.z}
                            queue[#queue + 1] = F[nk]
                        end
                    end
                end
                for k in pairs(F) do
                    if not parent[k] then
                        return ("farmland at %s cannot be tilled: no cell beside it is free")
                                :format(k)
                    end
                end
                for i = #order, 1, -1 do               -- the farthest first, the edge last
                    local c = order[i]
                    -- a cell still holding something: the general loop below says why
                    if state(c.x, c.y, c.z) ~= "air" then return nil end
                    if state(c.x, c.y + 1, c.z) ~= "air" then
                        return ("farmland at %s: no air above it to till"):format(c.k)
                    end
                    local ok, from = held(c.x, c.y, c.z, p)
                    if not ok then return "no ground under the farmland at " .. c.k end
                    local at = reach(c.x, c.y, c.z, here)
                    if not at then return "no way to place the farmland's dirt at " .. c.k end
                    waits_on(from)
                    steps[#steps + 1] = {k = c.k, act = "place", block = DIRT}
                    set(c.k, DIRT)
                    here = stand(at)
                    local s = parent[c.k]
                    if not ((here[1] == s[1] and here[2] == s[2] and here[3] == s[3])
                            or route.find(here, "n", s, LOCAL) ~= ""
                            or route.find(entry, "n", s) ~= "") then
                        return ("no way beside the farmland at %s to till it (from %d,%d,%d,"
                                .. " grid %d, robot at %d,%d,%d)"):format(c.k, s[1], s[2], s[3],
                                vc.route_get(s[1], s[2], s[3]), here[1], here[2], here[3])
                    end
                    local dir
                    for _, d in ipairs(SIDE4) do
                        if s[1] + d[1] == c.x and s[3] + d[2] == c.z then dir = d[3] end
                    end
                    steps[#steps + 1] = {k = c.k, act = "till", from = s, dir = dir}
                    set(c.k, {FARM, 0})
                    here = stand(s)
                    for i2, l in ipairs(left) do
                        if l == c then table.remove(left, i2) break end
                    end
                end
                return nil
            end
            for _, y in ipairs(ys) do
                local left, mine = by_y[y], {}
                why = why or farm_layer(left)
                table.sort(left, function(a, b)
                    if a.z ~= b.z then return a.z < b.z end
                    return a.x < b.x
                end)
                while #left > 0 and not why do
                    local did = false
                    for i, c in ipairs(left) do
                        local there = state(c.x, c.y, c.z)
                        if there and there ~= "air" and there:find("leaves") then
                            -- leaves there yet: the block waits for the end (TODO.md, 000)
                            result.after_leaves[c.k] = want[c.k]
                            table.remove(left, i)
                            did = true
                            break
                        end
                        if there and there ~= "air" then
                            why = ("%s still holds %s"):format(c.k, there)
                            break
                        end
                        local ok, from = held(c.x, c.y, c.z, p)
                        if ok then
                            local at = reach(c.x, c.y, c.z, here)
                            if at then
                                waits_on(from)
                                waits_on(owner[key(at[1], at[2], at[3])])
                                steps[#steps + 1] = {k = c.k, act = "place", block = want[c.k]}
                                set(c.k, want[c.k])
                                here = stand(at)
                                table.remove(left, i)
                                did = true
                                break
                            end
                        end
                    end
                    if why then break end
                    if not did then
                        -- nothing held and reachable: a support chain to the first block left
                        local c = left[1]
                        local chain = chain_to(c)
                        if not chain then
                            why = ("no anchor for %s within %d (the design needs a support)")
                                    :format(c.k, CHAIN_FAR)
                            break
                        end
                        for _, k in ipairs(chain) do
                            if not put_support(k) then
                                why = "no way to put a support at " .. k
                                break
                            end
                            mine[#mine + 1] = k
                            all[#all + 1] = k
                        end
                    end
                end
                if why then break end
                -- this layer done: the supports of the layer under it away
                why = take_away(prev)
                if why then break end
                prev = mine
            end
            if not why then why = take_away(all) end      -- whatever support is left
        end

        -- the robot must get home from where the packet leaves it, on the world as the packet
        -- leaves it (the user, 2026-10-05: "the planner must prove at least one path to the
        -- station exists in it's work ordering"; redesign/05-packets.md)
        if not why and not (here[1] == entry[1] and here[2] == entry[2] and here[3] == entry[3])
                and route.find(here, "n", entry) == "" then
            why = ("no way back to the station from %d,%d,%d"):format(here[1], here[2], here[3])
        end
        if why then
            -- the packet's changes undone: the world as if it had not been tried
            for i = #undo, 1, -1 do
                local u = undo[i]
                local x, y, z = unkey(u[1])
                changed[u[1]], owner[u[1]], placed_by_us[u[1]] = u[2], u[3], u[5]
                vc.route_set(x, y, z, u[4])
            end
            p.unproven, p.steps = why, nil
            stats.unproven = stats.unproven + 1
        else
            p.steps, p.unproven = steps, nil
            for _, k in ipairs(stood_here) do
                stood[k] = stood[k] or {}
                stood[k][p.id] = true
            end
            for q in pairs(waits) do p.waits[q] = true end
            stats.proven = stats.proven + 1
            stats.steps = stats.steps + #steps
            if p.kind == "place" then finished[p.id] = true end
            pos = here
        end
        if opts.yield and n % 4 == 0 then opts.yield() end
    end
    vc.route_restore()
    stats.leaves, stats.after_leaves = #result.leaves, 0
    for _ in pairs(result.after_leaves) do stats.after_leaves = stats.after_leaves + 1 end
    stats.took = vc.app_time() - t0
    return stats
end

return prove
