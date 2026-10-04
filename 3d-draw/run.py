"""run.py <program> [address start] - runs one of 3d-draw's robot programs on a robot on the relay.

    python 3d-draw/run.py mapper            robot/mapper.lua, on the only computer on the relay
    python 3d-draw/run.py contour 016db072  on the one whose address starts so
    python 3d-draw/run.py mapper 016db072 --extend
                                            adds the columns painted in the simulator
                                            (data/extend.txt) to the robot's map
    python 3d-draw/run.py exec 016db072 --job data/job.txt
                                            a job the PC planned (design/clear.py), handed to
                                            robot/exec.lua as JOB; the live log starts with
                                            data/map.txt, so the view shows the robot on it
    python 3d-draw/run.py exec 016db072 --job data/job.txt --start -17,9,-13
                                            the same, for a robot left at x,y,z, not at home

The program (robot/<program>.lua) is sent as a one-off zone, the way console/install_octerm.py
opens one; it gets the zone as `...` and sends its lines with z.send. Every line is printed and
written to data/live.log, which the simulator's scenes/draw3d follows; the log is started anew
for each run, so the view starts over. data/ is gitignored: what the robot reads is the user's
world (CLAUDE.md, rule 4).

The relay is reached on 127.0.0.1:7778, or at `relay` in the repo's config.ini.
"""
import os, socket, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def relay_host():
    """The relay's address: `relay` in config.ini, else this PC (console/connector.h does the
    same)."""
    try:
        for line in open(os.path.join(REPO, "config.ini"), encoding="utf-8"):
            key, _, value = line.partition("=")
            if key.strip() == "relay" and not line.lstrip().startswith("#"):
                return value.strip()
    except OSError:
        pass
    return "127.0.0.1"


def fnv64(b):
    """The zone cache's hash (console/protocol.h, payload_hash)."""
    h = 0xcbf29ce484222325
    for c in b:
        h = ((h ^ c) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h


def map_events():
    """data/map.txt as the live view's events (box, pal, blk, guess), the way the view itself
    reads a finished map: a job's log starts with them, so its moves are drawn on the map."""
    lines = open(os.path.join(HERE, "data", "map.txt")).read().splitlines()
    nums = [int(v) for v in lines[1].split() if v.lstrip("-").isdigit()]
    x0, y0, z0 = nums[0], nums[2], nums[4]
    out = ["box " + " ".join(map(str, nums))]
    guessed = {}
    for line in lines:
        p = line.split(" ", 2)
        if p[0] == "palette":
            out.append("pal " + line.split(" ", 1)[1])
        elif p[0] == "guessed":
            guessed[int(p[1])] = [r.split(",") for r in p[2].split(";")]
    for line in lines:
        p = line.split(" ", 2)
        if p[0] != "layer":
            continue
        y = int(p[1])
        for zi, row in enumerate(p[2].split(";")):
            for xi, v in enumerate(row.split(",")):
                if int(v) > 0:
                    g = y in guessed and guessed[y][zi][xi] == "1"
                    out.append(f"{'guess' if g else 'blk'} {x0 + xi} {y} {z0 + zi} {v}")
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    job = None
    if "--job" in sys.argv:
        i = sys.argv.index("--job")
        job = open(sys.argv[i + 1], encoding="utf-8").read()
        del sys.argv[i:i + 2]
    start = None
    if "--start" in sys.argv:
        i = sys.argv.index("--start")
        start = [int(v) for v in sys.argv[i + 1].split(",")]
        del sys.argv[i:i + 2]
    args = [a for a in sys.argv[1:] if a != "--extend"]
    extend = "--extend" in sys.argv
    program = args[0]
    prefix = args[1] if len(args) > 1 else ""
    code = open(os.path.join(HERE, "robot", program + ".lua"), "rb").read()
    if extend:
        # The painted columns go to the robot first, with ocscp; the program is told to use them.
        painted = os.path.join(HERE, "data", "extend.txt")
        if not os.path.exists(painted):
            sys.exit("run: --extend, but nothing is painted (no data/extend.txt)")
        put = [os.path.join(REPO, "console", "ocscp", "ocscp.exe"), "put", painted,
               "/home/3d-draw/extend.txt"] + (["--computer", prefix] if prefix else [])
        if subprocess.call(put) != 0:
            sys.exit("run: could not copy extend.txt to the robot")
        code = b"EXTEND = true\n" + code
    if job is not None:
        assert "]==]" not in job
        code = b"JOB = [==[\n" + job.encode() + b"]==]\n" + code
    if start is not None:
        code = ("START = {%d, %d, %d}\n" % tuple(start)).encode() + code
    os.makedirs(os.path.join(HERE, "data"), exist_ok=True)
    log = open(os.path.join(HERE, "data", "live.log"), "w", encoding="utf-8", newline="\n")
    if job is not None:
        log.write("\n".join(map_events()) + "\n")
        log.flush()

    s = socket.create_connection((relay_host(), 7778), timeout=3600)
    buf = b""

    def take(n):
        nonlocal buf
        while len(buf) < n:
            chunk = s.recv(65536)
            if not chunk:
                raise EOFError("the relay closed the connection")
            buf += chunk
        out, buf = buf[:n], buf[n:]
        return out

    assert take(1) == b"L"
    addrs = [take(take(1)[0]).decode() for _ in range(take(1)[0])]
    hits = [a for a in addrs if a.startswith(prefix)]
    if len(hits) != 1:
        sys.exit(f"run: want one computer starting {prefix!r}; the relay has {addrs}")
    s.sendall(b"A" + bytes([len(hits[0])]) + hits[0].encode())
    assert take(1) == b"Y"
    name = program.encode()
    h = fnv64(code).encode()
    s.sendall(b"O" + bytes([len(name)]) + name + bytes([len(h)]) + h + b"\1"
              + struct.pack(">I", len(code)) + code)
    try:
        while True:
            t = take(1)
            if t == b"P":
                status = take(1)[0]
                take(1)
                msg = take(struct.unpack(">H", take(2))[0]).decode()
                if status != 0:
                    sys.exit(f"run: the zone did not open: {msg}")
                continue
            text = take(struct.unpack(">H", take(2))[0]).decode("utf-8", "replace")
            if t == b"d":
                print(text, flush=True)
                log.write(text + "\n")
                log.flush()
            elif t == b"x":
                print("-- zone ended:", text, flush=True)
                log.write("zone ended: " + text + "\n")
                break
    except (OSError, EOFError) as e:
        print("-- stopped:", e, flush=True)
    log.close()
    s.close()


if __name__ == "__main__":
    main()
