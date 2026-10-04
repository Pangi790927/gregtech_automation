--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | Draws what a 3d-draw robot sees, as it sees it.
-- |
-- | The robot's programs (../3d-draw/robot/) send one event per line, and 3d-draw/run.py appends
-- | them to scene.LOG. This reads that file from the start when the scene opens - so reopening it
-- | replays the whole run - and then follows it every quarter second:
-- |
-- |     box  xmin xmax ymin ymax zmin zmax   a new map: the view is emptied and the camera placed
-- |     pal  id name meta hardness how       a kind of block; its texture is looked for in the jars
-- |     scan x z chars                       a scanned column from ymin up: . air # solid ~ liquid
-- |     blk  x y z id                        a block named by touching it; id 0 is air (broken)
-- |     guess x y z id                       a block guessed from its hardness
-- |     at   x y z facing energy             where the robot is
-- |     charge home|wait|done energy         going to charge, waiting, carrying on
-- |
-- | PAINTING (the user, 2026-10-04: "give me some sort of paint to add more terrain"): G turns it
-- | on and off; holding B marks the columns under the crosshair for the robot to map, N unmarks
-- | them. Only columns not mapped yet can be marked; the marks are small yellow cubes at the
-- | contour's level, and they are kept in scene.EXTEND for `3d-draw/run.py mapper --extend`.
-- |
-- | THE PLAN (a house to build, 2026-10-04): scene.PLAN holds one block per line,
-- |     b x y z name meta shape facing
-- | in the robot's coordinates, with the cell shapes of world_composer.h (0 cube, 3/4 slab,
-- | 5/6 stairs, 7 fence, 8 pane, 9 gate, 10/11 trapdoor, 12 door) and a facing of xneg, xpos,
-- | zneg, zpos or -. A block named minecraft:air is terrain the plan digs out. H shows it over
-- | the terrain and hides it again, putting back what was there. The file is read again when it
-- | changes.
-- |
-- | WHAT IS LEFT (J, the user, 2026-10-04: "where the proposal shows the final result, this one
-- | will show what is left"): scene.PENDING holds `p x y z status name` lines from the build
-- | agent; J draws a small cube in each cell, yellow to build, red lacking, purple stuck.
-- |
-- | LABELS (2026-10-04: the station, marked "because we will need to build around it"):
-- | scene.LABELS holds `label x y z text` lines, robot coordinates; each is drawn as text over
-- | its block, and the file is read again when it changes.
-- |
-- | MARKERS (the user, 2026-10-04: "colored markers so I can tell you what things are"): K turns
-- | marker mode on; a left click marks the block under the crosshair in the chosen colour (C or
-- | the panel's buttons) with the panel's note, a right click unmarks it. scene.MARKERS keeps
-- | `marker x y z colour [note]` lines, robot coordinates, for Claude to read.
-- |
-- | Anything else is a message for people and goes in the panel. Positions are the robot's own,
-- | relative to its start block, x east, y up, z south: the simulator's axes, shifted so the map
-- | sits in the middle of the world.
-- |
-- | What a cell looks like: a named block is a whole cube with its texture (or a colour when none
-- | was found); a guess is a small cube of the same; a scanned block nobody has named yet is a
-- | small grey cube, or blue for one that reads as hard as a liquid.
-- |
-- | @date 2026-10-04
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local blocks = require("blocks")

local controller = {}

local state = {}

-- Cells of each robot's path kept to draw: 800 lagged the view with seven robots (the user,
-- 2026-10-04: "make the drawn path length 1/3 or 1/4 of what it is now, better 1/4").
local TRAIL = 200

local function reset()
    state.offset = nil          -- added to a robot position to get a world cell
    state.box = nil
    state.palette = {}          -- id -> {name, meta, hardness, how, tile, tint, cells}
    state.pending = {}          -- palette ids whose texture is still to be looked for
    state.robot = nil           -- {x, y, z, facing, energy}, the robot's own coordinates
    state.robots = {}           -- by name, the same: there can be more than one (`at ... name`)
    state.trails = {}           -- by name, the cells it went through, last TRAIL of them
    state.charge = nil
    state.messages = {}
    state.events = 0
    state.source = "nothing yet"
    state.cam_placed = false
    state.mapped = {}           -- "x,z" -> true for every column the robot has sent anything of
    state.terrain = {}          -- "x,y,z" -> {id, ghost}: the robot's block there, under any plan
    state.wiped = true          -- the world was emptied: a plan that is on goes back on
    state.covered = {}          -- "x,y,z" -> true where the plan is drawn (see place)
    state.left = {}             -- "x,y,z" -> true where what is left of a build is drawn (J)
end

-- ---- what a block looks like ------------------------------------------------------------------

--[[ Which texture file draws a block, the colour it is multiplied by, and its shape.
-- |
-- | Core: 1.7.10 HAS NO BLOCK MODELS. A block's picture is chosen in its code, so this is a guess
-- | from the name, right for most vanilla blocks; a block it gets wrong falls back to a colour.
-- | Grass and leaves are grey in the jar and coloured by the biome in the game, hence the tints.
-- | Shapes as the cell's `shape`: 0 a cube, 1 a cross (plants, crops, torches), 2 leaves, 3 a
-- | bottom slab (a bed). Each key below was checked against the jars' file lists (2026-10-04,
-- | every name of the plans and the kept chunks); a key that is no file draws as colour_of.
-- | @return string key for vc.render_block_tiles, number 0xRRGGBB, number shape
-- | @date 2026-10-04 ]]
local GREEN, LEAF = 0x7fb238, 0x48b518
local CUBE, CROSS, LEAVES = 0, 1, 2
local VANILLA = {
    grass = {"grass_top", GREEN, CUBE}, tallgrass = {"tallgrass", GREEN, CROSS},
    water = {"water_still", 0x3f76e4, CUBE}, flowing_water = {"water_still", 0x3f76e4, CUBE},
    lava = {"lava_still", 0xffffff, CUBE}, torch = {"torch_on", 0xffffff, CROSS},
    web = {"web", 0xffffff, CROSS}, deadbush = {"deadbush", 0xffffff, CROSS},
    reeds = {"reeds", 0xffffff, CROSS}, sapling = {"sapling_oak", 0xffffff, CROSS},
    log = {"log_oak", 0xffffff, CUBE}, planks = {"planks_oak", 0xffffff, CUBE},
    stonebrick = {"stonebrick", 0xffffff, CUBE},
    double_plant = {"double_plant_grass_bottom", GREEN, CROSS},
    red_flower = {"flower_rose", 0xffffff, CROSS},
    yellow_flower = {"flower_dandelion", 0xffffff, CROSS},
    snow_layer = {"snow", 0xffffff, CUBE}, sandstone = {"sandstone_normal", 0xffffff, CUBE},
}
-- Vanilla leaves by metadata & 3: leaves holds oak, spruce, birch, jungle; leaves2 acacia, big oak.
local VANILLA_LEAVES = {leaves = {"oak", "spruce", "birch", "jungle"},
                        leaves2 = {"acacia", "big_oak", "acacia", "big_oak"}}

--[[ Biomes O' Plenty 2.1.0.2308, read out of its jar (BlockBOPFlower2, BlockBOPLeaves): flowers2's
-- names by metadata, and the leaf kinds, four to a block - `leavesN` with metadata m is kind
-- (N - 1) * 4 + (m & 3), drawn with leaves_<kind>_fancy. @date 2026-10-04 ]]
local BOP_FLOWERS2 = {"hibiscus", "lilyofthevalley", "burningblossom", "lavender", "goldenrod",
                      "bluebells", "minersdelight", "icyiris", "rose"}
local BOP_LEAVES = {"yellowautumn", "bamboo", "magic", "dark", "dead", "fir", "ethereal",
                    "orangeautumn", "origin", "pinkcherry", "maple", "whitecherry", "hellbark",
                    "jacaranda"}

-- Wood by metadata, as the game names its textures: planks_<wood>, log_<wood>.
local WOODS = {"oak", "spruce", "birch", "jungle", "acacia", "big_oak"}
-- Stone bricks by metadata: plain, mossy, cracked, chiselled.
local STONEBRICK = {"stonebrick", "stonebrick_mossy", "stonebrick_cracked", "stonebrick_carved"}
-- What the building blocks are drawn with. In 1.7.10 a fence, gate, trapdoor and wooden door are
-- oak whatever planks made them; stairs take their material's own picture.
local BUILDING = {
    spruce_stairs = "planks_spruce", dark_oak_stairs = "planks_big_oak", oak_stairs = "planks_oak",
    stone_stairs = "cobblestone", stone_brick_stairs = "stonebrick", fence = "planks_oak",
    fence_gate = "planks_oak", trapdoor = "trapdoor", wooden_door = "door_wood_lower",
    glass_pane = "glass", cobblestone_wall = "cobblestone", redstone_lamp = "redstone_lamp_on",
    cobblestone = "cobblestone", glass = "glass", stone = "stone", hay_block = "hay_block_side",
    brick_block = "brick", chest = "planks_oak",           -- a chest is a model: no block picture
    acacia_stairs = "planks_acacia", mossy_cobblestone = "cobblestone_mossy",
    melon_block = "melon_side", pumpkin = "pumpkin_side",  -- the harbour's goods and stone mix
}

-- Chisel's pictures are keyed WITH THEIR FOLDER (`chisel:<folder>/<file>`, which
-- render_block_tiles takes since 2026-10-04): one file name sits in many folders - chaotic-hor
-- in six planks-<wood>, terrain-cob-detailedbrick in cobblestone and cobblestonemossy - and the
-- folder-less key drew the first in the jar, dark oak and mossy.
--
-- THE LANG FILE'S NUMBERS ARE NOT THE METADATA. Read from chisel-2.11.4-GTNH.jar's bytecode,
-- addVariation(desc, meta, texture): cobblestone's tile.cobblestone.<n>.desc is meta n + 1
-- (Features$21), so "Detailed Cobblestone Bricks" (desc 1) is meta 2 and "Cobblestone with
-- Creeper Panel" (desc 10) is meta 11; stonebricksmooth's (Features$91) and planks'
-- (Features$110) desc numbers are their metas. Meta 0 of cobblestone is no variation.
local CHISEL_COBBLE = {"terrain-cobb-brickaligned", "terrain-cob-detailedbrick",
    "terrain-cob-smallbrick", "terrain-cobblargetiledark", "terrain-cobbsmalltile",
    "terrain-cob-french", "terrain-cob-french2", "terrain-cobmoss-creepdungeon",
    "terrain-mossysmalltiledark", "terrain-pistonback-dungeontile",
    "terrain-pistonback-darkcreeper", "terrain-pistonback-darkdent",
    "terrain-pistonback-darkemboss", "terrain-pistonback-darkmarker",
    "terrain-pistonback-darkpanel"}
-- Stone bricks by metadata (Features$91). Metas 0-3 are connected textures of type 16, whose
-- file carries -v4 (2026-10-04: they were drawn with masonry*-v4, a different family).
local CHISEL_STONEBRICK = {[0] = "stonebrick2/masonBricksPlain-v4",
    "stonebrick2/masonBricksFelsic-v4", "stonebrick2/masonBricksMafic-v4",
    "stonebrick2/masonBricksMixed-v4", "stonebrick/smallbricks", "stonebrick/largebricks",
    "stonebrick/smallchaotic", "stonebrick/chaoticbricks", "stonebrick/chaotic",
    "stonebrick/fancy", "stonebrick/ornate", "stonebrick/largeornate", "stonebrick/panel-hard",
    "stonebrick/sunken", "stonebrick/ornatepanel", "stonebrick/poison"}

-- The dye names as the game spells them in texture files, by dye number: ItemDye's second
-- name table (1.7.10.jar, acj.class: "light_blue", where the first table has "lightBlue").
-- Wool of metadata m is wool_colored_<DYE_NAMES[~m & 15]> (BlockColored), so white is meta 0;
-- chisel's antiBlock of metadata m is antiblock/<DYE_NAMES[m]>-antiBlock (Features$6 indexes
-- the same table by m directly), so its meta 14 is orange, not wool's red (read 2026-10-04:
-- wool was drawn white and tinted, and the antiBlock tinted with wool's order).
local DYE_NAMES = {"black", "red", "green", "brown", "blue", "purple", "cyan", "silver", "gray",
                   "pink", "lime", "yellow", "light_blue", "magenta", "orange", "white"}

-- Chisel's wooden planks (chisel:<wood>_planks) by metadata, from team/chisel/Features$110 in
-- chisel-2.11.4-GTNH.jar: addVariation(desc, meta, "planks-<wood>/<file>"). Meta 0 is not
-- registered; 9 is a connected texture (double-top, double-side), drawn with its side. The
-- windmill's "Spruce Wood Planks in Disarray" (meta 14) is chaotic-hor (2026-10-04: drawn as a
-- plain colour, the key chisel:spruce_planks being no file at all).
local CHISEL_PLANKS = {[1] = "clean", [2] = "short", [3] = "vertical", [4] = "vertical-uneven",
    [5] = "parquet", [6] = "fancy", [7] = "blinds", [8] = "panel-nails", [9] = "double-side",
    [10] = "crate", [11] = "crate-fancy", [12] = "crateex", [13] = "large", [14] = "chaotic-hor",
    [15] = "chaotic"}
-- The vanilla planks each of chisel's woods is made from, for its unregistered meta 0.
local CHISEL_WOODS = {oak = "oak", spruce = "spruce", birch = "birch", jungle = "jungle",
                      acacia = "acacia", dark_oak = "big_oak"}

-- Biomes O' Plenty's logs: `logsN` with metadata m is kind (N - 1) * 4 + (m & 3), its side
-- log_<kind>_side (BlockBOPLog's types and registerBlockIcons, read 2026-10-04; bigflowerstem
-- has a picture of its own name).
local BOP_LOGS = {"sacredoak", "cherry", "dark", "fir", "ethereal", "magic", "mangrove", "palm",
                  "redwood", "willow", "dead", "bigflowerstem", "pine", "hellbark", "jacaranda",
                  "mahogany"}

-- Blocks of other mods the plan uses, drawn with a vanilla picture: ExtraTrees' spruce fence and
-- MalisisDoors' spruce gate (GTNH makes those from spruce planks).
local OTHER = {["ExtraTrees:fence"] = "minecraft:planks_spruce",
               ["JABBA:barrel"] = "jabba:barrel_side_0",      -- the user's barrels
               ["malisisdoors:spruceFenceGate"] = "minecraft:planks_spruce",
               ["malisisdoors:trapdoor_spruce"] = "minecraft:trapdoor"}

local BOP_FOLIAGE = {"duckweed", "shortgrass", "mediumgrass", "flaxbottom", "bush", "sprout",
                     "flaxtop", "poisonivy", "berrybush", "shrub", "wheatgrass", "dampgrass",
                     "koru", "cloverpatch", "leafpile", "deadleafpile"}
local BOP_PLANTS = {"deadgrass", "desertgrass", "desertsprouts", "dunegrass", "spectralfern",
                    "thorn", "wildrice", "cattail", "rivercane", "cattailtop", "cattailbottom",
                    "wildcarrot", "cactus", "witherwart", "reed", "root"}
-- Drawn greyscale and coloured by the biome's grass, as the game does.
local BOP_TINTED = {shortgrass = true, mediumgrass = true, bush = true, sprout = true,
                    poisonivy = true, wheatgrass = true, dampgrass = true, koru = true,
                    cloverpatch = true, leafpile = true, duckweed = true}

--[[ The shape and facing of a block of the map, from its name and metadata, as the game keeps
-- | them: stairs rise east 0, west 1, south 2, north 3, upside down +4 (vanilla BlockStairs);
-- | a slab's top half is bit 8; a fence, a pane or iron bars draw as theirs. A plan says its
-- | shapes outright (`b ... shape facing`); a map has only name and metadata, and every block
-- | of a building imprinted into the map was drawn as a cube - fences as planks, stairs as
-- | blocks (the user, 2026-10-04: "fences where replaced with planks stairs with other blocks
-- | etc. they are loosing detail"). Blocks that keep their facing in a tile entity
-- | (malisisdoors' gates and trapdoors) cannot be told: they stand as the shape, unturned.
-- | @return number shape (world_composer.h), number facing or nil
-- | @date 2026-10-04 ]]
local STAIR_FACING = {[0] = blocks.FACE.XPOS, [1] = blocks.FACE.XNEG, [2] = blocks.FACE.ZPOS,
                      [3] = blocks.FACE.ZNEG}
local function map_shape(name, meta, shape)
    local n = name:lower()
    if n:find("_stairs") then
        return (meta & 4) ~= 0 and 6 or 5, STAIR_FACING[meta & 3]
    end
    if n:find("slab") and not n:find("double") then
        return (meta & 8) ~= 0 and 4 or 3, nil
    end
    if n:find("gate") then return 9, nil end
    if n:find("fence") then return 7, nil end
    if n:find("pane") or n:find("iron_bars") then return 8, nil end
    if n:find("trapdoor") then return (meta & 4) ~= 0 and 11 or 10, nil end
    if n:find("_door") then return 12, nil end
    return shape, nil
end

local function look(name, meta)
    if OTHER[name] then return OTHER[name], 0xffffff, CUBE end
    local ns, block = name:match("^([^:]+):(.+)$")
    ns, block = ns or "minecraft", block or name
    if ns == "minecraft" and (block == "planks" or block == "log" or block == "log2") then
        local wood = block == "log2" and WOODS[(meta & 1) + 5] or WOODS[(block == "planks"
                and meta or (meta & 3)) + 1] or "oak"
        return "minecraft:" .. (block == "planks" and "planks_" or "log_") .. wood, 0xffffff, CUBE
    end
    if ns == "minecraft" and block == "stonebrick" then
        return "minecraft:" .. (STONEBRICK[(meta & 3) + 1]), 0xffffff, CUBE
    end
    -- Slabs: wooden by wood; stone by its kind (meta & 7), as BlockStoneSlab names its pictures.
    if ns == "minecraft" and block == "wooden_slab" then
        return "minecraft:planks_" .. (WOODS[(meta & 7) + 1] or "oak"), 0xffffff, CUBE
    end
    if ns == "minecraft" and block == "stone_slab" then
        local kinds = {"stone_slab_top", "sandstone_top", "planks_oak", "cobblestone", "brick",
                       "stonebrick", "nether_brick", "quartz_block_top"}
        return "minecraft:" .. kinds[(meta & 7) + 1], 0xffffff, CUBE
    end
    -- A door's top half (bit 8, BlockDoor) is door_wood_upper; the lower is in BUILDING.
    if ns == "minecraft" and block == "wooden_door" and (meta & 8) ~= 0 then
        return "minecraft:door_wood_upper", 0xffffff, CUBE
    end
    if ns == "minecraft" and BUILDING[block] then
        return "minecraft:" .. BUILDING[block], 0xffffff, CUBE
    end
    if ns == "minecraft" then
        if block == "wool" then
            return "minecraft:wool_colored_" .. DYE_NAMES[(~meta & 15) + 1], 0xffffff, CUBE
        end
        -- A crop: BlockCrops draws wheat_stage_<meta>, past 7 as 7 (1.7.10.jar, akf.class). The
        -- game draws it as a # of four planes (render type 6); the cross is the nearest shape
        -- here. It was a cube of no picture (2026-10-04: "the wheat ... is not drawn properly").
        if block == "wheat" then
            return "minecraft:wheat_stage_" .. math.min(math.max(meta, 0), 7), 0xffffff, CROSS
        end
        -- Farmland's top is farmland_wet with any moisture (meta > 0), farmland_dry without, its
        -- sides dirt (BlockFarmland's getIcon, aky.class). A cell has one picture: the top's,
        -- which is what the field shows from above. There was no "farmland" file to find.
        if block == "farmland" then
            return "minecraft:farmland_" .. (meta > 0 and "wet" or "dry"), 0xffffff, CUBE
        end
        -- A sign is drawn with the oak planks' picture (BlockSign's getIcon); a bed's top is
        -- bed_feet_top, or bed_head_top with bit 8, and it stands about half a block high.
        if block == "standing_sign" or block == "wall_sign" then
            return "minecraft:planks_oak", 0xffffff, CUBE
        end
        if block == "bed" then
            return "minecraft:bed_" .. ((meta & 8) ~= 0 and "head" or "feet") .. "_top", 0xffffff, 3
        end
        local kinds = VANILLA_LEAVES[block]
        if kinds then return "minecraft:leaves_" .. kinds[(meta & 3) + 1], LEAF, LEAVES end
        local v = VANILLA[block]
        if v then return "minecraft:" .. v[1], v[2], v[3] end
        return "minecraft:" .. block, 0xffffff, CUBE
    end
    local lns, lblock = ns:lower(), block:lower()
    -- Chisel's cobblestone by metadata, from its own folder (CHISEL_COBBLE: the desc numbers
    -- are one less than the meta). Meta 0 is plain cobblestone's place in the group.
    if lns == "chisel" and lblock == "cobblestone" then
        if CHISEL_COBBLE[meta] then
            return "chisel:cobblestone/" .. CHISEL_COBBLE[meta], 0xffffff, CUBE
        end
        return "minecraft:cobblestone", 0xffffff, CUBE
    end
    if lns == "chisel" and lblock == "stonebricksmooth" then
        return "chisel:" .. CHISEL_STONEBRICK[meta & 15], 0xffffff, CUBE
    end
    -- Chisel's antiBlock: a picture per dye, by metadata in dye order (DYE_NAMES). It was
    -- looked for as chisel:antiblock, which is no file, and drawn a colour in wool's order.
    if lns == "chisel" and lblock == "antiblock" then
        return "chisel:antiblock/" .. DYE_NAMES[(meta & 15) + 1] .. "-antiblock", 0xffffff, CUBE
    end
    -- Chisel's planks, from the folder of their wood: planks-<wood>, dark_oak as dark-oak.
    local wood = lns == "chisel" and lblock:match("^(.+)_planks$")
    if wood and CHISEL_WOODS[wood] then
        if CHISEL_PLANKS[meta] then
            return ("chisel:planks-%s/%s"):format(wood:gsub("_", "-"), CHISEL_PLANKS[meta]),
                   0xffffff, CUBE
        end
        return "minecraft:planks_" .. CHISEL_WOODS[wood], 0xffffff, CUBE
    end
    -- Ztones' korp and lave blocks: sets/<set>/<set>_ (<meta>) (BlockKorp, BlockLave).
    local set = lns == "ztones" and lblock:match("^tile%.(%l+)block$")
    if set == "korp" or set == "lave" then
        return ("ztones:%s_ (%d)"):format(set, meta & 15), 0xffffff, CUBE
    end
    -- Thaumcraft's trees (BlockMagicalLog, BlockMagicalLeaves): <wood>side for the log; the
    -- leaves are silverwood with bit 1, coloured 0x8899aa, else greatwood in the foliage green.
    if lns == "thaumcraft" and lblock == "blockmagicallog" then
        local woods = {"greatwood", "silverwood", "silverwoodknot", "greatwood"}
        return "thaumcraft:" .. woods[(meta & 3) + 1] .. "side", 0xffffff, CUBE
    end
    -- Pam's gardens: harvestcraft:<kind>garden0 (BlockPamNormalGarden and its kin), bushes.
    if lns == "harvestcraft" and lblock:find("garden$") then
        return "harvestcraft:" .. lblock .. "0", 0xffffff, CROSS
    end
    if lns == "thaumcraft" and lblock == "blockmagicalleaves" then
        if (meta & 1) ~= 0 then return "thaumcraft:silverwoodleaves", 0x8899aa, LEAVES end
        return "thaumcraft:greatwoodleaves", LEAF, LEAVES
    end
    if lns == "biomesoplenty" then
        if lblock == "flowers2" and BOP_FLOWERS2[meta + 1] then
            return "biomesoplenty:" .. BOP_FLOWERS2[meta + 1], 0xffffff, CROSS
        end
        local logs = tonumber(lblock:match("^logs(%d)$"))
        local kind = logs and BOP_LOGS[(logs - 1) * 4 + (meta & 3) + 1]
        if kind then
            return "biomesoplenty:" .. (kind == "bigflowerstem" and "bigflowerstem_side"
                    or "log_" .. kind .. "_side"), 0xffffff, CUBE
        end
        local n = tonumber(lblock:match("^leaves(%d)$"))
        if n and BOP_LEAVES[(n - 1) * 4 + (meta & 3) + 1] then
            return "biomesoplenty:leaves_" .. BOP_LEAVES[(n - 1) * 4 + (meta & 3) + 1] .. "_fancy",
                   0xffffff, LEAVES
        end
        -- foliage and plants by metadata, from the static lists of BlockBOPFoliage and
        -- BlockBOPPlant: a "foliage" picture does not exist (damp grass was drawn untextured).
        local list = lblock == "foliage" and BOP_FOLIAGE or lblock == "plants" and BOP_PLANTS
        if list and list[meta + 1] then
            local name = list[meta + 1]
            return "biomesoplenty:" .. name, BOP_TINTED[name] and GREEN or 0xffffff, CROSS
        end
        if lblock:find("flower") or lblock:find("foliage") or lblock:find("plant") then
            return lns .. ":" .. lblock, 0xffffff, CROSS
        end
    end
    return lns .. ":" .. lblock, 0xffffff, CUBE
end

-- What a block with no picture looks like, by a word in its name: the machines, cables and
-- computers of the station, glass, hives and the like have no one picture to find (their
-- pictures are made in code, or keyed by a folder render_block_tiles drops). The first match
-- wins, so the more particular words come first.
local NAME_COLOURS = {
    {"glass", 0xbfdbe6}, {"leaves", 0x3a7a2a}, {"hive", 0xd8b040}, {"berry", 0x4a7a32},
    {"garden", 0x5a9a3a}, {"bush", 0x4a7a32}, {"flower", 0x9a70c0}, {"log", 0x6b5233},
    {"plank", 0xa8865a}, {"wood", 0x8a6a42}, {"fence", 0x8a6a42}, {"gate", 0x8a6a42},
    {"door", 0x8a6a42}, {"barrel", 0x8a6a42}, {"cable", 0x505a64}, {"conduit", 0x505a64},
    {"solar", 0x2a3a6a}, {"screen", 0x2a2e33}, {"case", 0x3a3f46}, {"charger", 0x4a5058},
    {"adapter", 0x4a5058}, {"drive", 0x5a6068}, {"energy", 0x5a6068}, {"machine", 0x7a8088},
    {"device", 0x7a8088}, {"stone", 0x7d7d7d}, {"brick", 0x8a5a4a}, {"shape", 0x9a9a9a},
}

-- A colour for a block whose texture was not found: by NAME_COLOURS, else one of its own,
-- steady from run to run. The hash alone gave a station's glass and machines random pastels.
local function colour_of(name, meta)
    local lname = name:lower():gsub("^[^:]*:", "")
    for _, c in ipairs(NAME_COLOURS) do
        if lname:find(c[1], 1, true) then return c[2] end
    end
    local h = 5381
    for i = 1, #name do h = (h * 33 + name:byte(i)) % 0x1000000 end
    h = (h + meta * 2654435) % 0x1000000
    local r, g, b = (h >> 16) & 0xff, (h >> 8) & 0xff, h & 0xff
    return ((r // 2 + 64) << 16) | ((g // 2 + 64) << 8) | (b // 2 + 64)
end

-- ---- the world --------------------------------------------------------------------------------

local function cell_at(w, x, y, z)
    if not state.offset then return nil end
    local wx, wy, wz = x + state.offset[1], y + state.offset[2], z + state.offset[3]
    local size = w:size()
    if wx < 0 or wy < 0 or wz < 0 or wx >= size[1] or wy >= size[2] or wz >= size[3] then
        return nil
    end
    return wx, wy, wz
end

-- Puts a block cell at a robot position, or changes the one there.
local function put(w, x, y, z, tile, tint, ghost, shape, facing)
    local wx, wy, wz = cell_at(w, x, y, z)
    if not wx then return nil end
    local c = w:get(wx, wy, wz)
    if not c or c.kind ~= blocks.KIND.MC_BLOCK then
        c = blocks.make(blocks.KIND.MC_BLOCK)
        w:set(wx, wy, wz, c)
    end
    c.tile, c.tint, c.ghost, c.shape = tile, tint, ghost and 1 or 0, shape or 0
    if facing then c.facing = facing end
    return c
end

local function remove(w, x, y, z)
    local wx, wy, wz = cell_at(w, x, y, z)
    if wx then w:set(wx, wy, wz, nil) end
end

-- state.covered: the cells the plan is drawn in, while it is shown. The robot's blocks there
-- are only remembered (state.terrain), not drawn: a map replayed after the plan went on, or a
-- texture found later, painted terrain over the plan (2026-10-04, the barn: its centre post
-- turned into the tree trunk the robot had guessed was there). reset() empties it with the world.
-- Draws block `id` at a robot position, seen or guessed, and remembers the cell under that id, so
-- its texture can be put on once it is found. Under the plan, or under what is left of a build
-- (state.left, J), it is only remembered.
local function place(w, x, y, z, id, ghost)
    local p = state.palette[id]
    if not p then return end
    local k = x .. "," .. y .. "," .. z
    state.terrain[k] = {id, ghost}
    if state.covered[k] or state.left[k] then return end
    local c = put(w, x, y, z, p.tile or -1, p.tile and p.tint or p.colour, ghost, p.shape,
                  p.facing)
    if c and not p.cells[c] then
        p.cells[c] = true
        p.count = p.count + 1
    end
end

-- ---- events -----------------------------------------------------------------------------------

-- The live log's block kinds by its own numbers, kept whatever is shown: a zone shown from the
-- chunk files numbers its kinds its own way, and the log's news is put into it by name.
local logpal = {}

-- The block registry (3d-draw/data/palette.txt: `id name meta how`), which every map has numbered
-- its kinds by since 2026-10-04: what an id means when the log never said - the log can be
-- started anew (run.py does) while the robots go on, and their blocks were dropped as unknown
-- (the user, 2026-10-04: "I don't see the progress of cairol, the blocks don't update").
local registry = {}
local function registry_kind(scene, id)
    if registry[id] == nil and scene.REGISTRY then
        local f = io.open(vc.path_resolve(scene.REGISTRY), "r")
        if f then
            for line in f:lines() do
                local i, name, meta, how = line:match("^(%d+) (%S+) (%d+) (%S+)")
                if i then registry[tonumber(i)] = {name, meta, "1.00", how} end
            end
            f:close()
        end
        if registry[id] == nil then registry[id] = false end
    end
    return registry[id] or nil
end

-- What each robot is at, by name, from `status <name> <state> | <short goal> | <long goal>`
-- (the user, 2026-10-04: "on the pc I want to see their status, their short time goal and their
-- long time goal"). Kept whatever the view shows: it is not the world's.
local statuses = {}

-- Each robot's one colour, in the 3D view, on the map of chunks and in its legend: by its name's
-- place among the names seen, so it stays the same while the robots stay the same (the user,
-- 2026-10-04: "I want them to keep their colors on the map and maybe a legend").
local ROBOT_COLOURS = {0xff2090ff, 0xff40d040, 0xffd04080, 0xff40c0e0, 0xff20d0f0, 0xfff07030,
                       0xffb060ff, 0xff80ffa0}
local function robot_colour(name)
    local names = {}
    for n in pairs(state.robots) do names[#names + 1] = n end
    table.sort(names)
    for i, n in ipairs(names) do
        if n == name then return ROBOT_COLOURS[(i - 1) % #ROBOT_COLOURS + 1] end
    end
    return 0xffffffff
end

local function event(w, scene, line)
    if state.zone and not state.loading_zone then
        -- A zone from the chunk files: the robots move in it, and what they find goes into it too,
        -- by name. Taking only the robots left it as old as its files (the user, 2026-10-04:
        -- "there were resolved cubes that now I see as unresolved").
        local first, rest = line:match("^(%S+)%s*(.*)$")
        if first == "pal" then
            local id, name, meta, hard, how = rest:match("^(%d+) (%S+) (%d+) (%S+) (%S+)")
            if id then logpal[tonumber(id)] = {name, meta, hard, how} end
            return
        elseif first == "blk" or first == "guess" then
            local x, y, z, id = rest:match("^(-?%d+) (-?%d+) (-?%d+) (-?%d+)")
            id = tonumber(id)
            if not id then return end
            if id > 0 then
                local k = logpal[id] or registry_kind(scene, id)
                if not k then return end
                local key = k[1] .. " " .. k[2] .. " " .. k[4]
                local zid = state.zone_ids[key]
                if not zid then
                    zid = state.zone_next
                    state.zone_next, state.zone_ids[key] = zid + 1, zid
                    state.loading_zone = true
                    event(w, scene, table.concat({"pal", zid, k[1], k[2], k[3], k[4]}, " "))
                    state.loading_zone = false
                end
                line = ("%s %s %s %s %d"):format(first, x, y, z, zid)
            end
        elseif first ~= "at" and first ~= "charge" and first ~= "status" then
            return
        end
    end
    state.events = state.events + 1
    local word, rest = line:match("^(%S+)%s*(.*)$")
    local n = {}
    for v in (rest or ""):gmatch("%S+") do n[#n + 1] = v end

    if word == "box" then
        -- A new map empties the view, but the file being followed and its messages stay: forgetting
        -- the source made update() start the file over, every quarter second, camera and all.
        w:wipe()
        local messages, source = state.messages, state.source
        reset()
        state.messages, state.source = messages, source
        state.box = {tonumber(n[1]), tonumber(n[2]), tonumber(n[3]), tonumber(n[4]),
                     tonumber(n[5]), tonumber(n[6])}
        -- In the middle of the world, so there is room all round for what is scanned beyond the
        -- contour later (the user, 2026-10-04).
        local size, b = w:size(), state.box
        local o = {(size[1] - (b[2] - b[1] + 1)) // 2, (size[2] - (b[4] - b[3] + 1)) // 2,
                   (size[3] - (b[6] - b[5] + 1)) // 2}
        state.origin = o
        state.offset = {o[1] - b[1], o[2] - b[3], o[3] - b[5]}
        state.redraw_marks = true
    elseif word == "status" then
        local name, rest = line:match("^status (%S+) (.*)$")
        if name then
            local st, short, long = rest:match("^(.-) | (.-) | (.*)$")
            statuses[name] = {st or rest, short or "", long or ""}
        end
    elseif word == "pal" then
        local id, meta = tonumber(n[1]), tonumber(n[3]) or 0
        if not state.loading_zone then logpal[id] = {n[2], n[3], n[4], n[5]} end
        local key, tint, shape = look(n[2], meta)
        local facing
        if shape == CUBE then shape, facing = map_shape(n[2], meta, shape) end
        state.palette[id] = {name = n[2], meta = meta, hardness = tonumber(n[4]), how = n[5],
                             key = key, tint = tint, shape = shape, facing = facing,
                             colour = colour_of(n[2], meta), cells = {}, count = 0}
        state.pending[#state.pending + 1] = id
    elseif word == "scan" and state.box then
        local x, z, col = tonumber(n[1]), tonumber(n[2]), n[3] or ""
        state.mapped[x .. "," .. z] = true
        for i = 1, #col do
            local ch = col:sub(i, i)
            if ch ~= "." then
                put(w, x, state.box[3] + i - 1, z, -1, ch == "~" and 0x3060ff or 0x7a7a7a, true)
            end
        end
    elseif word == "blk" then
        local x, y, z, id = tonumber(n[1]), tonumber(n[2]), tonumber(n[3]), tonumber(n[4])
        state.mapped[x .. "," .. z] = true
        if id == 0 then
            local k = x .. "," .. y .. "," .. z
            state.terrain[k] = nil
            if not state.covered[k] then remove(w, x, y, z) end
        else
            place(w, x, y, z, id, false)
        end
    elseif word == "guess" then
        state.mapped[n[1] .. "," .. n[3]] = true
        place(w, tonumber(n[1]), tonumber(n[2]), tonumber(n[3]), tonumber(n[4]), true)
    elseif word == "at" then
        state.robot = {tonumber(n[1]), tonumber(n[2]), tonumber(n[3]), n[4], tonumber(n[5])}
        local name = n[6] or "robot"
        state.robots[name] = state.robot
        local trail = state.trails[name] or {}
        state.trails[name] = trail
        local last = trail[#trail]
        local r = state.robot
        if not last or last[1] ~= r[1] or last[2] ~= r[2] or last[3] ~= r[3] then
            trail[#trail + 1] = {r[1], r[2], r[3]}
            if #trail > TRAIL then table.remove(trail, 1) end
        end
    elseif word == "gone" then
        -- A robot that is no more (the user, 2026-10-04: "cortana no longer exists, it can be
        -- removed from the map"): its body, its trail and its status go from the view.
        local name = line:match("^gone (%S+)")
        if name then
            state.robots[name], state.trails[name], statuses[name] = nil, nil, nil
        end
    elseif word == "charge" then
        state.charge = n[1] ~= "done" and (n[1] .. " " .. (n[2] or "")) or nil
    else
        state.events = state.events - 1
        state.messages[#state.messages + 1] = line
        if #state.messages > 8 then table.remove(state.messages, 1) end
    end
end

-- Looks for the textures of the kinds of block that arrived, all in one pass over the jars, and
-- puts them on the cells already drawn.
local function textures()
    if #state.pending == 0 then return end
    local keys = {}
    for i, id in ipairs(state.pending) do keys[i] = state.palette[id].key end
    local tiles = vc.render_block_tiles(table.concat(keys, "\n"))
    for i, id in ipairs(state.pending) do
        local p = state.palette[id]
        p.tile = (tiles[i] or -1) >= 0 and tiles[i] or nil
        for c in pairs(p.cells) do
            c.tile = p.tile or -1
            c.tint = p.tile and p.tint or p.colour
        end
    end
    state.pending = {}
end

-- The camera above and south of the map, looking north across it, the first time there is one.
local function place_camera(scene)
    if state.cam_placed or not state.box then return end
    local b, o = state.box, state.origin
    local cx = o[1] + (b[2] - b[1]) / 2
    local top = o[2] + (b[4] - b[3])
    local south = o[3] + (b[6] - b[5])
    vc.cam_set(cx + 0.5, top + 10, south + 14, 0.0, -0.55)
    state.cam_placed = true
end

-- ---- following the file -----------------------------------------------------------------------

local follow = {path = nil, pos = 0, partial = "", wait = 0}

-- Reads what was added to the file since last time. A file shorter than what was read is a new
-- run, and the view starts over.
local function read_more(w, scene)
    local f = io.open(follow.path, "rb")
    if not f then return end
    local size = f:seek("end")
    if size < follow.pos then
        follow.pos, follow.partial = 0, ""
        if not state.zone then
            w:wipe()
            reset()
            state.source = scene.LOG
        end
    end
    f:seek("set", follow.pos)
    local data = f:read("a") or ""
    follow.pos = f:seek()
    f:close()
    if data == "" then return end
    data = follow.partial .. data
    local last = 1
    for line, stop in data:gmatch("([^\n]*)\n()") do
        line = line:gsub("\r$", "")
        if line ~= "" then event(w, scene, line) end
        last = stop
    end
    follow.partial = data:sub(last)
    textures()
    place_camera(scene)
end

-- A finished map, as events, for when there is no log to follow.
local function load_map(w, scene, path)
    local f = io.open(path, "r")
    if not f then return false end
    local box
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
    for _, line in ipairs(lines) do
        local a = {line:match("^box x (%S+) (%S+) y (%S+) (%S+) z (%S+) (%S+)$")}
        if a[1] then
            box = a
            event(w, scene, "box " .. table.concat(a, " "))
        end
        local id, name, meta, hard, how = line:match("^palette (%d+) (%S+) (%d+) (%S+) (%S+)$")
        if id then event(w, scene, table.concat({"pal", id, name, meta, hard, how}, " ")) end
    end
    if not box then return false end
    local guessed = {}
    for _, line in ipairs(lines) do
        local gy, data = line:match("^guessed (%S+) (.*)$")
        if gy then guessed[tonumber(gy)] = data end
    end
    for _, line in ipairs(lines) do
        local ly, data = line:match("^layer (%S+) (.*)$")
        if ly then
            local y = tonumber(ly)
            local grows = {}
            for row in (guessed[y] or ""):gmatch("[^;]+") do grows[#grows + 1] = row end
            local z = tonumber(box[5])
            local zi = 1
            for row in data:gmatch("[^;]+") do
                local gflags = {}
                for v in (grows[zi] or ""):gmatch("[^,]+") do gflags[#gflags + 1] = v end
                local x, xi = tonumber(box[1]), 1
                for v in row:gmatch("[^,]+") do
                    local id = tonumber(v)
                    if id and id > 0 then
                        event(w, scene, (gflags[xi] == "1" and "guess " or "blk ")
                                .. table.concat({x, y, z, id}, " "))
                    end
                    x, xi = x + 1, xi + 1
                end
                z, zi = z + 1, zi + 1
            end
        end
    end
    textures()
    place_camera(scene)
    return true
end

-- ---- the plan --------------------------------------------------------------------------------

-- scene.PLAN is one file or a list of them, all shown at once (the house, and the harbour
-- planned next to it, 2026-10-04).
local plan = {on = false, paths = {}, text = nil, blocks = {}, tex = {}, check = 0,
              reload = false, at = {}}             -- at: "x,y,z" -> its block, for one cell

local function plan_text()
    local all = {}
    for _, p in ipairs(plan.paths) do
        local f = io.open(p, "rb")
        all[#all + 1] = f and f:read("a") or ""
        if f then f:close() end
    end
    return table.concat(all, "\n")
end
local FACINGS = {xneg = blocks.FACE.XNEG, xpos = blocks.FACE.XPOS, zneg = blocks.FACE.ZNEG,
                 zpos = blocks.FACE.ZPOS}

local AIR = "minecraft:air"

local function plan_read()
    plan.blocks, plan.at = {}, {}
    for line in plan_text():gmatch("[^\n]+") do
        local x, y, z, name, meta, shape, facing =
            line:match("^b (-?%d+) (-?%d+) (-?%d+) (%S+) (%d+) (%d+) (%S+)")
        if x then
            plan.blocks[#plan.blocks + 1] = {tonumber(x), tonumber(y), tonumber(z), name,
                                             tonumber(meta), tonumber(shape), FACINGS[facing]}
            plan.at[x .. "," .. y .. "," .. z] = plan.blocks[#plan.blocks]
        end
    end
    -- the textures, all in one pass over the jars
    local keys, want = {}, {}
    for _, b in ipairs(plan.blocks) do
        local key, tint = look(b[4], b[5])
        b.key, b.tint = key, tint
        if b[4] ~= AIR and plan.tex[key] == nil and not want[key] then
            want[key] = true
            keys[#keys + 1] = key
        end
    end
    if #keys > 0 then
        local tiles = vc.render_block_tiles(table.concat(keys, "\n"))
        for i, k in ipairs(keys) do plan.tex[k] = tiles[i] or -1 end
    end
end

-- Takes the plan off the world, putting back the robot's block in each of its cells. A cell
-- showing what is left of a build (J) keeps showing it.
local function plan_hide(w)
    local was = {}
    for k in pairs(state.covered) do was[#was + 1] = k end
    for _, k in ipairs(was) do
        state.covered[k] = nil
        local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        local t = state.terrain[k]
        if state.left[k] then                           -- J's cube stays
        elseif t then place(w, x, y, z, t[1], t[2])
        else remove(w, x, y, z) end
    end
end

-- Draws one block of the plan in its cell. The cell there is taken away first and a new one
-- made: the old one is still listed under its palette id, and textures() would paint it back.
-- An `air` block is terrain the plan digs out, so the cell stays empty.
local function plan_put(w, b)
    remove(w, b[1], b[2], b[3])
    if b[4] ~= AIR then
        local tile = plan.tex[b.key] or -1
        put(w, b[1], b[2], b[3], tile, tile >= 0 and b.tint or colour_of(b[4], b[5]),
            false, b[6], b[7])
    end
end

-- Puts the plan on the world, except where J shows what is left of a build: there the plan's
-- final block would hide the small cube saying the block is not built yet.
local function plan_show(w)
    plan_hide(w)
    for _, b in ipairs(plan.blocks) do
        if cell_at(w, b[1], b[2], b[3]) then
            local k = b[1] .. "," .. b[2] .. "," .. b[3]
            state.covered[k] = true
            if not state.left[k] then plan_put(w, b) end
        end
    end
end

-- Reads the plan again when its file changed - by its contents: a new version of a house can
-- be just as long as the last (the user, 2026-10-04: reload "without me needing to close the
-- app") - or when the panel's button asks, and shows it again when it is on.
local function plan_follow(w, dt)
    plan.check = plan.check - dt
    if plan.check > 0 and not plan.reload then return end
    plan.check = 1.0
    local text = plan_text()
    if text ~= plan.text or plan.reload then
        plan.text, plan.reload = text, false
        if plan.on then plan_hide(w) end
        plan_read()
        if plan.on then plan_show(w) end
    end
end

-- ---- what is left of a build (J) -------------------------------------------------------------
--
-- The user, 2026-10-04: "maybe add an option on j to show what is still pending (colored cubes
-- that woill show me what is left of a build, where the proposal shows the final result, this
-- one will show what is left)". The build agent rewrites scene.PENDING (a file, a list of them,
-- or `*` patterns: one file per plan) every 30 s, `p x y z status name` a line in robot
-- coordinates under a `# plan <file> <time> <left> left` header. J draws a small cube in each
-- such cell: yellow to build, red lacking its material, purple stuck (the builders cannot place
-- it now). With H on too, the built part shows the plan's blocks and the rest these cubes.

local LEFT_COLOURS = {build = 0xf0d020, lacking = 0xe03030, stuck = 0xa040e0}
local LEFT_ORDER = {"build", "lacking", "stuck"}

local left = {on = false, specs = {}, text = nil, cells = {}, heads = {}, count = {}, total = 0,
              check = 0}

-- The files scene.PENDING names now: each entry is a path, or a path whose file name has `*`
-- in it, matched against its folder's listing (vc.path_list_dir), so a plan's file that appears
-- later is picked up.
local function left_files()
    local out = {}
    for _, spec in ipairs(left.specs) do
        local dir, pat = spec:match("^(.*)/([^/]*%*[^/]*)$")
        if dir then
            local lua_pat = "^" .. pat:gsub("[%.%-%+%?%(%)%[%]%^%$%%]", "%%%0"):gsub("%*", ".*")
                    .. "$"
            local names = vc.path_list_dir(dir)
            table.sort(names)
            for _, n in ipairs(names) do
                if n:match(lua_pat) then out[#out + 1] = dir .. "/" .. n end
            end
        else
            out[#out + 1] = spec
        end
    end
    return out
end

-- Puts J's cube in one cell, in place of what is drawn there. The old cell is taken away first,
-- or textures() would paint a terrain cell it still lists back over the cube.
local function left_put(w, k, status)
    local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not cell_at(w, x, y, z) then return end
    state.left[k] = true
    remove(w, x, y, z)
    put(w, x, y, z, -1, LEFT_COLOURS[status] or LEFT_COLOURS.build, true, 0)
end

-- Takes J's cubes away, putting back what was there: the plan's block where H shows the plan,
-- otherwise the robot's own, otherwise nothing.
local function left_hide(w)
    local was = {}
    for k in pairs(state.left) do was[#was + 1] = k end
    for _, k in ipairs(was) do
        state.left[k] = nil
        local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        local t = state.terrain[k]
        if state.covered[k] then
            if plan.at[k] then plan_put(w, plan.at[k]) else remove(w, x, y, z) end
        elseif t then place(w, x, y, z, t[1], t[2])
        else remove(w, x, y, z) end
    end
end

-- Draws every cell still left, over whatever is drawn there.
local function left_show(w)
    left_hide(w)
    for k, status in pairs(left.cells) do left_put(w, k, status) end
end

-- Reads the files again when their text changed, once a second, as the plan and the markers
-- are: the cells, each file's header, and the count by status for the panel. scene.PENDING is
-- taken here, not in init: a viewer that reloads this file does not run its start again.
local function left_follow(w, dt, scene)
    left.check = left.check - dt
    if left.check > 0 then return end
    left.check = 1.0
    if #left.specs == 0 and scene and scene.PENDING then
        local p = scene.PENDING
        left.specs = type(p) == "table" and p or {p}
    end
    local all = {}
    for _, p in ipairs(left_files()) do
        local f = io.open(vc.path_resolve(p), "rb")
        all[#all + 1] = f and f:read("a") or ""
        if f then f:close() end
    end
    local text = table.concat(all, "\n")
    if text == left.text then return end
    left.text, left.cells, left.heads, left.count, left.total = text, {}, {}, {}, 0
    for line in text:gmatch("[^\n]+") do
        line = line:gsub("\r$", "")
        local x, y, z, status = line:match("^p (-?%d+) (-?%d+) (-?%d+) (%a+)")
        if x then
            local k = x .. "," .. y .. "," .. z
            if not left.cells[k] then left.total = left.total + 1 end
            left.cells[k] = status
        end
        local head = line:match("^# plan (.*)$")
        if head then left.heads[#left.heads + 1] = head end
    end
    for _, status in pairs(left.cells) do left.count[status] = (left.count[status] or 0) + 1 end
    if left.on then left_show(w) end
end

-- The panel's lines: how much is left, by status, and each file's header.
local function left_panel()
    local parts = {}
    for _, s in ipairs(LEFT_ORDER) do parts[#parts + 1] = (left.count[s] or 0) .. " " .. s end
    vc.ImGui_Text(("left %s (J)   %d left (%s)"):format(left.on and "shown" or "hidden",
            left.total, table.concat(parts, ", ")))
    vc.ImGui_Text("yellow: to build   red: lacking material   purple: stuck")
    for _, h in ipairs(left.heads) do vc.ImGui_Text("  plan " .. h) end
end

-- ---- labels ----------------------------------------------------------------------------------

local labels = {path = nil, text = nil, list = {}, check = 0}

local function labels_follow(dt)
    labels.check = labels.check - dt
    if labels.check > 0 then return end
    labels.check = 1.0
    local f = io.open(labels.path, "rb")
    local text = f and f:read("a") or ""
    if f then f:close() end
    if text == labels.text then return end
    labels.text, labels.list = text, {}
    for line in text:gmatch("[^\n]+") do
        local x, y, z, words = line:match("^label (-?%d+) (-?%d+) (-?%d+) (.+)$")
        if x then
            labels.list[#labels.list + 1] = {tonumber(x), tonumber(y), tonumber(z),
                                             (words:gsub("\r$", ""))}
        end
    end
end

-- Each label over the top of its block, on a dark backing so it reads against anything.
local function draw_labels()
    if not state.offset or #labels.list == 0 then return end
    local disp = vc.ImGui_GetDisplaySize()
    local W, H = math.floor(disp.x), math.floor(disp.y)
    vc.ImGui_SetDrawForeground(true)
    for _, l in ipairs(labels.list) do
        local at = vc.render_project(l[1] + state.offset[1] + 0.5, l[2] + state.offset[2] + 1.3,
                                     l[3] + state.offset[3] + 0.5, W, H)
        if at[3] > 0 and at[1] > -100 and at[1] < W + 100 and at[2] > 0 and at[2] < H then
            local size = vc.ImGui_CalcTextSize(l[4])
            local x0, y0 = at[1] - size.x / 2 - 4, at[2] - size.y - 4
            vc.ImGui_AddRectFilled({x = x0, y = y0}, {x = x0 + size.x + 8, y = y0 + size.y + 4},
                    0xc0202020, 3)
            vc.ImGui_AddText({x = x0 + 4, y = y0 + 2}, 0xff40e0ff, l[4])
        end
    end
    vc.ImGui_SetDrawForeground(false)
end

-- ---- painting --------------------------------------------------------------------------------

local paint = {on = false, marks = {}, brush = 1, path = nil, at = nil}
local marks                       -- the markers' state, filled in with them below (MARKERS)
local MARK_Y, MARK_TINT = -1, 0xffd800       -- the contour blocks' level, and yellow

local function paint_load()
    paint.marks = {}
    local f = io.open(paint.path, "r")
    if not f then return end
    for line in f:lines() do
        local x, z = line:match("^(-?%d+) (-?%d+)$")
        if x then paint.marks[x .. "," .. z] = {tonumber(x), tonumber(z)} end
    end
    f:close()
end

local function paint_save()
    local f = io.open(paint.path, "w")
    if not f then return end
    for _, m in pairs(paint.marks) do f:write(("%d %d\n"):format(m[1], m[2])) end
    f:close()
end

local function paint_count()
    local n = 0
    for _ in pairs(paint.marks) do n = n + 1 end
    return n
end

-- Draws every mark not mapped yet; a mapped column's own cells win.
local function paint_draw(w)
    for k, m in pairs(paint.marks) do
        if not state.mapped[k] then put(w, m[1], MARK_Y, m[2], -1, MARK_TINT, true, 0) end
    end
end

-- The column the crosshair points at: where the view's ray meets the contour blocks' top.
local function aimed()
    if not state.offset then return nil end
    local cam, fwd = vc.cam_get(), vc.cam_forward()
    local plane = state.offset[2] + MARK_Y + 1
    if fwd[2] >= -0.01 then return nil end
    local t = (plane - cam[2]) / fwd[2]
    if t <= 0 or t > 200 then return nil end
    local wx, wz = math.floor(cam[1] + fwd[1] * t), math.floor(cam[3] + fwd[3] * t)
    return wx - state.offset[1], wz - state.offset[3]
end

-- Marks (or, erasing, unmarks) the brush's square around the aimed column.
local function paint_apply(w, erase)
    local x0, z0 = aimed()
    paint.at = x0 and {x0, z0} or nil
    if not x0 then return end
    local r, changed = paint.brush - 1, false
    for x = x0 - r, x0 + r do
        for z = z0 - r, z0 + r do
            local k = x .. "," .. z
            if erase and paint.marks[k] then
                paint.marks[k] = nil
                if not state.mapped[k] then remove(w, x, MARK_Y, z) end
                changed = true
            elseif not erase and not paint.marks[k] and not state.mapped[k] then
                paint.marks[k] = {x, z}
                put(w, x, MARK_Y, z, -1, MARK_TINT, true, 0)
                changed = true
            end
        end
    end
    if changed then paint_save() end
end

-- ---- the controller's hooks -------------------------------------------------------------------

function controller.init(w, scene, mc_path)
    w:wipe()
    reset()
    follow.path = vc.path_resolve(scene.LOG)
    paint.path = vc.path_resolve(scene.EXTEND)
    paint_load()
    labels.path = vc.path_resolve(scene.LABELS)
    labels.text = nil
    marks.path = vc.path_resolve(scene.MARKERS)
    marks.text, marks.check = nil, 0
    plan.paths = {}
    for _, p in ipairs(type(scene.PLAN) == "table" and scene.PLAN or {scene.PLAN}) do
        plan.paths[#plan.paths + 1] = vc.path_resolve(p)
    end
    plan.text = nil
    follow.pos, follow.partial = 0, ""
    local report = {}
    local f = io.open(follow.path, "rb")
    if f then
        f:close()
        state.source = scene.LOG
        read_more(w, scene)
        report[#report + 1] = ("following %s: %d events so far"):format(scene.LOG, state.events)
    elseif load_map(w, scene, vc.path_resolve(scene.MAP)) then
        state.source = scene.MAP
        report[#report + 1] = "no live log; showing the finished map " .. scene.MAP
    else
        report[#report + 1] = "nothing to show yet: run a robot program with 3d-draw/run.py"
    end
    return report
end

function controller.origin()
    if not state.offset then return nil end
    return {-state.offset[1], -state.offset[2], -state.offset[3]}
end

-- ---- the map of chunks (M) -------------------------------------------------------------------

-- The user, 2026-10-04: "a sort of map with chunk wide click zones that centers the map around
-- that zone and draws the 3x3 chunk in the viewer, maybe put that map on M". The chunks are the
-- ones 3d-draw/zones.py keeps (data/chunks/, world coordinates); its overview gives the block on
-- top of each column. A click shows the 3x3 chunks round the one clicked, read straight from
-- their files into the robots' frame (data/anchor.txt), and centres the camera there; the
-- robots go on being drawn from the live log. "live log" goes back to following it. Which zone
-- the robots work in is zones.py's business (data/zone.txt): drawn here in red.
local zmap = {on = false, dir = nil, anchor = nil, chunks = {}, names = {}, work = nil,
              pick = nil, back = false}
local PX = 3                    -- screen pixels a column
local NATURAL = {
    ["minecraft:grass"] = 0x5d9b3a, ["minecraft:dirt"] = 0x86603e,
    ["minecraft:stone"] = 0x7d7d7d, ["minecraft:water"] = 0x3060e0,
    ["BiomesOPlenty:leaves4"] = 0x2f6b1f, ["minecraft:log"] = 0x6b5233,
    ["minecraft:sand"] = 0xdbd3a0, ["minecraft:gravel"] = 0x857f7b,
    ["minecraft:clay"] = 0x9fa4b1, ["BiomesOPlenty:flowers2"] = 0xa070c0,
    ["chisel:antiBlock"] = 0xd060c0, ["minecraft:cobblestone"] = 0x6f6f6f,
    ["minecraft:planks"] = 0xa8865a, ["minecraft:leaves"] = 0x3a7a2a,
}

local function abgr(rgb)
    return 0xff000000 | ((rgb & 0xff) << 16) | (rgb & 0xff00) | ((rgb >> 16) & 0xff)
end

-- The overview, the anchor and the robots' zone, read again each time the map is opened. Each
-- chunk's rows are kept as runs of one colour, so a frame draws a few hundred rectangles, not
-- one a column.
local function zmap_read(scene)
    zmap.dir = vc.path_resolve(scene.CHUNKS)
    zmap.chunks, zmap.names, zmap.anchor, zmap.work = {}, {}, nil, nil
    local f = io.open(zmap.dir .. "/overview.txt", "r")
    if f then
        for line in f:lines() do
            local names = line:match("^names (.*)$")
            if names then
                for n in names:gmatch("%S+") do zmap.names[#zmap.names + 1] = n end
            end
            local cx, cz, data = line:match("^chunk (-?%d+) (-?%d+) (.*)$")
            if cx then
                local cols = {}
                for v in data:gmatch("[^,]+") do cols[#cols + 1] = tonumber(v) end
                local runs = {}
                for row = 0, 15 do
                    local start, last = 0, nil
                    for col = 0, 16 do
                        local v = col < 16 and cols[row * 16 + col + 1] or nil
                        if col == 16 or v ~= last then
                            if last ~= nil and col > 0 then
                                local name = zmap.names[last + 1]
                                local rgb = last >= 0 and (NATURAL[name] or colour_of(name, 0))
                                        or 0x202020
                                runs[#runs + 1] = {row, start, col, abgr(rgb)}
                            end
                            start, last = col, v
                        end
                    end
                end
                zmap.chunks[#zmap.chunks + 1] = {tonumber(cx), tonumber(cz), runs}
            end
        end
        f:close()
    end
    local a = io.open(vc.path_resolve(scene.ANCHOR), "r")
    if a then
        for line in a:lines() do
            local x, y, z = line:match("^start (-?%d+) (-?%d+) (-?%d+)")
            if x then zmap.anchor = {tonumber(x), tonumber(y), tonumber(z)} end
        end
        a:close()
    end
    local zf = io.open(vc.path_resolve(scene.ZONE), "r")
    if zf then
        local cx, cz = (zf:read("a") or ""):match("zone (-?%d+) (-?%d+)")
        zf:close()
        if cx then zmap.work = {tonumber(cx), tonumber(cz)} end
    end
end

-- The files a zone is drawn from, scene.BUILT and scene.FIXED after its chunks: what the robots
-- built and finished (imprint.py) and what the user told of, `x y z name meta hardness how`, in
-- world coordinates - zones.fixed's two layers, in its order, the user's word last.
local function zone_layers(scene)
    local out = {}
    for _, k in ipairs({"BUILT", "FIXED"}) do
        if scene[k] then out[#out + 1] = vc.path_resolve(scene[k]) end
    end
    return out
end

-- The text of every file zone cx, cz is drawn from, to tell when one of them changed.
local function zone_text(scene, cx, cz)
    local all = {}
    for i = cx - 1, cx + 1 do
        for j = cz - 1, cz + 1 do
            local f = io.open(("%s/c%d_%d.txt"):format(zmap.dir, i, j), "rb")
            all[#all + 1] = f and f:read("a") or ""
            if f then f:close() end
        end
    end
    for _, p in ipairs(zone_layers(scene)) do
        local f = io.open(p, "rb")
        all[#all + 1] = f and f:read("a") or ""
        if f then f:close() end
    end
    return table.concat(all, "\n")
end

-- The 3x3 chunks round cx, cz, from their files, as the events a map gives, in the robots'
-- frame. Each chunk file numbers its own palette: here every block gets one number, in the order
-- met. BUILT and FIXED are laid over them, so a building finished after a chunk was saved is
-- drawn as built all the same. `keep_cam`: a refresh of the zone shown, which leaves the camera
-- where the user put it.
local function zone_load(w, scene, cx, cz, keep_cam)
    local a = zmap.anchor
    if not a then return end
    zmap.text = zone_text(scene, cx, cz)
    local files, y0, y1 = {}, math.huge, -math.huge
    for i = cx - 1, cx + 1 do
        for j = cz - 1, cz + 1 do
            local f = io.open(("%s/c%d_%d.txt"):format(zmap.dir, i, j), "r")
            if f then
                local lines = {}
                for line in f:lines() do lines[#lines + 1] = line end
                f:close()
                local b = {(lines[2] or ""):match(
                        "^box x (%S+) (%S+) y (%S+) (%S+) z (%S+) (%S+)$")}
                if b[1] then
                    y0, y1 = math.min(y0, tonumber(b[3])), math.max(y1, tonumber(b[4]))
                    files[#files + 1] = {lines = lines, x0 = tonumber(b[1]), z0 = tonumber(b[5])}
                end
            end
        end
    end
    if #files == 0 then return end
    local robots, trails = state.robots, state.trails
    state.loading_zone = true
    w:wipe()
    event(w, scene, ("box %d %d %d %d %d %d"):format((cx - 1) * 16 - a[1], (cx + 2) * 16 - 1 - a[1],
            y0 - a[2], y1 - a[2], (cz - 1) * 16 - a[3], (cz + 2) * 16 - 1 - a[3]))
    local ids, next_id = {}, 1
    for _, file in ipairs(files) do
        local here, guessed = {}, {}
        for _, line in ipairs(file.lines) do
            local id, name, meta, hard, how = line:match("^palette (%d+) (%S+) (%d+) (%S+) (%S+)$")
            if id then
                local key = name .. " " .. meta .. " " .. how
                if not ids[key] then
                    ids[key] = next_id
                    event(w, scene, table.concat({"pal", next_id, name, meta, hard, how}, " "))
                    next_id = next_id + 1
                end
                here[tonumber(id)] = ids[key]
            end
            local gy, data = line:match("^guessed (%S+) (.*)$")
            if gy then guessed[tonumber(gy)] = data end
        end
        for _, line in ipairs(file.lines) do
            local ly, data = line:match("^layer (%S+) (.*)$")
            if ly then
                local y = tonumber(ly)
                local grows = {}
                for row in (guessed[y] or ""):gmatch("[^;]+") do grows[#grows + 1] = row end
                local zi = 0
                for row in data:gmatch("[^;]+") do
                    local flags = {}
                    for v in (grows[zi + 1] or ""):gmatch("[^,]+") do flags[#flags + 1] = v end
                    local xi = 0
                    for v in row:gmatch("[^,]+") do
                        local id = here[tonumber(v)]
                        if id then
                            event(w, scene, ("%s %d %d %d %d"):format(
                                    flags[xi + 1] == "1" and "guess" or "blk",
                                    file.x0 + xi - a[1], y - a[2], file.z0 + zi - a[3], id))
                        end
                        xi = xi + 1
                    end
                    zi = zi + 1
                end
            end
        end
    end
    -- BUILT, then FIXED, over the chunks: air is taken away (blk id 0), a block drawn as seen.
    local wx0, wx1, wz0, wz1 = (cx - 1) * 16, (cx + 2) * 16 - 1, (cz - 1) * 16, (cz + 2) * 16 - 1
    for _, p in ipairs(zone_layers(scene)) do
        local f = io.open(p, "r")
        for line in (f and f:lines() or function() end) do
            local x, y, z, name, meta, hard, how =
                    line:match("^(-?%d+) (-?%d+) (-?%d+) (%S+) (%d+) (%S+) (%S+)")
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            if x and x >= wx0 and x <= wx1 and z >= wz0 and z <= wz1 then
                local id = 0
                if name ~= AIR then
                    local key = name .. " " .. meta .. " " .. how
                    if not ids[key] then
                        ids[key] = next_id
                        event(w, scene, table.concat({"pal", next_id, name, meta, hard, how}, " "))
                        next_id = next_id + 1
                    end
                    id = ids[key]
                end
                event(w, scene, ("blk %d %d %d %d"):format(x - a[1], y - a[2], z - a[3], id))
            end
        end
        if f then f:close() end
    end
    state.loading_zone = false
    state.zone = {cx, cz}
    state.zone_ids, state.zone_next = ids, next_id          -- for the log's news (see event)
    state.robots, state.trails = robots, trails
    state.source = ("zone %d %d, from the chunk files"):format(cx, cz)
    state.cam_placed = keep_cam or false
    textures()
    place_camera(scene)
end

-- Keeps the zone shown as current as its files: every 2 s they are read, and when any changed
-- the zone is drawn again from them, the camera staying on the same blocks. The zone was read
-- once, when picked, and never again (the user, 2026-10-04: "make sure that the in-view maps
-- stays kinda-updated at least (the lighthouse is built in reality, but in practice it's not
-- there)" - the harbour was imprinted into built.txt and the chunks at 23:45, the zone shown had
-- been read at 22:21).
local function zone_follow(w, scene, dt)
    zmap.follow = (zmap.follow or 0) - dt
    if not state.zone or zmap.pick or zmap.follow > 0 then return end
    zmap.follow = 2.0
    local cx, cz = state.zone[1], state.zone[2]
    if zone_text(scene, cx, cz) == zmap.text then return end
    local before = state.offset
    zone_load(w, scene, cx, cz, true)
    local after = state.offset
    if before and after and (before[1] ~= after[1] or before[2] ~= after[2]
            or before[3] ~= after[3]) then
        local cam = vc.cam_get()
        vc.cam_set(cam[1] + after[1] - before[1], cam[2] + after[2] - before[2],
                   cam[3] + after[3] - before[3], cam[4], cam[5])
    end
end

-- M opens and closes the map; a click or the button is acted on here, where the world is.
local function zmap_update(w, scene)
    -- On start, the robots' work zone (data/zone.txt), as if it had been picked on the map: the
    -- live log alone began with whatever map a robot program last wrote (the user, 2026-10-04:
    -- "make the default load the work area on restarts").
    if not zmap.started then
        zmap.started = true
        zmap_read(scene)
        if zmap.work then zmap.pick = {zmap.work[1], zmap.work[2]} end
    end
    if vc.ImGui_IsKeyPressed("ImGuiKey_M", false) and not vc.ImGui_WantCaptureKeyboard() then
        zmap.on = not zmap.on
        if zmap.on then zmap_read(scene) end
    end
    -- While it is open, the overview is read again now and then: the scouts' work goes into
    -- the chunks as it comes (keep_chunks.py).
    if zmap.on then
        zmap.check = (zmap.check or 0) + 1
        if zmap.check >= 600 then
            zmap.check = 0
            zmap_read(scene)
        end
    end
    if zmap.pick then
        zone_load(w, scene, zmap.pick[1], zmap.pick[2])
        zmap.pick = nil
    end
    if zmap.back then
        state.zone, zmap.back = nil, false
        state.source = "the live log again"           -- update() starts the log over
    end
end

-- A rectangle round the 3x3 chunks round cx, cz.
local function zone_frame(at, cx0, cz0, cx, cz, colour, thick)
    local S = 16 * PX
    vc.ImGui_AddRect({x = at.x + (cx - 1 - cx0) * S, y = at.y + (cz - 1 - cz0) * S},
            {x = at.x + (cx + 2 - cx0) * S, y = at.y + (cz + 2 - cz0) * S}, colour, 0, thick)
end

local function draw_zmap()
    if not zmap.on then return end
    vc.ImGui_Begin("chunks (M)", 0)
    if #zmap.chunks == 0 or not zmap.anchor then
        vc.ImGui_Text("no chunks kept yet: python 3d-draw/zones.py save")
        vc.ImGui_End()
        return
    end
    local cx0, cx1, cz0, cz1 = math.huge, -math.huge, math.huge, -math.huge
    for _, c in ipairs(zmap.chunks) do
        cx0, cx1 = math.min(cx0, c[1]), math.max(cx1, c[1])
        cz0, cz1 = math.min(cz0, c[2]), math.max(cz1, c[2])
    end
    local S = 16 * PX
    local at = vc.ImGui_GetCursorScreenPos()
    local hover
    for _, c in ipairs(zmap.chunks) do
        local ox, oy = at.x + (c[1] - cx0) * S, at.y + (c[2] - cz0) * S
        for _, r in ipairs(c[3]) do
            vc.ImGui_AddRectFilled({x = ox + r[2] * PX, y = oy + r[1] * PX},
                    {x = ox + r[3] * PX, y = oy + (r[1] + 1) * PX}, r[4], 0)
        end
        vc.ImGui_AddRect({x = ox, y = oy}, {x = ox + S, y = oy + S}, 0x50ffffff, 0, 1)
        if vc.ImGui_IsMouseHoveringRect({x = ox, y = oy}, {x = ox + S, y = oy + S}, true) then
            hover = c
        end
    end
    if zmap.work then zone_frame(at, cx0, cz0, zmap.work[1], zmap.work[2], 0xff4040ff, 2) end
    if state.zone then zone_frame(at, cx0, cz0, state.zone[1], state.zone[2], 0xff20e0ff, 2) end
    if hover then
        zone_frame(at, cx0, cz0, hover[1], hover[2], 0xffffffff, 1)
        if vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false) then
            zmap.pick = {hover[1], hover[2]}
        end
    end
    -- the robots, where they are in the world
    for name, r in pairs(state.robots) do
        local wx, wz = r[1] + zmap.anchor[1], r[3] + zmap.anchor[3]
        local px = at.x + (wx - cx0 * 16) * PX + PX / 2
        local py = at.y + (wz - cz0 * 16) * PX + PX / 2
        vc.ImGui_AddCircleFilled({x = px, y = py}, 4, robot_colour(name))
    end
    vc.ImGui_Dummy({x = (cx1 - cx0 + 1) * S, y = (cz1 - cz0 + 1) * S})
    -- the legend: each robot's colour and name
    local names = {}
    for name in pairs(state.robots) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local p = vc.ImGui_GetCursorScreenPos()
        vc.ImGui_AddCircleFilled({x = p.x + 6, y = p.y + 8}, 5, robot_colour(name))
        vc.ImGui_Dummy({x = 14, y = 16})
        vc.ImGui_SameLine(0, -1)
        local st = statuses[name]
        vc.ImGui_Text(name .. (st and ("   " .. st[1] .. ": " .. st[2]) or ""))
    end
    vc.ImGui_Text(hover and ("chunk %d %d: world x %d..%d, z %d..%d - click: show the 3x3 round it")
            :format(hover[1], hover[2], hover[1] * 16, hover[1] * 16 + 15, hover[2] * 16,
                    hover[2] * 16 + 15) or "point at a chunk")
    vc.ImGui_Text(("shown: %s (yellow); the robots' work zone: %s (red, zones.py load)"):format(
            state.zone and (state.zone[1] .. " " .. state.zone[2]) or "the live log",
            zmap.work and (zmap.work[1] .. " " .. zmap.work[2]) or "none"))
    if state.zone and vc.ImGui_Button("live log", {x = 0, y = 0}) then zmap.back = true end
    vc.ImGui_End()
end

-- ---- markers ---------------------------------------------------------------------------------
--
-- The user, 2026-10-04: "I would also like to be able to place some colored markers so I can tell
-- you what things are, so that I won't have to go read coords" - and they chose markers in this
-- view over wool in the game. K turns marker mode on; a left click puts a marker on the block
-- under the crosshair, in the chosen colour and with the note typed in the panel; a right click
-- takes the one there away. scene.MARKERS keeps them as `marker x y z colour [note]`, robot
-- coordinates, which is what Claude reads. The file is followed like the labels, so Claude may
-- edit or empty it while the view is open.

-- The colours, by the one word written into the file. Few and far apart, so a name said in chat
-- picks out one at a glance.
local MARK_COLOURS = {
    {"red", 0xe03030}, {"orange", 0xf08a20}, {"yellow", 0xf0e030}, {"green", 0x40c040},
    {"cyan", 0x30d0d0}, {"blue", 0x3c64f0}, {"purple", 0xa040e0}, {"white", 0xf0f0f0},
}
local MARK_RGB = {}
for _, c in ipairs(MARK_COLOURS) do MARK_RGB[c[1]] = c[2] end

local MARK_REACH = 200           -- as far as the paint tool aims: the whole 64-wide world

marks = {on = false, path = nil, text = nil, list = {}, check = 0, colour = 1, note = "",
         at = nil}

-- Reads scene.MARKERS again when its text changed, once a second: whoever wrote it last (this view
-- or Claude, clearing what it has read) is what is shown. Lines that are not markers are kept out.
-- `scene` is the update's own: controller.lua has no `scene` of its own to read.
local function marks_follow(dt, scene)
    marks.check = marks.check - dt
    if marks.check > 0 then return end
    marks.check = 1.0
    -- A viewer started before markers existed reloads this file but not its start: the path is
    -- set here then (an io.open(nil) every frame made the screen flicker, 2026-10-04).
    marks.path = marks.path or (scene and scene.MARKERS and vc.path_resolve(scene.MARKERS))
    if not marks.path then return end
    local f = io.open(marks.path, "rb")
    local text = f and f:read("a") or ""
    if f then f:close() end
    if text == marks.text then return end
    marks.text, marks.list = text, {}
    for line in text:gmatch("[^\n]+") do
        local x, y, z, colour, note =
                line:gsub("\r$", ""):match("^marker (-?%d+) (-?%d+) (-?%d+) (%a+)%s*(.*)$")
        if x then
            marks.list[#marks.list + 1] = {tonumber(x), tonumber(y), tonumber(z), colour, note}
        end
    end
end

-- Writes every marker back, in the order they were placed, and remembers the text so the next
-- follow does not read the view's own write as news.
local function marks_save()
    local out = {"# 3d-draw viewer markers (K): marker x y z colour [note], robot coordinates\n"}
    for _, m in ipairs(marks.list) do
        out[#out + 1] = ("marker %d %d %d %s%s\n"):format(m[1], m[2], m[3], m[4],
                m[5] ~= "" and (" " .. m[5]) or "")
    end
    local text = table.concat(out)
    local f = io.open(marks.path, "wb")
    if not f then
        state.messages[#state.messages + 1] = "markers: cannot write " .. tostring(marks.path)
        return
    end
    f:write(text)
    f:close()
    marks.text = text
end

-- The block under the crosshair, in robot coordinates, or nil. A real voxel cast
-- (world:raycast), not the paint tool's plane: a marker is on one block, at any height. The
-- ground plane the cast also reports is not a block the robots saw, so it is no hit here.
local function marks_aim(w)
    if not state.offset then return nil end
    local cam, fwd = vc.cam_get(), vc.cam_forward()
    local hit = w:raycast(cam[1], cam[2], cam[3], fwd[1], fwd[2], fwd[3], MARK_REACH)
    if not hit[1] or hit[8] then return nil end
    return {hit[2] - state.offset[1], hit[3] - state.offset[2], hit[4] - state.offset[3]}
end

-- The index of the marker on block p, or nil.
local function marks_find(p)
    for i, m in ipairs(marks.list) do
        if m[1] == p[1] and m[2] == p[2] and m[3] == p[3] then return i end
    end
end

-- The marker a right click takes away when none is on the block aimed at: the one nearest the
-- crosshair's ray, within MARK_PICK blocks of it (its dot, the point drawn on the block's top),
-- or one within two blocks of the cell aimed at. A marker whose block is gone - a zone redrawn,
-- terrain dug - has nothing under it to aim at (the user, 2026-10-04: "I can't remove them
-- anymore because they no longer stay on blocks").
local MARK_PICK = 1.5
local function marks_nearest()
    if not state.offset then return nil end
    local cam, fwd = vc.cam_get(), vc.cam_forward()
    local len = math.sqrt(fwd[1] ^ 2 + fwd[2] ^ 2 + fwd[3] ^ 2)
    if len == 0 then return nil end
    local f = {fwd[1] / len, fwd[2] / len, fwd[3] / len}
    local o, a = state.offset, marks.at
    local best, best_d
    for i, m in ipairs(marks.list) do
        local p = {m[1] + o[1] + 0.5 - cam[1], m[2] + o[2] + 1.05 - cam[2],
                   m[3] + o[3] + 0.5 - cam[3]}
        local t = p[1] * f[1] + p[2] * f[2] + p[3] * f[3]
        local d = math.sqrt((p[1] - t * f[1]) ^ 2 + (p[2] - t * f[2]) ^ 2 + (p[3] - t * f[3]) ^ 2)
        local near = a and math.abs(m[1] - a[1]) <= 2 and math.abs(m[2] - a[2]) <= 2
                and math.abs(m[3] - a[3]) <= 2
        if t > 0 and (d <= MARK_PICK or near) and (not best_d or d < best_d) then
            best, best_d = i, d
        end
    end
    return best
end

-- One frame of marker mode: K toggles it, C steps the colour, a click places or takes away.
-- Clicks count only while the pointer is captured, because the crosshair is what aims; with it
-- released (Tab) the panel's note box has the keys, and K or C typed there is just text.
local function marks_update(w)
    local typing = vc.ImGui_WantCaptureKeyboard()
    if not typing and vc.ImGui_IsKeyPressed("ImGuiKey_K", false) then marks.on = not marks.on end
    if not marks.on then
        marks.at = nil
        return
    end
    if not typing and vc.ImGui_IsKeyPressed("ImGuiKey_C", false) then
        marks.colour = marks.colour % #MARK_COLOURS + 1
    end
    marks.at = marks_aim(w)
    if not vc.mouse_captured() or vc.ImGui_WantCaptureMouse() then return end
    local i = marks.at and marks_find(marks.at)
    if vc.ImGui_IsMouseClicked("ImGuiMouseButton_Right", false) then
        i = i or marks_nearest()
        if i then
            table.remove(marks.list, i)
            marks_save()
        end
        return
    end
    if not marks.at then return end
    if vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false) then
        -- A block already marked is marked again: its colour and note become the new ones.
        local m = {marks.at[1], marks.at[2], marks.at[3], MARK_COLOURS[marks.colour][1],
                   (marks.note:gsub("[\r\n]", " "))}
        if i then marks.list[i] = m else marks.list[#marks.list + 1] = m end
        marks_save()
    elseif vc.ImGui_IsMouseClicked("ImGuiMouseButton_Right", false) and i then
        table.remove(marks.list, i)
        marks_save()
    end
end

-- Each marker as a coloured dot on its block's top, with its note (or its colour) over it on a
-- dark backing, the way the labels are drawn; the block aimed at gets a ring in the chosen colour.
local function draw_marks()
    if not state.offset then return end
    local disp = vc.ImGui_GetDisplaySize()
    local W, H = math.floor(disp.x), math.floor(disp.y)
    local o = state.offset
    vc.ImGui_SetDrawForeground(true)
    for _, m in ipairs(marks.list) do
        local at = vc.render_project(m[1] + o[1] + 0.5, m[2] + o[2] + 1.05, m[3] + o[3] + 0.5, W, H)
        if at[3] > 0 and at[1] > -100 and at[1] < W + 100 and at[2] > 0 and at[2] < H then
            local colour = abgr(MARK_RGB[m[4]] or 0xff00ff)
            vc.ImGui_AddCircleFilled({x = at[1], y = at[2]}, 7, colour)
            vc.ImGui_AddCircle({x = at[1], y = at[2]}, 7, 0xff000000, 2)
            local text = m[5] ~= "" and m[5] or m[4]
            local size = vc.ImGui_CalcTextSize(text)
            local x0, y0 = at[1] - size.x / 2 - 4, at[2] - size.y - 14
            vc.ImGui_AddRectFilled({x = x0, y = y0}, {x = x0 + size.x + 8, y = y0 + size.y + 4},
                    0xc0202020, 3)
            vc.ImGui_AddText({x = x0 + 4, y = y0 + 2}, colour, text)
        end
    end
    if marks.on and marks.at then
        local a = marks.at
        local at = vc.render_project(a[1] + o[1] + 0.5, a[2] + o[2] + 1.05, a[3] + o[3] + 0.5, W, H)
        if at[3] > 0 then
            vc.ImGui_AddCircle({x = at[1], y = at[2]}, 11,
                    abgr(MARK_COLOURS[marks.colour][2]), 3)
        end
    end
    vc.ImGui_SetDrawForeground(false)
end

-- The markers' part of the panel: the mode, the colour buttons, the note for the next marker, and
-- what the crosshair is on - the block's name too, so the user sees what they are marking.
local function marks_panel()
    vc.ImGui_Text(("markers %s (K)   %d placed   left click marks, right click unmarks"):format(
            marks.on and "ON " or "off", #marks.list))
    for i, c in ipairs(MARK_COLOURS) do
        if i > 1 then vc.ImGui_SameLine(0, -1) end
        local label = (i == marks.colour and "[%s]" or "%s"):format(c[1])
        if vc.ImGui_SmallButton(label) then marks.colour = i end
    end
    local typed = vc.ImGui_InputText("note", marks.note, 80)
    if typed[1] then marks.note = typed[2] end
    vc.ImGui_Text("the note goes on the next marker; Tab frees the mouse to type, Tab again to aim")
    if marks.on and marks.at then
        local a = marks.at
        local t = state.terrain[a[1] .. "," .. a[2] .. "," .. a[3]]
        local p = t and state.palette[t[1]]
        vc.ImGui_Text(("aiming at %d %d %d  %s"):format(a[1], a[2], a[3],
                p and (p.name .. ":" .. p.meta) or ""))
    end
    vc.ImGui_Text("C: next colour   file: 3d-draw/data/markers.txt")
end

function controller.update(w, scene, dt, speed)
    if vc.ImGui_IsKeyPressed("ImGuiKey_G", false) then paint.on = not paint.on end
    if paint.on then
        if vc.ImGui_IsKeyDown("ImGuiKey_B") then paint_apply(w, false)
        elseif vc.ImGui_IsKeyDown("ImGuiKey_N") then paint_apply(w, true)
        else
            local x, z = aimed()
            paint.at = x and {x, z} or nil
        end
    end
    if vc.ImGui_IsKeyPressed("ImGuiKey_H", false) then
        plan.on = not plan.on
        if plan.on then plan_show(w) else plan_hide(w) end
    end
    if vc.ImGui_IsKeyPressed("ImGuiKey_J", false) and not vc.ImGui_WantCaptureKeyboard() then
        left.on = not left.on
        if left.on then left_show(w) else left_hide(w) end
    end
    plan_follow(w, dt)
    left_follow(w, dt, scene)
    labels_follow(dt)
    marks_follow(dt, scene)
    marks_update(w)
    zmap_update(w, scene)           -- every frame: a key press or a click lasts one
    zone_follow(w, scene, dt)
    if state.redraw_marks then
        paint_draw(w)
        state.redraw_marks = false
    end
    follow.wait = follow.wait - dt
    if follow.wait > 0 then return end
    follow.wait = 0.25
    if not follow.path then return end     -- init did not get as far as naming the file
    local f = io.open(follow.path, "rb")
    if not f then return end
    f:close()
    if state.source ~= scene.LOG and not state.zone then
        w:wipe()
        reset()
        follow.pos, follow.partial = 0, ""
        state.source = scene.LOG
    end
    read_more(w, scene)
    if state.wiped and state.box then
        if plan.on then plan_show(w) end
        if left.on then left_show(w) end
        state.wiped = false
    end
end

local FACING = {north = {0, -1}, south = {0, 1}, west = {-1, 0}, east = {1, 0}}

-- Each robot: a ring where it is, a line the way it faces, its name and energy beside it. Robots
-- are told apart by the name at the end of their `at` events (the user, 2026-10-04, with two:
-- "only cairol is drawn, gunter is not").


local function draw_one(name, r, colour)
    local disp = vc.ImGui_GetDisplaySize()
    local W, H = math.floor(disp.x), math.floor(disp.y)
    local x, y, z = r[1] + state.offset[1] + 0.5, r[2] + state.offset[2] + 0.5,
                    r[3] + state.offset[3] + 0.5
    local at = vc.render_project(x, y, z, W, H)
    if at[3] <= 0 then return end
    local d = FACING[r[4]] or {0, 0}
    local ahead = vc.render_project(x + d[1] * 0.9, y, z + d[2] * 0.9, W, H)
    vc.ImGui_SetDrawForeground(true)
    vc.ImGui_AddCircleFilled({x = at[1], y = at[2]}, 9, colour)
    if ahead[3] > 0 then
        vc.ImGui_AddLine({x = at[1], y = at[2]}, {x = ahead[1], y = ahead[2]}, colour, 3)
    end
    vc.ImGui_AddText({x = at[1] + 12, y = at[2] - 8}, 0xffffffff,
            ("%s  %s  %s"):format(name, r[5] and tostring(r[5]) or "?",
            state.charge and ("(" .. state.charge .. ")") or ""))
    -- What it is at, beside it on the screen, not only in the panel (the user, 2026-10-04:
    -- "all the workers ... to have their status on the screen ... with immediate scope and with
    -- long term scope").
    local st = statuses[name]
    if st then
        vc.ImGui_AddText({x = at[1] + 12, y = at[2] + 6}, 0xffd0e0ff, st[1] .. ": " .. st[2])
        vc.ImGui_AddText({x = at[1] + 12, y = at[2] + 20}, 0xffa0a0a0, st[3])
    end
    vc.ImGui_SetDrawForeground(false)
end

-- Where a robot has been: a line through the cells it went through, in its colour, fading to
-- the oldest (the user, 2026-10-04: "draw the pathing of the bot ... with their colors a
-- connected line path").
local function draw_trail(trail, colour)
    local disp = vc.ImGui_GetDisplaySize()
    local W, H = math.floor(disp.x), math.floor(disp.y)
    local o = state.offset
    local prev
    vc.ImGui_SetDrawForeground(true)
    for i, c in ipairs(trail) do
        local at = vc.render_project(c[1] + o[1] + 0.5, c[2] + o[2] + 0.5, c[3] + o[3] + 0.5, W, H)
        if at[3] > 0 then
            if prev then
                local alpha = math.floor(60 + 195 * i / #trail)
                vc.ImGui_AddLine({x = prev[1], y = prev[2]}, {x = at[1], y = at[2]},
                        (colour & 0x00ffffff) | (alpha << 24), 2)
            end
            prev = at
        else
            prev = nil
        end
    end
    vc.ImGui_SetDrawForeground(false)
end

local function draw_robot()
    if not state.offset then return end
    local names = {}
    for name in pairs(state.robots) do names[#names + 1] = name end
    table.sort(names)
    for i, name in ipairs(names) do
        local colour = robot_colour(name)
        if state.trails[name] then draw_trail(state.trails[name], colour) end
        draw_one(name, state.robots[name], colour)
    end
end

-- The robots' panel: each one's state, what it does next, and how far its whole task is.
local function draw_status()
    local names = {}
    for name in pairs(statuses) do names[#names + 1] = name end
    if #names == 0 then return end
    table.sort(names)
    vc.ImGui_Begin("robots", 0)
    for _, name in ipairs(names) do
        local st = statuses[name]
        local r = state.robots[name]
        vc.ImGui_Text(("%-14s %s%s"):format(name, st[1],
                r and ("   at %d %d %d, energy %s"):format(r[1], r[2], r[3], tostring(r[5])) or ""))
        vc.ImGui_Text("    now:     " .. st[2])
        vc.ImGui_Text("    overall: " .. st[3])
    end
    vc.ImGui_End()
end

function controller.draw(scene)
    draw_robot()
    draw_status()
    draw_zmap()
    draw_labels()
    draw_marks()
    vc.ImGui_Begin("3d-draw - what the robot sees", 0)
    vc.ImGui_Text("source: " .. state.source .. ("   %d events"):format(state.events))
    for name, r in pairs(state.robots) do
        vc.ImGui_Text(("%s at %d %d %d facing %s, energy %s"):format(name, r[1], r[2], r[3],
                tostring(r[4]), tostring(r[5])))
    end
    if state.charge then vc.ImGui_Text("charging: " .. state.charge) end
    vc.ImGui_Separator()
    vc.ImGui_Text("id  block                              cells  picture")
    local ids = {}
    for id in pairs(state.palette) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local p = state.palette[id]
        vc.ImGui_Text(("%2d  %-34s %5d  %s"):format(id, p.name .. ":" .. p.meta, p.count,
                p.tile and "texture" or "colour"))
    end
    vc.ImGui_Separator()
    vc.ImGui_Text("small cubes: guessed (coloured), scanned but not named (grey, blue = liquid)")
    vc.ImGui_Separator()
    vc.ImGui_Text(("paint %s (G)   B marks, N unmarks   %d columns marked"):format(
            paint.on and "ON " or "off", paint_count()))
    vc.ImGui_Text(("brush %dx%d"):format(paint.brush * 2 - 1, paint.brush * 2 - 1))
    vc.ImGui_SameLine(0, -1)
    if vc.ImGui_Button("smaller", {x = 0, y = 0}) and paint.brush > 1 then
        paint.brush = paint.brush - 1
    end
    vc.ImGui_SameLine(0, -1)
    if vc.ImGui_Button("larger", {x = 0, y = 0}) and paint.brush < 8 then
        paint.brush = paint.brush + 1
    end
    if paint.on and paint.at then
        vc.ImGui_Text(("aiming at column %d %d%s"):format(paint.at[1], paint.at[2],
                state.mapped[paint.at[1] .. "," .. paint.at[2]] and " (mapped)" or ""))
    end
    vc.ImGui_Text("then: python 3d-draw/run.py mapper <robot> --extend")
    vc.ImGui_Separator()
    marks_panel()
    vc.ImGui_Separator()
    vc.ImGui_Text(("plan %s (H)   %d blocks in %d files"):format(
            plan.on and "shown" or "hidden", #plan.blocks, #plan.paths))
    vc.ImGui_SameLine(0, -1)
    if vc.ImGui_Button("reload plan", {x = 0, y = 0}) then plan.reload = true end
    left_panel()
    for _, m in ipairs(state.messages) do vc.ImGui_Text(m) end
    vc.ImGui_End()
end

return controller
