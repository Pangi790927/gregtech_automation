# 3d-draw — map an area with robots, design a building in the simulator, build it with robots

Asked for by the user on 2026-10-04: "sort of like a 3d blender for minecraft". What is decided,
what it rests on, and what is still open. It uses the console (`console/DESIGN.md`) to reach the
robots and the simulator (`simulator/`) to show the map and the building.

This file is the top of 3d-draw's design: what it is, how to pick it up, what is open, and a map of
the sub-docs in `docs/`, one subject each. Detail goes into the sub-doc of its subject; a sub-doc
that grows past 150 lines is split again. `TODO.md` keeps what is still to be done.

**The system now is the redesign (since 2026-10-05/06):** the PC side is C++ and Lua - one exe,
`main.exe`, with the viewer, the planner, the crew and the link to the robots. It built the
village and rebuilt the burned cabin. Its notes, in order, are `redesign/README.md`; how it is
run from Claude is `redesign/19-ops.md`, with the scripts in `ops/`. Every change is still written
in `redesign/` first. The Python notes below ("The steps", rlink.py, the old docs/) describe the
system before it, kept until the user has walked through what is dropped.

## The steps

1. **Contour:** a robot walks a contour of blocks the user laid out, and remembers it.
2. **Map:** robots map everything inside the contour into a block array.
3. **Materials:** a mini ME (an ME interface the robot takes items from) holds the building blocks;
   its contents are read for the simulator.
4. **Design:** the map is drawn in the simulator, where the user decides on a building.
5. **Build:** robots build it in Minecraft. Robots talk to each other (wireless card, or the relay).

## Picking it up again (a new session starts here)

- **Start with** `TODO.md` (the state of things and what is open) and `USAGE.md` (each task the
  user asks for, and its commands), then `redesign/19-ops.md`
  (the app's control port, `ops/ask.py`, the crew's start/stop/reload, watching each robot, the
  checks before the robots), then as the work needs them: the roster in `docs/robots.md`; what the
  user allowed and forbade in `docs/rules.md`; the crew in `redesign/15-crew.md`.
- **The old way (Python, before the redesign):** driving them through `rlink.py` (the robot
  server, `docs/robots.md`). By
  hand: `python 3d-draw/rlink.py serve <robot>` holds one, `python 3d-draw/rlink.py do "move n" ...`
  sends a batch. From Python: `rlink.Robot("858fde4e")`; the mini ME's computer:
  `rlink.Robot("9cdb8754", log=None, program="me_server", zone=b"meserver")`.
- **The files now:** the map is `data/chunks/` read with its layers (`scouted.txt`, `built.txt`,
  `fixed.txt`, and `world.txt`, what the crew did and saw - `scripts/chunks.lua`); the plans are
  `data/village.txt` (`design/village.py`), `data/house.txt` (the cabin, `design/house.py`) and
  `data/harbour.txt`; the crew's own files are listed in `redesign/19-ops.md`.
- **The files before:** `data/map.txt` the map (PC side, the only copy that matters);
  `data/house.txt` the plan (`design/house.py`; the harbour's `design/harbour.py`);
  `data/build-done.txt` what
  is built (builders.py, `docs/building.md`);
  `data/live.log` what the viewer follows. All of `data/` is gitignored: it is the user's world.
- **Seeing it:** `simulator/main.exe --scene scenes/draw3d`; H shows the plan. To show the map as
  it is now: write `run.map_events()` into `data/live.log` (the viewer starts over when the file
  gets shorter). The world there is 64 x 64 x 64: the map must fit.
- **Mapping more:** `python 3d-draw/survey.py 956b836d` maps what the loaded zone lacks (the
  scout, `docs/scouts.md`); then `python 3d-draw/zones.py save`.
- **Zones:** the map is kept by chunk in `data/chunks/` (world coordinates); `data/map.txt` is
  the 3x3 chunks loaded to work on. `python 3d-draw/zones.py where | load <cx> <cz> | save`.
  Save before loading another zone, or what the robots found in this one is lost.

## The sub-docs (`docs/`)

- `docs/robots.md` -- the robot as built; the roster (names, addresses, parks, the mini ME's
  computer); energy; the robot server and rlink; coroutines; the OpenComputers facts.
- `docs/rules.md` -- what the user allowed and forbade (water, ground, walls, scouts, trees,
  materials); where the robots may go; the station, built around; water does not come back.
- `docs/running.md` -- how the work is run: an agent per area, sim.py before live, efficiency
  probing, the crew's working share, a silent robot is urgent; one zone at a time.
- `docs/map.md` -- the contour, the map, zones by chunk, the block registry, guessed grass.
- `docs/scouts.md` -- the survey and the naming, what stopped the scouts, where a scout may be.
- `docs/building.md` -- how a robot places a block; building in sectors (buildsite.py,
  builders.py, sim.py, placing.py): helpers, breaking in, dig and refill, fields.
- `docs/speed.md` -- why the builders are slow: what a call and a step cost in ticks (from the
  mod), where run 14's builder-minutes went, the fixes proposed; the benchmark (bench.py).
- `docs/materials.md` -- from the mini ME into a robot (me_server.lua); crafting, by Gunter.
- `docs/viewer.md` -- the live view, the robots' status, the map of chunks (M), markers (K).

## Open

- The server's own `OpenComputers.cfg` (geolyzer, `allowItemStackInspection`, robot settings).
- How the map is drawn in the simulator: read `simulator/CLAUDE.md` and `OBJECTIVE.md` first.
- The build step: the build-order check (support, fluids after the walls that hold them),
  refilling at the mini ME, charging.
