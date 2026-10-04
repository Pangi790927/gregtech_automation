"""bench.py - what a robot's step really costs: robot/bench.lua's phases, timed in server ticks on
the robot and in seconds on this PC (3d-draw/docs/speed.md).

    python 3d-draw/bench.py <robot> [--n 10]      runs it; the robot must be lent for it
    python 3d-draw/bench.py --plan                 says what it would do, reaching nothing

The user, 2026-10-04: "tell me the current marks of the bots and we must figure out why those are
slow, so we will analyze their speed and algorithms". A live step took about 1 s against the
pack's 0.4 s move delay; the mod's own code says a step of server.lua costs 13 ticks (speed.md).
This measures both sides of that: the ticks a call costs, and how long a tick is on the server.

Safety: the robot only goes straight up into the air over where it stands, n cells, and back down
to the same cell; it swings at nothing and places nothing. robot/bench.lua scans the column over
it before every phase that moves, and refuses unless every cell reads air. Its position file is
not touched. A robot is driven only when it is lent: this refuses one whose server zone
(rlink's `rserver`) is open, which is how a crew or an agent holds it.

What it prints, and appends to data/bench.txt: each phase's ticks (the robot's count) and wall
seconds (the PC's, the relay's round trip taken off), and from them the ticks of one call or one
step, and the server's ticks a second.
"""
import os, socket, statistics, struct, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rlink                                                             # noqa: E402
from run import relay_host                                               # noqa: E402

OUT = os.path.join(HERE, "data", "bench.txt")
ZONE = b"rbench"


def phases(n):
    """The phases in the order they run: (command, units it counts, what one unit is). The
    calls first, standing still; then the moves, bare first and last, to see the server drift."""
    return [
        ("ping", 1, "round trip"), ("ping", 1, "round trip"), ("ping", 1, "round trip"),
        ("sleep 5", 100, "game tick (os.sleep)"), ("sleep 5", 100, "game tick (os.sleep)"),
        ("facing 20", 20, "navigation.getFacing"), ("energy 20", 20, "computer.energy"),
        ("save 20", 20, "save()"), ("detect 20", 20, "robot.detect"),
        ("scan 10", 10, "geolyzer.scan, 24 cells"), ("turns 2", 4, "robot.turn"),
        (f"bare {n}", 2 * n, "robot.move alone"),
        (f"server {n}", 2 * n, "server.lua's step, up or down"),
        (f"nosave {n}", 2 * n, "the same, no save"),
        (f"nodetect {n}", 2 * n, "the same, no detect"),
        (f"nofacing {n}", 2 * n, "the same, no getFacing"),
        (f"bare {n}", 2 * n, "robot.move alone, again"),
    ]


def zones_open(prefix):
    """The zones open on the computer, asked of octerm itself ('Z', console/octerm_ext.lua):
    whoever holds the robot has its zone open there."""
    s = socket.create_connection((relay_host(), 7778), timeout=30)
    buf = b""

    def take(k):
        nonlocal buf
        while len(buf) < k:
            chunk = s.recv(65536)
            if not chunk:
                raise rlink.RobotError("the relay closed the connection")
            buf += chunk
        out, buf = buf[:k], buf[k:]
        return out

    try:
        assert take(1) == b"L"
        addrs = [take(take(1)[0]).decode() for _ in range(take(1)[0])]
        hits = [a for a in addrs if a.startswith(prefix)]
        if len(hits) != 1:
            raise rlink.RobotError(f"want one computer starting {prefix!r}; the relay has {addrs}")
        s.sendall(b"A" + bytes([len(hits[0])]) + hits[0].encode())
        if take(1) != b"Y":
            raise rlink.RobotError(f"the relay would not attach {hits[0]}")
        s.sendall(b"Z")
        while True:
            t = take(1)
            if t == b"z":
                return [take(take(1)[0]).decode() for _ in range(take(1)[0])]
            if t in (b"d", b"x"):
                take(struct.unpack(">H", take(2))[0])
            else:
                raise rlink.RobotError(f"unexpected frame {t!r} while asking for the zones")
    finally:
        s.close()


def run(prefix, n):
    """Every phase, one batch each, timed here; -> [(command, units, unit, ticks, wall, why)]."""
    held = zones_open(prefix)
    if rlink.ZONE.decode() in held:
        raise SystemExit(f"bench.py: {prefix} is held ({held}): its server zone is open. A robot "
                         "is benched only when it is lent, its crew or agent done with it.")
    r = rlink.Robot(prefix, log=None, program="bench", zone=ZONE)
    rows = []
    try:
        for cmd, units, unit in phases(n):
            t0 = time.perf_counter()
            st, v = r.batch([cmd])[0]
            wall = time.perf_counter() - t0
            if st != "ok":
                rows.append((cmd, units, unit, None, wall, v))
                print(f"  {cmd}: {st} {v}", flush=True)
                if "STRANDED" in v:
                    raise SystemExit(f"bench.py: {r.name} is {v} - urgent, tell the user")
                if cmd.split()[0] in ("bare", "server", "nosave", "nodetect", "nofacing"):
                    break                             # a move phase failed: no more moving
                continue
            ticks = int(v.split()[0])
            rows.append((cmd, units, unit, ticks, wall, ""))
            print(f"  {cmd}: {ticks} ticks, {wall:.2f} s", flush=True)
    finally:
        r.close()
    return r.name, rows


def report(name, rows):
    """The table, and what follows from it: the round trip, the tick's length, each call's and
    each step's ticks and seconds. -> its lines."""
    ok = [x for x in rows if x[3] is not None]
    rtt = statistics.median([x[4] for x in ok if x[0] == "ping"] or [0.0])
    sleeps = [(x[3], x[4] - rtt) for x in ok if x[0].startswith("sleep")]
    tick = statistics.median([w / t for t, w in sleeps if t]) if sleeps else None
    lines = [f"bench {time.strftime('%Y-%m-%d %H:%M:%S')} {name}: round trip {rtt:.2f} s"
             + (f", a tick {tick * 1000:.0f} ms ({1 / tick:.1f} TPS)" if tick else "")]
    lines.append(f"  {'phase':14s} {'ticks':>6s} {'wall s':>7s} {'ticks/u':>8s} {'s/u':>6s} "
                 f"{'TPS':>5s}  unit")
    for cmd, units, unit, ticks, wall, why in rows:
        if ticks is None:
            lines.append(f"  {cmd:14s} failed: {why}")
            continue
        w = max(0.0, wall - rtt)
        tps = f"{ticks / w:5.1f}" if ticks >= 20 and w > 0 else "    -"
        lines.append(f"  {cmd:14s} {ticks:6d} {wall:7.2f} {ticks / units:8.2f} "
                     f"{w / units:6.3f} {tps}  {unit}")
    per = {x[0].split()[0]: x[3] / x[1] for x in ok if x[0] != "ping"}
    if "bare" in per and "server" in per:
        lines.append(f"  a step up/down: {per['server']:.1f} ticks as server.lua makes it, "
                     f"{per['bare']:.1f} bare; a step sideways adds a getFacing "
                     f"({per.get('facing', 0):.1f}), a turn {per.get('turns', 0):.1f}")
        for k, what in (("nosave", "save"), ("nodetect", "detect"), ("nofacing", "getFacing")):
            if k in per:
                lines.append(f"    {what} costs {per['server'] - per[k]:.1f} ticks a step")
    return lines


def main(a):
    n = int(a[a.index("--n") + 1]) if "--n" in a else 10
    if "--plan" in a or not a or a[0].startswith("--"):
        print(__doc__)
        print("The phases, one batch each:")
        for cmd, units, unit in phases(n):
            print(f"  {cmd:14s} {units:4d} x {unit}")
        return
    name, rows = run(a[0], n)
    lines = report(name, rows)
    print("\n".join(lines))
    with open(OUT, "a", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv[1:])
