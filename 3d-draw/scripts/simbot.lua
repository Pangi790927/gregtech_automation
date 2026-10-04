--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | A robot on a world of blocks, simulated: the hardware robot/machine.lua drives (its `hw`),
-- | for the tests and for the exe's demo (J). Robot coordinates throughout.
-- |
-- |     local w = simbot.world(blocks)       blocks: {["x,y,z"] = {name, meta}}; w.blocks is it
-- |     w:add_container(x, y, z, slots)      a chest or the interface: slots {[i] = {name, meta,
-- |                                          count}}
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

local simbot = {}

local STEP = {n = {0, 0, -1}, s = {0, 0, 1}, e = {1, 0, 0}, w = {-1, 0, 0}, u = {0, 1, 0},
              d = {0, -1, 0}}
local CLOCKWISE = {n = "e", e = "s", s = "w", w = "n"}
local ROBOT = "OpenComputers:robot"

local function key(x, y, z) return x .. "," .. y .. "," .. z end

local World = {}
World.__index = World

function simbot.world(blocks)
    return setmetatable({blocks = blocks or {}, containers = {}, entities = {}, placed = {}},
                        World)
end

function World:get(x, y, z) return self.blocks[key(x, y, z)] end
function World:set(x, y, z, b) self.blocks[key(x, y, z)] = b end
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

    local hw = {}
    function hw.move(dir)
        turn_to(dir)
        r.ticks = r.ticks + 1
        local x, y, z = ahead(dir)
        if w.entities[key(x, y, z)] then return false, "entity" end
        if w:get(x, y, z) then
            r.ticks = r.ticks + 10                        -- a failed move pauses too
            return false, "solid"
        end
        w:set(r.x, r.y, r.z, nil)
        r.x, r.y, r.z = x, y, z
        w:set(x, y, z, {ROBOT, 0})
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
    function hw.swing(dir)
        turn_to(dir)
        r.ticks = r.ticks + 10
        local x, y, z = ahead(dir)
        local b = w:get(x, y, z)
        if not b or b[1] == ROBOT then return false end
        w:set(x, y, z, nil)
        w.placed[key(x, y, z)] = nil
        r.energy = r.energy - 1
        return true
    end
    function hw.place(dir, slot, face, sneak)
        turn_to(dir)
        r.ticks = r.ticks + 11
        local st = r.slots[slot]
        if not st or st.count <= 0 then return false, "nothing selected" end
        local x, y, z = ahead(dir)
        if w:get(x, y, z) or w.entities[key(x, y, z)] then return false, "taken" end
        w:set(x, y, z, {st.name, st.meta})
        w.placed[key(x, y, z)] = true
        st.count = st.count - 1
        if st.count == 0 then r.slots[slot] = nil end
        r.energy = r.energy - 1
        return true
    end
    function hw.use(dir, slot, face, sneak)
        turn_to(dir)
        r.ticks = r.ticks + 11
        return "false"
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
    function hw.give(dir, mine, n)
        turn_to(dir)
        r.ticks = r.ticks + 11
        local c = w.containers[key(ahead(dir))]
        local st = r.slots[mine]
        if not c or not st then return 0 end
        local moved = math.min(n or st.count, st.count)
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
    function hw.craft(slot, n) r.ticks = r.ticks + 1; return 0 end
    function hw.energy() return r.energy, r.max end
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
        return ("max %d dur 1 up 0 mem 0/0 chunk %s tanks 0"):format(r.max, tostring(r.chunk))
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
