17 - two ME interfaces: a station each, a lock each
===================================================

A part of 15-crew.md ("Two interfaces"), split off for length. The one interface held every
builder in a queue; the user added a second, and chose: "Two locks, either one" - each interface
its own lock and spot, a builder takes whichever is free.

## Where (robot coordinates = world - (255, 63, 139))

| station | interface (ae2fc:fluid_interface) | spot, facing | around it                     |
|---------|-----------------------------------|--------------|-------------------------------|
| 1       | (1,0,1), world 256 63 140         | (0,0,1), e   | the transposer below (water)  |
| 2       | (1,1,2), world 256 64 141         | (0,1,2), e   | the adapter below, drive above|

Cairol stood on (0,1,2) and looked: east of it, the interface (2026-10-06). The water's path -
the transposer and the tank under the first interface (13-farm.md) - stays the first's.

## The ME's computer, one database for both

robot/me_machine.lua names the interface for a command: `at <addr> <command> ...`; the plain
commands stay on the first component (`component.me_interface`). OC's setInterfaceConfiguration
stores a copy of the database's stack into the interface's config (DriverBlockInterface.getStack,
UpgradeDatabase.getStackInSlot returns `ItemStack.copy()`; read from OpenComputers-1.9.14-GTNH,
2026-10-06), so one entry serves both in turn; it pauses the computer 0.5 s a slot. Each
interface has 9 config slots (AE2 rv3 DualityInterface.NUMBER_OF_CONFIG_SLOTS). `ifaces`
(read-only) answers each interface's address and its 9 slots' configuration.

## The PC (scripts/me.lua)

- **A station each:** {interface cell, spot, facing, address, stocked, to clear, lock holder}.
  `me.config(slots, st)`, `me.later_clear(slots, st)`, `me.flush(st)`; a station whose address
  is known is named with `at`. The first with no address known takes the plain command, as
  before; the second is used only once its address is known (`me.open()`).
- **Telling them apart, read-only:** which address is which cannot be read off the components.
  At link time `ifaces` is asked only to list them. Right after a robot at the first spot took
  what the first station stocked - its takes ended done, so that stock was in the interface in
  front of it - `ifaces` is asked again (`me.learn`): the interface configured exactly as the
  PC stocked it (every other slot empty), the other not, is the first station's. Anything else
  - nothing stocked, both alike, not two, an older me_machine.lua without `ifaces` - decides
  nothing: only the first station is used, and the crew's log says why. Three tries a link.
- **Read again in place:** `lua dofile('scripts/me.lua')` (or `reload me`) keeps the module's
  table - the link, the view, the stations, what is stocked - so every holder goes on.
- **`me.relink()`:** the link opened anew (me_machine.lua read again) in its turn, holding it
  meanwhile; the robots' asks wait for it (up to 120 s - two stations queue more asks).

## The crew (scripts/crew.lua)

- **A lock per station, one queue for both:** a robot waiting waits for either and takes the
  first let go of; with both free, the nearest spot. FIFO as before (crew.me_queue). The first
  station's holder stays `crew.me_owner` (an older crew's trip after a reload reads it); the
  second's is kept on the station in me.lua. A trip of this crew marks its job (`j.any`); an
  older crew's waiter is handed only the first. `lock_me` returns the station and still ends
  with `giveway.settle`.
- **Everything at the station it got:** the give-back rounds, the rounds of takes, the packet's
  start from that spot, the way home from it, Gunter's crafting; the copies' world holds one
  container per interface, so two robots take at once (`interface_in_copy(stocked, st)`).
- **Known to the map:** each station in use has its interface solid in the pathfinder's grid -
  the second was air there, and Cortana's way to its spot went through it (2026-10-06).
- **Never standing on a spot:** none waits for a lock on any station's spot (Cortana stood on
  the spot waiting, and Baymax, holding the lock, could not reach it, 2026-10-06); a failed
  trip leaves any spot; a robot moved aside never stops on one (16-giveway.md, kept off).
- **The hop to the spot:** kept off the cells the other robots' copies stand in (the dry run is
  made in the copies' world), and a dry run refused `wait robot` is tried again under the lock,
  the way planned anew, 10 times 3 s apart - "taking, round 1 did not dry-run: wait robot" had
  sent the robot to the back of the queue: 26 packets started, 4 finished, Cortana waiting ~30
  min (2026-10-06).

## The ways from the parks (the grid, read 2026-10-06)

To the second spot the column x 0, y 1 is open from z -2 to 2 and crosses no park (Gunter's
(0,0,0) is under it); every park reached it. The first spot is reached from above (0,1,1), from
below, from (0,0,2), or through Gunter's park, which a way avoids while he stands there. No park
moved.

## Left as it is

- Which interface is which is not kept across a restart of the exe: learnt again at the first
  takes at the first station.
- A give-back's way home found empty ("") leaves the robot on the spot, as before two.
