# 3d-draw: the contour and the map

Part of 3d-draw's design; the top, with the map of every sub-doc, is `../DESIGN.md`. How an area is
outlined, mapped, kept by chunk and numbered. The scouts that map it: `scouts.md`. Paths are from
`3d-draw/`.

## 1. The contour (the user's rules)

- **Start:** the robot stands on a contour block, the area to map on its right, the mini ME and
  a charger on its left. The block under it is analyzed (`geolyzer.analyze`): that name and
  metadata are "the contour block", id 1 in the map.
- **A step** tries three directions, in order: **forward, right, left** (never back).
  Trying a direction:
  - blocked by a contour block: **rise** while the block ahead is a contour block (follow walls
    made of contour blocks only), then go on;
  - blocked by anything else: this direction **fails**;
  - moved, and air below: **fall**, but stop falling, and fail, once no contour block is
    adjacent any more;
  - landed on a contour block: the direction **succeeds**; on anything else it fails.
  A failed direction is undone (the robot goes back to where it tried from) before the next.
- **The path of successful steps is the contour.** The walk ends back at the start position.
- **Never into a liquid** (the user, 2026-10-04, after the first walk deleted a water block): a
  robot moving into a source block destroys it, and `robot.detect` calls a liquid not solid, so
  a liquid ahead, above or below counts as a failed direction and the robot does not move.
- **Positions are counted by the robot**, relative to the start block (the user's choice,
  2026-10-04): every move and turn reports success or failure, so the count does not drift. The
  navigation upgrade only works inside the map it was crafted with, and the robot's is not; the
  start block's world coordinates, read once with F3, give real positions where needed.
- **The station, always laid out the same** (the user, 2026-10-04): at the start the charger is
  on the robot's left; one block forward, the mini ME's interface is on its left (on the first
  site, `ae2fc:fluid_interface`, AE2FC's dual interface: items and fluids). Checked on the first
  robot, 016db072: one block there and back cost 7 energy.

## 2. The map

- **Extent:** the columns inside the contour **and the contour's own columns** (the walked path,
  projected onto x/z), from the contour's lowest point −4 to its highest +4.
- **Non-invasive:** the robot flood-fills through the air inside that volume; it places nothing
  and never enters a liquid.
- **Grass is broken as soon as it is named** (tall grass, the grass and fern halves of double
  plants, Biomes O' Plenty's foliage), and its cell is air from
  then on, flown through like any
  other (the user, 2026-10-04: it hides the terrain). Flowers and everything else stay. Grass has
  hardness 0 but is not air, so the scan gives it noise and the mapper names it like a block.
- **Lavender stays** (Biomes O' Plenty flowers2:3; the user, 2026-10-04): a block under one the
  robot could not get at is taken to be grass.
- **Painted columns** (the viewer's paint tool, `run.py mapper --extend`) are added to the map
  without redoing it, scanned as high as the geolyzer reaches so pillars are seen whole; the
  box grows to 2 above the highest top, and old columns get only the new layers.
- **Exact blocks:** from every air cell visited, `analyze` on each solid neighbour (name,
  metadata, hardness). Everything visible from the air gets its real block.
- **Blocks it cannot touch** (underground): `geolyzer.scan` reads their hardness; each is guessed
  as the already-analyzed block of the same hardness, or else as dirt, stone or obsidian by
  hardness (the user's defaults).
- **Format:** one integer per cell, e.g. 20×20×20 = 8000. 0 is air, 1 the contour block, then
  ids in the order blocks are first analyzed; a palette maps each id to its block. A scene has
  few block kinds, so the ids stay small.
- **Memory:** the robot has one T3.5 module; it sends finished parts to the PC over the relay
  and keeps only what is still to visit. **That is the limit now:** on 2026-10-04 an extend run
  over x -17..6, z -13..8, y -5..10 (8,448 cells) stopped with "not enough memory" while naming
  blocks, the robot left out at the walkway's north end. Everything it learned had been sent, so
  `design/map_from_log.py <log>` rebuilt the map from the old one and the log, and
  `run.py exec --job data/job-home.txt --start x,y,z` brought it home along cells it had flown
  through. Larger areas need the map kept in pieces, not whole in the robot.

## Zones: the map by chunk, worked on 3x3 at a time

The user, 2026-10-04: "I want different map zones to be saved as chunks, such that we will be
able to load 3x3 chunk areas, this will be our standard work zone, that we will move around".

- **Where the start block is in the world:** x 255, y about 63, z 139 (the user), in
  `data/anchor.txt`. World = robot frame + that. Chunk (15, 8) holds the start block; chunk
  borders fall at robot x 1 (world 256) and z 5 (world 144).
- `zones.py save` puts `data/map.txt` into `data/chunks/c<cx>_<cz>.txt` (a map file over that
  chunk's 16 x 16 columns, in world coordinates), merging: the newest wins, but a guess never
  replaces a block a robot named. `zones.py load cx cz` puts the 3x3 round chunk cx, cz back into
  `data/map.txt` in the robots' frame (48 x 48: it fits the viewer's 64 x 64 world).
- The first zone, loaded 2026-10-04: (15, 8), robot x -31..16, z -27..20 - the house, the barn,
  the station and the pier. 25 chunks are kept (13..17 x 6..10), from the 64 x 64 survey.
- **A chunk that is not loaded reads as air** to the geolyzer: the impossible "air beside water"
  a scan from home found was exactly chunk (16, 9). The survey sets aside any column that reads
  air from top to bottom, and says so. Far from the player, the scout's chunkloader has to work
  (it refused, 2026-10-04: the server's config is still to be read).

## Block numbers: one registry

`data/palette.txt` gives every block kind (name, meta, named or guessed) its number once; every
map zones.py writes uses it. A zone rebuilt from the chunks used to number its palette afresh,
and the scouts' copies and the live view then meant different blocks by one number (water drawn
as flowers, 2026-10-04). Two scouts at once also number their new kinds from 1000 and 2000.

## Guessed grass

The user, 2026-10-04: a grass block only guessed, whose top and four sides are all known (named
or air), is grass for good - no scout will learn more (chosen over "dirt"). `zones.py
settle-grass` does it on the zone's map; blocks it settles do not count as known in the same
pass, so guesses cannot confirm each other. Exceptions: the user says.

## Guesses settled after naming (2026-10-07)

Run once B (`../redesign/20-scouts.md`) leaves nothing more that `analyze` can name. The user:
""hidden" blocks with no view from top, left, right, front, back will be considered dirt if they
have a plant on top" - then "grass, I confused it with dirt".
- **Hidden under a plant:** a block seen from neither above nor any side, a plant on top: grass.
- **The leaf/dirt chain**, both ways (the user: "the idea is to chain down", so it "fixes both
  trees and underground"): a guessed leaf under dirt is dirt; a guessed dirt over a leaf is a
  leaf. A block settled so counts as known for the next, so a column settles in one go. The two
  touch different guesses (a leaf's, a dirt's) and cannot undo each other.
