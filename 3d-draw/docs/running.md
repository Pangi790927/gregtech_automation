# 3d-draw: how the work is run

Part of 3d-draw's design; the top, with the map of every sub-doc, is `../DESIGN.md`. Who watches the
robots, and the one zone they all work in. Paths are from `3d-draw/`.

## Who watches what

**Who watches what** (the user, 2026-10-04: "you can launch parallel agents for the 3 tasks
... building, scouting and designing"; "why is there no agent monitoring the scouts?, why is
there no separate agent monitoring the build?"): one standing background agent for the scouts,
one for the builders, one for design; main relays the user's questions. The robot agents keep
their robots busy (a job killed at the 2-hour background limit is started again), treat a robot
gone quiet as urgent (a broken robot's item despawns in 5 minutes), probe efficiency at random
(an action taking 4x what it should is a fault to find and fix: "if the robots do things that
are 400% ineficient, maybe come up with a strategy to fix it"), and track the crew's working
share ("if 1/5 of the team works, maybe there is something wrong with the build process").
Every change to robot logic passes sim.py before it goes live.

## One zone at a time

**One zone at a time, all robots in it** (the user, 2026-10-04: "he should stay in the same
3x3 with gunther and cairol, we only work in one 3x3 at a time"). Two scouts split the zone
(Cairol the west half, Tom the east), each on its own copy of the zone's map
(`data/map-cairol.txt`, `data/map-tom.txt`), saved into the chunks with
`zones.py save <its map>` when done: two programs on one map file save over each other.

## Probing the builders, and their working share

- `data/actions.log` (builders.py): one line an action - time, robot, action (place, helper,
  till, clear, breakin, load, look_over, go, charge, idle, side, robot, release, ended), cell,
  seconds, batches, moves, a go's Manhattan length, how deep in another action, a note (a load's
  items and what it went for, a look-over's cells read against needed).
- `probe.py` reads it: the working share (placing, helpers, tilling, clearing, breaking in,
  with the go to the stand each needs) against idle (no sector), waiting for a side or a robot,
  loading, looking over, travel; and what is 4x what it should cost (a go's moves against its
  length, seconds a block, a load's seconds an item, a look-over's cells, waiting against
  working). `--random` probes one robot in a random 20 minutes, as the watcher does every 10-20.
- `crew_watch.py`: the crew's alarms - the loop frozen 2 minutes, a batch unanswered 2 minutes,
  a builder ENDED, no block placed for 10 minutes, a working share under 60% over 30 minutes
  while more than a sector's work (70 blocks) is left. Near a plan's end, with fewer blocks than
  five can share (the lighthouse's 51 in one sector), idling is expected and not a fault.
- `sim.py` runs on a simulated clock (asyncio's, jumping to the next timer): a command takes the
  robot delays of the pack's `OpenComputers.cfg` (move, turn, swing, place, use 0.4 s; suck,
  drop 0.5; the charger 100 a tick), a batch 0.3 s more for the relay; so its working share and
  the crew's time compare before and after a change. On the harbour's last 145 blocks, 2026-10-04:
  31 moves a block and 14.0 minutes before the sectors were cut small, 23 and 9.7 after.
