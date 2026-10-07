"""builders.py - the crew builds a plan in sectors (3d-draw/docs/building.md,
"Building in sectors").

    python 3d-draw/builders.py --plan data/harbour.txt [--robots 016db072,a77c49f1] [--steps N]
                               [--no-craft] [--map data/map-village.txt] [--dig]
    python 3d-draw/builders.py --home      every builder to its park, charged

Why it is this way (2026-10-04): the planner before (design/build.py, crew.py) worked out one
order for one robot and ran it with five; builders swung at cells others stood in and broke three
of them (Cortana's item despawned, she is gone), dug through ground to travel and sealed
themselves in, trusted the scouts' guesses and dug into the riverbed, and stood idle through
hour-long plans. The user: "so your planner is clearly bad, what you are doing makes no sense, you
kill other bots you get stuck non-stop"; and chose "Full redesign before building". So:

  - SECTORS. The work is cut into sectors (buildsite.Site.sectors). A robot leases one and builds
    all it can there; no two sectors closer than GAP are worked at once. Two builders never work
    the same cells, so a swing never meets a builder (robot/server.lua refuses one anyway).
  - NEVER DIG TO TRAVEL. Moves break nothing. A robot goes through air (known, or unknown and
    found out by moving), into water only where a planned block replaces it or the user allowed
    it (data/wet-ok.txt). Between sectors it flies a lane of its own, over everything the plan
    will build: the lanes are at different heights, so two robots never meet head on.
  - BREAK ONLY TO PLACE. Ground in a planned cell is broken by the robot standing outside it, in
    the same batch as the place (`swing; place; analyze`): no hole is left to fall into.
  - LOOK BEFORE TRUSTING. On leasing a sector the robot scans its columns (one batch) and the map
    takes what the geolyzer read over the scouts' guesses; only known blocks are clicked.
  - A STUCK ROBOT STOPS AND SAYS SO. It never digs itself out; the crew goes on without it.
"""
import asyncio, heapq, os, sys, time
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import buildsite                                                         # noqa: E402
from buildsite import in_box, apart                                      # noqa: E402
from placing import DIRS, OPP, add, options, item_of, reads_right, COBBLE  # noqa: E402
from placing import HOE, TILLED, TILLABLE, CROP, H, full                  # noqa: E402
from placing import SUBSTITUTE, substitutes                               # noqa: E402


def items_for(block):
    """The items that can build a plan cell: its own, then what may stand in for it."""
    return [item_of(b[0], b[1]) for b in substitutes(block)]

CREW = [  # prefix, name, park, crafts first
    ("858fde4e", "G.U.N.T.E.R.", (0, 0, 0), True),     # the start block; crafts what is short
    ("f4470a27", "ASIMO", (2, 0, -2), False),          # east of the second charger
    ("a77c49f1", "Pintsize", (0, 0, -2), False),       # west of it
    ("a4c330bf", "Baymax", (1, -1, -2), False),        # under it, over water
    ("1bf71bda", "Dalek_Sec", (1, 1, -2), False),      # on top of it (the user, 2026-10-04)
]
DEPOT = (-3, 4, -5, 3)            # x0 x1 z0 z1: the station, the parks, the interface
# Cells between two sectors worked at once: 2 keeps every target and every cell to stand in
# apart (targets in the sector, stands MARGIN out of it); 3 left two of five builders without a
# sector (2026-10-04, the harbour, run 4)
GAP = 2
SECTOR = 70                       # blocks a sector, about: smaller, more of them to go round
WIDE = 8                          # and cells across at most (buildsite.Site.sectors)
MARGIN = 1                        # how far outside its sector a builder may stand
FREE = 3                          # slots kept empty for what a swing brings in (load)
# How far round a sector left unfinished a block built makes it worth another try
RETRY = 2
# Cells round a sector's blocks that are its too: a builder stands and finds its way only in its
# sector and MARGIN round it, and a sector cut down to one block's bounds left it a 3 by 3 area
# to go round in - the blocks of a tree by the lighthouse were left so (the simulation,
# 2026-10-04)
PAD = 2
KIT = 24                          # how far round its sector the work its kit is loaded for
SCAN_NEAR = 12                   # how far across a builder scans a sector from (look_over)
NEAR = 4                          # how far round its ends a way up to a lane or down may go
OUT = 12                          # how far round, when there is no way up near (route)
CHAIN = 5                         # the most helpers in one chain (3 left the lighthouse's top)
DIRT = ("minecraft:dirt", 0)
# Never broken to get in: what hangs on a wall goes with it, and glass drops nothing
HANGS = ("ladder", "torch", "trapdoor", "door", "sign", "lever", "button", "gate", "bars",
         "pane", "rail")
WEST, EAST = ((0, 0, 1), "e", (1, 2, 3), 4), ((2, 0, 1), "w", (5, 6, 7), 8)
SAW = ("gregtech:gt.metatool.01", 10)
ROBOT = "OpenComputers:robot"
LOW, FLOOR = 0.4, 1500            # charge under this share; robot/server.lua's own floor
RESERVE = 8000                    # energy kept for a sector's way there and back
SLEEP = 1.0                       # sim.py runs on a clock of its own (simulated seconds)
# One line an action, for probe.py (the user, 2026-10-04: "plz also add random probing for
# efficiency, if the robots do things that are 400% ineficient, maybe come up with a strategy to
# fix it"): when, robot, action, cell, seconds, batches, moves, the way's length for a go, how
# deep in another action it was (a go inside a place is 1), and a note. None: no log.
ACTIONS = os.path.join(HERE, "data", "actions.log")
CLOCK = time.time                 # sim.py: its simulated clock


# What a link's error says when the robot is gone from the relay (rlink.py, sim.py): the builder
# stops there, it does not try the next block
LINK_LOST = ("link was closed", "gave no answer", "relay closed", "cannot reach")


class Stuck(Exception):
    """A robot that cannot get on: it stops where it is, and says so."""


def dist(a, b):
    return sum(abs(p - q) for p, q in zip(a, b))


def center(box):
    return ((box[0] + box[1]) // 2, 0, (box[2] + box[3]) // 2)


async def nap(s):
    await asyncio.sleep(s * SLEEP)


class Crew:
    """What the builders share: the site, the sectors and who holds which, where each robot is,
    the mini ME's link, the record."""

    def __init__(self, site, me, record):
        self.site, self.me, self.record = site, me, record
        self.leased = {}                  # box -> robot name
        self.given_up = {}                # cell -> (the sector it was left in, signature then)
        self.dig = False                  # --dig: the plan's air cells are dug (dig_plan_air)
        self.lacking = set()              # items the mini ME has none of
        self.boxes = []
        self.recut()
        self.pos = {}                     # robot name -> cell
        self.depot = asyncio.Lock()       # one robot moving among the parks at a time
        self.me_lock = asyncio.Lock()
        self.stuck, self.events = [], []
        self.free_sides, self.side_holder = [], {}
        self.refill = set(site.dug)       # ground dug outside the plan, to fill back
        self.scanned = {}                 # (x, z) -> (lo, hi): columns read this run (look_over)

    def others(self, name):
        return {c for n, c in self.pos.items() if n != name}

    def todo(self, box):
        return [c for c in self.site.pending() if in_box(c, box)]

    def signature(self, box):
        """How much is done in and round a sector: a sector left unfinished is leased again only
        once this has changed (something built next to it may give its rest a face to click)."""
        return sum(1 for c in self.site.plan if in_box(c, box, RETRY) and self.site.done(c))

    def live(self):
        """The pending cells free to be cut into sectors: in no leased sector, and not given up
        as things stand (given up in a sector round which nothing has been built since)."""
        sig, out = {}, []
        for c in self.site.pending():
            if any(in_box(c, b) for b in self.leased):
                continue
            if all(it in self.lacking for it in items_for(self.site.plan[c])):
                # none in the mini ME: it waits for the user, not leased and given up again
                # and again (the village's simulation, 2026-10-04: 4263 leases in 170 minutes,
                # nearly all of them for blocks the ME had run out of)
                continue
            g = self.given_up.get(c)
            if g:
                if g[0] not in sig:
                    sig[g[0]] = self.signature(g[0])
                if sig[g[0]] == g[1]:
                    continue
            out.append(c)
        return out

    def recut(self):
        """The sectors cut again from what is left, at each lease and release: cut once at the
        start, they kept the shape of the whole plan's work while what was left of it shrank to
        scattered blocks (2026-10-04, the harbour's end)."""
        self.boxes = [(b[0] - PAD, b[1] + PAD, b[2] - PAD, b[3] + PAD)
                      for b in self.site.sectors(SECTOR, wide=WIDE, cells=self.live())]
        return self.boxes

    def lease(self, name, at):
        best = None
        for box in self.recut():
            if any(not apart(box, b, GAP) for b in self.leased):
                continue
            todo = self.todo(box)
            if not todo:
                continue
            key = (min(c[1] for c in todo), dist(at, center(box)))
            if best is None or key < best[0]:
                best = (key, box)
        if best:
            self.leased[best[1]] = name
            return best[1]
        return None

    def release(self, box, finished):
        self.leased.pop(box, None)
        todo = self.todo(box)
        if finished:
            for c in todo:
                self.given_up.pop(c, None)
        else:
            sig = self.signature(box)
            for c in todo:
                self.given_up[c] = (box, sig)
        self.recut()

    def finished(self):
        """Nothing leased, and nothing that could be: what is left cannot be built as things
        are."""
        return not self.leased and not self.live()

    def note(self, what, c):
        if self.record:
            with open(self.record, "a", newline="\n") as f:
                f.write(f"{what} {c[0]} {c[1]} {c[2]}\n")


class Builder:
    def __init__(self, crew, prefix, name, park, crafts, idx, reach):
        self.crew, self.prefix, self.name, self.home = crew, prefix, name, tuple(park)
        self.crafts, self.idx, self.reach = crafts, idx, reach
        self.fails, self.placed, self.idle = {}, 0, 0
        # the last load's items taken (None: no trip); sectors left "later" with nothing built
        self.loaded, self.later_runs, self.placed_at = None, 0, 0
        self.relinks = 0                  # times the link was reached again after a drop
        self.moves, self.depth = 0, 0     # moves made; actions open round the one now (the log)
        self.held, self.dirty = {}, True
        # robot/server.lua's way home, as it keeps it: its energy floor is 12 a step of it plus
        # 1500, and under that it does nothing but go home (a scout was stranded so, 2026-10-04)
        self.trail = []
        self.cur_area = None
        self.cur_box = None
        self.air_blocks = {}              # cells that read empty and would not let it in
        self.holding = None               # (spot cell, side name) of the interface it holds
        self.open_for = {}                # cell cleared -> the block it was cleared to stand for
        self.equipped, self.tool_slot = None, None   # the hoe while in a field, and where the
                                                     # robot's own tool went meanwhile

    async def connect(self):
        self.r = await self.reach(self.prefix)
        hello = (await self.r.run("hello")).split()
        self.size = int(hello[6])
        self.r.energy, self.max = int(hello[4]), int(hello[5])
        self.r.pos = [int(v) for v in hello[:3]]
        self.crew.pos[self.name] = self.at()
        return self

    def at(self):
        return tuple(self.r.pos)

    def say(self, *a):
        print(f"  {self.name}:", *a, flush=True)

    # ---- the action log (probe.py) ------------------------------------------------------------

    def log_action(self, what, cell, t0, b0, m0, way="-", note=""):
        if not ACTIONS:
            return
        t = CLOCK()
        c = ",".join(map(str, cell)) if cell else "-"
        note = str(note or "-").replace(" ", "_")
        with open(ACTIONS, "a", newline="\n") as f:
            f.write(f"{time.strftime('%H:%M:%S', time.localtime(t))} {t:.1f} {self.name} {what} "
                    f"{c} {t - t0:.1f} {getattr(self.r, 'answered', 0) - b0} {self.moves - m0} "
                    f"{way} {self.depth} {note}\n")

    async def timed(self, what, cell, aw):
        """An action awaited and written to the log, with what it returned as its note."""
        t0, b0, m0 = CLOCK(), getattr(self.r, "answered", 0), self.moves
        res = "error"
        self.depth += 1
        try:
            res = await aw
            return res
        finally:
            self.depth -= 1
            self.log_action(what, cell, t0, b0, m0, "-", res)

    async def pause(self, what, s):
        """A wait, logged: idle for want of a sector, side for the interface, robot for a robot
        in the way."""
        t0, b0, m0 = CLOCK(), getattr(self.r, "answered", 0), self.moves
        await nap(s)
        self.log_action(what, None, t0, b0, m0)

    # ---- the whole job ------------------------------------------------------------------------

    async def craft_first(self):
        """What the plan still needs beyond what the mini ME holds, crafted (Gunter, before he
        builds; craft.py: in batches, at the interface's west side)."""
        import craft
        need = {}
        for c in self.crew.site.pending():
            it = item_of(*self.crew.site.plan[c][:2])
            need[it] = need.get(it, 0) + 1
        spot, name = await self.side()
        self.holding = (spot[0], name)
        try:
            await self.load({})                              # empty-handed but for the saw
            await self.go(spot[0])
            c = craft.Crafter(self.r, self.crew.me, spot)
            await c.at_interface()
            try:
                asks = await c.short(need)
            finally:
                await c.deposit_all()
        except BaseException:
            self.holding = None
            async with self.crew.me_lock:
                await self.crew.me.batch([f"release {name} {self.name}"])
            raise
        self.dirty = True
        if asks:
            self.say(f"no recipe for {asks}: to ask the user for")

    async def run(self, limit=None):
        try:
            if self.crafts:
                try:
                    await self.craft_first()
                except (Exception, SystemExit) as e:
                    # craft.py ends on SystemExit when a craft fails: inside a coroutine that
                    # would end the whole crew (2026-10-04); Gunter builds without it instead
                    self.say(f"crafting stopped: {e!r}; building with what there is")
            while limit is None or self.placed < limit:
                await self.charge_if_low()
                box = self.crew.lease(self.name, self.at())
                if box is None:
                    if self.crew.finished():
                        break
                    await self.go(self.home, home=True)
                    self.idle += 1
                    await self.pause("idle", 5)
                    continue
                how = "stuck"
                try:
                    how = await self.work(box, limit)
                except Exception as e:
                    # The relay dropped the link mid-batch (the field's trial, 2026-10-04:
                    # Gunter answered at once when reached again, safe where he stood): reached
                    # again, twice at most a run, and on; the sector is not given up for it
                    if not any(k in str(e) for k in LINK_LOST) or self.relinks >= 2:
                        raise
                    self.relinks += 1
                    self.say(f"link lost ({e!r}); reaching it again")
                    await self.connect()
                    self.dirty, how = True, "later"
                finally:
                    self.crew.release(box, how != "stuck")
                    t = CLOCK()
                    self.log_action("release", center(box), t, getattr(self.r, "answered", 0),
                                    self.moves, "-", f"{how},box={box[0]}..{box[1]}/{box[2]}.."
                                    f"{box[3]},left={len(self.crew.todo(box))}")
            await self.go(self.home, home=True)
        except Stuck as e:
            self.say(f"STUCK at {self.at()}: {e}")
            self.crew.stuck.append((self.name, self.at(), str(e)))
            self.log_action("ended", self.at(), CLOCK(), 0, self.moves, "-", f"STUCK:{e}")
        except Exception as e:
            # Said at once, where it stands: a builder whose coroutine ended on an error was
            # silent till the whole crew ended (Pintsize, 2026-10-04, run 8: found "done" in
            # crew-stacks.txt, at (-9, 21, -28), the error never printed). A robot gone quiet
            # is urgent (the user, after Cortana).
            import traceback
            self.say(f"ENDED on {e!r} at {self.at()}")
            traceback.print_exc()
            sys.stdout.flush()
            self.crew.stuck.append((self.name, self.at(), repr(e)))
            self.log_action("ended", self.at(), CLOCK(), 0, self.moves, "-", f"ENDED:{e!r}")

    async def work(self, box, limit):
        """A sector: blocks loaded for it, its columns looked at, then all it can build there.
        -> whether it is done."""
        todo = self.crew.todo(box)
        self.say(f"sector x {box[0]}..{box[1]} z {box[2]}..{box[3]}: {len(todo)} to build")
        want = {}
        for c in todo:
            it = item_of(*self.crew.site.plan[c][:2])
            want[it] = want.get(it, 0) + 1
        want[COBBLE] = want.get(COBBLE, 0) + 4                 # helpers
        if any(in_box(c, box, MARGIN + 1) for c in self.crew.site.dig_ok):
            want[DIRT] = want.get(DIRT, 0) + 12                # to fill back what it digs
        if HOE in want:
            want[HOE] = 0 if self.equipped == HOE else 1      # a tool, not spent
        # The work left near it, the nearest first: the kit for its next sectors, taken along
        # when it goes to the interface anyway (load). Counted over the whole plan, the kit was
        # the plan's commonest items, and a builder went back for each next sector's (the
        # village's simulation, 2026-10-04: 163 loads of 2 minutes and 59 moves each)
        mid, later = center(box), {}
        near = sorted((c for c in self.crew.site.pending() if not in_box(c, box)
                       and dist((c[0], 0, c[2]), mid) <= KIT),
                      key=lambda c: dist((c[0], 0, c[2]), mid))
        for c in near:
            it = item_of(*self.crew.site.plan[c][:2])
            later[it] = later.get(it, 0) + 1
        await self.timed("load", None, self.load(want, later))
        await self.timed("look_over", center(box), self.look_over(box))
        while limit is None or self.placed < limit:
            if self.dirty:
                await self.inv()
            have = {(a, b) for a, b, n in self.held.values() if n > 0}
            if self.equipped:
                have.add(self.equipped)
            act = self.choose(box, have)
            if act is None:
                await self.tool_back()
                await self.refill_holes(box)
                # Nothing it can do with what it holds. Blocks the mini ME has none of wait for
                # the user (crew.lacking); for blocks it does have, back to load (2026-10-04:
                # builders went to the interface and back for barrels the ME had none of, over
                # and over, building nothing).
                lacking = {item_of(*self.crew.site.plan[c][:2]) for c in self.crew.todo(box)
                           if self.fails.get(c, 0) < 3
                           and not have & set(items_for(self.crew.site.plan[c]))}
                # back for them - unless the last load brought nothing, or this sector has been
                # left so twice with nothing built: then it is given up till things change
                # (the livelock of the village's simulation, above load)
                self.later_runs = self.later_runs + 1 if self.placed == self.placed_at else 0
                self.placed_at = self.placed
                if lacking - self.crew.lacking and self.loaded != 0 and self.later_runs < 2:
                    return "later"
                return "stuck"
            try:
                if act[0] == "clear":
                    if not await self.timed("clear", act[1], self.cleared(*act[1:])):
                        self.fails[act[1]] = self.fails.get(act[1], 0) + 1
                    continue
                if act[0] == "breakin":
                    if not await self.timed("breakin", act[1], self.broke_in(*act[1:])):
                        self.fails[act[1]] = self.fails.get(act[1], 0) + 1
                    continue
                if act[0] == "till":
                    ok = await self.timed("till", act[1], self.till(*act[1:]))
                    if not ok:
                        self.fails[act[1]] = self.fails.get(act[1], 0) + 1
                    continue
                ok = await self.timed(act[0], act[1], self.place(*act[1:]) if act[0] == "place"
                                      else self.helped(*act[1:]))
            except Stuck as e:
                # no way to the cell to stand in (what the map did not know): that block is
                # tried another way, or left; stuck for good shows on the way out of the sector
                self.say(f"{act[1]}: {e}")
                self.fails[act[1]] = self.fails.get(act[1], 0) + 1
                continue
            except Exception as e:
                # A command that failed (an analyze, an inventory read) costs that block a
                # try, said aloud; a link lost ends the builder (run() says so at once)
                if any(k in str(e) for k in LINK_LOST):
                    raise
                self.say(f"{act[0]} at {act[1]} failed: {e!r}")
                self.fails[act[1]] = self.fails.get(act[1], 0) + 1
                continue
            if not ok and act[0] == "place":
                self.fails[act[1]] = self.fails.get(act[1], 0) + 1
            if self.low():
                break                         # back for energy: not given up
        await self.tool_back()
        await self.refill_holes(box)
        return "done" if not self.crew.todo(box) else "later"

    async def short_of_anything(self, box):
        """Whether what is left in the sector needs blocks the robot holds none of (it goes back
        to the interface when the sector is leased again)."""
        if self.dirty:
            await self.inv()
        have = {(a, b) for a, b, n in self.held.values() if n > 0}
        return any(not have & set(items_for(self.crew.site.plan[c]))
                   for c in self.crew.todo(box) if self.fails.get(c, 0) < 3)

    # ---- choosing -----------------------------------------------------------------------------

    def area(self, box):
        """The cells a builder works its sector from: the sector and MARGIN round it, from under
        the lowest work to the lane."""
        site = self.crew.site
        todo = self.crew.todo(box)
        y0 = min([c[1] for c in todo] + [self.at()[1]]) - 4
        return (box[0] - MARGIN, box[1] + MARGIN, y0, self.lane_over(box),
                box[2] - MARGIN, box[3] + MARGIN)

    def lane_over(self, box):
        site = self.crew.site
        top = max(site.column_top(x, z) for x in range(box[0] - NEAR, box[1] + NEAR + 1)
                  for z in range(box[2] - NEAR, box[3] + NEAR + 1))
        return top + 2 + self.idx

    def reachable(self, area, extra=(), known=False):
        """Every cell the builder can get to in `area` from where it is, and the way: {cell:
        cost}. `extra`: cells taken as solid (a block about to be placed). `known`: through
        cells known to be open only - what a way out may count on (2026-10-04, the simulation:
        four builders sealed themselves in, the way out they counted on unknown ground)."""
        site, start = self.crew.site, self.at()
        x0, x1, y0, y1, z0, z1 = area
        others = self.crew.others(self.name)
        dist_ = {start: 0}
        q = [(0, start)]
        while q:
            d, c = heapq.heappop(q)
            if d > dist_[c]:
                continue
            for k in DIRS:
                n = add(c, k)
                if not (x0 <= n[0] <= x1 and y0 <= n[1] <= y1 and z0 <= n[2] <= z1):
                    continue
                if n in others or n in extra:
                    continue
                w = site.cost(n)
                if w is None or (known and site.kind(n) == "unknown"):
                    continue
                if d + w < dist_.get(n, 1e9):
                    dist_[n] = d + w
                    heapq.heappush(q, (d + w, n))
        return dist_

    def way_out(self, reach, area):
        """Whether one of the cells it reaches has an open column up to the lane: a way out of
        the sector."""
        site, top = self.crew.site, area[3]
        for c in reach:
            if all(site.cost((c[0], y, c[2])) is not None
                   and site.kind((c[0], y, c[2])) != "unknown" for y in range(c[1] + 1, top + 1)):
                return True
        return False

    def choose(self, box, have=None):
        """The next block to place, and how: the lowest first, then the nearest; only a click
        on a known face, from a cell it can reach, leaving it a way out; only a block it holds
        (`have`, items)."""
        site = self.crew.site
        area = self.cur_area = self.area(box)
        self.cur_box = box
        reach = self.reachable(area)
        # a cell cleared to stand in stays open until what it was cleared for is built: placed
        # back at once, it was cleared again, for ever (the simulation)
        held = {c for c, t in self.open_for.items() if t in self.crew.site.pending()
                and self.fails.get(t, 0) < 3}
        todo = sorted((c for c in self.crew.todo(box) if self.fails.get(c, 0) < 3
                       and c not in held and (have is None
                                              or have & set(items_for(site.plan[c])))),
                      key=lambda c: (c[1], dist(c, self.at())))
        later = []
        act = self.dig_plan_air(box, reach) if self.crew.dig else None
        if act:
            return act
        for c in todo:
            if site.plan[c][0] == TILLED:
                act = self.till_option(c, reach)
                if act:
                    return act
                continue
            if site.plan[c][0] == CROP and add(c, "d") not in site.placed:
                continue                  # seeds only on farmland tilled: not on grass
            for sd, f in options(site.plan[c]):
                stand, face = add(c, OPP[sd]), add(c, f)
                if stand not in reach or stand == c:
                    continue
                if not site.clickable(face, f, sd):
                    later.append((c, sd, f, stand, face))
                    continue
                if self.closes_in(stand, c, area):
                    continue
                return ("place", c, sd, f, stand)
        for c, sd, f, stand, h in later:                        # a helper to click
            act = self.helper_for(c, sd, f, stand, h, reach, area)
            if act:
                return act
        act = self.clearing(todo, reach, area)
        if act:
            return act
        act = self.breaking_in(todo, reach)
        if act:
            return act
        if todo:
            self.why_not(todo, reach, area)
        return None

    def dig_plan_air(self, box, reach):
        """A cell the plan wants empty (`minecraft:air` in it: the field's terraces cut into the
        slope, the flowers over them) that still holds something, in the sector, the highest
        first, broken from a cell beside or over it - never one by water, which would run in.
        Only with --dig (the field, 2026-10-04: the user approved the village, its digs with
        it); left undug, the wheat had no stand that kept a way out."""
        site = self.crew.site
        todo = self.crew.todo(box)
        low = min([c[1] for c in todo] or [0]) + 3
        # what stands in the work's way first (the terraces, the flowers on them), top down;
        # a tree's crown over it last (the field's trial, 2026-10-04: Gunter began at its top)
        cells = sorted((c for c in site.clear if in_box(c, box)
                        and site.kind(c) in ("solid", "guess")),
                       key=lambda c: (c[1] > low, -c[1], dist(c, self.at())))
        for c in cells:
            if any(site.kind(add(c, d)) == "water" for d in DIRS):
                continue
            for d in ("d",) + H + ("u",):
                s_ = add(c, OPP[d])
                if s_ in reach:
                    return ("clear", c, d, s_)
        return None

    def clearing(self, todo, reach, area):
        """A planned cell that holds ground and stands where the builder must stand to place
        another: broken now (from a cell beside it), its own block placed later. Only the plan's
        cells, never ground outside it; never next to water, which would run in; the highest
        first, so it digs down from the open side (the rocks set into the slope at the
        lighthouse's foot, 2026-10-04: every cell to stand in was the slope's own ground)."""
        site = self.crew.site
        pend = set(todo)
        wanted = []
        for t in todo:
            for sd, f in options(site.plan[t]):
                s_ = add(t, OPP[sd])
                if s_ not in reach and site.kind(s_) in ("solid", "guess") \
                        and site.clickable(add(t, f), f, sd) and s_ not in self.open_for \
                        and (s_ in pend or s_ in site.clear
                             or s_ in site.dig_ok and s_ not in site.plan):
                    # a planned cell; a cell the plan wants empty (the field's terraces, cut
                    # into the slope, flowers over them: the stands to till from, 2026-10-04);
                    # or ground outside the plan where the user let builders dig, to be filled
                    # back (the lighthouse's base, 2026-10-04)
                    wanted.append((s_, t))
        for c, t in sorted(set(wanted), key=lambda ct: (-ct[0][1], dist(ct[0], self.at()))):
            if any(site.kind(add(c, d)) == "water" for d in DIRS):
                continue
            for d in DIRS:
                s_ = add(c, OPP[d])
                if s_ in reach and s_ != c:
                    self.open_for[c] = t
                    return ("clear", c, d, s_)
        return None

    async def cleared(self, c, d, stand):
        site = self.crew.site
        await self.go(stand)
        st, why = (await self.r.batch([f"swing {d}"]))[0]
        self.dirty = True
        if st == "ok":
            site.learn(c, "air")
            if c in site.clear:
                self.crew.note("cleared", c)          # the plan wants it empty: stays so
            elif c not in site.plan:
                self.crew.refill.add(c)
                self.crew.note("dug", c)
            return True
        if "liquid" in why:
            site.learn(c, "water")
            return True
        self.say(f"could not clear {c}: {why}")
        if "robot" in why:
            raise Stuck(f"a robot in the cell it is to clear, {c}")
        site.learn(c, "solid")
        return False

    def breaking_in(self, todo, reach):
        """A wall to break to get in: blocks to place inside what is built, with a cell to stand
        in there that cannot be reached. A built full block between a cell it reaches and an
        empty one it does not - nothing hanging on it, not glass, no water by it - broken now,
        kept open till the work inside is done, then built again (the user, 2026-10-04: "you can
        break in safer through a wall, search for such a wall and place it back afterwards";
        the lighthouse's inside, closed by its own walls)."""
        site = self.crew.site
        inside = {}
        for t in todo:
            for sd, f in options(site.plan[t]):
                s_ = add(t, OPP[sd])
                if s_ not in reach and site.kind(s_) == "air" and site.clickable(add(t, f), f, sd):
                    inside[s_] = t
        if not inside:
            return None
        best = None
        for w in site.placed:
            if w in self.open_for or not full(site.plan[w][0]) \
                    or "glass" in site.plan[w][0] or not in_box(w, self.cur_box, MARGIN):
                continue
            near = [add(w, d) for d in DIRS]
            if any(site.kind(n) == "water" for n in near):
                continue
            names = [(site.name(n) or "").lower() for n in near]
            if any(k in nm for nm in names for k in HANGS):
                continue
            above = (site.name(add(w, "u")) or "").lower()
            if "sand" in above or "gravel" in above:
                continue
            outs = [d for d in DIRS if add(w, OPP[d]) in reach]
            ins = [n for n in near if n not in reach and site.kind(n) == "air"]
            if not outs or not ins:
                continue
            key = min(dist(n, s_) for n in ins for s_ in inside)
            if best is None or key < best[0]:
                best = (key, w, outs[0], ins[0])
        if best is None or best[0] > 4:
            return None
        _, w, d, n = best
        target = min(inside, key=lambda s_: dist(s_, n))
        self.open_for[w] = inside[target]
        return ("breakin", w, d, add(w, OPP[d]))

    async def broke_in(self, w, d, stand):
        site = self.crew.site
        await self.go(stand)
        st, why = (await self.r.batch([f"swing {d}"]))[0]
        self.dirty = True
        if st != "ok":
            self.say(f"could not break in at {w}: {why}")
            if "robot" in why:
                raise Stuck(f"a robot in the wall it is to break, {w}")
            return False
        site.placed.discard(w)
        site.learn(w, "air")
        self.crew.note("breakin", w)
        self.say(f"broke in at {w}; it goes back when the inside is done")
        return True

    async def refill_holes(self, box):
        """Ground dug outside the plan to stand in, filled back with dirt once what it was dug
        for is built (the user: "Yes, dig and refill")."""
        site = self.crew.site
        for c in sorted(self.crew.refill, key=lambda c: -c[1]):
            if not in_box(c, box, MARGIN + 1) or site.kind(c) != "air":
                if site.kind(c) != "air":
                    self.crew.refill.discard(c)
                continue
            t = self.open_for.get(c)
            if t is not None and t in site.pending_set and self.fails.get(t, 0) < 3:
                continue                                      # still wanted as a stand
            slot = await self.slot_of(DIRT)
            if slot is None:
                self.say(f"no dirt to fill {c} back")
                continue
            area = self.area(box)
            reach = self.reachable(area)
            done = False
            for sd, f in options((DIRT[0], 0, 0, "-")):
                st_, face = add(c, OPP[sd]), add(c, f)
                if st_ in reach and site.clickable(face, f, sd) \
                        and not self.closes_in(st_, c, area):
                    await self.go(st_)
                    (pst, pv), = await self.r.batch([f"place {sd} {f} {slot}"])
                    if pst == "ok":
                        self.used(slot)
                        site.learn(c, "solid", DIRT[0])
                        self.crew.refill.discard(c)
                        self.crew.note("filled", c)
                        self.say(f"filled {c} back")
                        done = True
                    break
            if not done:
                self.say(f"could not fill {c} back yet")

    def why_not(self, todo, reach, area):
        """What keeps the sector's last blocks from being placed, counted, for the log."""
        site, why = self.crew.site, {}
        rank = ["no option", "stand out of reach", "no face, no helper", "would close it in"]
        for c in todo:
            r = "no option"
            for sd, f in options(site.plan[c]):
                stand, face = add(c, OPP[sd]), add(c, f)
                if stand not in reach:
                    k = "stand out of reach"
                elif not site.clickable(face, f, sd):
                    k = "no face, no helper"
                else:
                    k = "would close it in"
                r = max(r, k, key=rank.index)
            why[r] = why.get(r, 0) + 1
        self.say(f"leaves {len(todo)}: {why}")

    def open_column(self, c, top):
        """Whether the column over c is open to the lane, and stays so: no cell of it unknown or
        closed, and none a block another builder will put in (outside this builder's sector).
        Counted on, the edge's columns let a builder in the ship's hull be shut in by the deck
        a builder of the next sector laid (the simulation, 2026-10-04)."""
        site, box = self.crew.site, self.cur_box
        pend = site.pending_set
        for y in range(c[1] + 1, top + 1):
            n = (c[0], y, c[2])
            if site.cost(n) is None or site.kind(n) == "unknown":
                return False
            if n in pend and box and not in_box(n, box):
                return False
        return True

    def till_option(self, c, reach):
        """Farmland at c: ground the hoe can till (dirt or grass, as named or as the geolyzer
        read it), the cell over it empty, and a cell beside that one to stand in. The robot
        faces the cell over the dirt and clicks the dirt's top (`use <side> d`)."""
        site = self.crew.site
        if site.kind(c) not in ("solid", "guess") or (site.name(c) or "?") not in TILLABLE:
            return None
        over = add(c, "u")
        if site.kind(over) in ("solid", "guess") and over in site.plan \
                and not any(site.kind(add(over, d)) == "water" for d in DIRS):
            # The cell over it is the plan's (the wheat's) and still holds the slope's ground:
            # the field is cut into it in terraces. Broken first, from beside, as any planned
            # cell (the field's simulation, 2026-10-04: no farmland had air over it)
            for sd in H + ("d",):
                stand = add(over, OPP[sd])
                if stand in reach:
                    return ("clear", over, sd, stand)
            return None
        if site.kind(over) != "air":
            return None
        for sd in H + ("d",):                                # beside it, or over it
            stand = add(over, OPP[sd])
            if stand in reach:
                return ("till", c, sd, stand)
        return None

    def closes_in(self, stand, c, area):
        """Whether placing c from `stand` would leave the builder no way out: a search through
        known open cells, c taken as solid, for a cell with an open column to the lane - it
        stops at the first, most often a step or two away."""
        site, top = self.crew.site, area[3]
        x0, x1, y0, y1, z0, z1 = area
        others = self.crew.others(self.name)
        seen, q = {stand}, [stand]
        for cur in q:
            if cur != c and (cur[0], cur[2]) != (c[0], c[2]) and self.open_column(cur, top):
                return False
            if cur[0] == c[0] and cur[2] == c[2] and cur[1] > c[1] and self.open_column(cur, top):
                return False
            for k in DIRS:
                n = add(cur, k)
                if n in seen or n == c or n in others:
                    continue
                if not (x0 <= n[0] <= x1 and y0 <= n[1] <= y1 and z0 <= n[2] <= z1):
                    continue
                if site.cost(n) is None or site.kind(n) == "unknown":
                    continue
                seen.add(n)
                q.append(n)
        return True

    def helper_for(self, c, sd, f, stand, h, reach, area):
        """Helpers - cobblestone, taken away after - from h, the face c is to be clicked on, to
        something that can be clicked: a chain of up to CHAIN cells of known air outside the
        plan, the deepest placed first, each next one against it (design/build.py's helper
        chains; the crane's arm and the railings hang in the air, 2026-10-04).
        -> ("helper", c, sd, f, stand, [(cell, side, face, stand), ...]) or None."""
        site = self.crew.site
        others = self.crew.others(self.name)
        banned = {c, stand}

        pend = site.pending_set

        def free(n):
            # Known air outside the plan; or a planned cell still to build, its own block put in
            # once the helper is away (the crane's arm, 2026-10-04: its first log has only a
            # window pane to its west); or water the user let builders into, the ship's hull
            # (its bottom row floats over a cell or two of the river: a helper under it).
            if n in others or n in banned:
                return False
            k = site.kind(n)
            if k == "air":
                return n not in site.plan or n in pend
            return k == "water" and (n in site.wet_ok or n in pend)

        if not free(h):
            return None
        q = deque([[h]])
        while q:
            path = q.popleft()
            last = path[-1]
            for sd2, f2 in options((COBBLE[0], 0, 0, "-")):
                s2, face2 = add(last, OPP[sd2]), add(last, f2)
                if s2 not in reach or s2 in path or s2 in banned or face2 in path \
                        or not site.clickable(face2, f2, sd2):
                    continue
                steps = [(last, sd2, f2, s2)]
                for k in range(len(path) - 2, -1, -1):
                    cell, nxt = path[k], path[k + 1]
                    fd = next(d for d in DIRS if add(cell, d) == nxt)
                    st = next((add(cell, OPP[sd3]) for sd3 in DIRS if sd3 != OPP[fd]
                               and add(cell, OPP[sd3]) in reach
                               and add(cell, OPP[sd3]) not in path
                               and add(cell, OPP[sd3]) not in banned), None)
                    if st is None:
                        break
                    sd3 = next(d for d in DIRS if add(cell, OPP[d]) == st)
                    steps.append((cell, sd3, fd, st))
                else:
                    if not self.closes_in(steps[0][3], steps[0][0], area):
                        return ("helper", c, sd, f, stand, steps)
            if len(path) < CHAIN:
                for d in DIRS:
                    n = add(last, d)
                    if n not in path and free(n):
                        q.append(path + [n])
        return None

    # ---- doing --------------------------------------------------------------------------------

    async def inv(self):
        out = {}
        for part in filter(None, (await self.r.run("inventory")).split(";")):
            slot, rest = part.split(":", 1)
            name, dmg, n = rest.rsplit(":", 2)
            out[int(slot)] = (name, int(dmg), int(n))
        self.held, self.dirty = out, False
        return out

    async def slot_of(self, item):
        if self.dirty:
            await self.inv()
        for s, (a, b, n) in self.held.items():
            if (a, b) == item and n > 0:
                return s
        return None

    def used(self, slot):
        a, b, n = self.held[slot]
        if n > 1:
            self.held[slot] = (a, b, n - 1)
        else:
            del self.held[slot]

    async def place(self, c, sd, f, stand):
        """c from `stand`: what is in it broken first (it is the plan's cell; the robot stands
        outside it), placed, read back - one batch."""
        site = self.crew.site
        block = site.plan[c]
        slot = None
        for it in items_for(block):                    # the plan's item, else its substitute
            slot = await self.slot_of(it)
            if slot is not None:
                break
        if slot is None:
            return False
        await self.go(stand)
        cmds = []
        if site.kind(c) in ("solid", "guess", "unknown"):
            cmds.append(f"swing {sd}")
        cmds += [f"place {sd} {f} {slot}", f"analyze {sd}"]
        replies = await self.r.batch(cmds)
        if cmds[0].startswith("swing"):
            st, why = replies.pop(0)
            self.dirty = True
            if st != "ok":
                if "liquid" in why:
                    site.learn(c, "water")                      # the block goes into it
                    replies = await self.r.batch(cmds[1:])
                else:
                    self.say(f"could not clear {c}: {why}")
                    if "robot" in why:
                        raise Stuck(f"a robot in the cell it is to build, {c}")
                    return False
            else:
                site.learn(c, "air")
        (pst, pv), (ast, av) = replies[0], replies[1]
        if pst != "ok":
            # said, with the robot's answer: run 9 (2026-10-04) failed a dozen places at the
            # lighthouse's floor in a row, and nothing said why
            seen = await self.r.batch([f"analyze {sd}", "inventory"])
            inv = dict(p.split(":", 1) for p in seen[1][1].split(";") if ":" in p)
            self.say(f"place {block[0]} at {c} from {stand} on face {f} refused: {pv}; the cell "
                     f"holds {seen[0][1]!r}, slot {slot} holds {inv.get(str(slot))!r}")
            self.dirty = True
            await self.look(c, add(c, f))
            await self.check_built(add(c, f))
            return False
        self.used(slot)
        got = av.split()
        if not got or got[0] in ("air", "minecraft:air"):
            # The place answered ok and the cell is empty: the click met another block than
            # the one meant and the block went in elsewhere (2026-10-04, an upside-down stair
            # over the lighthouse's door). Not counted as built; where it went is written down
            # for a look (data/strays.txt).
            self.say(f"placed {block[0]} at {c} but the cell reads empty: it went elsewhere")
            with open(STRAYS, "a", newline="\n") as fh:
                fh.write(f"{c[0]} {c[1]} {c[2]} {block[0]} {sd} {f} {stand}\n")
            await self.look(c, add(c, f))
            self.dirty = True
            return False
        site.placed.add(c)
        site.learn(c, "solid", block[0])
        self.crew.note("placed", c)
        self.placed += 1
        if not reads_right(block, got[0], int(got[1]) if len(got) > 1 else -1):
            self.say(f"placed {got} at {c}, the plan has {block}: the rule to check")
        self.r._event(f"placed {c[0]} {c[1]} {c[2]} {block[0]} {block[1]}")
        return True

    async def hold_hoe(self):
        """The hoe in the tool slot: `equip` swaps the selected slot with it, so the robot's own
        tool comes out into that slot and goes back after the field (tool_back)."""
        if self.equipped == HOE:
            return True
        slot = await self.slot_of(HOE)
        if slot is None:
            return False
        await self.r.batch([f"select {slot}", "equip"])
        self.equipped, self.tool_slot, self.dirty = HOE, slot, True
        return True

    async def tool_back(self):
        """The robot's own tool back in its tool slot, the hoe out into the inventory."""
        if self.equipped == HOE and self.tool_slot:
            await self.r.batch([f"select {self.tool_slot}", "equip"])
            self.equipped, self.tool_slot, self.dirty = None, None, True

    async def till(self, c, sd, stand):
        """Farmland at c: from `stand`, beside the cell over c, the hoe on c's top. robot.use
        answers whether the item was used; the seeds that go on next tell for sure (they take
        only to farmland)."""
        site = self.crew.site
        if not await self.hold_hoe():
            return False
        await self.go(stand)
        (st, v), = await self.r.batch([f"use {sd} d"])
        if st != "ok" or not v.startswith("true"):
            self.say(f"the hoe did nothing at {c}: {st} {v}")
            return False
        site.placed.add(c)
        site.learn(c, "solid", TILLED)
        self.crew.note("placed", c)
        self.placed += 1
        self.r._event(f"placed {c[0]} {c[1]} {c[2]} {TILLED} 0")
        return True

    async def helped(self, c, sd, f, stand, steps):
        """The helpers placed, the deepest first; c placed against the last; the helpers taken
        away again."""
        site = self.crew.site
        put = []
        ok = False
        try:
            for cell, sd2, f2, s2 in steps:
                slot = await self.slot_of(COBBLE)
                if slot is None:
                    return False
                await self.go(s2)
                (pst, pv), = await self.r.batch([f"place {sd2} {f2} {slot}"])
                if pst != "ok":
                    await self.look(cell, add(cell, f2))
                    return False
                self.used(slot)
                site.helpers.add(cell)
                site.learn(cell, "solid", COBBLE[0])
                self.crew.note("scaffold", cell)
                put.append(cell)
            ok = await self.place(c, sd, f, stand)
        finally:
            for cell in reversed(put):
                await self.unhelp(cell)
        return ok

    async def unhelp(self, h):
        """The helper at h away: from a cell beside it the builder can reach."""
        site = self.crew.site
        area = (h[0] - 3, h[0] + 3, h[1] - 3, h[1] + 3, h[2] - 3, h[2] + 3)
        reach = self.reachable(area)
        for d in DIRS:
            s = add(h, OPP[d])
            if s in reach:
                await self.go(s)
                st, why = (await self.r.batch([f"swing {d}"]))[0]
                if st == "ok":
                    site.helpers.discard(h)
                    site.learn(h, "air")
                    self.crew.note("unscaffold", h)
                    self.dirty = True
                    return True
        self.say(f"left a helper at {h}: no way to it")
        return False

    async def look(self, *cells):
        """What a place that failed was up against, read with the geolyzer, into the map."""
        at = self.at()
        cmds = [f"scan {c[0] - at[0]} {c[2] - at[2]} {c[1] - at[1]} 1" for c in cells]
        for c, (st, v) in zip(cells, await self.r.batch(cmds)):
            if st == "ok":
                self.learn_hardness(c, float(v.split(",")[0]))

    async def check_built(self, c):
        """A block the record says is built, that a click on it was refused: read, and if it is
        air or water, it is not there - recorded `missing`, to build again. The old crew broke
        the lighthouse's floor (y -1) on its way after it was placed, and the record kept it
        built: run 9 and 11 (2026-10-04) clicked it a dozen times, refused each time."""
        site = self.crew.site
        if c not in site.placed:
            return
        at = self.at()
        (st, v), = await self.r.batch([f"scan {c[0] - at[0]} {c[2] - at[2]} {c[1] - at[1]} 1"])
        if st != "ok":
            return
        h = float(v.split(",")[0])
        if h == 0 or h > 50:
            site.placed.discard(c)
            site.learn(c, "air" if h == 0 else "water")
            self.crew.note("missing", c)
            self.say(f"{c} is not there though the record has it built: to build again")

    def learn_hardness(self, c, h):
        site = self.crew.site
        if c in site.placed or c in site.helpers or c in self.crew.others(self.name) \
                or c == self.at():
            return                        # a robot reads as a block: its own cell too
        if h == 0:
            site.learn(c, "air")
        elif h > 50:
            site.learn(c, "water")
        elif site.kind(c) in ("guess", "unknown", "air", "water"):
            # Solid, whatever its hardness: the geolyzer's noise put the riverbed's dirt under
            # 0.35 and the builders took it for leaves and would not click it (2026-10-04, the
            # first live trial). A name a scout analyzed is kept (learn).
            site.learn(c, "solid", "?")

    async def look_over(self, box):
        """The sector's columns, scanned from where the builder is when it comes over them: what
        the geolyzer reads takes the place of the map's guesses (one batch). The geolyzer reaches
        32 up and down and 64 at most a scan (the scouts' clamp, survey.py); a column read all
        air is a chunk not loaded, which the geolyzer reads so - not believed (survey.py).
        A column read already this run, over the heights wanted, is not read again: what was
        built or broken since is in the site, each builder writes it there. And it is read from
        where the builder is, when that is near enough (SCAN_NEAR across, the heights within
        the geolyzer's 32): with sectors cut small (2026-10-04) a look-over each sector, with a
        go to scan from, took 16 of the crew's 97 minutes in the simulation."""
        site = self.crew.site
        todo = self.crew.todo(box)
        if not todo:
            return
        lo0 = min(c[1] for c in todo) - 4
        hi0 = max(c[1] for c in todo) + 6
        cols = [(x, z) for x in range(box[0] - MARGIN, box[1] + MARGIN + 1)
                for z in range(box[2] - MARGIN, box[3] + MARGIN + 1)
                if not (self.crew.scanned.get((x, z), (99, -99))[0] <= lo0
                        and self.crew.scanned.get((x, z), (99, -99))[1] >= hi0)]
        if not cols:
            return "cells=0,need=0"
        at = self.at()
        if not (max(abs(x - at[0]) for x, z in cols) <= SCAN_NEAR
                and max(abs(z - at[2]) for x, z in cols) <= SCAN_NEAR
                and at[1] - 32 <= lo0 and hi0 <= at[1] + 32):
            try:
                await self.go(self.over(box, todo))
            except Stuck:
                # no way to the low point found: from over the sector, at its lane, as before
                mid = center(box)
                await self.go((mid[0], self.lane_over(box), mid[2]))
            at = self.at()
        lo = max(lo0, at[1] - 32)
        hi = min(max(self.lane_over(box), hi0), at[1] + 32, lo + 63)
        cmds = [f"scan {x - at[0]} {z - at[2]} {lo - at[1]} {hi - lo + 1}" for x, z in cols]
        seen = {"air": 0, "water": 0, "solid": 0, "failed": 0, "all air": 0}
        missing = 0
        for (x, z), (st, v) in zip(cols, await self.r.batch(cmds)):
            if st != "ok":
                seen["failed"] += 1
                if seen["failed"] == 1:
                    self.say(f"a scan failed: {v}")
                continue
            vals = [float(s_) for s_ in v.split(",")]
            if not any(vals):
                seen["all air"] += 1
                continue
            self.crew.scanned[(x, z)] = (lo, hi)
            for i, h in enumerate(vals):
                c = (x, lo + i, z)
                if c in site.placed and (h == 0 or h > 50) and c not in self.crew.others(self.name):
                    # recorded built, read empty: broken since (the old crew broke the
                    # lighthouse's floor after placing it; run 12 found it a cell a refusal)
                    site.placed.discard(c)
                    self.crew.note("missing", c)
                    missing += 1
                self.learn_hardness(c, h)
                seen["air" if h == 0 else "water" if h > 50 else "solid"] += 1
        self.say(f"looked over the sector (y {lo}..{hi}): {seen}"
                 + (f"; {missing} recorded built read empty: to build again" if missing else ""))
        site.settle()
        # what it had to read: the columns round the blocks to build, MARGIN + 1 out
        need = {(c[0] + dx, c[2] + dz) for c in todo for dx in range(-MARGIN - 1, MARGIN + 2)
                for dz in range(-MARGIN - 1, MARGIN + 2)}
        return f"cells={len(cols) * (hi - lo + 1)},need={len(need) * (hi - lo + 1)}"

    def over(self, box, todo):
        """Where to scan a sector from: just over its highest block to build (+2), in the column
        of the sector whose top lets it lowest and whose cell there is known air (a sim run
        stuck a builder going for one past the map's edge), the nearest the centre first. From
        the lane over the whole sector it was the lighthouse's top, 24 high, for blocks at the
        crane at 2: some 50 moves up and down for each look (the user, 2026-10-04, of Gunter:
        "took a long ass time to go to the top of the lighthouse, I don't even know if it did
        anything"). The geolyzer reaches 32 up and down from there."""
        site, mid = self.crew.site, center(box)
        y = max(c[1] for c in todo) + 2
        best = None
        for x in range(box[0], box[1] + 1):
            for z in range(box[2], box[3] + 1):
                h = max(y, site.column_top(x, z) + 1)
                if site.kind((x, h, z)) != "air":
                    continue                    # unknown: the map's edge, past the zone loaded
                key = (h, abs(x - mid[0]) + abs(z - mid[2]))
                if best is None or key < best[0]:
                    best = (key, (x, h, z))
        return best[1] if best else (mid[0], self.lane_over(box), mid[2])

    # ---- moving -------------------------------------------------------------------------------

    async def go(self, goal, home=False):
        """go_(), logged with the way's length as the crow flies (Manhattan)."""
        goal, start = tuple(goal), self.at()
        if start == goal:
            return
        t0, b0, m0 = CLOCK(), getattr(self.r, "answered", 0), self.moves
        note = "stuck"
        self.depth += 1
        try:
            await self.go_(goal, home)
            note = "ok"
        finally:
            self.depth -= 1
            self.log_action("go", goal, t0, b0, m0, dist(start, goal), note)

    async def go_(self, goal, home=False):
        """To goal, through air (and water where allowed), never breaking anything; round what a
        move finds in the way. Raises Stuck when there is no way."""
        goal = tuple(goal)
        fails, waits = 0, 0
        while self.at() != goal:
            if goal in self.crew.others(self.name):
                # another robot stands there (at a side of the interface, at a park): it moves
                # on; waited for without holding the depot, which it may need to leave
                waits += 1
                if waits > 300:
                    raise Stuck(f"{goal} stayed taken by another robot")
                await self.pause("robot", 2)
                continue
            depot = in_box(self.at(), DEPOT) or in_box(goal, DEPOT)
            if depot:
                async with self.crew.depot:
                    ok = await self.step_toward(goal, home)
            else:
                ok = await self.step_toward(goal, home)
            if ok is None:
                fails += 1
                if fails > 30:
                    raise Stuck(f"no way from {self.at()} to {goal}")
                await self.pause("robot", 2)  # robots in the way move on: the way again
            elif not ok:
                fails += 1
                if fails > 40:
                    raise Stuck(f"cannot get from {self.at()} to {goal}")
        self.left_spot()

    async def step_toward(self, goal, home):
        """One way found and walked: True there, False stopped on the way, None no way now."""
        path = self.route(goal)
        if path is None:
            return None
        return await self.walk(path, home)

    def left_spot(self):
        """The side of the interface it held, given back once it has stepped off it: given back
        before, the next robot came and stood waiting where it still was (the simulation)."""
        if self.holding and self.at() != self.holding[0]:
            self.crew.free_sides.append(self.holding[1])
            self.holding = None

    def route(self, goal):
        """In its sector: a way through the sector's area. Near: a way in the box round both
        ends. Far, or no such way: up to this robot's lane near where it is, along the lane, down
        near the goal. Near meant 12 steps alone, and a near way not found was not tried by the
        lane: a stand across its own sector, 14 steps off, sent a builder up to its lane and down
        again, a 36 s batch, for each block (the user, 2026-10-04: "clumsy moves")."""
        here = self.at()
        a = self.cur_area
        if a and all(a[0] <= p[0] <= a[1] and a[2] - 2 <= p[1] <= a[3] and a[4] <= p[2] <= a[5]
                     for p in (here, goal)):
            path = self.way(here, {goal}, (a[0], a[1], a[2] - 2, a[3], a[4], a[5]))
            if path is not None:
                return path
        depot = in_box(here, DEPOT) and in_box(goal, DEPOT)
        if depot or max(abs(p - q) for p, q in zip(here, goal)) <= 12:
            box = (min(here[0], goal[0]) - NEAR, max(here[0], goal[0]) + NEAR,
                   min(here[1], goal[1]) - 2, max(here[1], goal[1]) + 6,
                   min(here[2], goal[2]) - NEAR, max(here[2], goal[2]) + NEAR)
            path = self.way(here, {goal}, box)
            if path is not None or depot:
                return path
        site = self.crew.site
        xs, zs = sorted((here[0], goal[0])), sorted((here[2], goal[2]))
        top = max(site.column_top(x, z) for x in range(xs[0] - 1, xs[1] + 2)
                  for z in range(zs[0] - 1, zs[1] + 2))
        lane = max(top, here[1], goal[1]) + 2 + self.idx
        up_box = (here[0] - NEAR, here[0] + NEAR, here[1] - 1, lane, here[2] - NEAR,
                  here[2] + NEAR)
        a = self.cur_area
        if a and a[0] <= here[0] <= a[1] and a[4] <= here[2] <= a[5]:
            # out of the sector the way it came in: the sector's whole area
            up_box = (min(up_box[0], a[0]), max(up_box[1], a[1]), min(up_box[2], a[2]) - 2, lane,
                      min(up_box[4], a[4]), max(up_box[5], a[5]))
        up = self.way(here, None, up_box, lane=lane)
        if up is None:
            # no way straight up: wider, and down first - out of the lighthouse's shaft by its
            # door, its top built over (the gate's simulation, 2026-10-04: a builder 13 up in
            # it found no way home and stood STUCK)
            up = self.way(here, None, (here[0] - OUT, here[0] + OUT, here[1] - 2 * OUT, lane,
                                       here[2] - OUT, here[2] + OUT), lane=lane)
        if up is None:
            return None
        path, c = list(up), here
        for d in up:
            c = add(c, d)
        mid = [("e" if goal[0] > c[0] else "w")] * abs(goal[0] - c[0]) + \
            [("s" if goal[2] > c[2] else "n")] * abs(goal[2] - c[2])
        for d in mid:
            c = add(c, d)
        path += mid
        down = self.way(c, {goal}, (goal[0] - NEAR, goal[0] + NEAR, goal[1] - 1, lane,
                                    goal[2] - NEAR, goal[2] + NEAR))
        if down is None:
            return None
        return path + down

    def way(self, start, goals, box, lane=None):
        """The cheapest way in box from start to one of goals (or, with `lane`, to any cell at
        that height whose column is clear to it), as directions."""
        site = self.crew.site
        x0, x1, y0, y1, z0, z1 = box
        others = self.crew.others(self.name)
        prev, cost = {start: None}, {start: 0}
        q = [(0, start)]
        while q:
            d, c = heapq.heappop(q)
            if d > cost[c]:
                continue
            if (goals and c in goals) or (lane is not None and c[1] == lane):
                out = []
                while prev[c]:
                    c, k = prev[c]
                    out.append(k)
                return out[::-1]
            for k in DIRS:
                n = add(c, k)
                if not (x0 <= n[0] <= x1 and y0 <= n[1] <= y1 and z0 <= n[2] <= z1):
                    continue
                if n in others:
                    continue
                w = site.cost(n)
                if w is None:
                    continue
                if d + w < cost.get(n, 1e9):
                    cost[n], prev[n] = d + w, (c, k)
                    heapq.heappush(q, (d + w, n))
        return None

    async def walk(self, path, home):
        """Along a path, its moves in one batch. A move that will not go: water or a block the
        map did not have is learned and False sends go() to find the way again; a robot in the
        way is waited for."""
        site = self.crew.site
        cmds, c = [], self.at()
        for d in path:
            c = add(c, d)
            wet = site.kind(c) in ("water", "unknown") and site.wet_allowed(c)
            cmds.append(f"move {d}" + (" home" if home else "") + (" wet" if wet else ""))
        replies = await self.r.batch(cmds)
        self.crew.pos[self.name] = self.at()
        self.moves += sum(1 for st, _ in replies if st == "ok")
        for d, (st, v) in zip(path, replies):
            if st == "ok":
                if self.trail and self.trail[-1] == OPP[d]:
                    self.trail.pop()
                else:
                    self.trail.append(d)
                continue
            n = add(self.at(), d)
            if "liquid" in v:
                site.learn(n, "water")
                return False
            if "low energy" in v:
                raise Stuck(f"too little energy to go on ({v})")
            if "blocked" in v:
                what = (await self.r.run(f"analyze {d}")).split()
                if not what or what[0] == ROBOT:
                    await self.pause("robot", 2)  # a robot: it moves on, the way again
                    return False
                if what[0] in ("air", "minecraft:air"):
                    # Empty, and the move would not go: a fence or a wall below, whose box
                    # stands half a block into this cell (ASIMO went round and round by the
                    # barn, 2026-10-04) - or a robot just gone. Twice, or over a fence: closed.
                    below = site.name(add(n, "d")) or ""
                    self.air_blocks[n] = self.air_blocks.get(n, 0) + 1
                    if self.air_blocks[n] >= 2 or any(k in below.lower()
                                                      for k in ("fence", "wall", "gate")):
                        site.learn(n, "solid", "?over a fence")
                    else:
                        await self.pause("robot", 2)
                    return False
                if what[0] == "minecraft:water":
                    site.learn(n, "water")
                else:
                    site.learn(n, "solid", what[0])
                return False
            raise Stuck(f"move {d}: {v}")
        if self.at() == (0, 0, 0):
            self.trail = []
        return True

    # ---- energy and blocks --------------------------------------------------------------------

    def low(self):
        """Whether to charge before going on: under LOW of a full charge, or near the robot's own
        floor with the way to a sector and back to spare."""
        e = getattr(self.r, "energy", None) or 0
        return e < LOW * self.max or e < len(self.trail) * 12 + FLOOR + RESERVE

    async def charge_if_low(self):
        if self.low():
            await self.timed("charge", self.home, self.charge())

    async def charge(self):
        e = self.r.energy
        self.say(f"charging ({e})")
        await self.go(self.home, home=True)
        await self.r.run("charge 0.95 120")
        self.r.energy, self.trail = self.max, []
        return f"from={e}"

    async def release_sides(self):
        while self.crew.free_sides:
            name = self.crew.free_sides.pop()
            async with self.crew.me_lock:
                await self.crew.me.batch([f"release {name} {self.crew.side_holder[name]}"])

    async def side(self):
        """A side of the interface, from the mini ME's computer, which hands them out."""
        while True:
            await self.release_sides()
            for spot in (WEST, EAST):
                name = "west" if spot[1] == "e" else "east"
                async with self.crew.me_lock:
                    st, _ = (await self.crew.me.batch([f"claim {name} {self.name}"]))[0]
                if st == "ok":
                    self.crew.side_holder[name] = self.name
                    return spot, name
            await self.pause("side", 5)

    async def load(self, want, later=None):
        """What the sector needs, as much as the slots hold, from the interface; what it holds
        and the sector does not use goes back when it goes there anyway, or when fewer than
        FREE slots are left. Given back each time, every new sector cost a trip to the
        interface, also when all its blocks were already in the robot (2026-10-04, the sectors
        cut small). When it does go: what the work left elsewhere needs (`later`, item
        -> count) is kept, or taken along, while slots allow - but only of what the mini ME holds
        enough of for all that work, so no builder takes what another's sector needs. Loading
        for its own sector alone, each builder went to the interface for each sector, for one
        or two items, and stood in the queue for a side: the simulation, 2026-10-04, 18 minutes
        loading and 20 waiting for a side of the crew's 97, against 5 placing. -> a note for the
        log: items taken and stacks given back."""
        import me as mini
        held = await self.inv()
        have = {}
        for a, b, n in held.values():
            have[(a, b)] = have.get((a, b), 0) + n
        room = self.size - sum(1 for v in held.values() if v[:2] == SAW)
        cut, used = {}, 0
        for it, n in sorted(want.items(), key=lambda kv: -kv[1]):
            k = (max(n, have.get(it, 0)) + 63) // 64
            if used + k > room:
                n = max(0, (room - used) * 64)
                k = room - used
            if n > 0:
                cut[it] = n
                used += k
        give = [s for s, (a, b, n) in held.items() if (a, b) != SAW and (a, b) not in cut
                and a != ROBOT]
        # what the mini ME has none of is not gone for (it waits for the user): asked for each
        # time, a sector with a ladder in it sent its builder to the interface for nothing
        need = {}
        for it, n in cut.items():
            if it in self.crew.lacking and SUBSTITUTE.get(it) not in self.crew.lacking | {None}:
                it = SUBSTITUTE[it]                    # none of it: what stands in for it
            if n > have.get(it, 0) and it not in self.crew.lacking:
                need[it] = n - have.get(it, 0)
        if not need and (not give or len(held) < self.size):
            self.loaded = None
            return "nothing"
        # To its park first, then a side claimed: claimed where it stood, a builder held a side
        # all its way back from the sector, and the others queued for it (the simulation,
        # 2026-10-04: 20 of the crew's 97 minutes waiting for a side)
        why = sorted(need)                                     # what it went for (the log)
        await self.go(self.home, home=True)
        spot, name = await self.side()
        self.holding = (spot[0], name)
        try:
            async with self.crew.me_lock:
                avail = await mini.me_items(self.crew.me) if need else {}
            # what the mini ME has none of: those blocks wait for the user
            self.crew.lacking |= {it for it in need if not avail.get(it)}
            self.crew.lacking -= {it for it in avail if avail[it] > 0}
            for it in list(need):                      # short: its substitute (SUBSTITUTE)
                sub = SUBSTITUTE.get(it)
                if sub and avail.get(it, 0) < need[it] and avail.get(sub, 0) > 0:
                    need[sub] = need.get(sub, 0) + need[it] - avail.get(it, 0)
            need = {it: min(n, avail.get(it, 0)) for it, n in need.items() if avail.get(it)}
            used = sum((max(n, have.get(it, 0)) + 63) // 64 for it, n in cut.items())
            rank = {it: k for k, it in enumerate(later or {})}         # nearest work first
            for sl in sorted(give, key=lambda sl: rank.get(held[sl][:2], 1e9)):
                if (later or {}).get(held[sl][:2]) and used < room:
                    give.remove(sl)                   # kept: work elsewhere uses it
                    used += 1
            kept = {held[sl][:2] for sl in held if sl not in give}
            for it in list(need):                     # its own stacks topped up for later work
                mine = cut.get(it, need[it])          # a substitute is not in cut
                total = mine + (later or {}).get(it, 0)
                if (later or {}).get(it) and avail.get(it, 0) >= total:
                    k = (max(mine, have.get(it, 0)) + 63) // 64
                    need[it] = max(need[it], min(k * 64, total) - have.get(it, 0))
            if avail:
                for it, n in (later or {}).items():          # in the order of the nearest work
                    if used >= room - FREE:
                        break
                    if it in kept or it in need or it in self.crew.lacking:
                        continue
                    if avail.get(it, 0) >= n:         # enough for all of it: none taken short
                        need[it] = min(n, 64)
                        used += 1
            # Room for what it goes for: the sector's own first. Kit kept or taken for later
            # work gives way when the slots would not hold it - full of kit, a builder pulled
            # nothing, built nothing, and leased the sector again, for ever (the village's
            # simulation, 2026-10-04: 5670 loads, the batch cap reached)
            free = [s for s in range(1, self.size + 1)
                    if (s not in held or s in give) and s != self.tool_slot]
            stacks = sum((n + 63) // 64 for n in need.values())
            for sl in sorted((sl for sl in held if sl not in give and held[sl][:2] not in cut
                              and held[sl][:2] != SAW and held[sl][0] != ROBOT),
                             key=lambda sl: -rank.get(held[sl][:2], 1e9)):
                if len(free) >= stacks:
                    break
                give.append(sl)
                free.append(sl)
            for it in [it for it in need if it not in cut][::-1]:
                if len(free) >= stacks:
                    break
                stacks -= (need.pop(it) + 63) // 64           # the kit dropped, the latest first
            await self.go(spot[0])
            if give:
                await mini.give_back(self.r, spot[1], spot[3], give)
            free = sorted(free)
            # Not under the lock: each side has its own slots and the link keeps a batch whole;
            # held, the two sides loaded one after the other and three builders stood waiting
            # for a side (2026-10-04, the harbour, run 3)
            got, short = await mini.pull(self.r, self.crew.me, spot, need, free)
            if short:
                self.say(f"the mini ME is short of {short}")
            taken = sum(got.values()) if isinstance(got, dict) else got
            self.loaded = taken
        except BaseException:
            self.holding = None
            async with self.crew.me_lock:
                await self.crew.me.batch([f"release {name} {self.name}"])
            raise
        self.dirty = True
        return f"items={taken},back={len(give)},for=" + "+".join(
            f"{it[0].split(':')[-1]}/{it[1]}" for it in why)


STACKS, WATCH = os.path.join(buildsite.DATA, "crew-stacks.txt"), 30
STRAYS = os.path.join(buildsite.DATA, "strays.txt")
PENDING = buildsite.DATA                  # where pending-<plan>.txt goes (sim.py: None)


def write_pending(crew):
    """What is left of the plan, for the viewer's J overlay (the user, 2026-10-04): every plan
    cell not built, `p x y z status name` - build (open), lacking (an item the mini ME has none
    of), stuck (given up: out of reach, no face) - under `# plan <file> <time> <n> left`. One
    file a plan, data/pending-<plan>.txt, written whole to a temporary file and renamed, so
    the viewer never reads half of one. Not from the simulation (PENDING is None there)."""
    if not PENDING:
        return
    site = crew.site
    live = set(crew.live())
    leased = {c for b in crew.leased for c in crew.todo(b)}
    rows = []
    for c in sorted(site.pending()):
        if all(it in crew.lacking for it in items_for(site.plan[c])):
            st = "lacking"
        elif c in live or c in leased:
            st = "build"
        else:
            st = "stuck"
        rows.append(f"p {c[0]} {c[1]} {c[2]} {st} {site.plan[c][0]}\n")
    name = os.path.splitext(os.path.basename(site.plan_path))[0]
    path = os.path.join(PENDING, f"pending-{name}.txt")
    with open(path + ".tmp", "w", newline="\n") as f:
        f.write(f"# plan {os.path.basename(site.plan_path)} {time.strftime('%H:%M:%S')} "
                f"{len(rows)} left\n")
        f.writelines(rows)
    os.replace(path + ".tmp", path)


async def watchdog(tasks, builders, me):
    """Every WATCH s, each builder's link and what its coroutine awaits, into STACKS: what to read
    when one stands still (2026-10-04: Pintsize stood at the interface for minutes, silent); and
    what is left of the plan (write_pending)."""
    while True:
        await asyncio.sleep(WATCH)
        if builders:
            write_pending(builders[0].crew)
        with open(STACKS, "w", encoding="utf-8") as f:
            f.write(time.strftime("%H:%M:%S") + "\n")
            for name, r in [(b.name, b.r) for b in builders] + [("mini ME", me)]:
                pend = getattr(r, "pending", None)
                f.write(f"{name}: {getattr(r, 'answered', 0)} batches answered; "
                        + (f"waiting {time.time() - pend[1]:.0f} s on {pend[0][:3]}"
                           if pend else "nothing asked") + "\n")
            for b, t in zip(builders, tasks):
                f.write(f"--- {b.name}{' (done)' if t.done() else ''} at {b.at()}\n")
                c = t.get_coro()
                while c is not None:
                    fr = getattr(c, "cr_frame", None) or getattr(c, "gi_frame", None)
                    if fr is None:
                        f.write(f"    awaiting {c!r}\n")
                        break
                    f.write(f"    {os.path.basename(fr.f_code.co_filename)}:{fr.f_lineno} "
                            f"{fr.f_code.co_name}\n")
                    c = getattr(c, "cr_await", None) or getattr(c, "gi_yieldfrom", None)


async def run(site, crew_def, reach, me_connect, crafting=True, limit=None,
              record=buildsite.DONE, watch=True, dig=False):
    me = await me_connect("meserver-crew")
    crew = Crew(site, me, record)
    crew.dig = dig
    await me.batch([f"clear {k}" for k in WEST[2] + EAST[2]])
    if record:
        # the stock as the crew starts, for the simulation (sim.py's mini ME): read once, a
        # file read at another time was stale - the user added 56 acacia logs after it
        # (2026-10-04)
        import me as mini
        mini.save_stock(await mini.me_items(me))
    builders = []
    for idx, (prefix, name, park, crafts) in enumerate(crew_def):
        b = Builder(crew, prefix, name, park, crafts and crafting, idx, reach)
        builders.append(await b.connect())
    print(f"crew: {', '.join(b.name for b in builders)}; {len(site.pending())} blocks to build "
          f"in {len(crew.boxes)} sectors ({len(site.skipped)} kept as ground)", flush=True)
    tasks = [asyncio.ensure_future(b.run(limit)) for b in builders]
    dog = asyncio.ensure_future(watchdog(tasks, builders, me)) if watch else None
    results = await asyncio.gather(*tasks, return_exceptions=True)
    if dog:
        dog.cancel()
    for b, res in zip(builders, results):
        if isinstance(res, BaseException):
            print(f"  {b.name} ended on {res!r}", flush=True)
    left = site.pending()
    write_pending(crew)
    print(f"crew: {sum(b.placed for b in builders)} placed; {len(left)} left; stuck: "
          f"{crew.stuck or 'none'}", flush=True)
    if crew.lacking:
        wait = sum(1 for c in left if all(it in crew.lacking
                                          for it in items_for(site.plan[c])))
        print(f"crew: {wait} of those wait for what the mini ME has none of: "
              + ", ".join(f"{a}:{b}" for a, b in sorted(crew.lacking)), flush=True)
    crew.builders = builders
    return crew


async def main(a):
    import rlink, me as mini
    plan = os.path.abspath(a[a.index("--plan") + 1]) if "--plan" in a else \
        os.path.join(HERE, "data", "harbour.txt")
    only = a[a.index("--robots") + 1].split(",") if "--robots" in a else None
    limit = int(a[a.index("--steps") + 1]) if "--steps" in a else None
    crew_def = [d for d in CREW if only is None or any(d[0].startswith(o) for o in only)]
    # the plan's own map: the village's field is in data/map-village.txt (chunks 14..16 x
    # 9..11), not in the harbour's zone map (the coordinator, 2026-10-04)
    mp = os.path.abspath(a[a.index("--map") + 1]) if "--map" in a else None
    site = buildsite.Site(plan, mp)
    if "--home" in a:
        await home(site, crew_def, rlink.reach, mini.me_connect)
        return
    # The gate (tests/gate.py) passed on this very code, or no live run: the user's rule that
    # robot logic is tried in the simulation first, kept by the program, not by hand (the
    # audit, 2026-10-04). --home stays open: it is how a crew is stopped safely.
    sys.path.insert(0, os.path.join(HERE, "tests"))
    import gate
    if not gate.stamp_ok():
        raise SystemExit("builders.py: the gate has not passed on this code; run "
                         "python 3d-draw/tests/gate.py first")
    await run(site, crew_def, rlink.reach, mini.me_connect, crafting="--no-craft" not in a,
              limit=limit, dig="--dig" in a)


async def home(site, crew_def, reach, me_connect):
    """Every builder to its park and charged, breaking nothing on the way: when a crew is
    stopped (2026-10-04: the harbour's last blocks out of reach, the builders went round them
    leasing and giving up)."""
    me = await me_connect("meserver-crew")
    crew = Crew(site, me, None)
    builders = []
    for idx, (prefix, name, park, crafts) in enumerate(crew_def):
        builders.append(await Builder(crew, prefix, name, park, False, idx, reach).connect())

    async def one(b):
        try:
            await b.go(b.home, home=True)
            await b.r.run("charge 0.95 120")
            b.say(f"home at {b.at()}, charged")
        except (Stuck, Exception) as e:
            b.say(f"not home: {e!r}")

    await asyncio.gather(*(one(b) for b in builders))


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:]))
