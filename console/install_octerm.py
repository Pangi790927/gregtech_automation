"""install_octerm.py - puts a new octerm.lua on the computer through the running octerm, and
restarts it.

    python install_octerm.py [port]          default 7778, the relay's connector port

A connector, like term.exe: it attaches to the only computer on the relay and opens a one-off
zone whose code keeps /home/octerm.lua as /home/octerm.old.lua (to undo: move it back), writes
this folder's octerm.lua in its place, writes the relay's address from the repo's config.ini
(`pc`, `computer_port`) to /home/.octerm/relay, where a bare `octerm` reads it, and restarts
octerm. It restarts it by closing the running one, then typing `octerm` and Enter, which wait in
the signal queue for the shell octerm returns to. Closing takes two pushes: a Ctrl+C from the
computer's own keyboard, which the single-file octerm (protocol 1) closed on, and octerm_stop,
which stage 1 and its extension close on (their Ctrl+C belongs to the monitor's console, where it
does no harm). It speaks the connector side of protocol.h, which is the same in protocol 1 and 2.

Written 2026-09-30 to move the user's computer from protocol 1 to 2 without their typing it.
"""
import os, socket, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7778
NEW = open(os.path.join(HERE, "octerm.lua"), "rb").read().decode("utf-8")


def read_config():
    """Returns the repo's config.ini as a dict: `key = value` lines, `#` comments."""
    path = os.path.join(HERE, "..", "config.ini")
    if not os.path.exists(path):
        sys.exit("install_octerm: no config.ini at the repo root; copy config-example.ini")
    out = {}
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            out[key.strip()] = value.strip()
    return out


CONFIG = read_config()
RELAY = f"{CONFIG['pc']} {CONFIG.get('computer_port', '7777')}"

level = 1
while "]" + "=" * level + "]" in NEW:
    level += 1
CODE = f"""local z = ...
local computer, fs, tty = require("computer"), require("filesystem"), require("tty")
local NEW = [{"=" * level}[{NEW}]{"=" * level}]
local path, old = "/home/octerm.lua", "/home/octerm.old.lua"
if fs.exists(path) then
  if fs.exists(old) then fs.remove(old) end
  fs.rename(path, old)
end
local f = assert(io.open(path, "wb"))
f:write(NEW)
f:close()
z.send("written " .. #NEW .. " bytes to " .. path .. "; the old one is " .. old)
fs.makeDirectory("/home/.octerm")
f = assert(io.open("/home/.octerm/relay", "w"))
f:write("{RELAY}\\n")
f:close()
local kb = tty.keyboard()
local function key(char, code)
  computer.pushSignal("key_down", kb, char, code, "install_octerm")
  computer.pushSignal("key_up", kb, char, code, "install_octerm")
end
key(3, 0x2E)                                      -- closes a single-file octerm
computer.pushSignal("octerm_stop")                -- closes stage 1 and its extension
for c in ("octerm"):gmatch(".") do key(c:byte(), 0) end
key(13, 0x1C)                                     -- Enter: the shell starts the new one
z.wait(5)
"""


def fnv64(b):
    h = 0xcbf29ce484222325
    for c in b:
        h = ((h ^ c) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h


s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
buf = b""


def take(n):
    global buf
    while len(buf) < n:
        buf += s.recv(65536)
    out, buf = buf[:n], buf[n:]
    return out


assert take(1) == b"L"
addrs = [take(take(1)[0]).decode() for _ in range(take(1)[0])]
if len(addrs) != 1:
    sys.exit(f"install_octerm: want exactly one computer on the relay, there are {addrs}")
print("computer:", addrs[0])
s.sendall(b"A" + bytes([len(addrs[0])]) + addrs[0].encode())
assert take(1) == b"Y"
code = CODE.encode("utf-8")
h = fnv64(code).encode()
s.sendall(b"O" + bytes([7]) + b"install" + bytes([len(h)]) + h + b"\1"
          + struct.pack(">I", len(code)) + code)
# The zone's first words can come before the answer to opening it: the single-file octerm ran the
# zone as soon as it was loaded, and it closes the old octerm, so its 'P' may never come at all.
try:
    while True:
        t = take(1)
        if t == b"P":
            status, hit = take(1)[0], take(1)[0]
            msg = take(struct.unpack(">H", take(2))[0]).decode()
            if status != 0:
                sys.exit(f"install_octerm: the zone did not open: {msg}")
            continue
        n = struct.unpack(">H", take(2))[0]
        text = take(n).decode("utf-8", "replace")
        if t == b"d":
            print("computer:", text)
        elif t == b"x":
            print("zone ended:", text)
            break
except (OSError, socket.timeout):
    print("the relay closed the connection: the old octerm has closed")   # as expected
s.close()
