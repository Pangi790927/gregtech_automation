# 3d-draw: building

Part of 3d-draw's design; the top, with the map of every sub-doc, is `../DESIGN.md`. How a robot
places a block, and how the crew builds a plan in sectors. Materials and crafting: `materials.md`.
Paths are from `3d-draw/`.

## Building: how a robot places a block

Read from OpenComputers 1.9.14's `Agent.place`, `Agent.pick` and `Player$.updatePositionAndRotation`
(2026-10-04); `placing.py` holds the rules, one copy, for the builders and the simulation:

- `robot.place(side, face, sneaky)`: the block goes into the cell toward `side`; the robot clicks
  that cell's neighbour toward `face` (any but back toward itself). With no face: straight on,
  below, above, then sideways, in that order.
- The click is a ray from the middle of the robot's face toward `side`, 0.51 along it and 0.65
  (`useAndPlaceRange`) toward `face`; it ignores liquids. The fake player looks along side + face:
  a stair or gate takes that yaw. From above with a sideways face, the ray meets the side 0.61 up
  (upside-down stairs, top slabs); from below, 0.39 up. Sideways faces with a sideways side give
  a diagonal yaw that rounds either way: not used for anything that turns.
- No angel upgrade: nothing goes where no neighbour can be clicked. A **helper** - cobblestone
  put where one is missing, taken away after - gives the click.
- A click on a thin or partial block (bars, panes, fences, ladders, a slab's or stair's empty
  half) can miss it and the block goes in elsewhere: a place answered ok that reads back empty is
  a stray (`data/strays.txt`). A stair, slab, fence or pane that is not the plan's own is never
  clicked: which way it stands is not known.
- Ladders hang on the wall clicked (vanilla BlockLadder: meta 2 a wall south, 3 north, 4 east,
  5 west); the item is meta 0. Leaves: the item is meta & 3, placed leaves get | 4 (no decay).
  `minecraft:log2` (acacia, dark oak) stands as `log`. A short item may have a substitute
  (`placing.SUBSTITUTE`): oak leaves -> spruce leaves (the user, 2026-10-04: "use spruce leafs
  when missing substitute").
- **Leaves are never clicked against**: they decay once their tree's trunk is cut.
- **What is built is written down**, block by block, in `data/build-done.txt`; the site is
  read from it at every start, so a crew stopped and started again goes on where it was.

## Building in sectors (builders.py, from 2026-10-04 evening)

The old system (design/build.py's one order, crew.py, build_run.py - deleted 2026-10-04, the
user: "you may delete old unused code in the build system") planned for one robot and ran it
with five: builders swung at cells others stood in and broke three of them (Cortana lost), dug
through ground to travel and sealed themselves in, and dug into the riverbed on the scouts'
guesses. The user: "what did you do to get so many bugs?"; "Full redesign before building".

- `buildsite.py` - the site: the plan, the world as known (air, water, solid with its name, a
  guess, unknown), what is built, the work left. Ground that ends up hidden is kept (the user:
  "Keep hidden ground").
- `builders.py` - the crew, one coroutine a robot:
  - **Sectors** are cut from the blocks left at every lease and release: halved at the median
    while more than 70 blocks or wider than 8, then padded 2 cells round (a builder stands and
    finds its way only in its sector and 1 round it). No two leased sectors closer than 2.
    A block given up is tried again once something is built within 2 of its sector.
    Cut once by count alone, the harbour's last 160 blocks made a 22 by 20 sector for 44 of
    them, scanned 16,000 cells a look, and left three builders at home.
  - **Loading** (`me.py`): no trip when the sector needs nothing new; items the mini ME has none
    of wait for the user; when it goes, it takes along what later sectors need, of what the ME
    holds enough of for all; it claims a side of the interface only once at its park.
  - **Look-over**: the sector's columns scanned once, from just over its highest block (+2),
    from where it is when within 12; a column read this run is not read again; a column read
    all air is a chunk not loaded, not believed.
  - **Moving**: through the sector's area first, then a near box, then its own lane (a
    different height a robot); with no way straight up, out wider and down first (the
    lighthouse's shaft). Moves break nothing.
  - **Placing**: lowest first, nearest first; only a known face; ground in a planned cell broken
    in the same batch as the place, by a robot outside it; helper chains of cobblestone, 5 deep;
    never a place that leaves no way out through known cells.
  - **Breaking in, digging and refilling** (the user's leave, `rules.md`): a wall broken to
    reach cells inside, built again when the work inside is done (records `breakin`, `placed`);
    ground in `data/dig-ok.txt` dug to stand in is filled back with dirt (`dug`, `filled`).
  - **Fields**: a plan's farmland is tilled - the hoe (`gt.metatool.01` meta 8) swapped into the
    tool slot, `use <side> d` on the dirt's top from beside it (a hoe tills only a block with air
    over it); wheat is seeds placed on the farmland's top. Not yet run live: the user watches the
    first one ("I want to see you run it first, make sure you don't break").
  - A builder that cannot get on stops and says STUCK; one that ends on an error says ENDED with
    the error at once (Pintsize's coroutine died silently in run 8). The rest go on.
  - Every action goes to `data/actions.log` (`running.md`, probing).
- `sim.py` - the same crew offline on a simulated clock (`running.md`), over a world from the
  map with a quarter of its guesses wrong; a swing at a robot breaks it, water runs into opened
  cells, a missed click goes in elsewhere, metadata follows the click, chunks now and then read
  unloaded, the mini ME holds what the real one held at the last crew start (`data/me-now.txt`).
- `tests/gate.py` - sim.py on seeds 1, 2, 3 from the live record: fails on a robot broken or
  swung at, ground dug outside the plan, a builder STUCK or ENDED, fewer blocks placed than the
  last pass from the same record, or a working share under 40% with more than 350 blocks left.
  builders.py runs live only when the gate passed on its code (a stamp of the hashes);
  `--home` is always allowed.
- Commands: `python 3d-draw/builders.py --plan data/<plan>.txt [--robots a,b] [--steps N]
  [--no-craft]`; `--home` sends every builder to its park and charges it (to stop a crew: kill
  it, then `--home`). `python 3d-draw/tests/gate.py`. `python 3d-draw/sim.py [--plan ...]
  [--seed N] [--done <copy of the record>] [--actions <log>] [--kill NAME@SECONDS] [--left f]`.
- Learned live, 2026-10-04 (each in the code where it bit): the geolyzer's noise puts dirt under
  0.35 (every solid reading counts as solid); a robot's own cell reads as a block; a fence's box
  stands half a block into the cell over it; a chest's or pumpkin's facing is fine either way.

## From the old system, kept

- The interface's two sides (west 0 0 1, east 2 0 1), each with its own stocked slots, and
  blocks given back with `dropslot` into the side's return slot (4 or 8), never a plain drop:
  `me.py`, `materials.md`.
- Water: a planned cell, or one in `data/wet-ok.txt`, is gone into with `move <dir> wet`;
  without it `robot/server.lua` refuses any liquid. Only leaves a scout named are passable.
- A robot is a block: `robot/server.lua` refuses a swing at a robot ("blocked: a robot").
- Not carried over: the old crew's rescue of a builder gone from the relay (the nearest went to
  its cell and sucked from every side). Today a builder gone is reported at once instead.
