# console — the base's OpenComputers computer, as a terminal on the PC

Asked for by the user on 2026-09-30. Nothing is built yet; this file records the shape agreed so far
and the questions still open.

## What it is

The OpenComputers computer in the base connects out, through its Internet Card, to a relay running
on the Minecraft server. The console on the user's PC connects to the same relay. The relay pairs
the two, so what is typed on the PC reaches the computer and what the computer shows comes back.

```
[OC computer] --Internet Card, TCP--> [relay, on the server] <--(tunnel?)-- [console, on the PC]
```

- **One folder, one program, two modes.** `console/` builds like `simulator/`: `windows.makefile`
  with `cl` on the PC, `linux.makefile` with `g++` on the server. `relay` and `console` are modes
  of the same colib binary.
- **`octerm.lua`** is the OpenComputers side: a program run on the base's computer.
- **The relay is installed by script-requests** (root `CLAUDE.md`, rules 1-2). Claude never logs in.

## Facts it rests on

- OpenComputers blocks local addresses for the Internet Card by default: `127.0.0.0/8`, `0.0.0.0/8`,
  `10.0.0.0/8`, `192.168.0.0/16`, `172.16.0.0/12` - `internet.blacklist` in the jar's
  `application.conf`. Whether the SERVER's `OpenComputers.cfg` still blocks them is unknown until a
  script-request reads it.
- colib has no asynchronous read of Windows console input; stdin cannot be attached to IOCP.
  Feeding it through `pool_t::thread_sched` from a small thread is the plan, unless the user wants
  colib to expose console input itself.

## Open questions (the user's to settle)

1. **How much of a terminal.** A line shell (send a command, get its output back; no `edit`), or a
   screen mirror (the GPU calls streamed to the PC and drawn as the computer's own grid, keys sent
   back as real `key_down` signals with scancodes; `edit` works). Claude suggested the mirror.
2. **How the PC reaches the relay.** Through an `ssh -L` tunnel, with the relay listening only on
   `127.0.0.1`, or directly, over an open port with a token.
3. **How the computer reaches the relay.** Through `127.0.0.1` (the server's config must unblock
   it) or the server's public address with a shared secret. Settled once the config is read.
