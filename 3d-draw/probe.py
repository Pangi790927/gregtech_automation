"""probe.py - how efficiently the builders work, read from data/actions.log (builders.py writes it).

    python 3d-draw/probe.py [--log data/actions.log] [--all]    the whole log, every flag
    python 3d-draw/probe.py --random [--minutes 20]             a random robot, a random window

Two standing asks of the user, 2026-10-04: "plz also add random probing for efficiency, if the
robots do things that are 400% ineficient, maybe come up with a strategy to fix it (or if they
they 4x-5x the ammount of time they should take)"; and "the team's idle ammount should be
reasoned about, if 1/5 of the team works, maybe there is something wrong with the build
process". So, against what each thing should cost, anything at 4x or more is flagged:
  - a go's moves against its length as the crow flies (Manhattan);
  - seconds a placed block against the crew's median;
  - a load's seconds an item against the crew's median;
  - a look-over's cells read against the cells round the blocks it was for;
  - waiting (no sector, a side of the interface, a robot in the way) against working.
And the crew's utilisation: the share of builder-time spent working (placing, helpers, tilling,
clearing, breaking in, with the go to the stand each needs) - under 60% while more than a
sector's work is left is a fault of the build process, not the end of the build.
"""
import os, random, sys
from statistics import median

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "data", "actions.log")
WORK = ("place", "helper", "till", "clear", "breakin")
WAITS = ("idle", "side", "robot")
X = 4.0                                   # how many times over what it should cost: flagged


def load(path=LOG):
    """The log's lines as dicts: t (when it ended), robot, what, cell, secs, batches, moves,
    way (a go's Manhattan length, else None), depth, note."""
    out = []
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8", errors="replace"):
        w = line.split()
        if len(w) < 11:
            continue
        try:
            out.append({"hms": w[0], "t": float(w[1]), "robot": w[2], "what": w[3],
                        "cell": w[4], "secs": float(w[5]), "batches": int(w[6]),
                        "moves": int(w[7]), "way": None if w[8] == "-" else int(w[8]),
                        "depth": int(w[9]), "note": w[10]})
        except ValueError:
            continue
    return out


def spent(recs):
    """Builder-seconds by kind, from the top-level actions; the waits inside one (a side of the
    interface while loading, a robot in the way while placing) taken out of it and counted as
    waits. Every robot's lines come in order, so the deeper lines before a top-level one are its
    own."""
    by, inner = {}, {}
    for r in recs:
        if r["depth"] > 0:
            if r["what"] in WAITS:
                inner[r["robot"]] = inner.get(r["robot"], 0.0) + r["secs"]
            continue
        k = r["what"]
        k = "work" if k in WORK else k
        w = inner.pop(r["robot"], 0.0)
        if k not in WAITS:
            by[k] = by.get(k, 0.0) + r["secs"] - w
            by["robot/side (inside)"] = by.get("robot/side (inside)", 0.0) + w
        else:
            by[k] = by.get(k, 0.0) + r["secs"]
    return by


def utilisation(recs):
    by = spent(recs)
    total = sum(by.values())
    return (by.get("work", 0.0) / total if total else 0.0), by


def flags(recs, base=None):
    """What in recs is X times or more over what it should cost; `base` (the whole log) gives
    the crew's medians."""
    base = base or recs
    out = []
    for r in recs:
        if r["what"] == "go" and r["way"] and r["moves"] >= 16 and r["moves"] >= X * r["way"]:
            out.append(f"{r['hms']} {r['robot']} go to {r['cell']}: {r['moves']} moves for "
                       f"{r['way']} as the crow flies ({r['moves'] / r['way']:.1f}x), "
                       f"{r['secs']:.0f} s")
        if r["what"] == "look_over" and "need=" in r["note"]:
            kv = dict(p.split("=") for p in r["note"].split(","))
            cells, need = int(kv["cells"]), int(kv["need"])
            if need and cells >= X * need:
                out.append(f"{r['hms']} {r['robot']} look-over at {r['cell']}: {cells} cells "
                           f"read for {need} needed ({cells / need:.1f}x)")

    def per_item(r):
        kv = dict(p.split("=") for p in r["note"].split(",") if "=" in p)
        n = int(kv.get("items", 0))
        return r["secs"] / n if n else None
    rates = [x for x in (per_item(r) for r in base if r["what"] == "load") if x]
    if rates:
        m = median(rates)
        for r in recs:
            if r["what"] == "load":
                x = per_item(r)
                if x and r["secs"] >= 30 and x >= X * m:
                    out.append(f"{r['hms']} {r['robot']} load: {r['secs']:.0f} s for "
                               f"{r['note']} ({x:.1f} s an item, the crew's median {m:.1f})")

    def per_block(rs):
        out_ = {}
        for name in {r["robot"] for r in rs}:
            mine = [r for r in rs if r["robot"] == name and r["depth"] == 0]
            secs = sum(r["secs"] for r in mine if r["what"] not in ("idle",))
            n = sum(1 for r in rs if r["robot"] == name and r["what"] == "place"
                    and r["note"] == "True")
            out_[name] = (secs, n)
        return out_
    whole = [s / n for s, n in per_block(base).values() if n]
    if whole:
        m = median(whole)
        for name, (secs, n) in per_block(recs).items():
            if n and secs / n >= X * m:
                out.append(f"{name}: {secs / n:.0f} s a placed block ({n} placed), the crew's "
                           f"median {m:.0f} s")
            elif not n and secs >= X * m and secs >= 300:
                out.append(f"{name}: {secs:.0f} s busy, nothing placed (the crew's median "
                           f"{m:.0f} s a block)")
    by = spent(recs)
    waits = sum(by.get(k, 0.0) for k in WAITS) + by.get("robot/side (inside)", 0.0)
    if by.get("work", 0.0) and waits >= X * by["work"]:
        out.append(f"waiting {waits:.0f} s against {by['work']:.0f} s working "
                   f"({waits / by['work']:.1f}x)")
    return out


def report(recs, title="the whole log"):
    if not recs:
        print("probe: no actions logged")
        return
    u, by = utilisation(recs)
    t0, t1 = min(r["t"] - r["secs"] for r in recs), max(r["t"] for r in recs)
    names = sorted({r["robot"] for r in recs})
    print(f"probe ({title}, {(t1 - t0) / 60:.0f} min, {len(names)} builders): utilisation "
          f"{100 * u:.0f}% working; " + ", ".join(f"{k} {v / 60:.0f} min" for k, v in
                                                sorted(by.items(), key=lambda kv: -kv[1])))
    for name in names:
        ur, _ = utilisation([r for r in recs if r["robot"] == name])
        print(f"  {name}: {100 * ur:.0f}% working")
    fl = flags(recs)
    print(f"  {len(fl)} at {X:.0f}x or more" + (":" if fl else ""))
    for f in fl[:15]:
        print("   ", f)


def main(a):
    path = a[a.index("--log") + 1] if "--log" in a else LOG
    recs = load(path)
    if "--random" not in a:
        report(recs)
        return
    if not recs:
        print("probe: no actions logged")
        return
    minutes = float(a[a.index("--minutes") + 1]) if "--minutes" in a else 20
    end = max(r["t"] for r in recs)
    recent = [r for r in recs if r["t"] >= end - 7200]
    name = random.choice(sorted({r["robot"] for r in recent}))
    start = random.uniform(min(r["t"] for r in recent), max(end - minutes * 60,
                                                            min(r["t"] for r in recent)))
    win = [r for r in recent if start <= r["t"] <= start + minutes * 60]
    mine = [r for r in win if r["robot"] == name]
    crew = [r for r in recs if r["t"] >= end - 1800]
    u, _ = utilisation(crew)
    fl = flags(mine, recs) + [f"crew: {f}" for f in flags(win, recs) if "waiting" in f]
    hms = mine[0]["hms"] if mine else "-"
    print(f"probe: {name} from {hms}, {minutes:.0f} min: {len(mine)} actions; the crew's "
          f"last 30 min {100 * u:.0f}% working" + ("" if fl else "; nothing at 4x"), flush=True)
    for f in fl[:8]:
        print("  FLAG", f, flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
