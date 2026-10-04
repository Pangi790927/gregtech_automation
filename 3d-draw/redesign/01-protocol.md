01 - the language between the robot and the PC
===============================================

What exists today (2026-10-05), read from `robot/server.lua`, `rlink.py` and
`console/protocol.h`. Three layers, each inside the one before.

## Layer 1: the pipe - robot to relay to PC (console/, C++ and Lua, not 3d-draw's)

The robot runs `octerm.lua` (the loader). It opens a TCP socket with its **internet card** to the
**relay** (`console/relay.cpp`) and says who it is: `'H' version address hash`. The relay sends
it `octerm_ext.lua`, the extension, and from then on carries bytes in channels:
`'D' channel:u8 n:u16 bytes[n]`.

The PC (today `rlink.py`; before it `term.exe`, `claude-oc.exe`) is a **connector**. It connects
to the relay on port 7778, gets the list of computers there (`'L'`), and attaches to one
(`'A' address` -> `'Y'`). After that the socket is a channel to that computer, both ways.

All numbers are big-endian, built by hand on the Lua side (OC's Lua 5.2 has no `string.pack`).

## Layer 2: zones - programs the PC starts on the robot (console/protocol.h)

Inside the channel, the PC asks the loader to run a program as a **zone**:

| PC -> robot | robot -> PC | |
|---|---|---|
| `'O' name hash has [len:u32 code]` | `'P' status hit n:u16 msg` | open a zone running that code; cached by its fnv64 hash, so the code is sent only once |
| `'Z'` | `'z' count {name}` | list the zones |
| `'T' name` | `'z' ...` | end a zone |
| `'d' n:u16 bytes` | `'d' n:u16 bytes` | the zone's own conversation |
| | `'x' n:u16 why` | the zone has ended (a crash says why here) |

3d-draw opens `robot/server.lua` as zone `rserver` (`me_server.lua` as `meserver` on the mini
ME's computer). A zone left open by a dropped PC is ended with `'T'` and opened again.

## Layer 3: the robot server's text lines (robot/server.lua, inside 'd')

Plain text, one command per line:

```
PC -> robot    <id> <command> [arguments]      a batch: any number of lines sent at once
robot -> PC    <id> ok [values]                done, and what it found
               <id> err <why>                  not done - and every later line of this batch:
               <id> skip                       skipped, so a failed step never lets the next run
               ready <x> <y> <z> <facing> <energy> <name>      once, when the server starts
```

`id` is a counter the PC keeps. Directions are the world's: `n s e w u d`. Positions count from
the start block (robot 0 0 0 = world 255 63 139).

The 28 commands, plus `bye`, which the loop handles itself:

- **Where it is:** `hello`, `pos`, `setpos x y z`, `energy`; `tanks` and `sys` (uptime and
  memory: both read-only, added on 2026-10-04 for the tank question and Gunter's drops)
- **Moving:** `move <dir> [home] [wet]`, `face <dir>`, `back` (walks its own trail home)
- **Looking:** `detect <dir>`, `analyze <dir>` (name meta hardness),
  `scan dx dz [dy] [h]` (the geolyzer's hardness column; air is exactly 0)
- **Acting:** `swing <dir> [home]`, `place <dir> [face] [slot] [sneak]`, `use <dir> [face] [sneak]`
- **Items:** `select`, `stack`, `inventory`, `suck`, `suckslot`, `drop`, `dropslot`, `equip`,
  `transfer`, `craft`
- **Upkeep:** `chunk on|off`, `wait`, `charge [share] [seconds]`

**What the robot keeps to itself**, because the link can drop at any moment:
- it never moves into a liquid unless the move says `wet`;
- it never swings at another robot;
- its position goes to `/home/3d-draw/pos.txt` after every step, and is reset to 0 0 0 whenever
  its charger is east of it;
- its trail home is kept, and below an energy floor (trail x 12 + 1500) it refuses everything
  that spends energy, except `back` and `move/swing ... home`.

## What it costs (docs/speed.md)

- A batch's round trip through the relay is about 0.3 s.
- On the robot, every non-direct call costs a server tick. A `move` is 10 ticks of its own (the
  0.4 s pause), plus `getFacing` and `detect`: 14 ticks, at the server's 13 TPS about 1.07 s.
- So batching matters: one round trip for a whole walk, not one per step.

## For the new PC side: open questions, nothing decided

1. Layers 1 and 2 are already C++ on the PC side (`console/connector.h`, used by `term.exe`).
   The new program can attach to robots the same way, with no Python in between.
2. Layer 3 can stay as it is: text, batched, `ok`/`err`/`skip`. It is small and has held up.
   Or it moves to binary frames like the others - the replies are short, so the gain is small.
3. `server.lua` per step: read facing once per batch, skip `detect` above the river's level
   where the PC knows the cell is air (the user allowed it, 2026-10-04: "yes allow it, above
   water level, so water is mostly at a specific level (the river's level)"). Not yet made.
4. Two drops of Gunter at the field (2026-10-04, 23:14 and 23:17) came through this pipe, the
   same 295 of 2084 bytes each time; not explained.
