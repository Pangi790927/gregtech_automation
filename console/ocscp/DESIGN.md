# ocscp — copying a file between the PC and a computer

One of the console's agents (`console/DESIGN.md` has the relay, the loader, zones, and how to
build and run everything). Asked for by the user on 2026-10-01 as the "mini scp" they had
foreseen when zones were designed ("file trasfer apps would also make more sense (mini scp)"),
so they can name a file on a computer and Claude reads it: "I will tell you what file to read
from the OC, make a scp tool if needed so one beside claude-oc and term".

## What it is

```
ocscp.exe get <path on the computer> [local path]   without a local path, to stdout
ocscp.exe put <local path> <path on the computer>
... --computer <address start>    the computer, when several are on the relay
... --port <n>                    the relay's connector port, default 7778, on 127.0.0.1
```

- **A connector with no window** (`console/connector.h`): it opens the `ocscp` zone
  (`ocscp.lua`, beside it) on the only computer, or the one whose address starts as given, and
  the zone copies one file, then ends. What happened goes to stderr and stdout carries the file
  alone, so `get` without a local path is a way to read a file; the exit code is 0 when the file
  was copied.
- **Subcommands, not scp's `host:path`**: a Windows path's `C:` would read as a host.
- **In pieces of 32768 bytes**, both ways: a computer has a few MB of memory. `get` sends one
  piece per round of octerm's loop (the zone yields after each, so octerm writes it before the
  next is read); `put` writes pieces as they arrive. Binary, byte for byte. A path on the
  computer not starting with / is under /home; `put` makes the folder it names.
- **Frames:** the ocscp zone's section of `console/protocol.h` (`G`, `P`, `B`, `E` from the PC;
  `O`, `B`, `E`, `K` from the computer).

## Using it from Claude

Allowed like the rest of the link (`console/DESIGN.md`, "Using it from Claude"): when the user
names a file on a computer, `ocscp\ocscp.exe get <path>` from `console/` prints it. It opens no
window, so it never takes the user's keyboard. `put` changes files on the user's base: say what
will be written where before running it.

## Known gaps

- One copy at a time per computer: a second, while one runs, is refused ("ocscp is open
  already").
- Files only: no directories, no listing.

## Checks

- `console/tests.exe`: a file of three pieces taken byte for byte however the zone's bytes are
  cut, and the answers when a file cannot be read or written.
