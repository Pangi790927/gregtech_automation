redesign/ - 3d-draw started anew
=================================

The user, 2026-10-05: "ok, so we will start anew , the pc side will be controlled by a something
akin to ~/workspace/math_editor and the idea is that we will make the substantial parts c++ (also
the one that will compute paths and such) and the logic part in lua". And: "we will get ridd of
python and port or drop things, you will write a redesign/ dir where we will note all the
changes before you do them, 12000 lines is a lot and I think that's why everything grinds to a
halt".

The rule of this folder: a change is written here first, read by the user, and only then made.
Nothing in the Python system is deleted until the user has walked through it.

Assumed, to be confirmed: "math_editor" is `~/workspace/math_writer` (no math_editor exists on
this PC) - C++ on `../utils` (virt_composer), the logic in Lua.

## The notes, in order

- `01-protocol.md` -- the language the robot and the PC speak today, layer by layer, and what of
  it the new PC side keeps
- `02-commands.md` -- the robot's 28 commands today, and who on the PC uses each
- `03-exec.md` -- the robot as a state machine: `exec` (a serialized program), `status`,
  `status_fast`, `give_way`, `geo`, `history`; stops, energy, coroutines, polling
- `04-notation.md` -- the program's notation: steps, ops, palette, energy header
- `05-packets.md` -- work packets: the plan cut into 5x5x8 boxes, ordered, one robot each
- `06-pc.md` -- the exe: C++ for world, planner, paths, robot copies, link; Lua coroutines for
  the logic; one exe with the viewer
- `07-inventory.md` -- every file of the old system: covered, open, or dropped
- `08-order.md` -- the order of work: skeleton, robot, link, copy, planner, crew, the rest

## The direction (from the user's words; details come as notes above)

- **C++ on the PC** for what is heavy: the map, paths, sectors, the sim's world.
- **Lua on the PC** for the logic: what a builder or scout decides to do next.
- **Lua on the robot** stays thin: it does commands and keeps itself safe.
- **The PC simulates each robot** and sends batches only after they ran clean on its copy; the
  robot's `status` checks the copy (`02-commands.md`). The same simulator makes the app testable
  and gives the viewer what the robots are about to do.
- **No threads on the control paths: Lua coroutines** - the user, 2026-10-05: "~/workspace/homeauto
  has an example of mixing lua with coroutines, thing that should help this project avoid
  threads, which are a pain (or at least avoid threads on the control paths, those will be much
  better used in c++ to simulate the drones, such that pc side will be verry fast and schedule
  say 20 block places at a time)". To read before the PC loop is designed:
  `~/workspace/homeauto/core/` (CURR_DESIGN.md, home_composer.h).
- **Python goes**: each of its files is ported, folded into another, or dropped - noted here,
  file by file, before it happens.
