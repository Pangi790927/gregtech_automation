"""buildsite.py - what the sector builders (builders.py) know of a building site: the plan,
the world as far as it is known, what is built, and the work cut into sectors
(3d-draw/docs/building.md, "Building in sectors").

Why it is built this way (2026-10-04, after the harbour's first day): the old planner worked out
one order for one robot, and five robots ran it at once. Builders swung at cells other robots
stood in and broke three of them; they dug through ground to travel and sealed themselves in;
they trusted the scouts' guesses and dug into the riverbed. So here:
  - a cell is known (air, water, solid with its name), guessed (the survey's hardness only), or
    unknown; only what is known is clicked, and moves - which break nothing - find out the rest;
  - the work is cut into sectors, each built by one robot at a time, and no two neighbouring
    sectors at once: two builders never work the same cells;
  - ground already there that ends up hidden is kept, not swapped for the plan's block (the
    user, 2026-10-04, choosing "Keep hidden ground"): most of the digging was that, and the
    pits and the riverbed's water came with it.
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import survey                                                # noqa: E402
from placing import DIRS, OPP, add, full, meets, COBBLE, TILLED, CROP  # noqa: E402

DATA = os.path.join(HERE, "data")
DONE = os.path.join(DATA, "build-done.txt")
LOG = os.path.join(DATA, "live.log")
# Water the user let builders go into, beyond water a planned block replaces: `box x0 x1 y0 y1 z0
# z1 <why>` per line, robot frame. The ship's hull below its deck (the user, 2026-10-04: "Robots
# may enter the hull's water").
WET_OK = os.path.join(DATA, "wet-ok.txt")
# Ground outside the plan the user let builders dig, to have a cell to stand in, and fill back
# after: same lines. The lighthouse's base (the user, 2026-10-04: "Yes, dig and refill").
DIG_OK = os.path.join(DATA, "dig-ok.txt")
# The harbour's records start after this many lines of build-done.txt (the house's before).
HARBOUR_FROM = 842

LEAVES = ("leaves",)
SOFT = ("flowers", "tallgrass", "double_plant", "foliage", "web", "torch", "sapling",
        "leaves", "vine", "reeds", "mushroom")
WATER = "minecraft:water"


def soft(name):
    """Not a face to click: a plant, a torch, leaves (whole blocks, but they decay)."""
    return any(k in name for k in SOFT)


class Site:
    """The plan and the world as known. `state[c]` is ("air",), ("water",) or ("solid", name);
    a cell not in it is unknown. `guess` holds the cells whose state is the survey's guess."""

    def __init__(self, plan_path, map_path=None, record_from=HARBOUR_FROM, log=LOG):
        self.plan, self.clear = {}, set()
        self.plan_path = plan_path
        for line in open(plan_path):
            p = line.split()
            if not p or p[0] != "b":
                continue
            c = tuple(map(int, p[1:4]))
            if p[4] == "minecraft:air":
                self.clear.add(c)                       # dug out by the plan: leaves cleared
            else:
                self.plan[c] = (p[4], int(p[5]), int(p[6]), p[7])
        pal, cells, guessed = survey.load(map_path or survey.MAP)
        names = {int(q.split()[0]): q.split()[1] for q in pal}
        self.state, self.guess = {}, set()
        for c, v in cells.items():
            if v == 0:
                self.state[c] = ("air",)
            elif names.get(v) == WATER:
                self.state[c] = ("water",)
            else:
                self.state[c] = ("solid", names.get(v, "?"))
                if c in guessed:
                    self.guess.add(c)
        self.placed = set()                             # plan blocks built
        self.helpers = set()                            # cobblestone put in for a while
        self.dug = set()                                # ground dug outside the plan, open
        self._replay(record_from)
        self._broken_since(log, record_from)
        self.wet_ok = self._wet_ok()
        self.dig_ok = self._wet_ok(DIG_OK)
        self.skipped = set()
        self.settle()
        self.index_columns()

    # ---- what is known ------------------------------------------------------------------------

    def _replay(self, start):
        """The record from the harbour's start: what was placed, helped, cleared."""
        if not os.path.exists(DONE):
            return
        for line in open(DONE).read().splitlines()[start:]:
            w = line.split()
            if len(w) != 4:
                continue
            c = tuple(map(int, w[1:4]))
            if w[0] in ("placed", "replaced", "lift") and c in self.plan:
                self.placed.add(c)
                self.state[c] = ("solid", self.plan[c][0])
                self.guess.discard(c)
            elif w[0] == "scaffold":
                self.helpers.add(c)
                self.state[c] = ("solid", COBBLE[0])
                self.guess.discard(c)
            elif w[0] == "dug":                         # ground dug to stand in (builders)
                self.dug.add(c)
                self.state[c] = ("air",)
                self.guess.discard(c)
            elif w[0] == "cleared":                     # a cell the plan wants empty, emptied
                self.state[c] = ("air",)
                self.guess.discard(c)
            elif w[0] == "filled":                      # and filled back with dirt
                self.dug.discard(c)
                self.state[c] = ("solid", "minecraft:dirt")
            elif w[0] in ("unscaffold", "breakin", "missing"):
                self.helpers.discard(c)
                self.placed.discard(c)
                self.state.pop(c, None)                 # most likely air; a move will tell

    def _broken_since(self, log, start):
        """Cells the old builders broke on their way (live.log `broke`), never written down as
        records: air, or the river's water by now - unknown until looked at."""
        if not log or not os.path.exists(log):
            return
        for line in open(log, encoding="utf-8", errors="replace"):
            if line.startswith("broke "):
                c = tuple(map(int, line.split()[1:4]))
                if c not in self.placed and c not in self.helpers:
                    self.state.pop(c, None)
                    self.guess.discard(c)

    def _wet_ok(self, path=WET_OK):
        out = set()
        if os.path.exists(path):
            for line in open(path):
                p = line.split()
                if p and p[0] == "box":
                    x0, x1, y0, y1, z0, z1 = map(int, p[1:7])
                    out |= {(x, y, z) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)
                            for z in range(z0, z1 + 1)}
        return out

    def kind(self, c):
        """"air", "water", "solid", "guess" (solid by the survey's reading only), "unknown"."""
        s = self.state.get(c)
        if s is None:
            return "unknown"
        if s[0] == "solid" and c in self.guess:
            return "guess"
        return s[0]

    def name(self, c):
        s = self.state.get(c)
        return s[1] if s and s[0] == "solid" else None

    def learn(self, c, kind, name=None):
        """What a robot found at c: "air", "water" or "solid" (with its name when analyzed)."""
        self.guess.discard(c)
        if kind == "solid":
            old = self.name(c)
            self.state[c] = ("solid", name or old or "?")
        else:
            self.state[c] = (kind,)

    # ---- moving and clicking ------------------------------------------------------------------

    def wet_allowed(self, c):
        """Water a builder may go into: where a planned block replaces it, or a box the user
        allowed."""
        return (c in self.plan and c not in self.placed) or c in self.wet_ok

    def cost(self, c):
        """What it costs a route to go through c: None for never. Known air is cheap; unknown
        dearer (a move finds out, breaking nothing); water only where allowed; nothing solid -
        a builder never digs to travel."""
        k = self.kind(c)
        below = self.name(add(c, "d")) or ""
        if any(w in below.lower() for w in ("fence", "wall")) and "gate" not in below.lower():
            return None                   # a fence's box stands half a block into this cell
        if k == "air":
            return 1
        if k == "unknown":
            return 6
        if k == "water" and self.wet_allowed(c):
            return 2
        return None

    def clickable(self, c, face, side):
        """Whether a click toward `face` meets what is at c, for certain: a placed plan block by
        its shape, a helper, known terrain that is not soft. Never a guess."""
        if c in self.placed:
            return meets(self.plan[c], face, side)
        if c in self.helpers:
            return True
        k = self.kind(c)
        # a stair, slab, fence or pane that is not the plan's: which way it stands is not known
        # here, so no click on it is certain (the simulation, 2026-10-04: leaves clicked on a
        # house stair's top went in elsewhere)
        name = self.name(c) or "?"
        return k == "solid" and not soft(name) and full(name)

    # ---- what is still to do ------------------------------------------------------------------

    def settle(self):
        """The plan's cells left to build. Ground already there that will be hidden once all is
        built - every neighbour solid - is kept (the user's choice, 2026-10-04); so is a cell
        whose ground is already the plan's block."""
        self.skipped = set()
        for c, b in self.plan.items():
            if c in self.placed or b[0] in (TILLED, CROP):
                # farmland is tilled from the ground there, never kept as it is: the field's
                # farmland, every neighbour ground or wheat, was all "kept" and nothing tilled
                # (the field's simulation, 2026-10-04)
                continue
            if self.kind(c) == "solid" and self.name(c) == b[0]:
                self.skipped.add(c)
                continue
            if self.kind(c) == "solid" and not soft(self.name(c) or "?") \
                    and all(self._final_solid(add(c, d)) for d in DIRS):
                self.skipped.add(c)

    def _final_solid(self, n):
        if n in self.plan:
            return full(self.plan[n][0])
        if n in self.clear:
            return False
        return self.kind(n) == "solid" and not soft(self.name(n) or "?")

    def pending(self):
        return [c for c in self.plan if c not in self.placed and c not in self.skipped]

    @property
    def pending_set(self):
        return {c for c in self.plan if c not in self.placed and c not in self.skipped}

    def done(self, c):
        """Whether c holds what it should for the work around it: built, or kept ground."""
        return c in self.placed or c in self.skipped

    # ---- sectors ------------------------------------------------------------------------------

    def sectors(self, size=110, least=3, wide=8, cells=None):
        """The pending cells (or `cells`) cut into sectors: halves along the longer side, at the
        median, while a part holds more than `size` cells or is wider than `wide`, and is wider
        than `least`. -> [(x0, x1, z0, z1)]. Cut by count alone, the harbour's last 160 blocks,
        scattered, made four sectors; one 22 by 20 for 44 blocks: its builder scanned 16,000
        cells a look-over and flew up to its lane and down between stands, while three builders
        sat at home for want of a sector apart from it (the user, 2026-10-04, found the build
        "very slow and full of clumsy moves")."""
        out = []

        def cut(cells):
            xs = [c[0] for c in cells]
            zs = [c[2] for c in cells]
            box = (min(xs), max(xs), min(zs), max(zs))
            wx, wz = box[1] - box[0] + 1, box[3] - box[2] + 1
            if (len(cells) <= size and max(wx, wz) <= wide) or max(wx, wz) <= least:
                out.append(box)
                return
            axis = 0 if wx >= wz else 2
            vals = sorted(c[axis] for c in cells)
            mid = vals[len(vals) // 2]
            if mid == vals[0]:                     # half the cells on the lowest line
                mid = next(v for v in vals if v > vals[0])
            cut([c for c in cells if c[axis] < mid])
            cut([c for c in cells if c[axis] >= mid])

        cells = self.pending() if cells is None else list(cells)
        if cells:
            cut(cells)
        return out

    def index_columns(self):
        """Each column's highest ground and highest planned block, for the lanes over the site."""
        self._ground_top = {}
        for c, s in self.state.items():
            if s[0] != "air" and c[1] > self._ground_top.get((c[0], c[2]), -99):
                self._ground_top[(c[0], c[2])] = c[1]
        self._plan_top = {}
        for c in self.plan:
            if c[1] > self._plan_top.get((c[0], c[2]), -99):
                self._plan_top[(c[0], c[2])] = c[1]

    def column_top(self, x, z):
        """The highest cell of a column that is not air: ground, water, the plan's blocks to
        come (lanes go over what will be built, not only what is)."""
        return max(self._plan_top.get((x, z), -99), self._ground_top.get((x, z), -99))


def in_box(c, box, margin=0):
    x0, x1, z0, z1 = box
    return x0 - margin <= c[0] <= x1 + margin and z0 - margin <= c[2] <= z1 + margin


def apart(a, b, gap):
    """Whether two sector boxes are at least `gap` cells apart (in x or in z)."""
    return a[1] + gap < b[0] or b[1] + gap < a[0] or a[3] + gap < b[2] or b[3] + gap < a[2]
