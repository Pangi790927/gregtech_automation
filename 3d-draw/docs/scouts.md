# 3d-draw: the scouts

Part of 3d-draw's design; the top, with the map of every sub-doc, is `../DESIGN.md`. How the scouts
survey and name an area, and what stopped them. Where they may go: `rules.md`. Paths are from
`3d-draw/`.

## The scout and the survey

`survey.py` flies the scout over waypoints 10 apart, and at each scans the columns within 10
that the map lacks (`scan` is one column, up to 64 high: y -14 .. 17). Air reads exactly 0 and
water about 100, so those are certain; other blocks are guessed by hardness (leaves, dirt or
grass, stone, log) and marked guessed; blocks named before keep their names. It moves only
through air it has scanned, goes home to charge when the way back would need more than it has,
and saves the map after every waypoint. **A scan from home of columns 6-9 blocks away read air
next to water at the same height** (impossible: the water would flow); the scout's near scans
there found the river. Near scans are to be trusted, far ones checked.

`name.py` then names what the survey guessed: it flies to cells beside guessed blocks that air
shows and analyzes them, choosing the stop that sees the most for the way there (the nearest
alone made a stop a block). **A robot's link to the relay drops when its chunk unloads** (the
computer stops): Cairol's did twice at the zone's south edge. The long programs reconnect and go
on from where the robot says it is (its position file).

What stopped the scouts, and how it is met (2026-10-04, the user: "why are the scouts idling at
base when there is still un-prospected land"):
- **The geolyzer reaches 32 up and down** (OpenComputers' geolyzerRange). Flying high over
  higher ground, a scan down to y -14 asked for more, failed, and skipped the rest of its batch.
  The survey ignored that, so 9197 western columns read as "not reachable". `scan_around` now
  keeps each scan within the robot's reach, and prints the first failure it meets.
- **Ridges above the old scan top**: `survey.py --taller --y -14 49` scans again the columns
  whose known top was still solid, to the new top, so there is air over them to fly through
  (64 blocks a scan at most: -14..49).
- **The canopy**: a guessed block on the forest floor has air beside it, but that air is shut
  in by leaves, solid to a scout. `name.py --leaves` lets a way go through leaves, breaking each
  as the scout comes to it (the user allowed it for Tom, 2026-10-04).
- **No way home known** where a scout was stopped between two map saves (Cairol, 2026-10-04,
  at -82 22 -108): `go_charge` scans the air round it (`air_round`) and tries again. A scout's
  map must also hold home: a map exported for a far area alone left Tom no way out to it.
- **Where a scout may be** (`survey.Rules`; the user, 2026-10-04: "just map the terain, ok ...
  only allow it if under the sun or under a tree", and "in built know area you can pass under
  buildings, I don't care, but exploration needs sunlight"). Exploring - a survey's waypoint, a
  naming stop - needs known air with nothing above it but air, or leaves and logs the scouts
  NAMED (a guessed "leaves" may be ground). Travel may also use any known air in the known area
  (`KNOWN_AREA`, the work zone). `data/refused.txt` keeps everyone out of the tunnels the scouts
  dug that day; a scout found inside one gets its way out once (`Rules.pocket`). Leaves are
  swung at only when `analyze` toward them says leaves (`leaf_ahead`), and a scan round never
  spends the energy the way home needs (`home_cost`). Tests: scratchpad test_scout_rules.py.
- **The old scans' top along a ridge** (2026-10-04, Cairol, 2864 columns left past the
  mountain): columns scanned to y 49 where the ground reached 46-49, new ones beside them with
  air from 50 up - no step joined them, so the air over the mountain was an island. `--taller`
  now also scans again a column whose ground, or a neighbour's, is within 4 of its known top
  (`survey.taller_columns`).
- **The robot's own energy floor** (robot/server.lua: its trail home at 12 a step + 1500) is
  higher than the PC's guess after a winding run, and refuses analyze and scan too. name.py
  asked one stop again thousands of times, for an hour or more in every run that day; the
  survey dropped waypoints unscanned. Both now charge on `low energy` and go on (the survey
  does that waypoint again); a stop whose analyses all fail for another reason is set aside
  with the unreached, not asked again. Tests: the scratchpad's test_scout_rules.py (`Floor`,
  `Ridge`).
- **The chunkloader's `false`** is not a refusal: OpenComputers documents `setActive` as
  "returns true if active changed" (UpgradeChunkloader, read from the jar), so an upgrade
  already on answers false. `isActive` says whether it is on.
