"""keep_chunks.py - keeps the chunk store up with maps that are still being worked on: whenever
one of them changes on disk, it is merged into data/chunks/ (zones.py save, which also writes the
overview the viewer's map of chunks draws). The user, 2026-10-04, during the 15x15 survey: "I
also want the map updated, right now I don't see the newly scanned zones".

    python 3d-draw/keep_chunks.py data/map-cairol-big.txt data/map-tom-big.txt [--every 60]

It reads the maps only; the scouts go on writing them (their saves replace the file whole, so a
read never sees half of one).
"""
import os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import zones                                                  # noqa: E402


def main():
    a = sys.argv[1:]
    every = 60
    if "--every" in a:
        i = a.index("--every")
        every = int(a[i + 1])
        del a[i:i + 2]
    paths = [os.path.abspath(p) for p in a]
    seen = {}
    while True:
        for p in paths:
            try:
                m = os.path.getmtime(p)
            except OSError:
                continue
            if seen.get(p) != m:
                seen[p] = m
                t = time.time()
                zones.save(p)
                print(f"{time.strftime('%H:%M:%S')} {os.path.basename(p)} into the chunks "
                      f"({time.time() - t:.0f} s)", flush=True)
        time.sleep(every)


if __name__ == "__main__":
    main()
