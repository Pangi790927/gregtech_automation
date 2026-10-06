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
-- |     p.problems  {unknown, flying, cycle}: what cannot be planned, by cell or packet, for the
-- |                 user; and water = {...}: the water cells to pour (13-farm.md), to be seen
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
        -- a chest of any facing where the plan's lost it; a trapdoor open or shut (14-turn.md)
        local want = require("orient").placed_meta(wname, wmeta)
        if want == nil then return true end
        return want == require("orient").placed_meta(hname, hmeta)
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
    -- farmland is built as dirt (as_built: what a build packet places for a cell), and worked
    -- later from below, its own work (redesign/13-farm.md, "Tilling from below")
    local as_built, farmcells = {}, {}
    local DIRT = {"minecraft:dirt", 0}
    -- a plant right above a planned farmland or water cell, where the plan names nothing, goes:
    -- the field's water cell is its open edge to till from (redesign/13-farm.md)
    -- and two above farmland too: the stand its wheat is planted from (13-farm.md)
    for k, b in pairs(want) do
        if b[1] == "minecraft:farmland" or b[1] == "minecraft:water" then
            local x, y, z = unkey(k)
            local up = key(x, y + 1, z)
            if not want[up] and plant(have(x, y + 1, z)) then dig[up] = true end
            local up2 = key(x, y + 2, z)
            if b[1] == "minecraft:farmland" and not want[up2] and plant(have(x, y + 2, z)) then
                dig[up2] = true
            end
        end
    end
    for k, b in pairs(want) do
        local x, y, z = unkey(k)
        local hname, hmeta = have(x, y, z)
        if hname == nil then
            unknown[#unknown + 1] = k
        elseif b[1] == "minecraft:water" then
            -- poured from a bucket once sealed (redesign/13-farm.md, "The water step"); water
            -- there already is done
            if hname ~= "minecraft:water" then
                if hname ~= "air" then dig[k] = true end
                put[k] = b
                water[#water + 1] = k
            end
        elseif b[1] == AIR then
            -- Thaumcraft's invisible blocks (an aura node: blockAiry) are left be - a robot's
            -- swing does not break one (Pintsize, -26,6,13, 2026-10-05); the cell counts as air
            if hname ~= "air" and hname ~= "Thaumcraft:blockAiry" then dig[k] = true end
        elseif b[1]:find("_door", 1, true) and b[2] >= 8 then
            -- a door's upper half comes with its lower half (ItemDoor, 14-turn.md): never put
            if hname ~= "air" and hname ~= b[1] then dig[k] = true end
        elseif hname == "air" then
            put[k] = b
            if b[1] == "minecraft:farmland" then farmcells[k], as_built[k] = true, DIRT end
        elseif b[1] == "minecraft:farmland" then
            -- dirt, grass or farmland there already: nothing to build, only the work; anything
            -- else out, then dirt
            farmcells[k] = true
            if not GROUND[hname] and hname ~= "minecraft:farmland" then
                dig[k], put[k], as_built[k] = true, b, DIRT
            end
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
    -- A block whose way the place decides (14-turn.md) clicks a block beside it: when none of
    -- its ways' clicked blocks is there to stay, its packet waits on the packet placing the
    -- first one planned, as a block waits on what holds it; or, that packet ranked after its
    -- own, it moves there (placed after the plain blocks of its layer) - a wait both ways had
    -- left 10 packets in cycles (-31,17,30's stair, 2026-10-05).
    local orient = require("orient")
    for _, k in ipairs(order_cells) do
        local b, p = put[k], cell_packet[k]
        if p and orient.has(b[1]) then
            local x, y, z = unkey(k)
            local ready, first = false, nil
            for _, wy in ipairs(orient.ways(b[1], b[2])) do
                local off = orient.click(wy.f, wy.s)
                local cx, cy, cz = x + off[1], y + off[2], z + off[3]
                if stays(cx, cy, cz) and orient.clickable((have(cx, cy, cz))) then
                    ready = true
                    break
                end
                first = first or cell_packet[key(cx, cy, cz)]
            end
            if not ready and first and first ~= p then
                if before(first, p) then
                    wait(p, first)
                else
                    for i, c in ipairs(p.cells) do
                        if c == k then table.remove(p.cells, i) break end
                    end
                    first.cells[#first.cells + 1] = k
                    first.moved = (first.moved or 0) + 1
                    cell_packet[k] = first
                end
            end
        end
    end
    -- A door's hinge counts the blocks beside it, at both its heights (ItemDoor.placeDoorBlock):
    -- its packet waits on the packets placing them, or moves into the last of them when that
    -- comes after its own - the planks on one side in one box, a log on the other in the next
    -- (-13,3,10, 2026-10-06).
    for _, k in ipairs(order_cells) do
        local b, p = put[k], cell_packet[k]
        if p and orient.door(b[1]) and b[2] < 8 then
            local x, y, z = unkey(k)
            local bx = (b[2] == 1 and -1) or (b[2] == 3 and 1) or 0
            local bz = (b[2] == 0 and 1) or (b[2] == 2 and -1) or 0
            local last
            for _, s in ipairs({-1, 1}) do
                for dy = 0, 1 do
                    -- the normal cubes it counts only: a door beside it is not one, and moving
                    -- a double door's half after the other let its frame in first (-11,6,41)
                    local sk = key(x + s * bx, y + dy, z + s * bz)
                    local q = put[sk] and orient.normal_cube(put[sk][1]) and cell_packet[sk]
                    if q and q ~= p then
                        if before(q, p) then
                            wait(p, q)
                        elseif not last or before(last, q) then
                            last = q
                        end
                    end
                end
            end
            if last then
                for i, c in ipairs(p.cells) do
                    if c == k then table.remove(p.cells, i) break end
                end
                last.cells[#last.cells + 1] = k
                last.moved = (last.moved or 0) + 1
                cell_packet[k] = last
            end
        end
    end
    -- And its stand: when every way of it stands on one cell the plan fills from a packet
    -- ranked before its own, it moves into that packet, where the proof places it before the
    -- block on its stand (a roof's stair standing on the next one, -1,10,42, 2026-10-05).
    for _, k in ipairs(order_cells) do
        local b, p = put[k], cell_packet[k]
        if p and orient.has(b[1]) then
            local x, y, z = unkey(k)
            local only = nil
            for _, wy in ipairs(orient.ways(b[1], b[2])) do
                local v = orient.V[wy.f]
                local sx, sy, sz = x - v[1], y - v[2], z - v[3]
                local sk = key(sx, sy, sz)
                if not stays(sx, sy, sz) then        -- a stand solid for good is none
                    if only == nil then only = sk elseif only ~= sk then only = false end
                end
            end
            local q = only and cell_packet[only]
            if q and q ~= p and before(q, p) then
                for i, c in ipairs(p.cells) do
                    if c == k then table.remove(p.cells, i) break end
                end
                q.cells[#q.cells + 1] = k
                q.moved = (q.moved or 0) + 1
                cell_packet[k] = q
            end
        end
    end
    for id, p in pairs(packets) do                      -- a packet all of whose blocks moved
        if #p.cells == 0 then packets[id] = nil end
    end

    -- A field's work is one packet of its own (redesign/13-farm.md, "Tilling from below"): its
    -- farmland, joined side by side at one level, built as dirt by the packets above, is worked
    -- from under it - dug through, tilled from below, filled back - and the wheat planted over
    -- it. The packet holds the wheat cells (taken from their packets), and the farmland to
    -- work as `farm`; it waits on the packets that put the field's dirt, the dirt under it, and
    -- the water beside it ("the water must be placed before working the field").
    local seen, fields, field_exit = {}, 0, {}
    local starts = {}
    for k in pairs(farmcells) do starts[#starts + 1] = k end
    table.sort(starts)
    for _, start in ipairs(starts) do
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
                    if farmcells[n] and not seen[n] then
                        seen[n] = true
                        queue[#queue + 1] = n
                    end
                end
            end
            table.sort(comp)
            -- A field worked already - every cell farmland but its exit, left dirt for the user -
            -- is no work: the wheat still unplanted over it (the exit's, a cell boxed in) leaves
            -- the plan for the user's list, as the proof puts it (the upper field came back for
            -- them, 2026-10-06)
            local not_farm = 0
            for _, k in ipairs(comp) do
                if have(unkey(k)) ~= "minecraft:farmland" then not_farm = not_farm + 1 end
            end
            if not_farm <= 1 then
                for _, k in ipairs(comp) do
                    local x, y, z = unkey(k)
                    local up = key(x, y + 1, z)
                    local q = cell_packet[up]
                    if put[up] and put[up][1] == "minecraft:wheat" then
                        if q then
                            for i, c in ipairs(q.cells) do
                                if c == up then table.remove(q.cells, i) break end
                            end
                            cell_packet[up] = nil
                        end
                        field_exit[up] = put[up]
                    end
                end
                goto next_field
            end
            local cx, cy, cz = unkey(comp[1])
            local bx, by, bz = planner.box_of(cx, cy, cz)
            fields = fields + 1
            local f = {id = ("place field %d %d %d"):format(cx, cy, cz), kind = "place",
                       box = {bx, by, bz}, cells = {}, waits = {}, field = true, farm = comp}
            packets[f.id] = f
            -- The field's own cells to build - its dirt, the dirt under it, its water - leave
            -- the 5 x 5 boxes for a packet of their own, which waits only on what holds them
            -- from below: the boxes mixed them with fences, a house's stairs, torches and a
            -- mod's gate, none of it the field's (the upper field, 2026-10-06).
            local b = {id = f.id .. " build", kind = "place", box = {bx, by, bz}, cells = {},
                       waits = {}}
            local function build(k)
                local q = cell_packet[k]
                if not q or q == f or q == b then return end
                for i, c in ipairs(q.cells) do
                    if c == k then table.remove(q.cells, i) break end
                end
                b.cells[#b.cells + 1] = k
                cell_packet[k] = b
            end
            for _, k in ipairs(comp) do
                local x, y, z = unkey(k)
                build(k)
                build(key(x, y - 1, z))
                for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
                    local n = key(x + d[1], y, z + d[2])
                    if put[n] and put[n][1] == "minecraft:water" then
                        build(n)
                        build(key(x + d[1], y - 1, z + d[2]))   -- the floor it is poured on
                    end
                end
            end
            -- The field's digs, a packet of its own as its build is: what is in the build's
            -- cells, and the plants right above the farmland and two above, where its wheat is
            -- planted from. Every dig comes before any place anyway, but the crew and a sim's
            -- focus go by the waits named, and a village dig packet holds more than the field's
            -- (-21,6,24's tall grass in "dig -5 0 4", 2026-10-06).
            local dg = {id = f.id .. " dig", kind = "dig", box = {bx, by, bz}, cells = {},
                        waits = {}}
            local function dug_first(q, x, y, z)
                local k = key(x, y, z)
                if not dig[k] then return end
                local id = ("dig %d %d %d"):format(planner.box_of(x, y, z))
                local from = packets[id]
                if from then
                    for i, c in ipairs(from.cells) do
                        if c == k then table.remove(from.cells, i) break end
                    end
                end
                local seen_k = false
                for _, c in ipairs(dg.cells) do if c == k then seen_k = true end end
                if not seen_k then dg.cells[#dg.cells + 1] = k end
                packets[dg.id] = dg
                q.waits[dg.id] = true
            end
            if #b.cells > 0 then
                packets[b.id] = b
                f.waits[b.id] = true
                for _, k in ipairs(b.cells) do
                    local x, y, z = unkey(k)
                    local q = cell_packet[key(x, y - 1, z)]
                    if q and q ~= b and q ~= f then b.waits[q.id] = true end
                    dug_first(b, x, y, z)
                end
            end
            for _, k in ipairs(comp) do
                local x, y, z = unkey(k)
                dug_first(f, x, y + 1, z)
                dug_first(f, x, y + 2, z)
            end
            for _, k in ipairs(comp) do
                local x, y, z = unkey(k)
                -- a block planned two above, on the stand the wheat is planted from (a fence
                -- over the field's edge, -20,6,21, 2026-10-06): placed after the field's work, in
                -- a packet of its own that keeps its old packet's waits - the old one may hold the
                -- field's own dirt, which the field waits on
                local k2 = key(x, y + 2, z)
                local q2 = cell_packet[k2]
                if q2 and q2 ~= f then
                    local aid = f.id .. " after"
                    local a = packets[aid]
                    if not a then
                        a = {id = aid, kind = "place", box = f.box, cells = {}, waits = {}}
                        packets[aid] = a
                        a.waits[f.id] = true
                    end
                    for i, c in ipairs(q2.cells) do
                        if c == k2 then table.remove(q2.cells, i) break end
                    end
                    for wid in pairs(q2.waits) do a.waits[wid] = true end
                    a.cells[#a.cells + 1] = k2
                    cell_packet[k2] = a
                end
                local up = key(x, y + 1, z)
                local q = cell_packet[up]
                if put[up] and put[up][1] == "minecraft:wheat" and q then
                    for i, c in ipairs(q.cells) do
                        if c == up then table.remove(q.cells, i) break end
                    end
                    f.cells[#f.cells + 1] = up
                    cell_packet[up] = f
                end
            end
            ::next_field::
        end
    end
    for id, q in pairs(packets) do                      -- a packet left empty by the fields
        if #q.cells == 0 then packets[id] = nil end
    end
    -- A water cell is poured only once sealed - its floor and four sides solid, else it spreads
    -- (13-farm.md): its packet waits on the packets placing any of them.
    for k, b in pairs(put) do
        local p = cell_packet[k]
        if b[1] == "minecraft:water" and p then
            local x, y, z = unkey(k)
            for _, d in ipairs(SUPPORTS) do
                local q = cell_packet[key(x + d[1], y + d[2], z + d[3])]
                if q and q ~= p then p.waits[q.id] = true end
            end
        end
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
    return {packets = packets, order = order, as_built = as_built, field_exit = field_exit,
            problems = {unknown = unknown, flying = flying, cycle = cycle, water = water},
            stats = {dig_packets = nd, place_packets = np, dig_cells = cd, place_cells = cp}}
end

return planner
