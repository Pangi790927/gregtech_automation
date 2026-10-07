USAGE - how to do each thing the user asks, today
=================================================

Task first, then the commands; the why is in `redesign/` (implementation) and `docs/` (the older
Python notes). Asked for by the user, 2026-10-07: "is usage knowledge up to par, or is it burried
under implementation?". Keep this file to what works now; state and open work are in `TODO.md`.
Commands go to the running app: `python 3d-draw/ops/ask.py "lua <code>"` (`redesign/19-ops.md`);
Lua paths are from `3d-draw/`.

## A session starts

`TODO.md` (the state) -> this file -> what the task needs. Memory notes hold the user's standing
rules (no git, the camera is the user's, check each robot, solve or stop, sim before live).

## "Move the focused zone to what I'm seeing" - zones

- **The zone shown** is 3x3 chunks the app draws: `lua local z=require('view').zone return
  z.cx..' '..z.cz`. The user moves it (M map, arrow keys); Claude never moves the view or camera
  on its own.
- **The robots' work zone - "the focused zone"** - is `data/zone.txt`, one line `zone <cx> <cz>`.
  "Move the focused zone to what I'm seeing" = write the shown zone's `cx cz` there (note the
  old line first, to undo). Writing it when the user asks is not "moving the zone on my own".
- **What reads it, today:** the app at its start (the zone it opens on) and the M map, which
  reads it again each time M is opened (its red frame); the old Python scout tools (`zones.py`,
  `survey.py`) work in it. The new crew does not use it - its plans span any chunks.
- **Check:** read the file back; the user reopens M and sees the red frame on the zone shown.

## "Scan it" - what is there now (next session's subject)

- **Read-only, from a parked scout:** `ops/scan_box.lua` with BOX `{x0, x1, y0, y1, z0, z1}` and
  SCOUT (Tom_Servo or Cairol at the station; Pintsize has a geolyzer too). The geolyzer reaches 32
  blocks from the scout, 64 cells a call. Hardness 0 = air (exact), ~100 = water, else "a block",
  its kind unknown (noise about +-1). Results in SCAN.
- **Into the map:** `ops/scan_to_map.lua` (PLAN: a plan file, for what a solid cell is) - copy
  `data/world.txt` first. Against a plan: `ops/plan_diff.lua` says what is gone.
- **Not built in the new system yet:** mapping unknown terrain by moving scouts (redesign
  `08-order.md`, stage 6). The old Python way still exists: `survey.py`, `zones.py`
  (`docs/scouts.md`, `docs/map.md`). A block's kind: a robot beside the cell, `analyze`
  (`look` ops, `crew.look_at`).

## "Design X" - a new plan

- A design is a Python generator in `design/` (model: `design/village.py`) writing
  `data/<name>.txt`: one line a cell, `b x y z name meta shape facing`, robot coordinates; stairs
  as meta 0 with `facing` xpos/xneg/zpos/zneg and shape 6 for upside down; `minecraft:air` to dig.
- **Read the world as it is now:** `data/chunks/` and then its layers in `scripts/chunks.lua`'s
  order - `scouted.txt`, `built.txt`, `fixed.txt`, `world.txt`. village.py reads only chunks,
  built.txt and refused.txt: what the crew built since (all in `world.txt`) it would not see, and
  a script copied from it would plan over the village. Keep every cell of the other plans
  (`data/village.txt`, `house.txt`, `harbour.txt`) and `refused.txt` out of a new one.
- **Ask first** where it goes (a viewer marker, K) and whether something there already does the
  job - the village has a market hall (house D in village.py) and its square.
- Obey `docs/rules.md` before drawing: kept places (station, tunnels, walls), water never touched,
  lavender stays but under buildings, plants only on dirt/sand/farmland (every generator checks it
  before writing, as village.py's plants_on_ground). Materials: what the ME has now
  (`lua require('me').items()`, then `me.view`; `data/me-now.txt` is from 2026-10-04), what
  Gunter can craft (`scripts/recipes.lua`).
- To show it: add the file to `packets.plans` (live: `lua local p=require('packets')
  table.insert(p.plans, 'data/<name>.txt')`; for good, main.lua's PLANS and reinit.packets). The
  user reviews it in the app (H shows a plan) before anything is built.

## "Plan the build"

- Packets panel (**P**): pick the plan, **plan it** - the planner cuts it into packets and the
  proof fills each on paper (`packets.run`). Unproven ones list why (`packets.unproven`).
- Without touching the live plan: `ops/prove_offline.lua` (PLAN, and SCAN if a scan should count).
- Common whys: a stair's stand taken (`14-turn.md`: dig and put back), nothing to hold a block
  (`05-packets.md`: supports), a plant not on soil (`docs/rules.md`), a cell never scanned
  (`crew.look_at('<robot>', {x, y, z})`).

## "Simulate it"

Packets panel: **simulate the build** - the same packets and programs on the robots' copies; J
shows what is left of each packet, O the paths, speed x1..x256. **clear** it before the real
crew: it holds the pathfinder's grid (`crew.start` refuses while it is on).

## "Build it"

1. Materials: `lua return require('crew').short('G.U.N.T.E.R.')` crafts what is short and has a
   recipe, and names the rest for the user; one item: `crew.craft('G.U.N.T.E.R.', '<item:meta>',
   n, true)`. Gunter's grid slots must be empty (saw in 4, mattock in 16, pickaxe in hand).
2. The plan picked (`packets.pick`), the sim cleared, then `lua return dofile('ops/crew_go.lua')`.
3. Chunkloading: ASIMO, Pintsize and Baymax have no chunkloader. The user's instruction
   (2026-10-07): escort them - one or two chunkloading robots that only chunkload, staying by
   their work wherever it leaves the chunks in `data/chunkloaded.txt`, even at base; resting on a
   block rather than hovering, and taking them home with it when it goes to charge; the user does
   not want to think about them. TO BE BUILT first thing (`TODO.md`, Open 1). Until then they take
   only packets wholly in loaded chunks; `crew.NO_LOADER_OK` (allowed while the user is on) is
   not used any more.
4. Stop: `lua require('crew').run.stop = true`, then send home any robot left away
   (`crew.go_home(r)`).

## Watching a build

- A Monitor on the log, re-armed every 30 min while the crew works - the command is in
  `redesign/19-ops.md`. Every check looks at **each** robot:
  `lua local c=require('crew') local t={} for _,n in ipairs(c.BUILDERS) do local
  r=require('robots').by[n] t[#t+1]=n..' '..table.concat(r.sf.pos,',')..' '..r.sf.state..'
  '..tostring(c.jobs[n] and c.jobs[n].p.id) end return table.concat(t,'\n')`.
- Cadence after a stop or error: 1 min x3, 3 min x3, then 15 min. A silent robot is checked at
  once. What a log line means and what the crew does about it: `redesign/15-crew.md`.

## Something broke in the world (a fire, a hand)

The cabin, 2026-10-07: scan the box -> `plan_diff` -> `scan_to_map` -> plan -> simulate (the
user watches) -> build -> scan again and diff. Drop what cannot be built only on the user's word.

## A robot is lost, misplaced, or placed back by hand

`crew.locate(robots.by['<name>'])` matches its six looks to the map and sets it only on one exact
match; the crew loop does it by itself for a robot just started. Never move a robot whose
position is unsure. A silent robot: `robots.link('<name>', false)` then `true` (new zone).

## Code changed

`./main.exe --test` in `3d-draw/` (17 suites, the crew sim among them), then
`ops/crew_reload.lua` (or `ops/relink_idle.lua` for robot code). robots/relay/me/copy: an app
restart, by the user.

## Finding more

- The API of a module: its header, `WHAT THIS FILE OFFERS` - `grep -n "^-- |" scripts/<mod>.lua`.
- The control port's commands: `scripts/control.lua`'s header.
- Why something is as it is: `redesign/README.md` (the notes in order); the user's rules:
  `docs/rules.md`; a robot's parts and addresses: `docs/robots.md`.
