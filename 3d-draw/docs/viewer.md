# 3d-draw: the viewer

Part of 3d-draw's design; the top, with the map of every sub-doc, is `../DESIGN.md`. What the
simulator's `scenes/draw3d` shows, and the user's tools in it. Paths are from `3d-draw/`.

## The live view

`3d-draw/run.py <program> [address]` runs a robot program and writes its lines to
`data/live.log`; the simulator's `scenes/draw3d` (`main.exe --scene scenes/draw3d`) follows that
file. Events, one per line: `box`, `pal`, `scan`, `at`, `blk`, `guess`, `charge`
(`scenes/draw3d/controller.lua` lists them). An `at` event may end with the robot's name; the
view draws each robot by its name. Blocks are a simulator cell kind of their own,
`MC_BLOCK`, textured from the jars where a texture is found and coloured where not.

## Status, for the viewer's robots panel

Every program reports `status <robot> <state> | <now> | <overall>` into the live log
(`rlink.Robot.status`): naming (the next three blocks, named n of m), surveying, building (the
block and where, the house's steps built), loading, charging, crafting.

## The map of chunks in the viewer (M)

The user, 2026-10-04: "a sort of map with chunk wide click zones that centers the map around that
zone and draws the 3x3 chunk in the viewer, maybe put that map on M". M opens a window with every
kept chunk, each column coloured by the block on top (`data/chunks/overview.txt`, which
`zones.py save` writes). Hovering outlines the 3x3 a click would show; a click reads those nine
chunk files straight into the view, in the robots' frame, and centres the camera. Yellow: the
zone shown; red: the robots' work zone (`data/zone.txt`); dots: the robots. While a zone from
the chunks is shown, the live log moves only the robots; "live log" goes back to it.

The zone shown keeps up with its files (the user, 2026-10-04: "make sure that the in-view maps
stays kinda-updated at least (the lighthouse is built in reality, but in practice it's not
there)"): every 2 s its nine chunk files, `data/built.txt` and `data/fixed.txt` are read, and
when one changed the zone is drawn again, the camera staying put. BUILT and FIXED are laid over
the chunks in zones.py's order, so a finished building shows even before its chunks are saved.

## What is left of a build (J)

The user, 2026-10-04: "maybe add an option on j to show what is still pending (colored cubes
that woill show me what is left of a build, where the proposal shows the final result, this one
will show what is left)". The build agent rewrites `data/pending.txt` (or one
`data/pending-<plan>.txt` per plan; the viewer reads both) every 30 s: `p x y z status name`,
robot coordinates, under `# plan <file> <time> <left> left`. **J** draws a small cube in each
cell: yellow to build, red lacking material, purple stuck. With H on too, what is built shows as
the plan's blocks and what is left as cubes. The panel counts them: "N left (a build, b
lacking, c stuck)". The file is read again when it changes, once a second.

## Markers in the viewer (K)

The user, 2026-10-04: "I would also like to be able to place some colored markers so I can tell
you what things are, so that I won't have to go read coords". The user chose markers in the
viewer over wool in the game, which a scout would have had to find and `analyze`.
- **K** turns marker mode on. **Left click** marks the block under the crosshair (a voxel
  raycast, so it works at any height), **right click** takes the mark away - also one with no
  block left under it: the marker nearest the crosshair's ray (1.5 blocks) or within two blocks
  of the cell aimed at ("I can't remove them anymore because they no longer stay on blocks",
  2026-10-04), **C** or the panel's
  buttons choose the colour: red, orange, yellow, green, cyan, blue, purple or white. The panel's
  note box (Tab frees the mouse to type in it) goes on the next marker placed. Marking a block
  that already has a marker replaces it.
- **`data/markers.txt`**, one `marker x y z colour [note]` a line, robot coordinates, in the order
  placed. **When the user mentions a marker, Claude reads this file.** The block itself is in the
  map at that cell. The viewer reads the file again when it changes, so Claude may edit or empty it.
- Drawn like the labels: a dot on the block's top, with the note (or the colour) over it.
