--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | How a block of the map is drawn: which texture, which tint, which shape, which way it faces.
-- |
-- |     look.look(name, meta)              key for vc.render_block_tiles, tint 0xRRGGBB, shape
-- |     look.map_shape(name, meta, shape)  the shape and facing of stairs, slabs, fences, panes,
-- |                                        gates, trapdoors and doors, from name and metadata
-- |     look.colour_of(name, meta)         a colour for a block whose texture was not found
-- |     look.CUBE, look.CROSS, look.LEAVES the shapes as world_composer.h numbers them
-- |
-- | Moved whole from the simulator's 3d-draw viewer (simulator/scenes/draw3d/controller.lua,
-- | 2026-10-05, stage 0 of 3d-draw/redesign/08-order.md). That viewer is frozen from then on and
-- | goes once this program shows what it showed; until then the two copies are the same text.
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local blocks = require("blocks")

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

-- The station's blocks (2026-10-05: the user saw wrong textures and models there "much
-- earlier"). Their pictures are named apart from the block in the jars - OpenComputers'
-- `ChargerSide.png` for `OpenComputers:charger`, AE2's `BlockDriveFront.png` for
-- `tile.BlockDrive` - so the name alone found nothing and they were plain cubes of a colour; and
-- levers, cables, conduits and the keyboard are no cubes. Keys read from the jars' file lists
-- (OpenComputers-1.9.14-GTNH, appliedenergistics2-rv3-beta-250-GTNH). The shapes are
-- world_composer.h's: a cable drawn as a fence joins its neighbours, as a cable does; a lever as
-- a cross, like a torch; the keyboard as a thin plate. GregTech's machines and EnderIO's conduits
-- draw their faces in code: no one picture, a colour (NAME_COLOURS) and, for the conduit, the
-- cable's shape.
local FENCE, PLATE = 7, 10
local STATION = {
    ["OpenComputers:charger"] = {"opencomputers:ChargerSide", CUBE},
    ["OpenComputers:case1"] = {"opencomputers:CaseFront", CUBE},
    ["OpenComputers:case2"] = {"opencomputers:CaseFront", CUBE},
    ["OpenComputers:case3"] = {"opencomputers:CaseFront", CUBE},
    ["OpenComputers:adapter"] = {"opencomputers:AdapterSide", CUBE},
    ["OpenComputers:screen1"] = {"opencomputers:screen/fmm", CUBE},
    ["OpenComputers:screen2"] = {"opencomputers:screen/fmm", CUBE},
    ["OpenComputers:screen3"] = {"opencomputers:screen/fmm", CUBE},
    ["OpenComputers:keyboard"] = {"opencomputers:Keyboard", PLATE},
    ["OpenComputers:cable"] = {"opencomputers:CablePart", FENCE},
    ["appliedenergistics2:tile.BlockDrive"] = {"appliedenergistics2:BlockDriveFront", CUBE},
    ["appliedenergistics2:tile.BlockCreativeEnergyCell"] =
            {"appliedenergistics2:BlockCreativeEnergyCell", CUBE},
    ["appliedenergistics2:tile.BlockCableBus"] = {"appliedenergistics2:MECable_Blue", FENCE},
    ["EnderIO:blockConduitBundle"] = {"enderio:conduitConnector", FENCE},
    ["minecraft:lever"] = {"minecraft:lever", CROSS},
}

local function look(name, meta)
    if STATION[name] then return STATION[name][1], 0xffffff, STATION[name][2] end
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

return {look = look, map_shape = map_shape, colour_of = colour_of, CUBE = CUBE, CROSS = CROSS,
        LEAVES = LEAVES}
