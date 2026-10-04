"""zones.py - the map kept by Minecraft chunk, worked on 3x3 chunks at a time (3d-draw/docs/map.md,
"Zones: the map by chunk").

    python 3d-draw/zones.py save [map]        data/map.txt (or that map) -> data/chunks/, merged
    python 3d-draw/zones.py load <cx> <cz>    the 3x3 chunks round chunk cx, cz -> data/map.txt
    python 3d-draw/zones.py where             the zone loaded now, and what chunks are kept
    python 3d-draw/zones.py overview          data/chunks/overview.txt again (save writes it)
    python 3d-draw/zones.py settle-grass [map]   guessed grass, all but the bottom known: grass
    python 3d-draw/zones.py grass-under-plants [map]   a grass block under every plant
    python 3d-draw/zones.py export cx0 cz0 cx1 cz1 map  kept chunks in that range, one map

The user, 2026-10-04: "I want different map zones to be saved as chunks, such that we will be
able to load 3x3 chunk areas, this will be our standard work zone, that we will move around".
A 3x3 zone is 48 x 48 columns: it fits the simulator's 64 x 64 x 64 world with room round it.

Two frames. The robots count from the start block (0 0 0); that is the frame of data/map.txt, of
the plans and of everything the robots are told. The chunk files are in the world's own frame,
so they do not depend on where the robots started: data/anchor.txt says where the start block is
in the world (`start <x> <y> <z>`, the user, 2026-10-04: x 255, z 139, y about 63). The chunk
borders that gives were confirmed by the map itself: a scan from home read air, beside water,
exactly over chunk (16, 9) - a chunk that was not loaded then (the geolyzer reads an unloaded
chunk as air).

A chunk file is a map file (the same format as data/map.txt) whose box is that chunk's 16 x 16
columns in world coordinates. Saving merges: what the robots found last wins, except that a
guess never replaces a block a robot named.
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
CHUNKS = os.path.join(DATA, "chunks")
MAP = os.path.join(DATA, "map.txt")
ZONE = os.path.join(DATA, "zone.txt")


def anchor():
    """Where the start block is in the world."""
    for line in open(os.path.join(DATA, "anchor.txt")):
        p = line.split()
        if p and p[0] == "start":
            return int(p[1]), int(p[2]), int(p[3])
    raise SystemExit("no `start x y z` in data/anchor.txt")


def read(path):
    """A map file: {cell: (name, meta, hardness, how) or 0 for air}, and the guessed cells."""
    lines = open(path).read().splitlines()
    x0, _, _, _, z0, _ = map(int, re.findall(r"-?\d+", lines[1]))
    pal, cells, guessed = {}, {}, set()
    for line in lines:
        kind, _, rest = line.partition(" ")
        if kind == "palette":
            i, name, meta, hard, how = rest.split()[:5]
            pal[int(i)] = (name, int(meta), float(hard), how)
    for line in lines:
        kind, _, rest = line.partition(" ")
        if kind not in ("layer", "guessed"):
            continue
        y, data = rest.split(" ", 1)
        for zi, row in enumerate(data.split(";")):
            for xi, v in enumerate(row.split(",")):
                c = (x0 + xi, int(y), z0 + zi)
                if kind == "layer" and int(v) >= 0:
                    cells[c] = pal[int(v)] if int(v) > 0 else 0
                elif kind == "guessed" and v == "1":
                    guessed.add(c)
    return cells, guessed & set(cells)


REGISTRY = os.path.join(DATA, "palette.txt")
# Blocks the user told of, which no scan may undo: `x y z name meta hardness how`, in world
# coordinates. The scouts' own maps still held the station as it was, and every merge of them
# into the chunks would have put air back where the user built (2026-10-04: "I had to add
# blocks to the station, the geometry changed a bit").
FIXED = os.path.join(DATA, "fixed.txt")
# What the robots built, finished (imprint.py writes it): the same, a layer no scan undoes - a
# scout's map from before the build has air where the house now stands (the user, 2026-10-04:
# the finished part "importalied in the map, not to be part of the proposal design").
BUILT = os.path.join(DATA, "built.txt")


def fixed():
    """FIXED and BUILT: (x, y, z) -> (name, meta, hardness, how), world coordinates; None for
    air the build dug out."""
    out = {}
    for path in (BUILT, FIXED):                               # the user's word last
        if os.path.exists(path):
            for line in open(path):
                p = line.split()
                if len(p) >= 7 and not line.startswith("#"):
                    w = tuple(map(int, p[:3]))
                    out[w] = None if p[3] == "minecraft:air" else \
                        (p[3], int(p[4]), float(p[5]), p[6])
    return out


def apply_fixed():
    """FIXED and BUILT into every chunk file they touch (zones.save applies them only to the
    chunks of the map it saves)."""
    by_chunk = {}
    for w, v in fixed().items():
        by_chunk.setdefault((w[0] >> 4, w[2] >> 4), {})[w] = v
    for (cx, cz), new in sorted(by_chunk.items()):
        path = chunk_path(cx, cz)
        old, oldg = read(path) if os.path.exists(path) else ({}, set())
        for w, v in new.items():
            old[w] = v
            (oldg.add if v and v[3] == "guessed" else oldg.discard)(w)
        ys = [w[1] for w in old]
        write(path, old, oldg, (cx * 16, cx * 16 + 15, min(ys), max(ys), cz * 16, cz * 16 + 15))
    overview()
    print(f"apply_fixed: {len(by_chunk)} chunks")


def registry():
    """Every block kind's one number, (name, meta, how) -> id. A map rebuilt from the chunks
    numbered its palette afresh each time, and the scouts' copies, the live view and the map
    then meant different blocks by one number: water was drawn as flowers (2026-10-04). Kinds
    are only ever added; the contour block is 1, as the robot programs expect."""
    reg = {}
    if os.path.exists(REGISTRY):
        for line in open(REGISTRY):
            p = line.split()
            if len(p) >= 4 and not line.startswith("#"):
                reg[(p[1], int(p[2]), p[3])] = int(p[0])
    return reg


def write(path, cells, guessed, box):
    """A map file over box = (x0, x1, y0, y1, z0, z1), its palette in the registry's numbers."""
    x0, x1, y0, y1, z0, z1 = box
    reg = registry()
    added = []
    blocks = sorted({v for v in cells.values() if v}, key=lambda b: b[0] != "chisel:antiBlock")
    ids = {}
    for b in blocks:
        key = (b[0], b[1], b[3])
        if key not in reg:
            reg[key] = max(reg.values(), default=0) + 1
            added.append((reg[key], key))
        ids[b] = reg[key]
    if added:
        with open(REGISTRY, "a", newline="\n") as f:
            if os.path.getsize(REGISTRY) == 0 if os.path.exists(REGISTRY) else True:
                f.write("# 3d-draw block kinds (zones.py): id name meta how - never renumbered\n")
            for i, (n, m, how) in added:
                f.write(f"{i} {n} {m} {how}\n")
    out = ["# 3d-draw map 1", f"box x {x0} {x1} y {y0} {y1} z {z0} {z1}"]
    seen = set()
    for b in blocks:
        if ids[b] not in seen:
            seen.add(ids[b])
            out.append(f"palette {ids[b]} {b[0]} {b[1]} {b[2]:.2f} {b[3]}")
    for kind in ("layer", "guessed"):
        for y in range(y0, y1 + 1):
            rows = []
            for z in range(z0, z1 + 1):
                row = []
                for x in range(x0, x1 + 1):
                    v = cells.get((x, y, z), -1)
                    if kind == "layer":
                        row.append(str(-1 if v == -1 else ids[v] if v else 0))
                    else:
                        row.append("1" if (x, y, z) in guessed else "0")
                rows.append(",".join(row))
            out.append(f"{kind} {y} " + ";".join(rows))
    tmp = path + ".tmp"
    open(tmp, "w", newline="\n").write("\n".join(out) + "\n")
    os.replace(tmp, path)


def chunk_path(cx, cz):
    return os.path.join(CHUNKS, f"c{cx}_{cz}.txt")


def overview():
    """data/chunks/overview.txt: each chunk's columns by the block on top, for the viewer's map of
    chunks (M). `names` lists the blocks; then `chunk cx cz` and 256 indices, row by row (z), -1
    where nothing is known."""
    names, out = [], []
    for f in sorted(os.listdir(CHUNKS)):
        m = re.match(r"^c(-?\d+)_(-?\d+)\.txt$", f)
        if not m:
            continue
        cx, cz = int(m.group(1)), int(m.group(2))
        cells, _ = read(os.path.join(CHUNKS, f))
        top = {}
        for (x, y, z), v in cells.items():
            if v and v[0] != "minecraft:air" and ((x, z) not in top or y > top[(x, z)][0]):
                top[(x, z)] = (y, v[0])
        row = []
        for z in range(cz * 16, cz * 16 + 16):
            for x in range(cx * 16, cx * 16 + 16):
                if (x, z) in top:
                    name = top[(x, z)][1]
                    if name not in names:
                        names.append(name)
                    row.append(str(names.index(name)))
                else:
                    row.append("-1")
        out.append(f"chunk {cx} {cz} " + ",".join(row))
    with open(os.path.join(CHUNKS, "overview.txt"), "w", newline="\n") as f:
        f.write("# 3d-draw chunk overview (zones.py): the block on top of each column\n")
        f.write("names " + " ".join(names) + "\n" + "\n".join(out) + "\n")


def save(path=MAP):
    """data/map.txt (or another working map: a scout's own) into the chunk files it touches."""
    ax, ay, az = anchor()
    cells, guessed = read(path)
    by_chunk = {}
    for (x, y, z), v in cells.items():
        w = (x + ax, y + ay, z + az)
        by_chunk.setdefault((w[0] >> 4, w[2] >> 4), {})[w] = (v, (x, y, z) in guessed)
    os.makedirs(CHUNKS, exist_ok=True)
    for (cx, cz), new in sorted(by_chunk.items()):
        path = chunk_path(cx, cz)
        old, oldg = read(path) if os.path.exists(path) else ({}, set())
        for w, (v, g) in new.items():
            if g and w in old and old[w] and w not in oldg:
                continue                                      # a guess never beats a name
            old[w] = v
            (oldg.add if g else oldg.discard)(w)
        for w, v in fixed().items():                          # built, and the user's, last
            if (w[0] >> 4, w[2] >> 4) == (cx, cz):
                old[w] = v
                (oldg.add if v and v[3] == "guessed" else oldg.discard)(w)
        ys = [w[1] for w in old]
        write(path, old, oldg, (cx * 16, cx * 16 + 15, min(ys), max(ys), cz * 16, cz * 16 + 15))
    overview()
    print(f"save: {len(by_chunk)} chunks written to data/chunks/")


def load(cx, cz):
    """The 3x3 chunks round cx, cz into data/map.txt, in the robots' frame."""
    ax, ay, az = anchor()
    cells, guessed = {}, set()
    found = []
    for i in range(cx - 1, cx + 2):
        for j in range(cz - 1, cz + 2):
            if os.path.exists(chunk_path(i, j)):
                c, g = read(chunk_path(i, j))
                cells.update({(x - ax, y - ay, z - az): v for (x, y, z), v in c.items()})
                guessed |= {(x - ax, y - ay, z - az) for (x, y, z) in g}
                found.append((i, j))
    if not cells:
        raise SystemExit(f"no chunks kept round {cx} {cz}")
    # The built and told-of blocks laid over the chunks here too, whatever a chunk file holds:
    # a zone loaded before the chunks had the house (it is laid into them on their next save)
    # left the fisher's house out of the map, and the harbour was planned through it
    # (2026-10-04, 13:44).
    for (x, y, z), v in fixed().items():
        if (cx - 1) * 16 <= x < (cx + 2) * 16 and (cz - 1) * 16 <= z < (cz + 2) * 16:
            c = (x - ax, y - ay, z - az)
            cells[c] = v
            (guessed.add if v and v[3] == "guessed" else guessed.discard)(c)
    ys = [c[1] for c in cells]
    box = ((cx - 1) * 16 - ax, (cx + 2) * 16 - 1 - ax, min(ys), max(ys),
           (cz - 1) * 16 - az, (cz + 2) * 16 - 1 - az)
    write(MAP, cells, guessed, box)
    open(ZONE, "w", newline="\n").write(f"zone {cx} {cz}\n")
    print(f"load: zone {cx} {cz} ({len(found)} of 9 chunks kept) into data/map.txt: x {box[0]}.."
          f"{box[1]}, z {box[4]}..{box[5]} from the start block; world x {(cx - 1) * 16}.."
          f"{(cx + 2) * 16 - 1}, z {(cz - 1) * 16}..{(cz + 2) * 16 - 1}")


def settle_grass(path=MAP):
    """A grass block only guessed, whose top and four sides are all known (named, or air), is
    taken as grass for good: no scout will learn more of it (the user, 2026-10-04, choosing
    between this and dirt: "becomes grass"). Known means known before this pass: blocks settled
    here do not count, so a run of guesses cannot confirm each other."""
    cells, guessed = read(path)
    sides = [(0, 1, 0), (1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1)]
    grass = ("minecraft:grass", 0, 0.6, "analyzed")
    settled = []
    for c in list(guessed):
        v = cells.get(c)
        if not v or v[0] != "minecraft:grass":
            continue
        around = [(c[0] + a, c[1] + b, c[2] + d) for a, b, d in sides]
        if all(n in cells and n not in guessed for n in around):
            settled.append(c)
    for c in settled:
        guessed.discard(c)
        cells[c] = grass
    xs = [c[0] for c in cells]; ys = [c[1] for c in cells]; zs = [c[2] for c in cells]
    write(path, cells, guessed, (min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)))
    left = sum(1 for c in guessed if cells.get(c) and cells[c][0] == "minecraft:grass")
    print(f"settle-grass: {len(settled)} guessed grass blocks settled as grass; {left} still "
          f"guessed (a side or the top not known yet)")


PLANTS = ("BiomesOPlenty:flowers", "BiomesOPlenty:flowers2", "BiomesOPlenty:foliage",
          "BiomesOPlenty:plants", "minecraft:tallgrass", "minecraft:double_plant",
          "minecraft:red_flower", "minecraft:yellow_flower")


def grass_under_plants(path=MAP):
    """Under every plant - a flower, tall grass, the lavender - a grass block, where the map has
    a guess or nothing: a plant stands on one, and holes under them made the drawing gappy (the
    user, 2026-10-04: "I want dirt grass blocks underneath the grass types, flowers, tall grass,
    etc, such that drawing doesn't have unwarranted holes"). Only under the bottom of a plant;
    a block a robot named is left as it is."""
    cells, guessed = read(path)
    grass = ("minecraft:grass", 0, 0.6, "analyzed")
    n = 0
    for c, v in list(cells.items()):
        if not v or v[0] not in PLANTS:
            continue
        below = (c[0], c[1] - 1, c[2])
        b = cells.get(below)
        if b is not None and b and b[0] in PLANTS:
            continue                                     # the top half of a tall plant
        if b is None or below in guessed:
            cells[below] = grass
            guessed.discard(below)
            n += 1
    xs = [c[0] for c in cells]; ys = [c[1] for c in cells]; zs = [c[2] for c in cells]
    write(path, cells, guessed, (min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)))
    print(f"grass under plants: {n} blocks written as grass")


def export(cx0, cz0, cx1, cz1, path):
    """The kept chunks cx0..cx1 x cz0..cz1 into one map file in the robots' frame: a scout's
    working map for a survey wider than a zone (the 15x15 chunks of 2026-10-04). Chunks not
    kept are left out: the survey scans them."""
    ax, ay, az = anchor()
    cells, guessed = {}, set()
    for i in range(cx0, cx1 + 1):
        for j in range(cz0, cz1 + 1):
            if os.path.exists(chunk_path(i, j)):
                c, g = read(chunk_path(i, j))
                cells.update({(x - ax, y - ay, z - az): v for (x, y, z), v in c.items()})
                guessed |= {(x - ax, y - ay, z - az) for (x, y, z) in g}
    ys = [c[1] for c in cells] or [0]
    box = (cx0 * 16 - ax, (cx1 + 1) * 16 - 1 - ax, min(ys), max(ys),
           cz0 * 16 - az, (cz1 + 1) * 16 - 1 - az)
    write(path, cells, guessed, box)
    print(f"export: chunks {cx0}..{cx1} x {cz0}..{cz1} into {path}: x {box[0]}..{box[1]}, "
          f"z {box[4]}..{box[5]} from the start block")


def where():
    zone = open(ZONE).read().split()[1:] if os.path.exists(ZONE) else None
    kept = sorted(tuple(map(int, f[1:-4].split("_"))) for f in os.listdir(CHUNKS)
                  if re.match(r"^c-?\d+_-?\d+\.txt$", f)) if os.path.isdir(CHUNKS) else []
    print("zone loaded:", " ".join(zone) if zone else "none")
    print("chunks kept:", " ".join(f"{a},{b}" for a, b in kept) or "none")
    ax, ay, az = anchor()
    print(f"the start block: world {ax} {ay} {az}, chunk {ax >> 4} {az >> 4}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["save"]:
        save(os.path.abspath(a[1]) if len(a) > 1 else MAP)
    elif a[:1] == ["load"] and len(a) == 3:
        load(int(a[1]), int(a[2]))
    elif a[:1] == ["export"] and len(a) == 6:
        export(*map(int, a[1:5]), os.path.abspath(a[5]))
    elif a[:1] == ["grass-under-plants"]:
        grass_under_plants(os.path.abspath(a[1]) if len(a) > 1 else MAP)
    elif a[:1] == ["settle-grass"]:
        settle_grass(os.path.abspath(a[1]) if len(a) > 1 else MAP)
    elif a[:1] == ["overview"]:
        overview()
    elif a[:1] == ["where"]:
        where()
    else:
        sys.exit(__doc__)
