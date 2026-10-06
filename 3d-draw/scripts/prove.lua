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
local orient = require("orient")
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
    -- what the build packets place: the plan's block, or what it is built as (farmland as dirt,
    -- worked later - 13-farm.md); the field's work reads the plan itself
    local plan_want = want
    want = setmetatable({}, {__index = function(_, k)
        local b = result.as_built and result.as_built[k]
        return b or plan_want[k]
    end})
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
            if c then return c[1], c[2], false, true end   -- placed by the proof: known
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

    -- the cell a step is worked from, reached from `from` (else from entry): its stand, or nil;
    -- `only`: the stands allowed (default STANDS)
    local function reach(x, y, z, from, only)
        for _, d in ipairs(only or STANDS) do
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
    -- Only a block the place's ray can click holds (orient.clickable): a plant, a crop or water
    -- does not - a replaceable plant clicked even takes the block in its own cell (ItemBlock),
    -- a fence beside a bush had gone into the bush (the scarecrow's -22,6,21, 2026-10-05).
    local function held(x, y, z, p)
        for _, d in ipairs(AROUND6) do
            local nx, ny, nz = x + d[1], y + d[2], z + d[3]
            local name = state(nx, ny, nz)
            if name and name ~= "air" and name ~= ROBOT and orient.clickable(name) then
                local nk = key(nx, ny, nz)
                if not name:find("leaves") or placed_by_us[nk] then
                    return true, owner[nk]
                end
            end
        end
        return false
    end

    -- Water (redesign/13-farm.md, "The water step"): poured only into a cell sealed - its floor
    -- and four sides solid, else it spreads; and a till only with water in Hunger Overhaul's
    -- reach (isWaterNearby: 4 across, the dirt's level or one up).
    local WATER = "minecraft:water"
    local function sealed(x, y, z)
        for _, d in ipairs({{0, -1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}) do
            local n = state(x + d[1], y + d[2], z + d[3])
            if not n or n == "air" then return false, key(x + d[1], y + d[2], z + d[3]) end
        end
        return true
    end
    local function water_near(x, y, z)
        for dx = -4, 4 do
            for dy = 0, 1 do
                for dz = -4, 4 do
                    local n = state(x + dx, y + dy, z + dz)
                    if n and n:find("water", 1, true) then return true end
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

        if not why and p.field then
            why = prove.field_work(p, {state = state, set = set, reach = reach, held = held,
                stand = stand, waits_on = waits_on, water_near = water_near, entry = entry,
                here = function(v) if v then here = v end return here end,
                want = plan_want, steps = steps, result = result, undo = undo})
        elseif not why and p.kind == "dig" then
            -- One cell: dug from a stand reached now. Out of reach, it waits for a later round;
            -- in the last (`last`), one in a tree is left for the end. False: not done.
            local function dig_one(c, last)
                local name, meta, guessed, exact = state(c[1], c[2], c[3])
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
                steps[#steps + 1] = {k = key(c[1], c[2], c[3]), act = "dig", block = {name, meta},
                                     natural = not exact}
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
            -- A water cell poured from the cell above, once sealed (13-farm.md, "The water
            -- step"): nil, or why not.
            local ABOVE = {{0, 1, 0}}
            local function pour(c)
                local there = state(c.x, c.y, c.z)
                if there ~= "air" then
                    return ("the water's cell %s still holds %s"):format(c.k, tostring(there))
                end
                local ok, open = sealed(c.x, c.y, c.z)
                if not ok then
                    return ("the water at %s would spread: %s is open"):format(c.k, open)
                end
                local at = reach(c.x, c.y, c.z, here, ABOVE)
                if not at then return "no way above the water at " .. c.k .. " to pour it" end
                for _, d in ipairs({{0, -1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}) do
                    waits_on(owner[key(c.x + d[1], c.y + d[2], c.z + d[3])])
                end
                waits_on(owner[key(at[1], at[2], at[3])])
                steps[#steps + 1] = {k = c.k, act = "water", block = {WATER, 0}}
                set(c.k, {WATER, 0})
                here = stand(at)
                return nil
            end
            -- A block whose way the place decides (14-turn.md): a stand and a face that make the
            -- plan's way, the block the face clicks there now, the stand reached. -> the way
            -- {f, s}, the stand, the clicked cell's packet; nil when none is open yet.
            local function turned_way(c)
                local b = want[c.k]
                c.fails = {}                       -- why each way is shut, for the why-not
                for _, wy in ipairs(orient.ways(b[1], b[2])) do
                    local off = orient.click(wy.f, wy.s)
                    local cx, cy, cz = c.x + off[1], c.y + off[2], c.z + off[3]
                    local v = orient.V[wy.f]
                    if orient.clickable(state(cx, cy, cz)) then
                        local at = reach(c.x, c.y, c.z, here, {{-v[1], -v[2], -v[3]}})
                        if at then return wy, at, owner[key(cx, cy, cz)] end
                        c.fails[#c.fails + 1] = ("%s/%s: stand %s not free or reached"):format(
                                wy.f, wy.s, key(c.x - v[1], c.y - v[2], c.z - v[3]))
                    else
                        c.fails[#c.fails + 1] = ("%s/%s: click %s is %s"):format(wy.f, wy.s,
                                key(cx, cy, cz), tostring(state(cx, cy, cz)))
                    end
                end
            end
            for yi, y in ipairs(ys) do
                local left, mine = by_y[y], {}
                local function wet(c) return want[c.k] and want[c.k][1] == WATER end
                local function turned(c) return want[c.k] and orient.has(want[c.k][1]) end
                -- a door goes first in its layer: its hinge counts the blocks beside it as they
                -- are then - placed before a double door's frame, else tried again after it
                local function door(c) return want[c.k] and orient.door(want[c.k][1]) end
                table.sort(left, function(a, b)
                    if wet(a) ~= wet(b) then return wet(b) end    -- water after the rest
                    if door(a) ~= door(b) then return door(a) end
                    if turned(a) ~= turned(b) then return turned(b) end  -- turned after plain
                    if a.z ~= b.z then return a.z < b.z end
                    return a.x < b.x
                end)
                -- A block standing on the only stand of a turned block still to come goes
                -- after it (a fence in front of a stair, a roof's stair on the next one's stand:
                -- -14,3,18 and -1,10,38, 2026-10-05) - unless nothing else can be done.
                local function only_stand(c)
                    for _, t in ipairs(left) do
                        if t ~= c and turned(t) then
                            local b, other, on_it = want[t.k], false, false
                            for _, wy in ipairs(orient.ways(b[1], b[2])) do
                                local v = orient.V[wy.f]
                                local sx, sy, sz = t.x - v[1], t.y - v[2], t.z - v[3]
                                local sk = key(sx, sy, sz)
                                if sk == c.k then
                                    on_it = true
                                elseif state(sx, sy, sz) == "air" or to_place[sk] then
                                    other = true          -- a stand solid for good is none
                                end
                            end
                            if on_it and not other then return true end
                        end
                    end
                    return false
                end
                local force = false
                while #left > 0 and not why do
                    local did, deferred = false, false
                    for i, c in ipairs(left) do
                        if not force and only_stand(c) then
                            deferred = true
                            goto next_cell
                        end
                        if wet(c) then
                            -- poured once sealed; else tried again after the others
                            if sealed(c.x, c.y, c.z) then
                                why = pour(c)
                                if why then break end
                                table.remove(left, i)
                                did = true
                                break
                            end
                            goto next_cell
                        end
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
                        if turned(c) then
                            -- from the stand and face that make its way; else after the others
                            local wy, at, from = turned_way(c)
                            -- a door: its upper half comes with it, the hinge by what stands
                            -- beside it now - not the plan's yet: later, when more is there
                            local b0 = want[c.k]
                            if wy and orient.door(b0[1]) then
                                local upk = key(c.x, c.y + 1, c.z)
                                local up = want[upk]
                                local function cube(x, y, z)
                                    local n = state(x, y, z)
                                    return n and n ~= "air" and orient.normal_cube(n)
                                end
                                local function door(x, y, z) return state(x, y, z) == b0[1] end
                                local m = orient.door_upper(c.x, c.y, c.z, b0[2], cube, door)
                                if state(c.x, c.y + 1, c.z) ~= "air" or not up or up[2] ~= m then
                                    c.fails = {("its upper half: %s there, hinge %d, the plan %s")
                                            :format(tostring(state(c.x, c.y + 1, c.z)), m,
                                                    tostring(up and up[2]))}
                                    wy = nil
                                end
                            end
                            if wy then
                                waits_on(from)
                                waits_on(owner[key(at[1], at[2], at[3])])
                                steps[#steps + 1] = {k = c.k, act = "place", block = want[c.k],
                                                     dir = wy.f, face = wy.s}
                                set(c.k, want[c.k])
                                if orient.door(b0[1]) then
                                    local upk = key(c.x, c.y + 1, c.z)
                                    set(upk, want[upk])           -- the upper half with it
                                end
                                here = stand(at)
                                table.remove(left, i)
                                did = true
                                break
                            end
                            goto next_cell
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
                        ::next_cell::
                    end
                    if why then break end
                    if did then force = false end
                    if not did and deferred and not force then
                        force = true                      -- the deferred ones, after all
                        goto next_round
                    end
                    -- doors whose hinge is not the plan's yet wait into the layer above, its
                    -- blocks beside them there too (-13,3,10: planks one side, a log the other,
                    -- the upper log a layer up, 2026-10-06)
                    if not did and door(left[1]) then
                        local up_y = ys[yi + 1]
                        if not up_y then
                            up_y = y + 1
                            ys[#ys + 1] = up_y
                            by_y[up_y] = {}
                        end
                        local moved = 0
                        for i = #left, 1, -1 do
                            -- two layers above its own at most: a hinge never right is a why
                            if door(left[i]) and up_y <= left[i].y + 2 then
                                table.insert(by_y[up_y], table.remove(left, i))
                                moved = moved + 1
                            end
                        end
                        if moved > 0 then
                            if #left == 0 then break end
                            goto next_round
                        end
                    end
                    if not did and turned(left[1]) then
                        -- only turned blocks left, none with its way open: a support where a way
                        -- clicks - an eave's stair has nothing under it or beyond it by design -
                        -- on a chain from an anchor if nothing holds it there, taken away with
                        -- the layer's supports; its stand open and reached now
                        local c = left[1]
                        local b = want[c.k]
                        local ways = orient.ways(b[1], b[2])
                        local done_one = false
                        for _, wy in ipairs(ways) do
                            local v, off = orient.V[wy.f], orient.click(wy.f, wy.s)
                            local ck = key(c.x + off[1], c.y + off[2], c.z + off[3])
                            local cx, cy, cz = unkey(ck)
                            if state(cx, cy, cz) == "air" and not to_place[ck]
                                    and vc.route_get(cx, cy, cz) == 1
                                    and reach(c.x, c.y, c.z, here,
                                              {{-v[1], -v[2], -v[3]}}) then
                                local chain = {}
                                if not held(cx, cy, cz, p) then
                                    chain = chain_to({k = ck, x = cx, y = cy, z = cz}) or false
                                end
                                if chain then
                                    chain[#chain + 1] = ck
                                    local all_put = true
                                    for _, k in ipairs(chain) do
                                        if not put_support(k) then all_put = false break end
                                        mine[#mine + 1] = k
                                        all[#all + 1] = k
                                    end
                                    if all_put then done_one = true break end
                                end
                            end
                        end
                        if not done_one then
                            why = ("no stand and face to place %s %s:%d its way (%d ways, none"
                                   .. " open, nor a support for the click: %s)"):format(c.k, b[1],
                                   b[2], #ways, table.concat(c.fails or {}, "; ", 1,
                                   math.min(3, #(c.fails or {}))))
                            break
                        end
                        goto next_round
                    end
                    if not did and wet(left[1]) then
                        -- only water left, and none of it sealed: it would spread
                        local c = left[1]
                        local _, open = sealed(c.x, c.y, c.z)
                        why = ("the water at %s would spread: %s is open"):format(c.k, open)
                        break
                    end
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
                    ::next_round::
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

--[[ A field's work, from below (redesign/13-farm.md, "Tilling from below"): down through the exit
-- cell E (dug, then the cell under it), a walk depth first through the cells under the farmland -
-- each dug, the farmland above it tilled from it, and filled back on the way out of it - then out
-- through E, the cell under E and E filled back (E is left dirt: the user tills it by hand), and
-- the wheat planted from two above each farmland cell. Nothing goes right above farmland: the
-- cells over the field are kept off the routes from the start (p.lock), and every step names the
-- cell it is done from. `c`: the proof's own functions and state. -> nil, or why not. ]]
function prove.field_work(p, c)
    local FARM, DIRT, GROUNDS = "minecraft:farmland", {"minecraft:dirt", 0},
            {["minecraft:dirt"] = true, ["minecraft:grass"] = true}
    local cells, at_key = {}, {}
    for _, k in ipairs(p.farm or {}) do
        local x, y, z = unkey(k)
        local f = {k = k, x = x, y = y, z = z}
        cells[#cells + 1] = f
        at_key[k] = f
        local n = c.state(x, y, z)
        if not (GROUNDS[n] or n == FARM) then
            return ("the field's %s is %s, not dirt yet"):format(k, tostring(n))
        end
        local u = c.state(x, y - 1, z)
        if not GROUNDS[u] then
            return ("the field is not two deep: under %s is %s"):format(k, tostring(u))
        end
    end
    if #cells == 0 then return "a field with no farmland" end
    -- The exit, its wheat never planted: a cell whose planting stand two above is taken first
    -- (a scarecrow's arm over it, -22,5,21, 2026-10-06), else any - but one the robot gets to and
    -- away from with the cells over the rest of the field kept off its routes (p.lock): it comes
    -- down and goes up that way, never over farmland.
    local order = {}
    for _, f in ipairs(cells) do
        if c.state(f.x, f.y + 2, f.z) ~= "air" then order[#order + 1] = f end
    end
    for _, f in ipairs(cells) do
        if c.state(f.x, f.y + 2, f.z) == "air" then order[#order + 1] = f end
    end
    local E, top, marks
    local function lock_all_but(e)
        local m = {}
        for _, f in ipairs(cells) do
            if f ~= e and vc.route_get(f.x, f.y + 1, f.z) == 1 then
                m[#m + 1] = {f.x, f.y + 1, f.z}
                vc.route_set(f.x, f.y + 1, f.z, 2)
            end
        end
        return m
    end
    local function unlock_marks(m)
        for _, x in ipairs(m) do
            if vc.route_get(x[1], x[2], x[3]) == 2 and c.state(x[1], x[2], x[3]) == "air" then
                vc.route_set(x[1], x[2], x[3], 1)
            end
        end
    end
    for _, f in ipairs(order) do
        if c.state(f.x, f.y + 1, f.z) == "air" then
            local m = lock_all_but(f)
            top = c.reach(f.x, f.y, f.z, c.here(), {{0, 1, 0}})
            if top and route.find(top, "n", c.entry) ~= "" then E, marks = f, m break end
            unlock_marks(m)
        end
    end
    if not E then
        return "no farmland cell of the field reached from above and left, for its exit"
    end
    p.lock = {}
    for _, m in ipairs(marks) do p.lock[#p.lock + 1] = key(m[1], m[2], m[3]) end
    local function unlock() unlock_marks(marks) end
    -- one step, done from cell `from` toward `dir`: the robot gets there first
    local function step(st, from)
        local h = c.here()
        if not ((h[1] == from[1] and h[2] == from[2] and h[3] == from[3])
                or route.find(h, "n", from, LOCAL) ~= ""
                or route.find(c.entry, "n", from) ~= "") then
            return ("no way to %d,%d,%d to %s %s"):format(from[1], from[2], from[3], st.act, st.k)
        end
        st.from = {from[1], from[2], from[3]}
        c.steps[#c.steps + 1] = st
        c.here(c.stand(from))
        return nil
    end
    local function name_at(x, y, z)
        local n, m = c.state(x, y, z)
        return {n, m or 0}
    end
    local ex, ey, ez = E.x, E.y, E.z
    local why = step({k = E.k, act = "dig", block = name_at(ex, ey, ez), dir = "d"}, top)
    if why then unlock() return why end
    c.set(E.k, nil)
    local U0 = key(ex, ey - 1, ez)
    why = step({k = U0, act = "dig", block = name_at(ex, ey - 1, ez), dir = "d"}, {ex, ey, ez})
    if why then unlock() return why end
    c.set(U0, nil)
    local SIDE4 = {{1, 0, "e"}, {-1, 0, "w"}, {0, 1, "s"}, {0, -1, "n"}}
    local visited = {[E.k] = true}
    local function visit(f)
        local u = {f.x, f.y - 1, f.z}
        if f ~= E then
            if not c.water_near(f.x, f.y, f.z) then
                return ("no water within 4 of the farmland at %s: it would not till"):format(f.k)
            end
            if c.state(f.x, f.y + 1, f.z) ~= "air" then
                return ("farmland at %s: no air above it to till"):format(f.k)
            end
            if c.state(f.x, f.y, f.z) ~= FARM then
                local w = step({k = f.k, act = "till", dir = "u"}, u)
                if w then return w end
                c.set(f.k, {FARM, 0})
            end
        end
        for _, d in ipairs(SIDE4) do
            local g = at_key[key(f.x + d[1], f.y, f.z + d[2])]
            if g and not visited[g.k] then
                visited[g.k] = true
                local vk = key(g.x, g.y - 1, g.z)
                local w = step({k = vk, act = "dig", block = name_at(g.x, g.y - 1, g.z),
                                dir = d[3]}, u)
                if w then return w end
                c.set(vk, nil)
                w = visit(g)
                if w then return w end
                w = step({k = vk, act = "place", block = DIRT, dir = d[3]}, u)
                if w then return w end
                c.set(vk, DIRT)
            end
        end
        return nil
    end
    why = visit(E)
    if not why then
        why = step({k = U0, act = "place", block = DIRT, dir = "d"}, {ex, ey, ez})
        if not why then c.set(U0, DIRT) end
    end
    if not why then
        why = step({k = E.k, act = "place", block = DIRT, dir = "d"}, top)
        if not why then c.set(E.k, DIRT) end
    end
    if why then unlock() return why end
    -- the dirt under every farmland cell is back: the wheat, from two above each
    p.exit = E.k
    c.result.field_exit = c.result.field_exit or {}
    for _, f in ipairs(cells) do
        local wk = key(f.x, f.y + 1, f.z)
        local wb = c.want[wk]
        if f == E then
            if wb then c.result.field_exit[wk] = wb end
        elseif wb and wb[1] == "minecraft:wheat" then
            -- from two above; or, that cell taken (a scarecrow's fence), from beside at the
            -- wheat's level over ground that is not farmland, facing down: the seeds click the
            -- farmland's top all the same
            local w = step({k = wk, act = "place", block = wb, dir = "d"}, {f.x, f.y + 2, f.z})
            if w then
                for _, d in ipairs(SIDE4) do
                    local sx, sz = f.x - d[1], f.z - d[2]
                    local under = c.state(sx, f.y, sz)
                    if c.state(sx, f.y + 1, sz) == "air" and under and under ~= "air"
                            and under ~= FARM and vc.route_get(sx, f.y + 1, sz) == 1 then
                        w = step({k = wk, act = "place", block = wb, dir = d[3], face = "d"},
                                 {sx, f.y + 1, sz})
                        if not w then break end
                    end
                end
            end
            if w then
                -- no stand for it (boxed in by the plan's own blocks): left for the user, as the
                -- exit's is
                c.result.field_exit[wk] = wb
            else
                c.set(wk, wb)
            end
        end
    end
    unlock()
    return nil
end

return prove
