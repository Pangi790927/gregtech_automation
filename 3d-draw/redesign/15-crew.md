15 - the crew: the builders at once, until the plan is built
============================================================

The user, 2026-10-06: "I want you to do the final crew setup and make it so that the entire build
runs, when it breaks inspect it fix it and patch it until the current plan is built". Until now a
crew ran one robot at a time (crew.chain, 10-live.md); here every builder works.

## The loop (`crew.run_all`, a coroutine of its own)

Every few seconds, and whenever a robot ends a packet:

1. **The plan made again** when the world changed (a packet ended, a block learned): packets.run
   on world.txt - what is done drops out of it (crew.is_done).
2. **A free builder** - linked, standing still, its copy agreeing, charged above the floor -
   **takes the next ready packet**: in the plan's order, its waits done, not one being worked,
   its box apart from the boxes being worked (as the sim's robots: a box and its neighbours
   are one robot's - dropped, see below). Gunter, the crafter, stays out of it.
3. **Its trip**, as crew.trip: what is missing taken, the packet, back. The items come from the
   interface, which holds one robot's stock at a time: **the interface is a lock** - held from
   the first config of a robot's takes to its last take, and again for its give-back; another
   robot needing it waits its turn (in its park, or where it stands).
4. **Charging:** under the floor (20,000), home to charge first (crew.charge).
5. **Home** when nothing is ready for it (10-live.md, "Then home").

## What the first live hours changed (2026-10-06)

- **Several packets a visit:** a free builder takes its next packet and up to three more ready
  ones whose items fit its free slots (crew.BATCH), all in one visit; those it keeps reserved and
  does next, their items already with it. What a robot holds counts against a bill.
- **The lock only at the station:** a robot needing items flies to its park, beside the
  interface, without the lock; it holds it for the hop to the spot and the takes - the flight
  across the village had held every other robot up (the user: "they are not working in
  paralele...").
- **No boxes kept apart:** the user, "they should not bother much with each-other when executing
  their work, the planner made sure that is ok to do"; and of their ways: "There are only some
  paths that need some special care, but beyond that they only need to not intersect their end
  path points and they can move near the destination either way, if for example all wanting to
  go at the station". So a way keeps off where the others will stop (an idle robot's cell, a
  running one's end), the cells others are about to dig or place, and a field's lock - nothing
  else.
- **Not faults:** no way there now (the others' work in the way), a dry run stopped by a robot,
  a packet with nothing to do now - set aside, or counted done, never a robot parked.

## When it breaks

- **A stop on a block learned** (blocked, not-expected): the cell into the map (learn_block,
  look_around), the robot's copy set right, the plan made again; the packet tried again.
- **Waiting on a robot** (`wait robot`) 12 s: robots waiting on each other, whatever they run,
  one gives way and comes back; one waiting long on something else gives way too; an idle one
  steps aside - 16-giveway.md (ASIMO and Dalek_Sec head on for good, 2026-10-06).
- **Anything else** - a stop not understood, a divergence, no answer: that robot parked as it is
  (not sent anything more), its packet back in the queue for another, and said - for the user
  and for me to inspect and fix (the user's rule: no robot left silent, robot-silence-is-urgent).
- **A packet failed three times**: left out, said; the rest goes on.
- **A copy a slot count apart** (it missed a take or a place) is not the world wrong: the robot
  is let finish and is the truth at its end (crewfix.leg). Dropped mid-packet, Dalek_Sec had
  built all of place 0 -1 5 unwatched, none of it written.
- **A builder stopped where no loop saw it** (the loop restarted under it): idle and diverged on
  a stop for a cell unknown, it looks round and is set right (crewfix.idle) - four slept so, the
  user: "pintsize sleeps". A look reads its results only once they came (they had not: every
  look learned nothing). The loop does not end while a builder is on a job of its own or a
  packet is only set aside.

- **Its slots read at every leg's end** (crew.read_slots): the poll had missed programs over
  between two polls, and legs were planned on old slots - "nothing selected", "took 0 of 3",
  "no slot left" (2026-10-06). The takes are counted again on them under the lock.
- **A packet its dry run refused never ran:** no step of it written (one a visit had been).
- **The lock kept while the robot's own program still runs**, a leg given up or not; a copy's
  take short while the robot went on is the copy's interface wrong, waited out like a slot count.

## What it needs from the plan

Every packet proven; the 30 held up by the nine stair stands (14-turn.md, "Left unproven") wait
for the user. The scheduler runs what is ready and says what is left and why.

## Two interfaces (2026-10-06)

The one interface held every builder in a queue; the user added a second, and chose: "Two
locks, either one" - each interface its own lock and spot, a builder takes whichever is free.
Where they are, how the ME's computer and the PC address each, how the two are told apart, the
locks and their one queue: 17-stations.md.

## What sank the crew (2026-10-06)

An hour of patches made it worse (the user: "One hour later the bugs are still not fixed, in fact
it seems to be worse"). The causes, under the patches:

- **The program stood still.** The loop made the plan again after every look round, and a plan
  holds the whole program 36 s: no link read, no status, no lock handed over. The watchdog then
  closed the robots' links as silent - their programs died "- idle" (the 74- and 77-step
  packets, blamed on their size). Now: the plan at most every crew.REPLAN_S while robots work;
  the watchdog takes the program's own still off every ask (robots.watch_round).
- **Two programs on one robot.** A second program sent while the first was on its way or
  running replaced it part way (machine.lua's exec): robot and copy apart - the four "ended at
  ..., its copy at its park". Now robots.run refuses one, "busy", and a leg waits for it.
- **A spawn that starts nothing.** vc.coroutine_spawn only queues the coroutine; run() takes its
  own reference once it begins, so a handle nobody kept could be collected first - the
  destructor's close() emptied the thread, and run() logged "Nothing to call, set_call() first"
  (../utils): the three trips that never began. The utils' own tests keep every handle; the
  user: "so I understand the core/tests keep a reference, then so should we" - every spawn goes
  through spawn.lua, which keeps it until its coroutine ends.
- **Patches over the copy.** "The robot is the truth" rules, resyncs by hand, packets left out:
  each hid a wrong map or copy, and the next failure grew from it. Fixes go through the crew's
  own sim (robot machines on simbot, the real crew code) before the live robots.
