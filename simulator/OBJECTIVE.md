# OBJECTIVE — an OpenComputers simulator

Stated by Andrei Pangratie ("Pangi"), 2026-09-16, at the start of the project. This file is the
record of what the thing is FOR, so a later session does not have to reconstruct it from the code.

## The end goal

A mini-Minecraft simulator for OpenComputers programs — an emulator for the Lua in this repo's
parent directory (`gtnh_ae2ex.lua`, `gtnh_stats.lua`, `hw_crafting.lua`, and the rest). The point is
to run and debug those programs without a Minecraft instance and without a GregTech world.

The shape of it:

- The map starts flat and empty, and the player flies around it.
- The player places blocks and wires, and breaks them. That is close to the whole of the world
  editing — this is not a game, it is a test bench that happens to look like one.
- Once a world exists, the user interacts with it to **send events** into the simulated computers.
  That is what the whole thing is built to do; everything before it is scaffolding.

## The architecture, as stated

Modelled on `../../math_writer` — the same makefile split, the same ImGui usage, the same input
idea, the same `virt_composer` boundary between C++ and Lua.

- **C++ provides the low level drawing and the cells.** A `cell_t` is a C++ object held in the map
  matrix. Modifications made to it are what make it react in different ways.
- **A cell is a leaf.** The author's own framing, 2026-09-16: it is "similar to an mexpr, that's
  what lua will store at a slot ... but not a recursive one, only a cell". Lua builds the cell
  through a C++ factory and drops it into a slot; there are no children and no tree.
- **Lua drives.** Camera, input, which cell a click places, the UI. Lua also owns the settings file
  and saves the world — not C++.
- **Lua knows nothing about textures.** Texture loading, atlasing and face selection are entirely a
  C++ concern. Lua names a kind and a state; C++ decides what that looks like.
- **The settings file remembers where Minecraft is.** Textures are read from the GregTech: New
  Horizons instance at runtime. When that path is missing or the assets are not found, the renderer
  draws manual shapes instead — a placed cell is always visible, with or without Minecraft.

## Milestone 1 — what was asked for first

1. Save this objective. (This file.)
2. Create the `simulator/` directory to work in.
3. A flying camera.
4. A map of 64 x 64 x 32 — width x length x height — initially empty.
5. Place an OpenComputers case on the ground, textured from the GTNH instance.
6. Break it with left click.

## The emulator, so far

Steps one to four are done: a computer case runs a real OpenComputers machine, it boots OpenOS off a
floppy, it draws to a screen, and it can be typed at.

`machine_composer.h` gives each machine its own `lua_State` - a raw one, never a virt_composer
state, because the guest is emulated code and must not see the simulator's own scripting - and
drives the mod's own `machine.lua` as a coroutine through the four-case yield protocol its header
describes. The components are C++ objects on the machine: the computer block itself, an EEPROM
carrying the mod's `bios.lua`, a scratch filesystem, the case's hard disk, and whatever the world
says is plugged in.

Booting follows the game. Starting a case gathers what is connected to it at that moment - its own
hard disk, the floppy in any disk drive standing against it, a graphics card for every adjacent
screen, and a keyboard for every keyboard bolted to one of those screens - and only then starts. The
BIOS binds the first gpu to the first screen, then looks through the filesystems for one with an
`/init.lua`.

So the whole sequence works as it does in Minecraft: a bare computer finds nothing to boot and says
so; put an OpenOS disk drive against it and it boots into the operating system, which reports that
the home directory is read-only and suggests running `install`; typing `install` copies the system
onto the hard disk; and the machine then boots on its own with the drive taken away entirely.

What a screen is displaying is read back out of its character grid, so the panel on the right and
the focused view both show the real terminal rather than a host-side log.

Components are gathered when a computer starts, with one exception: a keyboard bolted onto a screen
while the machine is already running attaches straight away. OpenOS caches a screen's keyboards and
only looks again when a `component_added` signal arrives, so the machine is told - which is what
makes it behave the way the game does, where a keyboard works the moment it is placed.

What is not there yet is the screen BLOCK's face: a screen in the world still draws as a dark panel,
and its contents are only visible in the focused view. Rendering the grid onto the block itself is a
drawing job rather than an emulation one.

What remains, in order: redstone, then inventories and the transposer, then the GregTech and AE2
adapters this repository's own programs talk to.

## Deliberately not here yet

Wires, redstone, the OpenComputers Lua machine itself, event injection, inventories, multiple
computer tiers, and any notion of time or ticks. They are the reason the project exists; they are
not milestone 1.

## Building and running

`make` from this directory. On Windows that needs `cl` on the PATH (a Visual Studio build tools
prompt) and produces `main.exe`; on Linux it uses g++ and needs glfw, GL and libbacktrace. The
makefile reaches up two levels for `../../imgui`, `../../implot` and `../../utils`, which is where
they sit beside this repository.

Nothing needs to be downloaded for the textures. The Minecraft path lives in `settings.save`, which
is written on the first clean exit; the panel in the running application can change it and apply it
without a restart. With no valid path the world is drawn with hand-made shapes and the panel says
so.

## Controls

    tab              capture the mouse and look around, or release it
                     (the simulator opens already captured)
    w a s d          move along the heading and across it, always level
    space / shift    rise and descend; both at once holds height, which is
                     what lets shift+right click place without sinking
    ctrl             move at the faster speed
    wheel, or 1..9   choose what a right click places
    left click       break what the crosshair is on - a flat thing first,
                     then the block it clings to
    right click      open a case, a screen or a chest; place the selected thing
                     on anything else
    shift+rclick     place against one of those three instead of opening it
    f                toggle the aimed case between off and running
    esc              step back out of a focused screen, straight back into
                     looking around
    ctrl+q           quit, saving the world on the way out

A right click follows the game: it opens whatever has
anything to open, and sneaking past it with shift places against it instead.

What can be placed, in selector order: a computer case, a screen, a disk drive and a redstone lamp,
which are cubes; a keyboard, which is flat and bolts onto the side of a case or a screen; and a
redstone wire, which is flat and goes on any exposed face including the floor. Nothing can be built
against a face that carries a flat thing. The selector draws each one as an angled model textured
from the same atlas the world uses.

A computer case arrives with its components installed - an APU at tier 3, two sticks of tier 3.5
memory, a Lua EEPROM and a tier 3 hard disk, which are the highest craftable, non-creative tiers in
GregTech: New Horizons. A disk drive arrives with an OpenOS floppy in it. Both are recorded in the
cell's `u`, ready for the emulator to build a machine from.

Aiming at a screen opens a console view on the right of the window. It names the case the screen is
attached to - adjacency is the whole of the network until there are cables - and shows the screen's
own `u.lines`, which is empty until there is a machine to write to it.

A save is a directory, laid out the way the game's is:

    save/level.save                       the map and the camera
    save/settings.save                    where Minecraft is, autosave
    save/opencomputers/<address>/         one hard disk, as real files - home/prog.lua and the rest

The address is written beside the computer in `level.save`, the way the mod keeps it in the item's
NBT. The flat `world.save` and `disks.save` the first version wrote are still read when the
directory has nothing yet, and are never written to again.

There are two instances of the program. `main.exe` is the simulator. `main.exe --test` is the
testing instance: its own entry script, every file under `test_run/`, no window, no frame loop, and
an exit code - 42 cases in under six seconds.

The world file remembers the camera as well as the map, so a saved world reopens looking at what
was being worked on.

## How the pieces sit

    main.cpp              window, lua state, the frame loop
    gl_util.h             shader, texture, indexed mesh, a 4x4 matrix
    mc_assets.h           the jar reader, the PNG decode, the hand-drawn tiles
    world_composer.h      cell_t and world_t - the map, and what is in it
    render_composer.h     camera, texture atlas, meshing, the 3D pass
    app_composer.h        pointer capture and the quit request
    imgui_composer.h      ImGui, exposed to Lua - copied from math_writer and extended
    imvec_marshal.h       how an ImVec2 crosses the boundary
    path_composer.h       app-local paths - copied from math_writer unchanged

    scripts/main.lua      test_init / test_draw / test_shutdown
    scripts/saves.lua     the shape of a save directory; nothing else builds a path
    scripts/tests.lua     the testing instance's entry point, run by --test only
    scripts/settings.lua  the settings file
    scripts/blocks.lua    kind, state and face names; the one cell creator; the `u` table
    scripts/camera.lua    the flying camera
    scripts/world.lua     aim, place, break, and the world file
    scripts/ui.lua        the crosshair and the panel

## To investigate

Open questions recorded for later, not conclusions.

- **~700 GregTech materials are absent from the item catalogue.** `gt_materials()` reads 511 of the
  ~1,206 names the lang file has. The ones it does not read are built through GregTech's copy
  constructor, which takes a material rather than a sub-id as its first argument. Recorded
  2026-09-17.
