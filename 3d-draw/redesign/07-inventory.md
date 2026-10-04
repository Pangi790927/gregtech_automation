07 - what of the old system is left, file by file
==================================================

The user, 2026-10-05: "what else is left in the python side?". Each file of today's 3d-draw,
against the notes 01-06: **covered** (the redesign replaces it), **open** (still needed, no note
says where it goes yet), or **drop**. Lines as counted on 2026-10-05. Nothing is deleted before
the user has walked through it (README.md).

## Covered by the redesign

| File | Lines | Replaced by |
|---|---|---|
| builders.py | 1698 | Lua robot and crew coroutines; C++ planner, pathfinder, program maker (05, 06) |
| buildsite.py | 298 | the planner's packets (05) |
| sim.py | 801 | the robot copies on the world (06) |
| tests/gate.py | 147 | the whole exe run against copies, in `main.exe --test` (06) |
| rlink.py | 457 | the C++ link, on `console/connector.h` (01, 06) |
| run.py | 166 | the link; `relay_host`, `fnv64` exist in C++ already |
| probe.py, crew_watch.py | 275 | the exe's own watching: `status_fast`, `status`, alarms (03, 06) |
| imprint.py | 56 | the world's built layer, written when a packet is done (06) |
| robot/server.lua | 409 | the robot's state machine: exec, status, geo, history (03, 04) |

## Open: still needed, not yet placed

Placed since, 2026-10-05: every one of these becomes a Lua module of the exe - `blocks`,
`recipes`, `me`, `scouts`, `map`, `designs` (06-pc.md, "Lua: everything else"). The table below
keeps what each holds.

| File | Lines | What it holds | Where it might go |
|---|---|---|---|
| placing.py | 172 | how each block is placed and read back: stairs, slabs, ladders, leaves, logs, substitutes, `item_of`, `expected_meta` | data for the program maker (C++ table or Lua); learned live, so kept whole |
| craft.py | 356 | Gunter's recipes, filling the grid, what the ME is short of | a crafting packet kind; recipes as data |
| me.py, read_me.py | 183 | the mini ME's computer (`robot/me_server.lua`), the interface's two sides, the stock | a second kind of machine on the link; the ME's sides as places in the world |
| survey.py, name.py | 1029 | the scouts: the rules (sky or a named tree, never break ground, refused.txt), exploring, naming blocks | scout coroutines with `geo`; the rules in C++ path costs - a note of their own |
| zones.py, keep_chunks.py | 414 | the map in chunks: merge a scout's map, save, the overview, the work zone | the C++ world; the chunk files kept as they are |
| design/house.py, harbour.py, village.py | 3232 | the three designs, generating the plan files | not runtime: port to Lua scripts in the exe, or kept as data (the plan files) and the generators dropped once the user has no more changes to them |
| tests/test_scouts.py | 457 | the scouts' rules tested | goes with the scouts' note |

## Drop

| File | Lines | Why |
|---|---|---|
| robot/mapper.lua, robot/contour.lua | 745 | the first mapping, done; the scouts and `geo` replace them |
| robot/exec.lua, design/clear.py | 465 | the first clearing job; packets replace it |
| design/map_from_log.py | 99 | rebuilt one map once, after a mapper run (2026-10-04) |
| bench.py, robot/bench.lua | 324 | the speed bench, never run; redone on the new link if wanted |

## In numbers

About 4,300 lines are covered, about 5,800 open (3,200 of them the three designs), 1,600
dropped. Without the designs, the open part is about 2,600 lines - most of it knowledge learned
live (placing, recipes, scout rules) that moves as data and rules, not as code.
