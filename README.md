# gregtech_automation

OpenComputers programs for a GregTech: New Horizons base, and `simulator/` — a small Minecraft and
OpenComputers simulator for running and debugging them without starting the game.

Licensed MIT, see `LICENSE`.

## The simulator ships no game content

`simulator/` reads everything it draws and everything it emulates **at runtime, from a Minecraft
installation you already have** — the path is in its settings file. Textures, `machine.lua`,
`bios.lua`, the OpenOS loot, `GregTech.lang` and GregTech's material list are all read from the jars
on your own disk. None of it is copied into this repository, and none of it is reproduced in the
source.

If you have no such installation the simulator still runs, drawing stand-in shapes instead.

## Third-party credits

### ocelot-desktop

**Ocelot Desktop** (`ocelot-desktop`, version 1.11.1) — an OpenComputers emulator, licensed under
the **Apache License 2.0**. The jar carries the full licence text at `LICENSE` and names its vendor
in `META-INF/MANIFEST.MF`; it states no project URL, so none is given here.

A copy of `ocelot-desktop-v1.11.1.jar` was committed to this repository in `d2a8687` and removed in
`b02ce56`. It remains retrievable from those commits:

    git show d2a8687:ocelot-desktop-v1.11.1.jar > ocelot-desktop-v1.11.1.jar

It was present in the working tree while `simulator/` was being written, and its archive was opened
during that work — to read its `LICENSE` and `META-INF/MANIFEST.MF`. Credit is recorded here because
it was in the room, not because any of it was copied: the simulator's OpenComputers emulation is
written against the mod's own files, which is what the notes in `simulator/CLAUDE.md` track
decision by decision.

### Lua libraries

- `crc32.lua` and `deflate.lua` — © 2008-2011 David Manura, MIT. Their licence text is kept intact
  at the top of each file.

## Layout

    *.lua                the OpenComputers programs that run in-game
    simulator/           the simulator; see simulator/OBJECTIVE.md and simulator/CLAUDE.md
    recipes.db           recipe notes, in this repository's own notation
    ae2ex_manual.txt     the AE2 extension's user guide
