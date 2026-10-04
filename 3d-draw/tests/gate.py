"""gate.py - the simulation every change to the builders passes before it drives the real robots.

    python 3d-draw/tests/gate.py [--plan data/harbour.txt] [--seeds 1,2,3]
                                 [--map data/map-village.txt] [--robots N] [--dig]
                                 [--me data/me-after-craft.txt]

The user's rule (2026-10-04, after builders broke three of their own, Cortana lost): robot logic
runs in sim.py first. The audit of that day found it kept by hand, and changes went live
untried; so this runs the whole plan from the live record (data/build-done.txt, copied) on each
seed and fails - exit 1 - on any of:
  - a robot broken, or a swing at a robot;
  - ground dug outside the plan and outside the user's dig-ok boxes;
  - a builder STUCK, or ended on an error;
  - fewer blocks placed than the last pass from the same record (a regression);
  - a working share under SHARE while the bulk of a plan is left (more than BULK blocks): near
    a plan's end the work left is too little to share among five, and idling is expected.
On a pass it writes STAMP: the hash of builders.py, buildsite.py and placing.py, which
builders.py checks before it runs the live crew.
"""
import hashlib, os, re, shutil, subprocess, sys, tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
HERE = os.path.dirname(TESTS)
STAMP = os.path.join(TESTS, "gate-stamp.txt")
CODE = ("builders.py", "buildsite.py", "placing.py")
SHARE, BULK = 0.40, 350


def code_hash():
    """One hash over the code the live crew runs on."""
    h = hashlib.sha256()
    for f in CODE:
        h.update(open(os.path.join(HERE, f), "rb").read())
    return h.hexdigest()


def stamp_ok():
    """Whether the gate passed on the code as it is now (builders.py asks before a live run)."""
    if not os.path.exists(STAMP):
        return False
    return open(STAMP).readline().split()[-1] == code_hash()


def last_placed():
    """{(run key, record length, seed): placed} from the passes before, every plan's."""
    out = {}
    if os.path.exists(STAMP):
        for line in open(STAMP).readlines()[1:]:
            w = line.split()
            if len(w) == 5 and w[0] == "placed":
                out[(w[1], int(w[2]), int(w[3]))] = int(w[4])
    return out


def run(seed, plan, done, tmp, extra=()):
    """sim.py on one seed (`extra`: the live run's --map, --robots, --dig); -> (its output,
    the figures read from it)."""
    out = subprocess.run([sys.executable, os.path.join(HERE, "sim.py"), "--seed", str(seed),
                          "--plan", plan, "--done", done,
                          "--actions", os.path.join(tmp, f"actions-{seed}.log"), *extra],
                         capture_output=True, text=True, cwd=HERE).stdout
    fig = {}
    m = re.search(r"robots broken (\d+), swings at robots (\d+), ground dug outside the plan "
                  r"\d+ \((\d+) outside", out)
    if m:
        fig["broken"], fig["swings"], fig["dug"] = map(int, m.groups())
    m = re.search(r"^crew: (\d+) placed; (\d+) left; stuck: (.*)$", out, re.M)
    if m:
        fig["placed"], fig["left"], fig["stuck"] = int(m.group(1)), int(m.group(2)), m.group(3)
    m = re.search(r"^crew: .*; (\d+) blocks to build", out, re.M)
    if m:
        fig["todo"] = int(m.group(1))
    m = re.search(r"utilisation (\d+)% working", out)
    if m:
        fig["share"] = int(m.group(1)) / 100
    fig["ended"] = len(re.findall(r"ENDED on|STUCK at", out))
    m = re.search(r"^sim: dry moves into water (\d+)", out, re.M)
    fig["dry"] = int(m.group(1)) if m else None
    return out, fig


def main(a):
    plan = os.path.join(HERE, a[a.index("--plan") + 1]) if "--plan" in a else \
        os.path.join(HERE, "data", "harbour.txt")
    seeds = [int(s) for s in (a[a.index("--seeds") + 1] if "--seeds" in a else "1,2,3")
             .split(",")]
    extra = []
    if "--map" in a:
        extra += ["--map", os.path.join(HERE, a[a.index("--map") + 1])]
    if "--robots" in a:
        extra += ["--robots", a[a.index("--robots") + 1]]
    if "--dig" in a:
        extra.append("--dig")
    if "--me" in a:                       # the mini ME's stock to start from (after crafting)
        extra += ["--me", os.path.join(HERE, a[a.index("--me") + 1])]
    # the run's own key in the stamp: a regression is counted against the same plan and options
    key = os.path.basename(plan) + ("+dig" if "--dig" in a else "") \
        + (f"+r{a[a.index('--robots') + 1]}" if "--robots" in a else "")
    tmp = tempfile.mkdtemp(prefix="gate-")
    done = os.path.join(tmp, "build-done.txt")
    shutil.copy(os.path.join(HERE, "data", "build-done.txt"), done)
    n_rec = sum(1 for _ in open(done))
    before, faults, placed = last_placed(), [], {}
    # the seeds at once, each sim its own process: the village's took 12 minutes a seed
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(len(seeds)) as pool:
        results = list(pool.map(lambda sd: run(sd, plan, done, tmp, extra), seeds))
    for seed, (out, fig) in zip(seeds, results):
        open(os.path.join(tmp, f"sim-{seed}.out"), "w").write(out)
        if "placed" not in fig or "broken" not in fig:
            faults.append(f"seed {seed}: the sim did not finish (see {tmp})")
            continue
        placed[seed] = fig["placed"]
        print(f"seed {seed}: {fig['placed']} placed of {fig.get('todo', '?')}, {fig['left']} "
              f"left; broken {fig['broken']}, swings {fig['swings']}, dug outside {fig['dug']}, "
              f"stuck {fig['stuck']}; working {100 * fig.get('share', 0):.0f}%", flush=True)
        if fig["broken"] or fig["swings"]:
            faults.append(f"seed {seed}: a robot broken or swung at")
        if fig["dug"]:
            faults.append(f"seed {seed}: ground dug outside the plan")
        if fig["dry"] is None or fig["dry"]:
            # a `dry` move skips the robot's detect: one into water destroys a source block
            # for good (the user's leave, 2026-10-04: dry moves only above the river's level)
            faults.append(f"seed {seed}: DRY MOVES INTO WATER: {fig['dry']} - the wet rule "
                          "broken; never run this live")
        if fig["stuck"] != "none" or fig["ended"]:
            faults.append(f"seed {seed}: a builder stuck or ended: {fig['stuck']}")
        if fig.get("todo", 0) > BULK and fig.get("share", 0) < SHARE:
            faults.append(f"seed {seed}: working share {100 * fig['share']:.0f}% under "
                          f"{100 * SHARE:.0f}% with {fig['todo']} blocks to build")
        was = before.get((key, n_rec, seed))
        if was is not None and fig["placed"] < was:
            faults.append(f"seed {seed}: {fig['placed']} placed, {was} last time from this record")
    if faults:
        print("GATE FAILED:\n  " + "\n  ".join(faults) + f"\n  (outputs in {tmp})")
        sys.exit(1)
    for seed, n in placed.items():
        before[(key, n_rec, seed)] = n
    with open(STAMP, "w", newline="\n") as f:
        f.write(f"passed {code_hash()}\n")
        for (k, r, seed), n in sorted(before.items()):
            f.write(f"placed {k} {r} {seed} {n}\n")
    print(f"gate passed; stamp written ({STAMP})")


if __name__ == "__main__":
    main(sys.argv[1:])
