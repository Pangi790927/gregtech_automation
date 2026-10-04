# console: the facts it rests on, and its gaps

Part of the console's design; the top, with the agents and the map of the sub-docs, is
`../DESIGN.md`. Paths are from `console/`.

## Facts it rests on

- OpenComputers filters by **address only, never port**. In 1.8.0.13 (GTNH 2.3.0) the host is
  resolved, coerced to an int by Guava's `InetAddresses.coerceToInteger` and range-checked
  against a blacklist (`Settings$AddressValidator`, `InternetCard$.checkLists`).
- **1.9.14 (GTNH 2.4.0, the server from 2026-10-03)** replaced the lists with `filteringRules`:
  the first rule matching the address applies, none matching denies. Its defaults are
  `removeme`, `deny private`, `deny bogon`, `allow default` (the jar's `application.conf`), so
  loopback and the LAN are closed. The server's rules, from its Claude: `allow ip:127.0.0.2`,
  `allow ip:<pc>`, then the defaults. It also reported that this build writes
  `version="@VERSION@"` into the config, which made each start rebuild the rules from the
  defaults; it set the version by hand.
- The 2.3.0 server's blacklist (applied 2026-09-30, read back by request 001) was 127/8, 0/8,
  10/8, 172.16/12, 224/3 and 192.168/16 minus the PC's address.
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
  (colib `stop_handle`, `stop_fd` on Linux): `shutdown` alone leaves that read waiting for a
  peer that may never close, such as a computer that rebooted.

## Known gaps

- A shell killed while running leaves its entry in OpenOS's process list.
- colib's Windows `connect` does not set `SO_UPDATE_CONNECT_CONTEXT`, so `shutdown` on a socket it
  connected fails with WSAENOTCONN. Reported to the user, not patched here; nothing relies on it.
