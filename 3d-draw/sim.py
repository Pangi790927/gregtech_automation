"""sim.py - an offline world for the builders: robots, the mini ME and the ground, answering the
commands robot/server.lua and robot/me_server.lua answer, so the crew's logic is tried here before
it drives the user's robots (the user, 2026-10-04, after builders broke three of their own and dug
into the riverbed: "what did you do to get so many bugs?" - nothing had been tried before the
game).

The world is the map with what it got wrong put back in: a guessed cell may be water or plain dirt
whatever the survey's hardness said, an unknown one is ground below the column's known surface and
air above it. What matters most is kept true to the game:
  - a robot is a block: a swing at it breaks it (here: counted as a robot broken, and that robot
    dies; robot/server.lua refuses such a swing, and the count says whether the crew asked);
  - water flows into a cell that is opened next to it, and on into air beside and below;
  - a move never breaks anything, and never goes into a liquid unless told `wet`;
  - a place needs a face to click and an empty or watery target.

    python 3d-draw/sim.py [--plan data/harbour.txt] [--seed 1] [--robots 4] [--steps N]
                          [--done a copy of data/build-done.txt] [--actions a log to write]
                          [--facing-each]   (server.lua as in run 14: facing read every
                                             step, for the before of a comparison)
                          [--river N]       (the river's level forced: builders.RIVER)
"""
import asyncio, os, random, sys, time
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from placing import DIRS, OPP, add, meets, full, COBBLE, expected_meta   # noqa: E402
from placing import HOE, SEEDS, TILLED, CROP                             # noqa: E402
from placing import H, STAIR_META, item_of, options, substitutes         # noqa: E402


def placed_meta(plan_block, st, d, face, facing):
    """The metadata a block takes, placed with item `st` facing `d`, clicking `face`, the robot
    turned `facing`: the plan's own when the click is one of its options (placing.options);
    else by vanilla 1.7.10's rules - a stair rises the way the placer looks and is upside down
    clicked on a block's underside or high on its side; a slab likewise goes to the top half;
    a ladder hangs on the wall clicked; leaves placed by hand do not decay. So a wrong click
    gives a wrong block in the simulation as in the game (the audit, 2026-10-04: the sim
    placed every block as the plan had it)."""
    name, meta = st[0], st[1]
    if plan_block and plan_block[0] == name:
        for b in substitutes(plan_block):
            if item_of(b[0], b[1]) == (name, meta) and (d, face) in options(b):
                return expected_meta(b)
    upper = face == "u" or (face in H and d == "d")
    if name.endswith("_stairs"):
        yaw = d if d in H else facing
        return STAIR_META[{"e": "xpos", "w": "xneg", "s": "zpos", "n": "zneg"}[yaw]] | \
            (4 if upper else 0)
    if name.endswith("_slab"):
        return meta | (8 if upper else 0)
    if name in ("minecraft:leaves", "minecraft:leaves2"):
        return meta | 4
    if name == "minecraft:ladder":
        return {"s": 2, "n": 3, "e": 4, "w": 5}.get(face, 0)
    return meta
import buildsite                                                          # noqa: E402

FACINGS = ("n", "e", "s", "w")
CHARGERS = {(1, 0, 0), (1, 0, -2), (1, -1, -1)}
INTERFACE = (1, 0, 1)
ROBOT = "OpenComputers:robot"


class RobotError(Exception):
    """A command the simulated robot or mini ME refuses, as rlink.RobotError for the real ones."""


# Server ticks a command takes the robot, for the simulated clock (docs/speed.md, "A step"):
# charged by the 0.4 s of the pack's config alone, a move cost 0.4 s here and 0.95 live (run 14).
# OpenComputers 1.9.14 runs a call that is not direct at the next server tick; a pause of 0.4 s
# is 8 ticks with its call (bench.py on Pintsize, 2026-10-04: a move 8, a turn 8; getFacing,
# detect, scan a tick each; save() 0.3). TICKS: what each command calls besides its getFacing
# reads and its turns: a move is detect and move (a `dry` one no detect), a place select, select,
# getStackInInternalSlot and place, a suckslot or dropslot its call and 0.5 s; a swing's breaking
# taken as 8 (harvestRatio 1, the block's own time); `inventory` adds a tick a stack, `wait` its
# seconds. READS: getFacing calls before the turns, as server.lua made them till 2026-10-04:
# face() read once and again after every turn, where() once more.
TICKS = {"move": 9, "face": 0, "swing": 11, "place": 11, "use": 8, "analyze": 1, "detect": 1,
         "scan": 1, "select": 1, "stack": 1, "inventory": 1, "suckslot": 10, "dropslot": 10,
         "equip": 1, "hello": 2, "pos": 0, "setpos": 0, "energy": 0, "chunk": 2, "wait": 0,
         "charge": 0}
READS = {"move": 2, "face": 2, "swing": 1, "place": 1, "use": 1, "analyze": 1, "detect": 1,
         "suckslot": 1, "dropslot": 1, "hello": 1, "pos": 1, "setpos": 1}
TURN = 8                          # robot.turn: 0.4 s
# FACING_ONCE: robot/server.lua reads its facing once a batch and keeps it through its turns
# (the coordinator, 2026-10-04: "read facing once per batch") - then no READS, a tick a batch
FACING_ONCE = True
# TPS: the server's ticks a second - the user's /forge tps, 2026-10-04 23:32: "Overall 13.067
# TPS, mean tick 76.5 ms" (bench.py read 11.5 at 23:37). BATCH: a batch's way through the relay
# and back, 0.16-0.19 s (bench.py's pings).
TPS, BATCH, CHARGE_RATE = 13.0, 0.18, 2000.0
TICK = 1 / TPS
LOST = 0.01                       # share of the cells recorded built that are gone in the world


class Clocked(asyncio.SelectorEventLoop):
    """An event loop on simulated time: when nothing is ready to run, the clock jumps to the
    next timer. A robot's batch sleeps what its commands take; a builder's nap is 5 s of it, so
    waiting and working are counted in the same seconds (the user, 2026-10-04: "the team's idle
    ammount should be reasoned about")."""

    def __init__(self):
        """A selector loop whose clock starts at 0 simulated seconds."""
        super().__init__()
        self.now = 0.0

    def time(self):
        """The simulated clock: what asyncio's timers and builders.CLOCK read."""
        return self.now

    def _run_once(self):
        """With nothing ready, the clock moved on to the next timer, then asyncio's own step."""
        if not self._ready and self._scheduled:
            self.now = max(self.now, self._scheduled[0]._when)
        super()._run_once()


class World:
    """The true world: cell -> ("air",) | ("water",) | ("solid", name, meta) | ("robot", name)."""

    def __init__(self, site, seed=1, wrong=0.25):
        """The world from the site's map, a `wrong` share of the survey's guesses made wrong
        (water by the river, dirt elsewhere), what the record says is built, and the station."""
        rnd = random.Random(seed)
        self.cells, self.plan = {}, site.plan
        self.broken_robots, self.robot_swings, self.ground_dug = [], [], []
        self.dry_into_water = []          # (robot, cell): a `dry` move that met water
        self.batches, self.cap = 0, 40000
        self.tilled = 0
        self.unload, self.rnd = 0.0, rnd                # share of scans that read a chunk unloaded
        self.strays = []                                # blocks that went in elsewhere
        self.dig_ok = site.dig_ok                    # where the user let builders dig and refill
        self.clear = site.clear                      # the plan's empty cells: dug, not "outside"
        water = {c for c, s in site.state.items() if s[0] == "water"}
        near_water = {add(c, d) for c in water for d in DIRS} | water
        for c, s in site.state.items():
            if s[0] == "air":
                self.cells[c] = ("air",)
            elif s[0] == "water":
                self.cells[c] = ("water",)
            elif c in site.guess and rnd.random() < wrong:
                # the survey's guess wrong: water by the river, dirt elsewhere
                self.cells[c] = ("water",) if c in near_water else ("solid", "minecraft:dirt", 0)
            else:
                self.cells[c] = ("solid", s[1], 0)
        self.lost = set()
        for c in site.placed:
            b = site.plan[c]
            if rnd.random() < LOST:
                # recorded built, gone since (the old crew broke the lighthouse's floor after
                # placing it, 2026-10-04): the builders must find it, not click it
                self.cells[c] = ("air",)
                self.lost.add(c)
                continue
            self.cells[c] = ("solid", b[0], expected_meta(b))
        for c in site.helpers:
            self.cells[c] = ("solid", COBBLE[0], 0)
        self.top = {}
        for c, s in self.cells.items():
            if s[0] != "air" and c[1] > self.top.get((c[0], c[2]), -99):
                self.top[(c[0], c[2])] = c[1]
        # the station, as the user built it (data/fixed.txt has it; here what a robot meets)
        for c in CHARGERS:
            self.cells[c] = ("solid", "OpenComputers:charger", 0)
        self.cells[INTERFACE] = ("solid", "appliedenergistics2:tile.BlockInterface", 0)
        for y in range(0, 4):
            self.cells[(1, y, -1)] = ("solid", "gregtech:station", 0)
        for dx in (-1, 0, 1):
            for dz in (-1, 0, 1):
                if dx or dz:
                    self.cells[(1 + dx, 3, -1 + dz)] = ("solid", "minecraft:glass", 0)
        self.cells[(1, 0, -3)] = ("solid", "minecraft:lever", 0)

    def at(self, c):
        """What is truly at c."""
        s = self.cells.get(c)
        if s is not None:
            return s
        # unknown to the map: ground under the column's known top, air over it
        return ("solid", "minecraft:dirt", 0) if c[1] <= self.top.get((c[0], c[2]), -3) \
            else ("air",)

    def open_up(self, c):
        """c is air now: water beside or above flows in, and on into air beside and below."""
        if not any(self.at(add(c, d))[0] == "water" for d in ("n", "s", "e", "w", "u")):
            self.cells[c] = ("air",)
            return
        q, n = deque([c]), 0
        while q and n < 12:
            x = q.popleft()
            if self.at(x)[0] not in ("air",) and x != c:
                continue
            self.cells[x] = ("water",)
            n += 1
            for d in ("n", "s", "e", "w", "d"):
                y = add(x, d)
                if self.at(y)[0] == "air":
                    q.append(y)


class Robot:
    """A robot as rlink.AsyncRobot shows it to the crew: batch, run, pos, energy, name."""

    def __init__(self, world, name, prefix, pos, home, size=16, energy=40500):
        """A robot standing at pos (a block in the world: swung at, it breaks), charged full."""
        self.world, self.name, self.prefix = world, name, prefix
        self.pos, self.facing, self.home = list(pos), "n", tuple(home)
        self.energy, self.max = energy, energy
        self.size, self.inv, self.sel = size, {}, 1
        self.tool = ("minecraft:iron_pickaxe", 0)          # what it holds in its tool slot
        self.trail, self.dead, self.under = [], False, ("air",)
        self.drop_once = False                              # --drop: the next batch's link lost
        self.answered, self.pending, self.moves = 0, 0, 0
        self.log = []
        world.cells[tuple(pos)] = ("robot", name)

    # rlink's view
    def status(self, state, short, long):
        """The viewer's status line: nobody watches the simulation's."""

    def _event(self, line):
        """A line for live.log: the simulation keeps none."""

    async def close(self):
        """Nothing to close."""

    async def run(self, cmd):
        """One command: its value, or RobotError, as rlink's run."""
        (st, v), = await self.batch([cmd])
        if st != "ok":
            raise RobotError(f"{self.name}: {cmd}: {v}")
        return v

    async def batch(self, cmds):
        """Commands run in order till one fails (the rest skipped), as robot/server.lua; the
        clock moved on by the ticks they take (ticks). A broken robot answers nothing."""
        self.world.batches += 1
        if self.world.batches % 2000 == 0:
            print(f"  sim: {self.world.batches} batches", flush=True)
        if self.world.batches > self.world.cap:
            raise RobotError("the simulation's cap on batches: something goes round in circles")
        if self.dead:
            raise RobotError(f"{self.name}: the relay closed the connection (broken)")
        if self.drop_once:
            # the relay dropping a link mid-batch, the robot unharmed (the field's trial)
            self.drop_once = False
            raise RobotError(f"{self.name}: the relay closed the connection (dropped)")
        self.answered += 1
        out, failed, took = [], False, BATCH + (TICK if FACING_ONCE else 0)
        for cmd in cmds:
            if failed:
                out.append(("skip", ""))
                continue
            w = cmd.split()
            took += self.ticks(w) * TICK
            try:
                e0 = self.energy
                v = getattr(self, "c_" + w[0])(*w[1:])
                if w[0] == "charge":
                    took += (self.energy - e0) / CHARGE_RATE
                out.append(("ok", v))
            except RobotError as e:
                out.append(("err", str(e)))
                failed = True
        await asyncio.sleep(took)
        return out

    def ticks(self, w):
        """The server ticks command w (its words) takes, from the facing it finds the robot in:
        TICKS, a turn TURN each (two to turn about), and server.lua's getFacing reads."""
        k = TICKS.get(w[0], 1)
        if w[0] == "move" and "dry" in w[2:]:
            k -= 1                            # no detect before it
        if w[0] == "wait":
            k += int(float(w[1] if len(w) > 1 else 1) * 20)
        if w[0] == "inventory":
            k += len(self.inv)
        side = w[1] if len(w) > 1 and w[0] in READS and w[0] not in ("hello", "pos") else None
        turns = 0
        if side in FACINGS:
            turns = (FACINGS.index(side) - FACINGS.index(self.facing)) % 4
            turns = 2 if turns == 2 else min(turns, 1)
        k += turns * TURN
        if not FACING_ONCE:
            reads = READS.get(w[0], 0)
            if w[0] in ("swing", "place", "use", "analyze", "detect", "suckslot", "dropslot") \
                    and side not in FACINGS:
                reads = 0                     # up or down: no face() and no read
            if w[0] == "move" and side not in FACINGS:
                reads = 1                     # where() alone
            if w[0] in ("place", "use") and len(w) > 2 and w[2] in FACINGS:
                reads += 1                    # localFace reads it again
            k += reads + turns
        return k

    # helpers
    def cell(self):
        """Where it stands."""
        return tuple(self.pos)

    def where(self):
        """Its position and facing, as server.lua answers them."""
        return f"{self.pos[0]} {self.pos[1]} {self.pos[2]} {self.facing}"

    def low(self):
        """Under server.lua's energy floor: 12 a step of its way home, and 1500."""
        return self.energy < len(self.trail) * 12 + 1500

    def toward(self, d):
        """The cell on side d, turned that way if it is a horizontal side."""
        if d in FACINGS:
            self.facing = d
        return add(self.cell(), d)

    # commands: server.lua's, each c_<command> with its words as arguments
    def c_hello(self):
        """Position, facing, energy, its maximum, inventory size, the server's version."""
        return f"{self.where()} {self.energy} {self.max} {self.size} 1.0"

    def c_pos(self):
        """Position and facing."""
        return self.where()

    def c_energy(self):
        """Energy and its maximum."""
        return f"{self.energy} {self.max}"

    def c_setpos(self, x, y, z):
        """The robot's own idea of where it is: true here already."""
        return self.where()

    def c_wait(self, s="1"):
        """A pause (its ticks in Robot.ticks; the crew's naps are its own)."""
        return str(self.energy)

    def c_face(self, d):
        """Turned to d."""
        self.facing = d
        return d

    def c_chunk(self, on="on"):
        """The robot's chunkloader: every chunk here stays as loaded as the scans say."""
        return "true"

    def c_move(self, d, *flags):
        """One step, breaking nothing: not into ground or a robot, not into water unless `wet`,
        not over a fence or wall (its box stands half a block up); 15 energy a step."""
        if self.low() and "home" not in flags:
            raise RobotError("low energy: send back")
        n = self.toward(d)
        s = self.world.at(n)
        if s[0] == "water" and "dry" in flags and "wet" not in flags:
            # server.lua skips its detect on a `dry` move, and robot.move does not refuse a
            # liquid: the robot goes in and the source is gone for good. Counted, and the gate
            # fails on it (the user's leave for dry moves holds only above the river's level)
            self.world.dry_into_water.append((self.name, n))
            print(f"  sim: DRY MOVE INTO WATER: {self.name} at {n}", flush=True)
        elif s[0] == "water" and "wet" not in flags:
            raise RobotError(f"a liquid toward {d}")
        if s[0] in ("solid", "robot"):
            raise RobotError(f"blocked toward {d} (solid)")
        b = self.world.at(add(n, "d"))
        if b[0] == "solid" and any(k in b[1].lower() for k in ("fence", "wall")):
            raise RobotError(f"blocked toward {d} (solid)")   # a fence's box is 1.5 high
        self.world.cells[self.cell()] = self.under         # what it stood in: air, or water
        self.under = ("water",) if s[0] == "water" else ("air",)
        self.pos = list(n)
        self.world.cells[n] = ("robot", self.name)
        self.energy -= 15
        # robot/server.lua's way home: a step that undoes the one before is taken off; at the
        # start block it is emptied
        if self.trail and self.trail[-1] == OPP[d]:
            self.trail.pop()
        else:
            self.trail.append(d)
        if self.cell() == (0, 0, 0):
            self.trail = []
        self.moves += 1
        if self.energy <= 0:
            self.dead = True
        return f"{self.where()} {self.energy}"

    def c_analyze(self, d):
        """The block beside: name, meta and hardness, as the geolyzer's analyze."""
        s = self.world.at(self.toward(d))
        if s[0] == "air":
            return "air"
        if s[0] == "water":
            return "minecraft:water 0 100.00"
        if s[0] == "robot":
            return f"{ROBOT} 0 2.00"
        return f"{s[1]} {s[2]} 1.50"

    def c_detect(self, d):
        """Whether the cell beside is passable, and what it is, as robot.detect."""
        s = self.world.at(self.toward(d))
        return {"air": "false air", "water": "false liquid"}.get(s[0], "true solid")

    def c_scan(self, dx, dz, dy="-8", h="24"):
        """A column's hardness, h cells from dy up, at (dx, dz) from the robot: 0 air, 100
        water, else solid (no noise); now and then a chunk not loaded, read all air."""
        x, y, z = self.cell()
        if self.world.rnd.random() < self.world.unload:
            # a chunk not loaded reads all air (Cairol's, 2026-10-04): builders must not
            # believe it (look_over)
            return ",".join(["0"] * int(h))
        out = []
        for i in range(int(h)):
            s = self.world.at((x + int(dx), y + int(dy) + i, z + int(dz)))
            out.append({"air": "0", "water": "100.00", "robot": "2.00"}.get(s[0], "1.50"))
        return ",".join(out)

    def c_swing(self, d, *flags):
        """The block beside broken into the inventory, water let in (World.open_up); a swing at
        a robot is counted - server.lua refuses it, the count says the crew asked - and ground
        broken outside the plan is counted."""
        if self.low() and "home" not in flags:
            raise RobotError("low energy: send back")
        n = self.toward(d)
        s = self.world.at(n)
        if s[0] == "robot":
            self.world.robot_swings.append((self.name, s[1], n))
            raise RobotError("blocked: a robot")          # robot/server.lua's guard
        if s[0] == "air":
            return "air"
        if s[0] == "water":
            raise RobotError("a liquid")
        if n not in self.world.plan and n not in self.world.clear and s[1] != COBBLE[0]:
            self.world.ground_dug.append((self.name, n, s[1]))
        self.world.open_up(n)
        self.give((s[1], s[2]), 1)
        self.energy -= 5
        return "true"

    def give(self, item, k):
        """k of item into the first slot that takes them (lost when none does)."""
        for slot in range(1, self.size + 1):
            if slot not in self.inv:
                self.inv[slot] = [item[0], item[1], k]
                return
            if (self.inv[slot][0], self.inv[slot][1]) == item and self.inv[slot][2] + k <= 64:
                self.inv[slot][2] += k
                return

    def c_place(self, d, face="-", slot=None, sneak=None):
        """The selected block into the cell on side d (air or water), clicking `face` of it: a
        solid there that the click meets (placing.meets), else it goes in elsewhere; its meta
        by placed_meta. Seeds go only on farmland's top."""
        if self.low():
            raise RobotError("low energy: send back")
        if slot and slot != "-":
            self.sel = int(slot)
        st = self.inv.get(self.sel)
        if not st or st[2] <= 0:
            raise RobotError("nothing selected")
        t = self.toward(d)
        if self.world.at(t)[0] not in ("air", "water"):
            raise RobotError("not placed")
        f = add(t, face)
        fs = self.world.at(f)
        if fs[0] != "solid":
            raise RobotError("not placed")
        shown = self.world.plan[f] if f in self.world.plan and fs[1] == self.world.plan[f][0] \
            else (fs[1], fs[2], 0, "-")
        if not meets(shown, face, d):
            # The click missed a thin block (bars, a pane, a fence, a ladder; a slab's empty
            # half) and met what was behind: the place answers ok, the block goes in elsewhere
            # (the stray brick over the lighthouse's bars, 2026-10-04). Not modelled: where.
            self.world.strays.append((self.name, t, st[0], f, fs[1]))
            st[2] -= 1
            if st[2] == 0:
                del self.inv[self.sel]
            return st[0]
        if (st[0], st[1]) == SEEDS:
            # seeds take only to farmland, clicked on its top
            if face != "d" or fs[1] != TILLED:
                raise RobotError("not placed")
            self.world.cells[t] = ("solid", CROP, 0)
            st[2] -= 1
            if st[2] == 0:
                del self.inv[self.sel]
            return st[0]
        self.world.cells[t] = ("solid", st[0],
                               placed_meta(self.world.plan.get(t), st, d, face, self.facing))
        st[2] -= 1
        if st[2] == 0:
            del self.inv[self.sel]
        self.energy -= 5
        return st[0]

    def c_use(self, d, a=None, b=None):
        """With a face: the tool's use on that face of the block beyond the target. A hoe tills
        dirt or grass with air over it (vanilla ItemHoe: a robot standing on it is no air)."""
        face = a if a not in (None, "sneak", "-") else None
        t = self.toward(d)
        if face is None:
            return "true"
        c = add(t, face)
        cs = self.world.at(c)
        if self.tool == HOE and face == "d" and cs[0] == "solid" \
                and cs[1] in ("minecraft:grass", "minecraft:dirt") \
                and self.world.at(t)[0] == "air":
            self.world.cells[c] = ("solid", TILLED, 0)
            self.world.tilled += 1
            return "true item_used"
        return "false"

    def c_equip(self):
        """The selected slot and the tool slot swapped, as robot.equip (the hoe, the pick)."""
        st = self.inv.pop(self.sel, None)
        if self.tool:
            self.inv[self.sel] = [self.tool[0], self.tool[1], 1]
        self.tool = (st[0], st[1]) if st else None
        return "true"

    def c_select(self, slot):
        """The slot that place, suck and drop use."""
        self.sel = int(slot)
        return "true"

    def c_inventory(self):
        """Every slot held: slot:name:damage:count, ';' between."""
        return ";".join(f"{s}:{v[0]}:{v[1]}:{v[2]}" for s, v in sorted(self.inv.items()))

    def c_suckslot(self, d, slot, count):
        """Up to count from the interface's slot (what the mini ME stocked there) into the
        selected slot, as far as the network holds it and the stack takes it."""
        me = self.world.me
        if add(self.cell(), d) != INTERFACE:
            raise RobotError("no inventory there")
        it = me.slots.get(int(slot))
        if not it:
            return "0"
        have = self.inv.get(self.sel)
        if have and (have[0], have[1]) != it:
            return "0"
        k = min(int(count), 64 - (have[2] if have else 0), me.net.get(it, 0))
        if k <= 0:
            return "0"
        me.net[it] -= k
        if have:
            have[2] += k
        else:
            self.inv[self.sel] = [it[0], it[1], k]
        return str(k)

    def c_dropslot(self, d, slot, count=None):
        """The selected slot into the interface, and so into the network."""
        me = self.world.me
        if add(self.cell(), d) != INTERFACE:
            raise RobotError("no inventory there")
        st = self.inv.pop(self.sel, None)
        if not st:
            return "0"
        if st[0] != ROBOT:
            me.net[(st[0], st[1])] = me.net.get((st[0], st[1]), 0) + st[2]
        return "true"

    def c_charge(self, share="0.95", patience="60"):
        """Charged full at its park, beside a charger (the time it takes: batch's CHARGE_RATE)."""
        if self.cell() != self.home:
            raise RobotError("the charger gave nothing")
        self.energy, self.trail = self.max, []
        return str(self.energy)


class ME:
    """The mini ME's computer: what the network holds, the interface's stocked slots, sides."""

    def __init__(self, plan, extra=200, stock=None):
        """The network's stock: read from the real one (`stock`, read_me.py's data/me-now.txt)
        when there is such a file - the audit, 2026-10-04: holding the plan's need and 200 more,
        it never ran short where the real one did; else the plan's need and `extra`."""
        self.net = {}
        if stock and os.path.exists(stock):
            for line in open(stock):
                w = line.split()
                if w and not w[0].startswith("#"):
                    self.net[(w[0], int(w[1]))] = int(w[2])
        else:
            from placing import item_of
            for b in plan.values():
                it = item_of(b[0], b[1])
                self.net[it] = self.net.get(it, 0) + 1
            for it in list(self.net):
                self.net[it] += extra
            self.net[COBBLE] = self.net.get(COBBLE, 0) + 512
            self.net[HOE] = 1             # one hoe, as the real one
        self.slots, self.holders = {}, {}
        self.name, self.pos, self.answered, self.pending = "mini ME", [1, 0, 1], 0, 0
        self.writer = type("W", (), {"is_closing": lambda s: False})()

    async def close(self):
        """Nothing to close."""

    async def run(self, cmd):
        """One command: its value, or RobotError."""
        (st, v), = await self.batch([cmd])
        if st != "ok":
            raise RobotError(v)
        return v

    async def batch(self, cmds):
        """robot/me_server.lua's commands: items, stock, clear, claim, release, count; one that
        fails ends the batch."""
        await asyncio.sleep(BATCH)
        self.answered += 1
        out, failed = [], False
        for cmd in cmds:
            if failed:
                out.append(("skip", ""))
                continue
            w = cmd.split()
            if w[0] == "items":
                out.append(("ok", ";".join(f"{k[0]}:{k[1]}:{n}" for k, n in self.net.items()
                                           if n > 0)))
            elif w[0] == "stock":
                it = (w[2], int(w[3]))
                if not self.net.get(it):
                    out.append(("err", "the network has no " + w[2]))
                    failed = True
                else:
                    self.slots[int(w[1])] = it
                    out.append(("ok", w[1]))
            elif w[0] == "clear":
                self.slots.pop(int(w[1]), None)
                out.append(("ok", w[1]))
            elif w[0] == "claim":
                if self.holders.get(w[1], w[2]) != w[2]:
                    out.append(("err", "held by " + self.holders[w[1]]))
                    failed = True
                else:
                    self.holders[w[1]] = w[2]
                    out.append(("ok", w[1]))
            elif w[0] == "release":
                if self.holders.get(w[1]) == w[2]:
                    del self.holders[w[1]]
                out.append(("ok", w[1]))
            elif w[0] == "count":
                out.append(("ok", str(self.net.get((w[1], int(w[2])), 0))))
            else:
                out.append(("err", "no command " + w[0]))
                failed = True
        return out


class Links:
    """reach() and me_connect() for builders.py, over the simulated world."""

    def __init__(self, world, crew, stock=None):
        """Each robot of the crew at its park, and the mini ME with `stock` (ME.__init__)."""
        self.world, self.robots = world, {}
        for prefix, name, home, _ in crew:
            self.robots[prefix] = Robot(world, name, prefix, home, home)
        world.me = ME(world.plan, stock=stock)

    async def reach(self, prefix, tries=6, **kw):
        """The robot of that relay prefix, as rlink.reach; a broken one cannot be reached."""
        r = self.robots[prefix]
        if r.dead:
            raise RobotError(f"cannot reach {prefix}")
        return r

    async def me_connect(self, zone):
        """The mini ME's computer, as me.me_connect."""
        return self.world.me


def report(world, links, t0):
    """What the world holds against the plan, and what went wrong: robots broken, swings at
    robots, ground dug outside the plan, blocks gone in elsewhere; each robot's count."""
    plan = world.plan
    holds = [c for c, b in plan.items()
             if world.at(c)[0] == "solid" and world.at(c)[1] == b[0]]
    built = len(holds)
    right = sum(1 for c in holds if world.at(c)[2] == expected_meta(plan[c]))
    print(f"sim: {built} of {len(plan)} planned cells hold their block ({right} with the planned "
          f"state); robots broken {len(world.broken_robots)}, swings at robots "
          f"{len(world.robot_swings)}, ground dug outside the plan {len(world.ground_dug)} ("
          f"{sum(1 for g in world.ground_dug if g[1] not in world.dig_ok)} outside the boxes "
          f"the user let them dig in, data/dig-ok.txt; "
          f"{len({g[1] for g in world.ground_dug if world.at(g[1])[0] != 'solid'})} "
          f"of them still open); went in elsewhere {len(world.strays)}")
    print(f"sim: dry moves into water {len(world.dry_into_water)}"
          + (f": {world.dry_into_water[:5]}" if world.dry_into_water else ""))
    if world.lost:
        back = sum(1 for c in world.lost if world.at(c)[0] == "solid")
        print(f"  recorded built but gone at the start: {len(world.lost)}, built again {back}")
    for s in world.strays[:5]:
        print(f"  stray: {s[0]} put {s[2]} for {s[1]}, its click on {s[4]} at {s[3]} missed")
    print(f"  all: {sum(r.answered for r in links.robots.values())} batches, "
          f"{sum(r.moves for r in links.robots.values())} moves")
    for r in links.robots.values():
        print(f"  {r.name}: {r.answered} batches, {r.moves} moves, energy {r.energy}, "
              f"{'DEAD' if r.dead else 'alive'} at {tuple(r.pos)}")
    print(f"  {time.time() - t0:.1f} s of the PC's time")


async def main(a):
    """One run of the crew over the simulated world, reported (report, the probe, leftovers).
    Options as in the module comment; what builders.py writes for the live crew (strays,
    crew-stacks) goes to a temporary folder, never over the live crew's files."""
    import builders, tempfile
    global FACING_ONCE
    if "--facing-each" in a:          # the server.lua of run 14: getFacing at every step
        FACING_ONCE = False
    if "--river" in a:                # a river's level forced, to try the gate's dry-move check
        level = int(a[a.index("--river") + 1])
        builders.river = lambda site, margin=16: level
    builders.CLOCK = asyncio.get_running_loop().time
    builders.ACTIONS = a[a.index("--actions") + 1] if "--actions" in a else None
    if builders.ACTIONS and os.path.exists(builders.ACTIONS):
        os.remove(builders.ACTIONS)
    tmp = tempfile.mkdtemp(prefix="sim-")
    builders.STRAYS = os.path.join(tmp, "strays.txt")
    builders.STACKS = os.path.join(tmp, "crew-stacks.txt")
    builders.PENDING = None                               # the viewer's file: the live crew's
    stock = None if "--plan-stock" in a else (
        a[a.index("--me") + 1] if "--me" in a else os.path.join(HERE, "data", "me-now.txt"))
    unload = float(a[a.index("--unload") + 1]) if "--unload" in a else 0.02
    plan = a[a.index("--plan") + 1] if "--plan" in a else os.path.join(HERE, "data",
                                                                       "harbour.txt")
    seed = int(a[a.index("--seed") + 1]) if "--seed" in a else 1
    n = int(a[a.index("--robots") + 1]) if "--robots" in a else len(builders.CREW)
    steps = int(a[a.index("--steps") + 1]) if "--steps" in a else None
    mp = a[a.index("--map") + 1] if "--map" in a else os.path.join(HERE, "data", "map.txt")
    if "--done" in a:                     # a copy of the record: before and after alike
        buildsite.DONE = a[a.index("--done") + 1]
    site = buildsite.Site(plan, mp)
    world = World(buildsite.Site(plan, mp), seed)
    world.unload, world.rnd = unload, random.Random(seed)
    crew_def = builders.CREW[:n]
    links = Links(world, crew_def, stock)
    t0 = time.time()
    for opt in ("--kill", "--drop"):      # NAME@SECONDS: that robot off the relay then
        if opt not in a:
            continue
        who, at = a[a.index(opt) + 1].split("@")

        async def kill(who=who, at=float(at), gone=opt == "--kill"):
            """A robot gone mid-run (--kill: broken, as Pintsize's coroutine was, run 8: is it
            said at once?) or its link dropped once (--drop: reached again?)."""
            await asyncio.sleep(at)
            for r in links.robots.values():
                if r.name == who:
                    if gone:
                        r.dead = True
                    else:
                        r.drop_once = True
                    print(f"  sim: {who} {'off the relay' if gone else 'link dropped'} at "
                          f"{at:.0f} s", flush=True)
        asyncio.ensure_future(kill())
    # crafting off: the simulated robots have no crafting table (craft.py's commands); the
    # live crew runs with --no-craft as well. The watchdog runs, into the temporary folder.
    crew = await builders.run(site, crew_def, links.reach, links.me_connect, crafting=False,
                              limit=steps, record=None, watch=True, dig="--dig" in a)
    report(world, links, t0)
    print(f"  the crew's time: {asyncio.get_running_loop().time() / 60:.1f} simulated minutes")
    if builders.ACTIONS:
        import probe
        probe.report(probe.load(builders.ACTIONS))
    print("  idle waits for a sector:", {b.name: b.idle for b in crew.builders})
    print("  tilled:", world.tilled, "; tool slots:",
          {r.name: r.tool for r in links.robots.values()})
    leftovers(site)
    if "--left" in a:                     # the cells left, one a line, to compare runs
        with open(a[a.index("--left") + 1], "w") as f:
            for c in sorted(site.pending()):
                f.write(f"{c[0]} {c[1]} {c[2]} {site.plan[c][0]}\n")


def leftovers(site):
    """What is left, and why: no clickable face at all; a face but every cell to stand in
    closed; or a face and a cell to stand in (then reach, or closing itself in, kept it)."""
    from collections import Counter
    from placing import options, OPP
    names, why = Counter(), Counter()
    pend = set(site.pending())
    ex = {}
    for c in pend:
        names[site.plan[c][0].split(":")[-1]] += 1
        r = "no face"
        for sd, f in options(site.plan[c]):
            if site.clickable(add(c, f), f, sd):
                st = add(c, OPP[sd])
                if site.cost(st) is not None:
                    r = "face and stand"
                    break
                r = "face, stand " + site.kind(st) + ("/pending" if st in pend else "")
        why[r] += 1
        ex.setdefault(r, c)
    print("left by block:", dict(names.most_common(12)))
    print("left by why:", dict(why.most_common(12)))
    print("an example of each:", ex)


if __name__ == "__main__":
    loop = Clocked()
    asyncio.set_event_loop(loop)
    loop.run_until_complete(main(sys.argv[1:]))
