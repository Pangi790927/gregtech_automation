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
