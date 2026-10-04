"""craft.py - Gunter crafts what the house needs, out of the mini ME and back into it
(3d-draw/docs/materials.md, "Crafting, by the robot").

    python 3d-draw/craft.py try <pattern name>      lays that pattern once and says what came out
    python 3d-draw/craft.py make <name> <meta> <n>  makes n of an item (and what goes into it)
    python 3d-draw/craft.py need                    what data/house.txt needs that the ME lacks
    python 3d-draw/craft.py short                   makes what the harbour's blocks not yet
                                                    built need beyond what the mini ME holds

The robot stands at (0 0 1) facing east, the mini ME's interface in front; the mini ME's
computer stocks an interface slot with what it asks for (robot/me_server.lua), it takes it
(`suckslot`, again after a second: the interface fills on its own tick), crafts in its grid -
slots 1-3, 5-7, 9-11 - and drops what it made back into the interface, which puts it into the
network. Its GregTech saw stays in slot 4: a crafting tool comes back into the grid, damaged.

Coroutines (asyncio, rlink.AsyncRobot), as the builders: builders.py has Gunter craft the
shortfall in its own loop, on the crew's links, before he builds (`short`, below).

RECIPES holds only what was crafted and checked in-game; a pattern is 9 cells, row by row,
None for empty. `craft <slot> <n>` makes n *items*, so a batch of k crafts lays k of each
ingredient and asks for k * yield.
"""
import asyncio, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import me as mini                                             # noqa: E402
import rlink                                                  # noqa: E402

GRID = [1, 2, 3, 5, 6, 7, 9, 10, 11]
SAW_SLOT = 4
STORE = [8, 12, 13, 14, 15, 16]
SAW = ("gregtech:gt.metatool.01", 10)
AT = [0, 0, 1]                                                # in front of the interface

LOG, PL, ST = ("minecraft:log", 1), ("minecraft:planks", 1), ("minecraft:stick", 0)
LOG_B, PL_B = ("minecraft:log", 2), ("minecraft:planks", 2)
PL_D, SB, CB = ("minecraft:planks", 5), ("minecraft:stonebrick", 0), ("minecraft:cobblestone", 0)
GL = ("minecraft:glass", 0)
PL_A = ("minecraft:planks", 4)
_ = None

# (name, meta) -> (pattern, how many one craft makes). Checked in-game on 2026-10-04.
RECIPES = {
    PL: ([LOG, _, _, _, _, _, _, _, _], 2),
    PL_B: ([LOG_B, _, _, _, _, _, _, _, _], 2),
    # tried 2026-10-04 with the user's logs: one log, two planks
    ("minecraft:planks", 4): ([("minecraft:log2", 0), _, _, _, _, _, _, _, _], 2),
    PL_D: ([("minecraft:log2", 1), _, _, _, _, _, _, _, _], 2),
    ("minecraft:acacia_stairs", 0): ([PL_A, _, _, PL_A, PL_A, _, PL_A, PL_A, PL_A], 4),
    ST: ([PL, _, _, PL, _, _, _, _, _], 2),
    ("minecraft:spruce_stairs", 0): ([PL, _, _, PL, PL, _, PL, PL, PL], 4),
    ("ExtraTrees:fence", 1): ([ST, PL, ST, ST, PL, ST, ST, PL, ST], 1),
    ("minecraft:dark_oak_stairs", 0): ([PL_D, _, _, PL_D, PL_D, _, PL_D, PL_D, PL_D], 4),
    ("minecraft:stone_brick_stairs", 0): ([SB, _, _, SB, SB, _, SB, SB, SB], 4),
    ("minecraft:stone_stairs", 0): ([CB, _, _, CB, CB, _, CB, CB, CB], 4),
    ("minecraft:wooden_slab", 1): ([SAW, PL, _, _, _, _, _, _, _], 2),
    ("minecraft:wooden_slab", 2): ([SAW, PL_B, _, _, _, _, _, _, _], 2),
    ("minecraft:wooden_slab", 5): ([SAW, PL_D, _, _, _, _, _, _, _], 2),
    ("minecraft:stone_slab", 5): ([SAW, SB, _, _, _, _, _, _, _], 1),
    ("minecraft:stone_slab", 3): ([SAW, CB, _, _, _, _, _, _, _], 1),
    ("minecraft:glass_pane", 0): ([SAW, GL, _, _, _, _, _, _, _], 2),
    ("malisisdoors:spruceFenceGate", 0): ([("minecraft:flint", 0), _, ("minecraft:flint", 0),
                                           PL, ST, PL, PL, ST, PL], 1),
    ("malisisdoors:trapdoor_spruce", 0): ([("minecraft:wooden_slab", 1), ST,
                                           ("minecraft:wooden_slab", 1), ST, ("minecraft:flint", 0),
                                           ST, ("minecraft:wooden_slab", 1), ST,
                                           ("minecraft:wooden_slab", 1)], 1),
}
# Never crafted by `short`: the user gives them (2026-10-04: "I'm giving you the fences from now
# on"). `make` still makes one when asked by name.
# The spruce fences Gunter makes after all (the user, later that day: from the spruce logs).
GIVEN = {("minecraft:fence", 0)}
# Short items are made at least BATCH at a time, but these, to the count.
BATCH = 64
EXACT = {("malisisdoors:spruceFenceGate", 0), ("malisisdoors:trapdoor_spruce", 0),
         ("ExtraTrees:fence", 1)}
LOG_ACACIA, LOG_DARK = ("minecraft:log2", 0), ("minecraft:log2", 1)
# Patterns still to be tried, by name (`try`).
TRIALS = {
    # For the harbour (2026-10-04): the user gave acacia and dark oak logs.
    "acacia planks": [LOG_ACACIA, _, _, _, _, _, _, _, _],
    "dark oak planks": [LOG_DARK, _, _, _, _, _, _, _, _],
    "acacia stairs": [PL_A, _, _, PL_A, PL_A, _, PL_A, PL_A, PL_A],
    "dark oak stairs": [PL_D, _, _, PL_D, PL_D, _, PL_D, PL_D, PL_D],
    "stone brick stairs": [SB, _, _, SB, SB, _, SB, SB, SB],
    "cobble stairs": [CB, _, _, CB, CB, _, CB, CB, CB],
    "saw + spruce planks": [SAW, PL, _, _, _, _, _, _, _],
    "saw over spruce planks": [SAW, _, _, PL, _, _, _, _, _],
    "saw + stone bricks": [SAW, SB, _, _, _, _, _, _, _],
    "saw + cobblestone": [SAW, CB, _, _, _, _, _, _, _],
    "saw + glass": [SAW, GL, _, _, _, _, _, _, _],
    "saw + dark oak planks": [SAW, PL_D, _, _, _, _, _, _, _],
    "saw + birch planks": [SAW, PL_B, _, _, _, _, _, _, _],
    "spruce gate F_F/PSP/PSP": [("minecraft:flint", 0), _, ("minecraft:flint", 0),
                                PL, ST, PL, PL, ST, PL],
    "trapdoor, spruce slabs": [("minecraft:wooden_slab", 1), ST, ("minecraft:wooden_slab", 1),
                               ST, ("minecraft:flint", 0), ST,
                               ("minecraft:wooden_slab", 1), ST, ("minecraft:wooden_slab", 1)],
    # For the village (2026-10-04: 12 wooden doors, 7 in the ME): vanilla 1.7.10's six planks in
    # two columns; GregTech: New Horizons may have changed it - to be tried, not trusted
    "door, spruce planks": [PL, PL, _, PL, PL, _, PL, PL, _],
    "door, dark oak planks": [PL_D, PL_D, _, PL_D, PL_D, _, PL_D, PL_D, _],
}


class Crafter:
    """Gunter at the crafting: Crafter(robot, me) on links already open (the crew's), or
    `await Crafter.open()` on its own. It stands at a side of the interface (`spot`, the west by
    default: me.WEST) and fetches and gives back the way the builders load: what a craft
    lacks staged and taken in one pull, the grid laid in one batch and cleared in one (a command
    a round trip held Gunter at the interface for minutes a craft, 2026-10-04)."""

    def __init__(self, r, me, spot=None):
        self.r, self.me = r, me
        self.spot = spot or mini.WEST

    @classmethod
    async def open(cls):
        me = await rlink.reach("9cdb8754", log=None, program="me_server", zone=b"meserver")
        c = cls(await rlink.reach("016db072"), me)
        if c.r.pos == [0, 0, 0]:
            await c.r.run("move s")
        await c.at_interface()
        return c

    async def at_interface(self):
        if tuple(self.r.pos) != tuple(self.spot[0]):
            raise SystemExit(f"Gunter is at {self.r.pos}, not in front of the interface")
        await self.r.run(f"face {self.spot[1]}")

    async def close(self):
        await self.r.run("move n")
        await self.r.close()
        await self.me.close()

    async def inv(self):
        return await mini.inv_of(self.r)

    @staticmethod
    def count(inv, item):
        return sum(n for s, (a, b, n) in inv.items() if (a, b) == item and s in STORE)

    async def held(self, item):
        return self.count(await self.inv(), item)

    async def fetch(self, items):
        """{item: n} from the mini ME into the store slots (me.pull)."""
        inv = await self.inv()
        free = [s for s in STORE if s not in inv]
        if sum((n + 63) // 64 for n in items.values()) > len(free):
            await self.deposit_all(keep=tuple(items))
            inv = await self.inv()
            free = [s for s in STORE if s not in inv]
        got, missing = await mini.pull(self.r, self.me, self.spot, items, free)
        if missing:
            raise SystemExit(f"the mini ME did not give {missing}")

    async def deposit_all(self, keep=()):
        """Everything in the store slots and the grid back into the mini ME, but `keep`."""
        give = [s for s, (a, b, n) in (await self.inv()).items()
                if s != SAW_SLOT and (a, b) not in keep and a != "OpenComputers:robot"]
        if give:
            kept = await mini.give_back(self.r, self.spot[1], self.spot[3], give)
            if kept:
                print(f"  the interface did not take back slots {kept}", flush=True)

    async def lay(self, pattern, k):
        """k of each ingredient into its grid cell, the saw once from its slot: one batch."""
        left = {s: list(v) for s, v in (await self.inv()).items() if s in STORE}
        cmds = []
        for cell, item in zip(GRID, pattern):
            if item is None:
                continue
            if item == SAW:
                cmds.append(f"transfer {SAW_SLOT} {cell} 1")
                continue
            need = k
            for s in sorted(left):
                a, b, n = left[s]
                if need and (a, b) == item and n:
                    m = min(n, need)
                    cmds.append(f"transfer {s} {cell} {m}")
                    left[s][2] -= m
                    need -= m
            if need:
                raise SystemExit(f"short of {item} for the grid")
        if cmds:
            bad = [(c, v) for c, (st, v) in zip(cmds, await self.r.batch(cmds)) if st != "ok"]
            if bad:
                raise SystemExit(f"laying the grid: {bad[0]}")

    async def unlay(self):
        """The grid back, in one batch: the saw to its slot, the rest to free store slots."""
        inv = await self.inv()
        grid = [s for s in inv if s in GRID]
        free = [s for s in STORE if s not in inv]
        if len([s for s in grid if inv[s][:2] != SAW]) > len(free):
            await self.deposit_all()
            inv = await self.inv()
            grid = [s for s in inv if s in GRID]
            free = [s for s in STORE if s not in inv]
        cmds = [f"transfer {s} {SAW_SLOT if inv[s][:2] == SAW else free.pop(0)}" for s in grid]
        if cmds:
            bad = [(c, v) for c, (st, v) in zip(cmds, await self.r.batch(cmds)) if st != "ok"]
            if bad:
                raise SystemExit(f"clearing the grid: {bad[0]}")

    async def craft_once(self, pattern, k=1, yield_=None):
        """Lays pattern for k crafts and crafts them; what came out."""
        await self.unlay()
        inv = await self.inv()
        lack = {}
        for item in set(i for i in pattern if i and i != SAW):
            per = sum(1 for i in pattern if i == item) * k
            short = per - self.count(inv, item)
            if short > 0 and item in RECIPES:
                # Made now if the mini ME has too few: counting ahead missed what other recipes
                # use of the same thing (2026-10-04: sticks ate the planks put by for fences).
                stocked = await self.me_count(item)
                if stocked < short:
                    await self.make(item, short - stocked)
                    inv = await self.inv()
                    short = per - self.count(inv, item)
            if short > 0:
                lack[item] = short
        if lack:
            await self.fetch(lack)
        await self.lay(pattern, k)
        inv = await self.inv()
        free = [s for s in STORE if s not in inv]
        if not free:
            raise SystemExit("no free slot for what the craft makes")
        n = k * (yield_ or 1) if yield_ else 64
        status, values = (await self.r.batch([f"craft {free[0]} {n}"]))[0]
        await self.unlay()
        return status, values

    async def make(self, item, n):
        """n of item, its ingredients made first; all of it left in the robot."""
        pattern, y = RECIPES[item]
        crafts = math.ceil((n - await self.held(item)) / y)
        for ing in set(i for i in pattern if i and i != SAW):
            per = sum(1 for i in pattern if i == ing)
            if ing in RECIPES and \
                    await self.me_count(ing) + await self.held(ing) < per * crafts:
                await self.make(ing, per * crafts - await self.me_count(ing))
        while crafts > 0:
            k = min(crafts, 64 // max(1, max(sum(1 for i in pattern if i == ing)
                                             for ing in pattern if ing)), 64 // y)
            status, values = await self.craft_once(pattern, k, y)
            print(f"  {item[0]}:{item[1]} x{k * y}: {status} {values}", flush=True)
            if status != "ok":
                raise SystemExit("crafting failed")
            crafts -= k

    async def me_count(self, item):
        return (await mini.me_items(self.me)).get(item, 0)          # the static PC's cache

    async def short(self, need=None):
        """Makes what the steps not yet built still need beyond what the mini ME holds (the
        user, 2026-10-04: "make him craft things, in batches, not one by one"): each short item
        in one go, as many at a craft as its stacks allow. What has no recipe is named.
        `need`: {item: n} from the caller (builders.py, from its site), else remaining()'s."""
        items = sorted((need or remaining()).items(), key=lambda kv: -kv[1])
        asks = []
        for k, (item, n) in enumerate(items):
            have = await self.me_count(item)
            self.r.status("crafting", f"{item[0].split(':')[-1]}: {max(0, n - have)} short",
                          f"item {k + 1} of {len(items)} the house still needs")
            print(f"{item[0] + ':' + str(item[1]):40} still {n:4}  in the ME {have:5}",
                  flush=True)
            if have < n and item in GIVEN:
                print(f"  short by {n - have}: the user gives these", flush=True)
                asks.append((item, n - have))
            elif have < n and item in RECIPES:
                # At least a full batch (the user, 2026-10-04: "craft at least 64 or around that
                # at once"): 17 stairs cost the same trip and grid as 64. Gates, trapdoors and
                # fences are made to the count: their flint and sticks are not to be spent.
                await self.make(item, n - have if item in EXACT else max(n - have, BATCH))
                await self.deposit_all()
            elif have < n:
                print(f"  short by {n - have}, no recipe: to ask for", flush=True)
                asks.append((item, n - have))
        return asks


def bill():
    """What data/house.txt needs, as items: a door once (its lower half), stairs, slabs, logs,
    trapdoors and torches whichever way they stand. The scaffolds' cobblestone is had back."""
    need = {}
    for line in open(os.path.join(HERE, "data", "house.txt")):
        p = line.split()
        if not p or p[0] != "b" or p[4] == "minecraft:air":
            continue
        name, meta = p[4], int(p[5])
        if name == "minecraft:wooden_door":
            if meta >= 8:
                continue
            meta = 0
        elif name == "minecraft:log":
            meta &= 3
        elif name.endswith("_slab"):
            meta &= 7
        elif name.endswith("_stairs") or name.endswith("trapdoor") or \
                name.endswith("trapdoor_spruce") or name == "minecraft:torch":
            meta = 0
        need[(name, meta)] = need.get((name, meta), 0) + 1
    return need


def remaining(plan=os.path.join(HERE, "data", "harbour.txt")):
    """What the plan's blocks not yet built (buildsite: the plan against data/build-done.txt)
    still need, as items - what builders.py's Gunter crafts first, by the same count."""
    import buildsite
    from placing import item_of
    site, need = buildsite.Site(plan), {}
    for c in site.pending():
        it = item_of(*site.plan[c][:2])
        need[it] = need.get(it, 0) + 1
    return need


async def main():
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    c = await Crafter.open()
    try:
        if a[0] == "try":
            names = [" ".join(a[1:])] if len(a) > 1 else list(TRIALS)
            for name in names:
                print(f"{name:28} -> {await c.craft_once(TRIALS[name])}", flush=True)
                await c.deposit_all()
        elif a[0] == "make":
            await c.make((a[1], int(a[2])), int(a[3]))
            await c.deposit_all()
        elif a[0] == "short":
            await c.short()
        elif a[0] in ("need", "all"):
            # What the house needs against what the mini ME has; `all` makes what has a recipe.
            for item, n in sorted(bill().items(), key=lambda kv: -kv[1]):
                have = await c.me_count(item)
                how = "recipe" if item in RECIPES else "from the ME" if have >= n else "ASK"
                print(f"{item[0] + ':' + str(item[1]):40} need {n:4}  have {have:5}  {how}",
                      flush=True)
                if a[0] == "all" and item in RECIPES and have < n:
                    await c.make(item, n - have)
                    await c.deposit_all()
    finally:
        await c.deposit_all()
        await c.close()


if __name__ == "__main__":
    asyncio.run(main())
