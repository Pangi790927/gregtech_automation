13 - the field: farmland tilled, wheat planted
=============================================

The user, 2026-10-05: "farmland is made with a tool, I just gave all bots one (in me), the
mottock, wheat is seeds that grows and turn into wheat"; each builder now carries a TConstruct
mattock and a pickaxe; and of the wheat: "plz don't wait for the wheat to grow, that would take
too long (litteraly watching the grass grow...)".

## What the plan's cells become

- **Farmland** is dirt, placed, then tilled with the mattock. Its item is dirt (the bill, 11-me.md).
  A cell holding something else is dug first, as any (05-packets.md).
- **Wheat** is seeds put on farmland, from above: its item is `minecraft:wheat_seeds`. Planted is
  done - a crop of any growth stage is the plan's wheat; nothing waits for it to grow.
- **Water** (3 cells) needs a bucket: not yet. And it comes first: in this pack Hunger
  Overhaul (`modifyHoeUse`, IguanaEventHook, HungerOverhaul-1.7.10-1.0.4-GTNH) tills dirt only
  with water within 4 across and 1 up - without, dirt stays dirt and grass turns to dirt. The
  first tills failed so, the mattock barely worn (Pintsize, 2026-10-05). The ME holds no bucket
  and no water bucket (IC2 empty cells, AE2 fluid drops only): the user's to give.

## Tilling, as the game has it

A hoe - the mattock likewise - tills only with air right above the dirt and not from below; a
robot is a block, so it cannot till the dirt under it. It tills from beside, at the dirt's level,
from a cell still air. So a layer's farmland goes in an order: each cell placed (dirt, from above)
and tilled at once from a neighbour still air - one placed later, or a cell outside the field
(its edge, a water cell not yet filled). The proof builds the order as a tree from those outside
cells, the farthest cells first; a field with no open edge at its level is not proven. An edge
must still be reachable once the field around it is full.

A field is one packet: the 5 x 5 grid cut the village's field, and a piece proven after its
neighbours found every side filled. The village's lower field is sunk a block into the ground:
its one open edge is its water cell, under a Biomes O' Plenty plant the plan leaves unnamed. A
plant - tall grass, Biomes O' Plenty foliage, never lavender - standing right above a planned
farmland or water cell where the plan names nothing is dug (the old rule: such plants are broken
as soon as named, docs/map.md).

## The robot's ops (04-notation.md)

- `e<slot>`: equip - the item in that slot swapped with the tool in hand
  (inventory_controller.equip). The mattock comes into the hand before the first till and goes
  back before the program ends, so the robot's slots end as they began.
- `u<dir>/+` (the use op, no slot, the top face named): the tool in hand used on the block in
  front, clicking its top - the till. TConstruct's mattock tills through AbilityHelper.hoeGround
  (TConstruct-1.9.25-GTNH): never on a bottom face, only with air above, only dirt or grass;
  with no face named, OpenComputers clicked one that did not till (Pintsize's first field cell,
  the mattock untouched at durability 1.0, 2026-10-05).
- `?<dir><n>`: the block in front must be palette entry n, else the robot stops ("not-expected"):
  a till that did not take is seen at once, not later.

The copies till too (simbot: the mattock in hand, dirt or grass with air above, becomes
farmland), so every program dry-runs first.
