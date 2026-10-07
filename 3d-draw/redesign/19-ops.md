19 - running it: the app, its control port, the crew, the checks
=================================================================

How Claude runs the base from the PC, as it is done since 2026-10-06 - written down so the next
session starts here, not in a scratchpad that is gone (the user, 2026-10-07: "make sure ... the
paths to documentations are updated and that you include the status the workflow"). What is still
to do, and the state of things, is in `../TODO.md`; each task, from the user's side, in
`../USAGE.md`.

## The app and its port

- **main.exe** in `3d-draw/` (built with `make`; a running exe must be closed before linking) is
  the viewer, the crew, the copies and the link to the robots, in one. The user starts it; its
  working directory is `3d-draw/`, so every path below is relative to that.
- **The control port**, 127.0.0.1:7790 (`scripts/control.lua`): `python 3d-draw/ops/ask.py
  "<command>" ...`, one argument a command. `lua <code>` runs Lua in the app and returns what it
  returns; `robots`, `ask <robot> <cmd>`, `run <robot> <program>`, `reload <module>` - the list
  is in control.lua's header. Long work goes on a coroutine (`require('spawn')(function() ...
  end)`) with a global to poll; a `lua` answer must come back in seconds.
- **Reloading without a restart:** `lua return dofile('ops/crew_reload.lua')` reads crew,
  programs, crewfix, planner, prove, orient and simbot again while trips run, and rebuilds the
  idle robots' copies (`ops/fresh_copies.lua`). robots.lua, relay.lua, me.lua and copy.lua hold
  sockets and copies: they need an app restart (`../TODO.md` says if one is pending).
- **Robot code** (`robot/machine.lua`) reaches a robot only when it links again:
  `lua return dofile('ops/relink_idle.lua')` relinks each builder once it is idle (RELINKED).

## The crew

- **The plan** is the packets panel's pick: `packets.plans` / `packets.pick` - none proposed
  since the village was built (main.lua's PLANS; a new design is added there and live with
  `table.insert(require('packets').plans, ...)`). The loop makes the plan again itself.
- **Start:** `lua return dofile('ops/crew_go.lua')` - `crew.run_all` over the five builders
  (RESTART, `crew.run.note`, `crew.run_result`). It ends by itself: "nothing more can be done now".
- **Stop:** `lua require('crew').run.stop = true` - no new packets; trips running finish. It does
  NOT send them home: afterwards `crew.go_home(r)` each one away from its park (forgotten once,
  ASIMO and Pintsize left at the cabin, 2026-10-07).
- **Builders with no chunkloader** (ASIMO, Pintsize, Baymax - their upgrade container is tier 2):
  they take a packet only where every chunk of it is in `data/chunkloaded.txt` (the user's map).
  The user's way (2026-10-07): escorts - one or two chunkloading robots (Dalek_Sec, Cortana; an OC
  chunkloader keeps the 3x3 chunks round its own robot) hover over their work; to be built
  (`../TODO.md`, Open 1). `crew.NO_LOADER_OK` is not used any more.
- **A robot just started** (placed back by hand) is located by its six looks against the map
  (`crew.locate`) before anything is planned round it; a robot's position is set only on a single
  exact match (`setpos`), never by guess - and checked by a look after.
- **One packet:** `lua return require('crew').start('<robot>', '<packet id>')`; why a packet
  fails its dry run: `lua ID='<id>' return dofile('ops/dry_one.lua')`.

## Watching it

- **The log:** `data/crew-log.txt`, one line an event. The watch is a Monitor on
  `tail -n 0 -f 3d-draw/data/crew-log.txt | grep --line-buffered -v "could not take" | grep
  --line-buffered -E "NOT|done|sets off|giving back|broke|ERROR|error|stop|parked|no way|looked|
  nothing more|located"`, re-armed when it expires (30 min) while the crew works.
- **Each robot, by itself, on every check** (the user: "make sure you check them next time"):
  position, state, job and phase, energy, what it holds - `crew.jobs`, `robots.by[name].sf`. A
  robot standing still with work ready, or silent, is looked at at once.
- **Packets nobody takes:** their waits (`p.waits`), holds (`crew.run.notnow`), reservations
  (`crew.run.reserved`), refusals (`crew.run.refused`). A chain of waits is the plan's shape (a
  deck, then walls on it), not a fault.

## Checks before the robots

- **Tests:** `./main.exe --test` in `3d-draw/` - 17 suites, the crew's own sim among them
  (`18-crewsim.md`). Every failure met gets a test with its fix; the sim passes before live.
- **The app's simulation** of the plan picked: the packets panel (P), "simulate the build" - the
  same packets and programs on copies; the user watches it before a new kind of build.
- **What changed in the world** (a fire, the user's hand): `ops/scan_box.lua` (BOX, SCOUT: a
  scout's geolyzer, read only) -> SCAN; `ops/plan_diff.lua` (PLAN) says what of a plan is gone;
  `ops/scan_to_map.lua` writes air / water / the planned block into the map (copy
  `data/world.txt` first); `ops/prove_offline.lua` proves the plan on paper; then the sim; then
  the crew. The geolyzer tells only air (0, exact), water (~100) and "a block" (noise ~+-1).

## Files the crew keeps (all in `data/`, gitignored)

`crew-log.txt` the log; `crew-done.txt` packets done; `crew-owed.txt` blocks dug and still owed
back; `world.txt` what the robots did and saw (appended; the map's top layer); `robots-pos.txt`
each robot's last place; `me-stations.txt` the two interfaces; `chunkloaded.txt` the user's map of
loaded chunks; `markers.txt` the viewer's markers (K) - read it when the user names a marker.

## Rules that bit (each in the code and docs where it bit)

- No agents; a problem solved at its root (sim, test) or the crew stopped (the user, 2026-10-06).
- The mods are the specification: a rule is read out of the jar before it is coded (OC 1.9.14,
  BoP, binnie in the user's instance).
- A stair whose stands are taken: dug and put back; wild leaves or a bush dug and left empty;
  never a pocket the robot cannot leave (`14-turn.md`). Plants only on dirt, sand or farmland,
  checked by every planner (`../docs/rules.md`). No way runs over another robot's park
  (`09-paths.md`). A planned block replaces water in its cell; water is never dug.
