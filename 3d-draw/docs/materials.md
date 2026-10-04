# 3d-draw: materials and crafting

Part of 3d-draw's design; the top, with the map of every sub-doc, is `../DESIGN.md`. How blocks come
out of the mini ME into a robot, and what Gunter crafts. Paths are from `3d-draw/`.

## Materials: from the mini ME into a robot

- `robot/me_server.lua` on the mini ME's computer: `stock <slot> <name> <damage> [size]` makes
  the interface keep one of its 9 slots stocked from the network (`store` into the database, then
  `setInterfaceConfiguration`); `clear <slot>` stops it; `count <name> <damage>`.
- The robot stands at (0 0 1) facing east, the interface in front, and takes with
  `suckslot e <slot> <count>`. **The interface fills on its own tick**: taken at once it gives 0;
  ask again after a second (it is there within one).
- Anything dropped into the interface (`drop e`) goes back into the network: that is how the
  robot empties itself.
- **The GregTech saw does not come out:** stocked, it sits in the slot, and both `suckFromSlot`
  and `suck` take 0 of it (2026-10-04; why is not known). Tools go into the robot by hand.

## Crafting, by the robot (checked in-game, 2026-10-04)

`python 3d-draw/craft.py need` lists what `data/house.txt` needs against the mini ME;
`craft.py all` makes all of it that has a recipe, into the mini ME; `craft.py make <name> <meta>
<n>`; `craft.py try` lays the patterns in its TRIALS once and says what came out. Gunter works
at (0 0 1), facing the interface; the GregTech saw lives in its slot 4.

- The grid is the inventory's top-left 3x3: slots 1-3, 5-7, 9-11; storage is 4, 8, 12-16.
  `craft <slot> <n>` crafts **n items** (not n times) into that slot. Keep the grid empty but for
  the recipe. A crafting tool (the saw) comes back into the grid, damaged.
- GTNH's recipes are in `GTNewHorizonsCoreMod`'s `ScriptMinecraft`, each a full 3x3 array with
  exact items (an item named there with metadata 0 means exactly that: oak). What came out:
  - log -> **2** planks by hand; planks over planks -> **2** sticks;
  - stairs, the vanilla shape, 6 -> **4**: spruce, dark oak, stone brick, cobblestone;
  - slabs: shapeless, the saw and the block: a plank -> **2** wooden slabs (spruce, dark oak,
    birch); a stone brick or a cobblestone -> **1** stone slab;
  - glass panes: shapeless, the saw and a glass -> **2**;
  - fence: stick-plank-stick in all three rows -> 1. **With spruce planks it is an ExtraTrees
    spruce fence** (`ExtraTrees:fence` 1); `minecraft:fence` (oak) needs oak planks;
  - fence gate: flint, gap, flint / plank-stick-plank / plank-stick-plank -> 1; with spruce
    planks a **MalisisDoors spruce gate** (`malisisdoors:spruceFenceGate`);
  - trapdoor: slab-stick-slab / stick-flint-stick / slab-stick-slab -> 1; with spruce slabs a
    **MalisisDoors spruce trapdoor** (`malisisdoors:trapdoor_spruce`). How MalisisDoors places
    and opens it is to be checked on the first one.
- The user, 2026-10-04: "spruce fences are fine except the pergola", so only the pergola's 25
  fences need oak (not in the mini ME yet).
- Ingredients are made when found short, not counted ahead: two recipes use the same thing
  (sticks ate the planks put by for the fences).
