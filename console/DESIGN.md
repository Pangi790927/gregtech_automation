# console — the base's OpenComputers computers, reached from the PC

Asked for by the user on 2026-09-30 and reshaped the same day, several times. What is decided,
what it rests on, and how it is checked.

## What it is

```
computer: octerm.lua (stage 1)  --TCP 7777-->  relay.exe  <--127.0.0.1:7778--  connectors:
          + octerm_ext.lua (stage 2)           (PC)                            term/term.exe, ...
          + zones (term.lua, ...)
```

- **octerm.lua, stage 1** (under 256 lines at 80 columns, the user's limits; 135 now), is the only
  file on the computer. It connects, says hello with the computer's address and the hash of the
  extension it has cached, and runs the extension the relay answers with: the code, or "use your
  cached copy" (`/home/.octerm/octerm_<hash>.lua`, the current hash in `octerm_ext`). When the link
  goes it waits 5 s and connects again, so restarting the relay needs nothing on the computer.
  `octerm stop` closes it.
- **octerm_ext.lua, stage 2**, lives on the PC beside relay.exe, which reads it anew for every
  hello: editing it needs no copying and no restart (the user's two-stage plan, done when the
  monitor's console pushed the loader past its limit). It holds everything else:
  - **The monitor**: rows 1-2 say `running: <address>` and `octerm stop to close`; the rest is a
    normal console, a shell in an OpenOS window below them, for which the monitor is two rows
    shorter. Its Ctrl+C is its own (the user's call). A shell that exits or is killed comes back.
  - **Zones**: named Lua code a connector sends at its start, each in its own thread, talking to
    that connector alone; cached by hash, so a connector offers the hash first and sends the code
    on a miss. A zone ends when its code returns or fails, when its connector leaves ("if you
    disconnect you lose the session"), or on terminate; its `on_close` cleanups then run. Zones
    get `zone.run(window, path)` to run a program as its own process in an OpenOS window.
    `list()` and `terminate(name)` are frames any connector may send.
  - **Containment**: Ctrl+C and Ctrl+Alt+C inside zones or the console never reach octerm.
- **relay.exe** (PC) knows only each computer's address, and forwards: a connector attaches to a
  computer and gets a channel on it, and the relay wraps what it sends into `D` frames on that
  channel without looking inside. Several connectors may use one computer at once. A connector
  leaving is told to the computer (`G`). Ctrl+C in the relay's window stops it all.
- **Trust:** the computer runs whatever the relay and connectors send. Connectors reach the relay
  from this PC only (127.0.0.1), and only the server reaches the computer port. A private server
  with about three players, where the user does the programming (their words).
- **Frames:** `protocol.h`, all layers; protocol 2 since the two stages (1 was the single-file
  loader, which a relay now refuses with the reason in its log). Built by hand in Lua: 5.2 has no
  `string.pack`. **Hashes:** FNV-1a 64 as 16 hex digits, computed on the PC only (the user asked
  for more than 32 bits); the computer only files code under them.
- **colib, no threads.** Each relay socket has one writer (`net.h`), since frames for it come from
  several coroutines.

## Agents

The connectors, each in its own folder with its payload and its own description (the user's
layout, 2026-09-30). Read an agent's description before working on it or using it.

- **`term/`**: term.exe + term.lua, a shell on the computer in a window on the PC; the way Claude
  uses a computer. `term/DESIGN.md`.

Adding one: a folder `<name>/` with `<name>.cpp`, its payload and `DESIGN.md`, its name in
`AGENTS` in `windows.makefile` (it builds `<name>/<name>.exe` there, beside its payload), and a
line here. Shared by all, at the top of `console/`: `protocol.h` (frames), `net.h`, `screen.h`,
`relay.*`, `octerm*.lua`, `tests.cpp` (every agent's tests too), `conhelp.cpp`.

## Installing and running it

- **Build (PC):** `make` in `console/`, from PowerShell (Scoop's make); it builds the agents in
  their folders. Git Bash's make rewrites `cl`'s `/flags` into paths; there it needs
  `MSYS_NO_PATHCONV=1 make`. A running exe cannot be overwritten (`LNK1168`): stop it first, or
  build only `make tests.exe`.
- **Run (PC):** `relay.exe` in one window, and it stays up; an agent (`term\term.exe`) in another.
  The user runs the relay; the link exists only while they do. Clicking into the relay's window
  starts a selection that pauses it (QuickEdit) until released.
- **Install (computer):** stage 1 (`octerm.lua`) once, then `octerm <PC's address>` once (`pc` in
  the repo's `config.ini`; the address is not in the repo), which it keeps in
  `/home/.octerm/relay`; from then on `octerm`. The extension and the agents' zones come from
  the PC. To replace stage 1 later while octerm runs:
  `python install_octerm.py` (it keeps the old one as `/home/octerm.old.lua` and restarts octerm
  by typing it in). When a report looks like an old version, ask what the monitor says:
  `running: <address>` / `octerm stop to close` is the current one.
- **Windows Firewall:** an inbound rule for TCP 7777 from the server only (`server` in the repo's
  `config.ini`; the network is Public). If Windows offers to let `relay.exe` through, Cancel:
  the rule is enough, and narrower.
- **Tests:** `tests.exe`, and any test of Claude's, use ports other than 7777/7778. A test on 7777
  once bumped the user's live session.

## Using it from Claude

When the user has the relay up with a computer on it, Claude may use that computer through the
agents with no further asking; the user opening the link is the permission. The user also
allowed updating octerm on it and testing it there (2026-09-30). The recipe, driving term.exe
with `conhelp.exe`, is in `term/DESIGN.md`.

- **If the link is down, tell the user; do not work around it.** That is: no `relay.exe` running,
  term.exe saying "no relay", the screen showing "No computer is connected to the relay", or the
  relay's log (`conhelp.exe read <relay pid> 30 120 <file> tail`) showing the computer left.
  Starting the relay or octerm is the user's to do.
- A one-off zone from a small connector (as `install_octerm.py` does) reaches what term.exe does
  not, such as the monitor's contents; `term/DESIGN.md` has what not to touch from one while a
  terminal is open.
- It is the user's live base. Say what will be typed before anything that changes files or
  machines, as with any action that is hard to undo.

## Facts it rests on

- OpenComputers filters by **address only, never port**: the host is resolved, coerced to an int
  by Guava's `InetAddresses.coerceToInteger` and range-checked (`Settings$AddressValidator`,
  `InternetCard$.checkLists`). Guava folds IPv6 into 224.0.0.0/3, `::` into 0.0.0.0.
- The server's `~/servers/gtnh/config/OpenComputers.cfg` blacklist (applied 2026-09-30, read back
  by request 001) is 127/8, 0/8, 10/8, 172.16/12, 224/3 and 192.168/16 minus the PC's address
  (`pc` in `config.ini`) as 16 ranges. Tested against Guava 17.0: only the PC's address and
  public addresses pass.
- The socket's `read`, `write` and `finishConnect` are not direct calls (their `@Callback` has no
  `direct=true`), so each waits a server tick. The loader writes only when something is queued,
  and reads on every round. Reading only after `internet_ready` (re-armed after every read, per
  the bytecode) still left keys about a second late on the user's server, cause not found;
  reading every round was the user's call.
- **Windows per process:** OpenOS's `term.internal.open(dx, dy, w, h)` makes a window, and from
  then on `tty.window` is `process.info().data.window` (`lib/term.lua`). A process's `data` falls
  back to its parent's (`lib/process.lua`), so a window set on a new process's own table
  (`process.load`, then `process.internal.continue`, as `sh` runs commands) is its and its
  children's. **Threads are not processes**: `thread.create` coroutines join their creator's
  process (`process.findProcess` looks through its instances), so zones and the monitor's console
  thread share octerm's data; their shells are processes of their own.
- OpenOS's hard interrupt (Ctrl+Alt+C, `lib/event.lua`) calls `process.info().data.signal`,
  which `boot/01_process.lua` sets to `error`, in whichever process is running. octerm's own
  `signal` ignores it when octerm (or a thread of its) is running; programs its shells start
  still die of it, and a shell killed by it comes back. It once ended octerm with
  "error: interrupted".
- relay.exe logs why each computer leaves, and connections that never said hello or speak
  another protocol. It ends a session whose other side is gone by waking its pending read
  (colib `stop_handle`): `shutdown` alone leaves that read waiting for a peer that may never
  close, such as a computer that rebooted.

## Known gaps

- A shell killed while running leaves its entry in OpenOS's process list.
- colib's Windows `connect` does not set `SO_UPDATE_CONNECT_CONTEXT`, so `shutdown` on a socket it
  connected fails with WSAENOTCONN. Reported to the user, not patched here; nothing relies on it.

## Checks

- `tests.exe`: screen operations, frames cut at every byte, the key table, the payload hash; the
  relay's own sessions over real sockets (the extension sent or left to the cache, channels kept
  apart, attach refused with `N`, `G` when a connector leaves, a computer leaving closing its
  connectors, protocol 1 refused, a reboot replacing the old connection, nothing left behind);
  then each agent's own session through that relay (their DESIGN.md says what). All on ports
  Windows picks, and all in one pool: destroying a pool with reads still pending corrupted the
  heap for the next test.
- Stage 1 and the extension, with term.lua, under a stand-in OpenOS in scratch (minilua, with
  processes, windows and shells that echo their own keyboard's keys): the hello and the cache,
  the header and the console on the monitor, `octerm stop`, a second start from the cache.
- On the user's computer (2026-09-30): installed with install_octerm.py, relay replaced, the
  extension sent; the monitor read back with its header and console; term.exe used through it.
