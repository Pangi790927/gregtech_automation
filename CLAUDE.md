CLAUDE.md
=========

OpenComputers programs for a GregTech: New Horizons base, and the tools built to run, debug and
reach them. This file is kept to 100 lines: about 40 for how we work, the rest for the INDEX.

## How we work here

1. **The Minecraft server is reached only through the user.** Claude has no login and no key for
it. Anything to be done there is written as a **script-request**: a script in `server-requests/`
that the user reads and, if they agree, runs with `./doreq`. Its output lands in
`<request>.out` beside it, where Claude reads it. Nothing else goes there, except, by the user's
choice (2026-10-03), the console's agents reaching the relay run there (`console/DESIGN.md`),
which the user deploys and starts. **Claude never modifies
`server-requests/doreq.ps1`**; it is the user's, and Claude is not allowed to change it.
The server's LAN address and login are in `config.ini` (this PC's own addresses, not committed;
`config-example.ini` is its layout); Minecraft lives in `~/servers/gtnh/`, the world in
`~/servers/gtnh/World`.

2. A script-request states at its top **what it reads, what it changes, and how to undo it**. It
does one thing. Read-only requests come first; a change is asked for only once the facts it rests
on have come back.

3. **The mods are the specification.** How OpenComputers, AE2 or GregTech behave is read out of
their jars and configs, never reasoned from what seems sensible. `simulator/CLAUDE.md` records
what that has cost when skipped.

4. **No game content and nobody's save is committed. Be careful what you copy in here.** Textures,
mod Lua, class files and region files are read at runtime from the user's own install. Anything
copied from a save, a jar, a mod's source or a wiki goes to a scratch directory, or to a folder
`.gitignore` already covers (`world-debug/`, `ae2-stall/`, `simulator/scenes/aedbg/`). A new
local-only folder is added to `.gitignore` before anything lands in it. Check `git status` after.

5. C++ is built on `../utils` (virt_composer, colib), which is **not edited from here**. When it
lacks something, ask for it rather than work around it.

6. `make` in a project folder builds it; `cl` must be on the PATH on Windows. A running `.exe`
must be closed first, or the link fails and the old binary keeps running.

7. 100 columns, code and comments alike. A comment block stays attached to every function and says
what it does and why, especially where the why is the mod's behaviour.

8. **Design docs stay short and in a hierarchy.** The user, 2026-10-04: "be sure the design docs
have a hierarchical structure and are held short enough 100-150 lines, if they grow larger those
should be split in sub-docs, making sure not to break the architecture, but keep things ordered
and clean". A doc's top file maps its `docs/` folder; a section moves whole, quotes unchanged.

## INDEX

The per-subject documentation. Claude may add, change and remove entries here; keep each to a line
or two, and the whole file within 100 lines.

- `README.md` -- what the repo is, licensing, and the promise that it ships no game content
- `config-example.ini` -- the layout of `config.ini`: this PC's addresses, local only, gitignored
- `ae2ex_manual.txt` -- the user guide for `gtnh_ae2ex.lua`, the AE2 extension on the base
- `simulator/OBJECTIVE.md` -- what the Minecraft/OpenComputers simulator is for (user)
- `simulator/CLAUDE.md` -- how the simulator is built, tested, and kept faithful to the mod; the
  case histories behind its rules in `simulator/docs/`
- `console/DESIGN.md` -- the base's OC computers from the PC: octerm, zones, relay; install, test
  and facts in `console/docs/`; agents: `console/*/DESIGN.md` (term, claude-oc, ocscp); Claude
  may use it, says so when it's down
- `3d-draw/DESIGN.md` -- the top of 3d-draw: robots map a contoured area, the simulator shows it,
  robots build what the user designs (user, 2026-10-04); a map of `3d-draw/docs/`, by subject
- `3d-draw/USAGE.md` -- START HERE for any 3d-draw task: zones, scanning, design, plan, simulate,
  build, watch, a robot lost - what to do and the commands, task by task
- `3d-draw/TODO.md` -- the state of the base and what is still to be done, kept by Claude so the
  user need not keep track (user, 2026-10-04); read it at a session's start, keep it up
- `3d-draw/redesign/README.md` -- the system as it runs now (main.exe: C++ and Lua), its notes in
  order; `redesign/19-ops.md` how Claude runs it: the control port, `3d-draw/ops/` scripts, the
  crew's start/stop/reload, watching each robot, the checks (tests, sim, scans) before live
- `server-requests/` -- script-requests for the server, numbered, one per request (Claude);
  `doreq.ps1` copies one to the server and runs it; `<request>.out` keeps the result (gitignored)
- `ae2-stall/NOTES.md` -- the AE2 network stall on the server; not seen for days by 2026-09-30,
  kept only until the user calls it gone. Local only, gitignored
