"""Tests of the scouts' rules (the user, 2026-10-04): exploring only under the sky or a tree,
travel through any known air in the known area, the tunnels refused, the way out of one allowed
once, leaves broken only when analyze says leaves, scans never below the energy home needs.
Then the ridge past the mountain, the robot's energy floor, and the bounds on every retry (the
audit, 2026-10-04). No robot: small made-up maps, fake scouts, and the real map for the tunnels
(skipped where data/, the user's world, is not there).

    python 3d-draw/tests/test_scouts.py          exits 0 when all pass, 1 when any fails
"""
import asyncio, os, sys, unittest
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))     # 3d-draw/
sys.path.insert(0, HERE)
import survey, name                                           # noqa: E402

AIR, DIRT, STONE, LEAVES, LOG, WATER = 0, 2, 3, 4, 5, 6
PAL = ["2 minecraft:dirt 0 0.50 analyzed", "3 minecraft:stone 0 1.50 analyzed",
       "4 BiomesOPlenty:leaves4 1 0.20 analyzed", "5 minecraft:log 1 2.00 analyzed",
       "6 minecraft:water 0 100.00 analyzed"]
FAR = 200                       # x of the made-up terrain: well outside the known area


def terrain(ground=0, x0=FAR - 5, x1=FAR + 5, z0=-5, z1=5, y0=-6, y1=12):
    """Dirt up to `ground`, air above, a box of columns known from y0 to y1."""
    cells = {}
    for x in range(x0, x1 + 1):
        for z in range(z0, z1 + 1):
            for y in range(y0, y1 + 1):
                cells[(x, y, z)] = DIRT if y <= ground else AIR
    return cells


def rules(cells, guessed=(), refused=()):
    return survey.Rules(cells, PAL, set(guessed), refused=set(refused))


class Exploring(unittest.TestCase):
    def test_open_sky(self):
        c = terrain()
        r = rules(c)
        self.assertTrue(r.explore((FAR, 1, 0)))
        self.assertTrue(r.travel((FAR, 3, 0)))

    def test_under_a_named_tree(self):
        c = terrain()
        c[(FAR, 1, 0)] = LOG
        for dx in (-1, 0, 1):
            for dz in (-1, 0, 1):
                c[(FAR + dx, 4, dz)] = LEAVES
        r = rules(c)
        self.assertTrue(r.explore((FAR + 1, 1, 0)))           # under the canopy

    def test_under_guessed_leaves_is_not_a_tree(self):
        c = terrain()
        c[(FAR, 4, 0)] = LEAVES                                # by hardness only: may be ground
        r = rules(c, guessed={(FAR, 4, 0)})
        self.assertFalse(r.explore((FAR, 1, 0)))

    def test_tunnel_refused(self):
        c = terrain(ground=3)
        for x in range(FAR - 3, FAR + 3):
            c[(x, 0, 0)] = AIR                                 # a tunnel under 3 of dirt
        r = rules(c)
        self.assertFalse(r.explore((FAR, 0, 0)))
        self.assertFalse(r.travel((FAR, 0, 0)))

    def test_overhang_refused(self):
        c = terrain()
        c[(FAR, 5, 0)] = STONE                                 # a ledge over open air
        r = rules(c)
        self.assertFalse(r.explore((FAR, 2, 0)))
        self.assertFalse(r.travel((FAR, 2, 0)))
        self.assertTrue(r.explore((FAR, 6, 0)))                # above it, the sky

    def test_under_a_building_in_the_known_area(self):
        c = terrain(x0=-3, x1=3, z0=-3, z1=3)
        c[(0, 4, 0)] = STONE                                   # a roof at home
        r = rules(c)
        self.assertTrue(r.travel((0, 2, 0)))                   # travel: allowed
        self.assertFalse(r.explore((0, 2, 0)))                 # a stop there: not

    def test_refused_cells(self):
        c = terrain()
        r = rules(c, refused={(FAR, 3, 0)})
        self.assertFalse(r.explore((FAR, 3, 0)))
        self.assertFalse(r.travel((FAR, 3, 0)))


class Routing(unittest.TestCase):
    def test_route_avoids_tunnels(self):
        # Two ways from A to B: straight through a tunnel, or up and over through the sky.
        c = terrain(ground=3)
        for x in range(FAR - 4, FAR + 5):
            c[(x, 0, 0)] = AIR
        a, b = (FAR - 4, 0, 0), (FAR + 4, 0, 0)
        for y in range(0, 4):                                  # shafts up at both ends
            c[(a[0], y, 0)] = AIR
            c[(b[0], y, 0)] = AIR
        r = rules(c)
        self.assertFalse(r.travel((FAR, 0, 0)))                # the tunnel's middle
        path = survey.route(c, a, lambda x: x == b, ok=r.travel)
        self.assertIsNotNone(path)                             # up the shaft, over, down
        at = a
        for d in path:
            at = survey.add(at, d)
            self.assertTrue(r.travel(at), at)
        path = survey.route(c, (a[0], 4, 0), lambda x: x == (b[0], 4, 0), ok=r.travel)
        self.assertIsNotNone(path)
        at = (a[0], 4, 0)
        for d in path:
            at = survey.add(at, d)
            self.assertTrue(r.travel(at), at)                  # never through the tunnel

    def test_way_out_once(self):
        c = terrain(ground=3)
        for x in range(FAR - 3, FAR + 1):
            c[(x, 0, 0)] = AIR                                 # a tunnel
        for y in range(0, 4):
            c[(FAR, y, 0)] = AIR                               # and a shaft up out of it
        r = rules(c)
        start, park = (FAR - 3, 0, 0), (FAR, 6, 0)
        self.assertIsNone(survey.route(c, start, lambda x: x == park, ok=r.travel))
        out = r.pocket(start)
        path = survey.route(c, start, lambda x: x == park,
                            ok=lambda x: x in out or r.travel(x))
        self.assertIsNotNone(path)
        # once out, the pocket is not a way: from the sky, no route goes back down into it
        self.assertIsNone(survey.route(c, park, lambda x: x == start, ok=r.travel))


class Ridge(unittest.TestCase):
    """Past the mountain (2026-10-04): old columns scanned only to y 9 here, the ground rising to
    it; new columns beyond, ground at 9, scanned to 20. No air joins them until --taller scans
    the old ones whose air under their top is thin, or whose neighbour's ground nears it."""

    def world(self):
        c = {}
        for x in range(FAR - 6, FAR + 7):
            for z in range(-2, 3):
                g = 0 if x < FAR - 2 else 7 if x < FAR + 1 else 9   # flat, the foot, the ridge
                top = 9 if x < FAR + 1 else 20                       # old scans, new scans
                for y in range(-3, top + 1):
                    c[(x, y, z)] = DIRT if y <= g else AIR
        return c

    def test_island_before(self):
        c = self.world()
        r = rules(c)
        self.assertIsNone(survey.route(c, (FAR - 6, 5, 0), lambda x: x == (FAR + 4, 12, 0),
                                       ok=r.travel))

    def test_taller_joins(self):
        c = self.world()
        box = (FAR - 6, -2, FAR + 6, 2)
        cols = survey.taller_columns(c, box, 20)
        # the foot (air 8..9) and the flat column beside it (its neighbour's ground 7 >= 9 - 4);
        # the flat far off (ground 0, air to 9) and the new columns (top 20) are not scanned
        self.assertIn((FAR - 1, 0), cols)
        self.assertIn((FAR - 3, 0), cols)
        self.assertNotIn((FAR - 6, 0), cols)
        self.assertNotIn((FAR + 3, 0), cols)
        for x, z in cols:                                      # the scan: air up to 20
            for y in range(10, 21):
                c[(x, y, z)] = AIR
        r = rules(c)
        path = survey.route(c, (FAR - 6, 5, 0), lambda x: x == (FAR + 4, 12, 0), ok=r.travel)
        self.assertIsNotNone(path)

    def test_cliff(self):
        # ground 2 then a cliff to 9: the old column's air is thick (3..9), but its neighbour's
        # ground is at its top - it is scanned again, or the cliff top has no way up to it
        c = self.world()
        for x in range(FAR - 2, FAR + 1):
            for z in range(-2, 3):
                for y in range(1, 10):
                    c[(x, y, z)] = AIR if y > 2 else DIRT
        cols = survey.taller_columns(c, (FAR - 6, -2, FAR + 6, 2), 20)
        self.assertIn((FAR, 0), cols)
        self.assertNotIn((FAR - 2, 0), cols)

    def test_air_only_column_is_unscanned(self):
        # air_round's air, or the cells a scout stood in, with no ground under them: the column
        # is scanned whole, not taken as done (95 columns left in the north-west, 2026-10-04)
        c = self.world()
        for y in range(5, 15):
            c[(FAR + 8, y, 0)] = AIR
        cols = survey.unscanned_columns(c, (FAR - 6, -2, FAR + 8, 2))
        self.assertIn((FAR + 8, 0), cols)
        self.assertIn((FAR + 7, 0), cols)                      # nothing known: as before
        self.assertNotIn((FAR, 0), cols)                       # ground known: done

    def test_solid_top_still_taken(self):
        c = self.world()
        c[(FAR - 6, 9, 0)] = STONE
        self.assertIn((FAR - 6, 0), survey.taller_columns(c, (FAR - 6, -2, FAR + 6, 2), 20))


class FakeScout:
    """Answers analyze with what the made-up world has; counts swings and scans."""

    def __init__(self, world, pos, energy=40000, park=(0, 0, 0)):
        self.world, self.pos, self.e, self.park = world, list(pos), energy, park
        self.name, self.swings, self.scans = "fake", [], 0

    async def run(self, cmd):
        w = cmd.split()
        if w[0] == "analyze":
            n = survey.add(tuple(self.pos), w[1])
            return self.world.get(n, "minecraft:air") + " 0 0.5"
        if w[0] == "energy":
            return f"{self.e} 40500"
        raise AssertionError(cmd)

    async def batch(self, cmds):
        out = []
        for cmd in cmds:
            w = cmd.split()
            if w[0] == "swing":
                self.swings.append(survey.add(tuple(self.pos), w[1]))
                out.append(("ok", "true"))
            elif w[0] == "move":
                self.pos = list(survey.add(tuple(self.pos), w[1]))
                out.append(("ok", " ".join(map(str, self.pos)) + " n 30000"))
            elif w[0] == "scan":
                self.scans += 1
                out.append(("ok", ",".join(["0"] * int(w[4]))))
            else:
                out.append(("ok", ""))
        return out

    def _event(self, line):
        pass

    def status(self, *a):
        pass


class Swinging(unittest.TestCase):
    def test_leaves_only_after_analyze(self):
        cells = {(1, 0, 0): LEAVES, (2, 0, 0): LEAVES, (3, 0, 0): AIR}
        world = {(1, 0, 0): "BiomesOPlenty:leaves4", (2, 0, 0): "minecraft:dirt"}
        s = FakeScout(world, (0, 0, 0))
        ok = asyncio.run(name.fly(s, cells, ["e", "e", "e"], {LEAVES}))
        self.assertFalse(ok)                                   # stopped at the dirt
        self.assertEqual(s.swings, [(1, 0, 0)])                # the real leaves only
        self.assertNotEqual(cells[(2, 0, 0)], AIR)             # the dirt left solid in the map

    def test_no_leaves_flag_no_swing(self):
        cells = {(1, 0, 0): AIR}
        s = FakeScout({}, (0, 0, 0))
        asyncio.run(name.fly(s, cells, ["e"], ()))
        self.assertEqual(s.swings, [])


class FloorScout(FakeScout):
    """Under its floor (robot/server.lua) analyze and scan answer `err low energy`, the rest of
    the batch `skip`, until it is charged; `floor_from`: the scan or analyze batch it starts at."""

    def __init__(self, world, pos, floor_from=1, **kw):
        super().__init__(world, pos, **kw)
        self.floor_from, self.spending, self.charges, self.refused = floor_from, 0, 0, 0

    async def run(self, cmd):
        if cmd.startswith("chunk"):
            return "true"
        return await super().run(cmd)

    async def batch(self, cmds):
        w = cmds[0].split() if cmds else [""]
        if w[0] in ("analyze", "scan"):
            self.spending += 1
            if self.charges == 0 and self.spending >= self.floor_from:
                self.refused += 1
                if self.refused > 50:
                    raise AssertionError("asked again and again under the floor")
                return [("err", "low energy: send back")] + [("skip", "")] * (len(cmds) - 1)
        if w[0] == "analyze":
            return [("ok", await self.run(c)) for c in cmds]
        if w[0] == "scan":
            self.scans += len(cmds)
            return [("ok", ",".join(["1.5"] * 3 + ["0"] * (int(c.split()[4]) - 3))) for c in cmds]
        return await super().batch(cmds)

    async def close(self):
        pass


class Floor(unittest.TestCase):
    """2026-10-04: the robot's floor refused analyze at a stop the scout already stood in, and
    name.py asked the same stop thousands of times; survey.py dropped the waypoint unscanned."""

    def setUp(self):
        self.saved = (survey.load, survey.save, survey.go_charge, name.connect)

        async def go_charge(scout, cells, leaves=(), rules=None):
            scout.charges += 1
        survey.go_charge = go_charge
        survey.save = lambda *a, **k: None

    def tearDown(self):
        survey.load, survey.save, survey.go_charge, name.connect = self.saved

    def test_name_charges_instead_of_asking_forever(self):
        cells = terrain()
        guessed = {(FAR, 0, 0), (FAR + 1, 0, 0)}
        world = {(FAR, 0, 0): "minecraft:dirt", (FAR + 1, 0, 0): "minecraft:dirt"}
        s = FloorScout(world, (FAR, 1, 0))
        survey.load = lambda path=None: (list(PAL), cells, guessed)

        async def connect(prefix, tries=12):
            return s
        name.connect = connect
        argv, sys.argv = sys.argv, ["name.py", "fake"]
        try:
            asyncio.run(name.main())
        finally:
            sys.argv = argv
        self.assertGreaterEqual(s.charges, 1)
        self.assertEqual(guessed & {(FAR, 0, 0), (FAR + 1, 0, 0)}, set())   # both named

    def test_survey_scans_the_waypoint_after_charging(self):
        import zones
        cells = terrain(x0=FAR - 15, x1=FAR + 15, z0=-15, z1=15)
        hole = {(x, z) for x in range(FAR - 14, FAR - 11) for z in range(-15, 16)}
        for c in [c for c in cells if (c[0], c[2]) in hole]:
            del cells[c]
        s = FloorScout({}, (FAR, 3, 0), park=(FAR, 3, 0))
        survey.load = lambda path=None: (list(PAL), cells, set())

        async def reach(prefix, tries=6, **kw):
            return s
        saved = (survey.rlink.reach, zones.fixed, zones.anchor)
        survey.rlink.reach, zones.fixed, zones.anchor = reach, dict, lambda: (0, 0, 0)
        try:
            asyncio.run(survey.survey("fake", (FAR - 15, -15, FAR + 15, 15), -6, 12, "m",
                                      (FAR, 3, 0)))
        finally:
            survey.rlink.reach, zones.fixed, zones.anchor = saved
        self.assertGreaterEqual(s.charges, 1)
        left = {k for k in hole if (k[0], 0, k[1]) not in cells}
        self.assertEqual(left, set())                                    # all scanned


class Energy(unittest.TestCase):
    def test_scan_round_keeps_the_way_home(self):
        far = (60, 10, 60)
        s = FakeScout({}, far, energy=survey.home_cost(far, (0, 0, 0)) - 1)
        found = asyncio.run(survey.air_round(s, {}))
        self.assertEqual((found, s.scans), (0, 0))

    def test_scan_round_spends_only_the_spare(self):
        far = (60, 10, 60)
        s = FakeScout({}, far, energy=survey.home_cost(far, (0, 0, 0)) + 5 * survey.SCAN_COST)
        asyncio.run(survey.air_round(s, {}))
        self.assertLessEqual(s.scans, 5)


class Bounds(unittest.TestCase):
    """Every retry bounded (the audit, 2026-10-04): a stop that cannot be reached, a scout with
    no way home, a job's time, the chunkloader checked."""

    def setUp(self):
        self.saved = (survey.load, survey.save, survey.go_charge, name.connect, survey.fly)
        survey.save = lambda *a, **k: None

    def tearDown(self):
        survey.load, survey.save, survey.go_charge, name.connect, survey.fly = self.saved

    def run_name(self, scout, cells, guessed, *args):
        survey.load = lambda path=None: (list(PAL), cells, guessed)

        async def connect(prefix, tries=12):
            return scout
        name.connect = connect
        argv, sys.argv = sys.argv, ["name.py", "fake", *args]
        try:
            asyncio.run(name.main())
        finally:
            sys.argv = argv

    def test_a_stop_never_reached_is_set_aside(self):
        cells = terrain()
        guessed = {(FAR + 3, 0, 0)}
        s = FloorScout({}, (FAR, 1, 0), floor_from=10 ** 9)
        flights = []

        async def fly(scout, cells, path, home=False):          # every flight blocked
            flights.append(path)
            return False
        survey.fly = fly

        async def go_charge(scout, cells, leaves=(), rules=None):
            pass
        survey.go_charge = go_charge
        self.run_name(s, cells, guessed)
        self.assertLessEqual(len(flights), survey.TRIES)

    def test_times_up_at_a_stop(self):
        cells = terrain()
        guessed = {(FAR + 3, 0, 0)}
        s = FloorScout({}, (FAR, 1, 0), floor_from=10 ** 9)
        homes = []

        async def go_charge(scout, cells, leaves=(), rules=None):
            homes.append(1)
        survey.go_charge = go_charge
        self.run_name(s, cells, guessed, "--minutes", "0")
        self.assertEqual(homes, [])                             # not flown home: left there
        self.assertIn((FAR + 3, 0, 0), guessed)                 # and nothing done

    def test_stranded_says_so(self):
        cells = terrain(ground=3)
        cells[(FAR, 0, 0)] = AIR                                # sealed in, no air round it
        s = FakeScout({}, (FAR, 0, 0), park=(FAR, 8, 0))
        s.scanned_at = (FAR, 0, 0)                              # its scan round done before
        with self.assertRaises(SystemExit) as e:
            asyncio.run(self.saved[2](s, cells, rules=rules(cells)))
        self.assertIn("STRANDED", str(e.exception))

    def test_chunkloader_checked(self):
        class Off(FakeScout):
            async def run(self, cmd):
                return "false" if cmd == "chunk on" else await super().run(cmd)
        self.assertFalse(asyncio.run(survey.chunk_on(Off({}, (0, 0, 0)))))
        self.assertTrue(asyncio.run(survey.chunk_on(FloorScout({}, (0, 0, 0)))))


class RealMap(unittest.TestCase):
    """The 59 cells dug on 2026-10-04 and the water in them: refused on the real map. Their
    list is data/scout-damage.txt (the user's world: gitignored, so skipped where absent)."""

    def test_tunnels_refused(self):
        data = os.path.join(HERE, "data")
        damage, near = (os.path.join(data, f) for f in ("scout-damage.txt", "map-tom-near.txt"))
        if not (os.path.exists(damage) and os.path.exists(near)):
            self.skipTest("no data/scout-damage.txt or data/map-tom-near.txt here")
        dug = []
        for line in open(damage, encoding="utf-8"):
            p = line.split()
            if len(p) > 4 and p[1] == "robot":
                dug.append(tuple(map(int, p[2:5])))
        self.assertEqual(len(dug), 59)
        pal, cells, guessed = survey.load(near)
        r = survey.Rules(cells, pal, guessed)
        bad = [c for c in dug if r.explore(c) or r.travel(c)]
        self.assertEqual(bad, [])
        for c in ((3, -8, 9), (10, -8, 16), (9, -8, 16)):
            self.assertFalse(r.travel(c))
        # Without the refused list, the sky rule alone refuses a deep cell unless digging left
        # it an open shaft to the sky (all air above): those the list must keep out.
        bare = survey.Rules(cells, pal, guessed, refused=set())
        for c in (c for c in dug if c[1] <= -3 and bare.explore(c)):
            above = [cells.get((c[0], y, c[2])) for y in range(c[1] + 1, 3)]
            self.assertTrue(all(v == 0 for v in above), c)


if __name__ == "__main__":
    unittest.main(verbosity=2)
