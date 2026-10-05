09 - paths: the one new C++ of stage 5
======================================

The user, 2026-10-05: "we need paths I think and afterwards we can simulate the whole build right?"
- and, earlier, C++ for "the substantial parts ... (also the one that will compute paths and such)".

## The grid (`route_composer.h`, 3d-draw)

A byte a cell, over the box of chunks asked for, in robot coordinates:

| byte | means | a robot may |
|---|---|---|
| 0 | never scanned | not enter (a builder); a scout's business |
| 1 | air, seen | enter |
| 2 | a block | not enter: the robot digs only what its program names (03-exec.md) |
| 3 | water or lava | not enter: the PC owns water (the user, 2026-10-05) |

Loaded straight from the chunk files and the layer files - `scouted.txt`, `built.txt`, `fixed.txt`,
each over the one before (below) - in C++ (`route_load`): a
whole map is millions of cells, too many to hand over from Lua one by one. Above the highest block
ever scanned counts as air - the sky. Lua changes single cells as the world changes
(`route_set`): a block placed, a cell dug, a scout's news.

## A route (`route_find`)

A* from a cell and facing to a cell, cost in server ticks as measured (docs/speed.md): a step 13,
up or down 12, a turn 11 more. The answer is the program's own notation (04-notation.md):
`+3>12^4-2`, or "" when there is no way within the search's limit. Robots are not obstacles here:
two that meet wait and give way (03-exec.md); what the PC must not do is dig on another's way -
the crew's to check, not the route's.

## Guesses, and what the scouts found (2026-10-05)

The first survey named most cells under ground from the geolyzer's hardness alone, and its noise
made dirt into leaves and stone: under the village's field and its stone spot every guessed leaf
and every guessed stone read 0.4 - 0.6 averaged over 12 close scans - dirt or grass (Tom and
Cairol, 2026-10-05). So:

- **`data/scouted.txt`** (local, as all of `data/`): cells a scout read again, averaged close
  scans; laid over the chunk files, under `built.txt` and `fixed.txt`. A guessed or never
  scanned cell's mean: under 0.12 air, to 0.32 leaves, to 1.0 dirt (grass when the cell above
  reads as air), to 1.75 stone, above that a log. A seen cell is changed only when its mean
  says air or leaves and the map says ground - dirt in a crown (the user, 2026-10-05: "dirt
  doesn't stay in trees").
- **Guesses settled by how trees grow** (the user, 2026-10-05: "normally leaves don't have dirt on
  them and also dirt doesn't stay in trees"), as the planner reads the map (`chunks.read_area`):
  a guessed dirt or stone with air under it before any ground, touching a log or leaves, is
  leaves - top down, so a crown settles whole; a guessed leaf with ground right above it is dirt.
- **Leaves for the proof** (05-packets.md): seen, or guessed and left standing by those rules;
  a guessed leaf that the rules made dirt is ground.

## Retries, and other robots' work (the user, 2026-10-05)

The user: "robots should retry things that aren't dangerous: block placing and moving in a
direction (for meeting with mobs and other bots durring pathings, only breaking is dangerous and
care should be taken not to path through block breaking, hmm, actually, not to path through block
placing either, else it may get stuck inside a house or something like that)".

- **Retried on the robot:** a step, and now a put, that a creature or a robot is in the way of:
  `wait`, tried again every second, as a step already did (03-exec.md). The PC sees the wait in
  `status_fast`. A put failing for anything else stops, as before.
- **Never retried:** a dig. It stays checked to the exact block (03-exec.md).
- **Routes keep off work:** when a program is made, the cells of every packet another robot is
  working - to dig and to place, supports with them - count as blocks for its routes. A way is
  not taken through ground about to be dug, nor through air about to be filled, where the robot
  could be walled in. Its own packet's cells and the cell it stands on stay open. A route made
  earlier that a newer packet's blocks cross is blocked and made again (sim.lua, reroute).

## Open

1. Leaves: closed, as any block (the scouts' tunnels, 2026-10-04). A route through a tree is not
   taken.
2. The scouts' rule - explore only under sky or a named tree - stays the scouts' (stage 6); the
   grid gives them `0` cells to look at.
