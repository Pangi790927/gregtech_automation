"""village.py - the proposal for a village south of the fisher's house: houses round a green, a
wheat field and a windmill (3d-draw/DESIGN.md, TODO.md).

    python 3d-draw/design/village.py

Writes data/village.txt - one block per line, `b x y z name meta shape facing`, robot coordinates,
as harbour.py does - which the viewer shows with the harbour (H; M and a click on chunk 15 10 show
the whole village: robot x -31..16, z 5..52), and prints what each part is, where, and the bill.

The brief (the user, 2026-10-04): "I have a taks for the planner, can we see more thematic houses
around that area? maybe add a field of wheat (I've added seeds and hoes to the me) also build a
windmill in that area, so I will wait for the proposal". The area: the user's blue marker at
robot -9 3 33 (world 246 66 172, chunk 15 10), "around the center of the proposed area".

THE GROUND (read from the chunk store; guessed cells are hardness only): south of the house the
land rises west from the river (y -1 at the bank) to a grassy plateau (y 4-5) under the back
wall. A gully runs from the hollow south of the house (x -6..-2, z 13..17, floor y -4) south-west
and then south to the marker (x -13..-5, z 18..33, floor y -4..-9), and a cave lies under its
west side with a thin roof; its south end is a row of sinkholes round the marker. Lavender grows
everywhere. Old cobblestone lies set in the ground on the plateau's edge (x -24..-14, z 25..35),
torches stand in the grass here and there, and a bee hive hangs in a tree at -3 5 33: all kept.

THE PARTS (robot coordinates; the river is east, north is -z):
  - the green: the meadow on the marker kept as it is, a roofed well two south of the marker,
    benches; the paths meet at the marker;
  - five houses round it and along the lane, in the style of the user's own builds (2026-10-04,
    after the first drawing: "Some images with style, make the building larger, more details,
    with the style similar to what I've given you"): dark oak log posts, cobblestone corner
    pillars and a cobblestone band round every storey, walls of mixed planks, dark stairs
    flaring at the posts' feet, deep ragged roofs in two woods, dormers, a market front under a
    wool awning, a flag (house()):
      A, the inn, 9 x 11, two storeys, x -26..-18 z 40..50;  B, the hall, 9 x 9, two storeys,
      x -14..-6 z 41..49;  C, 9 x 9, one storey under a tall roof with dormers, x -2..6 z
      36..44;  D, the market hall, 8 x 7, x -1..6 z 24..30, open to the south;  E, 5 x 6, two
      storeys, x -17..-13 z 8..13, by the lane;
  - the lane: from the fisher's gravel path (x -11, z 2) south past the cabin, along the
    plateau's edge above the gully, down to the marker; paths from there to every door and to
    the mill, one to the field's gate; lamp posts along them;
  - the wheat field on the plateau, x -27..-20, z 12..24, in two terraces (y 3 and y 4), a
    water source in each, an oak fence round it with a gate to the lane, a scarecrow;
  - the windmill south-west of the field, at -28 31: a stone base, a timber body of mixed
    planks between dark oak posts, cobblestone bands round both, a two-wood cap, and four sails
    of logs and white wool turning toward the village.
Not built, the builders placing no entities and the mini ME holding none: the pictures' item
frames on the bands, their lanterns and banners; torches and glowstone light it instead, and
the flag is wool.
The gully, the cobblestone and the pond on the plateau (-22..-21, 27) are left as they are.

LAVENDER: the user's rule (2026-10-04, as DESIGN.md has it): lavender stays but under buildings.
Paths go round it. The field and the buildings take what grows where they stand, and every one
taken is planted again on open grass nearest where it grew - a choice made here, for the user to
confirm: the field is not a building, but there is no open ground on the plateau without it.
"""
import heapq, os, random, re, sys, zlib
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(os.path.dirname(HERE), "data")
sys.path.insert(0, os.path.dirname(HERE))
import zones                                                   # noqa: E402

# ---- the terrain, from the chunks ----------------------------------------------------------------

AX, AY, AZ = zones.anchor()
WORLD = {}                      # robot (x, y, z) -> (name, meta); air is ("minecraft:air", 0)
GUESS = set()                   # cells only guessed from their hardness
for _f in sorted(os.listdir(zones.CHUNKS)):
    _m = re.match(r"^c(-?\d+)_(-?\d+)\.txt$", _f)
    if not _m:
        continue
    _x0, _z0 = int(_m.group(1)) * 16 - AX, int(_m.group(2)) * 16 - AZ
    if not (-48 <= _x0 <= 32 and -16 <= _z0 <= 64):
        continue                                              # the village and round it
    _cells, _guess = zones.read(os.path.join(zones.CHUNKS, _f))
    for (_x, _y, _z), _v in _cells.items():
        _c = (_x - AX, _y - AY, _z - AZ)
        WORLD[_c] = (_v[0], _v[1]) if _v else ("minecraft:air", 0)
        if (_x, _y, _z) in _guess:
            GUESS.add(_c)

AIR_N, WATER = "minecraft:air", "minecraft:water"
LAVENDER = ("BiomesOPlenty:flowers2", 3)
# Not ground: plants and trees ("tallgrass", not "grass": a grass block is the ground itself).
SOFT = ("leaves", "flower", "tallgrass", "double_plant", "foliage", "plant", "sapling", "vine",
        "log", "torch", "hive")         # the bee hive hangs in its tree at -3 5 33
# What nature put here, which the plan may dig or build over; anything else someone made.
NATURAL = ("minecraft:grass", "minecraft:dirt", "minecraft:stone", "minecraft:sand",
           "minecraft:gravel", "minecraft:clay", "minecraft:tallgrass", "minecraft:log",
           "minecraft:leaves", "BiomesOPlenty:leaves4", "BiomesOPlenty:logs4",
           "BiomesOPlenty:foliage", "BiomesOPlenty:plants", "BiomesOPlenty:flowers2",
           "gregtech:gt.blockstones", AIR_N, WATER)


def name(x, y, z):
    """The block's name, "" for air, None where nothing is known - as the scouts left it, named
    or guessed (the user, 2026-10-04, on guesses: "your assumed leafs is ground, don't break
    ground")."""
    v = WORLD.get((x, y, z))
    return None if v is None else "" if v[0] == AIR_N else v[0]


def soft(n):
    """Whether a block is a plant or a tree, not the ground (the user, 2026-10-04, on guessed
    leaves under the scouts: "your assumed leafs is ground, don't break ground")."""
    return any(s in n.lower() for s in SOFT)


CANOPY = 7                      # the land here tops out at y 6-7: higher guesses over air are trees


def ground(x, z, top=14):
    """The top of the ground or the water in a column: the highest named block that is not a
    plant or a tree, or a guess with no air under it above more ground - a guess over air with
    ground under the air is a canopy the scouts read by hardness alone (leaves came out as dirt,
    seven deep in the oak west of the field). Under the ground soft dirt came out as "leaves" by
    its hardness, so a guess's own name says nothing. Only from CANOPY up: lower, a guess over air
    is the cave's roof (the gully's west side, the sinkholes round the marker), which is ground
    (the user, 2026-10-04: "your assumed leafs is ground, don't break ground").
    """
    def named_ground(y):
        """Whether a cell is ground that is no plant: a scout's guess counts (the user, 2026-10-04:
        "your assumed leafs is ground, don't break ground")."""
        n = name(x, y, z)
        return bool(n) and not ((x, y, z) not in GUESS and soft(n))

    for y in range(top, -15, -1):
        n = name(x, y, z)
        if not n:
            continue
        if (x, y, z) not in GUESS:
            if not soft(n):
                return y
            continue
        if y < CANOPY or not any(name(x, y - k, z) == "" and any(named_ground(y - j)
                                                                 for j in range(k + 1, k + 4))
                                 for k in range(1, 12)):
            return y
    return None


def lavender(x, y, z):
    """Whether a lavender grows in a cell (the user's rule, 2026-10-04, as DESIGN.md has it:
    lavender stays but under buildings)."""
    return WORLD.get((x, y, z)) == LAVENDER


# ---- what is kept --------------------------------------------------------------------------------

# The user's rules (2026-10-04): never into the station, the house, the harbour or the tunnels Tom
# and Cairol dug; never touch existing water; lavender stays but under buildings; trees and dirt
# may go within reason; the korpBlock wall is never broken.
KEPT = set()
for _line in open(os.path.join(DATA, "built.txt")):            # the house and the harbour
    _p = _line.split()
    if _p and not _p[0].startswith("#"):
        KEPT.add((int(_p[0]) - AX, int(_p[1]) - AY, int(_p[2]) - AZ))
for _plan in ("house.txt", "harbour.txt"):                      # their plans, finished or not
    for _line in open(os.path.join(DATA, _plan)):
        _p = _line.split()
        if _p and _p[0] == "b":
            KEPT.add(tuple(map(int, _p[1:4])))
for _line in open(os.path.join(DATA, "refused.txt")):          # the scouts' tunnels
    _p = _line.split()
    if _p and not _p[0].startswith("#"):
        KEPT.add(tuple(map(int, _p[:3])))
for _c, (_n, _) in WORLD.items():                               # what someone made, and under it
    if _n not in NATURAL:
        KEPT.add(_c)
        KEPT.add((_c[0], _c[1] - 1, _c[2]))                     # a torch stands on its block
WET = {c for c, v in WORLD.items() if v[0] == WATER}
# The bee hive's tree: no path under it, nothing planned round it.
HIVE = {(c[0] + dx, c[2] + dz) for c, v in WORLD.items() if "hive" in v[0]
        for dx in (-1, 0, 1) for dz in (-1, 0, 1)}


def by_water(x, y, z):
    """Whether a cell touches water from the side or above: opened, it would let the water in.
    Water is touched only by a planned block in its own cell (the user, 2026-10-04: "a block
    that will be replaced either way"); this plan puts none in any."""
    return any((x + dx, y + dy, z + dz) in WET
               for dx, dy, dz in ((1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1), (0, 1, 0)))


# ---- the plan ------------------------------------------------------------------------------------

plan = {}                       # (x, y, z) -> (name, meta, shape, facing)
part_of = {}                    # (x, y, z) -> the part that planned it
refused = Counter()             # what was not planned, and why
moved_lavender = []             # lavender a building, the field or a path takes the place of
moved_by = Counter()            # how many of them, by part
PART = ["-"]
CUBE, CROSS, SLAB, SLAB_TOP, STAIRS, STAIRS_DOWN, FENCE, PANE, GATE, PANEL = \
    0, 1, 3, 4, 5, 6, 7, 8, 9, 12
AIR = (AIR_N, 0)
OUT = {"xpos": (1, 0), "xneg": (-1, 0), "zpos": (0, 1), "zneg": (0, -1)}
OPP = {"xpos": "xneg", "xneg": "xpos", "zpos": "zneg", "zneg": "zpos"}


def put(x, y, z, block, shape=CUBE, facing="-", building=False):
    """A block into the plan, unless the cell is kept: the station, the house, the harbour, the
    tunnels (the user, 2026-10-04: "Leave them"), what someone made, water. Lavender, or the
    block a lavender stands on, only for a building (the user's rule, 2026-10-04: lavender stays
    but under buildings); its flower is then planted again elsewhere (replant())."""
    c = (x, y, z)
    if c in KEPT:
        refused["kept (built, planned, the tunnels, made by someone)"] += 1
        return False
    if c in WET:
        refused["water"] += 1
        return False
    for cc in (c, (x, y + 1, z)):
        if lavender(*cc) and cc not in plan:
            if not building:
                refused["lavender"] += 1
                return False
            if cc not in moved_lavender:
                moved_lavender.append(cc)
                moved_by[PART[0]] += 1
                if cc != c:
                    plan[cc] = (AIR_N, 0, CUBE, "-")
                    part_of[cc] = PART[0]
    plan[c] = (block[0], block[1], shape, facing)
    part_of[c] = PART[0]
    return True


def clear(x, y, z, building=False):
    """Terrain out of the way: dug out (an `air` line), unless something is planned there, the
    cell is air already, kept, water, or beside water - only what a planned building, path or
    field stands in (the user, 2026-10-04: "Keep hidden ground")."""
    n = name(x, y, z)
    if not n or n == WATER or (x, y, z) in plan or by_water(x, y, z):
        if n and by_water(x, y, z) and (x, y, z) not in plan:
            refused["beside water"] += 1
        return
    put(x, y, z, AIR, building=building)


def stairs(x, y, z, material, facing, down=False, building=True):
    """Stairs rising toward `facing`; upside down, the step hangs under the facing side - as
    placing.py places them (the user, 2026-10-04, of the fisher's roof: "more detail, more
    randomness, more wavy/depth")."""
    put(x, y, z, (STAIR[material], 0), STAIRS_DOWN if down else STAIRS, facing, building)


# ---- materials -----------------------------------------------------------------------------------

RNG = random.Random(11)         # the same village every time it is drawn
STONEBRICK = ("minecraft:stonebrick", 0)
COBBLE = ("minecraft:cobblestone", 0)
COBBLE_BRICKS = ("chisel:cobblestone", 1)       # "Detailed Cobblestone Bricks"
COBBLE_PANEL = ("chisel:cobblestone", 10)       # with a creeper panel, now and then
STONE, GRAVEL = ("minecraft:stone", 0), ("minecraft:gravel", 0)
SPRUCE = ("minecraft:planks", 1)
DARK_OAK = ("minecraft:planks", 5)
# The user's chisel spruce planks (640 of them in the mini ME): wall infill, under the roofs.
CHISEL_SPRUCE = ("chisel:spruce_planks", 14)
LOG_UP, LOG_X, LOG_Z = ("minecraft:log", 1), ("minecraft:log", 5), ("minecraft:log", 9)
FENCE_OAK = ("minecraft:fence", 0)              # 714 in the mini ME: rails, posts, the field
GATE_S = ("malisisdoors:spruceFenceGate", 0)
TRAPDOOR = ("malisisdoors:trapdoor_spruce", 4)  # open: the shutters
PANE_G = ("minecraft:glass_pane", 0)
DOOR = "minecraft:wooden_door"
TORCH = ("minecraft:torch", 5)
GLOW = ("minecraft:glowstone", 0)
CHEST = ("minecraft:chest", 0)
HAY = ("minecraft:hay_block", 0)
PUMPKIN = ("minecraft:pumpkin", 0)
WOOL = ("minecraft:wool", 0)                    # the sails' cloth
SLAB_STONE = ("minecraft:stone_slab", 5)        # stone brick
SLAB_SMOOTH = ("minecraft:stone_slab", 0)
SLAB_SPRUCE = ("minecraft:wooden_slab", 1)
SLAB_DARK = ("minecraft:wooden_slab", 5)
FARMLAND = ("minecraft:farmland", 0)
WHEAT = ("minecraft:wheat", 0)
WATER_B = (WATER, 0)
STAIR = {"spruce": "minecraft:spruce_stairs", "dark_oak": "minecraft:dark_oak_stairs",
         "stonebrick": "minecraft:stone_brick_stairs", "cobble": "minecraft:stone_stairs"}


def stone():
    """A block of mixed stone, as the harbour's: stone bricks, detailed cobblestone bricks,
    cobblestone, smooth stone, now and then the creeper-panel cobble (the user, 2026-10-04: "use
    normal cobble with gravel and maybe chisel variants"); smooth stone to spare the bricks and
    the cobble, which the bands and the paving want."""
    return RNG.choices([STONEBRICK, STONE, COBBLE_BRICKS, COBBLE, COBBLE_PANEL],
                       [42, 30, 10, 14, 4])[0]


def lamp(x, z, h=2):
    """A lamp post on the ground: oak fences and a torch on top, as the cabin's (the user,
    2026-10-04: "you can also put torches alongside it"); never on a path or a lavender."""
    g = ground(x, z)
    if g is None or name(x, g, z) == WATER or any((x, g + k, z) in plan for k in range(1, h + 2)):
        return
    if name(x, g + 1, z) or lavender(x, g + 1, z):
        return
    for k in range(1, h + 1):
        put(x, g + k, z, FENCE_OAK, FENCE)
    put(x, g + h + 1, z, TORCH, CROSS)


# ---- the wheat field -----------------------------------------------------------------------------

# The user, 2026-10-04: "maybe add a field of wheat (I've added seeds and hoes to the me)". On the
# plateau, the flattest open ground near the area that keeps off the cobblestone and the pond:
# 8 wide (x -27..-20), 13 long (z 12..24). The ground rises south, so two terraces, each dug down
# to its lowest cell and never filled - a hoe tills only dirt or grass already there:
# the north one (z 12..17) at y 3, the south one (z 18..24) at y 4. A water source in each, its
# four sides farmland of its own level, stone under it: vanilla farmland is wet within 4 cells
# across and with the water level with it or one above, so the south source wets the north
# terrace's last row too. An oak fence round it on the ground as it is; a gate east, to the lane.
FX0, FX1, FZ0, FZ1 = -27, -20, 12, 24
TERRACES = ((12, 17, 3), (18, 24, 4))           # z from, z to, the farmland's y
SOURCES = ((-24, 3, 14), (-24, 4, 21))
SCARECROW = (-21, 21)
FIELD_GATE = (-19, 15)


def level_at(z):
    """The farmland's y in a row of the field: its terrace's (the user, 2026-10-04: "maybe add a
    field of wheat")."""
    return next(y for z0, z1, y in TERRACES if z0 <= z <= z1)


def field():
    """The field: farmland ("minecraft:farmland", tilled by a builder with the hoe) with wheat
    on it ("minecraft:wheat" 0: seeds planted), the water sources, the earth dug off above each
    terrace, the oak in it felled, a fence round it and a scarecrow.

    Planting is a new action for the builders, built first (the user, 2026-10-04: "you will have
    to start with building the fields, that is a new action for you and I want to see you run it
    first, make sure you don't break"), so every field cell is plainly farmland or wheat; the
    cell the farmland is tilled in is dirt or grass already, the terraces being dug, never
    filled. The one oak standing in the field (its
    trunk at -26 5..8 13, its limbs at y 9..11) and the one on the south fence line (-22 25)
    are felled: their logs are dug out; their leaves, left alone, decay. Lavender under the
    field is planted again round it (replant())."""
    PART[0] = "field"
    for x in range(FX0, FX1 + 1):
        for z in range(FZ0, FZ1 + 1):
            L = level_at(z)
            g = ground(x, z)
            for y in range(L + 1, max(g if g is not None else L, L) + 1):
                clear(x, y, z, building=True)                 # the terrace dug down
            for y in range(L + 1, L + 14):                    # the trees in it felled
                n = name(x, y, z)
                if n and ("log" in n or ((x, y, z) in GUESS and not soft(n))):
                    clear(x, y, z, building=True)
            if (x, L, z) in SOURCES or (x, z) == SCARECROW:
                continue
            if g is not None and g < L:
                refused["field cell over lower ground (left out)"] += 1
                continue
            put(x, L, z, FARMLAND, building=True)
            put(x, L + 1, z, WHEAT, CROSS, building=True)
    for x, y, z in SOURCES:
        put(x, y - 1, z, STONE, building=True)                # what holds it up, for sure
        put(x, y, z, WATER_B, building=True)
    # the felled oak's limbs north of the field too, or they would hang there and keep its
    # leaves alive (logs at -27..-24, y 9..11, z 9..12)
    for x in range(-28, -22):
        for z in range(8, 18):
            for y in range(5, 14):
                n = name(x, y, z)
                if n and "log" in n:
                    clear(x, y, z, building=True)
    # the scarecrow, on a cell left untilled: a fence post, a hay body with fence arms, a head
    sx, sz = SCARECROW
    L = level_at(sz)
    put(sx, L + 1, sz, FENCE_OAK, FENCE, building=True)
    put(sx, L + 2, sz, HAY, building=True)
    put(sx - 1, L + 2, sz, FENCE_OAK, FENCE, building=True)
    put(sx + 1, L + 2, sz, FENCE_OAK, FENCE, building=True)
    put(sx, L + 3, sz, PUMPKIN, CUBE, "zpos", building=True)
    # the fence, a ring one out, on the ground as it is; the tree on its line felled first
    for x in range(FX0 - 1, FX1 + 2):
        for z in range(FZ0 - 1, FZ1 + 2):
            if FX0 <= x <= FX1 and FZ0 <= z <= FZ1:
                continue
            g = ground(x, z)
            for y in range((g or 0) + 1, (g or 0) + 14):
                n = name(x, y, z)
                if n and "log" in n:
                    clear(x, y, z, building=True)
            if (x, z) == (-22, 25):                           # the felled tree's foot
                g = min(ground(x + 1, z), ground(x - 1, z))
                for y in range(g + 1, g + 8):
                    clear(x, y, z, building=True)
            if g is None or name(x, g, z) == WATER:
                continue
            if (x, z) == FIELD_GATE:
                put(x, g + 1, z, GATE_S, GATE, "xpos", building=True)
            else:
                put(x, g + 1, z, FENCE_OAK, FENCE, building=True)
    for x, z in ((FX0 - 1, FZ0 - 1), (FX1 + 1, FZ0 - 1), (FX0 - 1, FZ1 + 1), (FX1 + 1, FZ1 + 1)):
        g = ground(x, z)
        if g is not None and (x, g + 1, z) in plan:
            put(x, g + 2, z, TORCH, CROSS, building=True)     # corner posts lit


# ---- the windmill --------------------------------------------------------------------------------

# The user, 2026-10-04: "also build a windmill in that area". A tower mill south-west of the
# field, on the plateau's highest ground (y 5-6), clear of the cobblestone at -24 5 30: an
# octagonal stone base, a narrower timber body on it, a cap, and four sails turned east,
# toward the village, in the plane x -23 - over the path to its door, four above it at the
# lowest, and over the field's south-east corner, eleven above the wheat.
WX, WZ = -28, 31


def octagon(r):
    """The ring of a square of half-width r with its corners cut: the mill's round (the user,
    2026-10-04: "also build a windmill in that area")."""
    return [(dx, dz) for dx in range(-r, r + 1) for dz in range(-r, r + 1)
            if max(abs(dx), abs(dz)) == r and not (abs(dx) == r and abs(dz) == r)] + \
        [(dx, dz) for dx in (-r + 1, r - 1) for dz in (-r + 1, r - 1)]


def inside(r):
    """The cells inside the octagon of half-width r: the mill's floor (the user, 2026-10-04: "also
    build a windmill in that area")."""
    ring = set(octagon(r))
    return [(dx, dz) for dx in range(-r + 1, r) for dz in range(-r + 1, r)
            if (dx, dz) not in ring]


def windmill():
    """The mill. The base: half-width 3, mixed stone from the ground up five, floored with
    spruce, a door east with a step down to the path, small windows, hay and chests inside; its
    top a stone shoulder round the body, with a lamp post at three of its sides. The body:
    half-width 2, chisel spruce with spruce log posts on its four short diagonal faces, seven
    high, a window each side twice. The cap: a dark oak gable with its ridge along the axle. The
    axle: a log out of the body's east face to the hub; the sails: four spars of spruce logs,
    seven long, up, down, north and south, each with a cloth of white wool two wide on its
    trailing side - logs and wool, full blocks a builder can click one against the next all the
    way out (a chain of fences can only be clicked on top). The user, 2026-10-04: "also build a
    windmill in that area"."""
    PART[0] = "windmill"
    foot = [ground(WX + dx, WZ + dz) for dx in range(-3, 4) for dz in range(-3, 4)]
    F = sorted(g for g in foot if g is not None)[len(foot) * 2 // 3]   # its floor: y 6
    base_top, body_top = F + 5, F + 12
    for dx, dz in octagon(3) + inside(3):
        x, z = WX + dx, WZ + dz
        g = ground(x, z)
        for y in range((g if g is not None else F - 3) + 1, F):
            put(x, y, z, STONE if y < F - 1 else stone(), building=True)   # the footing
        ring = (dx, dz) in octagon(3)
        put(x, F, z, stone() if ring else SPRUCE, building=True)
        for y in range(F + 1, body_top + 6):
            clear(x, y, z, building=True)
        if ring:
            for y in range(F + 1, base_top + 1):
                put(x, y, z, band_stone() if y == base_top or (abs(dx), abs(dz)) == (2, 2)
                    else stone(), building=True)              # pillars on the cut corners
        else:
            put(x, base_top, z, SPRUCE, building=True)          # the body's floor
    for dx, dz in ((-3, 0), (0, 3), (0, -3)):                  # the shoulder's lamps
        put(WX + dx, base_top + 1, WZ + dz, FENCE_OAK, FENCE, building=True)
        put(WX + dx, base_top + 2, WZ + dz, TORCH, CROSS, building=True)
    # the door, east, and the step down to the path; windows round the base
    door_x = WX + 3
    put(door_x, F + 1, WZ, (DOOR, DOOR_META["xpos"]), PANEL, "xpos", building=True)
    put(door_x, F + 2, WZ, (DOOR, 8), PANEL, "xpos", building=True)
    gx = ground(door_x + 1, WZ)
    for y in range(gx + 1, F + 1):
        if y == F:
            stairs(door_x + 1, y, WZ, "stonebrick", "xneg")
        else:
            put(door_x + 1, y, WZ, stone(), building=True)
    for y in range(F + 1, F + 4):
        clear(door_x + 1, y, WZ, building=True)
    for dx, dz in ((-3, 0), (0, 3), (0, -3)):
        put(WX + dx, F + 3, WZ + dz, PANE_G, PANE, building=True)
    # inside the base: hay, chests of flour, a light
    put(WX - 1, F + 1, WZ - 2, HAY, building=True)
    put(WX - 2, F + 1, WZ - 1, CHEST, CUBE, "xpos", building=True)
    put(WX - 1, F + 1, WZ + 2, CHEST, CUBE, "zneg", building=True)
    put(WX, F, WZ, GLOW, building=True)
    # the body: octagon(2) is its wall, the four (1, 1) cells its posts
    for k in range(1, body_top - base_top + 1):
        y = base_top + k
        for dx, dz in octagon(2):
            if (dx, dz) in ((2, 0), (-2, 0), (0, 2), (0, -2)) and k in (2, 5):
                put(WX + dx, y, WZ + dz, PANE_G, PANE, building=True)
            else:
                post = abs(dx) == 1 and abs(dz) == 1
                put(WX + dx, y, WZ + dz, LOG2 if post else wall_plank(), building=True)
    # cobblestone bands, as on the user's houses: one out round the base's top and round the
    # body's top - upside-down cobble stairs, full blocks where the cap's eaves rest on them
    for dx, dz in octagon(2):                                  # the body's top course
        if not (abs(dx) == 1 and abs(dz) == 1):
            put(WX + dx, body_top, WZ + dz, band_stone(), building=True)
    for yb, r_out in ((base_top, 4), (body_top, 3)):
        for dx, dz in octagon(r_out):
            x, z = WX + dx, WZ + dz
            if (abs(dz) == r_out and yb == body_top) or abs(dx) == abs(dz):
                put(x, yb, z, band_stone(), building=True)
            else:
                f = ("xpos" if dx < 0 else "xneg") if abs(dx) >= abs(dz) else \
                    ("zpos" if dz < 0 else "zneg")
                stairs(x, yb, z, "cobble", f, down=True)
    for dx, dz in ((4, 0), (-4, 0), (0, 4), (0, -4)):          # the flare at the foot, not east
        if dx == 4:
            continue
        x, z = WX + dx, WZ + dz
        g = ground(x, z)
        if g is not None and g <= F:
            for y in range(max(g + 1, F - 2), F + 1):
                put(x, y, z, stone(), building=True)
            f = ("xpos" if dx < 0 else "xneg") if dx else ("zpos" if dz < 0 else "zneg")
            stairs(x, F + 1, z, "dark_oak", f)
    # the cap: a dark oak gable over the body, ridge along x, one over all round
    cy = body_top + 1
    woods, fulls = blue_woods("windmill", 7, 7, 3)
    for dx in range(-3, 4):
        for r in range(3):
            for sgn, up, sx in ((-1, "zpos", r), (1, "zneg", 6 - r)):
                m = woods[(dx + 3, sx)]
                plank = WOOD_PLANK[m]
                if (dx + 3, sx) in fulls:
                    put(WX + dx, cy + r, WZ + sgn * (3 - r), plank, building=True)
                else:
                    stairs(WX + dx, cy + r, WZ + sgn * (3 - r), m, up)
                if r >= 1 and abs(dx) <= 2:
                    put(WX + dx, cy + r - 1, WZ + sgn * (3 - r), plank, building=True)
        m = woods[(dx + 3, 3)]
        put(WX + dx, cy + 3, WZ, WOOD_PLANK[m], building=True)     # the ridge
        if abs(dx) <= 2:
            put(WX + dx, cy + 2, WZ, WOOD_PLANK[m], building=True)
        if dx % 2 == 0:
            put(WX + dx, cy + 4, WZ, SLAB_DARK if m == "dark_oak" else SLAB_SPRUCE, SLAB,
                building=True)
    for dx in (-2, 2):                                           # the gables, closed
        for dz in (-1, 0, 1):
            put(WX + dx, cy, WZ + dz, DARK_OAK, building=True)
        put(WX + dx, cy + 1, WZ, DARK_OAK, building=True)
    # the axle and the hub, at the body's top storey, east
    hub_y = body_top - 1
    hub = WX + 5
    for x in range(WX + 3, hub):
        put(x, hub_y, WZ, LOG_X, building=True)
    put(hub, hub_y, WZ, DARK_OAK, building=True)
    # the sails: (along y or z, the way out, the cloth's side) - a pinwheel
    for (ay, az, cy_, cz) in ((1, 0, 0, -1), (0, -1, -1, 0), (-1, 0, 0, 1), (0, 1, 1, 0)):
        for k in range(1, 8):
            y, z = hub_y + ay * k, WZ + az * k
            put(hub, y, z, LOG_UP if ay else LOG_Z, building=True)
            if k >= 2:
                for w in (1, 2):
                    put(hub, y + cy_ * w, z + cz * w, WOOL, building=True)
    return F, base_top, body_top, hub_y


# ---- the houses ----------------------------------------------------------------------------------

# The user, 2026-10-04, on the first drawing, with five pictures of their own builds: "Some images
# with style, make the building larger, more details, with the style similar to what I've given
# you". What the pictures show: heavy dark log posts; walls of mixed planks, light and dark; a
# band of cobblestone round the top of every storey, standing out from the wall, cobblestone
# pillars at the corners; dark stairs flaring out at the foot of the posts; deep, ragged roofs of
# stairs on planks in two woods; dormers; market fronts under wool awnings; torches on the bands.
LOG2 = ("minecraft:log2", 1)                    # dark oak, upright: the posts (771 in the mini ME)
BIRCH = ("minecraft:planks", 2)                 # the light planks, from the mini ME's birch logs
WOOL_ORANGE = ("minecraft:wool", 1)
DOOR_META = {"zneg": 1, "zpos": 3, "xneg": 0, "xpos": 2}   # the lower half, by the way out
SIDES = ("zneg", "zpos", "xneg", "xpos")
STOREY = 5                      # four of wall, then the band


def wall_plank():
    """A wall's plank, mixed for the pictures' patchy walls (the user, 2026-10-04: "with the style
    similar to what I've given you"): the user's chisel spruce, birch for the light ones, spruce
    and dark oak (spruce logs are the shortest); oak, the pictures' own light plank, is not in
    the mini ME."""
    return RNG.choices([CHISEL_SPRUCE, BIRCH, SPRUCE, DARK_OAK], [42, 33, 13, 12])[0]


def band_stone():
    """A block of the cobblestone bands and pillars, as in the user's pictures (2026-10-04: "with
    the style similar to what I've given you"): cobblestone mostly, the detailed cobblestone
    bricks and stone bricks among it."""
    return RNG.choices([COBBLE, COBBLE_BRICKS, STONEBRICK], [43, 10, 47])[0]


WOOD_PLANK = {"dark_oak": DARK_OAK, "spruce": SPRUCE}
ROOF_STATS = []                 # (roof, largest one-wood patch, like-neighbour share, fulls, cells)
PATCH = 6                       # the most cells of one wood that may touch


def blue_woods(label, na, ns, ridge, full_share=0.085):
    """The woods of a roof's surface, cell by cell, and the cells that are full blocks. The user,
    2026-10-04: "so for the roofs try to have a more checkered pattern so that you have less big
    blobs of one color but not so precise as to assume a pattern. So make it chaotic enough that
    it dosent have a distinct pattern and  precise enough that it dosent have blobs of color on
    the roof, even if that would eventually happen in a chaotic pattern. Try to put rarely full
    blocks instead of tairs as that gives it a rustic feeling and less of a perfect roof."

    Blue noise, not white: the surface is a grid, `na` cells along the ridge by `ns` across it,
    over the ridge (row `ridge`) from eave to eave. Its cells are visited in a random order, and
    each takes dark oak (likelier, 62:38: the spruce logs run short) or spruce, the odds of a
    wood cut to 0.85 for every neighbour already of it; a wood that would make three in a line, a
    2x2 of one wood, or a patch of more than PATCH cells is all but ruled out - so like
    neighbours come to a third or so, against a half by coin tosses and none on a checkerboard.
    About `full_share` of the cells, never on an eave
    row or the ridge, become full blocks, no two touching (diagonals too). Seeded by the roof's
    name: the same roof every run. Returns {(a, s): wood} and the full cells, and notes the
    largest one-wood patch and the share of like neighbours in ROOF_STATS."""
    rng = random.Random(zlib.crc32(label.encode()))
    wood = {}

    def breaks(c, w):
        """Whether wood w at c makes three in a line or a 2x2 of one wood (the user, 2026-10-04:
        "precise enough that it dosent have blobs of color on the roof")."""
        a, s = c
        for da, ds in ((1, 0), (0, 1)):
            run = 1
            for sgn in (1, -1):
                k = 1
                while wood.get((a + sgn * k * da, s + sgn * k * ds)) == w:
                    run += 1
                    k += 1
            if run >= 3:
                return True
        for oa in (0, -1):
            for os_ in (0, -1):
                sq = [(a + oa + i, s + os_ + j) for i in (0, 1) for j in (0, 1)]
                if all(q == c or wood.get(q) == w for q in sq):
                    return True
        patch, todo = {c}, [c]                                # a patch of more than PATCH
        while todo and len(patch) <= PATCH:
            pa, ps = todo.pop()
            for q in ((pa + 1, ps), (pa - 1, ps), (pa, ps + 1), (pa, ps - 1)):
                if q not in patch and wood.get(q) == w:
                    patch.add(q)
                    todo.append(q)
        return len(patch) > PATCH

    cells = [(a, s) for a in range(na) for s in range(ns)]
    rng.shuffle(cells)
    for c in cells:
        odds = {}
        for w, base in (("dark_oak", 0.62), ("spruce", 0.38)):
            like = sum(wood.get((c[0] + da, c[1] + ds)) == w
                       for da, ds in ((1, 0), (-1, 0), (0, 1), (0, -1)))
            odds[w] = base * 0.85 ** like * (0.01 if breaks(c, w) else 1)
        wood[c] = "dark_oak" if rng.random() * (odds["dark_oak"] + odds["spruce"]) < \
            odds["dark_oak"] else "spruce"
    full = set()
    inner = [c for c in cells if c[1] not in (0, ns - 1, ridge)]
    want = round(full_share * len(inner))
    for c in inner:
        if len(full) >= want:
            break
        if not any((c[0] + da, c[1] + ds) in full for da in (-1, 0, 1) for ds in (-1, 0, 1)):
            full.add(c)
    seen, biggest = set(), 0
    for c in wood:
        if c in seen:
            continue
        todo, n = [c], 0
        seen.add(c)
        while todo:
            a, s = todo.pop()
            n += 1
            for q in ((a + 1, s), (a - 1, s), (a, s + 1), (a, s - 1)):
                if q in wood and q not in seen and wood[q] == wood[c]:
                    seen.add(q)
                    todo.append(q)
        biggest = max(biggest, n)
    pairs = [(c, (c[0] + da, c[1] + ds)) for c in wood for da, ds in ((1, 0), (0, 1))
             if (c[0] + da, c[1] + ds) in wood]
    like = sum(wood[p] == wood[q] for p, q in pairs) / len(pairs)
    ROOF_STATS.append((label, biggest, like, len(full), len(wood)))
    return wood, full


def window(x, y, z, out, shutters=False, h=2):
    """A window `h` high in the wall from y up; open spruce trapdoor shutters either side where
    asked, or else a sill of an upside-down dark oak stair under it outside - not both: the
    front's windows look onto the paths, where a sill at head height would be in the way
    (house.py's; the user, 2026-10-04: "more details")."""
    for k in range(h):
        put(x, y + k, z, PANE_G, PANE, building=True)
    dx, dz = OUT[out]
    ax, az = (0, 1) if dx else (1, 0)
    if shutters:
        for s in (-1, 1):
            put(x + dx + ax * s, y + h - 1, z + dz + az * s, TRAPDOOR, PANEL, OPP[out],
                building=True)
    else:
        stairs(x + dx, y - 1, z + dz, "dark_oak", OPP[out], down=True)


def house(label, x0, z0, w, d, door, storeys=2, chimney=None, dormers=False, market=False,
          double=False, flag=False, F=None):
    """A house in the user's style (2026-10-04: "make the building larger, more details, with the
    style similar to what I've given you"): walls w by d from x0, z0, the door in the middle of
    the `door` side.
      - footing of mixed stone up to the floor (at most three deep: a sinkhole is capped);
      - every storey four high: cobblestone pillars at the corners, dark oak log posts every
        third cell, mixed planks between, windows of two panes with dark sills, shutters on the
        front; a band of cobblestone round its top, one out from the wall - upside-down cobble
        stairs, here and there a full block, torches on its corners;
      - dark oak stairs flaring at the foot of the posts, on the sides without the door, each
        on the ground or a stone set under it;
      - a deep gable roof along the longer side: stairs in dark oak and spruce mixed with no
        patches and no pattern (blue_woods()), on planks (every stair but the eaves' on a full
        block), now and then a full block or a log end in a stair's place, a ridge of planks
        with a crest of slabs, gables of mixed planks round a log post with a window; dormers
        on both long sides where asked;
      - a cobblestone chimney through a gable's overhang where asked; inside, a floor of planks
        to every storey, a flight of stairs up, a chest, a table, glowstone lights;
      - `market`: the front open between its posts under a striped wool awning - hung from the
        posts and the band, no posts of its own in the way - a counter and goods under it (the
        pictures' market fronts);
      - `flag`: a pole on the ridge with an orange wool flag (the pictures' flags).
    Returns the floor's y and the cell outside the door."""
    PART[0] = label
    x1, z1 = x0 + w - 1, z0 + d - 1
    if F is None:
        gs = sorted(g for g in (ground(x, z) for x in range(x0, x1 + 1)
                                for z in range(z0, z1 + 1)) if g is not None)
        F = gs[len(gs) // 2]
    top = F + STOREY * storeys                                 # the top band
    along_x = w >= d
    span = (d if along_x else w) + 2                         # odd: every house here has an odd
    rows = (span - 1) // 2                                   # side across its ridge
    roof_top = top + rows + 4
    # the ground: footing and floor in the walls, cleared round them two out
    for x in range(x0 - 2, x1 + 3):
        for z in range(z0 - 2, z1 + 3):
            edge = not (x0 <= x <= x1 and z0 <= z <= z1)
            g = ground(x, z)
            for y in range(F + 2 if edge else F + 1, roof_top + 1):
                clear(x, y, z, building=True)
            if edge:
                continue
            for y in range(max((g if g is not None else F - 3) + 1, F - 3), F):
                put(x, y, z, STONE if y < F - 1 else stone(), building=True)   # hidden: plain
            wall = x in (x0, x1) or z in (z0, z1)
            put(x, F, z, stone() if wall else BIRCH, building=True)
    # the walls, storey by storey
    mid_x, mid_z = (x0 + x1) // 2, (z0 + z1) // 2
    fx, fz = (1, 0) if door in ("zneg", "zpos") else (0, 1)
    dcx, dcz = {"zneg": (mid_x, z0), "zpos": (mid_x, z1), "xneg": (x0, mid_z),
                "xpos": (x1, mid_z)}[door]
    doors = [] if market else [(dcx, dcz)] + ([(dcx - fx, dcz - fz)] if double else [])

    def on_side(x, z, side):
        """Whether a wall cell is on that side (the user, 2026-10-04: "more details")."""
        return {"zneg": z == z0, "zpos": z == z1, "xneg": x == x0, "xpos": x == x1}[side]

    def along(x, z, side):
        """The cell's place along its wall, from the wall's first corner."""
        return x - x0 if side in ("zneg", "zpos") else z - z0

    def post_at(x, z, side):
        """Whether a wall cell holds a post: every third, and the ends (the user's pictures,
        2026-10-04)."""
        i, n = along(x, z, side), (w if side in ("zneg", "zpos") else d) - 1
        return i % 3 == 0 or i == n
    for k in range(storeys):
        base = F + STOREY * k
        for x in range(x0, x1 + 1):
            for z in range(z0, z1 + 1):
                if not (x in (x0, x1) or z in (z0, z1)):
                    continue
                corner = x in (x0, x1) and z in (z0, z1)
                side = next(s for s in SIDES if on_side(x, z, s))
                post = post_at(x, z, side)
                open_front = market and k == 0 and on_side(x, z, door) and not corner and \
                    not post
                for y in range(base + 1, base + STOREY):
                    if corner:
                        put(x, y, z, band_stone(), building=True)
                    elif post:
                        put(x, y, z, LOG2, building=True)
                    elif open_front:
                        clear(x, y, z, building=True)
                    else:
                        put(x, y, z, wall_plank(), building=True)
        # windows: the bays between the posts, every other one; the front's with shutters
        for side in SIDES:
            if side == chimney:
                continue
            ox, oz = OUT[side]
            cells = [(x, z) for x in range(x0, x1 + 1) for z in range(z0, z1 + 1)
                     if on_side(x, z, side) and not (x in (x0, x1) and z in (z0, z1))]
            bays = [c for c in cells if not post_at(c[0], c[1], side)]
            for i, (x, z) in enumerate(bays):
                if i % 2 or (k == 0 and side == door and (market or (x, z) in doors or
                                                         abs(along(x, z, side) - along(
                                                             dcx, dcz, side)) <= 1)):
                    continue
                window(x, base + 2, z, side, shutters=side == door and k == 0)
        # the band round the storey's top, one out; full blocks on top, under the roof's eaves
        yb = base + STOREY
        for x in range(x0 - 1, x1 + 2):
            for z in range(z0 - 1, z1 + 2):
                inner = x0 <= x <= x1 and z0 <= z <= z1
                if inner and not (x in (x0, x1) or z in (z0, z1)):
                    put(x, yb, z, CHISEL_SPRUCE if RNG.random() < 0.6 else DARK_OAK,
                        building=True)
                    continue
                if inner:
                    put(x, yb, z, band_stone(), building=True)
                    continue
                corner = x in (x0 - 1, x1 + 1) and z in (z0 - 1, z1 + 1)
                if corner or k == storeys - 1 or RNG.random() < 0.3:
                    put(x, yb, z, band_stone(), building=True)
                    if corner:
                        put(x, yb + 1, z, TORCH, CROSS, building=True)
                else:
                    f = "xpos" if x < x0 else "xneg" if x > x1 else "zpos" if z < z0 else "zneg"
                    stairs(x, yb, z, "cobble", f, down=True)
        if k < storeys - 1:
            put(mid_x, yb, mid_z, GLOW, building=True)       # a light in the ceiling
    put(mid_x, F, mid_z, GLOW, building=True)
    # a flight of stairs up each storey along the wall opposite the door, its well left open
    run = (w if door in ("zneg", "zpos") else d) - 2
    back = {"zneg": z1 - 1, "zpos": z0 + 1, "xneg": x1 - 1, "xpos": x0 + 1}[door]
    if storeys > 1 and run >= STOREY:
        for k in range(storeys - 1):
            base = F + STOREY * k
            for i in range(STOREY):
                if door in ("zneg", "zpos"):
                    sx, sz, f = x0 + 1 + i, back, "xpos"
                else:
                    sx, sz, f = back, z0 + 1 + i, "zpos"
                for y in range(base + 1, base + 1 + i):
                    put(sx, y, sz, SPRUCE, building=True)
                stairs(sx, base + 1 + i, sz, "spruce", f)
                c = (sx, base + STOREY, sz)
                if i < STOREY - 1 and c in plan and plan[c][0] != AIR_N:
                    plan.pop(c)                               # the well in the floor above
                    part_of.pop(c, None)
    # in every storey a chest in a free inner corner, a table in the middle
    for k in range(storeys):
        base = F + STOREY * k
        for cx_, cz_ in ((x1 - 1, z1 - 1), (x0 + 1, z0 + 1), (x1 - 1, z0 + 1), (x0 + 1, z1 - 1)):
            c = (cx_, base + 1, cz_)
            if c not in plan or plan[c][0] == AIR_N:
                if (cx_ - OUT[door][0], cz_ - OUT[door][1]) not in doors:
                    put(*c, CHEST, CUBE, door, building=True)
                    break
        if (mid_x, base + 1, mid_z) not in plan or plan[(mid_x, base + 1, mid_z)][0] == AIR_N:
            put(mid_x, base + 1, mid_z, SLAB_SPRUCE, SLAB_TOP, building=True)
    # the door(s), a log lintel over them
    for (dx_, dz_) in doors:
        put(dx_, F + 1, dz_, (DOOR, DOOR_META[door]), PANEL, door, building=True)
        put(dx_, F + 2, dz_, (DOOR, 8), PANEL, door, building=True)
        put(dx_, F + 3, dz_, LOG_X if door in ("zneg", "zpos") else LOG_Z, building=True)
    ox, oz = OUT[door]
    out = (dcx + ox, dcz + oz)
    # the flare: dark oak stairs at the foot of the posts and pillars, but on the door's side
    for x in range(x0, x1 + 1):
        for z in range(z0, z1 + 1):
            if not (x in (x0, x1) or z in (z0, z1)):
                continue
            for side in SIDES:
                if not on_side(x, z, side) or side == door or not post_at(x, z, side):
                    continue
                ox_, oz_ = OUT[side]
                fx_, fz_ = x + ox_, z + oz_
                g = ground(fx_, fz_)
                if g is None or g > F or name(fx_, g, fz_) == WATER:
                    continue
                for y in range(max(g + 1, F - 2), F + 1):
                    put(fx_, y, fz_, stone(), building=True)
                stairs(fx_, F + 1, fz_, "dark_oak", OPP[side])
    # the roof
    if along_x:
        a0, a1, b0, b1 = x0, x1, z0, z1
    else:
        a0, a1, b0, b1 = z0, z1, x0, x1

    def at(a, b):
        """The x, z of a cell given along and across the ridge (the user, 2026-10-04: "more
        details")."""
        return (a, b) if along_x else (b, a)
    up_lo, up_hi = ("zpos", "zneg") if along_x else ("xpos", "xneg")
    ridge_b = b0 - 1 + rows
    woods, fulls = blue_woods(label, a1 - a0 + 3, 2 * rows + 1, rows)
    log_end = LOG_Z if along_x else LOG_X                     # its end toward the eaves
    lrng = random.Random(zlib.crc32((label + " logs").encode()))
    for r in range(rows):
        y = top + 1 + r
        for a in range(a0 - 1, a1 + 2):
            for b, up, sx in ((b0 - 1 + r, up_lo, r), (b1 + 1 - r, up_hi, 2 * rows - r)):
                c = (a - a0 + 1, sx)
                m = woods[c]
                plank = WOOD_PLANK[m]
                x, z = at(a, b)
                if c in fulls:                                # rare: rustic, not a perfect roof
                    put(x, y, z, log_end if lrng.random() < 0.2 else plank, building=True)
                else:
                    stairs(x, y, z, m, up)
                if r >= 1 and a0 <= a <= a1:                  # the under-layer
                    put(x, y - 1, z, CHISEL_SPRUCE if plank == SPRUCE else plank,
                        building=True)
    ry = top + 1 + rows
    for a in range(a0 - 1, a1 + 2):
        x, z = at(a, ridge_b)
        m = woods[(a - a0 + 1, rows)]
        plank = WOOD_PLANK[m]
        put(x, ry, z, plank, building=True)
        if a0 <= a <= a1:
            put(x, ry - 1, z, plank, building=True)
        if RNG.random() < 0.5:
            put(x, ry + 1, z, SLAB_DARK if m == "dark_oak" else SLAB_SPRUCE, SLAB,
                building=True)
    for a in (a0, a1):                                        # the gables
        for y in range(top + 1, ry):
            r = y - top - 1
            for b in range(b0 + r, b1 - r + 1):
                x, z = at(a, b)
                if (x, y, z) in plan and plan[(x, y, z)][0] not in (AIR_N,) and \
                        "stairs" in plan[(x, y, z)][0]:
                    continue
                if b == ridge_b:
                    put(x, y, z, LOG2, building=True)
                elif abs(b - ridge_b) == 1 and y in (top + 2, top + 3) and rows >= 4:
                    put(x, y, z, PANE_G, PANE, building=True)
                else:
                    put(x, y, z, wall_plank(), building=True)
    # dormers, a third and two thirds along each long side
    if dormers:
        for m_a in (a0 + (a1 - a0) // 3, a0 + 2 * (a1 - a0) // 3):
            for b_front, inward in ((b0, 1), (b1, -1)):
                for da in (-1, 0, 1):
                    a = m_a + da
                    for y in range(top + 1, top + 4):
                        x, z = at(a, b_front)
                        if da:
                            put(x, y, z, LOG2, building=True)
                        elif y < top + 3:
                            put(x, y, z, PANE_G, PANE, building=True)
                        else:
                            put(x, y, z, wall_plank(), building=True)
                        for db in (1, 2):
                            x, z = at(a, b_front + inward * db)
                            if da:
                                put(x, y, z, wall_plank(), building=True)
                            elif (x, y, z) in plan and name(x, y, z) == "":
                                plan.pop((x, y, z))           # the dormer's room, open
                                part_of.pop((x, y, z), None)
                    for db in (-1, 0, 1, 2):
                        x, z = at(a, b_front + inward * db)
                        m = ("dark_oak", "spruce")[(da + db) % 2]   # a dormer's own small mix
                        plank = WOOD_PLANK[m]
                        if da == 0:
                            put(x, top + 4, z, plank, building=True)
                            put(x, top + 5, z, SLAB_DARK, SLAB, building=True)
                        else:
                            up = ("xpos" if da < 0 else "xneg") if along_x else \
                                ("zpos" if da < 0 else "zneg")
                            stairs(x, top + 4, z, m, up)
    # the chimney, through a gable's overhang
    if chimney:
        cx, cz = {"xpos": (x1 + 1, mid_z), "xneg": (x0 - 1, mid_z), "zpos": (mid_x, z1 + 1),
                  "zneg": (mid_x, z0 - 1)}[chimney]
        g = ground(cx, cz)
        for y in range(max((g if g is not None else F - 1) + 1, F - 2), ry + 3):
            put(cx, y, cz, STONEBRICK if y >= ry + 1 else COBBLE, building=True)
        put(cx, ry + 3, cz, SLAB_STONE, SLAB, building=True)
    # the market front: an awning of striped wool, its valance, posts; a counter and goods
    if market:
        ox, oz = OUT[door]
        line = [(x, z) for x in range(x0, x1 + 1) for z in range(z0, z1 + 1)
                if on_side(x, z, door)]
        for x, z in line:
            i = along(x, z, door)
            wool = WOOL_ORANGE if i % 3 == 1 else WOOL
            put(x + ox, F + 4, z + oz, wool, building=True)
            put(x + 2 * ox, F + 4, z + 2 * oz, wool, building=True)
            put(x + 2 * ox, F + 3, z + 2 * oz, wool, building=True)
            if (x, z) not in (line[0], line[-1]) and not post_at(x, z, door):
                put(x - ox, F + 1, z - oz, LOG_X if door in ("zneg", "zpos") else LOG_Z,
                    building=True)                           # the counter
                goods = (CHEST, PUMPKIN, SLAB_SPRUCE)[i % 3]
                put(x - 2 * ox, F + 1, z - 2 * oz, goods,
                    SLAB_TOP if goods == SLAB_SPRUCE else CUBE, door, building=True)
        out = (line[len(line) // 2][0] + ox, line[len(line) // 2][1] + oz)
    if flag:
        x, z = at(a0 + 1, ridge_b)
        for y in range(ry + 1, ry + 4):
            put(x, y, z, FENCE_OAK, FENCE, building=True)
        ax_, az_ = at(1, 0)
        put(x + ax_, ry + 3, z + az_, WOOL_ORANGE, building=True)
        put(x + 2 * ax_, ry + 3, z + 2 * az_, WOOL_ORANGE, building=True)
        put(x + ax_, ry + 2, z + az_, WOOL, building=True)
    return F, out


# ---- the ground between the houses ---------------------------------------------------------------

# The user, 2026-10-04, on the second drawing: "The buildings look fine, what is not great is the
# walkable zone, there are potholes, there is little walkable area, random plants, can you make a
# plaza and figure how to make the roads more consistent, with the vegetation a bit more
# ordered?" So: a paved square round the marker; roads of one width and one paving, edged, with
# a stair at every change of height and never a step of more than one; every hole under and
# beside them filled; the loose plants cleared off them and their edges, and hedges, lavender
# beds and rows planted on purpose.
WALK = {}                       # (x, z) -> y of the walking surface's block (paving or stair)
STEPS = {}                      # (x, z) -> the way a stair in the walk rises
EDGE = {}                       # (x, z) -> what edges the walk there: "kerb", "bed", "hedge"
ROADS = []                      # (name, width, cells) for the summary
FILLED = Counter()              # what the fills took: "dirt", "stone", "grass", "capped"
SPRUCE_LEAVES = ("minecraft:leaves", 5)     # spruce, placed: it never decays (meta 1 | 4)
GRASS = ("minecraft:grass", 0)
DIRT = ("minecraft:dirt", 0)
SLAB_COBBLE = ("minecraft:stone_slab", 3)
PLANTS = ("tallgrass", "foliage", "double_plant", "flower", "BiomesOPlenty:plants",
          "red_flower", "yellow_flower")


def fill_under(x, z, t):
    """Fill a column from the ground up to y t - 1, so what stands at t stands on solid ground
    (the user, 2026-10-04: "there are potholes"): dirt for the top two, stone below; a hole
    deeper than eight - a sinkhole into the cave - gets its top three only, a cap held by the
    ground round it."""
    g = ground(x, z)
    lo = (g if g is not None else t - 4) + 1
    if lo < t - 8:
        lo = t - 3
        FILLED["capped"] += 1
    for y in range(lo, t):
        block = DIRT if y >= t - 2 else STONE
        if put(x, y, z, block, building=True):
            FILLED["dirt" if block == DIRT else "stone"] += 1
    for y in range(t - 1, t - 4, -1):                          # a thin roof over the cave:
        p = plan.get((x, y, z))                               # what is under t made solid
        n = name(x, y, z)
        if (p is not None and p[0] != AIR_N) or (p is None and n and n != WATER and
                                                  ((x, y, z) in GUESS or not soft(n))):
            break
        if (x, y, z) in KEPT or (x, y, z) in WET:
            break
        if put(x, y, z, DIRT, building=True):
            FILLED["dirt"] += 1


def clear_over(x, z, t, h=3):
    """The cells over a surface at t cleared, `h` of them: ground, plants (the user,
    2026-10-04: "random plants")."""
    for y in range(t + 1, t + 1 + h):
        clear(x, y, z, building=True)


def free_cell(x, z, t, up=4):
    """Whether a column may take ground works at height t: known ground, no water there, nothing
    kept at or over it, nothing planned standing over it - a house, a fence, the field - up to
    `up` over (the user's rules, 2026-10-04: existing water is never touched; and "Keep hidden
    ground")."""
    g = ground(x, z)
    if g is None or name(x, g, z) == WATER or (x, z) in WALK:
        return False
    for y in range(min(g, t) - 1, max(g, t) + up):
        if (x, y, z) in KEPT or (x, y, z) in WET:
            return False
        p = plan.get((x, y, z))
        if p is not None and p[0] != AIR_N and y > min(g, t) - 1:
            return False
    return True


def walkway(cells, heights, kind):
    """Cells into the walk at their heights (the user, 2026-10-04: "make the roads more
    consistent"); a cell already in it keeps its own."""
    for c, h in zip(cells, heights):
        if c not in WALK:
            WALK[c] = h
            EDGE.pop(c, None)
    ROADS.append((kind, cells))


def road(name_, rows, y0, y1=None, start_dir=None):
    """A road as rows across it, in order, from a start beside it at height y0 (the user,
    2026-10-04: "figure how to make the roads more consistent"): each row level across, its
    height the middle of its ground smoothed over five rows, never more than one from the row
    before - and given y1, ending there - so a hole is bridged and a bump cut. Where a row is one
    higher than the one before, its cells become stairs rising the way the road climbs; a row
    already walked (a junction) keeps its height."""
    gs = []
    for row in rows:
        v = sorted(g for g in (ground(*c) for c in row) if g is not None)
        gs.append(v[len(v) // 2] if v else None)
    fixed = [next((WALK[c] for c in row if c in WALK), None) for row in rows]
    h, prev = [], y0
    for i in range(len(rows)):
        near = sorted(v for v in gs[max(0, i - 2):i + 3] if v is not None)
        g = near[len(near) // 2] if near else prev
        v = fixed[i] if fixed[i] is not None else max(prev - 1, min(prev + 1, g))
        h.append(v)
        prev = v
    if y1 is not None:
        h[-1] = y1
        for i in range(len(h) - 2, -1, -1):
            if fixed[i] is None:
                h[i] = max(h[i + 1] - 1, min(h[i + 1] + 1, h[i]))
    cells, heights = [], []
    for i, row in enumerate(rows):
        for c in row:
            cells.append(c)
            heights.append(h[i])
    walkway(cells, heights, name_)

    def way(a, b):
        """The way from row a to row b, by their middles (the user, 2026-10-04: "roads")."""
        ax = sum(c[0] for c in a) / len(a)
        az = sum(c[1] for c in a) / len(a)
        bx = sum(c[0] for c in b) / len(b)
        bz = sum(c[1] for c in b) / len(b)
        if abs(bx - ax) >= abs(bz - az):
            return "xpos" if bx > ax else "xneg"
        return "zpos" if bz > az else "zneg"
    for i, row in enumerate(rows):
        before = h[i - 1] if i else y0
        if h[i] == before + 1:
            d = way(rows[i - 1], row) if i else start_dir
            for c in row:
                if d and WALK.get(c) == h[i] and c not in STEPS:
                    STEPS[c] = d
        if i and h[i] == h[i - 1] - 1:
            d = way(row, rows[i - 1])
            for c in rows[i - 1]:
                if WALK.get(c) == h[i - 1] and c not in STEPS:
                    STEPS[c] = d
    return h


def plaza(cells, level):
    """A paved square: its cells at the levels `level` gives, a stair wherever a cell is one
    above a neighbour on the square, rising away from it (the user, 2026-10-04: "can you make a
    plaza")."""
    hs = [level(c) for c in cells]
    walkway(cells, hs, "plaza")
    for (x, z) in cells:
        for d, (dx, dz) in OUT.items():
            n = (x - dx, z - dz)
            if n in WALK and WALK[n] == WALK[(x, z)] - 1 and (x, z) not in STEPS:
                STEPS[(x, z)] = d


def lay_paving():
    """The paving, one family laid as blue noise (the user, 2026-10-04: "make the roads more
    consistent"; as the roofs' woods, after "so make it chaotic enough that it dosent have a
    distinct pattern"): stone bricks, and among them cobblestone and gravel, never two of a kind
    side by side, an accent's odds cut for each accent beside it; gravel only where what is under
    it is solid. Stairs where the walk steps up. Under every cell the ground filled up, over it
    three cleared, and a window's shutter or sill at head height over it taken off."""
    rng = random.Random(zlib.crc32(b"paving"))
    cells = sorted(WALK)
    rng.shuffle(cells)
    kind = {}
    for c in cells:
        x, z = c
        near = [kind.get((x + dx, z + dz)) for dx, dz in OUT.values()]
        accents = sum(1 for k in near if k in ("cobble", "gravel"))
        p = 0.4 * 0.45 ** accents
        k = "brick"
        if rng.random() < p:
            k = "cobble" if rng.random() < 0.4 else "gravel"
            if k in near:
                k = "gravel" if k == "cobble" else "cobble"
                if k in near:
                    k = "brick"
        kind[c] = k
    PART[0] = "paving"
    for (x, z), t in sorted(WALK.items()):
        fill_under(x, z, t)
        if (x, z) in STEPS:
            stairs(x, t, z, "stonebrick", STEPS[(x, z)])
        else:
            k = kind[(x, z)]
            block = {"brick": STONEBRICK, "cobble": COBBLE, "gravel": GRAVEL}[k]
            if k == "gravel" and not under_ok(x, t, z):
                block = STONEBRICK
            put(x, t, z, block, building=True)
        clear_over(x, z, t)
        for y in (t + 1, t + 2):                              # no shutter or sill at head height
            p = plan.get((x, y, z))
            if p and (p[0] == TRAPDOOR[0] or (p[0].endswith("_stairs") and p[2] == STAIRS_DOWN)):
                plan.pop((x, y, z))
                part_of.pop((x, y, z), None)


def under_ok(x, y, z):
    """Whether what is under a cell holds gravel up: ground or a planned block, not air (the
    user, 2026-10-04: "a small path, you will use gravel and stone for that path")."""
    p = plan.get((x, y - 1, z))
    if p is not None:
        return p[0] != AIR_N
    n = name(x, y - 1, z)
    return bool(n) and n != WATER and not soft(n)


def edges(kinds, slab, lamps_every=0):
    """A kerb along the walk of the given kinds, one out on either side (the user, 2026-10-04:
    "make the roads more consistent"): the ground filled up to the walk's height and a slab on
    it; a fence instead over a drop of three or more (the gully), a lamp post every
    `lamps_every`; nothing where a bank stands higher than the slab, where another walk goes on,
    or where something is kept or planned."""
    k = 0
    for kind, cells in ROADS:
        if kind not in kinds:
            continue
        for (x, z) in cells:
            t = WALK[(x, z)]
            for dx, dz in OUT.values():
                n = (x + dx, z + dz)
                if n in WALK or n in EDGE or not free_cell(*n, t + 1):
                    continue
                g = ground(*n)
                if g > t + 1:
                    continue
                PART[0] = "edging"
                fill_under(n[0], n[1], t + 1)
                beyond = ground(n[0] + dx, n[1] + dz)
                drop = beyond is not None and beyond < t - 2
                k += 1
                if lamps_every and k % lamps_every == 0 and not drop:
                    lamp_at(n[0], t + 1, n[1])
                elif drop:
                    put(n[0], t + 1, n[1], FENCE_OAK, FENCE, building=True)
                else:
                    put(n[0], t + 1, n[1], slab, SLAB, building=True)
                clear_over(n[0], n[1], t + 1, 2)
                EDGE[n] = "kerb"


def lamp_at(x, y, z, h=2):
    """A lamp post from y up on the edge of a walk: oak fences, a torch on top (the user,
    2026-10-04: "you can also put torches alongside it")."""
    for k in range(h):
        put(x, y + k, z, FENCE_OAK, FENCE, building=True)
    put(x, y + h, z, TORCH, CROSS, building=True)


def hedges(kinds, budget):
    """Hedges of spruce leaves two out from the walk, beyond the kerb, in runs (the user,
    2026-10-04: "with the vegetation a bit more ordered"; spruce leaves, placed, do not decay):
    on grass level with the walk or one off, up to `budget` blocks (the mini ME has 64)."""
    used = 0
    for kind, cells in ROADS:
        if kind not in kinds:
            continue
        for i, (x, z) in enumerate(cells):
            if used >= budget:
                return used
            t = WALK[(x, z)]
            for dx, dz in OUT.values():
                n1, n2 = (x + dx, z + dz), (x + 2 * dx, z + 2 * dz)
                if EDGE.get(n1) != "kerb" or n2 in WALK or n2 in EDGE:
                    continue
                g = ground(*n2)
                if g is None or abs(g - t) > 1 or not free_cell(*n2, g + 1):
                    continue
                if name(n2[0], g, n2[1]) not in ("minecraft:grass", "minecraft:dirt"):
                    continue
                if (n2[0] + n2[1]) % 4 == 0:
                    continue                                  # a gap now and then
                PART[0] = "hedges"
                clear_over(n2[0], n2[1], g, 2)
                if put(n2[0], g + 1, n2[1], SPRUCE_LEAVES, building=True):
                    EDGE[n2] = "hedge"
                    used += 1
    return used


def bed_cells(zone):
    """The cells of a bed zone a lavender may go in, in order (the user, 2026-10-04: "with the
    vegetation a bit more ordered"): not walked or edged, and not where a lavender grows
    already - that one stays, as it is, part of the bed."""
    out = []
    for c in zone:
        g = ground(*c)
        if c in WALK or c in EDGE or g is None or lavender(c[0], g + 1, c[1]):
            continue
        out.append(c)
    return out


def plant_bed(cells, level=None, limit=10 ** 6):
    """Lavender planted in a bed (the user's rule, 2026-10-04: lavender stays but under buildings;
    every one taken is planted again, now in beds): each cell's ground filled or cut to `level`
    (or left at its own), grass on top, the lavender on that; `limit` at most. Returns how many
    went in."""
    n = 0
    for (x, z) in cells:
        g = ground(x, z)
        if g is None or n >= limit:
            continue
        t = level((x, z)) if level else g
        if not free_cell(x, z, t + 1, up=2) or abs(t - g) > 3:
            continue
        PART[0] = "beds"
        fill_under(x, z, t)
        if g > t:
            for y in range(t + 1, g + 1):
                clear(x, y, z, building=True)
        if name(x, t, z) != "minecraft:grass" or (x, t, z) in plan:
            if put(x, t, z, GRASS, building=True):
                FILLED["grass"] += 1
        clear_over(x, z, t, 2)
        if put(x, t + 1, z, LAVENDER, CROSS, building=True):
            EDGE[(x, z)] = "bed"
            n += 1
    return n


def tidy(radius=2):
    """Round the walk, out to `radius`: the loose plants cleared - tall grass, ferns, flowers, the
    lavender among them, taken to the beds - and every hole filled: a cell lower than all four
    of its neighbours is brought up to the lowest of them, dirt topped with grass (the user,
    2026-10-04: "there are potholes ... random plants"). Not in the field, a house, water or what
    is kept."""
    PART[0] = "tidying"
    near = {(x + dx, z + dz) for (x, z) in WALK for dx in range(-radius, radius + 1)
            for dz in range(-radius, radius + 1)}
    for (x, z) in sorted(near):
        g = ground(x, z)
        if g is None or (x, z) in WALK:
            continue
        for y in (g + 1, g + 2):
            n = name(x, y, z)
            if n and any(p in n for p in PLANTS) and (x, y, z) not in plan:
                clear(x, y, z, building=True)

    def surface(c):
        """The top a column will have: the walk's, an edge's, else its ground's."""
        if c in WALK:
            return WALK[c]
        g = ground(*c)
        top = g
        if g is not None:
            for y in range(g + 1, g + 4):
                p = plan.get((c[0], y, c[1]))
                if p and p[0] in (DIRT[0], GRASS[0], STONE[0]):
                    top = y
        return top
    for _ in range(3):
        for (x, z) in sorted(near):
            if (x, z) in WALK or (x, z) in EDGE:
                continue
            s = surface((x, z))
            ns = [surface((x + dx, z + dz)) for dx, dz in OUT.values()]
            if s is None or any(v is None for v in ns) or s >= min(ns):
                continue
            t = min(ns)
            if not free_cell(x, z, t) or name(x, ground(x, z), z) == WATER:
                continue
            fill_under(x, z, t)
            if put(x, t, z, GRASS, building=True):
                FILLED["grass"] += 1
            clear_over(x, z, t, 2)


# ---- the plaza, the well, the roads --------------------------------------------------------------

WELL = (-9, 33)                 # on the user's blue marker
PLAZA = [(x, z) for x in range(-14, -4) for z in range(31, 41)]     # 10 x 10, x -14..-5
MARKET = [(x, z) for x in range(0, 7) for z in range(31, 34)] + [(x, 34) for x in range(1, 7)]


def plaza_level(c):
    """The square's two terraces (the user, 2026-10-04: "can you make a plaza"): y 3 north of
    z 36, y 4 from there to the hall's door; the row between is the stair."""
    return 3 if c[1] <= 35 else 4


def well():
    """The well in the square's north half, on the user's blue marker (2026-10-04: "around the
    center of the proposed area"): a water source level with the paving, stone under it, a rim of
    mixed stone round it, oak posts at its corners, a spruce slab roof; benches of spruce stairs
    either side, their backs to the edges."""
    PART[0] = "plaza"
    wx, wz = WELL
    L = WALK[WELL]
    for dx in (-1, 0, 1):
        for dz in (-1, 0, 1):
            x, z = wx + dx, wz + dz
            if (dx, dz) == (0, 0):
                put(x, L - 1, z, STONE, building=True)
                put(x, L, z, WATER_B, building=True)
                continue
            put(x, L + 1, z, stone() if dx and dz else SLAB_STONE,
                CUBE if dx and dz else SLAB, building=True)
            if dx and dz:
                put(x, L + 2, z, FENCE_OAK, FENCE, building=True)
                put(x, L + 3, z, FENCE_OAK, FENCE, building=True)
            put(x, L + 4, z, SLAB_SPRUCE, SLAB, building=True)
    put(wx, L + 4, wz, SPRUCE, building=True)
    put(wx, L + 5, wz, SLAB_SPRUCE, SLAB, building=True)
    for x, f in ((wx - 3, "xneg"), (wx + 3, "xpos")):
        for z in (wz - 1, wz + 1):
            stairs(x, WALK[(x, z)] + 1, z, "spruce", f)


def ground_works(houses, mill_F):
    """The plaza, the roads and the beds, in order (the user, 2026-10-04: "can you make a plaza
    and figure how to make the roads more consistent, with the vegetation a bit more ordered?").

      - the plaza: x -14..-5, z 31..40, in two terraces, the hall's door on its south edge, the
        well on the marker; the market square before the market hall's open front, x 0..6, z
        31..34, at the hall's floor, a stair down to it from the plaza;
      - the main lane, three wide, from the fisher's gravel path to the plaza's north-west - but
        two between house E and the cabin (z 3..9), all the room there is - with cobble slab
        kerbs and lamp posts;
      - side paths two wide, smooth stone kerbs: to houses A and C, the mill, the field's gate.
    Returns the market square's front cells."""
    PART[0] = "plaza"
    plaza(PLAZA, plaza_level)
    plaza(MARKET, lambda c: houses["D"][0])
    # the main lane: rows across it, north to south
    rows = [[(-12, z), (-11, z)] for z in range(3, 10)]
    rows += [[(-12, z), (-11, z), (-10, z)] for z in range(10, 14)]
    rows += [[(-16, 14), (-15, 14), (-12, 14), (-11, 14), (-10, 14)]]   # by house E's flares
    rows += [[(x, 15) for x in range(-16, -9)]]
    rows += [[(x, z) for x in range(-15, -12)] for z in (16, 17)]
    rows += [[(x, 18) for x in range(-17, -13)]]
    rows += [[(x, z) for x in range(-17, -14)] for z in range(19, 24)]
    rows += [[(x, 24) for x in range(-17, -13)]]               # the bend past the cobblestone,
    rows += [[(x, 25) for x in range(-16, -10)]]               # two rows deep
    rows += [[(x, 26) for x in range(-15, -10)]]
    rows += [[(x, z) for x in range(-13, -10)] for z in range(27, 31)]
    PART[0] = "lane"
    road("lane", rows, -1, plaza_level((-12, 31)), start_dir="zpos")
    # side paths, two wide
    PART[0] = "paths"
    road("gate", [[(-17, 15), (-17, 16)], [(-18, 15), (-18, 16)]], WALK[(-16, 15)])
    road("mill", [[(-24, 31), (-23, 31)], [(-24, 32), (-23, 32)],
                  [(-24, 33), (-23, 33), (-24, 34), (-23, 34)]] +
         [[(x, 33), (x, 34)] for x in range(-22, -14)], mill_F, plaza_level((-14, 33)))
    FA, _ = houses["A"]
    road("house A", [[(x, 38), (x, 39)] for x in (-15, -16)] +
         [[(-17, 38), (-17, 39)]] + [[(-17, z), (-16, z)] for z in range(40, 46)],
         plaza_level((-14, 38)), FA)
    FC, _ = houses["C"]
    road("house C", [[(-4, z), (-3, z)] for z in range(37, 41)], plaza_level((-5, 37)), FC)
    road("market", [[(x, 31), (x, 32)] for x in range(-4, 0)], plaza_level((-5, 31)),
         houses["D"][0])
    lay_paving()
    well()
    edges(("lane",), SLAB_COBBLE, lamps_every=9)
    edges(("gate", "mill", "house A", "house C", "market"), SLAB_SMOOTH, lamps_every=11)
    return [c for c in MARKET if c[1] == 31]


HOUSE_BOXES = {"A": (-26, 40, 9, 11), "B": (-14, 41, 9, 9), "C": (-2, 36, 9, 9),
               "D": (-1, 24, 8, 7), "E": (-17, 8, 5, 6)}       # x0, z0, w, d


def beds(need):
    """The lavender taken, planted again in beds (the user, 2026-10-04: "with the vegetation a
    bit more ordered"; the user's rule: lavender stays but under buildings): first a border round
    the plaza, level with it; then borders round the houses, one out from their walls between
    the flaring stairs; then garden beds three wide - west of the field, south of it, north of
    it, south of the mill, west of the inn, behind the inn and the hall, by the gully's end, on
    the meadow north of the market hall. Returns how many went in."""
    ring = sorted({(x + dx, z + dz) for (x, z) in PLAZA for dx, dz in OUT.values()} -
                  set(PLAZA), key=lambda c: (c[1], c[0]))
    lv = {c: WALK.get(next(((c[0] - dx, c[1] - dz) for dx, dz in OUT.values()
                            if (c[0] - dx, c[1] - dz) in PLAZA), None), None) for c in ring}
    borders = []
    for x0, z0, w, d in HOUSE_BOXES.values():
        borders += [(x, z) for x in range(x0 - 1, x0 + w + 1) for z in range(z0 - 1, z0 + d + 1)
                    if x in (x0 - 1, x0 + w) or z in (z0 - 1, z0 + d)]

    def box(x0, x1, z0, z1):
        """A garden bed's cells."""
        return [(x, z) for z in range(z0, z1 + 1) for x in range(x0, x1 + 1)]
    zones = [(bed_cells(ring), lambda c: lv[c]), (bed_cells(borders), None),
             (bed_cells(box(-6, -4, 27, 29)), None),
             (bed_cells(box(-31, -29, 11, 25)), None),
             (bed_cells(box(-27, -23, 26, 27)), None),
             (bed_cells(box(-27, -20, 8, 9)), None),
             (bed_cells(box(-31, -25, 37, 38)), None),
             (bed_cells(box(-30, -28, 40, 50)), None),
             (bed_cells(box(-2, 1, 14, 22)), None),
             (bed_cells(box(-31, -29, 26, 27)), None),
             (bed_cells(box(-27, -20, 7, 7)), None),
             (bed_cells(box(-14, -6, 51, 52)), None),
             (bed_cells(box(-26, -18, 52, 53)), None),
             (bed_cells(box(-10, -7, 28, 29)), None),
             (bed_cells(box(2, 5, 14, 22)), None)]
    planted = 0
    for cells, level in zones:
        if planted >= need:
            break
        planted += plant_bed(cells, level, need - planted)
    return planted


# ---- the parts, placed ---------------------------------------------------------------------------

def village():
    """Everything, in an order that lets the buildings take their ground first, then the plaza and
    the roads run up to their doors, then the edges are tidied and planted (the user,
    2026-10-04: "can we see more thematic houses around that area? maybe add a field of wheat
    ... also build a windmill in that area", and then: "can you make a plaza and figure how to
    make the roads more consistent, with the vegetation a bit more ordered?")."""
    field()
    F, base_top, body_top, hub_y = windmill()
    houses = {}
    # A, the inn, west of the plaza on the plateau's foot: two storeys, a chimney
    houses["A"] = house("house A", -26, 40, 9, 11, "xpos", storeys=2, chimney="zpos")
    # B, the hall, on the plaza's south edge: two storeys, a double door, a flag
    houses["B"] = house("house B", -14, 41, 9, 9, "zneg", storeys=2, double=True,
                        chimney="xpos", flag=True)
    # C, east of the plaza on the lavender meadow, clear of the hive's tree: one storey under a
    # tall roof with dormers
    houses["C"] = house("house C", -2, 36, 9, 9, "xneg", storeys=1, dormers=True)
    # D, the market hall, north-east over the gully's end: its front open to the market square
    houses["D"] = house("house D", -1, 24, 8, 7, "zpos", storeys=1, market=True)
    # E, by the lane north: narrow, two storeys
    houses["E"] = house("house E", -17, 8, 5, 6, "xpos", storeys=2, F=2)
    market = ground_works(houses, F)
    houses["D"] = (houses["D"][0], market[len(market) // 2])
    hedge_n = hedges(("lane", "mill", "house A", "house C", "gate"), 60)
    tidy()
    return houses, (F, base_top, body_top, hub_y), hedge_n


# ---- checks --------------------------------------------------------------------------------------

def solid_after(c):
    """Whether a cell holds something solid once the plan is built: a planned block, or ground
    the plan leaves (not air, water, a plant). For checks() (the user, 2026-10-04, after the
    first builders: "what did you do to get so many bugs?")."""
    p = plan.get(c)
    if p is not None:
        return p[0] not in (AIR_N, WATER) and p[2] not in (CROSS,)
    n = name(*c)
    if c in GUESS:                  # read by hardness: solid, whatever name the guess got
        return bool(n) and n != WATER
    return bool(n) and n != WATER and not soft(n)


def checks():
    """What could go wrong in the world, counted: a planned water source not held on all four
    sides and below; farmland with no water within 4 across, level with it or one above
    (vanilla's BlockFarmland: dry, it turns back to dirt); a cell opened beside existing water;
    a block with nothing at all beside it (a builder could not click it on and it would hang);
    a planned cell in a kept one. (The user, 2026-10-04: "make sure you don't break".)"""
    out = Counter()
    for c, p in plan.items():
        x, y, z = c
        if p[0] == WATER:
            for n in ((x + 1, y, z), (x - 1, y, z), (x, y, z + 1), (x, y, z - 1), (x, y - 1, z)):
                if not solid_after(n):
                    out[f"water at {c} not held at {n}"] += 1
        if p[0] == FARMLAND[0] and not any(
                plan.get((x + dx, y + dy, z + dz), (AIR_N,))[0] == WATER
                for dx in range(-4, 5) for dz in range(-4, 5) for dy in (0, 1)):
            out[f"farmland at {c} dry"] += 1
        if p[0] == AIR_N and by_water(*c):
            out["opened beside water"] += 1
        if c in KEPT:
            out["in a kept cell"] += 1
        if p[0] != AIR_N:
            nb = [(x + 1, y, z), (x - 1, y, z), (x, y + 1, z), (x, y - 1, z), (x, y, z + 1),
                  (x, y, z - 1)]
            if not any(solid_after(n) or (n in plan and plan[n][0] not in (AIR_N,))
                       for n in nb):
                out[f"floating at {c}"] += 1
    return out


def walk_checks(doors):
    """The walk checked (the user, 2026-10-04: "there are potholes, there is little walkable
    area"): every walk cell on something solid; no hole - a cell lower than its four
    neighbours - within two of the walk; and from every door a way two wide to the plaza, a
    step of one at most, two clear over every cell. Returns the counts and, by door, whether
    it is reached."""
    out = Counter()
    for (x, z), t in WALK.items():
        if plan.get((x, t, z), (AIR_N,))[0] == WATER:
            continue
        if not solid_after((x, t - 1, z)) or not solid_after((x, t, z)):
            out["walk on air"] += 1

    def top(c):
        """A column's top once built."""
        if c in WALK:
            return WALK[c]
        g = ground(*c)
        if g is None:
            return None
        ys = [y for y in range(g - 8, g + 4) if plan.get((c[0], y, c[1]), (AIR_N,))[0]
              in (DIRT[0], GRASS[0], STONE[0], STONEBRICK[0], COBBLE[0])]
        dug = [y for y in range(g - 8, g + 1) if plan.get((c[0], y, c[1]), (AIR_N,))[0] == AIR_N]
        t = max(ys + [g])
        while t in dug:
            t -= 1
        return t
    near = {(x + dx, z + dz) for (x, z) in WALK for dx in range(-2, 3) for dz in range(-2, 3)}
    for c in near:
        if c in WALK or c in EDGE:
            continue
        s, ns = top(c), [top((c[0] + dx, c[1] + dz)) for dx, dz in OUT.values()]
        if s is not None and all(v is not None and v > s for v in ns) and free_cell(*c, s):
            out["hole by the walk"] += 1

    def clear_at(c):
        """Two clear over a walk cell."""
        t = WALK[c]
        return all(plan.get((c[0], y, c[1]), (AIR_N,))[0] == AIR_N and
                   (not name(c[0], y, c[1]) or (c[0], y, c[1]) in plan
                    or soft(name(c[0], y, c[1]))) for y in (t + 1, t + 2))
    ok = {c for c in WALK if clear_at(c)}
    wide = set()
    for (x, z) in ok:
        for ax, az in ((0, 0), (-1, 0), (0, -1), (-1, -1)):
            sq = [(x + ax + i, z + az + j) for i in (0, 1) for j in (0, 1)]
            if all(q in ok for q in sq) and max(WALK[q] for q in sq) - \
                    min(WALK[q] for q in sq) <= 1:
                wide.update(sq)
    seen = {c for c in PLAZA if c in wide}
    todo = list(seen)
    while todo:
        x, z = todo.pop()
        for dx, dz in OUT.values():
            n = (x + dx, z + dz)
            if n in wide and n not in seen and abs(WALK[n] - WALK[(x, z)]) <= 1:
                seen.add(n)
                todo.append(n)
    return out, {k: c in seen for k, c in doors.items()}


def extent(label):
    """The box a part's planned blocks fill, its digging left out: for the summary the user
    reads (2026-10-04: "so I will wait for the proposal")."""
    cs = [c for c, p in plan.items() if part_of[c] == label and p[0] != AIR_N]
    if not cs:
        return "nothing"
    xs, ys, zs = zip(*cs)
    return (f"x {min(xs)}..{max(xs)} z {min(zs)}..{max(zs)} y {min(ys)}..{max(ys)}, "
            f"{len(cs)} blocks")


# ---- out -----------------------------------------------------------------------------------------

def plant_ground(n):
    """Dirt, sand or farmland, a plant's ground in a design (a mod's dirt or grass counts as its
    kind; sand is sand only, not sandstone) - as 3d-draw's orient.design_ground."""
    if not n or any(s in n for s in PLANTS):
        return False
    return "dirt" in n or "grass" in n or "farmland" in n or n == "minecraft:sand"



def plants_on_ground():
    """Every plant planned stands on dirt, sand or farmland - a grass block is dirt grown over -
    as the plan leaves the cell under it, else as the world has it (the user, 2026-10-06:
    "plants need to stay on dirt, sand or farmland, note that this needs to be checked in further
    planners"). One that does not is taken out of the plan, counted in `refused`: a bed's
    lavender at -19 8 51 went over a lavender the scouts had named grass. Run last, so no part
    planned after the plant can change the cell under it unseen. -> how many taken out."""
    out = 0
    for c, p in list(plan.items()):
        if not any(s in p[0] for s in PLANTS + ("wheat", "sapling")):
            continue
        under = (c[0], c[1] - 1, c[2])
        n = plan[under][0] if under in plan else name(*under)
        if not plant_ground(n):
            del plan[c]
            refused[f"a plant not on dirt, sand or farmland ({n or 'unknown'} under it)"] += 1
            out += 1
    return out


houses, mill, hedge_n = village()
need = len(moved_lavender)
planted = beds(need)
plants_on_ground()                      # counted in `refused`, printed with it
problems = checks()
doors = {k: v[1] for k, v in houses.items()}
doors.update({"B 2": (-11, 40), "mill": (WX + 4, WZ), "field gate": (FIELD_GATE[0] + 1,
                                                                     FIELD_GATE[1])})
walk_problems, reached = walk_checks(doors)

with open(os.path.join(DATA, "village.txt"), "w", newline="\n") as f:
    f.write("# 3d-draw village (design/village.py): b x y z name meta shape facing\n")
    for (x, y, z), (n, m, s, fc) in sorted(plan.items(), key=lambda kv: (kv[0][1], kv[0])):
        f.write(f"b {x} {y} {z} {n} {m} {s} {fc}\n")


blocks = sum(1 for p in plan.values() if p[0] != AIR_N)
dug = sum(1 for p in plan.values() if p[0] == AIR_N)
print(f"village: {len(plan)} cells ({blocks} blocks, {dug} dug out) -> data/village.txt")
for label in ("field", "windmill", "house A", "house B", "house C", "house D", "house E",
              "plaza", "lane", "paths", "paving", "edging", "hedges", "tidying", "beds"):
    print(f"  {label:10} {extent(label)}")
farm = sum(1 for p in plan.values() if p[0] == FARMLAND[0])
crop = sum(1 for p in plan.values() if p[0] == WHEAT[0])
water = [c for c, p in plan.items() if p[0] == WATER]
print(f"  field: {farm} farmland, {crop} wheat; water placed at {water}")
print(f"  windmill: floor y {mill[0]}, shoulder y {mill[1]}, body top y {mill[2]}, "
      f"hub y {mill[3]}")
print(f"  house floors: " + ", ".join(f"{k} y {v[0]} door out {v[1]}" for k, v in
                                        sorted(houses.items())))
print(f"  lavender taken: {need} (" + ", ".join(f"{k} {n}" for k, n in moved_by.most_common())
      + f"), planted again in beds: {planted}")
print("  not planned:", ", ".join(f"{n} {k}" for k, n in refused.most_common()) or "nothing")
print("  checks:", ", ".join(f"{n} {k}" for k, n in problems.most_common()) or "all clear")
print("  walk:", ", ".join(f"{n} {k}" for k, n in walk_problems.most_common()) or "all clear",
      "| reached two wide from the plaza:", ", ".join(f"{k} {'yes' if v else 'NO'}"
                                                      for k, v in reached.items()))
for kind, cells in ROADS:
    print(f"  road {kind:8}: {len(cells)} cells")
print(f"  fills: {dict(FILLED)}; hedges {hedge_n} spruce leaves; kerbs "
      f"{sum(1 for v in EDGE.values() if v == 'kerb')}; beds {planted} lavender")
for label, biggest, like, nfull, ncells in ROOF_STATS:
    print(f"  roof {label:9}: {ncells} cells, largest one-wood patch {biggest}, like neighbours "
          f"{like:.0%}, full blocks {nfull} ({nfull / ncells:.0%})")
bill = Counter((p[0], p[1]) for p in plan.values() if p[0] != AIR_N)
for (n, m), k in bill.most_common():
    print(f"   {k:4} {n}:{m}")
