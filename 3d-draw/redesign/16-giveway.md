16 - robots that wait on each other: who gives way, and how
============================================================

A part of 15-crew.md ("When it breaks"), split off for length. The robot's side is 03-exec.md
("Creatures, and robots that meet"): `give_way <id> <program>` and `h`.

## The case (2026-10-06)

ASIMO, on its packet, stood at robot 0 6 22 waiting on a robot; Dalek_Sec, flying home through
x 0 y 6 northwards, stood at 0 6 23 waiting on a robot. Each waited on the other for good: the
machine tries a step blocked by a robot again every second, and the crew only ever moved an
idle robot with no job. Nothing looked at two robots that both run, nor at one running a program
outside a crew job (a way home, a give-back).

The user's words on ways stand: "There are only some paths that need some special care, but
beyond that they only need to not intersect their end path points and they can move near the
destination either way"; robots "should not bother much with each-other when executing their
work, the planner made sure that is ok to do". So the meeting is resolved where it happens,
not planned away.

## Seen (`giveway.tick`, every pass of the crew loop)

Every linked robot, whatever it runs - a crew leg, a way home, a give-back, a program sent by
hand. One in `wait robot` waits on the robot standing in the cell its op steps into (its copy's
op, the robot's position). Waited 12 s on the same cell (seen within ~15 s, the poll being 5 s):

1. **A ring** - it waits on one that waits on ... it: one of the ring gives way (below).
2. **On one that waits too, on something else, 12 s or more** (a creature, a charge, a robot
   further on): that one gives way to it, and comes back after.
3. **On one standing still** (idle, done, halted or stopped - not parked for inspection, its
   copy not diverged), on no crew job **or only waiting in the interface's queue** (not holding
   the lock): it moves aside a step and stays. Pintsize, third in the queue at her park, held
   Baymax's packet up for minutes (2026-10-06). Her trip reads where she stands once the lock
   is hers; `lock_me` first lets the move end and show in her status (`giveway.settle`), so no
   way to the spot is planned from the cell she left. A job in any other phase (at the spot,
   taking, giving back, looking round) counts on where it stands: not moved. A robot moved is
   not moved again until its status shows that move ended.
4. **On one running:** nothing; it is moving.

## Who gives way, in a ring

Of those with a free cell aside: the one **not on a packet** (going home, to the station, giving
back - only moving, nothing of the plan cut in two); else the **later in the roster**, as the
simulation has it (sim.lua). None with a free cell: said, and left to look at.

## How (`give_way`, on the robot and its copy both)

- **The cell aside:** beside it - across its line first, then up, then down - air in the map,
  no block to break; not under farmland's top (a robot stopping there tramples it, 13-farm.md);
  empty in the copies' world; no robot standing or ending there; no packet's cell being worked;
  and off every running or waiting robot's way still to go (its copy's ops from where it is,
  its stacked programs after). So the one passing never meets it again.
- **Out:** `give_way gw<n> $0 <aside> h <back>`: a step aside, a halt there, the step back
  after. The halt is inside the give-way program, so the robot shows `gw<n> halt` - not its own
  program halted, which a leg would read as its end (crewfix.leg: halt is a program's end at
  the interface).
- **Back,** once the other has passed (it stands neither where it waited nor where the giver
  stood, or it stopped running) or after 60 s anyway: `give_way gw<m> $0 f<facing>`, a turn to
  where it already faces - nothing - after which the halted give-way goes on: the step back,
  and then the op it waited at, its own program as it was (machine.give_way, the stack).
- **The copy in step:** first stepped to where its robot stands (the robot's op and cell, even
  within a step of many); given the same give-way once the robot said `ok`, and run to its halt;
  the same at the release, run until it is back in the robot's program. The one passing has its
  copy stepped to where it stands too, so the giver's copy does not step back into it. A copy
  that cannot step back yet is tried again each second, as the robot is.
- **The giver is no free builder meanwhile** (crew `still`), and a leg whose robot stopped in
  its give-way ends there, said, as any stop (it would else wait on its program for good).

## Left as it is

- `give_way` starts the robot's history anew (machine.lua's begin): after a give-way, `history`
  holds the give-way and what came after, not the program's first ops. Robot-side; not changed.
- The simulation keeps its own unjam (sim.lua, `+ -` without a halt): there the steps are taken
  in a fixed order, so the step back cannot beat the one passing.
