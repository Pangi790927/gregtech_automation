TODO - what is still to be done on the base
============================================

Kept by Claude so the user need not keep track (the user, 2026-10-04: "do I have to take them by
turn, can't you do them yourself? keep track of what still needs doing?"). Each item: what, what
it waits on, the next step. Done items go to the bottom with their date, then away.

## Open

00. **Scout the cave under the village** (the user, 2026-10-05: "it's real, it's a cave, for now
   leave it, but after we are done remember to tell the scouts to scout there"). Marked red in
   the viewer: robot x -16..-3, y -7..+1, z 10..28 (world 239..252, 56..64, 149..167), between
   the house and the field; the map holds 1,067 cells of it as air, with jacaranda leaves read at
   y -5 and -1 inside. Waits for the redesign (redesign/08-order.md); then the scouts, with `geo`.

0. **The harbour: CLOSED** (2026-10-04, 23:45; the user: "so you can't place ladders (this is
   the only missing thing), and in the rest the thing is done (minus some pieces that are mostly
   not visible), start the next project"). Built with the new builders (docs/building.md) from
   16:30; imprinted as built (data/harbour-built.txt into built.txt: 2211 cells, placed or kept
   as ground); 68 cells left unbuilt by the user's word, robots home.
   Why the ladders were not placed (not fixed; for a next plan with ladders): the lighthouse's
   ladders (x -12, y 4..13, z -24) are planned meta 4, which vanilla hangs on the block EAST of
   them (x -11) - the shaft's open air; the wall is WEST (x -13), and there it is iron bars at
   y 5, 8 and 11, which a ladder cannot hang on. So no click ever had a wall: the plan wants
   meta 5 and a solid west wall. 4 of 14 went in (y 2, 3, 14 and the pier's at 2 -1 -24).
   Materials: the user filled the mini ME (ladders, leaves, barrels, 56
   acacia logs); Gunter crafts the acacia and spruce planks; oak leaves short -> spruce leaves.
   Strays: LEFT AS THEY ARE (the user, 2026-10-04: "not sure what you are doing, don't breake
   stuff") - an upside-down stair meant over the lighthouse door (-7 4 -24), a stone brick
   clicked on iron bars (meant at -10 6 -27); not looked for, not removed.
   Done 2026-10-04 evening: sectors cut by size and re-cut as they finish, scans once a sector,
   loads only when needed, the action log and probe.py, crew_watch.py alarms, the gate
   (tests/gate.py), the honest sim, me.py; the old system (crew.py, build_run.py,
   design/build.py) deleted at the user's word. Open: at the harbour's end the lighthouse is one
   sector, so four builders wait (8-10% working share in the sim); in run 9 ASIMO had a dozen
   places refused at the lighthouse floor (y 0) - run 11 prints the robot's answer.
0b. **The village** (design agent; the user, 2026-10-04: "can we see more thematic houses around
   that area? maybe add a field of wheat (I've added seeds and hoes to the me) also build a
   windmill in that area, so I will wait for the proposal"). The area's centre is the user's blue
   marker, robot -9 3 33 (world 246 66 172, chunk 15 10), south of the fisher's house. Next: the
   proposal (design/village.py -> data/village.txt, shown in the viewer); the user reviews. Then
   the fields first, while the user watches ("you will have to start with building the fields,
   that is a new action for you and I want to see you run it first, make sure you don't break");
   the work zone moved to cover it (zones.py load 15 10). The viewer needs a restart to show it
   (also to drop Cortana: live.log's `gone Cortana`).

1. **The house is finished** (2026-10-04) and imprinted into the map (imprint.py: its 644 cells
   in data/built.txt, a layer no scan undoes; the viewer no longer shows it as a plan). Next: a
   geolyzer check of the house and pier against it, by a scout between jobs; differences go to
   build-done.txt as `missing`/`stray` and to built.txt.
2. **Scouts** (scout agent; the user, 2026-10-04: unprospected chunks first, then naming
   centre-first). The rule (survey.Rules, docs/scouts.md): explore only under the sky or a
   named tree, travel through any known air in the known area, never break ground. **No
   --leaves until the user approves it again** (it was allowed earlier on 2026-10-04, then
   withdrawn after the scouts dug 59 cells of tunnel under the forest: data/scout-damage.txt,
   kept out by data/refused.txt). Blocks only reachable through leaves wait for that word.
   Now (2026-10-04, 23:00): the 15x15 chunks (8..22 x 1..15) are all surveyed - the mountain
   and the north-west strip done at 22:55 after two survey fixes (docs/scouts.md). Tom names
   the east, map-tom-near.txt, --region 1 -91 96 84 (11,300 to go); Cairol names the west,
   map-cairol-big.txt (47,000 guessed). Next when done: the next ring outward past chunks
   8..22 x 1..15, the far west from the wall's top. Jobs end
   themselves at 110 min (--minutes) and are started again; maps go into the chunks with
   `zones.py save <map>` about every 30 min. Tests: tests/test_scouts.py.
3. **The harbour** (the user's brief, 2026-10-04): a crane in front of the lone tree (world 252
   115, robot -3 -24), a lighthouse behind it about 14 high (1.5 x the back wall's 9), the start
   of a large ship dock along the west bank going north, resources (crates, barrels, logs, hay)
   near the crane, a path from the house. Chisel blocks where possible; ask the user for
   materials when building. Next: draw it (design/harbour.py -> data/harbour.txt, shown with
   the house in the viewer), the user reviews. Then: the work zone moved north onto the tree's
   chunk, the scouts name the site's blocks, the site cleared but for the tree, built.
   Drawn 2026-10-04 after the user's four pictures (tower, stairs, two harbours), with the wall
   stairs and a stone pier by them. For building: build.py must take the harbour's plan file,
   and "wet" (moving into water) must cover any planned block, not only log stilts - the stone
   pier's pillars stand in the river (the user's rule: "a block that will be replaced either
   way"). FINAL (designer, 2026-10-04): data/harbour.txt, 2284 blocks, every one in the mini
   ME or crafted by Gunter from its logs (spruce ~630 of 1240, dark oak ~93 of 896, acacia ~19
   of 52: dark oak and acacia planks, acacia stairs - recipes to check). Tall grass and ferns
   left out (the user has none). Not to be changed while it is built. Prep done (builder,
   2026-10-04): `--plan data/harbour.txt` for build.py and crew.py (BUILD_PLAN for
   build_run.py); wet moves for any planned block; the work zone loaded on the tree's chunk
   (zones.py load 15 7: x -31..16, z -43..4, the station and the house in it); recipes checked
   in-game - acacia planks and dark oak planks (one log, two), acacia stairs (6 -> 4). Next:
   Building since 14:09 (crew.py --plan data/harbour.txt; final harbour.txt of 14:17). Open:
   the ship's bottom row (y -3, 28 dark oak planks + 18 keel logs) cannot be built - the hull's
   sides step in diagonally, so no planned water connects down to it, and under it the bed is
   too deep to click: the user to choose (drop the row - it is under water inside the hull -
   or let robots into the hull's unplanned water). The lighthouse top (y 17-22) plans once the
   sky over each column counts as air (done 14:44; the next replan has it).
4. **The 15x15 chunk survey**: ended 2026-10-04. Tom's half (east) scanned but 314 columns;
   Cairol's (west) left 9197 he could not reach through the air he had scanned (high ground, the
   back wall's far side). Next, if the city needs the west: a scout started from the wall's top.
   Cairol named the harbour site's blocks (2026-10-04: 361 named, 159 out of his reach; merged
   into the chunks), and the harbour was drawn again on them.
5. **Two shutters that did not open**: -8 1 8 and -10 1 4 (trapdoors placed, `use` left them
   shut). Next: a robot reads them back and uses them again.
6. **The chunkloader**: settled 2026-10-04 - `setActive` returns whether the state changed, so
   `false` meant "already on" (docs/scouts.md). Asked of the builder agent: robot/server.lua
   `chunk` to answer `isActive()` after setting it, so the scouts print what is true.
7. **A block placed one too high**: the planks recorded at 2 -1 5 stood at 2 0 5. Cause not
   known; all five robots' positions checked right afterwards. Watch: a geolyzer check after
   each building, `missing`/`stray` lines in build-done.txt for what it finds.
8. **The station's battery** is a guessed block in data/fixed.txt (`gregtech:gt.blockmachines`
   meta unknown): to be named with `analyze` when a robot is beside it.
9. **Markers in the viewer (K)**, built 2026-10-04 (docs/viewer.md). The user has not tried
   them yet. Next: once the user places some, read `data/markers.txt` and check that the
   coordinates match the blocks meant. Wool markers in the game were left out by the user's choice.
