"""map_from_log.py - rebuilds data/map.txt from a mapper run's events, for when the robot could not
save its map (3d-draw/docs/map.md, "2. The map").

    python 3d-draw/design/map_from_log.py <log>     the log run.py printed or wrote (live.log)

On 2026-10-04 an extend run (the strip north of the contour, for the barn) stopped with "not
enough memory" while naming blocks: the robot has one memory module, and the map had grown to
x -17..6, z -13..8. Everything it had learned was already sent: the box (`box`), the palette
(`pal`), what the geolyzer read in each new column (`scan x z` - `.` air, `#` solid, `~` liquid,
from y min up), every block named or broken (`blk x y z id`) and every guess (`guess`). So the map
is the last `box`, filled from the map before the run (an extend run sends its old cells again,
but only the solid ones: the air it does not) and then from those events in order. A solid cell
the robot never got to name is guessed as it would have: dirt, or water where the scan read a
liquid.

The map as it was is kept as data/map-before-<n>.txt.
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(os.path.dirname(HERE), "data")


def read_map(path):
    """A map file's cells, {(x, y, z): id}, and the guessed ones."""
    lines = open(path).read().splitlines()
    x0, _, _, _, z0, _ = map(int, re.findall(r"-?\d+", lines[1]))
    cells, guessed = {}, set()
    for line in lines:
        kind, _, rest = line.partition(" ")
        if kind in ("layer", "guessed"):
            y, data = rest.split(" ", 1)
            for zi, row in enumerate(data.split(";")):
                for xi, v in enumerate(row.split(",")):
                    k = (x0 + xi, int(y), z0 + zi)
                    if kind == "layer" and int(v) >= 0:
                        cells[k] = int(v)
                    elif kind == "guessed" and v == "1":
                        guessed.add(k)
    return cells, guessed


base = os.path.join(DATA, "map.txt")
box, pal = None, {}
cells, guessed = read_map(base)
for line in open(sys.argv[1], encoding="utf-8"):
    p = line.split()
    if not p:
        continue
    if p[0] == "box" and len(p) == 7:
        box = list(map(int, p[1:]))
    elif p[0] == "pal" and len(p) >= 6:
        pal[int(p[1])] = p[2:6]
    elif p[0] == "scan" and box:
        x, z, col = int(p[1]), int(p[2]), p[3]
        for i, ch in enumerate(col):
            if ch == ".":
                cells[(x, box[2] + i, z)] = 0
            elif (x, box[2] + i, z) not in cells or cells[(x, box[2] + i, z)] == 0:
                cells[(x, box[2] + i, z)] = None if ch == "#" else "~"
    elif p[0] in ("blk", "guess") and box:
        k = (int(p[1]), int(p[2]), int(p[3]))
        cells[k] = int(p[4])
        (guessed.add if p[0] == "guess" else guessed.discard)(k)
assert box and pal, "no box or palette in the log"

ids = {v[0]: k for k, v in pal.items()}
DIRT, WATER = ids.get("minecraft:dirt"), ids.get("minecraft:water")
unnamed = 0
for k, v in cells.items():
    if v is None or v == "~":
        cells[k] = DIRT if v is None else WATER
        guessed.add(k)
        unnamed += 1

x0, x1, y0, y1, z0, z1 = box
out = ["# 3d-draw map 1", f"box x {x0} {x1} y {y0} {y1} z {z0} {z1}"]
for i in sorted(pal):
    out.append("palette %d %s" % (i, " ".join(pal[i])))
for kind in ("layer", "guessed"):
    for y in range(y0, y1 + 1):
        rows = []
        for z in range(z0, z1 + 1):
            row = []
            for x in range(x0, x1 + 1):
                v = cells.get((x, y, z), -1)
                row.append(str(v) if kind == "layer" else ("1" if (x, y, z) in guessed else "0"))
            rows.append(",".join(row))
        out.append(f"{kind} {y} " + ";".join(rows))

path = os.path.join(DATA, "map.txt")
n = 1
while os.path.exists(os.path.join(DATA, f"map-before-{n}.txt")):
    n += 1
os.replace(path, os.path.join(DATA, f"map-before-{n}.txt"))
open(path, "w", newline="\n").write("\n".join(out) + "\n")
print(f"map: box x {x0}..{x1} y {y0}..{y1} z {z0}..{z1}, {len(pal)} kinds, "
      f"{sum(1 for v in cells.values() if v)} solid cells, {unnamed} never named (guessed); "
      f"the old one kept as data/map-before-{n}.txt")
