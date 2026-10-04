# console — the base's OpenComputers computers, reached from the PC

Asked for by the user on 2026-09-30 and reshaped the same day, several times. What is decided,
what it rests on, and how it is checked.

This file is the top of the console's design: what it is, its agents, and how Claude uses it. The
rest is in `docs/` (the map below); each agent has its own `DESIGN.md` in its folder.

## What it is

```
computer: octerm.lua (stage 1)  --TCP 7777-->  relay.exe  <--127.0.0.1:7778--  connectors:
          + octerm_ext.lua (stage 2)           (PC)                            term/term.exe
          + zones (term.lua, claude-oc.lua, ocscp.lua)                         claude-oc/...exe
                                                                               ocscp/ocscp.exe
```

- **octerm.lua, stage 1** (under 256 lines at 80 columns, the user's limits; 154 now), is the only
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
- **relay.exe** (PC), or **relay** on the server (`docs/install.md`), knows only each computer's
  address, and forwards: a connector attaches to a computer and gets a channel on it, and the relay
  wraps what it sends into `D` frames on that channel without looking inside. Several connectors may
  use one computer at once. A connector leaving is told to the computer (`G`). Ctrl+C in the relay's
  window stops it all.
- **Trust:** the computer runs whatever the relay and connectors send. Connectors reach the relay
  from this PC only: on 127.0.0.1, or, with the relay on the server, from the `pc` address alone
  (`--allow`, and the server's firewall). Only the computers reach the computer port. A private
  server with about three players, where the user does the programming (their words).
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
- **`claude-oc/`**: claude-oc.exe + claude-oc.lua + claude.lua: a `claude` program on every
  computer, answered by the user's own Claude Code on the PC, one session per computer whose
  only tools are that computer, and mail between them. `claude-oc/DESIGN.md`.
- **`ocscp/`**: ocscp.exe + ocscp.lua, copying one file between the PC and a computer, no
  window; the way Claude reads a file the user names on a computer. `ocscp/DESIGN.md`.

Adding one: a folder `<name>/` with `<name>.cpp`, its payload and `DESIGN.md`, its name in
`AGENTS` in `windows.makefile` (it builds `<name>/<name>.exe` there, beside its payload), and a
line here. `connector.h` does what every connector does (reach the relay, pick a computer,
attach, open the zone from the cache or with the code); an agent gives it its own parts as
functions. Shared by all, at the top of `console/`: `protocol.h` (frames, every zone's too),
`connector.h`, `keys.h` (the PC keyboard's keys as OpenOS's), `net.h`, `screen.h`, `relay.*`,
`octerm*.lua`, `tests.cpp` (every agent's tests too), `conhelp.cpp`.

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

## The sub-docs (`docs/`)

- `docs/install.md` -- building, running and installing it, the firewall; the relay on the
  server; the checks.
- `docs/facts.md` -- the facts it rests on (OpenComputers' address filter, the socket's ticks,
  OpenOS's windows, processes and hard interrupt, the relay's log) and the known gaps.
