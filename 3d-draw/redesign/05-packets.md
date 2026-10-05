05 - work packets: how a build is cut and ordered
==================================================

The user, 2026-10-05: "the work batching: we can simply split the proposed end shapes into 5x5x8
rectangles (8 is height) those rectangles will have an ordering, so some of them won't be able
to be executed before others exist, but this will be a "work packet", so a single bot will work
on such an element, consisting of breaking, placing, etc. those will be executed from bottom to
above, making sure that an obfuscated work zone is not scheduled and also a flying workzone is
not scheduled, so this is how the planner will work, it will first create those work batches and
order them, the exe will afterwards be able to schedule a builder to such an work packet, the
assumption is that the bots will be able to path to such work packets, because their paths can
interleave (the bots should also do the work packets in one or at most 2 trips)".

This replaces today's sectors (buildsite.py: re-cut at every lease, up to 8 wide plus padding,
about 70 blocks), which left 4 of 5 robots idle at the harbour's end (docs/speed.md).

## The planner: two steps, before any robot moves

The plan's stairs carry their way in `facing` (`b x y z name meta shape facing`, meta 0): read
into the game's meta - rising east 0, west 1, south 2, north 3, upside down (shape 6) +4 - or
every stair was wanted, simulated and drawn rising east (the user, 2026-10-05: "it seems stairs
are not oriented properly"). Open: in the game a robot sets a stair's way by where it faces as
it places (OC's jar to read first), not by the item - the program maker must turn it.

1. **Cut.** The plan (the end shape) against the map: every cell whose block must change - placed,
   or broken to air - falls into a box of 5 x 5 across and 8 high. A box with nothing to change
   is no packet. A packet holds at most 200 cells.
2. **Two kinds of packet, two orders** (the user, 2026-10-05: "split the work into rectangles,
   schedule dig work first (the current rectangles with dirt or whatever that obstruct other work
   rectangles), then schedule place work from in the reverse order (dig is scheduled up to
   bottom, while place is bottom to up)"). A box gives a **dig packet** (its cells that must
   become air) and a **place packet** (its cells that must become a block); either may be empty.
   - **Dig packets go first, top to bottom:** a dig packet waits for the dig packet above it.
   - **Place packets follow, bottom to top,** once every dig packet is done (decided below, 3);
     a place packet waits for the place packet under it, so nothing is scheduled **flying**
     (standing on nothing).
   - **Hidden:** a place packet that would close the way into another (a roof over a room) waits
     for that one, so nothing is scheduled inside something already closed.
   Inside a packet: digging runs from the top down, placing from the bottom up. In a layer, a
   cell not reachable yet is tried again after the others, until none is left or none more can
   be reached (the field's -27,5,16, opened by its neighbour's dig, 2026-10-05).

## The exe: one robot, one packet

- The exe gives a free robot the next packet whose waits are all done. The packet is the robot's
  alone until it is finished.
- **One trip, two at most:** the robot loads everything the packet needs at the ME, goes, does
  it, comes back. A second trip only when the packet needs more kinds or more items than its
  slots hold.
- **Paths may interleave:** robots share the way to their packets; two that meet are sorted out
  with `give_way` (03-exec.md). No robot digs a cell on another's path (the exe checks).
- A packet becomes one `exec` program, or two or three of about 30 s or more each (03-exec.md):
  the trip there, the work, the trip back.

## Decided by the user, 2026-10-05

1. **The grid is fixed in the world:** boxes every 5 from the robot frame's 0 0 0 across, every 8
   in height from 0.
2. **The robot prints:** "hover place downard like a printer" - above the layer it builds,
   placing down (`p-`), a serpentine over the 5 x 5, one layer up at a time. Exceptions, such as
   a door ("I'm sure you will figure a way to place the door as an exception"), get their own
   pattern, to be worked out per kind of block.
3. **"dig everything that must go first and build bottom up":** every dig packet before any place
   packet; dig packets top to bottom, place packets bottom to top.
4. **Blocks that hang on something** (torches, ladders, doors, leaves): their packet waits for the
   packet holding what they hang on, even sideways - part of the order.
5. **Trust the put:** "trust the put (it has an error code, if I don't remember that corectly then
   read the block to make sure it was placed)". To check in the OC jar what `robot.place`
   returns, and whether it can say true while the block went elsewhere - the harbour's two
   strays (TODO.md, item 0) were blocks placed against the wrong neighbour. If it cannot say so
   wrongly, no read-back; else `put` reads the cell back, as today.

## Scheduling and what cannot be built

The user, 2026-10-05: "Robots are scheduled to to the first work they can do (considering the
dependencies), the planner makes sure that the plan can be built and it is quite simple for it to
say that look this is not possible and if it's possible to use scafolding (scafolding btw will
only be placed inside the work grid and a neighbouring finished place work packet)".

- **Scheduling:** a free robot takes the first packet, in the order, whose waits are all done.
- **The planner proves the plan buildable** before any robot moves. What it cannot order - a
  block with nothing to stand on and nothing to click - it reports as impossible, by cell, to the
  user.
- **Scaffolding** is the planner's one way out: a temporary block, placed only inside the
  packet's own box or in a neighbouring place packet that is already finished, and taken away
  when the packet is done.

## Proven at planning, not paused at run time (the user, 2026-10-05)

The user, 2026-10-05: "you need to complete them in one shot, not pause them, or else the planner
with 5x5x8 grids will fail, the solution is to try to fill the 5x5x8 and only when successful
(maybe even with scafolding, but prove you can remove them) and only then can you queue this work
as potential next work, so you need to make sure you don't create impossible work (isolated work
that can't be reached), but also make sure that the work can be done, at planning phase".

- **The proof:** the packets are filled on a planning copy of the world (the pathfinder's grid,
  kept aside and put back), in the order the robots take them. A block is placed only where
  something holds it (a block there that stays - not wild leaves, not a robot - or one placed
  before it) and where a free cell next to it can be reached; a dig likewise.
- **Scaffolding:** a block nothing holds gets a column of scaffold under it - inside its own box
  or a finished neighbour's, never in a cell the plan fills later - placed bottom up, then the
  block, then the scaffold dug top down; its removal is proven the same way.
- **The steps:** a proven packet keeps its exact steps (scaffold, blocks, scaffold away); the
  robot runs them in that order, routing between cells as it goes.
- **What cannot be proven** is reported at planning, cell by cell, and with it every packet
  that waits on it; it never becomes work.
- **Leaves:** a cell out of reach is left for the end-of-build scan only when it is a leaf, or
  touches one - seen, or guessed and settled by how trees grow (09-paths.md, "Guesses"). The
  user, 2026-10-05, of the proof stopping at leaves: "plz make sure you are not".
- **Waits from the proof:** a packet whose proof stood on a block placed - or a cell dug - by an
  earlier packet waits on that packet, so robots in parallel keep the proof's assumptions.
- **A way back to the station** (the user, 2026-10-05: "the planner must prove at least one path
  to the station exists in it's work ordering"): after each packet's steps, on the planning world
  as that packet leaves it, a route from where its robot ends to the station must exist; if none,
  the packet is unproven, "no way back to the station", and its blocks are not placed on paper.
- At run time nothing is set aside: a step that fails is a divergence, reported.
