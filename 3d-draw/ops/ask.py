"""Claude's end of 3d-draw's control port (scripts/control.lua: 127.0.0.1:7790, the running
main.exe): each argument is one command, its answer printed up to the "." line.

    python 3d-draw/ops/ask.py "robots"
    python 3d-draw/ops/ask.py "lua return tostring(require('crew').run.note)"
    python 3d-draw/ops/ask.py "lua return dofile('ops/crew_go.lua')"

Paths given to dofile are relative to the app's working directory, 3d-draw/ (redesign/19-ops.md).
"""
import socket
import sys

s = socket.create_connection(("127.0.0.1", 7790), timeout=900)
f = s.makefile("rw", newline="\n")
for cmd in sys.argv[1:]:
    f.write(cmd + "\n")
    f.flush()
    for line in f:
        line = line.rstrip("\n")
        if line == ".":
            break
        print(line)
