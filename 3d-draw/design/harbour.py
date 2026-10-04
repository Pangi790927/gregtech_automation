"""harbour.py - the proposal for the next building: a harbour up the river's west bank, north of the
cabin (3d-draw/DESIGN.md, TODO.md item 3).

    python 3d-draw/design/harbour.py

Writes data/harbour.txt - one block per line, `b x y z name meta shape facing`, robot coordinates,
as house.py does - which the viewer shows with the house (H; the dock's north end lies past the
current work zone: M and a click on the tree's chunk show it), and prints the bill of materials.

The brief (the user, 2026-10-04): "a crane in front of that lonely tree (meaning near the river)
and in the back of the tree a lighthouse that should be 3/2 the height of that wall in the back
and a start of a large ship dock, with some resources nearby, use chisel if you can and/or ask me
(when the building time comes) to provide you with materials". Standing in the river looking at
the cabin, north (robot -z) is on the right: the shore goes on that way. The lone tree is at world
252 115, robot -3 -24; the back wall stands 9 above the ground ("as seen from the ground"), so the
lighthouse is about 14 above its own.

THE GROUND here is read from the chunk store (data/chunks/, zones.py) - the work zone's map does
not reach the dock - and much of it the scouts only guessed by hardness. Before building, the
zone is moved north and the site's blocks named; this plan is drawn again on what they find.

THE PARTS (robot coordinates; the river is east):
  - the lighthouse, centred 6 west of the tree: a round tower on a stone plinth, a door toward
    the river, white stone with red brick bands, windows, a ladder inside, a slab gallery with a
    railing, a glass lantern room round a light, a dark roof cap;
  - the crane, in front of the tree on the bank: a log mast on a stone foot, a jib reaching over
    the water to the ship's bow with a chain of fences and a crate hanging from it midway, a
    counterweight behind, ties from a mast on its cabin;
  - the dock: a stone quay along the waterline north of the crane, a plank deck on it with
    bollards and lamps, a jetty on stilts out into the river - the start of the large dock, laid
    so it can go on north;
  - resources: crates, log piles and hay between the crane and the lighthouse;
  - a gravel and stone path from the cabin's lane north to the lighthouse door.
The tree stays: nothing is planned in its column.
"""
import os, random, re, sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(os.path.dirname(HERE), "data")
sys.path.insert(0, os.path.dirname(HERE))
import zones                                                   # noqa: E402

# ---- the terrain, from the chunks -------------------------------------------------------------

AX, AY, AZ = zones.anchor()
WORLD = {}                      # robot (x, y, z) -> block name
for _f in sorted(os.listdir(zones.CHUNKS)):
    _m = re.match(r"^c(-?\d+)_(-?\d+)\.txt$", _f)
    if not _m:
        continue
    _x0, _z0 = int(_m.group(1)) * 16 - AX, int(_m.group(2)) * 16 - AZ
    if not (-48 <= _x0 <= 32 and -64 <= _z0 <= 16):
        continue                                              # the site and round it
    _cells, _ = zones.read(os.path.join(zones.CHUNKS, _f))
    for (_x, _y, _z), _v in _cells.items():
        if _v:
            WORLD[(_x - AX, _y - AY, _z - AZ)] = _v[0]

# Not ground: plants and trees. "tallgrass", not "grass": a grass block is the ground itself
# (2026-10-04: east of the barn was taken for unmapped, the grass on top passed over).
SOFT = ("leaves", "flower", "tallgrass", "double_plant", "foliage", "plant", "sapling", "vine",
        "log", "torch")
WATER = "minecraft:water"


def name(x, y, z):
    """The block's name, "" for air, None where nothing is known."""
    v = WORLD.get((x, y, z))
    return None if v is None else "" if v == "minecraft:air" else v


def ground(x, z, top=12):
    """The top of the ground or the water in a column (not leaves, plants or trunks)."""
    for y in range(top, -12, -1):
        n = name(x, y, z)
        if n and not any(s in n.lower() for s in SOFT):
            return y
    return None


def bed(x, z):
    """The top of what is under the water, or the ground where there is none."""
    y = ground(x, z)
    while y is not None and name(x, y, z) == WATER:
        y -= 1
    return y


def wet(x, z):
    return name(x, ground(x, z) or 0, z) == WATER


# ---- the plan --------------------------------------------------------------------------------

plan = {}
CUBE, CROSS, SLAB, SLAB_TOP, STAIRS, STAIRS_DOWN, FENCE, PANE = 0, 1, 3, 4, 5, 6, 7, 8
LADDER_SHAPE = 1

STONEBRICK = ("minecraft:stonebrick", 0)
CHISELED = ("minecraft:stonebrick", 3)
WHITE = ("chisel:stonebricksmooth", 0)          # the back wall's own; the user's chisel blocks
BRICK = ("minecraft:brick_block", 0)
COBBLE = ("minecraft:cobblestone", 0)
SPRUCE = ("minecraft:planks", 1)
DARK_OAK = ("minecraft:planks", 5)
LOG_UP, LOG_X, LOG_Z = ("minecraft:log", 1), ("minecraft:log", 5), ("minecraft:log", 9)
FENCE_S = ("ExtraTrees:fence", 1)
PANE_G = ("minecraft:glass_pane", 0)
GLOW = ("minecraft:glowstone", 0)
TORCH = ("minecraft:torch", 5)
LADDER = ("minecraft:ladder", 4)               # on the west wall's inside face, facing east
CHEST = ("minecraft:chest", 0)
HAY = ("minecraft:hay_block", 0)
GRAVEL, STONE = ("minecraft:gravel", 0), ("minecraft:stone", 0)
SLAB_STONE = ("minecraft:stone_slab", 5)
STAIR = {"dark_oak": "minecraft:dark_oak_stairs", "stonebrick": "minecraft:stone_brick_stairs",
         "spruce": "minecraft:spruce_stairs"}
AIR = ("minecraft:air", 0)
TREE = (-3, -24)
# The tree's kept zone. The user, 2026-10-04, with markers on the tree's top (white, -3 3 -24)
# and on its outer leaves either side (red -1 0 -25, orange -5 1 -25): "the current plan cuts the
# tree too much, on the white marker, let it be until the red and orange markers, so around that
# radius don't cut it". So 2 each way from the trunk on x and on z, a square (the canopy fills
# its corners), up to one over the white marker; the crane's counter-jib passes above that.
# Nothing is placed or cleared there, but in the trunk's own column nothing at any height. The
# road gave way to it (the user's choice, 2026-10-04): see road().
TREE_R, TREE_TOP = 2, 4


def by_tree(x, y, z):
    """Whether a cell is the lone tree's to keep: its trunk's column, or within TREE_R of it up
    to TREE_TOP."""
    if (x, z) == TREE:
        return True
    return abs(x - TREE[0]) <= TREE_R and abs(z - TREE[1]) <= TREE_R and y <= TREE_TOP


# The house's plan (house.py): never built into, nor cleared - the stone area once ran into the
# barn's north wall and a lane into its east side (2026-10-04).
HOUSE = set()
for _line in open(os.path.join(DATA, "house.txt")):
    _p = _line.split()
    if _p and _p[0] == "b" and _p[4] != "minecraft:air":     # its blocks, not what it digs
        HOUSE.add(tuple(map(int, _p[1:4])))
HOUSE_COLS = {(x, z) for x, y, z in HOUSE}


def put(x, y, z, block, shape=CUBE, facing="-"):
    if by_tree(x, y, z) or (x, y, z) in HOUSE:
        return                                                # the lone tree, the house stay
    plan[(x, y, z)] = (block[0], block[1], shape, facing)


def clear(x, y, z):
    """Terrain out of the way (not water, not the tree), unless something is planned there."""
    n = name(x, y, z)
    if n and n != WATER and (x, y, z) not in plan and not by_tree(x, y, z) \
            and (x, y, z) not in HOUSE:
        plan[(x, y, z)] = (AIR[0], 0, CUBE, "-")


def stairs(x, y, z, material, facing, down=False):
    put(x, y, z, (STAIR[material], 0), STAIRS_DOWN if down else STAIRS, facing)


def stilt(x, z, top):
    """A spruce log from the riverbed (or the ground) up to just under `top`."""
    b = bed(x, z)
    for y in range((b if b is not None else top - 4) + 1, top):
        put(x, y, z, LOG_UP)


def lamp(x, y, z, h=2):
    for k in range(h):
        put(x, y + k, z, FENCE_S, FENCE)
    put(x, y + h, z, TORCH, CROSS)



# The user's pictures, 2026-10-04: stairs of mixed stone between stepped side walls, dark posts,
# bushes and moss at their foot; a square stone tower on jagged buttresses, a wooden balcony on
# brackets, a timber lantern room, two stacked stone roofs trimmed in orange wood, vines, a flag;
# a canal harbour: stone quays with a boardwalk on log posts, railings, a timber crane lowering a
# pallet of cargo, crates, barrels and pumpkins. Mixed stone everywhere, never one block alone.
RNG = random.Random(7)                  # the same mix every time the plan is drawn
# The user's stone, 2026-10-04: "I don't have cracked stone bricks, I've placed a chisel variant
# of cobblestone instead; also no mossy cobblestone or mossy stone bricks, use normal cobble with
# gravel and maybe chisel variants". Chisel's cobblestone 1 is "Detailed Cobblestone Bricks", 10
# "Cobblestone with Creeper Panel" (tile.cobblestone.<meta>.desc in its en_US.lang). Gravel only
# where it lies - paving, rock - never in a wall: it falls.
COBBLE_BRICKS = ("chisel:cobblestone", 1)
COBBLE_PANEL = ("chisel:cobblestone", 10)
MOSSY = COBBLE_BRICKS                   # where moss was meant: earth against stone
BARREL = ("JABBA:barrel", 0)            # the user's barrels, in clusters of four
MASONRY = ("chisel:stonebricksmooth", 0)
ACACIA = ("minecraft:planks", 4)
LEAVES = ("minecraft:leaves", 4)        # oak, placed: no decay
GRASS = ("minecraft:grass", 0)
DIRT = ("minecraft:dirt", 0)
# Tall grass and ferns were planned on the grass; the user has none (2026-10-04: "not the plants,
# I don't have them"). Their random draws are kept, so the rest of the mix stays as approved.
TALL = [("minecraft:tallgrass", 1), ("minecraft:tallgrass", 2)]    # grass, fern: not placed
BARS = ("minecraft:iron_bars", 0)
WOOL_ORANGE = ("minecraft:wool", 1)
PUMPKIN = ("minecraft:pumpkin", 0)
SLAB_SPRUCE = ("minecraft:wooden_slab", 1)
STAIR.update({"cobble": "minecraft:stone_stairs", "acacia": "minecraft:acacia_stairs"})
FACE_OUT = {(1, 0): "xpos", (-1, 0): "xneg", (0, 1): "zpos", (0, -1): "zneg"}
INWARD = {"xpos": "xneg", "xneg": "xpos", "zpos": "zneg", "zneg": "zpos"}


def stone():
    """A block of the mixed stone: stone bricks, detailed cobblestone bricks, cobblestone, now
    and then the creeper-panel cobble."""
    return RNG.choices([STONEBRICK, COBBLE_BRICKS, COBBLE, COBBLE_PANEL],
                       [52, 22, 22, 4])[0]


def bush(x, y, z, size=2):
    """A few leaf blocks on the ground, a heap of them: the pictures' bushes."""
    put(x, y, z, LEAVES)
    for dx, dz in RNG.sample([(1, 0), (-1, 0), (0, 1), (0, -1)], size - 1):
        if (x + dx, y, z + dz) not in plan:
            put(x + dx, y, z + dz, LEAVES)
    if size > 2:
        put(x, y + 1, z, LEAVES)


# ---- the lighthouse ---------------------------------------------------------------------------

# The user, 2026-10-04, on the first drawing: "make the lighthouse's stone base 1.5x to 2x as
# big, such that the wooden part is above the wall in the back (let it even touch the wall if that
# is need/looks better)" - taller and wider both (asked), the 1.5x-the-wall height given up. One
# west of where it was, its plinth reaches toward the wall; the wall stairs end at its foot.
LX, LZ = TREE[0] - 7, TREE[1]
R = 3                           # the shaft: 7x7
SH = 12                         # the shaft's height: the balcony at 13, the wall's top at 9
FLOOR = max(ground(x, z) or 0 for x in range(LX - R - 1, LX + R + 2)
            for z in range(LZ - R - 1, LZ + R + 2) if (x, z) != TREE)
TOP = FLOOR + SH + 6            # the upper roof


def ring(r):
    """The cells at distance r (the square's edge), corners included."""
    return [(dx, dz) for dx in range(-r, r + 1) for dz in range(-r, r + 1)
            if max(abs(dx), abs(dz)) == r]


def out_of(dx, dz):
    """The facing out from the centre across the edge a cell is on (x first at a corner)."""
    if abs(dx) >= abs(dz):
        return "xpos" if dx > 0 else "xneg"
    return "zpos" if dz > 0 else "zneg"


def lighthouse():
    """Square on a rubble plinth with jagged buttress pillars round it (the user's tower): a 7x7
    shaft of mixed stone 12 high with three rows of barred windows and an arched door to the
    river; a spruce balcony on bracket stairs, 9x9, with a railing and vines; a glass lantern room
    on log posts round glowstone; a stone roof trimmed in acacia, a small timber room on it, a
    second roof, a spire with an orange flag."""
    F, P = FLOOR, R + 1
    # the plinth, 9x9, from the ground up to the floor; cleared above
    for dx in range(-P, P + 1):
        for dz in range(-P, P + 1):
            x, z = LX + dx, LZ + dz
            g = ground(x, z) if ground(x, z) is not None else F - 1
            for y in range(min(g, F) - 1, F + 1):
                put(x, y, z, stone())
            for y in range(F + 1, TOP + 6):
                clear(x, y, z)
    # buttresses on the plinth's edge, jagged; a skirt of stairs between them
    piers = {(-P, -P): 8, (P, -P): 4, (-P, P): 6, (P, P): 7, (-P, -1): 3, (-1, -P): 5,
             (2, P): 3, (-P, 2): 4, (1, -P): 2, (P, -2): 3}
    door = (R, 0)
    for dx, dz in ring(P):
        x, z = LX + dx, LZ + dz
        if (dx, dz) in piers:
            h = piers[(dx, dz)]
            for y in range(F + 1, F + 1 + h):
                put(x, y, z, stone())
            put(x, F + 1 + h, z, ("minecraft:stone_slab", 5), SLAB)
        elif (dx, dz) == (P, 0):
            stairs(x, F + 1, z, "stonebrick", "xneg")          # the step to the door
        else:
            stairs(x, F + 1, z, RNG.choice(["stonebrick", "cobble"]), INWARD[out_of(dx, dz)])
    # the shaft
    for k in range(1, SH + 1):
        y = F + k
        for dx, dz in ring(R):
            x, z = LX + dx, LZ + dz
            if (dx, dz) == door and k <= 2:
                continue
            if abs(dx) == R and abs(dz) == R:
                put(x, y, z, MASONRY if k % 3 else STONEBRICK)          # the corners
            elif (dx, dz) in ((0, -R), (0, R), (-R, 0), (R, 0)) and k in (4, 7, 10):
                put(x, y, z, BARS, PANE)
            else:
                put(x, y, z, stone())
        for dx in range(-R + 1, R):
            for dz in range(-R + 1, R):
                clear(LX + dx, y, LZ + dz)
        put(LX - R + 1, y, LZ, LADDER, LADDER_SHAPE, "xpos")
    stairs(LX + R, F + 3, LZ, "stonebrick", "xneg", down=True)          # the door's arch
    # the balcony, 9x9, spruce, on brackets
    b = F + SH + 1
    for dx in range(-P, P + 1):
        for dz in range(-P, P + 1):
            if abs(dx) == P and abs(dz) == P:
                continue
            m = max(abs(dx), abs(dz))
            put(LX + dx, b, LZ + dz, SPRUCE if m < P else DARK_OAK)
            if m == P:
                if (dx + dz) % 2 == 0:
                    put(LX + dx, b + 1, LZ + dz, FENCE_S, FENCE)
                if abs(dx) < P - 1 or abs(dz) < P - 1:
                    stairs(LX + dx, b - 1, LZ + dz, "spruce", INWARD[out_of(dx, dz)], down=True)
    put(LX - R + 1, b, LZ, LADDER, LADDER_SHAPE, "xpos")
    # the lantern room, 5x5: log posts, glass between, glowstone in the middle
    for k in (1, 2):
        y = b + k
        for dx, dz in ring(2):
            put(LX + dx, y, LZ + dz, LOG_UP if abs(dx) == 2 and abs(dz) == 2 else PANE_G,
                CUBE if abs(dx) == 2 and abs(dz) == 2 else PANE)
        put(LX, y, LZ, GLOW)
    # the first roof, 7x7: an acacia rim, slabs, stone
    r = b + 3
    for dx in range(-3, 4):
        for dz in range(-3, 4):
            m = max(abs(dx), abs(dz))
            if m == 3 and abs(dx) == 3 and abs(dz) == 3:
                put(LX + dx, r, LZ + dz, ACACIA)
            elif m == 3:
                stairs(LX + dx, r, LZ + dz, "acacia", INWARD[out_of(dx, dz)], down=True)
            elif m == 2:
                put(LX + dx, r, LZ + dz, ("minecraft:stone_slab", 5), SLAB_TOP)
            else:
                put(LX + dx, r, LZ + dz, STONEBRICK)
    # the timber room, 3x3; the second roof, 5x5; the spire, the flag
    for dx, dz in ring(1):
        if abs(dx) == 1 and abs(dz) == 1:
            put(LX + dx, r + 1, LZ + dz, LOG_UP)
        else:
            put(LX + dx, r + 1, LZ + dz, SPRUCE if (dx + dz) % 2 else PANE_G,
                CUBE if (dx + dz) % 2 else PANE)
    put(LX, r + 1, LZ, GLOW)
    for dx, dz in ring(2):
        if abs(dx) == 2 and abs(dz) == 2:
            put(LX + dx, r + 2, LZ + dz, ACACIA)
        else:
            stairs(LX + dx, r + 2, LZ + dz, "stonebrick", INWARD[out_of(dx, dz)])
    for dx, dz in ring(1):
        put(LX + dx, r + 2, LZ + dz, STONEBRICK)
        put(LX + dx, r + 3, LZ + dz, ("minecraft:stone_slab", 5), SLAB)
    put(LX, r + 2, LZ, STONEBRICK)
    put(LX, r + 3, LZ, STONEBRICK)
    put(LX, r + 4, LZ, FENCE_S, FENCE)
    put(LX, r + 5, LZ, FENCE_S, FENCE)
    put(LX + 1, r + 5, LZ, WOOL_ORANGE)                       # the flag
    put(LX + 1, r + 4, LZ, WOOL_ORANGE)
    # grass and moss at its foot
    for dx, dz in ((-P - 1, -2), (-P - 1, 3), (2, P + 1), (-1, -P - 1), (P + 1, 3)):
        x, z = LX + dx, LZ + dz
        g = ground(x, z)
        if g is not None and not wet(x, z):
            put(x, g, z, GRASS)
            RNG.choice(TALL)                                  # no plant on it (none to hand)
    bush(LX - P - 1, F + 1, LZ + 3, 3)
    bush(LX + P + 1, F + 1, LZ - 3, 2)


# ---- the stone landing and the stairs up the back wall ------------------------------------------

def wall_stairs():
    """The user, 2026-10-04: "put a stone pier in between the tower and the barn, with some stairs
    that would stick to the wall and climb it to it's surface" - the back wall (asked) - and then,
    with the first picture: "more detailed and more natural stairs, with patches of grass on
    parts, climbing alongside the stairs". Two wide, mixed stone brick and cobble steps against
    the wall's face, rising south from z -20 to its top (y 8); filled under with mixed stone; a
    side wall stepping up with them, capped with slabs, spruce log posts on it every third step;
    beside it a grassy bank climbing with the flight, tall grass and ferns on it, bushes at the
    foot and along the way, vines on the side wall, moss where earth meets stone."""
    # Foot at the stone area, south; climbing north toward the lighthouse: the user, 2026-10-04,
    # "following the shoreline it will be: fisherman -> stone pier/area -> lighthouse + crane ->
    # wood pier" - the stairs start where the road and the pier meet.
    z0, top = -11, 8
    face = {}
    for z in range(z0 - top - 2, z0 + 3):
        xs = [x for x in range(-24, -8) if "korp" in (name(x, 8, z) or "").lower()]
        if xs:
            face[z] = max(xs) + 1
    if not face:
        return
    fx = min(face.values())                                  # the first column off the wall
    side, bank = fx + 2, (fx + 3, fx + 4)
    # the foot: a small stone landing, bushes on both sides
    for z in range(z0 + 1, z0 + 3):
        for x in range(fx, fx + 3):
            g = ground(x, z)
            if g is not None:
                for y in range(g, 1):
                    put(x, y, z, stone())
    bush(fx + 3, 1, z0 + 2, 3)
    bush(fx, 1, z0 + 3, 2)
    for k in range(top):
        z, y = z0 - k, k + 1
        for x in (fx, fx + 1):                                # the flight, two wide
            for yy in range(1, y):
                put(x, yy, z, stone())
            stairs(x, y, z, RNG.choices(["stonebrick", "cobble"], [3, 1])[0], "zneg")
            for yy in range(y + 1, y + 4):
                clear(x, yy, z)
        for yy in range(1, y + 1):                            # the side wall, one higher
            put(side, yy, z, stone())
        if k % 3 == 2:
            put(side, y + 1, z, LOG_UP)                       # a post
            put(side, y + 2, z, FENCE_S, FENCE)
        else:
            put(side, y + 1, z, ("minecraft:stone_slab", 5), SLAB)
        # the bank: earth stepping up beside it, a little lower, grass on top
        for i, x in enumerate(bank):
            h = max(0, y - 1 - i - (k % 2))
            g = ground(x, z)
            base = g if g is not None else 0
            for yy in range(base + 1, h):
                put(x, yy, z, DIRT)
            if h > base:
                put(x, h, z, GRASS)
                if RNG.random() < 0.55:
                    RNG.choice(TALL)                          # no plant on it (none to hand)
                elif RNG.random() < 0.3:
                    put(x, h + 1, z, LEAVES)
            if 0 < h - 1 and RNG.random() < 0.5:
                put(side, h - 1, z, MOSSY)                    # moss where earth meets stone
    zt = z0 - top                                             # the top, onto the wall
    for x in (fx, fx + 1, side):
        for yy in range(1, top + 1):
            put(x, yy, zt, stone())
    put(side, top + 1, zt, LOG_UP)
    put(side, top + 2, zt, TORCH, CROSS)
    bush(side + 1, top - 1, zt, 2)


# ---- the crane --------------------------------------------------------------------------------

CX, CZ = TREE[0] + 5, TREE[1]
REACH = 12                      # the jib's tip, east of the tower's centre: over the ship's bow
HOOK = 6                        # the rope, the trolley's place on the jib (the user's purple mark)
APEX = 5                        # the mast over the cabin, above the cabin's floor, the ties' top


def crane():
    """A timber tower crane on the bank (the canal harbour's): a stone foot, a 3x3 tower of spruce
    log corners with crossed bracing, a cabin of planks at the top, a jib of logs over the water
    to the ship's bow with its rope (fences) down to a spruce pallet loaded with melons and hay, a
    counter-jib with a counterweight of cobble behind, a mast on the cabin with fence ties down to
    both ends.

    The user, 2026-10-04, marking the jib's end at 8 7 -24 in the viewer: "the crane's arm, the
    one on with the purple marker should be longer, to show that it reaches the ship, the part
    under the purple can stay, the system glides the rope". So the jib goes on east from x 8 to
    x 14, over the ship's forecastle (its deck spans x 12..14 in that row; the masts and sails
    are 4 and more rows south, the bowsprit 3 north, all lower), while the rope and the pallet
    stay at x 8: a trolley glides along the jib, the rope hangs where it is parked. An arm twice
    as long needs holding up: the mast and its ties, as a tower crane's, and the counterweight
    doubled - the counter-jib cannot grow west, the lone tree stands two past its end."""
    foot = bed(CX, CZ)
    base = foot if foot is not None else -3
    dry = [ground(CX + dx, CZ + dz) for dx in (-1, 0, 1) for dz in (-1, 0, 1)
           if not wet(CX + dx, CZ + dz) and ground(CX + dx, CZ + dz) is not None]
    deck = max(dry) if dry else base + 2
    for dx in (-1, 0, 1):
        for dz in (-1, 0, 1):
            b = bed(CX + dx, CZ + dz)
            for y in range((b if b is not None else base) + 1, deck + 1):
                put(CX + dx, y, CZ + dz, stone())
    top = deck + 8
    for y in range(deck + 1, top):
        for dx, dz in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
            put(CX + dx, y, CZ + dz, LOG_UP)
        if (y - deck) % 3 == 0:                               # bracing
            for dx, dz, f in ((0, -1, "xpos"), (0, 1, "xneg"), (-1, 0, "zpos"),
                              (1, 0, "zneg")):
                stairs(CX + dx, y, CZ + dz, "spruce", f, down=bool((y - deck) % 2))
        for dx in (-1, 0, 1):
            for dz in (-1, 0, 1):
                if (dx, dz) == (0, 0) or (y - deck) % 3:
                    clear(CX + dx, y, CZ + dz)
    put(CX, deck + 1, CZ, LADDER, LADDER_SHAPE, "zpos")
    for dx in (-1, 0, 1):                                     # the cabin
        for dz in (-1, 0, 1):
            put(CX + dx, top, CZ + dz, DARK_OAK)
            put(CX + dx, top + 2, CZ + dz, SLAB_SPRUCE, SLAB)
            if abs(dx) == 1 and abs(dz) == 1:
                put(CX + dx, top + 1, CZ + dz, LOG_UP)
            elif (dx, dz) != (0, 0):
                put(CX + dx, top + 1, CZ + dz, PANE_G if dz == 0 else SPRUCE,
                    PANE if dz == 0 else CUBE)
    for dx in range(2, REACH + 1):                            # the jib, the counter-jib
        put(CX + dx, top + 1, CZ, LOG_X)
    for dx in (-2, -3):
        put(CX + dx, top + 1, CZ, LOG_X)
        put(CX + dx, top, CZ, COBBLE)
        put(CX + dx, top - 1, CZ, COBBLE)                     # the weight doubled, for the reach
    stairs(CX + 2, top, CZ, "spruce", "xneg", down=True)
    # The mast through the roof's middle, and the ties: fences stepping down from its top, each
    # step one lower, the runs overlapping a column so the chain holds together; to the jib's tip
    # (resting on it there only) and to the counter-jib's end.
    a = top + APEX
    for y in range(top + 2, a + 1):
        put(CX, y, CZ, LOG_UP)
    tip = CX + REACH
    for y, x0, x1 in ((a, CX + 1, CX + 4), (a - 1, CX + 4, CX + 8), (a - 2, CX + 8, tip),
                      (a - 3, tip, tip)):
        for x in range(x0, x1 + 1):
            put(x, y, CZ, FENCE_S, FENCE)
    for y, x0, x1 in ((a, CX - 1, CX - 1), (a - 1, CX - 2, CX - 1), (a - 2, CX - 3, CX - 2),
                      (a - 3, CX - 3, CX - 3)):
        for x in range(x0, x1 + 1):
            put(x, y, CZ, FENCE_S, FENCE)
    end = CX + HOOK
    for y in range(top, deck + 1, -1):                        # the rope
        put(end, y, CZ, FENCE_S, FENCE)
    for dz in (-1, 0, 1):                                     # the pallet and its load
        put(end, deck + 1 - 1 if False else deck, CZ + dz, SLAB_SPRUCE, SLAB_TOP)
    put(end, deck + 1, CZ - 1, PUMPKIN)
    put(end, deck + 1, CZ + 1, HAY)
    put(end, deck + 2, CZ - 1, HAY)


# ---- the dock (its start) ---------------------------------------------------------------------

WATERLINE = max((ground(x, z) for x in range(-2, 12) for z in range(-40, -18)
                 if wet(x, z) and ground(x, z) is not None), default=-2)
DOCK = WATERLINE + 1


def dock():
    """A quay of mixed stone along the waterline north of the crane, its top a light stone
    walk (stone slabs over stone), and a spruce boardwalk at its foot over the water on log posts
    every third block, with a fence railing; a jetty on stilts out into the river from the
    middle, lamps on its posts; crates, barrels and pumpkins on the quay (the canal harbour)."""
    z0, z1 = CZ - 2, CZ - 14
    edges = {}
    for z in range(z1, z0 + 1):
        edge = next((x for x in range(-4, 16) if wet(x, z)), None)
        if edge is not None:
            edges[z] = edge
    for z, edge in edges.items():
        for x in range(edge - 4, edge):                       # the quay: stone, its top a walk
            b = bed(x, z)
            for y in range((b if b is not None else DOCK - 3) + 1, DOCK + 1):
                put(x, y, z, stone())
            put(x, DOCK + 1, z, STONE if (x + z) % 3 else ("minecraft:stone_slab", 0),
                CUBE if (x + z) % 3 else SLAB)
            for y in range(DOCK + 2, DOCK + 5):
                clear(x, y, z)
        put(edge, DOCK, z, SPRUCE)                            # the boardwalk, over the water
        post = (z - z1) % 3 == 0
        if post:
            stilt(edge + 1, z, DOCK + 2)
            put(edge + 1, DOCK + 2, z, LOG_UP)
        else:
            put(edge + 1, DOCK, z, SPRUCE)
            put(edge + 1, DOCK + 1, z, FENCE_S, FENCE)
        if (z - z1) % 6 == 3:
            put(edge + 1, DOCK + 3, z, TORCH, CROSS) if post else lamp(edge - 4, DOCK + 2, z)
    # the jetty, 3 wide, on stilts, posts and lamps at its corners
    jz = (z0 + z1) // 2
    edge = edges.get(jz, 4)
    for dx in range(2, 10):
        for dz in (-1, 0, 1):
            put(edge + dx, DOCK, jz + dz, SPRUCE if dz == 0 else DARK_OAK)
        if dx % 3 == 1:
            for dz in (-1, 1):
                stilt(edge + dx, jz + dz, DOCK)
                put(edge + dx, DOCK + 1, jz + dz, FENCE_S, FENCE)
    for dz in (-1, 1):
        lamp(edge + 9, DOCK + 1, jz + dz, 2)
    # goods on the quay
    goods = [CHEST, BARREL, PUMPKIN, PUMPKIN, HAY, CHEST, ("minecraft:log", 1)]
    for i, z in enumerate(sorted(edges)[1::3]):
        x = edges[z] - 3
        put(x, DOCK + 2, z, goods[i % len(goods)])
        if i % 2 == 0:
            put(x, DOCK + 3, z, goods[(i + 3) % len(goods)])


# ---- the stone pier by the wall stairs -----------------------------------------------------------

def stone_pier(zc=-16):
    """The user, 2026-10-04: "I also want a stone pier near the stone stairs". From the shore
    east of the wall stairs out into the river, 3 wide, about 10 long, level with the quay's walk:
    smooth stone down the middle, mixed stone at the edges; mixed-stone pillars to the riverbed
    every third block with arches of upside-down stairs between them; a slab parapet broken by
    stone posts; a 5-wide head with two lantern pillars (the harbour picture's braziers, here
    stone round glowstone); a stone walk on land from the stairs' foot to the pier's root."""
    deck = DOCK + 1
    edge = next((x for x in range(-12, 12) if wet(x, zc)), None)
    if edge is None:
        return
    x0, x1 = edge - 1, edge + 9
    for x in range(x0, x1 + 1):
        head = x >= x1 - 2
        width = (-2, -1, 0, 1, 2) if head else (-1, 0, 1)
        for dz in width:
            z = zc + dz
            rim = abs(dz) == max(abs(d) for d in width)
            put(x, deck, z, stone() if rim else STONE)
            k = x - x0
            pillar = rim and (k % 3 == 2 or x == x1)
            if pillar:
                b = bed(x, z)
                for y in range((b if b is not None else deck - 4) + 1, deck):
                    put(x, y, z, stone())
            elif rim and wet(x, z):
                near = 1 if (k + 1) % 3 == 2 else -1 if (k - 1) % 3 == 2 else 0
                if near:
                    stairs(x, deck - 1, z, "stonebrick", "xpos" if near > 0 else "xneg",
                           down=True)                         # an arch springing off a pillar
            if rim and not head:
                if pillar:
                    put(x, deck + 1, z, STONEBRICK)           # a post
                else:
                    put(x, deck + 1, z, ("minecraft:stone_slab", 5), SLAB)
            for y in range(deck + 1 + (1 if rim and not head else 0), deck + 4):
                clear(x, y, z)
    for dz in (-2, 2):                                        # the head's lantern pillars
        x, z = x1, zc + dz
        put(x, deck + 1, z, stone())
        put(x, deck + 2, z, GLOW)
        put(x, deck + 3, z, ("minecraft:stone_slab", 5), SLAB)


# ---- the stone area, the road, the rocks -------------------------------------------------------

ROAD_Y = DOCK + 1               # level with the quay's walk and the stone pier's deck


def pave(x, z, block=None, keep=False):
    """A road or plaza cell at ROAD_Y: filled under with stone where the ground is lower (the
    bank drops toward the river), cleared above; never into water or over the plan."""
    if wet(x, z) or (x, z) == TREE:
        return
    if keep and (x, ROAD_Y, z) in plan:
        return
    g = ground(x, z)
    for y in range(min(g if g is not None else ROAD_Y - 2, ROAD_Y), ROAD_Y):
        if (x, y, z) not in plan:
            put(x, y, z, stone())
    put(x, ROAD_Y, z, block or stone())
    for y in range(ROAD_Y + 1, ROAD_Y + 4):
        clear(x, y, z)


def stone_area():
    """Where the fisher's road, the wall stairs' foot and the stone pier meet: a plaza of mixed
    stone with a smooth-stone band through it, grass patches and a bush at its edges."""
    # It stops two short of the barn's north wall (z -9): a row of space before its doors, and
    # a row of stairs down to it (the user, 2026-10-04: "the barn meets the stone pier too
    # abruptly, leave a block of space and add some stairs to reach the same level").
    for x in range(-11, -2):
        for z in range(-18, -11):
            if wet(x, z):
                continue
            band = z in (-17, -16, -15)
            pave(x, z, STONE if band and RNG.random() < 0.7 else
                 GRAVEL if RNG.random() < 0.12 else None, keep=True)
        if not wet(x, -11) and (x, -11) not in HOUSE_COLS:
            pave(x, -11)
            put(x, ROAD_Y, -11, (STAIR["stonebrick"], 0), STAIRS, "zneg")   # down, south
    for x, z in ((-11, -18), (-3, -12)):
        if not wet(x, z):
            bush(x, ROAD_Y + 1, z, 2)


def road():
    """The road along the shore (the user, 2026-10-04: fisherman -> stone pier/area ->
    lighthouse + crane -> wood pier; "between the tree and the crane there is a small space, use
    that to pass a road"): from the fisher's lane into the stone area, north out of it, a branch
    west to the lighthouse door, east and through the gap between the tree and the crane's foot,
    north to the quay and its wooden jetty. Three wide, gravel down the middle and stone at the
    sides, as the cabin's path; lamp posts along it.

    It keeps out of the tree's zone (by_tree; the user's choice, 2026-10-04, between that and the
    road through the gap): the east run moved a row south, off z -22, and the gap is a path one
    wide at x 0, gravel, between the zone (x -1) and the crane's foot (x 1); 4 clear above it to
    the counter-jib's weight. The paved branch to the door is gone - its cells were the zone's -
    and the door is reached along the plinth's skirt of stairs at x -6 (z -21..-23, y 2), from
    the road's corner (-5 -21) over the hay there and a step on it (resources())."""
    line = [(x, z) for z in range(-19, -22, -1) for x in (-5, -4, -3)]         # out north
    line += [(x, z) for x in range(-5, 1) for z in (-21, -20)]                  # east
    line += [(0, z) for z in range(-22, -28, -1)]                               # the gap
    mid = {(-4, z) for z in range(-21, -18)} | {(0, z) for z in range(-27, -21)} | \
        {(x, -21) for x in range(-5, 1)}
    for x, z in line:
        if (x, z) == TREE or (x, ROAD_Y, z) in plan and plan[(x, ROAD_Y, z)][0] != AIR[0]:
            continue
        pave(x, z, GRAVEL if (x, z) in mid else STONE)
    # Past the barn: the user, "pass the road in front of the barn to connect to the fisher
    # house's road" - along its east side, at the ground's level, from the stone area's stairs
    # south to the fisher's gravel road (z -2, which runs west along the barn's south side).
    # East of the barn is water (an inlet, its surface at -2): there the road is a spruce
    # boardwalk on log posts, as the fisher's deck; on land gravel and stone - all at the
    # fisher's road's level (y -1).
    lane_y = -1
    for z in range(-10, -1):
        for x in (-5, -4, -3):
            if (x, z) in HOUSE_COLS:
                continue
            if wet(x, z):
                put(x, lane_y, z, SPRUCE)
                if x == -3 and z % 3 == 0:
                    stilt(x, z, lane_y)
                    put(x, lane_y + 1, z, FENCE_S, FENCE)
                elif x == -3:
                    put(x, lane_y + 1, z, FENCE_S, FENCE)
            else:
                g = ground(x, z)
                if g is None:
                    continue
                for y in range(min(g, lane_y), lane_y):
                    put(x, y, z, stone())
                put(x, lane_y, z, GRAVEL if x == -4 else STONE)
            for y in range(lane_y + 1 + (1 if x == -3 else 0), lane_y + 4):
                clear(x, y, z)
    for x in (-7, -6):                                        # onto the fisher's road
        if (x, -2) in HOUSE_COLS:
            continue
        if wet(x, -2):
            put(x, lane_y, -2, SPRUCE)
        else:
            put(x, lane_y, -2, GRAVEL)
    for x, z in ((-6, -20), (1, -22), (1, -27), (-2, -6)):
        if not wet(x, z) and (x, ROAD_Y, z) not in plan:
            pave(x, z)
            lamp(x, ROAD_Y + 1, z)


def rocks():
    """Rock at the base of the tower (the user): outcrops of stone, cobble, mossy cobble, gravel
    and masonry on the ground round the plinth, one to three high, grass and ferns among them."""
    spots = [(-14, -30, 2), (-12, -30, 3), (-9, -30, 2), (-6, -30, 2), (-5, -29, 1),
             (-4, -27, 2), (-15, -29, 1), (-8, -31, 1), (-11, -31, 2)]   # past the plinth
    for x, z, h in spots:
        g = ground(x, z)
        if g is None or wet(x, z):
            continue
        for k in range(h):
            for dx, dz in ((0, 0), (1, 0), (0, 1))[:3 - k]:
                c = (x + dx, g + 1 + k, z + dz)
                if c not in plan:
                    put(*c, RNG.choice([STONE, COBBLE, COBBLE_BRICKS, GRAVEL, GRAVEL]))
        c = (x - 1, g + 1, z)
        if c not in plan and ground(x - 1, z) == g:
            RNG.choice(TALL)                                  # no plant there (none to hand)


def barrels():
    """The user, 2026-10-04: "added some interesting barrels, those can be placed in sort of
    triangle shapes 4 connected (3 to a central piece) and placed on the stone pier", then
    "the 4 connected pieces are supposed to form with their centers a pyramid, or 3d
    perpendicular axes" - a corner: a centre barrel, one beside it along x, one along z, one on
    top of it. One on the stone pier's head, three on the stone area by its root, each corner
    turned its own way: 16 of the 17."""
    deck = DOCK + 1
    edge = next((x for x in range(-12, 12) if wet(x, -16)), None)
    clusters = []                       # (centre x, z, the x arm's side, the z arm's side)
    if edge is not None:
        clusters.append((edge + 8, -16, -1, 1))                       # the pier's head
    clusters += [(-10, -12, 1, -1), (-5, -12, -1, -1), (-10, -17, 1, 1)]   # apart, by the stairs
    for cx, cz, sx, sz in clusters:
        for dx, dy, dz in ((0, 0, 0), (sx, 0, 0), (0, 0, sz), (0, 1, 0)):
            put(cx + dx, deck + 1 + dy, cz + dz, BARREL)


# ---- the ship ----------------------------------------------------------------------------------

WOOL_WHITE = ("minecraft:wool", 0)


def ship():
    """The user, 2026-10-04: "a medium sized ship waiting in front of the stone pier". About 21
    long and 7 wide, its bow north up the river, its west side two off the stone pier's head, a
    gangplank of two spruce planks across. Hull of dark oak on a spruce keel, narrowing to the
    bow and a little to the stern, down to y -3 (the bed there is -4 to -6, the water's top -2);
    the main deck of spruce level with the pier (y 0), a gunwale of fences round it but at the
    gangway; a raised forecastle and a bowsprit; a stern cabin of dark oak with glass windows,
    a railed quarterdeck on it, lanterns at its corners; two masts with yards and white wool
    sails, an orange flag at the main top. Below the deck the water stays: it is not seen."""
    deck = DOCK + 1
    edge = next((x for x in range(-12, 12) if wet(x, -16)), None)
    if edge is None:
        return
    cx = edge + 9 + 3 + 3                  # the pier's head ends at edge + 9; two off; 7 wide
    z0, L = -26, 21                        # the bow's row, the length
    hw = [0, 1, 1, 2, 2, 3] + [3] * 11 + [3, 3, 2, 2]
    for i in range(L):
        z, w = z0 + i, hw[i]
        for y, dw in ((-3, -2), (-2, -1), (-1, 0), (0, 0)):
            ww = w + dw
            if ww < 0:
                continue
            for dx in range(-ww, ww + 1):
                x = cx + dx
                rim = abs(dx) == ww
                if y == -3 and dx == 0:
                    put(x, y, z, LOG_Z)                       # the keel
                elif y == 0:
                    put(x, y, z, DARK_OAK if rim else SPRUCE)   # the deck, its edge
                elif rim or y == -3:
                    put(x, y, z, DARK_OAK)                    # the hull's sides and bottom
        # the gunwale, but at the gangway (the west side, by the pier's axis)
        if 3 < i < 16:
            for dx in (-w, w):
                if dx < 0 and -17 <= z <= -15:
                    continue
                put(cx + dx, deck + 1, z, FENCE_S, FENCE)
    # the forecastle: the bow's first rows raised a step, a rail; the bowsprit
    for i in range(0, 4):
        z, w = z0 + i, hw[i]
        for dx in range(-w, w + 1):
            put(cx + dx, deck + 1, z, SPRUCE)
            if abs(dx) == w:
                put(cx + dx, deck + 2, z, FENCE_S, FENCE)
    put(cx, deck + 1, z0 - 1, LOG_Z)
    put(cx, deck + 2, z0 - 2, LOG_Z)
    put(cx, deck + 3, z0 - 3, FENCE_S, FENCE)
    # the stern cabin, its door toward the bow; the quarterdeck on it
    for i in range(16, L):
        z, w = z0 + i, hw[i]
        for dx in range(-w, w + 1):
            for y in (deck + 1, deck + 2):
                edge_cell = abs(dx) == w or i in (16, L - 1)
                if not edge_cell:
                    continue
                if i == 16 and dx == 0:
                    continue                                  # the door
                window = y == deck + 2 and (abs(dx) == w and i in (18, 19)
                                            or i == L - 1 and abs(dx) == 1)
                put(cx + dx, y, z, PANE_G if window else DARK_OAK, PANE if window else CUBE)
            put(cx + dx, deck + 3, z, SLAB_SPRUCE, SLAB_TOP)
            if abs(dx) == w or i == L - 1:
                put(cx + dx, deck + 4, z, FENCE_S, FENCE)
    for dx in (-hw[L - 1], hw[L - 1]):
        put(cx + dx, deck + 5, z0 + L - 1, TORCH, CROSS)
    # the masts, the yards, the sails, the flag
    for i, top, yards in ((6, 11, ((9, 2),)), (11, 14, ((8, 3), (12, 2)))):
        z = z0 + i
        for y in range(deck + 1, deck + top + 1):
            put(cx, y, z, LOG_UP)
        for yy, half in yards:
            for dx in range(-half, half + 1):
                if dx:
                    put(cx + dx, deck + yy, z, LOG_X)
            for y in range(deck + yy - (3 if half > 2 else 2), deck + yy):
                for dx in range(-half + 1, half):
                    if dx:
                        put(cx + dx, y, z + 1, WOOL_WHITE)    # the sail, just aft of the mast
    put(cx, deck + 15, z0 + 11, FENCE_S, FENCE)
    put(cx + 1, deck + 15, z0 + 11, WOOL_ORANGE)
    # the gangplank to the pier
    for x in range(edge + 10, cx - hw[10]):
        put(x, deck, -16, SPRUCE)


# ---- resources, and the path -------------------------------------------------------------------

def resources():
    """Crates, a log pile on rails' wise, hay and pumpkins on the ground round the tree."""
    spots = [(TREE[0] + 2, TREE[1] + 3), (TREE[0] + 1, TREE[1] + 3), (TREE[0] + 2, TREE[1] - 3),
             (TREE[0] - 2, TREE[1] + 3), (TREE[0] - 2, TREE[1] - 3)]
    for i, (x, z) in enumerate(spots):
        g = ground(x, z)
        if g is None or wet(x, z):
            continue
        if i < 2:
            put(x, g + 1, z, CHEST)
            if i == 0:
                put(x, g + 2, z, PUMPKIN)
        elif i == 2:
            for dx in range(0, 3):
                put(x + dx, g + 1, z, LOG_X)
                if dx < 2:
                    put(x + dx, g + 2, z, LOG_X)
        else:
            put(x, g + 1, z, HAY)
            if i == 3:
                # Not a second hay but a step west onto the lighthouse plinth's skirt: the one
                # cell beside it outside the tree's zone, the door's only way (road()).
                stairs(x, g + 2, z, "stonebrick", "xneg")
            bush(x, g + 1, z + 1, 2)



lighthouse()
wall_stairs()
stone_pier()
stone_area()
barrels()
ship()
crane()
dock()
road()
rocks()
resources()

with open(os.path.join(DATA, "harbour.txt"), "w", newline="\n") as out:
    out.write("# 3d-draw harbour (design/harbour.py): b x y z name meta shape facing\n")
    for (x, y, z), (n, m, s, f) in sorted(plan.items(), key=lambda kv: (kv[0][1], kv[0])):
        out.write(f"b {x} {y} {z} {n} {m} {s} {f}\n")
bill = Counter((v[0], v[1]) for v in plan.values() if v[0] != AIR[0])
print(f"harbour: {len(plan)} cells ({sum(bill.values())} blocks, "
      f"{sum(1 for v in plan.values() if v[0] == AIR[0])} dug out); lighthouse floor y {FLOOR}, "
      f"upper roof {TOP}; crane at {CX} {CZ}; dock deck y {DOCK}")
for (n, m), k in bill.most_common():
    print(f"   {k:4} {n}:{m}")
