CLAUDE.md
=========

OpenComputers programs for a GregTech: New Horizons base, and the tools built to run, debug and
reach them. This file is kept to 100 lines: about 40 for how we work, the rest for the INDEX.

## How we work here

1. **The Minecraft server is reached only through the user.** Claude has no login and no key for
it. Anything to be done there is written as a **script-request**: a script in `server-requests/`
that the user reads, runs if they agree, and whose output they paste back. Nothing else goes there.

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

## INDEX

The per-subject documentation. Claude may add, change and remove entries here; keep each to a line
or two, and the whole file within 100 lines.

- `README.md` -- what the repo is, licensing, and the promise that it ships no game content
- `ae2ex_manual.txt` -- the user guide for `gtnh_ae2ex.lua`, the AE2 extension on the base
- `simulator/OBJECTIVE.md` -- what the Minecraft/OpenComputers simulator is for (user)
- `simulator/CLAUDE.md` -- how the simulator is built, tested, and kept faithful to the mod
- `console/DESIGN.md` -- the remote console: a colib relay on the server, so the OpenComputers
  computer in the base becomes a terminal on the user's PC
- `server-requests/` -- script-requests for the server, numbered, one per request (Claude)
- `ae2-stall/NOTES.md` -- the AE2 network stall on the server; not seen for days by 2026-09-30,
  kept only until the user calls it gone. Local only, gitignored
