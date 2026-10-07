20 - the scouts: packets of scanning, like the builders' (DRAFT, being dictated)
================================================================================

The user, 2026-10-07, starting a new build in zone 12 10 (chunks 11..13 x 9..11, `data/zone.txt`):
"First we do scouting, then we design it and after that we do escorts, finaly we will build it".
Nothing here is built yet; this note is written first and read by the user (README, the rule).

## The idea

The user: "scouting will work similar to building, the idea: a scout will simply get commands of
the form go there, scan in this, this and this direction and so on, packets of work, it only
needs to return when low on battery".

- **A packet** is a chunk's scan, A or B below. The PC makes them; the scout runs one after the
  other with no trip home between, home only to charge, then the queue goes on where it stopped.
- **The scouts:** Tom_Servo and Cairol, geolyzer and chunkloader each (docs/robots.md): no escort.
  Pintsize has a geolyzer but no chunkloader. Both scouts at once, on different chunks.
- **What it ports:** `survey.py` worked well for the list of undecided blocks (A); `name.py`'s
  naming of single blocks "was broken bad" (the user) - B is new.

## Two kinds of scan

The user: "a chunk scan will contain two possible scans: "extended" -- containing caves and all
blocks in general and "restricted" -- this will scan only blocks that are hit by light (as far
as the robot knows anyway) or leafs".

Restricted is the one used most; extended is an option, asked for (the user, 2026-10-07).

- **Restricted - under the sun:** only blocks with nothing above but air and leaves; leaves don't
  stop the sun. The 2026-10-04 rule ("exploration needs sunlight") is this kind's.
- **Extended - "all under the sun":** every undecided block a scout can reach, caves too: it
  may go where the sun does not (the user, 2026-10-07, asked: "yeah").

## A - the mass scan: the list of undecided blocks

Done once a chunk ("Optional if it was done"); survey.py's job, ported.

- **From inside the chunk only**, the scout's chunkloader on (`isActive` asked first; off is
  reported, not scanned past): a loaded chunk can't read as all air.
- **To the chunk's centre**, about 10 above the ground, keeping above a moving average that
  filters potholes, and above the tops nearby (a lone tree or pillar). Then the chunk is scanned
  top to bottom, as far as the geolyzer reaches (32 up and down).
- **Against what was saved:** blocks gone are removed; a block where the map had air turns
  undecided. What A decides rests only on air (0, exact), water (~100) or a block; the kind
  guessed from the hardness labels the guess for the settling after B, nothing more. The noise
  is not averaged away (the user: "we only need to be certain").

## Moving

- On known map, moves are streamed with no checks; the map is taken as right.
- A surprise (a move refused where the map has air) is reported by the robot: the map changed
  there, it is marked, and the way is made again.
- A chunk never scanned, on the way: the PC first A-scans it from the chunk before it, and moves
  only through the air that scan found.
- Water that came after a scan and was not reported may be broken (the user: "it's ok").

## B - the particular scan: naming blocks with `analyze`

1. **Flood fill on the PC**, over the whole map (the user: "flood fill the entire thing"): air
   reached from outside. The walks may be long - over plains, stopping under a tree or at a
   hole - and can't leave what the scouts' chunkloaders keep loaded.
2. **T** = the undecided blocks the fill touches. To forget and rescan an area, the chunk is
   given with its blocks turned undecided in its copy only.
3. **A seed** from T, per column the highest:
   - extended: the highest reachable undecided block;
   - restricted: going up from it, a named block that is not a leaf rejects it; air and leaves
     pass; the first undecided met is the seed ("the first under the sun").
4. **Deferred, not rejected:** a block under an undecided one waits until that one is named
   (leaf: the sun passes; else: blocked), then is tried again. So the top is named first, and
   each round opens the layer under it, until a round changes nothing.
5. **The walk** from the seed: at each cell, `analyze` every undecided face; then move to an
   adjacent cell with an undecided block beside it (diagonal ones remembered, used after); when
   none, back to the last remembered cell not yet visited (a DFS). Restricted: every cell the
   walk takes must pass the same sun test, or it follows a cave's walls in.
6. **Then the next seed**, the one closest to where the scout is, so the surface goes first.
- **Blocks no scout can get beside** (under a crown closed to the ground, in a sealed pocket):
  left undecided. The user: "we can't enter to see, we don't decide, simple".

From name.py's failures, kept: the PC's energy floor is the robot's own (12 a step home + 1500),
or a refused stop is asked again for hours; a stop that fails is set aside, never asked again.

## After B: the guesses settled

When `analyze` can name nothing more, the map settles what is left by the user's rules:
grass under a plant where no robot sees, and the leaf/dirt chain both ways
(`../docs/map.md`, "Guesses settled after naming", the user's words there).

## The stages

Each passes its tests before the next; the robots only at the end, after the crew sim (as the
builders: 18-crewsim.md). What the robots already have is enough: `geo` answers a box at once
(03-exec.md), and a program's `l<dir>` looks at a block, read back from its history (04-notation,
`crew.read_looks`). No robot code is planned to change.

1. **The map's cells for scouts** (Lua, chunks.lua): never scanned, air, water, undecided (a
   block, its kind a guess), named. A scout's news goes where the robots' does: world.txt (how
   `geo` or `named`), the route grid (`route_set`), the copies. Tests: written, read back.
2. **The flood fill** (C++, route_composer.h, `route_flood`): the air reached from the sky over
   the whole grid loaded, the touched undecided blocks back to Lua - the only new C++, millions
   of cells. In Lua: T, the seeds (extended, restricted), the deferred and their rounds. Tests
   on small maps made by hand: a plain, an open tree, a crown closed to the ground (left
   undecided), a cave's mouth (restricted stays out, extended goes in), an overhang, a block
   under an undecided one (deferred, then taken).
3. **The walk** (Lua, `scouts.lua`): from a seed, the DFS of B 5 into a program of steps and
   looks, routes by `route_find`; restricted keeps the sun test on every cell; the program ends
   where the way home still fits the robot's floor (12 a step + 1500). Tests: the walks over
   stage 2's maps, every undecided reachable looked at once, no cell outside the rule.
4. **A, the mass scan** (Lua): the flight to a chunk's centre (above the average, above the tops
   near), `isActive`, the chunk's `geo` boxes top to bottom within 32, merged against the map; a
   chunk never scanned on the way is scanned from the one before. survey.py's parts that are kept
   noted in 07-inventory.md first. Tests: the flight over a pothole and a lone tree; a merge with
   a block gone and one come.
5. **The scouts' queue** (Lua, like crew.run_all): packets by chunk, A where never scanned,
   then rounds of B; two scouts on different chunks; home to charge when the next packet does
   not fit, the queue resumed; a surprise (a move refused) marks the map, the way is made again;
   a stop that fails is set aside. The crew's charge and home are used, not copied.
6. **The settling after B** (chunks.lua): grass under a plant no robot sees; the leaf/dirt chain
   both ways. chunks.lua's settling of 2026-10-05 (a floating guessed dirt touching a tree is
   leaves) stays beside it. Tests: a buried column of "leaves", a crown with dirt guessed in it.
7. **The crew sim's scouts** (simbot gets `geo`: hardness with noise growing to +-2 at 32, a box
   of at most 64, reach 32, 10 energy, an unloaded chunk all air): a world of plains, trees open
   and closed, a cave, a pond, an overhang, a lone tall tree; two scouts, restricted over three
   chunks, extended over one. Passes when: every block the rule allows is named, the closed ones
   left undecided, nothing broken, no water entered, every scout home and charged, no stall.
8. **Live**, watched: one scout, one chunk of zone 12 10, restricted; then both over the nine;
   then the settling, seen in the viewer. The zone's chunk files are from survey.py (2026-10-04):
   A is skipped there unless the user wants it scanned again. USAGE.md ("Scout an area") and
   19-ops.md get how it is run; survey.py and name.py go after the user's walkthrough.
