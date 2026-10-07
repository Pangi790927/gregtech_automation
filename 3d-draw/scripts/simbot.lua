--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | A robot on a world of blocks, simulated: the hardware robot/machine.lua drives (its `hw`),
-- | for the tests and the simulated crew (sim.lua). Robot coordinates throughout.
-- |
-- |     local w = simbot.world(blocks)       blocks: {["x,y,z"] = {name, meta}}; w.blocks is it
-- |     w:add_container(x, y, z, slots)      a chest or the interface: slots {[i] = {name, meta,
-- |                                          count}}; slots.sink = {[i] = true}: return slots,
-- |                                          whatever is given into them goes (the ME interface)
-- |     w:add_entity(x, y, z)                a creature standing in a cell; w:remove_entity(x,y,z)
-- |     local r = simbot.robot(w, opts)      opts: x, y, z, facing, energy, max, slots, name
-- |     r.hw                                 the hardware table machine.lua takes
-- |     r.ticks                              the server ticks its ops would have taken
-- |
-- | Each robot is also a block of the world ("OpenComputers:robot") while it stands there, so
-- | one robot meets another as the game has it: analyze names it, and a step into it fails.
-- |
-- | Ticks, from docs/speed.md (OpenComputers 1.9.14 read 2026-10-04): a move 10 ticks of pause
-- | plus a call, a turn 10, a place 10, a swing 10, an analyze or a slot call 1, a drop or suck
-- | 10. Energy: 7 a step (server.lua's measure), 1 for anything else.
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local orient = require("orient")

local simbot = {AFTERIMAGE_S = 0.6}     -- an afterimage's life: about a robot's move

local STEP = {n = {0, 0, -1}, s = {0, 0, 1}, e = {1, 0, 0}, w = {-1, 0, 0}, u = {0, 1, 0},
              d = {0, -1, 0}}
local CLOCKWISE = {n = "e", e = "s", s = "w", w = "n"}
local ROBOT = "OpenComputers:robot"

local function key(x, y, z) return x .. "," .. y .. "," .. z end

local World = {}
World.__index = World

function simbot.world(blocks)
    return setmetatable({blocks = blocks or {}, containers = {}, entities = {}, placed = {},
                         dug = {}}, World)
end

-- An afterimage (w.afterimages, a clock: the crew's sim) is gone once its time is over: in
-- OpenComputers it stands only while the robot's move lasts - kept until the robot's next move,
-- one left by a robot that stopped had stood for good and held another robot waiting on it.
function World:get(x, y, z)
    local k = key(x, y, z)
    local b = self.blocks[k]
    local till = self.after_till and self.after_till[k]
    if till and b and self.afterimages() >= till then
        self.blocks[k] = false
        self.after_till[k] = nil
        return nil
    end
    return b
end
-- An emptied cell is `false`, not nil: a world that falls back on another for cells it does not
-- hold (copy.lua, the pathfinder's grid) would otherwise show the old block again.
function World:set(x, y, z, b)
    local k = key(x, y, z)
    self.blocks[k] = b or false
    if self.on_change then self.on_change(k) end
end
function World:add_container(x, y, z, slots)
    self.containers[key(x, y, z)] = slots
    self:set(x, y, z, {"minecraft:chest", 0})
end
function World:add_entity(x, y, z) self.entities[key(x, y, z)] = true end
function World:remove_entity(x, y, z) self.entities[key(x, y, z)] = nil end

function simbot.robot(w, o)
    local r = {x = o.x or 0, y = o.y or 0, z = o.z or 0, facing = o.facing or "n",
               energy = o.energy or 20000, max = o.max or 20000, slots = o.slots or {},
               tool = o.tool, ticks = 0, name = o.name or "robot", chunk = false}
    w:set(r.x, r.y, r.z, {ROBOT, 0})

    local function ahead(dir)
        local d = STEP[dir]
        return r.x + d[1], r.y + d[2], r.z + d[3]
    end
    local function turn_to(dir)
        if dir == "u" or dir == "d" then return end
        while r.facing ~= dir do
            r.facing = CLOCKWISE[r.facing]
            r.ticks = r.ticks + 10
        end
    end

    -- Farmland under a solid block turns back to dirt (BlockFarmland.onNeighborBlockChange: the
    -- material above solid): a robot stopping right above a field undoes it (13-farm.md).
    local function trample(x, y, z)
        local below = w:get(x, y - 1, z)
        if below and below[1] == "minecraft:farmland" then
            w:set(x, y - 1, z, {"minecraft:dirt", 0})
        end
    end
    local hw = {}
    -- A world with w.afterimages (the crew's sim: its clock): a robot leaves OpenComputers'
    -- afterimage in the cell it moves out of while the move lasts (AFTERIMAGE_S) - a robot
    -- stepping in right behind it meets that, not air (Cortana met Baymax's at his park,
    -- 2026-10-06). Not for the copies' worlds.
    function hw.move(dir)
        turn_to(dir)
        r.ticks = r.ticks + 1
        local x, y, z = ahead(dir)
        if w.entities[key(x, y, z)] then return false, "entity" end
        if w:get(x, y, z) then
            r.ticks = r.ticks + 10                        -- a failed move pauses too
            return false, "solid"
        end
        if w.afterimages then
            local k = key(r.x, r.y, r.z)
            w:set(r.x, r.y, r.z, {ROBOT .. "Afterimage", 0})
            w.after_till = w.after_till or {}
            w.after_till[k] = w.afterimages() + simbot.AFTERIMAGE_S
        else
            w:set(r.x, r.y, r.z, nil)
        end
        r.x, r.y, r.z = x, y, z
        w:set(x, y, z, {ROBOT, 0})
        trample(x, y, z)
        r.ticks = r.ticks + 10
        r.energy = r.energy - 7
        return true
    end
    function hw.face(dir) turn_to(dir); return true end
    function hw.analyze(dir)
        turn_to(dir)
        r.ticks = r.ticks + 1
        local b = w:get(ahead(dir))
        if not b then return nil end
        return b[1], b[2]
    end
    function hw.detect(dir)
        turn_to(dir)
        r.ticks = r.ticks + 1
        local x, y, z = ahead(dir)
        if w.entities[key(x, y, z)] then return true, "entity" end
        if w:get(x, y, z) then return true, "solid" end
        return false, "air"
    end
    function hw.swing(dir)
        turn_to(dir)
        r.ticks = r.ticks + 10
        local x, y, z = ahead(dir)
        local b = w:get(x, y, z)
        if not b or b[1] == ROBOT then return false end
        w.placed[key(x, y, z)] = nil
        w.dug[key(x, y, z)] = true
        w:set(x, y, z, nil)
        r.energy = r.energy - 1
        return true
    end
    function hw.place(dir, slot, face, sneak)
        turn_to(dir)
        r.ticks = r.ticks + 11
        local st = r.slots[slot]
        if not st or st.count <= 0 then return false, "nothing selected" end
        local x, y, z = ahead(dir)
        -- water there is replaced, as the game's ItemBlock does (a liquid is replaceable)
        local there = w:get(x, y, z)
        if (there and not there[1]:find("water", 1, true)) or w.entities[key(x, y, z)] then
            return false, "taken"
        end
        -- seeds go only onto farmland, and become the crop (13-farm.md)
        if st.name == "minecraft:wheat_seeds" then
            local below = w:get(x, y - 1, z)
            if not below or below[1] ~= "minecraft:farmland" then
                return false, "not on farmland"
            end
            w.placed[key(x, y, z)] = true
            w:set(x, y, z, {"minecraft:wheat", 0})
            st.count = st.count - 1
            if st.count == 0 then r.slots[slot] = nil end
            return true
        end
        -- a plant only onto soil (orient.plant/soil): lavender on lavender came to nothing
        if orient.plant(st.name) then
            local below = w:get(x, y - 1, z)
            if not (below and orient.soil(below[1])) then return false, "no soil under it" end
        end
        -- The block the place clicks, as OpenComputers aims it (redesign/14-turn.md): the face
        -- named, or the faces it tries in order; without the angel upgrade (the builders have
        -- none) nothing clicked is nothing placed. Then the block's way, by the game's rule.
        local meta = orient.item_meta(st.name, st.meta)         -- leaves: their no-decay bit
        if not w.angel then
            local clicked
            for _, s in ipairs(face and {face} or orient.faceless(dir)) do
                local off = orient.click(dir, s)
                if not off then return false, "a face opposite the place" end
                local b = w:get(x + off[1], y + off[2], z + off[3])
                -- held only where the ray meets the block's own shape (orient.holds: a bottom
                -- slab is missed from above - Cortana's -9,7,33, 2026-10-06)
                if b and orient.holds(dir, s, b[1], b[2]) then clicked = s break end
            end
            if not clicked then return false, "nothing to hold it" end
            if orient.has(st.name) then
                meta = orient.meta(st.name, st.meta, dir, clicked)
                if not meta then return false, "its way not decided by this place" end
            end
        end
        -- a door puts its upper half too, its hinge by what stands beside it (ItemDoor)
        if orient.door(st.name) then
            if w:get(x, y + 1, z) then return false, "no room for the door's upper half" end
            local function cube(cx, cy, cz)
                local b = w:get(cx, cy, cz)
                return b and orient.normal_cube(b[1])
            end
            local function door(cx, cy, cz)
                local b = w:get(cx, cy, cz)
                return b and b[1] == st.name
            end
            local up = orient.door_upper(x, y, z, meta, cube, door)
            w.placed[key(x, y + 1, z)] = true
            w:set(x, y + 1, z, {st.name, up})
        end
        w.placed[key(x, y, z)] = true
        w:set(x, y, z, {st.name, meta})
        trample(x, y, z)
        st.count = st.count - 1
        if st.count == 0 then r.slots[slot] = nil end
        r.energy = r.energy - 1
        return true
    end
    -- That slot's item into the hand, the hand's into the slot (inventory_controller.equip).
    function hw.equip(slot)
        r.ticks = r.ticks + 1
        r.tool, r.slots[slot] = r.slots[slot], r.tool
        return true
    end
    -- Any water within Hunger Overhaul's reach of a cell: 4 across, its level or one up
    -- (IguanaEventHook.isWaterNearby, HungerOverhaul-1.7.10-1.0.4-GTNH).
    local function water_near(x, y, z)
        for dx = -4, 4 do
            for dy = 0, 1 do
                for dz = -4, 4 do
                    local b = w:get(x + dx, y + dy, z + dz)
                    if b and b[1]:find("water", 1, true) then return true end
                end
            end
        end
        return false
    end
    -- Use: what the game does with the tool in hand here (redesign/13-farm.md) - a mattock or a
    -- hoe on dirt or grass with air right above it and water near makes farmland; a water bucket
    -- used down into air pours a source and is left empty. A pour into a cell not sealed - its
    -- floor or a side open - the copy refuses: in the game it would spread, so the dry run stops
    -- there instead. With a slot: that item into the hand for the use, and back.
    function hw.use(dir, slot, face, sneak)
        if slot then hw.equip(slot) end
        turn_to(dir)
        r.ticks = r.ticks + 11
        local t = r.tool
        local x, y, z = ahead(dir)
        local b = w:get(x, y, z)
        local res = "false"
        -- the face clicked: the one named, else the use's own way first (Agent.use); a hoe
        -- tills on any face but the bottom - from below too, the top named (`u+/+`)
        local clicked = face or dir
        if t and (t.name:find("mattock") or t.name:find("hoe")) and b
                and (b[1] == "minecraft:dirt" or b[1] == "minecraft:grass")
                and clicked ~= "d" and not w:get(x, y + 1, z) and water_near(x, y, z) then
            w:set(x, y, z, {"minecraft:farmland", 0})
            res = "true"
        elseif t and t.name == "minecraft:water_bucket" and dir == "d" and not b then
            local sealed = true
            for _, d in ipairs({{0, -1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}) do
                if not w:get(x + d[1], y + d[2], z + d[3]) then sealed = false end
            end
            if sealed then
                w:set(x, y, z, {"minecraft:water", 0})
                r.tool = {name = "minecraft:bucket", meta = 0, count = 1}
                res = "true"
            end
        end
        if slot then hw.equip(slot) end
        return res
    end
    function hw.take(dir, their, mine, n)
        turn_to(dir)
        r.ticks = r.ticks + 11
        local c = w.containers[key(ahead(dir))]
        local st = c and c[their]
        if not st then return 0 end
        local have = r.slots[mine]
        if have and (have.name ~= st.name or have.meta ~= st.meta) then return 0 end
        local moved = math.min(n or 64, st.count, 64 - (have and have.count or 0))
        st.count = st.count - moved
        if st.count == 0 then c[their] = nil end
        r.slots[mine] = {name = st.name, meta = st.meta, count = (have and have.count or 0) + moved}
        return moved
    end
    function hw.give(dir, mine, n, their)
        turn_to(dir)
        r.ticks = r.ticks + 11
        local c = w.containers[key(ahead(dir))]
        local st = r.slots[mine]
        if not c or not st then return 0 end
        local moved = math.min(n or st.count, st.count)
        if their then
            -- into that one slot: the interface's return slots (c.sink) hand all to the network
            -- on its tick, so they take everything; another slot takes only its own kind
            local t = c[their]
            if c.sink and c.sink[their] then
                -- gone into the network
            elseif not t then
                c[their] = {name = st.name, meta = st.meta, count = moved}
            elseif t.name == st.name and t.meta == st.meta then
                moved = math.min(moved, 64 - t.count)
                t.count = t.count + moved
            else
                return 0
            end
            st.count = st.count - moved
            if st.count == 0 then r.slots[mine] = nil end
            return moved
        end
        for i = 1, 64 do
            local t = c[i]
            if not t then
                c[i] = {name = st.name, meta = st.meta, count = moved}
                break
            elseif t.name == st.name and t.meta == st.meta then
                t.count = t.count + moved
                break
            end
        end
        st.count = st.count - moved
        if st.count == 0 then r.slots[mine] = nil end
        return moved
    end
    function hw.shift(from, to, n)
        r.ticks = r.ticks + 1
        local a = r.slots[from]
        if not a then return false end
        local b = r.slots[to]
        if b and (b.name ~= a.name or b.meta ~= a.meta) then return false end
        local moved = math.min(n or a.count, a.count)
        r.slots[to] = {name = a.name, meta = a.meta, count = (b and b.count or 0) + moved}
        a.count = a.count - moved
        if a.count == 0 then r.slots[from] = nil end
        return true
    end
    -- The grid (recipes.GRID) crafted as the recipes say (scripts/recipes.lua, checked in-game):
    -- up to n items into `slot`, a craft taking one of each cell's ingredient, the saw back in
    -- its cell. A grid no recipe knows makes nothing, as in the game.
    function hw.craft(slot, n)
        r.ticks = r.ticks + 1
        local recipes = require("recipes")
        local cells = {}
        for i, s in ipairs(recipes.GRID) do
            local st = r.slots[s]
            cells[i] = st and (st.name .. ":" .. st.meta) or false
        end
        local item, yield = recipes.match(cells)
        if not item then return 0 end
        local crafts = (n + yield - 1) // yield
        for i, s in ipairs(recipes.GRID) do
            local st = r.slots[s]
            if st and cells[i] ~= recipes.SAW then crafts = math.min(crafts, st.count) end
        end
        local name, meta = item:match("^(.+):(%d+)$")
        local out = r.slots[slot]
        if out and (out.name ~= name or out.meta ~= tonumber(meta)) then return 0 end
        crafts = math.min(crafts, (64 - (out and out.count or 0)) // yield)
        if crafts <= 0 then return 0 end
        for i, s in ipairs(recipes.GRID) do
            local st = r.slots[s]
            if st and cells[i] ~= recipes.SAW then
                st.count = st.count - crafts
                if st.count == 0 then r.slots[s] = nil end
            end
        end
        r.slots[slot] = {name = name, meta = tonumber(meta),
                         count = (out and out.count or 0) + crafts * yield}
        r.ticks = r.ticks + crafts
        return crafts * yield
    end
    function hw.energy() return r.energy, r.max end
    function hw.clock() return r.ticks / 13 end            -- the server's 13 ticks a second
    function hw.chunk(on) r.chunk = on; return true end
    function hw.scan(x, z, y, wd, d, h)
        local out = {}
        for dy = 0, (h or 1) - 1 do
            for dz = 0, (d or 1) - 1 do
                for dx = 0, (wd or 1) - 1 do
                    local b = w:get(r.x + x + dx, r.y + y + dy, r.z + z + dz)
                    out[#out + 1] = b and 1.5 or 0
                end
            end
        end
        r.ticks = r.ticks + 1
        return out
    end
    function hw.extras()
        return ("max %d dur 1 up 0 mem 0/0 chunk %s tanks 0 name %s slots %d"):format(r.max,
                tostring(r.chunk), r.name, r.size or 32)
    end
    function hw.inventory()
        local out = {}
        for i = 1, 32 do
            local st = r.slots[i]
            if st then out[#out + 1] = ("%d:%s:%d:%d"):format(i, st.name, st.meta, st.count) end
        end
        return table.concat(out, ";")
    end
    function hw.save_pos() end
    function hw.history() end

    r.hw = hw
    return r
end

return simbot
