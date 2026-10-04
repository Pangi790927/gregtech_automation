"""clear.py - plans the clearing before the build: the robot's moves and breaks (3d-draw/DESIGN.md).

    python 3d-draw/design/clear.py            writes data/job.txt, for robot/exec.lua
    python 3d-draw/design/clear.py --apply    puts what the last run broke (data/live.log) into
                                              data/map.txt (the first time, the map as it was is
                                              kept as data/map-before-build.txt)

What goes: every block the plan (data/house.txt) marks as air - the terrain in the way - and
every contour block, which the user had taken away before the build (2026-10-04: "also remove
the contour blocks, you know where those are now"). Blocks the plan builds over stay until their
own block is placed, so nothing loses what it rests on early.

The PC plans and the robot only does: the map is here, whole, and the robot's one memory module is
better spent on the build. The plan:
  - the robot moves only through air the geolyzer saw (or that it broke), never into a liquid;
  - a block goes only once nothing still to go stands on it, so flowers are not knocked loose;
  - it is broken from the nearest air cell beside it (a robot swings ahead, up and down, and
    turns to face a side);
  - nothing that touches water from the side or above is broken: water does not come back (the
    user), and a hole beside it would draw it in. Such a block is refused, and said so.
The robot goes home to empty itself into the mini ME and to charge when it must (exec.lua).
"""
import os, re, sys
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(os.path.dirname(HERE), "data")
CONTOUR = "chisel:antiBlock"

# ---- the map ----------------------------------------------------------------------------------

MAP = os.path.join(DATA, "map.txt")
lines = open(MAP).read().splitlines()
XMIN, XMAX, YMIN, YMAX, ZMIN, ZMAX = map(int, re.findall(r"-?\d+", lines[1]))
NAMES, LAYERS, GUESSED = {}, {}, {}
for line in lines:
    if line.startswith("palette"):
        _, i, name, meta, *_ = line.split()
        NAMES[int(i)] = name
    elif line.startswith("layer") or line.startswith("guessed"):
        kind, y, data = line.split(" ", 2)
        (LAYERS if kind == "layer" else GUESSED)[int(y)] = [
            list(map(int, r.split(","))) for r in data.split(";")]


def inside(x, y, z):
    return XMIN <= x <= XMAX and YMIN <= y <= YMAX and ZMIN <= z <= ZMAX


def value(x, y, z):
    """The map's id at a position: 0 air, -1 not mapped, None outside the box."""
    return LAYERS[y][z - ZMIN][x - XMIN] if inside(x, y, z) else None


def name(x, y, z):
    v = value(x, y, z)
    return NAMES[v] if v and v > 0 else None


# ---- --apply: what the last run broke goes into the map --------------------------------------

if "--apply" in sys.argv:
    keep = os.path.join(DATA, "map-before-build.txt")
    if not os.path.exists(keep):
        open(keep, "w", newline="\n").write("\n".join(lines) + "\n")
    gone = 0
    for line in open(os.path.join(DATA, "live.log"), encoding="utf-8"):
        m = re.match(r"^broke (-?\d+) (-?\d+) (-?\d+)$", line.strip())
        if m:
            x, y, z = map(int, m.groups())
            if value(x, y, z):
                LAYERS[y][z - ZMIN][x - XMIN] = 0
                if y in GUESSED:
                    GUESSED[y][z - ZMIN][x - XMIN] = 0
                gone += 1
    out = []
    for line in lines:
        if line.startswith("layer") or line.startswith("guessed"):
            kind, y, _ = line.split(" ", 2)
            rows = (LAYERS if kind == "layer" else GUESSED)[int(y)]
            line = f"{kind} {y} " + ";".join(",".join(map(str, r)) for r in rows)
        out.append(line)
    open(MAP, "w", newline="\n").write("\n".join(out) + "\n")
    print(f"apply: {gone} broken blocks are air in data/map.txt now")
    sys.exit(0)

# ---- what goes --------------------------------------------------------------------------------

targets = set()
for line in open(os.path.join(DATA, "house.txt")):
    p = line.split()
    if p and p[0] == "b" and p[4] == "minecraft:air":
        targets.add(tuple(map(int, p[1:4])))
for y in LAYERS:
    for z in range(ZMIN, ZMAX + 1):
        for x in range(XMIN, XMAX + 1):
            guessed = y in GUESSED and GUESSED[y][z - ZMIN][x - XMIN]
            if name(x, y, z) == CONTOUR and not guessed:
                targets.add((x, y, z))
targets = {t for t in targets if value(*t) and value(*t) > 0}      # only what is there

SIDES = ((1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1))
refused = []
for t in sorted(targets):
    x, y, z = t
    if any(name(x + dx, y, z + dz) == "minecraft:water" for dx, _, dz in SIDES) \
            or name(x, y + 1, z) == "minecraft:water":
        refused.append(t)
targets -= set(refused)

# ---- the route --------------------------------------------------------------------------------

# Directions as exec.lua takes them: n s e w u d, x east, y up, z south.
DIRS = {"n": (0, 0, -1), "s": (0, 0, 1), "e": (1, 0, 0), "w": (-1, 0, 0), "u": (0, 1, 0),
        "d": (0, -1, 0)}
air = set()
for y in LAYERS:
    for z in range(ZMIN, ZMAX + 1):
        for x in range(XMIN, XMAX + 1):
            if value(x, y, z) == 0:
                air.add((x, y, z))


def free(t):
    """Whether nothing still to go stands on t: the cell above is not a target."""
    return (t[0], t[1] + 1, t[2]) not in targets


def nearest(start):
    """Breadth-first through the air to the nearest cell beside a target free to go. Returns the
    moves there, the direction to swing, and the target; None when none is reachable."""
    prev = {start: None}
    queue = deque([start])
    while queue:
        c = queue.popleft()
        for d, (dx, dy, dz) in DIRS.items():
            t = (c[0] + dx, c[1] + dy, c[2] + dz)
            if t in targets and free(t):
                moves = []
                while prev[c]:
                    moves.append(prev[c][1])
                    c = prev[c][0]
                return moves[::-1], d, t
        for d, (dx, dy, dz) in DIRS.items():
            n = (c[0] + dx, c[1] + dy, c[2] + dz)
            if n in air and n not in prev:
                prev[n] = (c, d)
                queue.append(n)
    return None


def route(start, goal):
    prev = {start: None}
    queue = deque([start])
    while queue:
        c = queue.popleft()
        if c == goal:
            moves = []
            while prev[c]:
                moves.append(prev[c][1])
                c = prev[c][0]
            return moves[::-1]
        for d, (dx, dy, dz) in DIRS.items():
            n = (c[0] + dx, c[1] + dy, c[2] + dz)
            if n in air and n not in prev:
                prev[n] = (c, d)
                queue.append(n)
    return None


HOME = (0, 0, 0)
pos, job, moves, broken = HOME, [], 0, 0
while targets:
    found = nearest(pos)
    if not found:
        break
    path, d, t = found
    for m in path:
        job.append(f"m {m}")
        dx, dy, dz = DIRS[m]
        pos = (pos[0] + dx, pos[1] + dy, pos[2] + dz)
    moves += len(path)
    job.append(f"b {d} {t[0]} {t[1]} {t[2]} {name(*t)}")
    targets.discard(t)
    air.add(t)
    broken += 1
back = route(pos, HOME)
assert back is not None, "no way home"
job += [f"m {m}" for m in back]
moves += len(back)
job.append("home")

with open(os.path.join(DATA, "job.txt"), "w", newline="\n") as f:
    f.write("# 3d-draw job: the clearing (design/clear.py); m <dir>, b <dir> x y z name, home\n")
    f.write("\n".join(job) + "\n")
print(f"clear: {broken} blocks to break, {moves} moves; written to data/job.txt")
if targets:
    print(f"unreachable through known air ({len(targets)}):", sorted(targets))
if refused:
    print(f"refused, touching water ({len(refused)}):", refused)
