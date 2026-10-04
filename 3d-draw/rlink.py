"""rlink.py - the PC's side of a robot running robot/server.lua: the robot as a thin interface to
the world, the PC holding the map and the plans (3d-draw/docs/robots.md, "The robot
server").

    python 3d-draw/rlink.py serve 016db072 [--port 7790]
        opens the server on that robot (through the relay) and holds it open, taking commands on
        127.0.0.1:<port>; every step it reports goes to data/live.log for the simulator's view
    python 3d-draw/rlink.py do "move n" "swing d" ... [--port 7790]
        sends one batch to the robot being served, and prints a line for each command:
        `ok <values>`, `err <why>`, or `skip` (an earlier command in the batch failed)

From Python: `Robot("016db072")` connects directly; `.batch([...])` sends a batch and returns the
replies, `.run("move n")` one command and its values (raising RobotError if it failed).

The commands, and what the robot keeps to itself for safety, are in robot/server.lua.
"""
import asyncio, os, socket, struct, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from run import relay_host, fnv64          # noqa: E402  (3d-draw/run.py)

LOG = os.path.join(HERE, "data", "live.log")
ZONE = b"rserver"
STEP = {"n": (0, 0, -1), "s": (0, 0, 1), "e": (1, 0, 0), "w": (-1, 0, 0), "u": (0, 1, 0),
        "d": (0, -1, 0)}
FACING = {"n": "north", "s": "south", "e": "east", "w": "west"}


class RobotError(Exception):
    pass


QUIET = 120                       # seconds without a frame before a robot is given up on


class _View:
    """What a robot link tells the simulator's view (data/live.log), blocking or not."""

    def _event(self, line):
        if self.log:
            with open(self.log, "a", encoding="utf-8", newline="\n") as f:
                f.write(line + "\n")

    def _seen(self, cmd, values):
        """Keeps the robot's position, and tells the view what changed."""
        word, *args = cmd.split()
        if word in ("move", "back", "hello", "pos") and len(values) >= 4:
            self.pos = [int(v) for v in values[:3]]
            self.facing = values[3]
            energy = values[4] if len(values) > 4 else "0"
            if len(values) > 4 and values[4].isdigit():
                self.energy = int(values[4])            # the builders' energy checks use it
            self._event(f"at {self.pos[0]} {self.pos[1]} {self.pos[2]} "
                        f"{FACING.get(self.facing, self.facing)} {energy} {self.name}")
        elif word == "swing" and args:
            d = STEP[args[0]]
            x, y, z = self.pos[0] + d[0], self.pos[1] + d[1], self.pos[2] + d[2]
            self._event(f"blk {x} {y} {z} 0")
            self._event(f"broke {x} {y} {z}")

    def status(self, state, short, long):
        """What the robot is at, for the viewer's panel of robots (the user, 2026-10-04: "I want
        to see their status, their short time goal and their long time goal"): what it is doing
        now, its next few targets, and how far it is in its whole task."""
        self._event(f"status {getattr(self, 'name', '?')} {state} | {short} | {long}")


class Robot(_View):
    """A robot running robot/server.lua, reached through the relay."""

    def __init__(self, prefix, log=LOG, program="server", zone=ZONE):
        """program: robot/<program>.lua, opened as the zone `zone` - server.lua on a robot,
        me_server.lua (zone b"meserver") on the mini ME's computer."""
        self.log, self.zone = log, zone
        self.buf, self.text, self.next_id = b"", "", 1
        self.s = socket.create_connection((relay_host(), 7778), timeout=30)
        assert self._take(1) == b"L"
        addrs = [self._take(self._take(1)[0]).decode() for _ in range(self._take(1)[0])]
        hits = [a for a in addrs if a.startswith(prefix)]
        if len(hits) != 1:
            raise RobotError(f"want one computer starting {prefix!r}; the relay has {addrs}")
        self.address = hits[0]
        self.s.sendall(b"A" + bytes([len(hits[0])]) + hits[0].encode())
        assert self._take(1) == b"Y"
        self.s.settimeout(None)
        code = open(os.path.join(HERE, "robot", program + ".lua"), "rb").read()
        if not self._open(code):
            # A server left open by a connection that did not close it: end it, open again.
            self.s.sendall(b"T" + bytes([len(zone)]) + zone)
            if not self._open(code):
                raise RobotError("could not open the server zone")
        line = self._line()
        if not line.startswith("ready"):
            raise RobotError("the server said " + line)
        self.pos, self.facing = None, None
        if len(line.split()) < 6:
            return                                            # not a robot: no position
        x, y, z, facing, energy = line.split()[1:6]
        self.name = line.split()[6] if len(line.split()) > 6 else self.address[:8]
        self.pos, self.facing = [int(x), int(y), int(z)], facing
        self._event(f"at {x} {y} {z} {FACING.get(facing, facing)} {energy} {self.name}")

    # ---- the frames ---------------------------------------------------------------------------

    def _take(self, n):
        while len(self.buf) < n:
            try:
                chunk = self.s.recv(65536)
            except socket.timeout:
                raise RobotError(f"{self.address[:8]} gave no answer for {QUIET} s")
            if not chunk:
                raise RobotError("the relay closed the connection")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _open(self, code):
        h = fnv64(code).encode()
        self.s.sendall(b"O" + bytes([len(self.zone)]) + self.zone + bytes([len(h)]) + h + b"\1"
                       + struct.pack(">I", len(code)) + code)
        while True:
            t = self._take(1)
            if t == b"P":
                status = self._take(1)[0]
                self._take(1)
                msg = self._take(struct.unpack(">H", self._take(2))[0]).decode()
                if status == 0:
                    return True
                if "open already" in msg:
                    return False
                raise RobotError("the server zone did not open: " + msg)
            if t == b"z":
                for _ in range(self._take(1)[0]):
                    self._take(self._take(1)[0])
            elif t in (b"d", b"x"):
                # The zone starts at once and can speak before the 'P' that says it opened: its
                # first line (ready) came first on 2026-10-04, and dropping it hung the PC.
                data = self._take(struct.unpack(">H", self._take(2))[0])
                if t == b"d":
                    self.text += data.decode("utf-8", "replace")
                else:
                    raise RobotError("the server ended: " + data.decode("utf-8", "replace"))

    def _line(self):
        """The next line the server sends."""
        while "\n" not in self.text:
            t = self._take(1)
            n = struct.unpack(">H", self._take(2))[0]
            data = self._take(n).decode("utf-8", "replace")
            if t == b"x":
                raise RobotError("the server ended: " + data)
            if t == b"d":
                self.text += data
        line, self.text = self.text.split("\n", 1)
        return line

    # ---- the commands -------------------------------------------------------------------------

    def batch(self, cmds):
        """Sends commands as one batch; returns (status, values) for each: "ok", "err", "skip"."""
        ids = []
        lines = []
        for c in cmds:
            ids.append(str(self.next_id))
            lines.append(f"{self.next_id} {c}")
            self.next_id += 1
        data = ("\n".join(lines) + "\n").encode()
        # A robot that never answers held a builder, and the side of the interface it stood at,
        # for good (ASIMO, 2026-10-04): a reply is waited for QUIET s, a charge for as long.
        self.s.settimeout(None if any(c.split()[0] == "charge" for c in cmds) else QUIET)
        self.s.sendall(b"d" + struct.pack(">H", len(data)) + data)
        replies = {}
        while len(replies) < len(ids):
            line = self._line()
            rid, _, rest = line.partition(" ")
            if rid in ids:
                status, _, values = rest.partition(" ")
                replies[rid] = (status, values)
            else:
                print("robot:", line, flush=True)
        out = []
        for c, i in zip(cmds, ids):
            status, values = replies[i]
            if status == "ok":
                self._seen(c, values.split())
            out.append((status, values))
        return out

    def run(self, cmd):
        """One command; its values, or RobotError with why it failed."""
        status, values = self.batch([cmd])[0]
        if status != "ok":
            raise RobotError(f"{cmd}: {status} {values}")
        return values

    def close(self):
        try:
            self.batch(["bye"])
        finally:
            self.s.close()


class AsyncRobot(_View):
    """Robot for asyncio (3d-draw/builders.py drives its builders from one event loop): the same
    frames and commands, and a deadline on every batch. A robot that never answered held a
    builder thread, and the interface side it stood at, for good (ASIMO, 2026-10-04); here a
    batch with no reply in time closes the link and raises RobotError, and the caller opens it
    again. One link may be used by several coroutines (the crew shares the mini ME's): a batch
    holds it until its replies are in."""

    @classmethod
    async def open(cls, prefix, log=LOG, program="server", zone=ZONE):
        self = cls()
        self.log, self.zone, self.prefix = log, zone, prefix
        self.text, self.next_id, self.name = "", 1, prefix[:8]
        self.address = prefix
        self.lock = asyncio.Lock()
        self.reader, self.writer = await asyncio.wait_for(
            asyncio.open_connection(relay_host(), 7778), 30)
        try:
            await asyncio.wait_for(self._attach(prefix, program), QUIET)
        except asyncio.TimeoutError:
            self.writer.close()
            raise RobotError(f"{prefix}: no answer while its server opened")
        except BaseException:
            self.writer.close()
            raise
        return self

    async def _attach(self, prefix, program):
        if await self._take(1) != b"L":
            raise RobotError("the relay did not list its computers")
        addrs = []
        for _ in range((await self._take(1))[0]):
            addrs.append((await self._take((await self._take(1))[0])).decode())
        hits = [a for a in addrs if a.startswith(prefix)]
        if len(hits) != 1:
            raise RobotError(f"want one computer starting {prefix!r}; the relay has {addrs}")
        self.address = hits[0]
        self.writer.write(b"A" + bytes([len(hits[0])]) + hits[0].encode())
        if await self._take(1) != b"Y":
            raise RobotError(f"the relay would not attach {hits[0]}")
        code = open(os.path.join(HERE, "robot", program + ".lua"), "rb").read()
        if not await self._open(code):
            # A server left open by a connection that did not close it: end it, open again.
            self.writer.write(b"T" + bytes([len(self.zone)]) + self.zone)
            if not await self._open(code):
                raise RobotError("could not open the server zone")
        line = await self._line()
        if not line.startswith("ready"):
            raise RobotError("the server said " + line)
        self.pos, self.facing = None, None
        if len(line.split()) < 6:
            return                                            # not a robot: no position
        x, y, z, facing, energy = line.split()[1:6]
        self.name = line.split()[6] if len(line.split()) > 6 else self.address[:8]
        self.pos, self.facing = [int(x), int(y), int(z)], facing
        if energy.isdigit():
            self.energy = int(energy)
        self._event(f"at {x} {y} {z} {FACING.get(facing, facing)} {energy} {self.name}")

    async def _take(self, n):
        try:
            return await self.reader.readexactly(n)
        except (asyncio.IncompleteReadError, ConnectionError) as e:
            raise RobotError(f"the relay closed the connection ({e!r})")

    async def _open(self, code):
        h = fnv64(code).encode()
        self.writer.write(b"O" + bytes([len(self.zone)]) + self.zone + bytes([len(h)]) + h
                          + b"\1" + struct.pack(">I", len(code)) + code)
        while True:
            t = await self._take(1)
            if t == b"P":
                status = (await self._take(1))[0]
                await self._take(1)
                n = struct.unpack(">H", await self._take(2))[0]
                msg = (await self._take(n)).decode()
                if status == 0:
                    return True
                if "open already" in msg:
                    return False
                raise RobotError("the server zone did not open: " + msg)
            if t == b"z":
                for _ in range((await self._take(1))[0]):
                    await self._take((await self._take(1))[0])
            elif t in (b"d", b"x"):
                n = struct.unpack(">H", await self._take(2))[0]
                data = await self._take(n)
                if t == b"d":
                    self.text += data.decode("utf-8", "replace")
                else:
                    raise RobotError("the server ended: " + data.decode("utf-8", "replace"))

    async def _line(self):
        while "\n" not in self.text:
            t = await self._take(1)
            n = struct.unpack(">H", await self._take(2))[0]
            data = (await self._take(n)).decode("utf-8", "replace")
            if t == b"x":
                raise RobotError("the server ended: " + data)
            if t == b"d":
                self.text += data
        line, self.text = self.text.split("\n", 1)
        return line

    async def _replies(self, ids):
        replies = {}
        while len(replies) < len(ids):
            line = await self._line()
            rid, _, rest = line.partition(" ")
            if rid in ids:
                status, _, values = rest.partition(" ")
                replies[rid] = (status, values)
            else:
                print(f"{self.name}:", line, flush=True)
        return replies

    async def batch(self, cmds):
        """As Robot.batch. The deadline: QUIET s, and 2 s more a command (a batch of moves
        takes a while); none for a charge, which the server gives up on itself when the charger
        gives nothing."""
        async with self.lock:
            if self.writer.is_closing():
                raise RobotError(f"{self.address[:8]}: the link was closed")
            ids, lines = [], []
            for c in cmds:
                ids.append(str(self.next_id))
                lines.append(f"{self.next_id} {c}")
                self.next_id += 1
            data = ("\n".join(lines) + "\n").encode()
            self.writer.write(b"d" + struct.pack(">H", len(data)) + data)
            self.pending = (cmds, time.time())              # what a watchdog shows
            limit = None if any(c.split()[0] == "charge" for c in cmds) \
                else QUIET + 2 * len(cmds)
            try:
                replies = await asyncio.wait_for(self._replies(ids), limit)
            except asyncio.TimeoutError:
                self.writer.close()
                raise RobotError(f"{self.address[:8]} gave no answer to {cmds[0]!r}"
                                 f"{' ...' if len(cmds) > 1 else ''} in {limit} s")
            except RobotError:
                self.writer.close()
                raise
            finally:
                self.pending = None
            self.answered = getattr(self, "answered", 0) + 1
        out = []
        for c, i in zip(cmds, ids):
            status, values = replies[i]
            if status == "ok":
                self._seen(c, values.split())
            out.append((status, values))
        return out

    async def run(self, cmd):
        status, values = (await self.batch([cmd]))[0]
        if status != "ok":
            raise RobotError(f"{cmd}: {status} {values}")
        return values

    async def close(self):
        try:
            if not self.writer.is_closing():
                await asyncio.wait_for(self.batch(["bye"]), 10)
        except Exception:
            pass
        finally:
            self.writer.close()


REACHING = asyncio.Lock()          # one attach at a time: the relay says no to a second at once


async def reach(prefix, tries=6, **kw):
    """A computer at the relay (AsyncRobot.open), one at a time and again if the relay is
    busy attaching another (it answers no then: two builders starting at once, 2026-10-04)."""
    for k in range(tries):
        try:
            async with REACHING:
                return await AsyncRobot.open(prefix, **kw)
        except (RobotError, OSError, asyncio.TimeoutError) as e:
            print(f"  {prefix}: not yet ({e!r}), again in 5 s", flush=True)
            await asyncio.sleep(5)
    raise SystemExit(f"cannot reach {prefix}")


# ---- serving one robot to other programs -------------------------------------------------------

def serve(prefix, port):
    """Holds a robot's server open, and runs each batch a client sends on 127.0.0.1:port: the
    client sends command lines and shuts its side; it gets a reply line for each."""
    robot = Robot(prefix)
    print(f"serving {robot.address} at {robot.pos} facing {robot.facing}, on 127.0.0.1:{port}",
          flush=True)
    lsock = socket.socket()
    lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lsock.bind(("127.0.0.1", port))
    lsock.listen(4)
    while True:
        c, _ = lsock.accept()
        with c:
            data = b""
            while True:
                chunk = c.recv(65536)
                if not chunk:
                    break
                data += chunk
            cmds = [l.strip() for l in data.decode().splitlines() if l.strip()]
            if not cmds:
                continue
            try:
                replies = robot.batch(cmds)
            except RobotError as e:
                c.sendall(f"lost {e}\n".encode())
                print("lost:", e, flush=True)
                return
            for cmd, (status, values) in zip(cmds, replies):
                print(f"{cmd} -> {status} {values}", flush=True)
            c.sendall("".join(f"{s} {v}\n" for s, v in replies).encode())
            if cmds[-1] == "bye":
                return


def send(cmds, port):
    """One batch to the robot being served; its reply lines."""
    with socket.create_connection(("127.0.0.1", port)) as c:
        c.sendall(("\n".join(cmds) + "\n").encode())
        c.shutdown(socket.SHUT_WR)
        data = b""
        while True:
            chunk = c.recv(65536)
            if not chunk:
                break
            data += chunk
    return data.decode().splitlines()


def main():
    args = sys.argv[1:]
    port = 7790
    if "--port" in args:
        i = args.index("--port")
        port = int(args[i + 1])
        del args[i:i + 2]
    if len(args) >= 2 and args[0] == "serve":
        serve(args[1], port)
    elif len(args) >= 2 and args[0] == "do":
        for line in send(args[1:], port):
            print(line)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
