--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | Blocks placed turned the plan's way (3d-draw/redesign/14-turn.md): how a robot's place aims
-- | and clicks (OpenComputers-1.8.0.13-GTNH, Agent.place and Player), and what each block makes of
-- | it (minecraft-1.7.10's onBlockPlaced / onBlockPlacedBy), in one place for the proof, the
-- | programs and the copies. Directions are the robots' letters: n s e w u d.
-- |
-- |     orient.has(name)                   whether a block's way is known here (else refused)
-- |     orient.click(f, s)                 the place toward f with face s: the cell clicked, as an
-- |                                        offset from the target, its side (0-5) and the hit
-- |     orient.yaw(f, s)                   the fake player's yaw
-- |     orient.meta(name, item, f, s)      the block a place makes (meta), or nil: no rule, or a
-- |                                        look right between two ways (a diagonal)
-- |     orient.ways(name, meta)            the {f, s} that make that block, the plainest first
-- |     orient.faceless(f)                 the faces a place with none named tries, in order
-- |     orient.clickable(name)             whether the ray clicks that block
-- |     orient.plant(name), orient.soil(name)  a plant, and soil one stands on
-- |     orient.design_ground(name)         a plant's ground in a design (the user's rule)
-- |     orient.item_meta(name, meta)       the meta an item of that damage places (leaves: | 4)
-- |     orient.holds(f, s, name, meta)     whether the place toward f with face s, its ray as OC
-- |                                        casts it, meets that block (beside the target, at the
-- |                                        click's cell) on its face toward the target - by the
-- |                                        block's own shape: a bottom slab is missed from above
-- |     orient.RANGE                       useAndPlaceRange (config/OpenComputers.cfg: 0.65)
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local orient = {RANGE = 0.65}

local V = {n = {0, 0, -1}, s = {0, 0, 1}, e = {1, 0, 0}, w = {-1, 0, 0}, u = {0, 1, 0},
           d = {0, -1, 0}}
local OPP = {n = "s", s = "n", e = "w", w = "e", u = "d", d = "u"}
local SIDE = {d = 0, u = 1, n = 2, s = 3, w = 4, e = 5}    -- Minecraft's side numbers
orient.V, orient.OPP = V, OPP

-- The fake player's look is normalize(f + s), its yaw -deg(atan2(x, z))
-- (Player.updatePositionAndRotation): 0 south, 90 west, 180 north, -90 east.
function orient.yaw(f, s)
    local x, z = V[f][1] + V[s][1], V[f][3] + V[s][3]
    if x == 0 and z == 0 then return 0 end
    return -math.deg(math.atan(x, z))
end

--[[ The ray of Agent.pick: from the robot's side toward the target T, C + f*0.5 to
-- C + f*1.01 + s*RANGE. With s = f it meets the block beyond T, on the face toward the robot, at
-- that face's middle; with s across f, T's neighbour on side s, on its face toward T, where the
-- ray leaves T: 0.5/RANGE of the way, 0.51 of that along f. -> offset from T, side, hx, hy, hz
-- (the hit inside the clicked block); nil for s = -f, which OC refuses. ]]
function orient.click(f, s)
    if s == OPP[f] then return nil end
    local hit = {0.5, 0.5, 0.5}
    local face = OPP[s]                        -- the clicked block's face toward T
    local fv, sv = V[f], V[s]
    for i = 1, 3 do
        if V[face][i] ~= 0 then hit[i] = V[face][i] > 0 and 1 or 0 end
    end
    if s ~= f then
        local along = 0.51 * (0.5 / orient.RANGE)
        for i = 1, 3 do
            -- the robot's side of T is at 0 when f points up an axis, 1 when down it
            if fv[i] > 0 then hit[i] = along elseif fv[i] < 0 then hit[i] = 1 - along end
        end
    end
    return {sv[1], sv[2], sv[3]}, SIDE[face], hit[1], hit[2], hit[3]
end

-- A value as Java's float holds it: the yaw is a float, and *4 and /360 are float sums.
local function f32(x) return (string.unpack("f", string.pack("f", x))) end

-- The game's floor(yaw*4/360 + k) & 3 (MathHelper.floor_double); nil when the sum is a whole
-- number - a diagonal look, right on the line between two ways - not chosen.
local function quarter(yaw, k)
    local v = f32(f32(f32(yaw) * 4) / 360) + k
    if v == math.floor(v) then return nil end
    return math.floor(v) & 3
end

-- A half decided by the side or the hit: the top when the bottom is clicked, or a side above
-- 0.5. A side clicked level with the robot is hit at 0.5 exactly - the fake player stands at the
-- robot's middle, y + 0.5 (Player's yOffset 0.5, added back by Entity.setLocationAndAngles) - and
-- 0.5 is not above: the bottom half, every time.
local function upper(side, hy)
    if side == 0 then return true end
    if side == 1 then return false end
    return hy > 0.5
end

local STAIRS_WAY = {[0] = 2, [1] = 1, [2] = 3, [3] = 0}       -- BlockStairs.onBlockPlacedBy
local RULES = {
    -- way by the yaw, upside down by the side or the hit (BlockStairs)
    stairs = function(item, side, hy, yaw)
        local up, q = upper(side, hy), quarter(yaw, 0.5)
        if q == nil then return nil end
        return STAIRS_WAY[q] | (up and 4 or 0)
    end,
    -- the axis of the side clicked, the wood kept (BlockRotatedPillar.onBlockPlaced)
    pillar = function(item, side)
        local axis = (side == 0 or side == 1) and 0 or (side == 2 or side == 3) and 8 or 4
        return (item & 3) | axis
    end,
    -- the top half by the side or the hit (BlockSlab.onBlockPlaced)
    slab = function(item, side, hy) return (item & 7) | (upper(side, hy) and 8 or 0) end,
    pumpkin = function(item, side, hy, yaw) return quarter(yaw, 2.5) end,   -- BlockPumpkin
    gate = function(item, side, hy, yaw) return quarter(yaw, 0.5) end,      -- BlockFenceGate
    -- on the side clicked: standing on a top (5), else hung on the side (BlockTorch.onBlockPlaced;
    -- the bottom of a block holds none)
    torch = function(item, side) return ({[1] = 5, [2] = 4, [3] = 3, [4] = 2, [5] = 1})[side] end,
    -- on the side clicked, a side only (BlockLadder.onBlockPlaced)
    ladder = function(item, side) return side >= 2 and side or nil end,
    -- on the side clicked, its top half by a side hit above 0.5 (BlockTrapDoor.onBlockPlaced;
    -- MalisisDoors' TrapDoor extends it, malisisdoors-1.13.7-GTNH)
    trapdoor = function(item, side, hy)
        local m = ({[2] = 0, [3] = 1, [4] = 2, [5] = 3})[side] or 0
        if side ~= 0 and side ~= 1 and hy > 0.5 then m = m | 8 end
        return m
    end,
    -- a door's lower half, only on the top of the block below, facing by the yaw
    -- (ItemDoor.onItemUse: floor((yaw + 180) * 4/360 - 0.5) & 3); its upper half comes with it
    door = function(item, side, hy, yaw)
        if side ~= 1 then return nil end
        local v = f32(f32(f32(f32(yaw) + 180) * 4) / 360) - 0.5
        if v == math.floor(v) then return nil end
        return math.floor(v) & 3
    end,
    -- facing the player (BlockChest.onBlockPlacedBy; a chest beside a chest turns both to it)
    chest = function(item, side, hy, yaw)
        local q = quarter(yaw, 0.5)
        return q and ({[0] = 2, [1] = 5, [2] = 3, [3] = 4})[q]
    end,
}
-- Vanilla's blocks only: a mod's block of the same kind may place by its own rule.
local KIND = {["minecraft:log"] = "pillar", ["minecraft:log2"] = "pillar",
              ["minecraft:hay_block"] = "pillar", ["minecraft:stone_slab"] = "slab",
              ["minecraft:wooden_slab"] = "slab", ["minecraft:pumpkin"] = "pumpkin",
              ["minecraft:lit_pumpkin"] = "pumpkin", ["minecraft:fence_gate"] = "gate",
              ["minecraft:torch"] = "torch", ["minecraft:ladder"] = "ladder",
              ["minecraft:chest"] = "chest", ["minecraft:trapped_chest"] = "chest",
              ["minecraft:wooden_door"] = "door", ["minecraft:iron_door"] = "door",
              ["minecraft:trapdoor"] = "trapdoor"}
local function kind(name)
    if KIND[name] then return KIND[name] end
    -- MalisisDoors' gates and trapdoors extend vanilla's and keep its rules (their
    -- onBlockPlacedBy only refreshes the tile entity, malisisdoors-1.13.7-GTNH)
    if name:match("^malisisdoors:%a*FenceGate$") then return "gate" end
    if name:match("^malisisdoors:trapdoor_%a+$") then return "trapdoor" end
    if name:match("^minecraft:[%w_]+_stairs$") then return "stairs" end
end

function orient.has(name) return kind(name) ~= nil end

-- What of a planned meta a place can and must make (the user's plan, 2026-10-06): a chest planned
-- 0 or 1 - no facing the game gives (2..5); the plan's source lost it - any facing (nil); a
-- trapdoor's open bit (4) is a state, not built: placed closed, opened by hand.
function orient.placed_meta(name, meta)
    local k = kind(name)
    if k == "chest" and meta < 2 then return nil end
    if k == "trapdoor" then return meta & ~4 end
    if name == "ExtraTrees:fence" then return 0 end         -- its wood in a tile entity
    return meta
end

-- A normal cube, as a door's hinge counts them (Block.isNormalCube: opaque, a full block, no
-- power): not glass nor glowstone (glass material), leaves, a door, trapdoor, slab, stairs, fence,
-- pane, chest, ladder, torch, farmland, a plant - a door beside a door had counted, and flipped a
-- double door's hinge (-10,6,41, 2026-10-06).
local NOT_CUBE = {"glass", "glowstone", "leaves", "_door", "trapdoor", "slab", "stairs", "fence",
                  "pane", "iron_bars", "chest", "ladder", "torch", "farmland", "lever", "button",
                  "pressure", "sign", "carpet", "bed", "cake", "skull", "flower_pot", "FenceGate"}
function orient.normal_cube(name)
    if not orient.clickable(name) then return false end
    if name:find("double_") then return true end          -- a double slab is a full block
    for _, t in ipairs(NOT_CUBE) do if name:find(t, 1, true) then return false end end
    return true
end

-- A door: placed as one item, its two halves at once (ItemDoor.placeDoorBlock).
function orient.door(name) return kind(name) == "door" end

-- The upper half's meta a door's lower half at x y z (meta `dir`) gets: 8, and 1 more for a hinge
-- on the other side - by the normal cubes beside it at both heights, and doors there
-- (ItemDoor.placeDoorBlock). `cube(x, y, z)`, `door(x, y, z)`: what is there now.
function orient.door_upper(x, y, z, dir, cube, door)
    local bx = (dir == 1 and -1) or (dir == 3 and 1) or 0
    local bz = (dir == 0 and 1) or (dir == 2 and -1) or 0
    local i1 = (cube(x - bx, y, z - bz) and 1 or 0) + (cube(x - bx, y + 1, z - bz) and 1 or 0)
    local j1 = (cube(x + bx, y, z + bz) and 1 or 0) + (cube(x + bx, y + 1, z + bz) and 1 or 0)
    local d1 = door(x - bx, y, z - bz) or door(x - bx, y + 1, z - bz)
    local d2 = door(x + bx, y, z + bz) or door(x + bx, y + 1, z + bz)
    local flip = (d1 and not d2) or j1 > i1
    return 8 | (flip and 1 or 0)
end

-- The faces a place with none named tries, in order: its own way, then Forge's VALID_DIRECTIONS
-- (down, up, north, south, west, east) but its way and the opposite (Agent.place, anonfun$3).
function orient.faceless(f)
    local out = {f}
    for _, s in ipairs({"d", "u", "n", "s", "w", "e"}) do
        if s ~= f and s ~= OPP[f] then out[#out + 1] = s end
    end
    return out
end

-- A block the ray can click: there, and not one it passes through (liquids, plants, crops,
-- torches, rails, snow) nor a robot - clicking a robot opens it rather than placing.
local THROUGH = {"water", "lava", "wheat", "tallgrass", "flower", "torch", "sapling",
                 "double_plant", "BiomesOPlenty:foliage", "BiomesOPlenty:flowers", "snow_layer",
                 "carpet", "rail", "reeds", "vine", "web", "carrots", "potatoes",
                 "OpenComputers:robot"}
function orient.clickable(name)
    if not name or name == "air" or name == "minecraft:air" then return false end
    for _, t in ipairs(THROUGH) do if name:find(t, 1, true) then return false end end
    return true
end

-- A plant: a flower, a sapling, grass, a bush - it stands only on soil (BlockBush.canBlockStay:
-- grass, dirt or farmland under it). Lavender planned at -19,8,51 over real lavender, the map's
-- grass there wrong: three robots stopped "nothing-placed", the copies and the proof had let it
-- (2026-10-06).
local PLANTS = {"flower", "sapling", "tallgrass", "double_plant", "BiomesOPlenty:foliage",
                "BiomesOPlenty:plants", "red_mushroom", "brown_mushroom", "deadbush"}
function orient.plant(name)
    if not name then return false end
    for _, t in ipairs(PLANTS) do if name:find(t, 1, true) then return true end end
    return false
end

-- Soil a plant stands on: grass, dirt (podzol is dirt), farmland, a mod's grass or dirt.
function orient.soil(name)
    if not name then return false end
    return name:find("grass", 1, true) ~= nil and not orient.plant(name)
        or name:find("dirt", 1, true) ~= nil or name:find("farmland", 1, true) ~= nil
end

-- The ground a plant may stand on in a design: dirt - a grass block is dirt grown over - sand or
-- farmland (the user, 2026-10-06: "plants need to stay on dirt, sand or farmland, note that this
-- needs to be checked in further planners"; docs/rules.md). Every planner checks it on what it
-- plans. The game's own rule, orient.soil, is stricter for most plants - lavender stays on
-- grass, dirt or farmland only, not sand (BoP's BlockBOPFlower2.isValidPosition) - and is
-- checked where the block is placed.
-- A mod's dirt or grass counts as its kind; sand is sand only (not sandstone).
function orient.design_ground(name)
    if not name or orient.plant(name) then return false end
    return name:find("dirt", 1, true) ~= nil or name:find("grass", 1, true) ~= nil
        or name:find("farmland", 1, true) ~= nil or name == "minecraft:sand"
end

-- The block's meta an item of that damage places, before any way is applied (the ItemBlock's
-- getMetadata): vanilla leaves come with the no-decay bit, d | 4 (ItemLeaves, `adg` in
-- minecraft 1.7.10.jar) - the copies placed spruce leaves as leaves:1 where the plan, and the
-- game, have leaves:5, and every dry run of place -1 0 7 stopped "not-expected minecraft:leaves:1"
-- (2026-10-06). Any other item: its damage.
-- And ExtraTrees' fences keep their wood in a tile entity (binnie's BlockFence, a
-- TileEntityMetadata): the block itself is meta 0 whatever the item - ASIMO's place of an
-- ExtraTrees:fence:1 read back ExtraTrees:fence:0, its check stopped it (the cabin, 2026-10-06).
function orient.item_meta(name, meta)
    if name == "minecraft:leaves" or name == "minecraft:leaves2" then return meta | 4 end
    if name == "ExtraTrees:fence" then return 0 end
    return meta
end

-- A block's boxes in its own cell (minecraft-1.7.10's block bounds), {x0, y0, z0, x1, y1, z1}
-- each; nil for a full cube. The partial ones the village has: a slab is half its cell (the top
-- half by meta & 8), stairs fill at least their half (meta & 4 upside down; the step above is
-- left out, so what holds is never more than the game's), a closed trapdoor its bottom or top
-- 0.1875 (open: thin against a side - not counted), fences, walls and panes their middle post,
-- farmland 0.9375 high, a chest inset 0.0625 and 0.875 high. Anything else: a full cube.
local function boxes(name, meta)
    meta = tonumber(meta) or 0
    if name:find("double_", 1, true) then return nil end
    if name:find("slab", 1, true) then
        return {meta & 8 ~= 0 and {0, 0.5, 0, 1, 1, 1} or {0, 0, 0, 1, 0.5, 1}}
    end
    if name:find("stairs", 1, true) then
        return {meta & 4 ~= 0 and {0, 0.5, 0, 1, 1, 1} or {0, 0, 0, 1, 0.5, 1}}
    end
    if name:find("trapdoor", 1, true) then
        if meta & 4 ~= 0 then return {} end
        return {meta & 8 ~= 0 and {0, 0.8125, 0, 1, 1, 1} or {0, 0, 0, 1, 0.1875, 1}}
    end
    if name:find("pane", 1, true) or name:find("iron_bars", 1, true) then
        return {{0.4375, 0, 0.4375, 0.5625, 1, 0.5625}}
    end
    if name:find("fence", 1, true) or name:find("FenceGate", 1, true) then
        return {{0.375, 0, 0.375, 0.625, 1, 0.625}}
    end
    if name:find("cobblestone_wall", 1, true) then return {{0.25, 0, 0.25, 0.75, 1, 0.75}} end
    if name:find("farmland", 1, true) then return {{0, 0, 0, 1, 0.9375, 1}} end
    if name:find("chest", 1, true) then return {{0.0625, 0, 0.0625, 0.9375, 0.875, 0.9375}} end
    return nil
end
orient.boxes = boxes

--[[ Whether the place toward f with face s clicks the block `name` (`meta`) where orient.click
-- puts it, on its face toward the target: Agent.pick's segment, C + f*0.5 to
-- C + f*1.01 + s*RANGE in the target's cell (C the robot's middle), cut against the block's
-- boxes moved to its cell; the box it meets first, and the face it enters by, must be the one
-- toward the target - the ray entering by a slab's top would place the block above the slab,
-- not in the target. Bounds count as inside (a side hit at 0.5 exactly holds a bottom slab).
-- Cortana, 2026-10-06: planks:1 into -9,7,33, a bottom slab its only neighbour - from above,
-- "nothing-placed" (the ray crosses the slab's cell at 0.61, over the slab); from the west,
-- placed (the ray level at 0.5 meets the slab's side). The copies had placed both. ]]
function orient.holds(f, s, name, meta)
    if not orient.clickable(name) or name:find("OpenComputers:robot", 1, true) then
        return false
    end
    local off = orient.click(f, s)
    if not off then return false end
    local bx = boxes(name, meta)
    if not bx then return true end                        -- a full cube: its face is the cell's
    local fv, sv = V[f], V[s]
    local S, E = {}, {}
    for i = 1, 3 do
        local c = 0.5 - fv[i]
        S[i] = c + fv[i] * 0.5
        E[i] = c + fv[i] * 1.01 + sv[i] * orient.RANGE
    end
    local best, best_axis, best_sign = math.huge, nil, nil
    for _, b in ipairs(bx) do
        local lo = {b[1] + off[1], b[2] + off[2], b[3] + off[3]}
        local hi = {b[4] + off[1], b[5] + off[2], b[6] + off[3]}
        local t0, t1, axis, sign = 0, 1, nil, nil
        local miss = false
        for i = 1, 3 do
            local d = E[i] - S[i]
            if d == 0 then
                if S[i] < lo[i] or S[i] > hi[i] then miss = true break end
            else
                local a, b2 = (lo[i] - S[i]) / d, (hi[i] - S[i]) / d
                local enter_sign = d > 0 and -1 or 1       -- the face entered: its outward normal
                if a > b2 then a, b2 = b2, a end
                if a > t0 then t0, axis, sign = a, i, enter_sign end
                if b2 < t1 then t1 = b2 end
                if t0 > t1 then miss = true break end
            end
        end
        if not miss and axis and t0 < best then best, best_axis, best_sign = t0, axis, sign end
    end
    if not best_axis then return false end
    -- the face toward the target: its outward normal points back along s
    return sv[best_axis] ~= 0 and best_sign == -sv[best_axis]
end

function orient.meta(name, item, f, s)
    local k = kind(name)
    if not k then return nil end
    local _, side, _, hy = orient.click(f, s)
    if not side then return nil end
    return RULES[k](item or 0, side, hy, orient.yaw(f, s))
end

-- The places that make `meta` of `name`: from above first (the printer's way), then beside,
-- then from below - a roof's stair from the attic under it, the side of its neighbour hit at
-- 0.39, its bottom half facing any way; the face the place's own way first (no face needed),
-- then the others.
function orient.ways(name, meta)
    local out, k = {}, kind(name)
    if not k then return out end
    local target = orient.placed_meta(name, meta)
    local item = k == "pillar" and meta & 3 or k == "slab" and meta & 7 or meta
    local fs = {"d", "n", "s", "e", "w", "u"}
    if k == "door" then
        if meta >= 8 then return out end               -- an upper half: placed with the lower
        fs = {"n", "s", "e", "w"}                      -- the cell above is its upper half
    end
    for _, f in ipairs(fs) do
        local tried = {}
        for _, s in ipairs({f, "d", "u", "n", "s", "e", "w"}) do
            if not tried[s] and s ~= OPP[f] then
                tried[s] = true
                local m = orient.meta(name, item, f, s)
                if m ~= nil and (target == nil or m == target) then
                    out[#out + 1] = {f = f, s = s}
                end
            end
        end
    end
    return out
end

return orient
