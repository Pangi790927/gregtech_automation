"""name.py - the scout names the blocks the survey could only guess (3d-draw/docs/scouts.md,
"The scout and the survey").

    python 3d-draw/name.py <scout>          in the zone loaded (data/map.txt), then save it with
                                            `python 3d-draw/zones.py save`
    ... --water                         the water's surface instead (below)
    ... --leaves                        through the canopy: leaves on the way are broken
    ... --minutes 110                   ends at a stop after that long (survey.MINUTES), before
                                            the 2-hour limit on background jobs; run it again
    ... --map data/map-tom.txt --park 1,-1,0 --region x0 z0 x1 z1
                                            two scouts at once, each in its part of the zone and
                                            on its own copy of its map (the user, 2026-10-04:
                                            "we only work in one 3x3 at a time"); each copy goes
                                            into the chunks with `zones.py save <its map>`

The survey reads hardness only, so every block it did not touch is a guess, drawn as a small
cube in the viewer. The user, 2026-10-04: "send the scout to scan the blocks". This flies the
scout, through air it knows, to a cell beside guessed blocks that air shows (a block nobody sees
stays a guess: it is under ground), and names each such neighbour with geolyzer.analyze. A guess
that turns out to be air makes the blocks behind it seen in turn. It breaks nothing and never
moves into a liquid (robot/server.lua). The viewer follows the live log, which holds the map
first, then a `pal` line for each new kind and a `blk` line for each block named.

The water: the survey reads a liquid at 100 or so, which is certain that it is a liquid, but
not which; the user, 2026-10-04: "scout the water, don't let it be a guess". With --water the
scout names the water's surface (what air shows of it), and water joined under a surface it has
named is taken as named too: the same body (`settle_water`).

Where to stop next: the cell that sees the most unnamed blocks for the way there. The nearest one
alone made a stop for every block or two, each stop a few round trips through the relay
(2026-10-04: 200 named in 150 stops). And the centre first: only the blocks of the nearest ring
round home (RING wide, in x and z) count until that ring is done or has no way left to it - the
user, 2026-10-04, finding Tom naming far east: "why is tom naming blocks in the other part of
the map when there are ... un-named block near the central zone?"
"""
import asyncio, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rlink, run, survey                                    # noqa: E402

SIDES = {"u": (0, 1, 0), "d": (0, -1, 0), "n": (0, 0, -1), "s": (0, 0, 1), "e": (1, 0, 0),
         "w": (-1, 0, 0)}
LOOK = 40                         # how far, in steps, it looks for the next stop
RING = 16                         # the rings round home it names in, nearest first
# New block kinds are numbered from here: two scouts at once each get their own range, or the
# viewer, which has one palette, draws one's sand as the other's wood (2026-10-04).
ID_BASE = 0
# Not below: the caves under the bank. Naming their walls helps neither the house nor the view,
# and down there the scout's link kept dropping (the user, 2026-10-04, seeing it at y -12: "you
# are sure it has enough space to turn back home?"). It still flies up out of one it is in.
FLOOR = -6


async def connect(prefix, tries=12):
    """The scout's server, again if the link dropped. A robot whose chunk unloads stops, and its
    link to the relay with it (Cairol, 2026-10-04, at the zone's edge: its chunkloader refuses).
    Its position survives in its own file, so the plan goes on from where it says it is."""
    scout = await rlink.reach(prefix, tries)
    scout.park = survey.PARK
    await survey.chunk_on(scout)
    return scout


def add(c, d):
    v = SIDES[d]
    return (c[0] + v[0], c[1] + v[1], c[2] + v[2])


def settle_water(cells, guessed, water):
    """Water joined (through water) to water a scout named is named: the same body. Only the
    liquid the survey read joins: anything else stays as it was."""
    from collections import deque
    named = [c for c, v in cells.items() if v in water and c not in guessed]
    q, seen = deque(named), set(named)
    n = 0
    while q:
        c = q.popleft()
        for d in SIDES:
            m = add(c, d)
            if m not in seen and cells.get(m) in water:
                seen.add(m)
                if m in guessed:
                    guessed.discard(m)
                    n += 1
                q.append(m)
    print(f"  water joined to named water, named too: {n}", flush=True)


async def fly(scout, cells, path, leaves):
    """survey.fly, but where the map says leaves the block is analyzed first and broken only if
    it really is leaves (survey.leaf_ahead); anything else ends the flight, and the way is found
    again round it. Every swing is logged (`swing x y z name`) for a record of what went."""
    if not leaves:
        return await survey.fly(scout, cells, path)
    at = tuple(scout.pos)
    for d in path:
        n = add(at, d)
        if cells.get(n) in leaves:
            if not await survey.leaf_ahead(scout, cells, d):
                return False
            await scout.batch([f"swing {d}"])
            cells[n] = 0
            scout._event(f"blk {n[0]} {n[1]} {n[2]} 0")
            scout._event(f"swing {n[0]} {n[1]} {n[2]} leaves")
        if not await survey.fly(scout, cells, [d]):
            return False
        at = n
    return True


async def reconnect(prefix):
    """The scout again, and its energy: tried until both answer (the link can drop again while
    it comes back, as Cairol's did on its way to charge, 2026-10-04)."""
    for _ in range(20):
        await asyncio.sleep(10)
        try:
            scout = await connect(prefix)
            return scout, await survey.energy(scout)
        except (rlink.RobotError, OSError) as e:
            print(f"  not back yet ({e})", flush=True)
    raise SystemExit(f"{prefix} does not come back")


async def main():
    args = sys.argv[1:]
    region = None
    if "--map" in args:
        i = args.index("--map")
        survey.MAP = os.path.abspath(args[i + 1])
        del args[i:i + 2]
    if "--park" in args:
        i = args.index("--park")
        survey.PARK = tuple(int(v) for v in args[i + 1].split(","))
        del args[i:i + 2]
    global ID_BASE
    if "--ids" in args:
        i = args.index("--ids")
        ID_BASE = int(args[i + 1])
        del args[i:i + 2]
    # The user, 2026-10-04: "Tom can break leaves to reach the forest floor" - with --leaves a
    # way may go through leaves, broken as the scout comes to them (most guessed blocks round the
    # house lay under the canopy, shut off from the air the scout flies in).
    through_leaves = "--leaves" in args
    if through_leaves:
        args.remove("--leaves")
    water_only = "--water" in args
    if water_only:
        args.remove("--water")
    if "--region" in args:
        i = args.index("--region")
        region = [int(v) for v in args[i + 1:i + 5]]
        del args[i:i + 5]
    minutes = survey.MINUTES
    if "--minutes" in args:
        i = args.index("--minutes")
        minutes = float(args[i + 1])
        del args[i:i + 2]
    prefix = args[0] if args else "956b836d"                  # Cairol
    pal, cells, guessed = survey.load()
    rules = survey.Rules(cells, pal, guessed)                 # under the sky (the user's rule)
    kinds, names = {}, {}                                     # (name, meta) -> id, named ones
    for p in pal:
        i, name, meta, hard, how = p.split()[:5]
        names[int(i)] = name
        if how != "guessed":
            kinds.setdefault((name, int(meta)), int(i))
    water = {i for i, n in names.items() if n == "minecraft:water"}
    leaves = {i for i, n in names.items() if "leaves" in n.lower()}

    def seen(c):
        if region and not (region[0] <= c[0] <= region[2] and region[1] <= c[2] <= region[3]):
            return False                                     # the other scout's part
        if c not in guessed or cells.get(c, 0) <= 0:
            return False
        if (cells[c] in water) != water_only:
            return False
        return any(cells.get(add(c, d)) == 0 for d in SIDES)

    todo = {c for c in guessed if seen(c) and c[1] >= FLOOR}
    unreached = set()                                         # a ring's blocks with no way

    def ring(c):
        return max(abs(c[0]), abs(c[2])) // RING
    scout = await connect(prefix)
    print(f"name: {len(todo)} guessed blocks in view; {scout.name} at {scout.pos}", flush=True)
    stops = named = 0
    energy = await survey.energy(scout)
    # Every retry is bounded (the audit, 2026-10-04, after the floor loop above): a stop is tried
    # TRIES times, then its blocks are set aside; charges, and link drops, with nothing named
    # between them end the job, to be looked at - no loop runs on unseen for an hour again.
    tries, idle_charges, drops, was = {}, 0, 0, -1
    ends = time.monotonic() + minutes * 60
    timed_out = False
    while todo:
        if named != was:
            idle_charges = drops = 0
            was = named
        if idle_charges > survey.TRIES or drops > 2 * survey.TRIES:
            raise SystemExit(f"{scout.name}: {idle_charges} charges and {drops} link drops with "
                             f"nothing named between them, at {scout.pos}")
        if time.monotonic() >= ends:
            # Before the 2-hour limit on background jobs cuts it mid-flight: it ends at a
            # stop, and the next job goes on from there (the audit, 2026-10-04).
            timed_out = True
            break
        try:
            rules.forget()                                # what was named since
            seen_from = {}
            near = min(map(ring, todo))
            for c in todo:
                if ring(c) != near:
                    continue
                for d in SIDES:
                    n = add(c, d)
                    if cells.get(n) == 0 and n[1] >= FLOOR and rules.explore(n):
                        seen_from[n] = seen_from.get(n, 0) + 1
            start = tuple(scout.pos)
            prev, dist, q, best = {start: None}, {start: 0}, [start], None
            for c in q:
                if len(prev) > survey.ROUTE_LIMIT:                # bounded, as survey.route
                    break
                if c in seen_from:
                    score = seen_from[c] / (dist[c] + 3)
                    if best is None or score > best[0]:
                        best = (score, c)
                if dist[c] >= LOOK and best is not None:   # further, while none
                    continue
                for d in SIDES:
                    n = add(c, d)
                    if n not in prev and (rules.travel(n)
                                          or through_leaves and cells.get(n) in leaves):
                        prev[n], dist[n] = (c, d), dist[c] + 1
                        q.append(n)
            if best is None:
                inner = {c for c in todo if ring(c) == near}
                if inner == todo:
                    break
                unreached |= inner                            # on to the next ring
                todo -= inner
                print(f"  ring {near} done, {len(inner)} with no way to them", flush=True)
                continue
            tries[best[1]] = tries.get(best[1], 0) + 1
            if tries[best[1]] > survey.TRIES:
                # Tried TRIES times and its blocks still there: set aside with the unreached.
                gone = {c for c in todo if any(add(c, d) == best[1] for d in SIDES)}
                print(f"  {scout.name}: stop {best[1]} tried {survey.TRIES} times; "
                      f"{len(gone)} blocks set aside", flush=True)
                todo -= gone
                unreached |= gone
                continue
            path, c = [], best[1]
            while prev[c]:
                c, d = prev[c]
                path.append(d)
            path.reverse()
            nxt = sorted((c for c in todo if any(add(c, d) == best[1] for d in SIDES)),
                     key=lambda c: c)[:3]
            scout.status("naming " + ("water" if water_only else "blocks"),
                         "next: " + ", ".join(f"{c[0]} {c[1]} {c[2]}" for c in nxt),
                         f"named {named} of {named + len(todo)}" +
                         (f" in x {region[0]}..{region[2]}" if region else ""))
            far = sum(abs(a - b) for a, b in zip(start, survey.PARK))
            if stops % 10 == 0:
                energy = await survey.energy(scout)
            if energy < (far + len(path) + 12) * survey.PER_STEP + survey.MARGIN:
                await survey.go_charge(scout, cells, leaves if through_leaves else (), rules)
                idle_charges += 1
                energy = await survey.energy(scout)
                continue
            energy -= len(path) * 8
            if not await fly(scout, cells, path, leaves if through_leaves else ()):
                if getattr(scout, "low", False):
                    scout.low = False
                    await survey.go_charge(scout, cells, leaves if through_leaves else (), rules)
                    idle_charges += 1
                    energy = await survey.energy(scout)
                continue
            at = tuple(scout.pos)
            dirs = [d for d in SIDES if add(at, d) in todo]
            res = await scout.batch(["analyze " + d for d in dirs])
            # The robot's own floor (robot/server.lua: its trail home at 12 a step, plus 1500)
            # refuses analyze too, and it is higher than this program's guess after a winding
            # day. At a stop it was already in, no move ever said so, and every run from
            # 2026-10-04 asked the same stop again thousands of times, an hour or more each, a
            # probe found (the user, that day: "if the robots do things that are 400%
            # ineficient, maybe come up with a strategy to fix it"). So: charge.
            if any(s == "err" and "low energy" in v for s, v in res):
                await survey.go_charge(scout, cells, leaves if through_leaves else (), rules)
                idle_charges += 1
                energy = await survey.energy(scout)
                continue
            if dirs and not any(s == "ok" for s, _ in res):
                # Nothing answered for another reason: these are set aside, not asked forever.
                print(f"  {scout.name}: analyze failed at {at}: {res[0][1]}", flush=True)
                for d in dirs:
                    todo.discard(add(at, d))
                    unreached.add(add(at, d))
                continue
            for d, (status, values) in zip(dirs, res):
                c = add(at, d)
                if status != "ok":
                    continue
                todo.discard(c)
                guessed.discard(c)
                if values.split()[0] in ("air", "minecraft:air"):
                    cells[c] = 0
                    scout._event(f"blk {c[0]} {c[1]} {c[2]} 0")
                    todo |= {add(c, e) for e in SIDES if seen(add(c, e)) and c[1] >= FLOOR}
                    continue
                name, meta, hard = values.split()[:3]
                key = (name, int(meta))
                if key not in kinds:
                    i = max([int(p.split()[0]) for p in pal] + [ID_BASE]) + 1
                    pal.append(f"{i} {name} {meta} {float(hard):.2f} analyzed")
                    kinds[key] = i
                    scout._event(f"pal {i} {name} {meta} {float(hard):.2f} analyzed")
                cells[c] = kinds[key]
                scout._event(f"blk {c[0]} {c[1]} {c[2]} {kinds[key]}")
                named += 1
            stops += 1
            if stops % 25 == 0:
                survey.save(pal, cells, guessed)
                print(f"  {stops} stops, {named} named, {len(todo)} to go, at {scout.pos}, "
                      f"energy {energy}", flush=True)
        except (rlink.RobotError, OSError) as e:
            print(f"  the link dropped ({e}); again from where the scout says it is",
                  flush=True)
            survey.save(pal, cells, guessed)
            drops += 1
            scout, energy = await reconnect(prefix)
    if water_only:
        settle_water(cells, guessed, water)
    survey.save(pal, cells, guessed)
    if timed_out:                                             # left at its stop, for the next
        await scout.close()
        print(f"name: time's up ({minutes:.0f} min): {named} named in {stops} stops; "
              f"{len(todo)} to go, {len(unreached)} set aside; at {scout.pos}", flush=True)
        return
    for _ in range(5):                                        # home, even across a dropped link
        try:
            await survey.go_charge(scout, cells, leaves if through_leaves else (), rules)
            break
        except (rlink.RobotError, OSError):
            scout, energy = await reconnect(prefix)
    await scout.close()
    todo |= unreached
    print(f"name done: {named} named in {stops} stops; {len(todo)} left (no way to them)",
          flush=True)


if __name__ == "__main__":
    asyncio.run(main())
