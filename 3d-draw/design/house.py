"""house.py - the proposal: a poor fisher's cabin on a deck by the river (3d-draw/DESIGN.md).

    python 3d-draw/design/house.py

Reads the robot's map (data/map.txt) for the ground and the water, writes the plan to
data/house.txt - one block per line, `b x y z name meta shape facing`, in the robot's coordinates
and with the simulator's cell shapes; scenes/draw3d shows it with H and reloads it when it changes
- and prints the bill of materials against what the mini ME holds (data/me.txt), and what of the
terrain the plan takes the place of.

The brief (the user, 2026-10-04): a middle-ages fisher's house on the riverside, built on a 5x5
grid, of the mini ME's blocks and what can be crafted from them. Then, on seeing the first
versions: "too little depth to the walls and too tall for a poor fisher's house, also too closed",
with three pictures of fishing cabins to take after - low, on decks over the water, open porches
and pergolas, posts and frames standing proud of the walls, shutters, lamps on posts, a stone
roof on one of them.

THE RIVER goes on past the contour - "like 20 more blocks of river", the user said, "so you can
use 7-8 more" (2026-10-04) - so the pier reaches 8 blocks past the contour's east side. That water
is not all on the robot's map yet: stilts there go 3 below the deck, and the real riverbed decides
when it is built.

THE STATION (the robot's charger, the mini ME, its computer; x 1..4, z -1..4, and GregTech blocks
under the water to x 6) is used a lot from here on, so the house keeps off it: the user, 2026-10-04,
"make the deck closer to the water, make place for the station ... move the hause, mostly as it is,
3-4 blocks the the right". The deck went one lower and four west, which is what clears it; the
contour's east line (x 0, where the robot docks) stays free too. `put` refuses those places, the
user's contour blocks and the walkway wall, so no later change can build into them by accident.

THE GRID: 5x5 modules sharing their walls, so their edges fall every 4 blocks; four of them make
the 9x9 deck. Grid points carry the stilts and posts.
  - the deck: spruce planks just above the water on spruce stilts, fence railings, lamp posts;
  - the cabin (the south-west module, over the water): plank walls 2 high between log corner posts
    and a log top plate, a window with open trapdoor shutters and a sill on each closed side, the
    river side open over a work counter, a low stone-brick roof with spruce trim at the gables,
    a cobblestone chimney outside;
  - the pergola (the north-east module): log posts and beams, spruce slab slats, a fish-cleaning
    table under it;
  - the yard (north-west): a drying rack and a firewood stack;
  - the jetty (south-east): open deck, a bench, a mooring gap;
  - the path: gravel and stone, two wide, west from the deck, round to the barn and the yard;
  - the pier: two wide, east into the river past the station, railings, lamps, a hoist;
  - the barn: two modules north of the yard across a lane, its west end at the pillars.
Terrain in the way (dirt, grass, the tree) is dug out: `air` lines in the plan.
"""
import os, random, re
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(os.path.dirname(HERE), "data")

# ---- the terrain ------------------------------------------------------------------------------

_lines = open(os.path.join(DATA, "map.txt")).read().splitlines()
XMIN, XMAX, YMIN, YMAX, ZMIN, ZMAX = map(int, re.findall(r"-?\d+", _lines[1]))
NAMES, LAYERS, GUESSED = {}, {}, {}
for _line in _lines:
    if _line.startswith("palette"):
        _, _i, _name, _meta, *_ = _line.split()
        NAMES[int(_i)] = (_name, int(_meta))
    elif _line.startswith("layer"):
        _, _y, _data = _line.split(" ", 2)
        LAYERS[int(_y)] = [list(map(int, r.split(","))) for r in _data.split(";")]
    elif _line.startswith("guessed"):
        _, _y, _data = _line.split(" ", 2)
        GUESSED[int(_y)] = [list(map(int, r.split(","))) for r in _data.split(";")]

PLANTS = {"BiomesOPlenty:flowers2", "minecraft:torch", "minecraft:web", "BiomesOPlenty:leaves4",
          "BiomesOPlenty:logs4"}


def cell(x, y, z):
    """The map's block at a position: (name, meta), None for air, False outside the map."""
    if not (XMIN <= x <= XMAX and ZMIN <= z <= ZMAX and YMIN <= y <= YMAX):
        return False
    v = LAYERS[y][z - ZMIN][x - XMIN]
    return False if v < 0 else None if v == 0 else NAMES[v]


def guessed(x, y, z):
    """Whether the robot only guessed this cell from its hardness (it could not name it): a
    guessed antiBlock is a tree trunk as hard as one, not the user's contour."""
    return y in GUESSED and bool(GUESSED[y][z - ZMIN][x - XMIN])


def ground(x, z, below=4):
    """The top of the ground or the water in a column, under the raised walkway (y 5 and up).
    The user's contour blocks are not ground: they are taken away before the build."""
    for y in range(min(YMAX, below), YMIN - 1, -1):
        c = cell(x, y, z)
        if c is False:
            return None
        if c and (c[0] not in PLANTS or guessed(x, y, z)) \
                and not (c[0] == "chisel:antiBlock" and not guessed(x, y, z)):
            return y                      # a guess is ground: leaves by hardness are soil
    return YMIN


def bed(x, z):
    """The top of what is under the water in a column, or of the ground where there is none."""
    g = ground(x, z)
    if g is None:
        return None
    y = g
    while y > YMIN and cell(x, y, z) and cell(x, y, z)[0] == "minecraft:water":
        y -= 1
    return y


# ---- the plan and its parts -------------------------------------------------------------------

plan = {}       # (x, y, z) -> (name, meta, shape, facing)
refused = Counter()     # what `put` would not build, by reason
CUBE, CROSS, SLAB, SLAB_TOP, STAIRS, STAIRS_DOWN = 0, 1, 3, 4, 5, 6
FENCE, PANE, GATE, PANEL = 7, 8, 9, 12

STONEBRICK = ("minecraft:stonebrick", 0)
COBBLE = ("minecraft:cobblestone", 0)
SPRUCE = ("minecraft:planks", 1)
DARK_OAK = ("minecraft:planks", 5)
LOG_UP, LOG_X, LOG_Z = ("minecraft:log", 1), ("minecraft:log", 5), ("minecraft:log", 9)
GLASS = ("minecraft:glass_pane", 0)
# Fences: spruce, ExtraTrees' (GTNH's fence recipe makes one from spruce planks); the
# pergola's oak, as the user chose it (2026-10-04: "spruce fences are fine except the
# pergola"). A spruce gate is MalisisDoors'.
FENCE_S = ("ExtraTrees:fence", 1)
FENCE_OAK = ("minecraft:fence", 0)
GATE_S = ("malisisdoors:spruceFenceGate", 0)
# Shutters: MalisisDoors' spruce trapdoor, which GTNH's trapdoor recipe makes from spruce slabs;
# meta 4: open.
TRAPDOOR = ("malisisdoors:trapdoor_spruce", 4)
TORCH = ("minecraft:torch", 5)
GRAVEL, STONE = ("minecraft:gravel", 0), ("minecraft:stone", 0)
STAIR = {"spruce": "minecraft:spruce_stairs", "dark_oak": "minecraft:dark_oak_stairs",
         "stonebrick": "minecraft:stone_brick_stairs", "cobble": "minecraft:stone_stairs"}
OPPOSITE = {"xpos": "xneg", "xneg": "xpos", "zpos": "zneg", "zneg": "zpos"}
STEP = {"xpos": (1, 0), "xneg": (-1, 0), "zpos": (0, 1), "zneg": (0, -1)}


AIR = ("minecraft:air", 0)
CONTOUR = "chisel:antiBlock"
WALL = {"Ztones:tile.korpBlock", "chisel:stonebricksmooth", "ArchitectureCraft:shape"}


def keep_out(x, y, z):
    """Why nothing may go at x, y, z, or None. The station's columns; under the water to x 6,
    where its GregTech blocks stand; the robot's way along the contour's east line to its dock
    (x 0, the deck's level and up); the walkway wall. The contour blocks themselves are not kept:
    the user had them taken away before the build (2026-10-04, "also remove the contour blocks"),
    so the pier's planks and the cabin's south sill go where some of them stood."""
    if 1 <= x <= 4 and -1 <= z <= 4:
        return "station"
    if 1 <= x <= 6 and -3 <= z <= 5 and y < -1:
        return "station, under the water"
    if x == 0 and y >= 0:
        return "the robot's dock line (x 0)"
    c = cell(x, y, z)
    if c and c[0] in WALL:
        return "the walkway wall"
    return None


def put(x, y, z, block, shape=CUBE, facing="-"):
    why = keep_out(x, y, z)
    if why:
        refused[why] += 1
        return
    plan[(x, y, z)] = (block[0], block[1], shape, facing)


def dig(x0, x1, y0, y1, z0, z1):
    """Plans the terrain out of a box: what is there and not built over becomes air."""
    for x in range(x0, x1 + 1):
        for z in range(z0, z1 + 1):
            for y in range(y0, y1 + 1):
                c = cell(x, y, z)
                if c and c[0] != "minecraft:water" and (x, y, z) not in plan:
                    put(x, y, z, AIR)


def stairs(x, y, z, material, facing, upside_down=False):
    """Stairs rising toward `facing`; upside down, the step hangs under the facing side."""
    put(x, y, z, (STAIR[material], 0), STAIRS_DOWN if upside_down else STAIRS, facing)


def stilt(x, z, top):
    """A spruce log from the riverbed (or the ground) up to just under `top`."""
    b = bed(x, z)
    for y in range((b if b is not None else top - 3) + 1, top):
        put(x, y, z, LOG_UP)


def lamp_post(x, y, z, height=2):
    """A fence post `height` high from y with a torch on top: the cabins' lanterns."""
    for k in range(height):
        put(x, y + k, z, FENCE_S, FENCE)
    put(x, y + height, z, TORCH, CROSS)


def shuttered_window(x, y, z, out, sill=True):
    """A pane in the wall at x, y, z; open trapdoor shutters on the wall either side of it,
    outside; a sill of an upside-down stair under it, standing out (not over a path: it would be
    in the way at the height one walks). `out` is the wall's outward facing."""
    put(x, y, z, GLASS, PANE)
    dx, dz = STEP[out]
    ax, az = (0, 1) if dx else (1, 0)                 # along the wall
    for s in (-1, 1):
        put(x + dx + ax * s, y, z + dz + az * s, TRAPDOOR, PANEL, OPPOSITE[out])
    if sill:
        stairs(x + dx, y - 1, z + dz, "spruce", OPPOSITE[out], upside_down=True)


# ---- where: the grid ------------------------------------------------------------------------

X0, Z0 = -9, -1                       # the deck's north-west corner: 4 west of the station
GRID_X, GRID_Z = (X0, X0 + 4, X0 + 8), (Z0, Z0 + 4, Z0 + 8)
X1, Z1 = X0 + 8, Z0 + 8                # x -1, z 7: x 0 is left free above the deck, the dock line
DY = -1                                # the deck: just above the water (y -2)

# ---- the deck ---------------------------------------------------------------------------------

for x in range(X0, X1 + 1):
    for z in range(Z0, Z1 + 1):
        edge = x in (X0, X1) or z in (Z0, Z1)
        put(x, DY, z, (LOG_X if z in (Z0, Z1) else LOG_Z) if edge else SPRUCE)
for x in GRID_X + (X0 + 2, X0 + 6):
    for z in GRID_Z + (Z0 + 2, Z0 + 6):
        if x in GRID_X or z in GRID_Z:
            if x in (X0, X1) or z in (Z0, Z1) or (x in GRID_X and z in GRID_Z):
                stilt(x, z, DY)

# ---- the cabin: the south-west module ---------------------------------------------------------

CX0, CZ0, CX1, CZ1 = X0, Z0 + 4, X0 + 4, Z0 + 8          # x -9..-5, z 3..7
WALL1, WALL2, PLATE = DY + 1, DY + 2, DY + 3
ROOF = PLATE + 1

for x in range(CX0, CX1 + 1):
    for z in range(CZ0, CZ1 + 1):
        if not (x in (CX0, CX1) or z in (CZ0, CZ1)):
            continue
        corner = x in (CX0, CX1) and z in (CZ0, CZ1)
        river_side = x == CX1 and not corner                 # open, over the work counter
        for y in (WALL1, WALL2):
            if corner:
                put(x, y, z, LOG_UP)
            elif not river_side:
                put(x, y, z, SPRUCE)
        put(x, PLATE, z, LOG_UP if corner else (LOG_X if z in (CZ0, CZ1) else LOG_Z))
# the work counter in the river-side opening, and a stool
for z in range(CZ0 + 1, CZ1):
    stairs(CX1, WALL1, z, "spruce", "xneg", upside_down=True)
stairs(CX1 - 1, WALL1, CZ0 + 2, "spruce", "xpos")
# the door, on the yard side; windows with shutters on the other closed sides
DOOR_X = CX0 + 2
put(DOOR_X, WALL1, CZ0, ("minecraft:wooden_door", 1), PANEL, "zneg")
put(DOOR_X, WALL2, CZ0, ("minecraft:wooden_door", 8), PANEL, "zneg")
shuttered_window(CX0 + 2, WALL2, CZ1, "zpos")
shuttered_window(CX0, WALL2, CZ0 + 2, "xneg")
# inside: a bed of sorts, a chest of sorts - a log and a plank under the window
put(CX0 + 1, WALL1, CZ1 - 1, LOG_X)
put(CX0 + 2, WALL1, CZ1 - 1, LOG_X)

# the roof: a low gable, its ridge along x, one block of overhang all round. Detailed, rough and
# uneven (the user, 2026-10-04: "more detail, more randomness, more wavy/depth"), the same every
# run (a fixed seed):
#   - stone-brick stairs with cobblestone ones among them;
#   - a flared eave: a row of slabs one further out at the foot of each slope;
#   - now and then a slab sitting in a step, so the slope is not a clean line;
#   - a raised verge: slabs along the gable edges;
#   - a crest on the ridge: slabs on every other block;
#   - upside-down spruce stairs as trim under the gable ends; dark-oak gables, a small window.
rnd = random.Random(1213)
STONE_SLAB = {"stonebrick": ("minecraft:stone_slab", 5), "cobble": ("minecraft:stone_slab", 3)}


def roof_material():
    return "cobble" if rnd.random() < 0.3 else "stonebrick"


RX0, RX1 = CX0 - 1, CX1 + 1
lo, hi, y = CZ0 - 1, CZ1 + 1, ROOF
for x in range(RX0, RX1 + 1):                           # the flared eave
    put(x, ROOF, lo - 1, STONE_SLAB[roof_material()], SLAB)
    put(x, ROOF, hi + 1, STONE_SLAB[roof_material()], SLAB)
while lo < hi:
    for x in range(RX0, RX1 + 1):
        for z, up in ((lo, "zpos"), (hi, "zneg")):
            m = roof_material()
            stairs(x, y, z, m, up)
            verge = x in (RX0, RX1)
            if verge or (y > ROOF and rnd.random() < 0.18):
                put(x, y + 1, z, STONE_SLAB[m], SLAB)       # a raised verge, or a rough step
    for gx, out in ((RX0, "xneg"), (RX1, "xpos")):
        stairs(gx, y - 1, lo, "spruce", OPPOSITE[out], upside_down=True)
        stairs(gx, y - 1, hi, "spruce", OPPOSITE[out], upside_down=True)
    lo, hi, y = lo + 1, hi - 1, y + 1
for x in range(RX0, RX1 + 1):
    put(x, y, lo, STONEBRICK)
    if (x - RX0) % 2 == 0:
        put(x, y + 1, lo, STONE_SLAB["stonebrick"], SLAB)  # the crest
RIDGE = y
for gx in (CX0, CX1):
    for yy in range(ROOF, RIDGE):
        span = yy - ROOF
        for z in range(CZ0 + span, CZ1 - span + 1):
            put(gx, yy, z, DARK_OAK)
    put(gx, ROOF + 1, (CZ0 + CZ1) // 2, GLASS, PANE)

# the chimney, outside the west wall: cobblestone from the ground, a stone-brick top
CHX, CHZ = CX0 - 1, CZ1
g = ground(CHX, CHZ)
for yy in range((g if g is not None else DY - 1) + 1, RIDGE + 2):
    put(CHX, yy, CHZ, STONEBRICK if yy >= RIDGE else COBBLE)
put(CHX, RIDGE + 2, CHZ, STONE_SLAB["stonebrick"], SLAB)    # its cap

# ---- the pergola: the north-east module, over the water ---------------------------------------

# Light against the dark spruce and the stone (the user, 2026-10-04: "the square frame ... make it
# from things that are on the lighter side"): oak fences for the posts and the rails - the user's
# choice over birch logs, there being no birch fence in the pack - and birch slab slats.
PX0, PZ0, PX1, PZ1 = X0 + 4, Z0, X1, Z0 + 4              # x -1..3, z -1..3
for x in (PX0, PX1):
    for z in (PZ0, PZ1):
        if (x, z) != (CX1, CZ0):                          # that corner is the cabin's post
            for yy in (WALL1, WALL2, PLATE):
                put(x, yy, z, FENCE_OAK, FENCE)
for x in range(PX0, PX1 + 1):                           # rails along x, on the posts
    put(x, ROOF, PZ0, FENCE_OAK, FENCE)
    put(x, ROOF, PZ1, FENCE_OAK, FENCE)
for z in range(PZ0 + 1, PZ1):                           # rails along z; slats every other row
    put(PX0, ROOF, z, FENCE_OAK, FENCE)
    put(PX1, ROOF, z, FENCE_OAK, FENCE)
    if (z - PZ0) % 2 == 1:
        for x in range(PX0 + 1, PX1):
            put(x, ROOF, z, ("minecraft:wooden_slab", 2 | 8), SLAB_TOP)
# the fish-cleaning table along the river side, a stool, a barrel of sorts
for z in range(PZ0 + 1, PZ1):
    stairs(PX1 - 1, WALL1, z, "spruce", "xpos", upside_down=True)
stairs(PX1 - 2, WALL1, PZ0 + 2, "spruce", "xpos")
put(PX0 + 1, WALL1, PZ0 + 1, LOG_UP)

# ---- the railings and the lamps -------------------------------------------------------------

PIER_Z = (Z1 - 2, Z1 - 1)                                 # where the pier leaves (east): z 5, 6,
MOOR_Z = PIER_Z                                           # south of the station; boats tie there
WALK_Z = (Z0 + 2, Z0 + 3)                                 # where the steps leave (west)
for x in range(X0, X1 + 1):
    for z in range(Z0, Z1 + 1):
        if not (x in (X0, X1) or z in (Z0, Z1)):
            continue
        if CX0 <= x <= CX1 and CZ0 <= z <= CZ1:
            continue                                      # the cabin's own walls
        if (x, DY + 1, z) in plan:
            continue                                      # a post
        if x == X1 and (z in PIER_Z or z in MOOR_Z) or x == X0 and z in WALK_Z \
                or z == Z0 and x == X0 + 2:
            continue                                      # the openings: pier, steps, the lane
        put(x, DY + 1, z, FENCE_S, FENCE)
for (x, z) in ((X0, Z0), (X1, Z1)):
    lamp_post(x, DY + 1, z)

# ---- the yard: a drying rack and a firewood stack (north-west, on the bank) -----------------

for x in (X0 + 1, X0 + 3):
    for yy in (WALL1, WALL2):
        put(x, yy, Z0 + 1, FENCE_S, FENCE)
for x in range(X0 + 1, X0 + 4):
    put(x, PLATE, Z0 + 1, LOG_X)
for x in (X0 + 1, X0 + 2):
    put(x, WALL1, CZ0 - 1, LOG_Z)
put(X0 + 1, WALL2, CZ0 - 1, LOG_Z)

# ---- the jetty (south-east): a bench by the water ---------------------------------------------

for z in (Z1 - 4, Z1 - 3):
    stairs(X1 - 1, WALL1, z, "spruce", "xneg")

# ---- the pier: east into the river -----------------------------------------------------------

PIER_END = X1 + 9                                         # 8 past the contour's east side
for x in range(X1 + 1, PIER_END + 1):
    for z in PIER_Z:
        put(x, DY, z, SPRUCE)
    for z in (PIER_Z[0] - 1, PIER_Z[1] + 1):
        if (x - X1) % 2 == 0:
            stilt(x, z, DY + 1)
            if x != PIER_END:
                put(x, DY, z, LOG_UP)
        else:
            put(x, DY, z, SPRUCE)
            put(x, DY + 1, z, FENCE_S, FENCE)
for z in (PIER_Z[0] - 1, PIER_Z[1] + 1):
    lamp_post(PIER_END, DY, z, 3)
    stilt(PIER_END, z, DY)
# the hoist near the end: a post, an arm out over the water, a rope of fence
HZ = PIER_Z[1] + 1
for yy in range(DY + 1, DY + 4):
    put(PIER_END - 2, yy, HZ, LOG_UP)
put(PIER_END - 2, DY + 4, HZ + 1, LOG_Z)
put(PIER_END - 2, DY + 4, HZ + 2, LOG_Z)
put(PIER_END - 2, DY + 3, HZ + 2, FENCE_S, FENCE)

# ---- the barn: two modules north of the yard, its west end against the walkway's pillars --------

# The user, 2026-10-04: "a building resting on the wall, ... some storage for wheat", with the hay
# bales they put in the mini ME. Moved north of the yard when the house moved west for the
# station; the first try there, one 5x5 lean-to sharing the deck's corner with a roof rising to
# y 9, was "too little with a much taller than need roof, it leaves too little space to the
# fisher's house, it has no detail on the sides". So now:
#   - 5 deep and 7 long, its west end at the pillars (x -15), one further from the house than the
#     first try (the user, 2026-10-04: "keep it 5 deep, but make it 7 long and move it one away
#     from the house to leave room for the path"), so a path two wide runs between it and the
#     deck. Its north side is past the contour, where the robot mapped on purpose (the user: "you
#     can use the bot to go explore outside");
#   - a half-pitch gable, the ridge at y 6: lower than the cabin's;
#   - a stone foundation course, a log frame (corner posts, a post where the modules meet, a top
#     plate), plank walls with a dark band under the plate, shuttered windows, an open double
#     doorway to the path, a loft door with a hoist over the pond.
# Attached to the wall (the user, 2026-10-04: "you can attach the barn to the wall"), never into
# it (it may not be broken): the west gable stands against the pillars, the roof's verge runs to
# them, and `put` refuses the pillars themselves.
BX0, BZ0, BX1, BZ1 = X0 - 5, Z0 - 7, X0 + 1, Z0 - 3        # x -14..-8, z -8..-4
BMID = (BX0 + BX1) // 2                                     # x -11, the middle post
BF = DY                                                     # the floor: the deck's level
BPLATE = BF + 4                                             # walls y 0..2, the plate at y 3
brnd = random.Random(2026)
DARK_SLAB, SPRUCE_SLAB = ("minecraft:wooden_slab", 5), ("minecraft:wooden_slab", 1)


def barn_wood():
    """Mostly dark oak, a weathered spruce one now and then."""
    return "spruce" if brnd.random() < 0.15 else "dark_oak"


# the foundation and the floor
for x in range(BX0, BX1 + 1):
    for z in range(BZ0, BZ1 + 1):
        g = ground(x, z)
        for yy in range((g if g is not None else BF - 1) + 1, BF):
            put(x, yy, z, COBBLE)
        wall = x in (BX0, BX1) or z in (BZ0, BZ1)
        put(x, BF, z, (COBBLE if brnd.random() < 0.4 else STONEBRICK) if wall else SPRUCE)

# the walls: posts, plank infill with a dark band, the top plate
for x in range(BX0, BX1 + 1):
    for z in range(BZ0, BZ1 + 1):
        if not (x in (BX0, BX1) or z in (BZ0, BZ1)):
            continue
        post = x in (BX0, BX1, BMID) and z in (BZ0, BZ1)
        for yy in range(BF + 1, BPLATE):
            if post:
                put(x, yy, z, LOG_UP)
            else:
                put(x, yy, z, DARK_OAK if yy == BPLATE - 1 else SPRUCE)
        put(x, BPLATE, z, LOG_UP if post else (LOG_X if z in (BZ0, BZ1) else LOG_Z))

# the roof: a half pitch across z, the ridge along x, one over all round. Rows from the eave:
# a stair, then a slab over the wall (planks under it close the wall's top), a stair, the
# ridge slab. Raised slabs along both verges.
RZ = (BZ0 + BZ1) // 2                                       # z -6, the ridge
for x in range(BX0 - 1, BX1 + 2):
    for z in range(BZ0 - 1, BZ1 + 2):
        d = min(z - (BZ0 - 1), (BZ1 + 1) - z)
        up = "zpos" if z - (BZ0 - 1) < (BZ1 + 1) - z else "zneg"
        m = barn_wood()
        if d == 0:
            stairs(x, BPLATE + 1, z, m, up)
        elif d == 1:
            put(x, BPLATE + 2, z, SPRUCE_SLAB if m == "spruce" else DARK_SLAB, SLAB)
            if BX0 <= x <= BX1:
                put(x, BPLATE + 1, z, DARK_OAK)
        elif d == 2:
            stairs(x, BPLATE + 2, z, m, up)
        else:
            put(x, BPLATE + 3, z, SPRUCE_SLAB if m == "spruce" else DARK_SLAB, SLAB)
        if x in (BX0 - 1, BX1 + 1) and d < 3:                # the raised verge
            put(x, BPLATE + 2 + (d + 1) // 2, z, DARK_SLAB, SLAB)
# the gables: dark oak under the roof
for gx in (BX0, BX1):
    for z in range(BZ0 + 1, BZ1):
        put(gx, BPLATE + 1, z, DARK_OAK)
    put(gx, BPLATE + 2, RZ, DARK_OAK)

# the south side, to the path: a shuttered window in the west bay, an open double doorway in the
# east one under a log lintel
shuttered_window(BX0 + 2, BF + 2, BZ1, "zpos", sill=False)
DOOR_XS = (BMID + 1, BMID + 2)                              # x -10, -9
for x in DOOR_XS:
    put(x, BF + 1, BZ1, AIR)
    put(x, BF + 2, BZ1, AIR)
for x in range(BMID + 1, BX1):
    put(x, BF + 3, BZ1, LOG_X)
# the north side: a shuttered window in each bay
shuttered_window(BX0 + 2, BF + 2, BZ0, "zneg")
shuttered_window(BMID + 2, BF + 2, BZ0, "zneg")
# the west gable, against the pillars: a small window; the east one, to the yard: a loft door
# (a fence gate) in the plate, and over it a hoist - a beam out under the eave, a rope of fence -
# with two bales on the ground under it
put(BX0, BPLATE + 1, RZ, GLASS, PANE)
put(BX1, BPLATE, RZ, GATE_S, GATE, "xpos")
put(BX1 + 1, BPLATE + 1, RZ, LOG_X)
put(BX1 + 2, BPLATE + 1, RZ, LOG_X)
put(BX1 + 2, BPLATE, RZ, FENCE_S, FENCE)

# the hay: along the north wall inside, the west half two high
HAY = ("minecraft:hay_block", 0)
for x in range(BX0 + 1, BX1):
    put(x, BF + 1, BZ0 + 1, HAY)
    if x < BMID:
        put(x, BF + 2, BZ0 + 1, HAY)
put(BX0 + 1, BF + 1, BZ0 + 2, HAY)

# ---- the path: gravel and stone, from the deck's west opening to the barn and the yard ---------

# The user, 2026-10-04: "a small path, you will use gravel and stone for that path, you can also
# put torches alongside it". Two wide, level with the deck (its top at y -1): west out of the
# deck where the steps were, north along the bank, east along the barn's front to its doorway
# and on to the gap in the yard's railing under the drying rack. Gravel and stone mixed at
# random; stone where nothing would hold gravel up. Torches on short posts along its edge.
PATH_Y = DY
LANE_X = X0 + 2                                             # x -7: the railing's gap, the rack
prnd = random.Random(7)
path = set()
for x in range(BX0 + 1, LANE_X + 1):                        # along the barn's front
    for z in (BZ1 + 1, BZ1 + 2):                            # z -3, -2
        path.add((x, z))
for x in (X0 - 2, X0 - 1):                                  # x -11, -10: down to the deck
    for z in range(BZ1 + 3, WALK_Z[1] + 1):                 # z -1 .. 2
        path.add((x, z))
for (x, z) in sorted(path):
    g = ground(x, z)
    held = g is not None and g >= PATH_Y - 1                # something under it, for gravel
    put(x, PATH_Y, z, GRAVEL if held and prnd.random() < 0.65 else STONE)
    for yy in range((g if g is not None else PATH_Y) + 1, PATH_Y):
        put(x, yy, z, STONE)
for z in (RZ, RZ + 1):                                      # under the hoist
    put(BX1 + 1, ground(BX1 + 1, z) + 1, z, HAY)
for (x, z) in ((X0 - 3, WALK_Z[1]), (X0 - 3, BZ1 + 3), (BX0, BZ1 + 2), (LANE_X + 1, BZ1 + 1)):
    g = ground(x, z)
    if g is not None and (x, g + 1, z) not in plan:
        lamp_post(x, g + 1, z, 1)

# ---- what is dug out ----------------------------------------------------------------------------

dig(X0, X1, DY + 1, DY + 3, Z0, Z1)                       # headroom over the deck
dig(BX0, BX1, BF + 1, BPLATE + 3, BZ0, BZ1)                 # the barn, up to its ridge
for (x, z) in path:                                         # headroom over the path
    dig(x, x, PATH_Y + 1, PATH_Y + 2, z, z)

# ---- out ------------------------------------------------------------------------------------

with open(os.path.join(DATA, "house.txt"), "w", newline="\n") as f:
    f.write("# 3d-draw plan: a poor fisher's cabin on a deck by the river (design/house.py)\n")
    f.write("# b x y z name meta shape facing\n")
    for (x, y, z), (name, meta, shape, facing) in sorted(plan.items(), key=lambda kv: (
            kv[0][1], kv[0][2], kv[0][0])):
        f.write(f"b {x} {y} {z} {name} {meta} {shape} {facing}\n")

# The bill of materials, as items: door halves as one door; stairs, logs, slabs, trapdoors and
# torches whichever way they stand.
need = Counter()
for (name, meta, shape, facing) in plan.values():
    if name == "minecraft:air":
        continue
    if name == "minecraft:wooden_door":
        if meta < 8:
            need[(name, 0)] += 1
    elif name == "minecraft:log":
        need[(name, meta & 3)] += 1                      # the wood, whichever way it lies
    elif name in ("minecraft:wooden_slab", "minecraft:stone_slab"):
        need[(name, meta & 7)] += 1
    elif name.endswith("_stairs") or name in ("minecraft:torch", "minecraft:trapdoor",
                                              "malisisdoors:trapdoor_spruce",
                                              "minecraft:fence_gate",
                                              "malisisdoors:spruceFenceGate"):
        need[(name, 0)] += 1
    else:
        need[(name, meta)] += 1

have = Counter()
for line in open(os.path.join(DATA, "me.txt")):
    if line.startswith("#") or not line.strip():
        continue
    name, meta, count = line.split()[:3]
    have[(name, int(meta))] += int(count)

# How each block not in the mini ME is had (ScriptMinecraft, GTNH 2.4.0; see docs/materials.md).
MADE = {
    ("minecraft:planks", 1): "crafted from spruce logs",
    ("minecraft:spruce_stairs", 0): "crafted from spruce planks",
    ("minecraft:dark_oak_stairs", 0): "crafted from dark oak planks",
    ("minecraft:stone_brick_stairs", 0): "crafted from stone bricks",
    ("minecraft:fence", 0): "crafted: oak planks + sticks (3 + 6 -> 1): ASK for oak",
    ("minecraft:glass_pane", 0): "crafted: saw + glass",
    ("minecraft:wooden_slab", 1): "crafted: saw + spruce planks",
    ("minecraft:wooden_slab", 5): "crafted: saw + dark oak planks",
    ("minecraft:wooden_slab", 2): "crafted: saw + birch planks (from birch logs)",
    ("minecraft:stone_slab", 5): "crafted: saw + stone bricks",
    ("minecraft:stone_slab", 3): "crafted: saw + cobblestone",
    ("minecraft:stone_stairs", 0): "crafted from cobblestone",
    ("malisisdoors:trapdoor_spruce", 0): "crafted: spruce slabs + sticks + flint",
    ("minecraft:fence_gate", 0): "crafted: oak planks + sticks + flint",
    ("malisisdoors:spruceFenceGate", 0): "crafted: spruce planks + sticks + flint",
    ("ExtraTrees:fence", 1): "crafted: spruce planks + sticks (3 + 6 -> 1)",
}
print(f"plan: {len(plan)} blocks; deck y {DY}, cabin walls y {WALL1}..{PLATE}, "
      f"roof ridge y {RIDGE}; written to data/house.txt")
print(f"{'block':36} {'need':>5} {'in ME':>6}  how")
for key, n in sorted(need.items(), key=lambda kv: -kv[1]):
    note = MADE.get(key, "" if have.get(key, 0) >= n else "MISSING")
    print(f"{key[0] + ':' + str(key[1]):36} {n:5} {have.get(key, 0):6}  {note}")

# What of the terrain the plan takes the place of: the tree and the ground are the user's to
# give up (2026-10-04: trees and dirt may be broken, never the wall at the back).
gone, under = Counter(), Counter()
for (x, y, z) in plan:
    c = cell(x, y, z)
    if c:
        (under if c[0] == "minecraft:water" else gone)[c[0]] += 1
print("dug out or built over:", ", ".join(f"{n} {k}" for k, n in gone.most_common()) or "nothing")
print("water displaced (it does not come back):", sum(under.values()))
print("refused (kept clear):", ", ".join(f"{n} at {k}" for k, n in refused.most_common())
      or "nothing")
