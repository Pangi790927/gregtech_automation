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

## 2. The link (C++) and the first robot in the exe

The link composer on `console/connector.h`; from Lua, `exec`, `give_way`, `geo`, `status_fast`,
`status`, `history` as awaitable calls. The exe reaches one robot, polls it (1 s, 5 s), and the
viewer draws it where it is.

## 3. The robot copy (Lua)

`blocks` (from placing.py) and `robot`: the copy runs each program's ops on the world; every
`status_fast` is compared at its op, `status` at the end; a difference fetches `history` and
names the first op where field and copy part. Tested on recorded programs, then live on short
walks.

## 4. The planner (Lua over the C++ world)

Dig and place packets on the fixed 5x5x8 grid, their order, the buildability proof, scaffolding
(05). Tested on the village plan: every packet ordered, nothing flying, nothing hidden, or the
cells it cannot do, listed. The viewer shows the packets coloured by state (today's J).

## 5. Programs, paths, the crew

The program maker (the printer's pattern, the door's exception), the pathfinder (C++, many
robots, shared paths, no dig on another's), the crew coroutines (packets to robots, `give_way`).
Tested: a whole build against copies, zero stops and zero divergences. Then live: one robot, one
packet, the user watching; then the crew.

## 6. The rest

The ME and crafting (`me`, `recipes`); the scouts (`geo`, exploring, naming, their rules - a note
of their own before it starts); the designs as Lua. Each replaces its Python files, which go only
after the user's walkthrough.
