TODO - what is still to be done on the base
============================================

Kept by Claude so the user need not keep track (the user, 2026-10-04: "do I have to take them by
turn, can't you do them yourself? keep track of what still needs doing?"). Each item: what, what
it waits on, the next step. Done items go to the bottom with their date, then away. Read this
first at a session's start, and keep it up; how to do each task is `USAGE.md`, how the tooling
runs is `redesign/19-ops.md`.

## The state (2026-10-07)

- **The village** (`data/village.txt`, `design/village.py`): built, 2026-10-06 night - "0
  packets left". Three planned cells west of the cabin that read empty (stone brick stairs at
  -12,0,3 and -11,0,3, a cobblestone slab at -13,1,3) were dropped from the plan by the user's
  word, 2026-10-07 (the plan before: data/village-before-path-cells-drop.txt).
- **The proposal space is clear** (the user, 2026-10-07: "ready for a new one in the next
  session"): no plan is proposed in the app (main.lua's PLANS and the packets list are empty);
  the built plans stay on disk as the record (village.txt, house.txt, harbour.txt).
- **A new build is starting** (the user, 2026-10-07): the focused zone moved to the one shown,
  `data/zone.txt` `zone 12 10` (chunks 11..13 x 9..11; was `zone 15 7`). Not chunkloaded.
- **The cabin** (`data/house.txt`, the fisher's cabin by the yellow marker): burned (174 wooden
  blocks gone), rebuilt 2026-10-07 by the crew from three geolyzer scans; the last scan read
  637 of 639 planned blocks; the two missing (a torch, a glass pane) placed after. The
  upside-down stair at -4,2,2 was dropped from the plan by the user's word ("just forget about
  it"; the plan before: data/house-before-stair-drop.txt). Two stilts at -3,-2,-1 and 3,-2,7
  were placed into water.
- **The robots:** all five builders and Gunter at their parks. Gunter is at 858fde4e now
  (placed back by the user). Tom_Servo and Cairol, the scouts, at the station.
- **The app:** robots.lua's per-link error catch (redesign/15-crew.md, "With no player on") waits
  for an app restart; relay.lua's frame fix is patched into the running app already.
  `crew.NO_LOADER_OK` is false and is NOT to be used any more (the escort replaces it, Open 1).
  Backups from the cabin work: `data/world-before-cabin-scans.txt` (world.txt
  before the scans were written into it), `data/house-before-stair-drop.txt`.

## Open

0. **The new build, in the user's order** (2026-10-07): scout zone 12 10, design, escorts (1
   below), build. Scouting as packets: `redesign/20-scouts.md`, settled; its 8 stages written,
   waiting on the user's read before stage 1.
1. **FIRST: escorts for ASIMO, Pintsize and Baymax** - the user, 2026-10-07: "instruct the new
   session to create a bridge with the escorts, one or two bots that only do chunkloading, that
   is, until I do my own solution, I will figure it out, but until them you escort them, even at
   base, I don't want to care about them (they have the file to know what is loaded and what
   isn't)". Their upgrade container is tier 2, a chunkloader needs tier 3: away from loaded
   chunks they freeze, their links drop, their programs are lost (redesign/15-crew.md). So:
   one or two of the chunkloading robots (Dalek_Sec, Cortana; an OC chunkloader keeps the 3x3
   chunks round its own robot, ChunkloaderUpgradeHandler) do nothing but escort while it lasts:
   whenever any chunk of such a builder's route or packet is not in `data/chunkloaded.txt`, an
   escort stays where its 3x3 covers it, off every route and stop point, there before the builder
   comes and gone only after it has left. The user is not to think about them, at base or away.
   And (the user, same day): "whenever it can it should find a place to stay without hovering,
   such that it saves energy, it will still have to refil and take the others with him" - it
   rests on a block when one is there, not in the air; and when it goes home to charge, the
   builders it covers go back with it (into loaded chunks), never left behind to freeze.
   Write it in `redesign/` first, sim it (the crew sim), test it, then live. Until it works, a
   builder with no chunkloader takes only packets wholly in loaded chunks; `crew.NO_LOADER_OK` is
   not used. The loaded map is the user's, already drawn: the station and its N, NW and W chunks,
   and the 3x3 walled square (chunks x 12..14, z 6..8).
2. **The app restart** (above): at a quiet moment.
3b. **The rest of the docs dry run** (the user, 2026-10-07): a fresh agent, read-only, given only
   the user's words, said what it would do for "move the focused zone" and "design a market";
   USAGE.md was fixed from both. Still to try the same way: "plan the build", "execute the
   build" (with the watch), and scanning once it is built. Design trap it found: village.py
   does not read world.txt (USAGE.md, "Design X").
4. **After a build, leaves and a rescan** (the user, 2026-10-05: "remember leaves and geo scan
   for them at the end, no bigie"; "it's scout's job to rescan the base area and check for
   changes"): `result.leaves` / `result.after_leaves` of the proof, scanned at the end;
   `ops/scan_box.lua` + `ops/plan_diff.lua` against a plan show what changed.
5. **Scout the cave under the village** (the user, 2026-10-05: "after we are done remember to
   tell the scouts to scout there"): robot x -16..-3, y -7..+1, z 10..28, marked red in the
   viewer. With `geo` from a scout.
6. **The harbour's ladders** (closed 2026-10-04 without them): planned meta 4 against open air;
   a next plan with ladders wants meta 5 and a solid west wall. Not to be done unless asked.
7. **Two shutters that did not open** (-8 1 8 and -10 1 4, trapdoors on the cabin): to be read
   back and used again. **The station's battery** is a guessed block in `data/fixed.txt`: to be
   named with `analyze` when a robot is beside it.

## Done

- 2026-10-07: the cabin rebuilt (above); the scan / diff / map / offline-proof scripts kept in
  `ops/`; the ExtraTrees fence's meta, water in a planned cell, dig-and-put-back into pockets,
  stop points kept off routes, robots located after being placed back - each with its test.
- 2026-10-06: the village built (redesign/15-crew.md: what sank the crew, and what changed).
- 2026-10-04: the harbour closed; the cabin (house) first built; markers in the viewer (K) - the
  user uses them now (`data/markers.txt`).
