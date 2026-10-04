# 3d-draw: speed

Part of 3d-draw's design; the top, with the map of every sub-doc, is `../DESIGN.md`. Why the
builders are slow: what a robot's call costs, read from the mod and measured (bench.py), and
where the crew's minutes went, read from `data/actions.log`. Asked for by the user, 2026-10-04:
"tell me the current marks of the bots and we must figure out why those are slow, so we will
analyze their speed and algorithms". Paths are from `3d-draw/`.

## What a call costs (OpenComputers 1.9.14-GTNH, the server's jar, read 2026-10-04)

The local Prism instance still holds 1.8.0.13 (GTNH 2.3.0); the server runs 2.4.0, whose jar is
in the CurseForge instance. What follows holds in both.

- A callback not marked `direct` is run by `Machine.update` at the server's next tick (the
  machine yields with a synchronized call): **one tick each**. A direct one costs `1 / limit` of
  the call budget (`callBudgets` 0.5, 1, 1.5 by CPU tier), refilled every tick; only a call
  over budget waits for a tick.
- `context.pause(s)` holds the machine `s * 20` ticks: a move, turn, place or use (0.4 s in the
  pack's config) is **8 ticks** with its own call (measured), a drop or suck 10. A move that
  fails pauses 0.4 s too.
- Not direct, a tick each: `robot` move, turn, detect, swing, place, use, select,
  inventorySize, drop, suck; `navigation.getFacing`; `geolyzer` scan, analyze;
  `inventory_controller` getStackInInternalSlot, suckFromSlot, dropIntoSlot;
  `filesystem.makeDirectory`; the internet card's socket read and write.
- Direct: `computer.energy`, `uptime`; `filesystem` exists, open (limit 4), write, close;
  `robot.count`, `space`. OpenOS's `fs.makeDirectory` asks `exists` first and returns.
- `robot.move` into a liquid is not blocked (`blockContent` gives `liquid` as passable): the
  detect before a move is what keeps the wet rule, and it costs its tick.
- `computer.uptime()` counts machine updates, one a tick, and `os.sleep` waits game ticks.

## Measured (bench.py on Pintsize, 2026-10-04 23:37) and the server's lag

| call or step                                   | ticks |   | call or step              | ticks |
|------------------------------------------------|-------|---|---------------------------|-------|
| robot.move, robot.turn                         | 8     |   | getFacing, detect, scan   | 1     |
| server.lua's step up/down (detect, move, read) | 10    |   | save(): makeDirectory..   | 0.3   |
| server.lua's step sideways (+ face()'s read)   | 11    |   | a turn in face() (+ read) | 9     |

The relay's round trip: 0.16-0.19 s. **The server runs at about 13 TPS**: the user's `/forge
tps`, 23:32, "Overall 13.067 TPS, mean tick 76.5 ms" (dimension 0 alone 44.3 ms); bench.py read
11.5, and 5.6-7.6 for a minute before. **Server lag is a 1.5x factor on everything** the robots
do: a step of 11 ticks is 0.85 s at 13 TPS against 0.55 s at 20. With 46% of moves up or down
and 0.14 turns a move (`data/live.log`), a move is ~11.8 ticks: 0.91 s - run 14's 0.90-0.95 s a
move, with nothing lost elsewhere. Pintsize's park has 2 cells of air over it (a block at 0 3 -2):
the moving phases ran 1 up; ticks are counted exactly whatever their number.

`python 3d-draw/bench.py <robot> [--n 10]` (`--plan` reaches nothing): only on a robot lent for
it - it refuses one whose server zone is open. It goes only up into the air over where it stands
and back, after a scan shows that air; no swing, no place; `data/bench.txt` keeps the tables.

## Run 14: where the builder-minutes went (22:10-22:59, 5 builders, 243 builder-min)

`python 3d-draw/probe.py --all`, cut by lease and by go. Placing and its walks: 19 min (8%).

| # | cause                                                          | builder-min |
|---|----------------------------------------------------------------|-------------|
| 1 | idle: no sector to lease - the tail, most blocks given up      | 100         |
| 2 | the depot lock held through whole walks                        | ~32         |
| 3 | lease cycles that placed nothing: 16 of 25 (load 11, look 12)  | 28          |
| 4 | the step: 11-12 ticks where a bare move is 8                   | ~12 of 41   |
| 5 | routes 1.40x Manhattan: 2570 moves for 1842                    | ~11         |
| 6 | waits for a side of the interface                              | 7           |
| 7 | places refused and tried 3 times: 81 of 159                    | 6           |

1. **Idle.** What was left was given up (stands that are ground), short in the mini ME, or too
   near a leased sector (GAP): the work had run out. A crew holding the next plan's sectors too
   would turn it into work; within one plan it is not to be had.
2. **The depot lock** was held for the whole batch when a way started or ended in the station:
   a builder walking 70 moves home held it 70 s, the rest waited even for one step (Gunter, 0 0 1
   to 0 0 0: 149 s and 161 s).
3. **Futile leases.** Loaded for (a trip home), walked to and scanned, and only then found to
   have nothing to build; four sectors 2-3 times, leased again on any change of a signature that
   settle() and the "missing" cells changed with nothing built.
4. **The step.** Two getFacing reads and a detect a step; save() costs a third of a tick.
5. **Routes.** 46% of moves up or down: lanes over the highest column of the whole rectangle
   between start and goal, so the lighthouse lifted trips that never passed it.
6. **Loads** went home first, and 3 of 13 trips were for 4 items or fewer.

## What was done (2026-10-05, the coordinator's go, through tests/gate.py)

- **builders.py.** The depot lock only on the leg of a way inside DEPOT, each locked leg routed
  once it is held (`step_toward`). SCAN_NEAR 12 -> 28 (the geolyzer reaches 32; its noise grows
  with height, not distance, `geolyzerNoise`); a dry `choose()` on the PC from the sector's
  lane (`feasible`) before any load, walk or scan, and a sector left so released at once; then
  the walk into the sector the look-over used to make (without it the gate placed 800 of 1500).
  A given-up sector leased again only once blocks were placed within RETRY. A flat way first up
  to FLAT (30) cells while not 1.5x the crow's way; lanes over the corridor flown, then the
  rectangle (`lanes`, `by_lane`). A load trip only for the sector's own blocks, or helpers'
  cobblestone and dirt when it holds none. A refusal's reason in actions.log's note, and a place
  refused not tried alike while the map at its cell and face is unchanged (`refused`).
- **Dry moves** (the user, 2026-10-04: "yes allow it, above water level, so water is mostly at a
  specific level (the river's level)"): RIVER, the highest water the map knows within 16 of the
  plan, found and printed at the crew's start; a move into known air above it, with no water
  known beside it, goes `move <dir> dry`, without the detect. At or below it the detect stays.
- **robot/server.lua.** Facing read once a batch and kept through turns that answered true;
  `dry`. Every robot that runs it must open its server anew to take it (rlink sends the code at
  each open): all five builders, the scouts if they use it.
- **sim.py** charges ticks, not the config's seconds: TICKS a command, TURN 8, a getFacing per
  READS (with `--facing-each`, the server.lua of run 14), at TPS 13 and a 0.18 s batch. A dry
  move into water goes in, as the robot would, is counted, and **fails the gate**; `--river N`
  forces the level.

## The gate's figures, before and after (sim.py at 13 TPS, seeds 1-3)

See the efficiency agent's report of 2026-10-05; to be kept here once the live runs confirm them.
