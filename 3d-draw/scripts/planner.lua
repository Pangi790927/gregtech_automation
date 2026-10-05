--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The planner (3d-draw/redesign/05-packets.md): a plan against the map, cut into dig and place
-- | packets on the world's fixed 5 x 5 x 8 grid, ordered, and checked that it can be built. Plain
-- | Lua, no `vc`: the tests run it without a window.
-- |
-- |     local p = planner.plan(want, have)
-- |         want    robot "x,y,z" -> {name, meta, ...}: the plan (plan.lua reads its files);
-- |                 "minecraft:air" is ground the plan digs away
-- |         have    function(x, y, z) -> name, meta | "air" | nil (never scanned), robot
-- |                 coordinates: the map
-- |     p.packets   by id: {id, kind = "dig" | "place", box = {bx, by, bz}, cells = {...},
-- |                 waits = {ids}, order = n}
-- |     p.order     the ids, in the order robots take them
-- |     p.problems  {unknown, flying, cycle, water = {...}}: what cannot be planned (water: for a
-- |                 bucket, later - its cell cleared), by
-- |                 cell or packet, for the user
-- |     p.stats     counts
-- |
-- | The rules, the user's (2026-10-05):
-- |   - the grid is fixed in the world: box (x // 5, y // 8, z // 5), robot coordinates;
-- |   - "dig everything that must go first and build bottom up": every dig packet before any
-- |     place packet, digs top to bottom (a dig waits for the one above it), places bottom to
-- |     top (a place waits for the one below it);
-- |   - nothing flying: a block is placed against something already there - ground that stays,
-- |     or a block placed before it; a block with neither is a problem (scaffolding, later);
-- |   - a block that hangs on something waits for the packet holding what it hangs on.
-- | A cell the map never scanned cannot be planned: listed, for a scout to read first.
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local planner = {}

local AIR = "minecraft:air"
planner.W, planner.H = 5, 8

local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function unkey(k)
    local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
    return tonumber(x), tonumber(y), tonumber(z)
end

function planner.box_of(x, y, z)
    return x // planner.W, y // planner.H, z // planner.W
end

-- Whether the block there already is the one wanted. Leaves keep their kind in meta & 3 (the game
-- sets decay bits on top); ground the plan calls dirt may be grass, and the other way round
-- (placing.py's "hidden ground is kept").
local GROUND = {["minecraft:dirt"] = true, ["minecraft:grass"] = true}
local function same(wname, wmeta, hname, hmeta)
    if wname == hname then
        if wname:find("leaves") then return (wmeta & 3) == (hmeta & 3) end
        -- a crop of any growth stage is the plan's wheat - nothing waits for it to grow - and
        -- farmland of any moisture its farmland (redesign/13-farm.md)
        if wname == "minecraft:wheat" or wname == "minecraft:farmland" then return true end
        return wmeta == hmeta
    end
    return GROUND[wname] and GROUND[hname] or false
end

-- The sides a placed block may lean on: below first, then the four around. Not above: the robot
-- prints from there.
local SUPPORTS = {{0, -1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}

-- A plant that may go: tall grass and Biomes O' Plenty foliage (docs/map.md, "Grass is broken as
-- soon as it is named"); lavender stays (BOP flowers2:3, the user, 2026-10-04).
local function plant(name)
    return name and (name:find("tallgrass", 1, true) or name:find("BiomesOPlenty:foliage", 1, true))
end

function planner.plan(want, have)
    local dig, put, unknown, water = {}, {}, {}, {}
    -- a plant right above a planned farmland or water cell, where the plan names nothing, goes:
    -- the field's water cell is its open edge to till from (redesign/13-farm.md)
    for k, b in pairs(want) do
        if b[1] == "minecraft:farmland" or b[1] == "minecraft:water" then
            local x, y, z = unkey(k)
            local up = key(x, y + 1, z)
            if not want[up] and plant(have(x, y + 1, z)) then dig[up] = true end
        end
    end
    for k, b in pairs(want) do
        local x, y, z = unkey(k)
        local hname, hmeta = have(x, y, z)
        if hname == nil then
            unknown[#unknown + 1] = k
        elseif b[1] == "minecraft:water" then
            -- no bucket yet (redesign/13-farm.md): the cell is cleared and left for later - in a
            -- field it is the open edge the tilling grows from
            if hname ~= "air" and hname ~= "minecraft:water" then dig[k] = true end
            water[#water + 1] = k
        elseif b[1] == AIR then
            -- Thaumcraft's invisible blocks (an aura node: blockAiry) are left be - a robot's
            -- swing does not break one (Pintsize, -26,6,13, 2026-10-05); the cell counts as air
            if hname ~= "air" and hname ~= "Thaumcraft:blockAiry" then dig[k] = true end
        elseif hname == "air" then
            put[k] = b
        elseif not same(b[1], b[2], hname, hmeta) then
            dig[k], put[k] = true, b                  -- the wrong block: out, then the right one
        end
    end

    -- the packets, by box
    local packets = {}
    local function packet(kind, x, y, z)
        local bx, by, bz = planner.box_of(x, y, z)
        local id = ("%s %d %d %d"):format(kind, bx, by, bz)
        local p = packets[id]
        if not p then
            p = {id = id, kind = kind, box = {bx, by, bz}, cells = {}, waits = {}}
            packets[id] = p
        end
        return p
    end
    for k in pairs(dig) do
        local x, y, z = unkey(k)
        local p = packet("dig", x, y, z)
        p.cells[#p.cells + 1] = k
    end
    local cell_packet = {}
    for k in pairs(put) do
        local x, y, z = unkey(k)
        local p = packet("place", x, y, z)
        p.cells[#p.cells + 1] = k
        cell_packet[k] = p
    end

    local function wait(p, q)
        if q and q ~= p then p.waits[q.id] = true end
    end
    -- digs top to bottom; places bottom to top, within a column of boxes
    for _, p in pairs(packets) do
        local bx, by, bz = p.box[1], p.box[2], p.box[3]
        if p.kind == "dig" then
            wait(p, packets[("dig %d %d %d"):format(bx, by + 1, bz)])
        else
            wait(p, packets[("place %d %d %d"):format(bx, by - 1, bz)])
        end
    end

    -- Packets ranked as robots take them: digs top down, then places bottom up, then by place.
    local function rank(p)
        local b = p.box
        if p.kind == "dig" then return 0, -b[2], b[1], b[3] end
        return 1, b[2], b[1], b[3]
    end
    local function before(a, c)
        local a1, a2, a3, a4 = rank(a)
        local c1, c2, c3, c4 = rank(c)
        if a1 ~= c1 then return a1 < c1 end
        if a2 ~= c2 then return a2 < c2 end
        if a3 ~= c3 then return a3 < c3 end
        return a4 < c4
    end

    -- Nothing flying: each block leans on ground that stays, or on a block placed before it. A
    -- packet waits only on one ranked before it; a block whose only support is in a packet ranked
    -- after its own moves into that packet, placed there after what it leans on. Waits both ways
    -- left 23 of the village's packets in cycles - roofs and eaves across a box's border, one
    -- block leaning east, its neighbour west (2026-10-05).
    local flying = {}
    local function stays(x, y, z)
        local k = key(x, y, z)
        if dig[k] and not put[k] then return false end
        local h = have(x, y, z)
        return h ~= nil and h ~= "air" and not dig[k]
    end
    local order_cells = {}
    for k in pairs(put) do order_cells[#order_cells + 1] = k end
    table.sort(order_cells, function(a, c)               -- bottom up: supports settle first
        local ax, ay, az = unkey(a)
        local cx, cy, cz = unkey(c)
        if ay ~= cy then return ay < cy end
        if ax ~= cx then return ax < cx end
        return az < cz
    end)
    for _, k in ipairs(order_cells) do
        local x, y, z = unkey(k)
        local p = cell_packet[k]
        local ok = false
        for _, d in ipairs(SUPPORTS) do                 -- ground that stays: no wait at all
            if stays(x + d[1], y + d[2], z + d[3]) then ok = true break end
        end
        if not ok then
            local best
            for _, d in ipairs(SUPPORTS) do             -- else a block placed before it
                local q = cell_packet[key(x + d[1], y + d[2], z + d[3])]
                if q and (q == p or before(q, p)) then best = q break end
                if q and (not best or before(q, best)) then best = q end
            end
            if best == p then
                ok = true
            elseif best and before(best, p) then
                wait(p, best)
                ok = true
            elseif best then
                -- only a later packet holds it up: the block goes there
                for i, c in ipairs(p.cells) do
                    if c == k then table.remove(p.cells, i) break end
                end
                best.cells[#best.cells + 1] = k
                best.moved = (best.moved or 0) + 1
                cell_packet[k] = best
                ok = true
            end
        end
        if not ok then flying[#flying + 1] = k end
    end
    for id, p in pairs(packets) do                      -- a packet all of whose blocks moved
        if #p.cells == 0 then packets[id] = nil end
    end

    -- A field is one packet of its own (redesign/13-farm.md): farmland is tilled from beside,
    -- from a cell still air, the tilling grown from the field's open edge inward - cut by the
    -- 5 x 5 grid, a piece proven after its neighbours found every side of a cell filled
    -- (-20,3,17, 2026-10-05). The farmland cells joined side by side at one level, and the wheat
    -- right above them, leave their packets for one packet, the field; it waits on all those
    -- packets waited on. Only the field: whole packets merged had brought stairs, torches and a
    -- gate with them, whose way needs the robot turned.
    local farm, seen = {}, {}
    for k, b in pairs(put) do
        if b[1] == "minecraft:farmland" and cell_packet[k] then farm[k] = true end
    end
    local fields = 0
    for start in pairs(farm) do
        if not seen[start] then
            local comp, queue, head = {}, {start}, 1
            seen[start] = true
            while queue[head] do
                local k = queue[head]
                head = head + 1
                comp[#comp + 1] = k
                local x, y, z = unkey(k)
                for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
                    local n = key(x + d[1], y, z + d[2])
                    if farm[n] and not seen[n] then
                        seen[n] = true
                        queue[#queue + 1] = n
                    end
                end
            end
            table.sort(comp)
            local cx, cy, cz = unkey(comp[1])
            local bx, by, bz = planner.box_of(cx, cy, cz)
            fields = fields + 1
            local f = {id = ("place field %d %d %d"):format(cx, cy, cz), kind = "place",
                       box = {bx, by, bz}, cells = {}, waits = {}, field = true}
            packets[f.id] = f
            local function take(k)
                local q = cell_packet[k]
                if not q then return end
                for i, c in ipairs(q.cells) do
                    if c == k then table.remove(q.cells, i) break end
                end
                for w in pairs(q.waits) do f.waits[w] = true end
                f.waits[q.id] = nil
                f.cells[#f.cells + 1] = k
                cell_packet[k] = f
            end
            for _, k in ipairs(comp) do
                take(k)
                local x, y, z = unkey(k)
                local up = key(x, y + 1, z)
                if put[up] and put[up][1] == "minecraft:wheat" then take(up) end
            end
        end
    end
    for id, q in pairs(packets) do                      -- a packet left empty by the fields
        if #q.cells == 0 then packets[id] = nil end
    end
    for _, q in pairs(packets) do
        q.waits[q.id] = nil
        for w in pairs(q.waits) do if not packets[w] then q.waits[w] = nil end end
    end
    for _, p in pairs(packets) do
        for w in pairs(p.waits) do if not packets[w] then p.waits[w] = nil end end
    end

    -- the order: digs first, top down; then places, bottom up; waits honoured (Kahn's)
    local ids = {}
    for id in pairs(packets) do ids[#ids + 1] = id end
    table.sort(ids, function(a, c) return before(packets[a], packets[c]) end)
    local done, order = {}, {}
    local digs_left = 0
    for _, id in ipairs(ids) do
        if packets[id].kind == "dig" then digs_left = digs_left + 1 end
    end
    local progress = true
    while progress and #order < #ids do
        progress = false
        for _, id in ipairs(ids) do
            if not done[id] then
                local p, ready = packets[id], true
                for w in pairs(p.waits) do
                    if not done[w] then ready = false break end
                end
                -- every dig before any place
                if ready and p.kind == "place" and digs_left > 0 then ready = false end
                if ready then
                    if p.kind == "dig" then digs_left = digs_left - 1 end
                    done[id] = true
                    order[#order + 1] = id
                    p.order = #order
                    progress = true
                    break                               -- again from the first, in rank
                end
            end
        end
    end
    local cycle = {}
    for _, id in ipairs(ids) do if not done[id] then cycle[#cycle + 1] = id end end

    local nd, np, cd, cp = 0, 0, 0, 0
    for _, p in pairs(packets) do
        if p.kind == "dig" then
            nd, cd = nd + 1, cd + #p.cells
        else
            np, cp = np + 1, cp + #p.cells
        end
    end
    table.sort(unknown)
    table.sort(flying)
    return {packets = packets, order = order,
            problems = {unknown = unknown, flying = flying, cycle = cycle, water = water},
            stats = {dig_packets = nd, place_packets = np, dig_cells = cd, place_cells = cp}}
end

return planner
