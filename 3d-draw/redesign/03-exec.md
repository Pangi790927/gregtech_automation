03 - the robot as a state machine: exec, status, status_fast
=============================================================

The user, 2026-10-05: "this sends a string, a ">^>>>v<<<<'place-block-char'" -- like chess
notation of sorts, so serialize an execution rather than tell it a simple path, so things like:
"go to the me and get those materials: ..." will be a set of exact commands that the robot does
at once, no thinking on the robot, simple state machine, do a status_fast command, that will
inform you of the state machine inside the robot, that's what the robot will be a state machine,
watchable and verifiable by the windows app server". And: "so dig, put, use, take, give, shift,
craft, charge, will all be serializable as the new command "exec", this way the robot will get 3
commands once in a while and be questioned once in a while, say 1s,5s, you decide".

And, 2026-10-05: "The robot will remember whatever he did, the pc will have a "history" command
with wich it will be able to download the last saved execution in case something stupid went on.
The robot and the windows-exe can both run the same robot in paralel, each "status_fast" giving
partial checkable information on the windows-exe side, with a complete synchronization at status
after executions, this way history will be used whenever a divergence occours ... some sort of
fixing will be in place for each kind of failure mode, but the c++ side will decide that, the
state machine on the robot will also have exact stopping paths, where it waits for the pc to view
it and fix it's stuckiness". On water: "no more wet step, the pc will be the only one to care
about it, he will hold the plan, the robot only executes, he doesn't care about water".

## The commands

| Command | Reply |
|---|---|
| `exec <id> <program>` | `ok` at once; the program starts |
| `status_fast` | `<id> <state> <op> <x> <y> <z> <facing> <energy> [why]`: one short line |
| `status` | the above, plus energy max, tool durability, uptime, memory, chunkloader, tanks, every slot `slot:name:meta:count`, and the results since the last `status` |
| `give_way <id> <program>` | `ok`; a robot waiting on another runs this program to let it pass, then goes back to the op it was waiting at (below) |
| `geo <x> <z> <y> <w> <d> <h>` | the geolyzer's hardness values for that box, relative to the robot (OC's `scan`; its size limit to be read from the jar), at once, between ops or idle. For scouts above all (the user, 2026-10-05: "a new command "geo" will be used to do geo scans from the pc, this will be usefull for scouts and I think their only needed additional command") |
| `history [<id>]` | the saved record of the last program (or that one): each op as done, with its result, the position and energy after it, and where it stopped |

## Two machines, one robot

The robot runs the program; the PC (the Windows exe) runs the same program at the same time on
its own copy of the robot.
- Each `status_fast` is a partial check: the op the robot is at, where it stands, its energy -
  against where the copy says it should be by then.
- At the end of a program a `status` is the full synchronization: inventory, tool, everything.
- Any difference is a **divergence**: the PC downloads `history`, finds the first op where the
  field and the simulation part, and the C++ side decides the fix for that kind of failure.
- The robot saves its record to a file after each op, so `history` survives a dropped link, a
  reboot or an unloaded chunk.

## The machine on the robot: no thinking, exact stops

- **States:** `idle`, `run`, `wait` (a step blocked by a creature or a robot, tried again every
  second), `halt` (an `h` op: waiting for the PC on purpose), `done`, `stop` (at an op, with
  why), waiting for the PC.
- **One op at a time, in order; the socket is read after every op**, so `status_fast` waits at
  most one op (about 1 s; longer only for a hard dig or a charge).
- **Every failure is an exact stop:** the op that could not be done is not retried, nothing after
  it runs, nothing is undone; the robot stands where it is, in `stop`, until the PC sends a new
  `exec`. The stop's why is fixed per op: `blocked`, `nothing-placed`, `not-dug`, `took 12 of
  64`, `no-energy`, ...
- **Water is the PC's.** The robot no longer checks for liquids; the PC holds the plan and the map
  and never sends a step into water it does not mean.
- **Digging: only the block it expects** (the user, 2026-10-05: "the pc will not send a dig where
  a robot path passes, so execution paths are presimulated by the pc beforehand, the idea is that
  the pathfinder will be allowed to pass two bots on the same path, but not to breake a block that
  another is in process of pathing through, so this is on the pc side, on the robot side, the
  robot will check that exact ids match, so a robot will only break a block that it expects, if
  it is not expected and a block for example blocks it's way, it will halt with error"). Every
  `x` names the block it is meant to break; the robot reads the block first (the geolyzer's
  `analyze`, one tick) and digs only on an exact match, else `stop`, why `not-expected <what is
  there>`. A robot, a player's chest, a guessed leaf that is ground: none of them match.
- **A block in the way of a step** is not dug either: `stop`, why `blocked <what is there>`.
- **Energy: a stop on the robot** (the user, 2026-10-05: "a no-energy stop, of course the pc will
  also try to simulate energy, but in the end the robot knows the reality and the robot will be
  given on an exec, the cost of it's path back to home, if it exceeds the curr-rewind +
  path-home-cost + some leway it stops and halts until a pc contacts it"). Each `exec` carries
  `$<cost>`: the energy of the way home from where the program starts. The robot keeps the
  rewind - its steps since the program started, a step undone by the next taken off - as an
  energy estimate only. Before every op, if energy < rewind x step cost + `$cost` + leeway, it
  stops, why `no-energy`. The PC simulates energy too; the robot's number is the real one.
- **The robot never finds its own way home** (the user, 2026-10-05: "the robot can't really know
  the path home, whatever paths he executed in the past are not necesarily also what is the
  fastest path home, so the pc will give it a "you are being pathed home now" and it follows the
  sent path when he accnoledges the fact that the pc knows it must go home, until then it simply
  wakes and sleeps until being sent home"). Stopped on `no-energy`, it sleeps until contacted
  (below: no waking to check), and runs nothing but a home program: `exec <id> $home ...`,
  the path the PC sends, which may run below the floor.

## Inside the robot: two coroutines, sleeping until contacted

The user, 2026-10-05: "can't you do this with coroutines on both, such that it can read and walk
at the same time, also such that it can safely sleep until contacted, not to waste energy just to
wake up". Yes, with one limit that is the mod's:

- **Two coroutines on one scheduler:** the executor runs the program and yields after every op;
  the listener answers `status_fast`, `status`, `geo`, `history`, takes a new `exec` or
  `give_way`. The scheduler is a single `computer.pullSignal` loop.
- **The limit: an op blocks the whole machine.** A move is a call that pauses the computer for
  its 0.4 s; no Lua runs on it meanwhile, in any coroutine. So reading and walking interleave op
  by op; they do not overlap. Nothing is lost: the internet card keeps what arrives, and queues
  the signal. A `status_fast` waits at most one op, and that is fine (the user, 2026-10-05: "a
  status fast should arrive even slower, especially because a status_fast should not interrupt
  the robot for much, it simply collects the status and sends it on the wire, no need to wait for
  it to arrive at the pc"): its line is built from what the machine already holds - no
  component call - and written to the socket without waiting for anything back.
- **Sleeping until contacted:** the internet card fires `internet_ready` when data arrives on its
  socket (OC 1.9.14's InternetCard$TCPSocket, read 2026-10-05). An idle, halted or stopped robot
  waits in `pullSignal` with no timeout, and wakes only on that signal - or, while `z` waits for
  charge, on a timer to read its energy.
- **What sleeping saves** (OC's config, read 2026-10-05): a robot costs 0.25 energy a tick while
  running, times `sleepFactor` 0.1 while sleeping in `pullSignal` or `os.sleep` - 0.025 a tick,
  0.5 a second. Waking every 5 s would have cost about 2% more than that; sleeping until
  contacted costs nothing extra.

On the PC the same shape: each robot's control is a Lua coroutine, all on one thread, woken by
its socket or a timer (the user, 2026-10-05: avoid threads "at least ... on the control paths";
`~/workspace/homeauto/core/` shows how).

## Creatures, and robots that meet (the user, 2026-10-05)

The user: "robot will wait for creatures and when a robot wants to pass in it's front by it's
own, a status_fast will detect kissing robots and make one of them give way, this will be a
command of the form: give_way "'exec'", this will be a set of commands for the robot giving way to
execute, such that it will let the other bot pass (btw, like ><^v moves, there will also be a
halt operation, this will tell the robot to wait for the server to come back and give it a
command, change execution, etc.)".

- **A creature in the way:** the step waits (`wait`, why `entity`) and is tried again every
  second; the program goes on once it is free. Nothing is attacked.
- **Two robots nose to nose:** both stand in `wait`, why `robot`, each facing the other. The PC
  sees it in their `status_fast` lines and picks one to give way.
- **`give_way <id> <program>`:** the chosen robot puts its program aside at the waiting op, runs
  the give-way program (say `+ h`: up out of the way, then halt), and when that program ends,
  goes back to the op it was waiting at. Ending in `h`, it halts instead; the PC, which knows
  where it stands, sends the rest with a new `exec` once the other has passed (say `- ...`).
- **`h`, halt:** an op like the steps. The robot stops on purpose and waits for the PC: a new
  `exec` replaces what is left, a `give_way` runs before it.
- To check in the OC jar before it is built: what `robot.detect` says for a robot in front
  (an entity, or a block), so `wait` can tell `entity` from `robot`.

## The notation

In `04-notation.md`: the ops, the palette, the energy header, and how a program parses.

## How often the PC asks

- While a program runs: `status_fast` every **1 s**, `status` every **5 s** and at its end.
- Idle robots: `status_fast` every 5 s, so a silent robot is seen within seconds.
- `history` only on a divergence.
- **How a `status_fast` is checked** (the user, 2026-10-05: "the exe will jut run it's internal
  simulated state machine up to status_fast's response, the idea is close to realtime checks with
  a final full sync at the end of an execution, execution that should take some time, maybe 30s,
  maybe more"): the exe steps its simulated machine to the op the line names and compares there,
  never against "now". A program is sized for about 30 s or more, so a handful of light checks
  and one full `status` cover it.
