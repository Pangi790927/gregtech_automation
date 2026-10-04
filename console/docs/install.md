# console: installing, running and checking it

Part of the console's design; the top, with the agents and the map of the sub-docs, is
`../DESIGN.md`. Paths are from `console/`.

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

## The relay on the server

Asked for by the user on 2026-10-03: the relay runs on the Minecraft server, beside the
computers, and the agents stay on this PC and reach it over the LAN. Ports and addresses, from
the server's own Claude session (gtnh-45) and the user:

```
computer: octerm --> 127.0.0.2:7777   relay (server)   <server>:7778 <-- agents (this PC)
```

- **127.0.0.2 for the computers.** OpenComputers filters by address, never port, and most of the
  server's services listen on every address, 127.0.0.1 included. So OpenComputers allows only
  127.0.0.2, which nothing else uses, and the server's firewall rejects every port on it but
  7777. Each computer is pointed there once: `octerm 127.0.0.2`.
- **7778 on the server's LAN address,** from this PC only: `--allow <pc>` closes any other
  connector unread (tested), and a firewall rule on the server does the same.
- **The agents** take the relay's address from `relay` in `config.ini` (`connector.h`,
  `relay_host`); with no such line they use 127.0.0.1, the relay on this PC.
- **Build:** `make -f linux.makefile` in WSL (`console/`), which links the program statically:
  the server is Ubuntu 18.04 (glibc 2.27, no C++20 compiler), WSL has g++ 15 and glibc 2.43.
  The binary needs Linux 3.2 or later. It goes to the server with `octerm_ext.lua` beside it, and
  runs as `relay --computers 127.0.0.2 --connectors <server> --allow <pc>`, in a screen session
  of its own, as Minecraft does. Deploying is a script-request, or the server's Claude.
- **Changing `octerm_ext.lua`** then means copying it to the server; the relay reads it anew for
  every hello, so no restart.
- Checked in WSL against a stand-in computer and connectors (2026-10-03): the extension sent, the
  list, attaching, data both ways (2.4 MB to a connector, so writes that fill the socket),
  a connector from another address refused, a connector leaving told to its computer.

## Checks

- `tests.exe`: screen operations, frames cut at every byte, the key table, the payload hash; the
  relay's own sessions over real sockets (the extension sent or left to the cache, channels kept
  apart, attach refused with `N`, `G` when a connector leaves, a computer leaving closing its
  connectors, protocol 1 refused, a reboot replacing the old connection, nothing left behind);
  then each agent's own tests, term's through that relay (their DESIGN.md says what). The
  socket tests run on ports Windows picks, and all in one pool: destroying a pool with reads
  still pending corrupted the heap for the next test.
- Stage 1 and the extension, with term.lua, under a stand-in OpenOS in scratch (minilua, with
  processes, windows and shells that echo their own keyboard's keys): the hello and the cache,
  the header and the console on the monitor, `octerm stop`, a second start from the cache;
  an address given once kept in `/home/.octerm/relay` for a bare `octerm`, and the usage
  printed when there is none.
- On the user's computer (2026-09-30): installed with install_octerm.py, relay replaced, the
  extension sent; the monitor read back with its header and console; term.exe used through it.
