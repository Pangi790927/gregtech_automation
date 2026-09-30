# term — the terminal agent: a shell on a computer, in a window on the PC

One of the console's agents (`console/DESIGN.md` has the relay, the loader, zones, and how to
build and run everything). Asked for by the user on 2026-09-30.

## What it is

- **term.exe** (this folder, built here by `make` in `console/`) is a connector: it opens the
  `terminal` zone on a computer with **term.lua**, its payload (beside it, read from there, sent
  first by hash only and in full on a cache miss), and shows that zone's screen in its window.
  With one computer it attaches at once; with several, a number picks one. Every key goes to the
  zone, Ctrl+C and Ctrl+Alt+C included (the user's call). Ctrl+D disconnects, which ends the zone
  ("if you disconnect you lose the session"). `term.exe zones [address]` lists a computer's zones;
  `term.exe kill <zone> [address]` ends one.
- **term.lua** runs a shell as its own process in its own OpenOS window, with its own keyboard
  address, so PC keys reach it alone and keys typed on the computer reach the monitor's console
  alone. It draws on a **virtual screen**: a GPU video-RAM buffer as large as the GPU itself can
  draw (`allocateBuffer()` with no size; the public `maxResolution` is `min` of the GPU's and the
  monitor's). The GPU is shared with the monitor's console, so its functions are wrapped on the
  tty's proxy and **routed by caller**: the zone's shell and everything it starts, whose window is
  the zone's, draw into the buffer and are mirrored; everyone else draws on the monitor. Each side
  keeps its own active buffer and colours, and the GPU is switched to a side's when that side
  draws or asks it something. One terminal zone at a time; `exit` in its shell ends it.
- **The virtual screen follows term.exe's window.** term.exe sends its size (`W`) when the zone
  opens and on every change; term.lua sizes the screen to it, within the buffer, and waits for
  the first one before starting the shell so OpenOS's banner fits. term.exe also never draws
  outside its window.
- **A screen mirror, not a line shell** (user's choice): keys go in as real `key_down`/`key_up`
  signals with scancodes, so `edit` works.
- **Frames:** the terminal zone's own section of `console/protocol.h` (`R`, `S`, `F`, `C` from the
  computer; `K`, `W` to it).
- **colib, no threads.** term.exe reads its window like any handle: `CONIN$` opened with
  `FILE_FLAG_OVERLAPPED` completes on the IOCP (tried in a scratch program first). That read gives
  characters and VT sequences, so `keys.h` maps them to OpenOS's `keyboard.keys`, US layout.
  `winconsole.h` takes the window over and gives it back.

## Using it from Claude

Allowed whenever the user has the relay up with a computer on it (`console/DESIGN.md`, "Using it
from Claude", has the rules: if the link is down, tell the user). `console/conhelp.exe` types into
term.exe's window and reads it back. From PowerShell:

```powershell
$C = "$(git rev-parse --show-toplevel)\console"   # run from inside the repo
Get-Process relay, term                   # relay running? (a term.exe of the user's is fine)
$before = Get-Date                        # a window of the size to test, e.g. the user's:
Start-Process cmd -ArgumentList "/c mode con cols=120 lines=30 && `"$C\term\term.exe`""
Start-Sleep -Milliseconds 6000            # attach, open the zone, first window size
$t = Get-Process term | Where-Object { $_.StartTime -ge $before } | Select-Object -First 1
& "$C\conhelp.exe" keys $t.Id l s SPACE / ENTER          # types: ls /
Start-Sleep -Milliseconds 3000                           # a round trip is a few server ticks
& "$C\conhelp.exe" read $t.Id 30 120 "$env:TEMP\screen.txt"
& "$C\conhelp.exe" keys $t.Id CTRL+D                     # disconnects; the zone ends
```

- With more than one computer, term.exe lists them; type the number of the one wanted.
- One terminal zone per computer: if the user's term.exe is attached to it, a second terminal is
  refused ("terminal is open already"); `term.exe zones` shows what is open.
- Do not switch GPU buffers from another zone while a terminal zone is open: term.lua tracks
  which buffer the GPU is on, and would draw onto the monitor.

## Facts it rests on

- **A tty's keyboard is its window's**: `tty.keyboard()` returns `window.keyboard` when set, and
  the line editor takes `key_down` from that address only (`lib/core/cursor.lua`); so term.lua's
  window gets an address of its own. Scancodes are `lib/core/full_keyboard.lua`'s. Keys from the
  PC carry the player "octerm".
- An Alt+Tab out of Minecraft leaves Alt down in OpenOS's `keyboard.pressedCodes`
  (`boot/92_keyboard.lua`), which made the PC's next Ctrl+C a Ctrl+Alt+C. Before the PC's keys
  go in, term.lua releases any Ctrl, Shift or Alt the PC did not press itself.
- **The GPU answers about its active buffer.** Asked `getViewport` while a buffer was active, the
  GPU answered 50,160 (sideways) for a 160x50 monitor, which read as the monitor having shrunk;
  term.lua switches to the asker's buffer before asking. `getViewport` on the screen is correct.
- A screen larger than term.exe's window, drawn past its bottom, scrolled the whole window: the
  banner vanished, Tab "cleared the history", prompts appeared in copies (reported by the user,
  reproduced in a 120x30 window, fixed by the `W` frame and clipping).
- The per-process windows, threads-are-not-processes and hard-interrupt facts it relies on are in
  `console/DESIGN.md`.

## Known gaps

- Drawing through `component.invoke` passes the wrapped proxy by, and lands on whichever buffer
  the GPU is on; OpenOS itself always uses the proxy.
- The GPU needs free video memory for the buffer; term.lua says so if not.
- Resizing term.exe's window while it runs is untested (it checks every 0.3 s).

## Checks

- `console/tests.exe`: the key table, frames cut at every byte, and term.h's own session through a
  real relay against a stand-in loader (a cache miss, the code, the screen, keys, the zone ending).
- term.lua with stage 1 and the extension under a stand-in OpenOS in scratch: the PC's keys
  reaching the zone's shell only, the computer's keys the monitor's console only, the GPU given
  back and the buffer freed when it ends.
- On the user's computer (2026-09-30): a 120x30 window with its banner fitted, `ls /`, `cat` +
  Tab + Enter scrolling cleanly; the monitor's side answering 160x50 with the terminal open; run
  again from `console/term/` after the move.
