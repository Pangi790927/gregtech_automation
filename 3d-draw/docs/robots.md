# 3d-draw: the robots

Part of 3d-draw's design; the top, with the map of every sub-doc, is `../DESIGN.md`. The robots as
built, who they are and where they park, and how the PC drives them. Paths are from `3d-draw/`.

## The robot (built by the user, 2026-10-04)

Tier 3 case. Cards: internet card (the relay), wireless network card. APU T3, one memory T3.5
(two exceed the Assembler's complexity limit), Lua EEPROM, HDD T3, screen and keyboard.
Containers: upgrade container T2 holding the tank upgrade, disk drive (OpenOS from a floppy).
Upgrades: geolyzer, navigation, hover, inventory controller, inventory, battery, database. The
tank upgrade was later swapped for a crafting upgrade.

Not in the pack or not obtainable: the ME upgrade (no recipe in `config/opencomputers/`), the
angel upgrade and the MFU (the user could not get them). So:
- every block is placed against one already there; the simulator checks the build order for it;
- the robot cannot read the mini ME; a computer with an Adapter at the mini ME's interface does
  (`getItemsInNetwork`, safe on a small network), and the robot only takes items with `suck`.

## The roster

**The robots** (positions count from the start block, x east, y up, z south):
- **G.U.N.T.E.R.** (Gunter), `016db072`, the builder: parks on the start block (0 0 0), the
  charger east of it. Inventory 16, a pickaxe in its tool slot, crafting upgrade, database.
- **Cairol**, `956b836d` (4d783168 until 2026-10-04, when the user picked it up and placed
  it again: a new address), a scout: parks on top of the charger (1 1 0). Geolyzer,
  navigation, chunkloader (`setActive` answers whether it changed: false is "already on"),
  inventory 16.
- **Tom_Servo** (Tom), `0511bc18` (4bcc1e4c until 2026-10-04), the second scout, the
  same parts: parks under the charger (1 -1 0), over the water. The charger reaches only
  the start block, above it and below it: one robot each.
- **The builders** (builders.py's CREW), each parked at a charger of the station:

  | robot      | address    | park        | notes                                             |
  |------------|------------|-------------|---------------------------------------------------|
  | G.U.N.T.E.R.| `016db072`| 0 0 0       | crafts first (the saw in slot 4)                  |
  | ASIMO      | `f4470a27` | 2 0 -2      | was 2158408e; broken and put back 2026-10-04: its |
  |            |            |             | battery holds 20,500 now, not 40,500              |
  | Pintsize   | `a77c49f1` | 0 0 -2      |                                                   |
  | Baymax     | `a4c330bf` | 1 -1 -2     | was 2082496e; broken and put back 2026-10-04      |
  | Dalek_Sec  | `1bf71bda` | 1 1 -2      | new 2026-10-04, in Cortana's place                |

  Cortana (082fe759) is gone: broken by another builder's swing on 2026-10-04, her item
  despawned. A robot picked up and placed again gets a NEW relay address: find it with a
  reach to a prefix nobody has (the error lists the relay's computers), then `hello`/`analyze`
  round it to learn which robot and where.
  - **The mini ME's computer**, `9cdb8754`: an Adapter on the ME interface (1 0 1), a database
  upgrade in the Adapter's own slot.

## Energy

When its energy would not get it home with a margin (12 a block, 7 measured, plus 3000), the
robot goes home, waits at the charger until 95% full, and carries on; a charger that gives nothing
for a minute stops it (the user, 2026-10-04: areas will outgrow the battery). Still to come for
large areas: scanning from more than one place (the geolyzer reaches 32 blocks), and a map kept
in pieces rather than whole in the robot's 1 MB.

## The robot server: the PC decides, the robot does

The user, 2026-10-04, after the mapper ran out of memory holding the map: "I don't really see why
you need to hold data on the robot, it can be streamed back and forth". So the robot runs
`robot/server.lua`, a loop taking commands from the PC through the zone (`zone.wait`), and the
PC holds the map and the plans. `rlink.py serve <robot>` holds one open and takes batches on a
local port; `rlink.py do "move n" "swing d"` sends one; from Python, `rlink.Robot`.

- **Batches:** lines of `<id> <command> [args]`; each answered `ok`, `err <why>`, or `skip` once
  an earlier one in the batch failed, so a failed step never lets the next run blind.
- **Primitives only:** move, face, detect, analyze, scan, swing, place, use, the inventory, suck
  and drop, wait, charge; directions are the world's (n s e w u d).
- **What stays on the robot**, because the link can drop mid-flight: never into a liquid; its
  position, in `/home/3d-draw/pos.txt` after each step and reset when the charger is east of it
  (the only such place), facing read from navigation every time; the way home (its steps,
  back-and-forths taken off), and below an energy floor nothing that spends energy but `back`.
- **Globals do not reset between zones** on the robot: a `START` set for one run was still there
  for the next (2026-10-04). Programs take what run.py sets and clear it at once.
- The mapper and `exec.lua` came before it; new work goes through the server.

## Coroutines, not threads

The user, 2026-10-04: "how about you stop doing that and use asyncio instead?", and then: "same
with the scouts". builders.py, survey.py and name.py drive their robots through
`rlink.AsyncRobot`, each robot a coroutine on one asyncio loop. Every batch has a deadline
(`rlink.QUIET`, 120 s, plus 2 s a command; none for a charge, which the server ends itself); a
reply that does not come closes that link and raises RobotError, and the program reaches the
robot again. Before this, ASIMO stopped answering while it loaded, and its thread held its side of
the interface for good. `rlink.reach` attaches one computer at a time, because the relay refuses
a second attach while one is under way. Several scouts run from one program, joined by `+`:
`survey.py <scout> <box> --map M --park P + <scout> <box> --map M2 --park P2`. The blocking
`rlink.Robot` remains for `rlink.py serve/do` and quick checks.

## Facts it rests on (OpenComputers 1.9.14-GTNH, read from the jar and the pack's config)

- Geolyzer: `scan` covers up to 32 blocks away, at most 64 blocks per call, 10 energy per call;
  noise up to ±2 at 32 blocks of vertical distance, growing linearly. `analyze` reads adjacent
  blocks only, and needs `allowItemStackInspection` (true in the pack's client config; the
  server's is still to be read).
- Robots: 15 energy per block moved, a 20000 buffer without batteries; without a hover upgrade
  at most 8 blocks above ground, 64 / 256 with tier 1 / 2.
- `robot.fill` toward air places a real source block (fluid placeable in the world, at least
  1000 mB, the spot air or replaceable); `robot.drain` takes fluid blocks or from tanks.
- Tier 3 robot slots: cards T3, T2, T2; CPU T3; memory T3 ×2; EEPROM; disks T3, T2; containers
  T3, T2, T2; upgrades T3 ×3, T2 ×3, T1 ×3.
