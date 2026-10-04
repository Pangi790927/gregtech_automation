# claude-oc: the facts it rests on, its gaps and its checks

Part of claude-oc's design; the top, with the map of the sub-docs, is `../DESIGN.md`. Paths are from
`console/claude-oc/`.

## Facts it rests on

- **Headless Claude Code 2.1.285** (tried 2026-09-30 against a stand-in MCP server in scratch):
  an `http` MCP server in `--mcp-config` works with `-p`; with `--tools ""` and
  `--strict-mcp-config` its tools are the only ones; with `--setting-sources ""` the user's
  global CLAUDE.md does not reach it; `--resume <session>` carries a conversation, and the
  session id stays the same. It reads the prompt from stdin. `--bare` would need an API key, so
  it is not used. `--safe-mode` also turns MCP servers off.
- **What it sends the MCP server** (`mcp.h` has the list): a `server/discover` probe first
  (an error answer moves it on to `initialize`), a GET for an event stream (405 declines it),
  connections kept alive. The URL's path is its own: one server serves every computer.
- **Its output** is read through a named pipe opened overlapped on this side, so colib reads it
  with no thread, and reads 0 at its exit. The child inherits only its three standard handles:
  sockets are inheritable on Windows, and a child holding the relay's socket would keep it open.
  A job object ends it when claude-oc.exe ends.
- **The relay** sends its list of computers to every connector not attached, whenever it
  changes, which the watcher lives on; and it closes the connectors of a computer that leaves,
  after which a node waits for its computer to come back.
- **The window's keys** are read from `CONIN$` opened overlapped, with
  `ENABLE_PROCESSED_INPUT` and `ENABLE_VIRTUAL_TERMINAL_INPUT` set: no echo, no line editing,
  keys as characters and VT sequences, and Ctrl+C still Windows' own. The reads complete on
  colib's IOCP (tried 2026-09-30). With processed input alone, keys that type nothing, like the
  arrows, never reached a read; as VT sequences they do, and `console/keys.h`, term.exe's
  decoder, turns them into OpenOS's key codes, which both editors use; Ctrl+Left is Left inside
  Ctrl's own down and up. The bytes are in the console's input code page and are turned into
  UTF-8; the window's output is UTF-8, with VT processing for redrawing the typed row and
  placing the cursor. The modes are put back on the way out, Ctrl+C and closing included.
- **OpenOS's key codes** for the editors' keys are `lib/core/full_keyboard.lua`'s: Left 0xCB,
  Right 0xCD, Home 0xC7, End 0xCF, Delete 0xD3. OpenOS blinks a cursor only inside
  `term.read`, so `claude` draws its own as a lit cell.
- **OpenOS's `term.clearLine()`** is the VT erase-line and a jump to the left edge
  (`lib/term.lua`), which is how `claude` prints a message above the line being typed.
- **OpenOS:** a process's io is its `data.io` (`lib/process.lua` copies the parent's into a new
  one), and `print`, `io.write`, `io.stderr` and `term.write` all reach it (`boot/03_io.lua`,
  `lib/term.lua`); so a tool replaces `data.io[0..2]`. Environment variables, the working
  directory among them, are `data.vars` (`boot/02_os.lua`), the session's own. `PATH` is
  `/bin:/usr/bin:/home/bin:.` (`boot/02_os.lua`). Ctrl+C pushes `interrupted`
  (`lib/event.lua`), which `claude` waits for next to its own signal.

## Known gaps

- oc_lua's globals live in the zone's memory: a reboot or reconnect loses them, while the
  session and its working directory go on.
- Claude Code deletes old session transcripts after a while (its cleanup period); a session
  left that long cannot be resumed, and its prompts fail until `claude stop`.
- A tool stopped by its time limit leaves its process in OpenOS's process list.
- Programs that draw on the GPU or move the cursor themselves (`clear`, `edit`) draw on the
  monitor, not into the captured output.
- A long answer scrolls past the top of the screen; there is no paging.
- Two `claude`s at once: the take-over was not tried on the computer.
- The window's line editor has no Up/Down. On both, the cursor moves within the open row only;
  Backspace past its start joins it to the row above, whose printed copy stays on the screen
  above. The rows of a prompt typed with `\` then Enter stay printed where they were typed, so
  a log line arriving meanwhile lands between them.
- Ctrl+C in the window with VT input on was not tried again; Windows documents processed
  input as still taking it.
- A computer is known to the mail once it has been on the relay since claude-oc.exe started,
  or has a session or a mailbox kept.

## Checks

- `console/tests.exe`: HTTP requests cut at every byte; the MCP answers (initialize, a
  notification, tools/list, tools/call told its path, an unknown method); a computer's frames
  cut at every byte; keys typed in the window (Backspace, `\` then Enter, Enter, the cursor,
  Ctrl+Left and Ctrl+Right stepping through two computers, `@<address start>`); the mail (sent
  by the start of an address, from `claude send`'s frame too, given to Claude once, listed with
  the new ones marked, refused when no computer has the address).
- `claude-oc.lua` under stand-ins in scratch: no session, the first `claude` making one where
  it was run, a second joining it and the first told, `claude stop` ending it (and saying so to
  the `claude` open), a reconnect bringing a kept session back with its directory; a send's
  frame and its answer, and mail reaching an open `claude`.
- `claude.lua` under stand-ins for OpenOS's event, term and GPU in scratch, with keys scripted:
  a prompt of two rows sent as one, a `PC>` message printed above a half-typed line, which goes
  on unbroken, and the cursor (Left, Home, Delete, End).
- On the user's computer (2026-09-30), through the MCP port: `oc_run` (output, `cd` kept, a
  missing program failing, `sleep 5` stopped at 2 s), `oc_lua` (printing, returning a table, an
  error, libraries as globals), `oc_write` and `oc_read` on `/tmp`; about 0.2 s a call. In
  term.exe: `claude`, a question about the computer's components answered from `oc_lua` in
  about 9 s, a follow-up answered from the conversation; claude-oc.exe closed while `claude`
  ran, and `claude` saying so. That was the one-computer claude-oc, before the shared window,
  the sessions kept, the line editors and the mail, which have not run with a computer yet.
