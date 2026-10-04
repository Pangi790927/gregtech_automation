"""me.py - the mini ME, as the builders and Gunter's crafting use it: its computer at the relay
(robot/me_server.lua), what it holds, the interface's two sides, and blocks into and out of a
robot there. Taken out of build_run.py (the old system, retired 2026-10-04: the user, "you may
delete old unused code in the build system"), as it was.
"""
import os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rlink                                                  # noqa: E402

ME_COMPUTER = "9cdb8754"            # the mini ME's computer, at the relay
STOCK = os.path.join(HERE, "data", "me-now.txt")              # what it held, last read
# The interface's two free sides: where to stand, which way to face, its slots there.
# Slots 1-3 (west) and 5-7 (east) are stocked; 4 and 8 take what robots give back, which the
# interface puts into the network on its tick (it is told to stock nothing there).
WEST, EAST = ((0, 0, 1), "e", (1, 2, 3), 4), ((2, 0, 1), "w", (5, 6, 7), 8)


async def me_connect(zone):
    """The mini ME's computer, in a session of that name."""
    return await rlink.reach(ME_COMPUTER, log=None, program="me_server",
                             zone=zone.encode())


async def me_items(me):
    """What the mini ME holds, {(name, damage): count}, from its computer (`items`)."""
    out = {}
    for part in filter(None, (await me.run("items")).split(";")):
        name, dmg, n = part.rsplit(":", 2)
        out[(name, int(dmg))] = int(n)
    return out


def save_stock(items, path=STOCK):
    """What me_items read, into `path` as `name damage count` lines under a dated header: the
    mini ME sim.py starts from."""
    with open(path, "w", newline="\n") as f:
        f.write(f"# the mini ME, read {time.strftime('%Y-%m-%d %H:%M')}: name damage count\n")
        for (name, dmg), n in sorted(items.items()):
            f.write(f"{name} {dmg} {n}\n")


async def inv_of(r):
    """A robot's inventory: slot -> (name, damage, count)."""
    out = {}
    for part in filter(None, (await r.run("inventory")).split(";")):
        slot, rest = part.split(":", 1)
        name, dmg, n = rest.rsplit(":", 2)
        out[int(slot)] = (name, int(dmg), int(n))
    return out


async def give_back(r, side, ret, slots):
    """What those robot slots hold, into the interface's return slot for that side (`dropslot`,
    never a plain drop: that lands in any free slot, a stocked one too), in one batch; the
    interface empties the slot into the network on its tick, so each drop waits a little, and
    what did not go is tried again a second later. -> the slots that kept their blocks."""
    left = list(slots)
    for t in range(4):
        if not left:
            break
        cmds = (["wait 1"] if t else []) + [f"face {side}"]
        for s_ in left:
            cmds += [f"select {s_}", f"dropslot {side} {ret}", "wait 0.25"]
        replies = await r.batch(cmds)
        drops = [v for c, (st_, v) in zip(cmds, replies) if c.startswith("dropslot")]
        drops += [""] * (len(left) - len(drops))
        left = [s_ for s_, v in zip(left, drops) if v != "true"]
    return left


async def stage(me, items, islots, clear=()):
    """Each (item, n) into an interface slot of its own, stocked to 64 at most; the interface
    fills it on its tick, and again whenever it is emptied. `clear`: slots told to stock nothing
    first, in the same batch. -> ([(item, n, slot)], [items the network has none of])."""
    todo = list(zip(items, islots))
    pre = [f"clear {s}" for s in clear]
    staged, missing = [], []
    while todo or pre:
        cmds = pre + [f"stock {s} {it[0]} {it[1]} {min(64, n)}" for (it, n), s in todo]
        replies = (await me.batch(cmds))[len(pre):]
        pre, rest = [], []
        for ((it, n), s), (status, values) in zip(todo, replies):
            if status == "ok":
                staged.append((it, n, s))
            elif status == "skip":                   # an error ends a batch: again
                rest.append(((it, n), s))
            elif "network has no" in values:
                missing.append(it)
            else:
                raise rlink.RobotError(f"stock {it}: {values}")
        todo = rest
    return staged, missing


async def unstage(me, islots):
    """Those interface slots told to stock nothing again; a link already gone is let be."""
    try:
        await me.batch([f"clear {s}" for s in islots])
    except rlink.RobotError:
        pass                                            # the link is gone: the crew clears


async def pull(r, me, spot, items, free, pre=None):
    """At the interface (the robot there): `items` ({item: n}) into the `free` robot slots.
    Up to 3 items are staged at once (`pre`: the first round, staged while it walked); each
    round is one batch to the robot - for every item a select and a suck, and for more than a
    stack, a wait and a suck again, the interface having filled the slot again - and one to the
    mini ME, clearing those slots and staging the next. An item that does not come is tried
    twice more. -> ({item: got}, [items that did not come])."""
    cell, side, islots, ret = spot
    queue = [(it, n) for it, n in items.items() if n > 0]
    got, missing, tries = {}, [], {}
    staged, fresh, last = [], False, []
    if pre is not None:
        staged, missing = pre[0], list(pre[1])
        done_ = {it for it, n, s in staged} | set(missing)
        queue = [q for q in queue if q[0] not in done_]
    try:
        while True:
            if not staged:
                if not queue or not free:
                    break
                rnd, queue = queue[:len(islots)], queue[len(islots):]
                staged, miss = await stage(me, rnd, islots, clear=last)
                last, fresh = [], True
                missing += miss
                if not staged:
                    continue
            cmds = (["wait 0.5"] if fresh else []) + [f"face {side}"]
            plan = []
            for layer in range(max((n + 63) // 64 for it, n, s in staged)):
                if layer:
                    cmds.append("wait 0.5")
                for it, n, s in staged:
                    k = min(64, n - 64 * layer)
                    if k > 0 and free:
                        rs = free.pop(0)
                        cmds += [f"select {rs}", f"suckslot {side} {s} {k}"]
                        plan.append((len(cmds) - 1, it, rs, k))
            replies = await r.batch(cmds)
            bad = [(c, st_, v) for c, (st_, v) in zip(cmds, replies) if st_ != "ok"]
            if bad:
                raise rlink.RobotError(f"at the interface: {bad[0]}")
            for idx, it, rs, k in plan:
                g = int(replies[idx][1])
                if g:
                    got[it] = got.get(it, 0) + g
                else:
                    free.insert(0, rs)
                if g < k:
                    tries[it] = tries.get(it, 0) + 1
                    if tries[it] < 3:
                        queue.insert(0, (it, k - g))
                    elif it not in missing:
                        missing.append(it)
            last = [s for it, n, s in staged]
            staged, fresh = [], False
    finally:
        await unstage(me, islots)
    return got, missing
