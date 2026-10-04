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
   Inside a packet: digging runs from the top down, placing from the bottom up.

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
