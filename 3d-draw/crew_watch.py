"""crew_watch.py - the live crew's alarms, one line each, for a watcher to act on at once.

    python 3d-draw/crew_watch.py [--plan data/harbour.txt]

The audit of 2026-10-04 found stalls caught only by 25-minute progress timers (a run placing 7
blocks in 25 minutes, a sector that kept three of five builders at home). So, read every 30 s:
  - the crew's loop frozen: data/crew-stacks.txt not rewritten for 2 minutes;
  - a builder silent: one batch unanswered for 2 minutes (the user: a robot gone quiet is
    urgent - Cortana's item despawned while nobody looked);
  - no block placed for 10 minutes while the crew runs;
  - every 10 minutes, the working share of the last 30 (probe.py) under 60% while more than a
    sector's work is left: a fault of the build process, not its end (the user, 2026-10-04:
    "if 1/5 of the team works, maybe there is something wrong with the build process").
Each alarm is said once until it clears.
"""
import os, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import probe                                                              # noqa: E402

STACKS = os.path.join(HERE, "data", "crew-stacks.txt")
DONE = os.path.join(HERE, "data", "build-done.txt")
SILENT, NO_PLACE, SHARE, EVERY = 120, 600, 0.60, 600


def pending(plan):
    """Blocks of the plan left to build, as the crew sees them (a fresh site: a few seconds)."""
    import buildsite
    return len(buildsite.Site(plan).pending())


def main(a):
    plan = os.path.join(HERE, a[a.index("--plan") + 1]) if "--plan" in a else \
        os.path.join(HERE, "data", "harbour.txt")
    told, placed, since, share_at = set(), -1, time.time(), time.time()

    def say(key, text):
        if key not in told:
            print(text, flush=True)
            told.add(key)

    while True:
        time.sleep(30)
        if not os.path.exists(STACKS):
            continue
        age = time.time() - os.path.getmtime(STACKS)
        if age > SILENT:
            say("frozen", f"crew-stacks not rewritten for {age:.0f} s: the crew's loop frozen "
                "or ended")
            continue
        told.discard("frozen")
        n = sum(1 for line in open(DONE) if line.startswith("placed"))
        if n != placed:
            placed, since = n, time.time()
            told.discard("noplace")
        elif time.time() - since > NO_PLACE:
            say("noplace", f"no block placed for {(time.time() - since) / 60:.0f} minutes "
                f"({n} placed in all)")
        for line in open(STACKS, encoding="utf-8"):
            d = re.match(r"--- (\S+) \(done\) at (.*)", line)
            if d:
                # a builder's coroutine over while the crew runs: it ended or stopped (STUCK,
                # an error), or the crew is finishing - its last words are in the crew output
                say("done " + d.group(1), f"{d.group(1)} ENDED, at {d.group(2).strip()}: no "
                    "longer driven (see the crew output and actions.log 'ended')")
            m = re.match(r"(\S+): (\d+) batches answered; (.*)", line)
            if not m or m.group(1) == "mini":
                continue
            w = re.search(r"waiting (\d+) s", m.group(3))
            key = "silent " + m.group(1)
            if w and int(w.group(1)) > SILENT:
                say(key, f"{m.group(1)} SILENT: one batch unanswered for {w.group(1)} s: "
                    f"{m.group(3)[:100]}")
            else:
                told.discard(key)
        if time.time() - share_at > EVERY:
            share_at = time.time()
            recs = [r for r in probe.load() if r["t"] >= time.time() - 1800]
            if recs:
                u, by = probe.utilisation(recs)
                left = pending(plan)
                if u < SHARE and left > 70:
                    print(f"working share {100 * u:.0f}% over the last 30 min with {left} "
                          f"blocks left: " + ", ".join(f"{k} {v / 60:.0f} min" for k, v in
                                                       sorted(by.items(),
                                                              key=lambda kv: -kv[1])[:5]),
                          flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
