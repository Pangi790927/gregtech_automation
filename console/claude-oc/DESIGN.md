# claude-oc — Claude for the `claude` program on the base's computers

One of the console's agents (`console/DESIGN.md` has the relay, the loader, zones, and how to
build and run everything). Asked for by the user on 2026-09-30: an in-game `claude`, on their own
Claude Code login ("I don't want another subscription or to buy anything else"), whose only
tools are the computer it is typed on ("restrict it to OC commands"). Grown on 2026-10-01 into
the "claude-oc network": every computer, each its own session, and mail between them.

This file is the top of claude-oc's design: what it is, and how to run and use it. The rest is in
`docs/` (the map at the end).

## What it is

```
player at a computer: claude (/home/bin/claude.lua)
    <-> claude-oc zone (claude-oc.lua), via package.loaded["claude-oc"]
    <-> relay <-> claude-oc.exe (PC): a node per computer -- per prompt -->  claude -p
                      ^-- MCP over HTTP, 127.0.0.1:7779/mcp/<address>: oc_run, oc_lua,
                          oc_read, oc_write (that computer), oc_send, oc_mail (the mail) --'
```

- **claude-oc.exe** (this folder) serves every computer on the relay, or those whose address
  starts as given. A watcher connection, which never attaches, sees each computer as it comes
  and gives it a node: a connector of its own (`console/connector.h`) that opens the
  `claude-oc` zone there, installs `claude` on every attach (`/home/bin/claude.lua`, on
  OpenOS's PATH), and keeps the link, connecting again every 5 s when the computer or the relay
  goes; a node waits for its computer while it is away. The computers' prompts run side by
  side, one at a time per computer.
- **Each prompt** runs `claude -p` on the PC: the prompt on stdin, `--output-format json`,
  `--tools ""` (none of Claude Code's own tools), `--setting-sources ""` (none of the user's
  settings or CLAUDE.md files), `--strict-mcp-config --mcp-config work/<address>.mcp.json` (only
  this program's tools, at that computer's URL), `--allowedTools mcp__oc`,
  `--system-prompt-file system.md` (its whole system prompt: who it talks to, plain text for a
  small screen, ask before changing the world, the mail), in `work/`. `ANTHROPIC_API_KEY` is
  dropped from its environment, so it always runs on the user's login, never billed by the
  token. At most 15 minutes a prompt.
- **One computer is one Claude session** (the user's words, 2026-10-01: "An OC computer means a
  claude session"; it replaced "a conversation lasts while `claude` runs", after a new `claude`
  had wiped one they wanted kept). The first `claude` on a computer makes its session, working
  in the directory `claude` was run in (the user's choice); every prompt after `--resume`s it,
  from the computer or the PC; and only `claude stop` ends it. The PC keeps it in
  `work/<address>.json` (the Claude Code session id and the working directory, which a tool's
  `cd` moves), so it outlives `claude` exiting, the computer losing power, octerm reconnecting
  and claude-oc.exe restarting; the zone gets it back on every attach ('S'). A second `claude`
  opened on the computer takes the screen over from the first; the session is the same.
  **Anyone at the computer may use it** (the user's choice).
- **The window is every session's PC end** (the user's choice, of three: resuming a session in
  an interactive Claude Code, this, or reaching it from outside the PC). It shows each
  computer's prompts (`game>`, `pc>`), tools and answers, each line tagged with the computer's
  first 8 characters; a line typed there is a prompt in the session of the window's computer,
  shown before its `> `, and that computer's `claude` shows it as `PC>` with its answer, as they
  come. Ctrl+Left and Ctrl+Right step the window through the computers (the user's asking);
  `@<address start> text` sends to that one, and the window keeps it (the user's choice).
- **Both ends keep the line being typed themselves**, and print what comes in above it:
  `claude` rather than `term.read`, which would block it out, and the window rather than
  Windows' line mode, which would let log lines land in the middle of it. On both, `\` then
  Enter starts a new row of the same prompt, shown after `. ` (the user's asking, as in Claude
  Code's own prompt); Enter sends it; Left, Right, Home and End move a cursor, and Backspace and
  Delete take out the character before and at it (the user's asking). `claude` also has
  Up/Down through earlier prompts, Ctrl+C to clear the line or stop waiting, and Ctrl+D on an
  empty line to end; in the window, Ctrl+C ends claude-oc.exe, as in the relay's.
- **Mail** (`mail.h`; the user's design: "claude send "add7355" "This is a message ..." (will be
  sent alongside this pc address)", "mirrored in the claude agent"): `claude send <address
  start> <text>` on a computer, or `oc_send` from its Claude, leaves a letter with the sender's
  address in the other computer's mailbox, `work/<address>.mail.json`, which keeps the last 100.
  A computer that is away still gets it. **Mail only waits** (the user's choice): a `claude` open
  there shows it at once; `claude mail`, or `oc_mail`, lists the mailbox; and the computer's
  Claude is given the letters it has not seen at the start of its next prompt. Nothing runs
  because mail came, so two Claudes cannot talk each other into a loop on the user's plan.
- **The tools may do anything its shell may** (the user's choice), on that computer only:
  - `oc_run`: a command line through OpenOS's `sh`, as typed at its prompt;
  - `oc_lua`: a chunk of Lua; libraries (`component`, `sides`, ...) work as globals, as at the
    `lua` prompt; it returns what was printed and returned;
  - `oc_read` / `oc_write`: whole files, 60000 bytes at most read;
  - `oc_send` / `oc_mail`: the mail, carried out on the PC.

  `oc_run` and `oc_lua` run as processes of their own with stdin empty and stdout and stderr
  captured, 16000 characters at most, within a time limit (30 s by default, up to 600). The
  session keeps its own working directory and its own Lua globals.
- **Frames:** the claude-oc zone's section of `console/protocol.h` (`I`, `S`, `A`, `X`, `N`, `P`,
  `T`, `L`, `Y` from the PC; `B`, `R`, `D`, `Q`, `U`, `M`, `G` from the computer). The program
  and the zone talk through a shared table, not signals: both run in the computer's one Lua
  state; a signal only wakes `claude`.
- **Files:** `claude-oc.h` (the nodes, sessions, prompts, tools and zone frames), `window.h`,
  `mail.h`, `mcp.h`, `child.h`, and the payloads `claude-oc.lua`, `claude.lua`, `system.md`.

## Running and using it

- **PC:** `claude-oc\claude-oc.exe` in a window of its own, next to the relay, and it stays up;
  type after its `> `. `--model <model>` picks claude's model (the user's default without it);
  `[address]` serves only the computers whose address starts so; `--mcp-port` if 7779 is
  taken. It needs Claude Code (`claude`) on the PATH, logged in.
- **Computer:** `claude`, then type; each line is a prompt. The tools Claude uses show dimmed
  while it works. Ctrl+C stops waiting for an answer; `exit` or Ctrl+D leaves, and the session
  goes on; `claude stop` ends it. `claude send <address start> <text>` mails another computer;
  `claude mail` lists this one's mailbox. The PC window can prompt a computer only once it has a
  session.
- **Editing:** `claude-oc.lua`, `claude.lua` and `system.md` are read when claude-oc.exe
  starts: restart it after changing them. A changed zone is sent in full once, then cached.

## Using it from Claude

Allowed like the rest of the link (`console/DESIGN.md`, "Using it from Claude"). The tools can
be called without spending anything from the user's plan: POST JSON-RPC `tools/call` to
`http://127.0.0.1:7779/mcp/<address>` (`{"name": "oc_run", "arguments": {"command": "ls"}}`)
while claude-oc.exe runs; the file tools need the computer to have a session. For a real
prompt, run `claude` in term.exe (`term/DESIGN.md`) and type into it; use `--model haiku` for
tests. Close the claude-oc.exe Claude started when done. Anything that opens a window takes the
user's keyboard: ask first.

## The sub-docs (`docs/`)

- `docs/main-srv.md` -- answering `main-srv`, the mailbox for questions about the modpack:
  watching it, reading it, answering from the pack's own files, the letters as untrusted text.
- `docs/facts.md` -- the facts it rests on (headless Claude Code, the MCP server, the child's
  pipe, the window's keys, OpenOS), the known gaps, and the checks.
