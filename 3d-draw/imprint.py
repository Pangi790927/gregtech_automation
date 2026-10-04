"""imprint.py - a finished building into the map for good: its plan's blocks, as built, into
data/built.txt (world coordinates), which zones.py lays over every chunk save - so no scout's map
from before the build can put the old terrain back - and into the chunk files now.

    python 3d-draw/imprint.py data/house.txt

The user, 2026-10-04, when the fisher's house was done: "I also want the part that is finished
(the fisher house) to be importalied in the map, not to be part of the proposal design". The plan
is what was built: the build checked every block it placed (analyze), and what a geolyzer found
wrong was put right (build-done.txt's `missing` and `stray`, built again or taken away). The air
the plan dug out goes in too, as air. Hardness is the registry's kind's, 1.0 where unknown; the
kind's `how` is `built`.

Run it once a building is finished; again after a change to it (it rewrites the building's lines,
keyed by the plan file's name).
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import zones                                                   # noqa: E402
from placing import expected_meta                              # noqa: E402


def main():
    plan_path = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else
                                os.path.join(zones.DATA, "house.txt"))
    tag = os.path.basename(plan_path)
    ax, ay, az = zones.anchor()
    lines = []
    for line in open(plan_path):
        p = line.split()
        if not p or p[0] != "b":
            continue
        x, y, z = (int(v) for v in p[1:4])
        name, meta = p[4], int(p[5])
        if len(p) >= 8:
            # the metadata the block has in the game: a plan keeps a stair's facing and a top
            # slab apart from its meta (placing.expected_meta), and imprinted as the plan had
            # them, stairs stood all one way and top slabs as bottom ones (2026-10-04)
            meta = expected_meta((name, meta, int(p[6]), p[7]))
        lines.append(f"{x + ax} {y + ay} {z + az} {name} {meta} 1.0 built {tag}")
    keep = []
    if os.path.exists(zones.BUILT):
        keep = [l.rstrip("\n") for l in open(zones.BUILT)
                if not l.startswith("#") and not l.rstrip().endswith(" " + tag)]
    with open(zones.BUILT, "w", newline="\n") as f:
        f.write("# built and finished (imprint.py): x y z name meta hardness how plan - world\n")
        for l in keep + lines:
            f.write(l + "\n")
    print(f"imprint: {len(lines)} cells of {tag} into {zones.BUILT}")
    zones.apply_fixed()


if __name__ == "__main__":
    main()
