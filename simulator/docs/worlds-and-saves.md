# The simulator: other worlds, robot maps, and saves

Part of the simulator's working instructions; the top, with the rules and how to check, is
`../CLAUDE.md`. Reading a real save, drawing 3d-draw's map, and the simulator's own save. Paths are
from `simulator/`.

## Looking at somebody else's world

`mca_reader.h` reads a real Minecraft 1.7.10 region file: the header, one chunk's zlib stream, and a
real NBT walk for the TileEntities. `vc.ae_nodes(path, cx0, cz0, cx1, cz1)` hands Lua every tile
carrying an Applied Energistics grid id. `scenes/aedbg` draws the result — one marker per device,
AE2's own textures, a window listing every grid with its channel count and what is wrong with it.

- **The region file is somebody's save and does not belong in this repository.** The test for it
  runs when `../world-debug/r.1.-1.mca` happens to be there and skips silently otherwise.
- **`scenes/aedbg` is local only**, gitignored like `world-debug/`: it is built on one server's
  save.
- **Chunk coordinates are absolute**, the numbers F3 shows; the file has to be the region they fall
  in, which is `floor(chunk / 32)`.
- **A mis-sized NBT payload desynchronises everything after it** and what comes out is plausible
  nonsense rather than an error — the same trap the class-file opcode table set. The walk was
  checked against an independent Python implementation of the same file: both find 15,294 tile
  entities and the same fifteen grids.
- Facts about AE2 come out of the jar, never memory. `proxy/g` is the grid id, `p` is the owning
  PLAYER and not a power flag (that one nearly became a false diagnosis), and an ad-hoc network over
  eight channels has `channelsInUse` set to **nought** rather than trimmed — `PathGridCache`.

## Drawing what a robot mapped (scenes/draw3d)

`scenes/draw3d` shows 3d-draw's robot at work (`../3d-draw/DESIGN.md`): it follows
`../3d-draw/data/live.log` and draws each block the robot names.

- **Any block, by name: `CELL_KIND_MC_BLOCK`.** Its look is the cell's own `tile` (an atlas tile),
  `tint` and `ghost` (a guess, drawn smaller): C++ fields, as `rs_in` is, because the renderer
  cannot read `u`. `vc.render_block_tiles(keys)` loads textures on demand, one jar pass for a
  batch of `ns:file` keys, and appends them to the atlas (kept in `renderer_t::tiles`).
- **1.7.10 has no block models**, so which texture draws a block is the scene's guess from its
  name (`look` in its controller); a guess that misses falls back to a colour.
- **Every key `look` makes is checked against the jars' file lists**, not reasoned: 2026-10-04,
  wheat, farmland, wool, chisel's planks and antiBlock were all keys of no file, drawn as colours.
- **A mod key may name its folder** (`mod_textures`, 2026-10-04, the user's go-ahead):
  `chisel:planks-spruce/chaotic-hor` is that one file under `textures/blocks/` or `items/`;
  `chisel:chaotic-hor` is still the first file of that name in any folder. Without the folder,
  six `planks-<wood>` and the mossy cobblestone share chisel's names, and the windmill came out
  dark oak, the harbour's cobblestone mossy. `look` keys every chisel block with its folder.
- **Chisel's lang numbers are not its metadata**: `addVariation(desc, meta, texture)` in the
  bytecode gives `tile.cobblestone.<n>.desc` to meta n + 1 ("Detailed Cobblestone Bricks" is
  meta 2). The metadata is read from the bytecode, never from en_US.lang.

## Where a save lives

A save is a DIRECTORY, laid out the way the game's is. `scripts/saves.lua` owns its shape and is the
only file that builds a path into it:

```
save/
  level.save                   the map and the camera - one file; there are no chunks to split
  settings.save                where Minecraft is, autosave; not facts about the world
  opencomputers/
    <filesystem address>/      one hard disk, as real files in real directories
      home/prog.lua
```

- **The disk's address is kept with the computer**, written as the last field of its `c` line in
  `level.save`, because that is how the mod does it - a filesystem's address lives in the item's
  NBT and names the folder on disk. `machines.of()` settles the address the moment a machine
  exists, deliberately: anything that settled it later would make the save depend on the disks
  being written before the map.
- **A disk's folder is cleared before it is rewritten.** Otherwise a file the guest deleted stays
  on the host and comes back on the next load.
- **The flat `world.save` / `disks.save` from the first version are still read**, through
  `saves.readable` and `machines.load_disks_legacy`, and are never written to again. Do not delete
  that path: the author has a real save in that shape.
