# 3d-draw: what the robots may and may not do

Part of 3d-draw's design; the top, with the map of every sub-doc, is `../DESIGN.md`. The user's
leave and limits, in their words. Paths are from `3d-draw/`.

## What the user allowed and forbade

**What the user allowed and forbade** (one list; the user's words, 2026-10-04):
- water: never touched, except a planned block's own cell ("you can enter in water on a block
  that will be replaced either way") and the ship's hull ("Robots may enter the hull's
  water") - `data/wet-ok.txt`;
- ground: builders break it only to place a planned block; outside the plan only at the
  lighthouse's base, filled back after ("Yes, dig and refill") - `data/dig-ok.txt`; ground
  that ends up hidden is kept ("Keep hidden ground");
- walls: broken to get inside and put back, nothing hanging on them, never glass ("you can
  break in safer through a wall ... and place it back afterwards");
- scouts: map only, never break ground ("your assumed leafs is ground, don't break ground");
  explore only under open sky or a tree ("exploration needs sunlight"), travel freely in the
  known, built area ("in built know area you can pass under buildings"); no --leaves until
  the user approves again; their dug tunnels stay ("Leave them"), kept out by
  `data/refused.txt`;
- trees and dirt may go within reason; the korpBlock wall in the back never; lavender stays
  but under buildings;
- materials: the user gives them; Gunter crafts what has a recipe (fences too, from spruce).

## Where the robots may go, and what they may break

Within reason, outside the contour too, and trees and dirt may be broken (the user, 2026-10-04);
**never the raised stone walkway with its pillars at the back (west) of the first site**. Grass
is broken while mapping; lavender stays.

## The station: built around, never into

The first site's station was scanned whole on 2026-10-04 (`data/map.txt`): charger (1,0,0), the
mini ME's dual interface (1,0,1), adapter (1,0,2), computer (1,0,3) with screen and keyboard, a
drive, cables and a solar panel on x 1, a glass canopy over x 2..4, z 2..4, and GregTech machine
blocks with glass under the water at y -5, x 1..6, z -3..5. The robot docks on the contour's
east line (x 0). The user, 2026-10-04: "we will use it a lot from here on", so the house moved
west to clear it. `design/house.py`'s `put` refuses the station's columns, the water above its
underwater part, x 0, the user's contour blocks and the walkway wall. `data/labels.txt` names the
station's blocks in the viewer.

## Building: water

**Water does not come back** (the user, 2026-10-04): a source block a stilt or any block takes
the place of is gone for good. The build displaces as little water as it can, and never breaks
or drains any. (The robot already never moves into a liquid.)
