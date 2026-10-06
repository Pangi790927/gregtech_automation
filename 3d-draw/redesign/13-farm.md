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
- **Water** (3 cells) comes first: in this pack Hunger Overhaul (`modifyHoeUse`,
  IguanaEventHook, HungerOverhaul-1.7.10-1.0.4-GTNH) tills dirt only with water within 4 across
  and 1 up - without, dirt stays dirt and grass turns to dirt. The first tills failed so, the
  mattock barely worn (Pintsize, 2026-10-05). How water is put and where it comes from: below.

## Water (tried in-game with Pintsize, 2026-10-05)

- **A water bucket, in hand, used down** (`e<slot> u- e<slot>`) puts water exactly in the cell
  below; the empty bucket stays. Placed (`p`) it fails.
- **An IC2 water cell placed forward** (`p^<slot>`, no face) puts water exactly in the cell in
  front, the cell spent. Placed down it put the water beside the robot; with a face it failed.
- **An empty bucket, in hand, used** on water below or in front takes it back, filled.
- Water falls and spreads into air: a water cell's floor and sides are solid when it is put
  (the user: "be aware that watter falls and spreads").

**Buckets filled at the station** (the user, 2026-10-05: "placing water in the tank bellow and
a bucket in it should fill the bucket and put it in the output slot"): under the ME interface a
transposer, under it a GregTech tank (4,000,000 mB), on the ME's computer. Each tick the tank
empties a filled container in its input slot (1) into itself and fills an empty one from itself,
the container landing in its output (2); only the input takes items, only the output gives them
(GT_MetaTileEntity_BasicTank, DigitalTankBase, gregtech-5.09.41.317). The computer's `move`
(transferItem) carries a container from a stocked interface slot into the input and back from the
output into a slot not stocked, which hands it to the ME: water buckets in fill the tank, empty
buckets in come back water buckets - a crafting step with no robot (12-craft.md). Tried with one
of each, everything back in the ME. The ME holds water buckets as items, so a robot takes them as
any (11-me.md).

## The water step (the user, 2026-10-05: "go ahead with the water step for the field")

- **A water cell is a place** whose item is a water bucket: poured from the cell above, `u-<slot>`
  (the bucket into the hand, used down, back into its slot, empty), then `?-<n>`: water below,
  still or flowing (a bucket's water is `flowing_water` until its first tick). Nothing else pours:
  down is the one way tried exact. A bucket does not stack: one take and one slot each.
- **Sealed first:** a water cell is poured only once its floor and its four sides are solid -
  else it spreads. The planner makes it wait on the packets of those cells; the proof pours it
  only when they are there; the copies refuse a pour into a cell not sealed, so the dry run stops
  before the robot spills.
- **In a field, the water goes first:** the field's packet holds its water cell. Its sides that
  are farmland get their dirt first (untilled: tilled later as ground already, never stood in),
  then the pour, then the tilling tree as below. Each till is proven with water in Hunger
  Overhaul's reach (`isWaterNearby`: any water block within 4 across, at the dirt's level or one
  up), and the copies till only so.
- **Where it stands, 2026-10-05:** the upper field (-24,4,21) and the house's water (-9,3,33) fit
  this. The lower field (-24,3,14) does not: closed by ground at its level, the cell tilled last
  has no air beside it, and its only edge is its own water cell - the user's to decide.

## Tilling from below - the field worked as its own step (the user, 2026-10-06)

Tried with Pintsize at -22,5,23, a dirt block above her and water the user put near it: every use
sideways and down failed (72 tries, 2026-10-06), but `u+/+` - `robot.use(sides.up, sides.up)`,
the dirt above clicked on its top face - tilled it ("ok true", farmland). OpenComputers activates
the block next to the robot on the face named (Agent.use, clickParamsForItemActivate); the hoe
only needs that face not the bottom, air above the block, and water in reach. And a robot passing
right above farmland undoes it (the user: "you are breaking the field in your path"; a solid block
above turns farmland back to dirt - BlockFarmland, to be read).

The user, 2026-10-06: "farming should be done from bellow, farm land will be done by digging
under it (farm land must allways be 2 peieces of dirt and have a final block for the exit, the
robot tiles moves and fills with dirt back in it's way, so farm field will only be allowed if in
this form and it will be something else done in a separate step, so not the same planning will go
into it, a special work type will be this working the field)". And before: "working the field
without a connected dirt path to the water will undo the work".

- **The field as built:** dirt, two deep under each farmland cell, plus the exit block; the
  building packets place it like any blocks (no tilling in them). A field not of this form is not
  allowed.
- **Working the field, a work type of its own:** under the farmland, the robot digs its way along
  the second layer, tills each cell above from below, and fills the dirt back behind it; it comes
  out through the exit block, put back last. Never right above farmland.
- The old way - tilled from beside, a tree grown from the field's open edge (prove.lua's
  farm_layer) - is replaced by this.

The user's answers, 2026-10-06:

- **The exit** is a cell of the field: "it can be a dirt block in the field, leaving the field
  incomplete, that is not such a big thing I will go and fix that 1 block/field manually". The
  robot comes down through it, and leaves it dirt, untilled, its wheat not planted.
- **Order:** "the water must be placed before working the field"; and "the dirt that will have the
  crops will need to be filled before any plant is placed" - every cell under the farmland filled
  back before the first seed.
- **Wheat** is planted in the same work, after the tilling, from two above each farmland cell:
  never right above it.
- **Nothing passes over the field:** "it will be a block in the end, it will be a wheat block and
  nothing should pass it because it will be work in progress as reported by the planner (I mean it
  will be locked until the wheat actually is there and afterwards the wheat will block the way
  anyway)" - the cells above the farmland are kept off every route from the field's work on.

### The work, step by step

1. Over the exit cell E: dig E, step down into it, dig the cell under it, step down.
2. Under the field, a walk through every cell under the farmland (depth first from under E): dig
   the next one, step in, till the cell above (`u+/+`, then `?+` farmland); on the way back out of
   a cell, turn to it and put its dirt back.
3. Back under E: up into E, the dirt put back under it; up out of E, dirt put back into E.
4. The seeds, each from two above its farmland cell (`p-` into the cell between); that cell
   taken, from beside at the wheat's level, over ground that is not farmland, facing down (the
   seeds click the farmland's top all the same).

What the village's two fields taught (2026-10-06): a block planned two above the farmland (a
fence over the field's edge) goes in after the work, in a packet of its own; an unnamed plant
there is dug, as one right above is. The exit is a cell whose wheat cannot be planted anyway (the
scarecrow's arm over it) when one can be got to and left with the rest of the field locked; any
wheat still boxed in goes with the exit's to `result.field_exit`, for the user - never missing
unsaid. Both fields proven so: the upper 55 digs, 53 tills, 107 places; the lower 48, 46, 94; the
user's by hand: their exits' wheat and the one under the scarecrow's arm.


## The robot's ops (04-notation.md)

- `e<slot>`: equip - the item in that slot swapped with the tool in hand
  (inventory_controller.equip). The mattock comes into the hand before the first till and goes
  back before the program ends, so the robot's slots end as they began.
- `u+/+` (the use op, upward, the top face named): the tool in hand used on the block above,
  clicking its top - the till, from below (2026-10-06). TConstruct's mattock tills through
  AbilityHelper.hoeGround (TConstruct-1.9.25-GTNH): never on a bottom face, only with air above,
  only dirt or grass.
- `?<dir><n>`: the block in front must be palette entry n, else the robot stops ("not-expected"):
  a till that did not take is seen at once, not later.

The copies till too (simbot: the mattock in hand, any face but the bottom, dirt or grass with
air above and water near, becomes farmland), and farmland under anything solid turns back to dirt
there as in the game, so every program dry-runs first.

In the code (2026-10-06): the planner builds farmland as dirt (`as_built`) and makes each field a
packet of its own (`field`, its farmland in `farm`); prove.field_work writes the work, every step
from the cell it names, and `p.lock` - the cells over the farmland - which programs.make keeps off
its routes; the exit's wheat cell goes to `result.field_exit`, for the user.
