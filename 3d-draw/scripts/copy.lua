--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | Each real robot's copy: robot/machine.lua on scripts/simbot.lua, in a world made of the map,
-- | run beside the robot (3d-draw/redesign/03-exec.md, "Two machines, one robot"; stage 3 of
-- | 08-order.md). The user, 2026-10-05: "the pc will cache and simulate the same thing as the
-- | robot ... resulting in you catching events much faster".
-- |
-- |     copy.dry(r, text)           the program run start to end on a throwaway copy of the robot
-- |                                 and the world: its end state, why, ops, ticks, where it ends
-- |     copy.start(r, id, text)     the copy runs it, beside the real robot
-- |     copy.follow(r)              after a status_fast: the copy stepped to the op the robot is
-- |                                 at, and compared; at the program's end, compared in full
-- |     copy.inventory(r, inv)      the robot's slots, from status's `inv` line
-- |     copy.world()                the copies' world: the zone's blocks, robot coordinates
-- |
-- | A difference is a divergence, kept on the robot as r.diverged = {why, ...}; its history is
-- | asked for (robots.lua) and shown. Nothing is mended here yet: that is the PC's to decide per
-- | kind of failure (03-exec.md).
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local machine = require("live")("machine")     -- by name, for `reload machine`
local simbot = require("live")("simbot")
local view = require("view")
local vc = require("virt_composer")

-- Beyond the zone's own blocks, the pathfinder's grid of the whole map (route_composer.h): a
-- block or a liquid there is a block to the copies too. The zone alone left the station empty
-- air to a copy whose robot charges outside the zone shown (Tom, 2026-10-05). Named from the
-- planned map (packets.have) where it has the cell: a dig names its exact block, and a copy that
-- knew only "map:block" refused every dig outside the zone (Gunter's dig 0 -1 2, 2026-10-05).
local BEYOND = {__index = function(t, k)
    local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
    if not x or not vc.route_get then return nil end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    local s = vc.route_get(x, y, z)
    if s == 3 then return {"minecraft:water", 0} end
    if s ~= 2 then return nil end
    local pk = package.loaded["packets"]
    if pk and pk.have then
        local name, meta = pk.have(x, y, z)
        if name and name ~= "air" then return {name, meta or 0} end
    end
    return {"map:block", 0}
end}

local copy = {BEYOND = BEYOND}

local W = nil                           -- the copies' world, built once from the zone shown

function copy.world()
    if W then return W end
    local blocks, a = {}, view.anchor
    for _, c in pairs(view.terrain) do
        blocks[(c[1] - a[1]) .. "," .. (c[2] - a[2]) .. "," .. (c[3] - a[3])] = {c[4], c[5]}
    end
    -- the grid loaded, if it is not yet; tests keep to a world of their own
    if not vc.app_is_testing() then
        if not require("route").loaded then require("route").load() end
        setmetatable(blocks, BEYOND)
    end
    W = simbot.world(blocks)
    return W
end

-- "slot:name:meta:count;..." into simbot's slots.
function copy.inventory(r, inv)
    local slots = {}
    for slot, name, meta, count in (inv or ""):gmatch("(%d+):([^:;]+:?[^:;]*):(%d+):(%d+)") do
        slots[tonumber(slot)] = {name = name, meta = tonumber(meta), count = tonumber(count)}
    end
    r.slots = slots
    return slots
end

local function deep(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deep(v) end
    return o
end

-- A robot of the copies' world (or of `w`) standing where the real one says it is.
local function body(w, r)
    local sf = r.sf
    local b = simbot.robot(w, {x = sf.pos[1], y = sf.pos[2], z = sf.pos[3], facing = sf.facing,
                               energy = sf.energy, max = 40500, slots = deep(r.slots or {}),
                               name = r.name})
    return b
end

--[[ The program on a throwaway world and robot: nothing of the copies' world changes. The world
-- is the copies' own blocks, shallow: simbot only ever puts new tables in it or takes them away. ]]
function copy.dry(r, text)
    local base = copy.world()
    local blocks = setmetatable({}, getmetatable(base.blocks))
    for k, v in pairs(base.blocks) do rawset(blocks, k, v) end
    local w = simbot.world(blocks)
    w.containers = deep(base.containers)
    -- the real robot's own cell is where its throwaway stands; its copy, if it drifted from the
    -- robot - ran on past a stop the robot made - is no robot in its way (Tom, 2026-10-05: his
    -- way home refused, "wait robot", by his own copy standing in his park)
    local sf = r.sf
    blocks[sf.pos[1] .. "," .. sf.pos[2] .. "," .. sf.pos[3]] = false
    if r.copy then blocks[r.copy.b.x .. "," .. r.copy.b.y .. "," .. r.copy.b.z] = false end
    local b = body(w, r)
    local m = machine.new(b.hw, {x = b.x, y = b.y, z = b.z, facing = b.facing})
    local ok, why = m.exec("dry", text)
    if not ok then return {state = "refused", why = why} end
    local n = 0
    while m.state == "run" and n < 100000 do
        m.step()
        n = n + 1
    end
    return {state = m.state, why = m.why, ops = #m.prog.ops, ticks = b.ticks,
            pos = {b.x, b.y, b.z}, facing = b.facing, hist = m.hist}
end

-- The copy for a robot, made when first needed, standing where the robot is.
local function copy_of(r)
    if r.copy then return r.copy end
    local w = copy.world()
    local sf = r.sf
    w:set(sf.pos[1], sf.pos[2], sf.pos[3], nil)
    local b = body(w, r)
    r.copy = {b = b, m = machine.new(b.hw, {x = b.x, y = b.y, z = b.z, facing = b.facing})}
    return r.copy
end

function copy.start(r, id, text)
    local c = copy_of(r)
    -- where the robot really is now, before it starts: a copy that drifted is set right
    local sf, b = r.sf, c.b
    local w = copy.world()
    if b.x ~= sf.pos[1] or b.y ~= sf.pos[2] or b.z ~= sf.pos[3] then
        w:set(b.x, b.y, b.z, nil)
        b.x, b.y, b.z = sf.pos[1], sf.pos[2], sf.pos[3]
        w:set(b.x, b.y, b.z, {"OpenComputers:robot", 0})
        c.m.pos = {b.x, b.y, b.z}
    end
    b.facing, b.energy, b.slots = sf.facing, sf.energy, deep(r.slots or {})
    c.m.facing = sf.facing
    r.diverged = nil
    return c.m.exec(id, text)
end

local function same_place(c, sf)
    return c.b.x == sf.pos[1] and c.b.y == sf.pos[2] and c.b.z == sf.pos[3]
end

-- After each status_fast of a program the copy runs: the copy is stepped up to the op the robot
-- reports - not past it - and where both have ended, everything is compared.
function copy.follow(r)
    local c, sf = r.copy, r.sf
    if not c or not c.m.prog or c.m.id ~= sf.id or r.diverged then return end
    local m = c.m
    local n = 0
    while m.state == "run" and m.pc < sf.op and n < 1000 do
        m.step()
        n = n + 1
    end
    local real_end = sf.state == "done" or sf.state == "stop" or sf.state == "halt"
    if real_end then
        -- a robot that stopped got no further than its op: its copy neither - else the copy dug
        -- in the copies' world what the robot never reached (Pintsize at the leaves, 2026-10-05)
        while m.state == "run" and n < 100000 and (sf.state ~= "stop" or m.pc < sf.op) do
            m.step()
            n = n + 1
        end
        if m.state ~= sf.state then
            r.diverged = {why = ("the robot ended %s%s, its copy %s%s"):format(sf.state,
                    sf.why and (" " .. sf.why) or "", m.state, m.why and (" " .. m.why) or "")}
        elseif not same_place(c, sf) then
            r.diverged = {why = ("the robot ended at %d %d %d, its copy at %d %d %d"):format(
                    sf.pos[1], sf.pos[2], sf.pos[3], c.b.x, c.b.y, c.b.z)}
        elseif c.b.facing ~= sf.facing then
            r.diverged = {why = ("the robot faces %s, its copy %s"):format(sf.facing, c.b.facing)}
        else
            r.matched = ("%s: robot and copy agree, %d ops"):format(sf.id, #m.prog.ops)
        end
    elseif m.state ~= "run" and m.pc < sf.op then
        r.diverged = {why = ("the robot is at op %d, its copy stopped at %d: %s"):format(sf.op,
                m.pc, tostring(m.why))}
    end
end

-- At the program's end, the slots compared: what the robot holds against what its copy does.
function copy.compare_inventory(r)
    local c = r.copy
    if not c or r.diverged then return end
    -- the robot is done: its copy, behind it (five robots and a busy app: false divergences of
    -- fences and lavender, 2026-10-06), run to the end of the same program before comparing
    if c.m.state == "run" then
        for _ = 1, 100000 do if c.m.step() ~= "run" then break end end
    end
    -- a dig's drops are the game's (grass gives dirt, tall grass now and then seeds): after a
    -- program with digs the copy takes the robot's slots as they are (redesign/10-live.md)
    -- and a program that touches no slot (moves only) has nothing to compare: the copy takes the
    -- robot's slots too - a stale count taken after a dig was called a divergence on the way home
    -- to charge (Pintsize, 2026-10-05)
    local touches = false
    for _, op in ipairs(c.m.prog and c.m.prog.ops or {}) do
        if op.k == "dig" then
            c.b.slots = deep(r.slots or {})
            return
        end
        if op.k == "put" or op.k == "take" or op.k == "give" or op.k == "craft"
                or op.k == "shift" or op.k == "equip" or op.k == "use" then
            touches = true
        end
    end
    if not touches then
        c.b.slots = deep(r.slots or {})
        return
    end
    local mine, real = c.b.slots, r.slots or {}
    for i = 1, 32 do
        local a, b = mine[i], real[i]
        local ka = a and (a.name .. ":" .. a.meta .. "x" .. a.count) or "-"
        local kb = b and (b.name .. ":" .. b.meta .. "x" .. b.count) or "-"
        if ka ~= kb then
            r.diverged = {why = ("slot %d: the robot holds %s, its copy %s"):format(i, kb, ka)}
            return
        end
    end
end

return copy
