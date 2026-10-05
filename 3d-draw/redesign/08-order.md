08 - the order of work
=======================

PROPOSAL for the user. Each stage ends in something that runs, is tested without the game, and
is shown to the user before the next starts. No robot runs new code before its offline test (the
user's rule: sim before live). The Python system stays as it is until the piece replacing it
runs; nothing is deleted before the user has walked through it.

## 0. The skeleton (C++, small)

`3d-draw/main.cpp`, `3d-draw.yaml`, makefiles, `scripts/main.lua`, `tests/lua/`, laid out like
math_writer. It includes the simulator's composers, opens a window, reads `data/chunks/` and
draws the map. Done when: it builds on Windows, shows the harbour and the house as today's
viewer does, and one `tests/lua` test runs.

Status, 2026-10-05: built (`make` in 3d-draw/). The old viewer's lasting parts are modules of
their own in `scripts/`: the zone from the chunk files with built and fixed laid over it (`view`,
`chunks`, `look`), plans (`plan`, H), markers (`marks`, K), labels, the map of chunks (`zmap`, M).
Files are followed by size every second and by text every 10 s (`watch`); the mesh is rebuilt only
when something drawn changed - the old viewer's lag. Left out, as the exe replaces them: the live
log's robots, the pending cubes (J), painting. The station's blocks got their real textures and
shapes (`look.lua`, STATION). `main.exe --test`: test_chunks, test_look, test_modules pass.
No `linux.makefile` yet.

Speed-ups in the simulator's shared headers (2026-10-05, the user: "do the c++ speed-ups first"):
the world keeps a mesh per 16-cube section and marks which ones a change touches
(`world_t::dirty_sections`, `render_composer.h`: `rebuild_world_section`) - a block changed now
costs 2 ms of meshing, not 83; and `world:put_blocks(flat)` takes a whole batch of blocks in one
call. H on 0.18 s (the first time, its textures read), off 0.06 s; a zone 0.36 s. The simulator's
own tests still pass.

## 1. The robot's state machine (robot Lua)

`robot/machine.lua` replaces `server.lua` (named apart from the old clearing job's `exec.lua`,
kept until the user's walkthrough): the notation's parser, the ops, the stops, `wait`, `halt`,
`give_way`, `geo`, the energy check, the history file; between ops it reads the zone, and idle it
sleeps in `zone.wait` until contacted (03, 04). Tested first under Lua against a mocked robot
(every op, every stop, every parse), shown in the exe with J (the user, 2026-10-05: "j will show
me what bots did until now with full blocks and the rest as ghostly blocks, with say 30% alpha").
Then once in the game, on one idle robot, with the user told first: `status`, then `exec` of a
step up and back above its park.

Status, 2026-10-05: tests pass on the mock robot (scripts/simbot.lua): parse, walk, stops, waits,
dig, put, take, energy, $home, give_way; the exe shows a simulated robot printing a hut, with J
(see-through rest) and the robot drawn as OpenComputers draws it. In the game, Pintsize
(a77c49f1, park 0 0 -2): `status`, `geo` of the two cells above, `exec t1 $0 + -` - up and back,
done in under a second, its history read back. Found there: the geolyzer's table is 64 long
whatever the box, so `geo` now answers only the box's values. The driver was a scratch script;
the exe's own link is stage 2.

## 2. The link (Lua over a thin C++ socket) and the robots in the exe

The user, 2026-10-05: "let c++ do the heavy lifting, pathfinding, planning etc, but the connection
logic put in lua, this way less shutdowns are needed", and the program "pool centric": colib's
pool is the main loop, a frame is a task drawn in a burst (main.cpp). `net_composer.h`: connect,
send, recv, close, sleep, each a task a Lua coroutine waits on. `relay.lua`: the relay's frames.
`robots.lua`: a coroutine a linked robot - the machine zone opened, `status_fast` every second,
`status` every fifth, queued commands sent; a watchdog closes a link silent for 15 s and it is
opened again. The robots drawn where they are, in their colours, with name, state and trail.

Status, 2026-10-05: built; `test_relay` passes (the hash as Python's, list, attach, open again
after "open already", lines split over frames). Live: Pintsize linked through it, `exec $0 + -`
done, unlinked. Nothing links by itself: the robots window has a box per robot.

## 3. The robot copy (Lua)

`blocks` (from placing.py) and `robot`: the copy runs each program's ops on the world; every
`status_fast` is compared at its op, `status` at the end; a difference fetches `history` and
names the first op where field and copy part. Tested on recorded programs, then live on short
walks.

Status, 2026-10-05 (`scripts/copy.lua`, `robots.run`): every program is run first on a
throwaway copy of the robot and the map and sent only when that copy ends `done`; then the
robot's own copy follows it op by op through `status_fast`, and at the end position, facing,
state and slots are compared; a difference fetches the robot's history into the panel; a copy
standing apart from its robot is drawn see-through. `test_copy` passes. Live, Pintsize: `$0 >`
refused before sending (the copy stopped, blocked by the charger); `$0 + -` sent, followed,
"robot and copy agree".

## 4. The planner (Lua over the C++ world)

Dig and place packets on the fixed 5x5x8 grid, their order, the buildability proof, scaffolding
(05). Tested on the village plan: every packet ordered, nothing flying, nothing hidden, or the
cells it cannot do, listed. The viewer shows the packets coloured by state (today's J).

Status, 2026-10-05 (`scripts/planner.lua`, `packets.lua`, P): the village (6,365 blocks)
planned in 0.13 s into 130 dig packets (2,847 blocks), then 166 place packets (5,045 blocks), all
296 ordered; 0 with nothing to stand on; 31 cells never scanned (a tree crown, -17 11..14 7..8),
for a scout to read first. Packets wait only on packets ranked before them; a block held up only
by a later packet moves into it (18 in the village) - waits both ways had left 23 packets in
cycles, roofs across a box's border. `test_planner` passes.

## 5. Programs, paths, the crew

The program maker (the printer's pattern, the door's exception), the pathfinder (C++, many
robots, shared paths, no dig on another's), the crew coroutines (packets to robots, `give_way`).
Tested: a whole build against copies, zero stops and zero divergences. Then live: one robot, one
packet, the user watching; then the crew.

Status, 2026-10-05, paths (`route_composer.h`, `scripts/route.lua`, 09-paths.md): the whole known
map, 2.7 million cells, loaded from the chunk files in 1.45 s; a route in 2-4 ms; `test_route`
passes. The copies see the grid beyond the zone shown. Live: Tom routed from its charger to over
the village plaza (`<5v9+v+4v20<8`, 38 s) and back (`-^3-^26->-2>11^>`), each dry-run first,
each "robot and copy agree". Next: the program maker, the crew, the whole build simulated.

## 6. The rest

At a build's end: a geo scan of the leaves the proof left (out of reach to dig, or still in a
planned cell); the blocks they held back go in once they are gone. The scouts rescan the base area
for changes (the user, 2026-10-05). TODO.md, item 000.

The ME and crafting (`me`, `recipes`); the scouts (`geo`, exploring, naming, their rules - a note
of their own before it starts); the designs as Lua. Each replaces its Python files, which go only
after the user's walkthrough.
