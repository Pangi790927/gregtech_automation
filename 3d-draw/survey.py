"""survey.py - the scout maps an area into data/map.txt, the PC holding the map
(3d-draw/docs/scouts.md, "The scout and the survey").

    python 3d-draw/survey.py <scout> <x0> <z0> <x1> <z1> [--y -14 17]
    python 3d-draw/survey.py <scout>        the zone loaded (zones.py): all of data/map.txt's box
    ... --map data/map-tom.txt --park 1,-1,0
                                            another scout at once: its own working map (seeded
                                            with a copy of the zone, so it knows its way out),
                                            and its own place at the charger. Two scouts on one
                                            map file save over each other.
    ... --taller                            columns scanned to a lower top and solid there, again
                                            up to the --y top: air over ridges, to fly over them
    ... --minutes 110                       ends at a waypoint after that long (MINUTES), before
                                            the 2-hour limit on background jobs; run it again
    python 3d-draw/survey.py <scout> ... + <scout> ...
                                            several scouts from one program, each a coroutine
                                            (asyncio, as the builders' crew; the user,
                                            2026-10-04: "same with the scouts")

Afterwards `python 3d-draw/zones.py save` keeps what it found in the chunk files.

The user, 2026-10-04: "I've added a scouter robot for you, with it you can start expanding the
area known". The scout runs robot/server.lua (rlink.py opens it); this program flies it over a
grid of waypoints, and at each one scans the columns within 8 blocks that the map does not have
yet. The geolyzer reads air as exactly 0 and liquids at 100 or so, so what is air and what is
water is exact; other blocks are named by hardness only (noise grows with distance, which is why
the scans are near), and marked guessed. Blocks the robot already named keep their names.

It moves only through air it has scanned, so it never meets what it does not know; a step that
fails anyway marks that cell solid, and it goes around. Its chunkloader is on while it is out.
When its energy would not get it home with a margin it goes back to the charger (it parks on
top of the charger, at 1 1 0) and comes out again. The map is saved after every waypoint.
"""
import asyncio, os, re, sys, traceback
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rlink                                                  # noqa: E402

MAP = os.path.join(HERE, "data", "map.txt")
DIRS = {"n": (0, 0, -1), "s": (0, 0, 1), "e": (1, 0, 0), "w": (-1, 0, 0), "u": (0, 1, 0),
        "d": (0, -1, 0)}
SAVE_EVERY = 5                    # waypoints between saves: a big map takes seconds to write
REACH = 10                        # scan within REACH of a waypoint, and waypoints REACH apart:
                                  # the next is always inside what the last one scanned
PER_STEP, MARGIN = 12, 6000       # the way home: 12 a step (7 measured), plus a margin
PARK = (1, 1, 0)                  # on top of the charger
# Bounds (the audit, 2026-10-04: every retry loop bounded, jobs ended before the 2-hour limit
# on background jobs cuts them mid-flight): tries of one stop or waypoint, and charges or link
# drops with no progress between them; a job's minutes; the cells one route search may visit.
TRIES, MINUTES, ROUTE_LIMIT = 3, 110, 3000000
# Hardness, read off what the robot named on this site: the guess for a block never named.
GUESS = [(0.35, "BiomesOPlenty:leaves4"), (0.8, "minecraft:dirt"), (1.75, "minecraft:stone"),
         (2.6, "minecraft:log"), (99.0, "minecraft:stone")]


# ---- the map ----------------------------------------------------------------------------------

def load(path=None):
    lines = open(path or MAP).read().splitlines()
    x0, x1, y0, y1, z0, z1 = map(int, re.findall(r"-?\d+", lines[1]))
    pal, cells, guessed = [], {}, set()
    for line in lines:
        kind, _, rest = line.partition(" ")
        if kind == "palette":
            pal.append(rest)
        elif kind in ("layer", "guessed"):
            y, data = rest.split(" ", 1)
            for zi, row in enumerate(data.split(";")):
                for xi, v in enumerate(row.split(",")):
                    c = (x0 + xi, int(y), z0 + zi)
                    if kind == "layer" and int(v) >= 0:
                        cells[c] = int(v)
                    elif kind == "guessed" and v == "1":
                        guessed.add(c)
    return pal, cells, guessed


def save(pal, cells, guessed, path=None):
    xs = [c[0] for c in cells]; ys = [c[1] for c in cells]; zs = [c[2] for c in cells]
    x0, x1, y0, y1, z0, z1 = min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)
    out = ["# 3d-draw map 1", f"box x {x0} {x1} y {y0} {y1} z {z0} {z1}"]
    out += ["palette " + p for p in pal]
    for kind in ("layer", "guessed"):
        for y in range(y0, y1 + 1):
            rows = []
            for z in range(z0, z1 + 1):
                if kind == "layer":
                    rows.append(",".join(str(cells.get((x, y, z), -1)) for x in range(x0, x1 + 1)))
                else:
                    rows.append(",".join("1" if (x, y, z) in guessed else "0"
                                         for x in range(x0, x1 + 1)))
            out.append(f"{kind} {y} " + ";".join(rows))
    path = path or MAP
    tmp = path + ".tmp"
    open(tmp, "w", newline="\n").write("\n".join(out) + "\n")
    os.replace(tmp, path)


def palette_id(pal, name, hardness):
    for i, p in enumerate(pal):
        if p.split()[1] == name:
            return int(p.split()[0])
    i = max(int(p.split()[0]) for p in pal) + 1
    pal.append(f"{i} {name} 0 {hardness:.2f} guessed")
    return i


# ---- flying -----------------------------------------------------------------------------------

def add(c, d):
    v = DIRS[d]
    return (c[0] + v[0], c[1] + v[1], c[2] + v[2])


# Where a scout may be (the user, 2026-10-04: "just map the terrain ... only allow it if under the
# sun or under a tree (outside of work area ofc)", then "in built known area you can pass under
# buildings, I don't care, but exploration needs sunlight"). Exploring - surveying or naming
# outside the known, built area - a cell must see the sky: nothing above it in its column but
# air, or leaves and logs (a tree). In the known area (the work zone round home and the station)
# any known air is fine for travel. Tunnels, caves, overhangs out in the terrain: refused.
KNOWN_AREA = (-31, 16, -43, 4)     # robot x0, x1, z0, z1: the work zone, chunks 14..16 x 6..8
TOP_Y = 80                         # above this nothing is mapped: the sky (scans reach 75)


def in_known_area(c, area=KNOWN_AREA):
    return area[0] <= c[0] <= area[1] and area[2] <= c[2] <= area[3]


def under_sky(cells, c, tree=(), top=TOP_Y):
    """Whether nothing above c, up to `top`, is known to be anything but air - or, with `tree`
    (leaf and log ids), leaves and logs. Scouts scan whole columns, so a cell they explore has
    its column known; a cell above not scanned is above the scans' top, the sky."""
    x, y, z = c
    for yy in range(y + 1, top + 1):
        v = cells.get((x, yy, z))
        if v is not None and v != 0 and v not in tree:
            return False
    return True


def may_be(cells, c, tree=(), area=KNOWN_AREA, refused=()):
    """Whether a scout may be at c: known air, not refused (the tunnels dug on 2026-10-04), and
    in the known area or under the sky or a tree."""
    if cells.get(c) != 0 or c in refused:
        return False
    return in_known_area(c, area) or under_sky(cells, c, tree)


REFUSED = os.path.join(HERE, "data", "refused.txt")


def refused_cells(path=REFUSED):
    """Cells no scout may be in, robot coordinates, `x y z` a line: the tunnels the scouts dug
    under the forest on 2026-10-04, and the water that came into them."""
    out = set()
    if os.path.exists(path):
        for line in open(path):
            p = line.split()
            if len(p) >= 3 and not line.startswith("#"):
                out.add(tuple(map(int, p[:3])))
    return out


class Rules:
    """Where a scout may be, for one map: `explore(c)` - a naming stop or a survey's waypoint:
    known air, not refused, under the sky or a tree; `travel(c)` - on the way: the same, or any
    known air in the known area (home, the station, the work zone). A tree is leaves and logs
    the scouts NAMED: a guessed "leaves" may be ground (2026-10-04), so it blocks the sky. What
    blocks a column is cached; `forget()` after a scan changes the map."""

    def __init__(self, cells, pal, guessed, refused=None, area=KNOWN_AREA):
        self.cells, self.guessed, self.area = cells, guessed, area
        self.tree = {int(p.split()[0]) for p in pal
                     if any(k in p.split()[1].lower() for k in ("leaves", "log"))}
        self.refused = refused_cells() if refused is None else set(refused)
        self.top = {}

    def forget(self):
        self.top.clear()

    def blocked_to(self, x, z):
        """The highest y in the column with something that hides the sky (-99: none known)."""
        k = (x, z)
        if k not in self.top:
            t = -99
            for y in range(TOP_Y, -15, -1):
                v = self.cells.get((x, y, z))
                if v and v > 0 and not (v in self.tree and (x, y, z) not in self.guessed):
                    t = y
                    break
            self.top[k] = t
        return self.top[k]

    def sky(self, c):
        return c[1] > self.blocked_to(c[0], c[2])

    def explore(self, c):
        return self.cells.get(c) == 0 and c not in self.refused and self.sky(c)

    def travel(self, c):
        return self.cells.get(c) == 0 and c not in self.refused and \
            (in_known_area(c, self.area) or self.sky(c))

    def pocket(self, start, limit=4000):
        """The air round `start` a scout may not travel through, as far as it goes: the one way
        out of a tunnel it is in, allowed once (go_charge)."""
        out, q = {start}, deque([start])
        while q and len(out) < limit:
            c = q.popleft()
            for d in DIRS:
                n = add(c, d)
                if n not in out and self.cells.get(n) == 0 and not self.travel(n):
                    out.add(n)
                    q.append(n)
        return out


def route(cells, start, goal_test, limit=6000, through=(), ok=None):
    """Breadth-first through known air; the moves to the first cell goal_test accepts. `ok`: a
    cell is only entered if ok(cell) (Rules.travel)."""
    prev = {start: None}
    q = deque([start])
    while q:
        c = q.popleft()
        if goal_test(c):
            out = []
            while prev[c]:
                c, d = prev[c]
                out.append(d)
            return out[::-1]
        if len(prev) > ROUTE_LIMIT:                     # the 15x15 chunks: long ways
            break
        for d in DIRS:
            n = add(c, d)
            if n not in prev and (cells.get(n) == 0 or cells.get(n) in through) \
                    and (ok is None or ok(n)):
                prev[n] = (c, d)
                q.append(n)
    return None


async def fly(scout, cells, moves, home=False):
    """Moves along a route, a few at a time; a step that fails marks that cell unknown. `home`:
    the way home, which the robot lets it take below its energy floor (robot/server.lua)."""
    for i in range(0, len(moves), 12):
        part = moves[i:i + 12]
        cmds = ["move " + d + (" home" if home else "") for d in part]
        for d, (status, values) in zip(part, await scout.batch(cmds)):
            if status == "err":
                print(f"  {scout.name}: blocked toward {d} at {scout.pos}: {values}", flush=True)
                if "low energy" in values:
                    # The robot's own floor (its way home is long): it goes to charge. The cell is
                    # not marked: marking every side unknown once left Tom no way home
                    # (2026-10-04).
                    scout.low = True
                    return False
                cells[add(tuple(scout.pos), d)] = -1          # not air after all: unknown
                return False
            if status == "skip":
                return False
    return True


async def energy(scout):
    return int((await scout.run("energy")).split()[0])


async def chunk_on(scout):
    """The chunkloader on, at every job's start and every reconnect, and whether it is: robot/
    server.lua's `chunk` answers isActive() after setting it (setActive's own `false` only
    means "already on"). A scout whose chunk unloads drops off the relay (Cairol, 2026-10-04).
    Said loudly when off, for the watcher (probe.py) to see; the job goes on."""
    try:
        got = (await scout.run("chunk on")).strip()
    except rlink.RobotError as e:
        got = f"refused ({e})"
    if got != "true":
        print(f"  {scout.name}: CHUNKLOADER OFF: {got}", flush=True)
    return got == "true"


async def leaf_ahead(scout, cells, d):
    """Whether the block toward d is leaves, read with `analyze` there and then - never the
    map's word: a map's "leaves" can be a hardness guess, and swinging at guesses dug into the
    ground under the house's forest (the user, 2026-10-04: "your assumed leafs is ground, don't
    break ground"). Anything else is written into the map as solid, so the way goes round it."""
    at = tuple(scout.pos)
    n = add(at, d)
    got = (await scout.run(f"analyze {d}")).split()
    if got and "leaves" in got[0].lower():
        return True
    if got and got[0] not in ("air", "minecraft:air"):
        if not cells.get(n):
            cells[n] = -1                                     # solid, unnamed: not flown into
    return False


async def fly_through(scout, cells, path, leaves):
    """The way home: as fly(home=True); where the map says leaves, the block is analyzed and
    broken only if it is leaves (leaf_ahead), else the way is given up and found again."""
    if not leaves:
        return await fly(scout, cells, path, home=True)
    at = tuple(scout.pos)
    for d in path:
        n = add(at, d)
        if cells.get(n) in leaves:
            if not await leaf_ahead(scout, cells, d):
                return False
            await scout.batch([f"swing {d}"])
            cells[n] = 0
        if not await fly(scout, cells, [d], home=True):
            return False
        at = n
    return True


SCAN_COST = 10                  # energy a geolyzer scan takes (OpenComputers' geolyzerScanCost)


def home_cost(at, park):
    """The energy the way home takes from `at`, by its length as the crow flies, plus MARGIN."""
    return (sum(abs(a - b) for a, b in zip(at, park)) + 12) * PER_STEP + MARGIN


async def air_round(scout, cells, r=10):
    """The air round the scout, scanned into the map (air only: what is solid is left as the map
    has it). A scout stopped between two saves stands where its map knows nothing, and no way
    home was found from there (Cairol, 2026-10-04, at -82 22 -108). Scans stay within the
    geolyzer's reach, 32 up and down; a column all air is a chunk not loaded, and left."""
    at = tuple(scout.pos)
    cols = [(dx, dz) for dx in range(-r, r + 1) for dz in range(-r, r + 1)]
    # Never below the way home: three rescues' scans took Cairol from 39181 to 2789 in a pocket
    # with no way out (2026-10-04). As many columns as the energy over that allows, nearest first.
    spare = await energy(scout) - home_cost(at, getattr(scout, "park", PARK))
    cols.sort(key=lambda c: abs(c[0]) + abs(c[1]))
    cols = cols[:max(0, int(spare // SCAN_COST))]
    if not cols:
        print(f"  {scout.name}: no energy to spare for a scan round", flush=True)
        return 0
    found = 0
    lo = -min(32, at[1] + 14)
    h = min(64, 32 - lo + 1)
    cells[at] = 0
    for i in range(0, len(cols), 24):
        part = cols[i:i + 24]
        res = await scout.batch([f"scan {dx} {dz} {lo} {h}" for dx, dz in part])
        for (dx, dz), (status, values) in zip(part, res):
            if status != "ok":
                continue
            vals = [float(v) for v in values.split(",")]
            if not any(vals):
                continue
            for k, v in enumerate(vals):
                c = (at[0] + dx, at[1] + lo + k, at[2] + dz)
                if v == 0 and cells.get(c, -1) <= 0 and cells.get(c) != 0:
                    cells[c] = 0
                    found += 1
    return found


async def go_charge(scout, cells, leaves=(), rules=None):
    """Home to its charger (scout.park, else PARK) and charged there. With no way home known,
    the air round it is scanned first, and again after each failed try."""
    park = getattr(scout, "park", PARK)
    print(f"  {scout.name}: home to charge", flush=True)
    scout.status("charging", f"flying home to {park[0]} {park[1]} {park[2]}",
                 getattr(scout, "long", ""))
    for k in range(16):                      # a failed step marks one cell: room for several
        # Through leaves too where they may be broken (name.py --leaves): Tom went in under the
        # canopy and found no way home through air alone (2026-10-04).
        ok = None
        if rules is not None:
            rules.forget()
            way_out = rules.pocket(tuple(scout.pos)) if not rules.travel(tuple(scout.pos)) \
                else set()
            ok = lambda c: c in way_out or rules.travel(c)          # noqa: E731
        path = route(cells, tuple(scout.pos), lambda c: c == park, through=leaves, ok=ok)
        if path is None and not getattr(scout, "scanned_at", None) == tuple(scout.pos):
            print(f"  {scout.name}: no way home known from {scout.pos}; scanning round",
                  flush=True)
            scout.scanned_at = tuple(scout.pos)
            if await air_round(scout, cells):
                continue                              # something new: route again
        if path is None:
            # A scan round that found nothing: no way home through known air. It used to break
            # and "charge" where it stood, and the caller asked again and again; now the job
            # ends, said loudly, for a person to look (a scout must never be stranded).
            raise SystemExit(f"{scout.name}: STRANDED, no way home known from {scout.pos}")
        if path is not None and await fly_through(scout, cells, path, leaves):
            break
    else:
        raise SystemExit(f"{scout.name} cannot get back to the charger from {scout.pos}")
    print(f"  {scout.name} charged:", await scout.run("charge 0.95 120"), flush=True)


# ---- the survey -------------------------------------------------------------------------------

def unscanned_columns(cells, box):
    """The columns in box = (x0, z0, x1, z1) with nothing solid known: never scanned, or known
    only as air - air_round's rescue scans keep air alone, and every cell a scout stood in is
    air. Such a column counted as scanned and was never scanned whole; with no ground known, a
    waypoint over it had nowhere to hover, and 95 columns in the north-west were left
    (2026-10-04)."""
    X0, Z0, X1, Z1 = box
    ground = {(c[0], c[2]) for c, v in cells.items() if v and v > 0}
    return {(x, z) for x in range(X0, X1 + 1) for z in range(Z0, Z1 + 1)} - ground


THIN = 4                        # air under a column's known top a scout needs to hover over it:
                                # hover_over wants the ground 3 to 6 below


def taller_columns(cells, box, y1):
    """The known columns in box = (x0, z0, x1, z1) that `--taller` scans again up to y1: those
    scanned before to a lower top and still solid there (the user, 2026-10-04: "why are the
    scouts idling at base when there is still un-prospected land" - Cairol had stopped with 9197
    columns past ground higher than his scans reached), and those whose ground, or a neighbour's,
    comes within THIN of that top. Past the mountain the old top (49) lay along the ridge: the
    columns there held 0 to 3 cells of air under it, the new ones beside them had air from 50 up,
    and no step joined the two - the air over the mountain was an island, and 2864 columns were
    left unscanned (2026-10-04)."""
    X0, Z0, X1, Z1 = box
    tops, ground = {}, {}
    for (x, y, z), v in cells.items():
        if X0 - 1 <= x <= X1 + 1 and Z0 - 1 <= z <= Z1 + 1:
            if y > tops.get((x, z), (-99, 0))[0]:
                tops[(x, z)] = (y, v)
            if v > 0 and y > ground.get((x, z), -99):
                ground[(x, z)] = y

    def wanted(k):
        y, v = tops[k]
        if y >= y1 or not (X0 <= k[0] <= X1 and Z0 <= k[1] <= Z1):
            return False
        if v != 0:
            return True
        near = [ground.get((k[0] + a, k[1] + b), -99)
                for a, b in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1))]
        return max(near) >= y - THIN
    return {k for k in tops if wanted(k)}


async def survey(prefix, box, y0, y1, map_path, park, taller=False, minutes=MINUTES):
    """One scout over one box, on its own map: a coroutine, so one program flies several. After
    `minutes` it ends at a waypoint, and the next job goes on from there."""
    X0, Z0, X1, Z1 = box
    pal, cells, guessed = load(map_path)
    # What the user built and told of (zones.FIXED), over whatever the scans said: the station's
    # new glass ring stood over Cairol's place at the charger, and his map had air there
    # (2026-10-04).
    import zones
    ax, ay, az = zones.anchor()
    for (x, y, z), v in zones.fixed().items():
        c = (x - ax, y - ay, z - az)
        # None: air the build dug out (zones.fixed reads data/built.txt too since 2026-10-04)
        cells[c] = 0 if v is None else palette_id(pal, v[0], v[2])
        guessed.discard(c)
    todo = unscanned_columns(cells, box)
    if taller:
        todo |= taller_columns(cells, box, y1)
    total = len(todo)
    print(f"survey {prefix}: {len(todo)} columns to scan in x {X0}..{X1}, z {Z0}..{Z1}, "
          f"y {y0}..{y1}", flush=True)

    async def connect():
        scout = await rlink.reach(prefix, tries=30)
        scout.park = park
        await chunk_on(scout)
        return scout
    scout = await connect()
    print(f"{scout.name} at", scout.pos, flush=True)
    water = palette_id(pal, "minecraft:water", 100.0)
    suspect = set()                                           # all air: an unloaded chunk

    async def scan_around(at):
        near = sorted(c for c in todo if max(abs(c[0] - at[0]), abs(c[1] - at[2])) <= REACH)
        # The geolyzer reaches 32 up and down (OpenComputers' geolyzerRange) and 64 blocks a scan:
        # a scan past that fails, and with it the rest of its batch - out west, flying high over
        # higher ground, every scan did, unnoticed (2026-10-04).
        lo, hi = max(y0, at[1] - 32), min(y1, at[1] + 32)
        h = min(hi - lo + 1, 64)
        for i in range(0, len(near), 24):
            part = near[i:i + 24]
            res = await scout.batch([f"scan {x - at[0]} {z - at[2]} {lo - at[1]} {h}"
                                     for x, z in part])
            for (x, z), (status, values) in zip(part, res):
                if status == "err" and "low energy" in values:
                    # The robot's floor (its trail home, robot/server.lua) refuses scans too:
                    # the waypoint's columns were dropped unscanned (2026-10-04). It charges, and
                    # the waypoint is done again (the main loop).
                    scout.low = True
                    return 0
                if status != "ok":
                    if status == "err" and not getattr(scout, "told", False):
                        print(f"  {scout.name}: a scan failed at {at}: {values}", flush=True)
                        scout.told = True
                    continue
                vals = [float(v) for v in values.split(",")]
                if not any(vals):
                    # Air from top to bottom: there is no such column here. It is a chunk that is
                    # not loaded - the geolyzer reads those as air (chunk 16 9 did, 2026-10-04).
                    # Left to scan again, not believed.
                    suspect.add((x, z))
                    continue
                for k, v in enumerate(vals):
                    c = (x, lo + k, z)
                    if c in cells and c not in guessed and cells[c] > 0:
                        continue                              # named before: kept
                    if c == tuple(at):
                        cells[c] = 0
                    elif v == 0:
                        cells[c] = 0
                        guessed.discard(c)
                    elif v >= 90:
                        cells[c], _ = water, guessed.add(c)
                    else:
                        name = next(n for limit, n in GUESS if v < limit)
                        if name == "minecraft:dirt" and vals[k + 1:k + 2] == [0.0]:
                            name = "minecraft:grass"          # the top of the ground
                        cells[c], _ = palette_id(pal, name, v), guessed.add(c)
                todo.discard((x, z))
        return len(near)

    await scan_around(scout.pos)                              # what is round the charger
    save(pal, cells, guessed, map_path)
    rules = Rules(cells, pal, guessed)                        # under the sky (the user's rule)
    points = {(x, z) for x in range(X0 + REACH // 2, X1 + 1, REACH)
              for z in range(Z0 + REACH // 2, Z1 + 1, REACH)}

    def hover_over(wx, wz):
        """A cell in that column 3 to 6 above the ground."""
        return lambda c: c[0] == wx and c[2] == wz and cells.get((c[0], c[1] - 2, c[2])) == 0 \
            and any(cells.get((c[0], c[1] - k, c[2]), 0) > 0 for k in range(3, 7))

    stops = 0
    # Bounded (the audit, 2026-10-04): a waypoint is tried again at most TRIES times; charges and
    # link drops with no column scanned between them end the job, to be looked at.
    tries, idle_charges, drops, was = {}, 0, 0, len(todo)
    ends = asyncio.get_running_loop().time() + minutes * 60
    timed_out = False

    def again(p):
        tries[p] = tries.get(p, 0) + 1
        if tries[p] < TRIES:
            points.add(p)
    while points:
        if len(todo) != was:
            idle_charges = drops = 0
            was = len(todo)
        if idle_charges > TRIES or drops > 2 * TRIES:
            raise SystemExit(f"{scout.name}: {idle_charges} charges and {drops} link drops with "
                             f"no column scanned between them, at {scout.pos}")
        if asyncio.get_running_loop().time() >= ends:
            timed_out = True
            break
        try:
            # The nearest waypoint it can get to now, through what it has scanned: one search
            # for them all (one a waypoint was far too slow over the 15x15 chunks).
            points = {p for p in points
                      if any(max(abs(c[0] - p[0]), abs(c[1] - p[1])) <= REACH for c in todo)}
            pset = set(points)

            def over_any(c):
                return (c[0], c[2]) in pset and hover_over(c[0], c[2])(c) and rules.explore(c)
            rules.forget()
            path = route(cells, tuple(scout.pos), over_any, ok=rules.travel)
            if path is None:
                break
            end_at = tuple(scout.pos)
            for d in path:
                end_at = add(end_at, d)
            wx, wz = end_at[0], end_at[2]
            points.discard((wx, wz))
            back = (abs(wx - park[0]) + abs(wz - park[2]) + 12) * PER_STEP + MARGIN
            scout.long = f"scanned {total - len(todo)} of {total} columns"
            if await energy(scout) < back + len(path) * PER_STEP:
                await go_charge(scout, cells, rules=rules)
                idle_charges += 1
                path = route(cells, tuple(scout.pos), hover_over(wx, wz), ok=rules.travel)
                if path is None:
                    continue
            scout.status("surveying", f"waypoint {wx} {wz}", scout.long)
            if not await fly(scout, cells, path) and getattr(scout, "low", False):
                scout.low = False
                again((wx, wz))                               # not reached: still to do
                await go_charge(scout, cells, rules=rules)
                idle_charges += 1
                continue
            n = await scan_around(scout.pos)
            if getattr(scout, "low", False):                  # refused under the floor
                scout.low = False
                again((wx, wz))
                await go_charge(scout, cells, rules=rules)
                idle_charges += 1
                continue
            stops += 1
            if stops % SAVE_EVERY == 0:
                save(pal, cells, guessed, map_path)
            print(f"{scout.name} at {scout.pos}: {n} columns scanned, {len(todo)} to go, "
                  f"energy {getattr(scout, 'energy', '?')}", flush=True)
        except (rlink.RobotError, OSError) as e:
            # A dropped link (its chunk unloaded, the relay, an answer that never came): the
            # work so far kept, then on from where the robot says it is.
            print(f"  {prefix}: the link dropped ({e}); reconnecting", flush=True)
            save(pal, cells, guessed, map_path)
            drops += 1
            await asyncio.sleep(10)
            scout = await connect()
    save(pal, cells, guessed, map_path)
    if timed_out:                                             # left at its waypoint
        await scout.close()
        print(f"survey {prefix}: time's up ({minutes:.0f} min): {len(todo)} columns to go; at "
              f"{scout.pos}", flush=True)
        return
    await go_charge(scout, cells, rules=rules)
    print(await scout.run("chunk off"), flush=True)
    await scout.close()
    save(pal, cells, guessed, map_path)
    scout.status("done", "parked at the charger", f"survey done: {len(todo)} columns left")
    print(f"survey {prefix} done: {len(todo)} columns not scanned; {len(suspect)} read all air "
          f"(a chunk not loaded?): {sorted(suspect)[:12]}", flush=True)


def parse(args):
    """One scout's arguments: <scout> [<x0> <z0> <x1> <z1>] [--y a b] [--map M] [--park x,y,z]
    [--taller] [--minutes N]."""
    map_path, park, y0, y1, minutes = MAP, PARK, -14, 17, MINUTES
    taller = "--taller" in args
    if taller:
        args.remove("--taller")
    if "--minutes" in args:
        i = args.index("--minutes")
        minutes = float(args[i + 1])
        del args[i:i + 2]
    if "--map" in args:
        i = args.index("--map")
        map_path = os.path.abspath(args[i + 1])
        del args[i:i + 2]
    if "--park" in args:
        i = args.index("--park")
        park = tuple(int(v) for v in args[i + 1].split(","))
        del args[i:i + 2]
    if "--y" in args:
        i = args.index("--y")
        y0, y1 = int(args[i + 1]), int(args[i + 2])
        del args[i:i + 3]
    if len(args) >= 5:
        box = tuple(map(int, args[1:5]))
    else:                                                     # the zone loaded
        nums = list(map(int, re.findall(r"-?\d+", open(map_path).read().splitlines()[1])))
        box = (nums[0], nums[4], nums[1], nums[5])
    return args[0], box, y0, y1, map_path, park, taller, minutes


async def main():
    groups, cur = [], []
    for a in sys.argv[1:]:
        if a == "+":
            groups.append(cur)
            cur = []
        else:
            cur.append(a)
    groups.append(cur)

    async def one(g):
        try:
            await survey(*parse(g))
        except (Exception, SystemExit):      # one scout stopping must not end the other
            print(f"  {g[0]} stopped:\n{traceback.format_exc()}", flush=True)
    await asyncio.gather(*(one(g) for g in groups))


if __name__ == "__main__":
    asyncio.run(main())
