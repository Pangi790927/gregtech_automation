10 - live: the plan's packets on the real robots
================================================

The user, 2026-10-05, of the steps to a real build: "go ahead with steps 1 and 2" - one real
robot driven from the plan, its blocks loaded by hand. Stage 5's "then live: one robot, one
packet, the user watching" (08-order.md). The crew of five comes after; the ME, energy trips and
the stairs' way are later steps.

## One packet, by command (`scripts/crew.lua`)

`crew <robot> <packet>` over the control port (or `crew.start` from `lua`): the robot takes that
packet, only when all of this holds - else nothing is sent, and why is said:

- **The packet is proven** and every packet it waits on is done for real (`crew.done`, kept in
  `data/crew-done.txt`). Packets done by hand or before are not known: the first ones taken wait
  on nothing.
- **The robot stands still:** linked, its last `status_fast` not `run` or `wait`, nothing queued
  for it, not diverged. The program starts from where the robot is, so that must be now - Tom's
  `go`, sent while he still flew, ran from two steps back (2026-10-05).
- **Its slots hold what the packet places,** read from its full status (`inv ...`); else the
  bill - each block and how many - is shown, for the user to load. For digs, free slots for the
  kinds dug (a stack of 64 each).
- **Routes keep off the other robots:** the cell each other linked robot stands in, and the
  cells of packets other robots are working, are blocks for this program's routes (09-paths.md).
  Parked robots too: Cairol waited behind Gunter's park for good (2026-10-05).

Then the program (programs.lua) is dry-run on the robot's copy and sent (robots.run, as `go`).

**The simulation and the real robots, never at once.** Both use the one pathfinder grid, and the
copies read it beyond the zone shown: a sim started while Gunter dug reloaded it, proved on it
and wrote its simulated blocks into it, and his copy met one ("blocked map:block") where the real
Gunter went on (2026-10-05). `crew` refuses while the sim is on; the sim refuses to start while
a real robot has a packet. `sim clear` reads the grid from the files again, built.txt with it.

## Following it, and the end

The link already asks `status_fast` every 5 s and the copy follows each one (03-exec.md). The
crew looks at the robot's state each second:

- **done, and robot and copy agree:** the packet is done. Its cells go into the pathfinder's
  grid, the copies' world, and `data/built.txt` (`x y z name meta hardness built <plan>`, world
  coordinates; a dug cell as `minecraft:air`), so the map knows them from then on;
  `crew-done.txt` gets its id.
- **stop, or the copy diverged:** nothing is assumed; the copy follows a stopped robot only up
  to the op it stopped at, never past it (else it changes the copies' world where the robot did
  not: Pintsize's copy dug a packet she never reached, 2026-10-05). The robot stays where it is, why is shown,
  and the cells of the steps it finished (the op it stopped at, through the program's opstep)
  are written as above; the rest of the packet waits for the user. Once the user has looked,
  `crew.resync(robot)` sets its copy where it really is and clears the divergence.
- **Then home - only when nothing follows:** a robot whose packet is done flies back to its park
  (robots.ROSTER), routed off the others, dry-run - when it has no next packet. The user,
  2026-10-05, of Gunter left at the field's edge after the first packet: "take gunther back,
  you've left him in the middle of the field"; and of a chain of packets: "a bot doesn't return
  home after each work packet, right?". In a chain (`crew.chain`) it goes from one packet
  straight to the next, through the interface only when it must: to take what a place packet
  needs, or to give back when it has not the room for the next. A robot that stopped stays:
  why comes first.
- **What a dig drops is the game's:** grass gives dirt, tall grass now and then seeds, a robot's
  copy cannot know. After a program with digs the copy takes the robot's slots as they are; the
  slots are compared one by one only after programs without digs (Gunter's `dig 0 -1 2`, its
  4 sand called a divergence, the trip stopped in the field, 2026-10-05).
- **What a stop teaches:** a robot stopped "blocked X" on a step, or "not-expected X" at a dig or
  a check, named the block in that cell itself; the crew writes it into the grid, the copies'
  world and `data/scouted.txt` - the cell the op's direction points at, not the robot's facing -
  re-plans on the corrected map and goes on (`crew.chain_to`), a few times at most. A dig that
  finds air is done, not a stop: air is what it was to leave (the crown over the field, mapped
  wrong both ways, 2026-10-05); any other block than the one named still stops it.
- **Never dug:** Thaumcraft's invisible blocks (`Thaumcraft:blockAiry`, an aura node): a robot's
  swing leaves one ("not-dug"), and a node is not the robots' to break. A cell the plan wants as
  air that holds one is taken as done; routes go round it.
- A robot silent for 15 s is the link's watchdog's (robots.lua) - and the user's at once.

## Open

- The crew of five: the sim's take / notnow / reroute on real links.
- Programs carry `$0`: the energy floor is not real yet (step 4). Chunks: Gunter's chunk loader
  is off; packets near the station are loaded with the base.
