"""placing.py - how a robot places a block, as the mods have it: which (side, face) pairs give a
block the way the plan has it, and which faces a click can meet. The physics was worked out for
design/build.py (its module comment: OpenComputers 1.9.14 Agent and Player, vanilla 1.7.10's
blocks) and checked on the house's blocks by reading them back; it is here on its own so the
sector builder (builders.py) and its simulation (sim.py) use the one copy.

A plan cell is (name, meta, shape, facing): shape 4 a top slab, 6 an upside-down stair; facing
xneg/xpos/zneg/zpos the way a stair rises or a gate turns, "-" for none.
"""

DIRS = {"n": (0, 0, -1), "s": (0, 0, 1), "e": (1, 0, 0), "w": (-1, 0, 0), "u": (0, 1, 0),
        "d": (0, -1, 0)}
OPP = {"n": "s", "s": "n", "e": "w", "w": "e", "u": "d", "d": "u"}
H = ("n", "s", "e", "w")
FACING = {"xneg": "w", "xpos": "e", "zneg": "n", "zpos": "s"}
NOT_CLICKABLE = ("minecraft:torch", "minecraft:wooden_door", "minecraft:fence_gate",
                 "malisisdoors:spruceFenceGate", "minecraft:trapdoor",
                 "malisisdoors:trapdoor_spruce")
COBBLE = ("minecraft:cobblestone", 0)
# The field (the user, 2026-10-04: "add a field of wheat (I've added seeds and hoes to the me)"):
# farmland is not placed but tilled - GregTech's hoe (metatool 8) in the tool slot, the dirt's top
# clicked from beside the cell over it (a hoe tills only a block with air over it, and a robot
# is a block: it cannot till what it stands on); wheat is seeds placed on the farmland's top.
HOE = ("gregtech:gt.metatool.01", 8)
SEEDS = ("minecraft:wheat_seeds", 0)
TILLED = "minecraft:farmland"
CROP = "minecraft:wheat"
TILLABLE = ("minecraft:grass", "minecraft:dirt", "?")


def add(c, d):
    v = DIRS[d]
    return (c[0] + v[0], c[1] + v[1], c[2] + v[2])


def options(block):
    """The (side, face) pairs that place `block` as the plan has it: side is the way the robot
    faces the target (it stands at target - side), face the target's neighbour it clicks.
    Clicking the block below first: what a block rests on is the surest thing to click."""
    name, meta, shape, facing = block
    f = FACING.get(facing)
    order = ["d", "n", "s", "e", "w", "u"]
    every = [(s, c) for c in order for s in DIRS if c != OPP[s]]
    if name.endswith("_stairs"):
        if shape == 6:                                       # upside down
            return [(f, "u"), ("d", f)]
        return [(f, "d"), ("u", f), (f, f)]
    if name.endswith("_slab"):
        if shape == 4 or meta & 8:                           # the top half
            return [(s, "u") for s in H] + [("d", c) for c in H]
        return [(s, "d") for s in H] + [("u", c) for c in H] + \
            [(s, c) for s in H for c in H if c != OPP[s]]
    if name in ("minecraft:log", "minecraft:log2"):            # log2: acacia, dark oak
        axis = {0: "y", 4: "x", 8: "z"}[meta & 12]
        faces = {"y": ("u", "d"), "x": ("e", "w"), "z": ("n", "s")}[axis]
        return [(s, c) for (s, c) in every if c in faces]
    if name == "minecraft:hay_block":
        return [(s, c) for (s, c) in every if c in ("d", "u")]
    if name.endswith("trapdoor") or name.endswith("trapdoor_spruce"):   # against its wall
        return [(s, f) for s in DIRS if s != OPP[f]]
    if name == "minecraft:wooden_door":
        return [(OPP[f], "d")]
    if name in ("minecraft:fence_gate", "malisisdoors:spruceFenceGate"):
        return [(f, "d"), (OPP[f], "d")]
    if name == "minecraft:ladder":
        # it hangs on the wall clicked: vanilla 1.7.10 BlockLadder takes its meta from the face
        # clicked, 2 on a wall to the south, 3 north, 4 east, 5 west; the plan's facing is not
        # what places it (the user's ladders, 2026-10-04, meta 4 with xpos and zpos alike)
        wall = {2: "s", 3: "n", 4: "e", 5: "w"}[meta]
        return [(s, wall) for s in DIRS if s != OPP[wall]]
    if name in ("minecraft:torch", "minecraft:gravel"):
        return [(s, "d") for s in H] + [("d", "d")]
    if name in (CROP, TILLED):
        # seeds on the farmland's top; the hoe on the dirt's top: from beside, the face below
        return [(s, "d") for s in H] + [("d", "d")]          # beside, or from above
    return every


def full(name):
    """Whether a block fills its cell (and so hides what is behind it, and takes any click)."""
    if name in NOT_CLICKABLE or name.endswith("_stairs") or name.endswith("_slab"):
        return False
    # iron bars are thin like a pane: a stone brick clicked on their top missed and went in
    # elsewhere (2026-10-04, the lighthouse)
    return not any(k in name for k in ("fence", "Fence", "pane", "door", "Gate", "torch",
                                       "bars", "ladder"))


def meets(block, face, side):
    """Whether a click on a built `block` (a plan cell's tuple) meets it: on its face toward the
    target (`face`, seen from the target), the robot facing `side`. The ray's geometry is
    design/build.py's clickable(): a fence's post fills the middle quarter, a slab half its
    height, a stair's full half is a slab's."""
    name, meta, shape, _ = block
    if full(name):
        return True
    top_face, bottom_face = face == "d", face == "u"
    if "pane" in name or "bars" in name:
        return top_face and side == "d"
    if "fence" in name and "Gate" not in name and "gate" not in name:
        return top_face
    if name.endswith("_slab"):
        if shape == 4 or meta & 8:
            return top_face or (face not in ("u", "d") and side == "d")
        return bottom_face or (face not in ("u", "d") and side == "u")
    if name.endswith("_stairs"):
        if shape == 6:
            return top_face or (face not in ("u", "d") and side == "d")
        return bottom_face or (face not in ("u", "d") and side == "u")
    return False


def item_of(name, meta):
    """The item a placed block is made from: a door's lower half, stairs, logs, slabs whichever
    way they stand."""
    if name in ("minecraft:log", "minecraft:log2"):
        return (name, meta & 3)
    if name == CROP:
        return SEEDS
    if name == TILLED:
        return HOE                        # not spent: the tool it takes
    if name.endswith("_slab"):
        return (name, meta & 7)
    if name in ("minecraft:leaves", "minecraft:leaves2"):
        return (name, meta & 3)           # 4 and 8 are how it decays, not which leaf
    if name.endswith("_stairs") or "trapdoor" in name or name in ("minecraft:torch",
                                                                   "minecraft:wooden_door",
                                                                   "minecraft:ladder"):
        return (name, 0)                  # the meta is how it was placed
    return (name, meta)


# What stands in for an item the mini ME is short of (the user, 2026-10-04: "use spruce leafs
# when missing substitute"): oak leaves -> spruce leaves
SUBSTITUTE = {("minecraft:leaves", 0): ("minecraft:leaves", 1)}


def substitutes(block):
    """The plan's block and the blocks that may stand for it, as plan tuples."""
    out = [block]
    it = item_of(block[0], block[1])
    sub = SUBSTITUTE.get(it)
    if sub and sub[0] == block[0]:
        out.append((block[0], (block[1] & ~3) | sub[1], block[2], block[3]))
    return out


# Stairs: vanilla 1.7.10 BlockStairs.onBlockPlacedBy: rising east 0, west 1, south 2, north 3; 4
# when upside down. Other mods' blocks keep their state their own way: only the name is checked.
STAIR_META = {"xpos": 0, "xneg": 1, "zpos": 2, "zneg": 3}
LENIENT = ("ExtraTrees:fence", "malisisdoors:", "minecraft:wooden_door",
           "minecraft:chest", "minecraft:pumpkin", "JABBA:barrel")   # face as the robot looked


def expected_meta(block):
    name, meta, shape, facing = block
    if name.endswith("_stairs"):
        return STAIR_META[facing] | (4 if shape == 6 else 0)
    if name.endswith("_slab") and shape == 4:
        return meta | 8                   # the top half: vanilla's bit 8 (spruce top slab: 9)
    if name in ("minecraft:leaves", "minecraft:leaves2"):
        return meta | 4                   # placed by hand: never decays (vanilla ItemLeaves)
    return meta


def reads_right(block, got_name, got_meta):
    """Whether what analyze read back is the plan's block, or a substitute for it."""
    for b in substitutes(block):
        if got_name == b[0] and (any(b[0].startswith(p) for p in LENIENT)
                                 or got_meta == expected_meta(b)):
            return True
    return False
