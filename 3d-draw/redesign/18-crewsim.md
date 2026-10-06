18 - the crew's sim: the live crew's code on simulated robots
=============================================================

The user, 2026-10-06, after an hour of live patches that made it worse: "build the crew sim
first". The older sim (sim.lua) has a scheduler of its own; the crew's code - crew.run_all, its
trips and locks, the two stations, the give-way, crewfix, robots.lua's links - had never run
anywhere but on the live robots. Now it runs in `tests/lua/test_crewsim.lua`, part of the suite.

## What is real, what stands in

- **Real:** crew.lua, crewfix, giveway, me.lua (but its computer), copy.lua, robots.lua's link
  loop (poll, full status, history, watchdog), and on each robot robot/machine.lua's own command
  loop, `M.serve(z, m)` - the same function the robots run - over a simbot body.
- **Stand-ins:** the relay connection (lines both ways, the zone opened on attach); the ME's
  computer (answers as me_machine.lua, ME_S slow, and keeps both interfaces stocked in the
  simulated world); the plan (rows of blocks at two sites, packets.run returning it).
- **Time** runs WARP (5) times faster: vc's clock and sleep are warped for every coroutine.
- **The program's stills:** each plan holds the whole program FREEZE_S real seconds (36 of the
  sim's, the longest seen live) while the robots' zones catch up after it - the robots did not
  stand still with the PC.
- **The map is wrong:** blocks the world has and the map does not (a wall two high across the
  way to one site), so robots bump, learn, look round, and the plan is made again.
- **The station is the field's:** both interfaces, every park as robots.ROSTER has it.

## It passes when

Every packet done and every block in the world; no robot parked, no packet left out; no copy
diverged and every robot where its status says, once all have settled home; no link closed by
the watchdog; at least three builders on a packet at once; the second station used. The report,
with the crew's whole log: test_run/crewsim-report.txt.

## What it does not catch (2026-10-06)

The watchdog closing links through a still, and two programs sent to one robot: put back, both
still pass the sim (its links read their answers before the watchdog looks; its senders never
overlap on a robot going two ways). Both are held by test_flight.lua instead.

## Found by it, first runs

- A stop on a block the map lacked counted as a failure: three bumps on an unknown wall left the
  packet out. Now a look round (crewfix), not a failure.
- The loop's end sent a second way home over one on its way (refused, "busy"; now skipped).
- "no way to the interface" now says who stood by the spot.
