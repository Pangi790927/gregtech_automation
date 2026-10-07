14 - blocks placed turned the plan's way (step 5)
================================================

The user, 2026-10-05, of the scarecrow the upper field waits on (its hay and its pumpkin): "can
you do 5?". Until now the crew refused every block whose way depends on how it is placed (stairs,
logs, slabs' top half, pumpkins, gates ...). Here they are placed so they come out as planned:
the game's own rules, read out of the jars, computed on the PC; the program names the robot's
stand, the way it places and the face it clicks; the copies compute the same; a look after
each one says it took.

## How a robot places (OpenComputers-1.8.0.13-GTNH, Agent.place, Player, read 2026-10-05)

`robot.place(side, face)` - in world terms: `f`, the way from the robot to the target cell T,
and `s`, the face. With no face, OC tries `s = f` first, then the others.

- **The fake player's look** is `normalize(f + s)` (Player.updatePositionAndRotation): yaw
  `= -deg(atan2(x, z))` (0 south, 90 west, 180 north, -90 east), pitch the same from y, x 0.99.
- **The click** (Agent.pick): a ray from the robot's side toward T, `C + f*0.5` to
  `C + f*1.01 + s*range` (`useAndPlaceRange`, 0.65 in this pack). It clicks the first block it
  meets - its side and the hit point go to the block (ItemBlock: the block lands in T).
  - `s = f`: the block beyond T, on its face toward the robot, hit at that face's middle.
  - `s` across `f`: T's neighbour on side `s`, on its face toward T, hit 0.61 along `f` from the
    robot's side (the ray leaves T after 0.39 of it).
  - `s = -f`: refused by OC (and it crashed the zone program, 2026-10-05).
  - The clicked block must be there and solid, or nothing is placed.
  - **And the ray must meet its shape** on the face toward T (`orient.holds`): a bottom slab
    beside T is missed from above - the ray crosses the slab's cell at 0.61, over the slab - but
    met from the side, level at 0.5. Cortana proved both live (-9,7,33, 2026-10-06); the copies
    and the proof had treated every solid neighbour as holding, and every such packet stopped
    "nothing-placed". The proof now writes a stand and face that hold on every plain place too.

## The blocks' rules (minecraft-1.7.10, through Forge's deobfuscation data)

`onBlockPlaced` (side clicked, hit) and `onBlockPlacedBy` (the player's yaw):

- **Stairs** (BlockStairs): way from `l = floor(yaw*4/360 + 0.5) & 3` -> 0:2, 1:1, 2:3, 3:0;
  upside down (+4) when the side clicked is the bottom, or a side face hit above 0.5.
- **Pillars** - logs, hay (BlockRotatedPillar): by the side clicked - top or bottom 0, north or
  south 8, west or east 4 - and the item's wood (meta & 3).
- **Slabs** (BlockSlab): the top half (+8) when the bottom is clicked, or a side above 0.5.
- **Pumpkins** (BlockPumpkin): `floor(yaw*4/360 + 2.5) & 3`.
- **Fence gates** (BlockFenceGate): `floor(yaw*4/360 + 0.5) & 3`.
- Not read yet, so still refused: doors, trapdoors, torches, ladders, levers, buttons, chests,
  furnaces - each when its rule is read.

A side clicked level with the robot is hit at 0.5 exactly: the fake player stands at the
robot's middle (Player's `yOffset` 0.5, added back by `Entity.setLocationAndAngles`), so the ray
keeps y + 0.5, and 0.5 is not above - the bottom half, every time. What is avoided is a look
right between two ways: a diagonal yaw (45, 135 ...) lands on the line `floor` cuts at.

## Where a turned block is placed from

The ways: from above (the printer's), from beside, and from below - from the attic under a
roof's stair, the side of its neighbour hit at 0.39, its bottom half any way. A bottom stair
has few: from beside on the side it faces away from, or from below. So:

- **A support where the way clicks**, when nothing is there - an eave's stair has nothing under
  or beyond it by design: on a chain from an anchor if needed, taken away with the layer's
  supports (as for blocks with nothing to lean on, 05-packets.md).
- **Its stand kept free:** in a layer, a block on the only stand of a turned block still to come
  goes after it (a fence in front of a stair); across packets, the turned block moves into the
  packet that fills its stand, when that one comes first.
- **Its click before it:** when a way's clicked block is still to be placed, its packet waits on
  that block's packet, or moves into it when it comes later.
- **Dig and put back** (the user, 2026-10-06: "dig and put back for the stairs"): when every
  stand is taken and no support opens one, what fills a stand is dug from a stand of its own,
  the turned block placed from the cell, and the block put back into it from outside, as it was
  (grass as grass, from the ME). Only a block that comes back: known, no way of its own (no
  stair, log, door), not leaves or a bush (they drop nothing), a plant only over soil, nothing
  over it that would fall or pop. Ten village stairs had no other way (-2,0,24 ...).
- **Left unproven:** a stair whose stands hold only what does not come back (wild leaves, a
  bush: -28,6,35), a cell never scanned; a roof's ridge whose stands are both turned blocks.

## In the code

- `scripts/orient.lua`: the look, the click and the rules, one place - `orient.meta` (what a
  place makes) and `orient.ways` (the `f, s` that make a wanted block).
- **The proof** places a turned block only from a stand and face that make it, with the clicked
  block there at that moment; else later in its layer; else it says why. The step keeps `f, s`.
- **Dig and put back** (`prove.lua`, dig_put_back): three steps - the dig, the place, the put
  back (`putback`, with its own stand and face) - run as any others; `test_turn` (dig_back_case)
  and the crew sim (`place 12 -1 25`) run them.
- **The program** puts it from that stand: `p<f><slot>/<s>`, then `?<f><n>` - the block named
  with its meta, so a way that did not take stops the robot at once.
- **The copies** (simbot) compute the meta of every place the same way, so the dry run shows it.
