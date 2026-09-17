# CLAUDE.md — the OpenComputers simulator

Instructions for working in `simulator/`. Written 2026-09-17 after a run of bugs that all had the
same shape.

## The reference is the mod, not your judgement

**This project emulates OpenComputers and Minecraft. Their behaviour is the specification. Yours is
not.** When a question comes up about how something behaves — how a component is found, what a
screen shows, what a key event carries, when a filesystem is writable — the answer is in the mod's
own files, and reading them takes a minute.

Do not reason from what seems sensible. Every bug below came from exactly that, and each one looked
perfectly reasonable while it was being written:

- **Components were gathered once, at boot.** "A computer is the sum of what is plugged in when you
  press the button" is a defensible design. It is not OpenComputers', which fires `component_added`
  and `component_removed` at runtime. A transposer placed against a running computer was plainly
  there and plainly invisible. Everything is hot swappable, always.
- **A screen was drawn as a scrolling log**, showing the last rows that fit. A screen is a fixed
  grid; `edit` puts the file at the top and its status bar on the last row. The top was cropped, so
  a file being typed was invisible while the status bar underneath looked perfectly alive.
- **The cursor was thought to be missing.** OpenComputers has no cursor. A terminal draws one by
  swapping a cell's two colours. Reading only characters out of the grid threw it away.
- **Key events carried a code of zero.** A program identifies a key by its scancode, not by the
  character: `bin/edit.lua` matches its whole keymap with `code == keyboard.keys[key]`, and
  `lib/core/cursor.lua` leaves `lua` on ctrl plus `code == keys.d`. Neither could match anything.
- **`computer.beep` was assumed to be a host function.** It is not; `machine.lua` defines it as
  `component.invoke(computer.address(), "beep")`, so the computer block has to exist as a component
  of its own machine.

In every case the mod's own source said so plainly.

### Where the facts for the liquid tank came from

Worth recording, because every one of these was checkable and the plausible guess was wrong:

- **A Super Tank IV holds 32,000,000 L.** Tier 4 of `commonSizeCompute` in
  `gregtech/common/tileentities/storage/GT_MetaTileEntity_DigitalTankBase`. The quest book's prose
  says a Super Tank I "matches" 4,096,000 L; the code says 4,000,000. Read the bytecode.
- **Litres, not buckets.** GregTech's own tank tooltip is `getCapacity()` followed by `" L"`.
- **The transposer's fluid methods** are `getTankCount`, `getTankLevel`, `getTankCapacity`,
  `getFluidInTank`, `compareFluid` and `transferFluid` - the names are in the constant pool of
  `li/cil/oc/server/component/Transposer$Common`, with their doc strings.
- **A fluid table carries exactly `name`, `label`, `amount`, `hasTag`** - that is what
  `li/cil/oc/integration/vanilla/ConverterFluidStack` puts on it, and nothing else.
- **The fluid catalogue is read out of the jar at runtime**, from
  `assets/gregtech/textures/blocks/fluids/fluid.<name>.png`, and the labels out of `GregTech.lang`
  at the instance root, whose lines read `S:fluid.<name>=<Label>`. No fluid is named in this repo.

### Item names come from the save, not the jars

The chest panel's item list is the modpack's **real registry**, read out of `saves/<world>/level.dat`
- the same list NEI shows, 10,432 entries on the author's install. Forge writes it into every world
so item ids survive a mod list changing, and it is the ONLY place on disk that knows the real names:
a golden apple's texture is `apple_golden.png`, its lang key is `item.appleGold.name`, and the item
is `minecraft:golden_apple`. No jar knows that.

Reading it: gzipped NBT, so skip the gzip header by its flag byte and inflate the rest with stb's
raw-deflate entry point. A full NBT walk desynchronised part way through that file, so the strings
are picked out by their framing instead - a two byte length followed by exactly that many bytes -
keeping the ones that carry FML's leading `1` (block) or `2` (item). That prefix byte is what
separates a registry entry from any other text with a colon in it.

**Pictures come from every jar under mods/**, not just vanilla: a mod's art is at
`assets/<ns>/textures/items/<name>.png` and its items register as `<ns>:<name>`, so the two join on
that pair (lower-cased - a registry writes `Botania:manaSteel`, the asset folder is `botania`).
2,539 of 10,415 get one that way, and **only those are offered** - an item with no picture is
filtered out rather than listed as a blank square. Some never can have one: GregTech draws thousands
of items off a single sheet indexed by damage value, which a registry name cannot index into. The
names are not lost, since the panel's text box takes any id typed into it.

Only the **item** registry is read (FML marks blocks 1, items 2). Every ItemBlock is in both, so
what is block-only is the technical sort nobody holds - flowing water, fire, a piston head - and
none of that can be in a chest. A picture is attached
when the vanilla jar has a texture whose file name matches the part after the colon. GregTech draws
thousands of items off one sheet indexed by damage value, which a registry name cannot index into.
An item with no picture still lists with a blank square, because its name is what a program compares.

### GregTech's material list comes out of the bytecode

**14,776 of GregTech's item names are templates** - `S:gt.metaitem.01.2324.name=%material Dust`. The
damage decomposes as shape * 1000 + material (2324 = dust of material 324), and the material list
exists in exactly one place: the static initialiser of `gregtech/api/enums/Materials`. Not the lang
file (it keys display names by material NAME), not the configs, not `IDs.cfg`, not the texture
folders (those are texture SETS - DIAMOND, DULL, SHINY - which GregTech tints per material at
runtime).

`mc_assets.h`'s `gt_material_ids()` reads it: parse the constant pool, find `<clinit>`'s Code, and
scan for `new Materials ; dup ; <push>` - the sub-id is the constructor's first argument, so it is
the first thing pushed - then pair each with the next `putstatic` of a Materials-typed field, whose
name is the material's. 511 materials, which turns 886 named GT items into 14,501. Sanity-checked
against public knowledge: iron 32, gold 86, copper 35.

**The icons come from the same place.** GregTech keeps no picture for a naquadah dust: it ships one
greyscale image per shape per texture set (`materialicons/METALLIC/dust.png`, plus an `_OVERLAY`
that goes on top untinted) and multiplies it by the material's colour when it draws. The texture set
and the colour are arguments to the same constructor, so `gt_materials()` reads them alongside the
id. 12,861 of the 14,501 are drawn this way.

**The shape a damage value stands for is NOT the OrePrefixes ordinal.** Each metaitem class builds
its own `new OrePrefixes[32]` in its constructor - index 2 of metaitem 01 is `dust`, which is what
makes 2324 a naquadah dust. The enum's own ordinal 2 is `sapling`, so reading that instead would
have given every item the wrong picture with nothing to flag it. `gt_prefixes()` reads the array.

**Decode each shape once.** Looking one up per item meant scanning an 18 MB archive 29,000 times and
put 15 seconds on startup; there are only a few hundred distinct shapes, and the per-material part
is just a multiply.

`class_reader.h` holds the class-file parsing, deliberately ignorant of GregTech: constant pool, one
method's code, and a helper for reading an integer push. It is not a disassembler and must not grow
into one.

The copy constructor takes a material rather than a number and is skipped, which is why this finds
~511 of the ~1,200 names the lang file has. Missing ones are dropped, never guessed.

There is a test for it that searches for "Naquadah Dust" - that is the exact thing the author
reported missing, and it fails the moment this stops working.

**Read jars by seeking, never whole.** mods/ is 400 MB across 238 jars and the wanted pictures are
a few MB. `zip_dir()` reads only the tail (to find the end-of-central-directory record) and then the
central directory; `zip_read()` then reads just the one entry. Reading each jar whole to find its
textures added seconds to startup - `read_file` on a jar is for the handful opened by name
(OpenComputers, vanilla, Iron Tanks, GregTech, AE2), not for sweeping the directory.

**The item picker draws only the rows in view.** Ten thousand Selectables a frame is far past what
ImGui will do at a sensible rate, and the filter is cached rather than re-run every frame. The
clipping needs an exact row pitch, which is what `ImGui_PushItemSpacing` exists for.

When there is no save, the list falls back to texture names, which are NOT registry names. Do not
"fix" that fallback by inventing a texture-to-registry mapping.

Fluids are the opposite case and that is why they are trusted: `fluid.chlorine.png` and
`S:fluid.chlorine=Chlorine` agree exactly, so the picture and the name are found by one string.

`javap` from the Adoptium JDK on this machine disassembles a class when the strings are not enough:
`javap -p -c Foo.class`.

### Extract to a scratch directory, and check you got there

Reading a mod's bytecode means extracting `.class` files somewhere. **That somewhere must not be
the repository.** On 2026-09-17 a run of `cd "$SCRATCH" && python -c "...extract..."` left GregTech,
GT++, GoodGenerator and TecTech class files plus seven `javap` dumps sitting untracked in the repo
root, one `git add -A` away from being committed - compiled mod code and its disassembly, which is
exactly what this repository must never carry.

The cause was `cd` to a path that resolved to nothing: an empty argument leaves the shell where it
is and says nothing. Use an absolute scratch path, or `cd X || exit`, and check `git status` after a
session of jar-reading.

## How to check

The jars are the source of truth and both are already on the machine. Read them directly:

```
python -c "import zipfile; z=zipfile.ZipFile(JAR); print(z.read(NAME).decode())"
```

- `mods/OpenComputers-1.8.0.13-GTNH.jar`
  - `assets/opencomputers/lua/machine.lua` — the sandbox and the host contract
  - `assets/opencomputers/lua/bios.lua` — the default EEPROM
  - `assets/opencomputers/loot/openos/**` — the whole operating system, 179 files
  - `assets/opencomputers/lang/en_US.lang` — item names and tiers, for anything user-facing
  - `assets/opencomputers/textures/blocks/**`
- the vanilla jar, for blocks that are Minecraft's rather than the mod's

Local `unzip` on Windows silently extracted 27 of 179 files once. Use python's `zipfile`.

## The layering, and why

- **C++ owns** the cell matrix, the renderer, the asset loading, and the component implementations.
- **Lua owns** the interface, what a click does, the world file, and which components a machine
  should have.
- **A guest machine gets a raw `lua_State`, never a virt_composer one.** The guest is emulated code.
  Letting it see `vc` would hand a simulated computer the keys to the simulator.
- `cell_t` is a leaf, deliberately: a kind, a state, a facing, a position, and `u` for whatever the
  script layer wants. **A new per-block field goes in `u`**, not in C++.
  - The exception, and the only one so far: `rs_in`, added 2026-09-18. A component implementation is
    C++ (`rs_get_input` in `machine_composer.h`) and cannot reach into a cell's `u` table, so a
    field a COMPONENT must read has to live on the cell. Everything a component does not touch still
    belongs in `u`.
- **A signal can now run into a computer, not only out of it.** `getInput` used to return a literal
  zero - "nothing in the world emits into a block yet" - which meant a scenario could listen to a
  program but never tell it anything. `cell_t::rs_in_set` drives a face and the guest reads it back
  through `redstone.getInput`. The fusion scenario uses four of them to say which catalysts have hit
  their limit, because the program has no line of sight to the bank and everything else it works
  with is its own bookkeeping.

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

## Testing

`main.exe --test` is the TESTING INSTANCE: `scripts/tests.lua` instead of `scripts/main.lua`, every
file under `test_run/`, no window, no frame loop, and an exit code. `main.exe` on its own is
untouched by any of it. This split exists because a test written into the application's own startup
ran every time a person opened the simulator - the window sat blank and then closed itself, which
looks exactly like the application being broken.

Wait on the thing being waited for, not on a count of iterations. The suite runs in six seconds
because every wait is `until_true`; the same suite written with fixed loop counts took two minutes.

**Test the path a person actually takes.** Three separate bugs survived a passing test because the
test called the helper underneath the thing that was broken:

- the terminal was driven through `machines.send_key` directly, never through the ImGui pairing;
- `machines.screen_output` was tested, never `ui.miniscreen`, which returns early unless a screen is
  under the crosshair;
- the editor was tested with real scancodes, never with what the live path was actually sending.

Where the real path needs input, drive it: ImGui accepts injected key and character events, and a
frame-by-frame script can type into a running machine. That harness found the answer in one run
after three rounds of reasoning had not.

Verify against the screen's own contents, not against "it did not crash".

**A test that passes because a fallback caught it has told you nothing.** The save directory work
had `load_disks` fall back to the old packed file whenever the new folder came up empty. The folder
came up empty - every computer wrote zero files - and the round trip still reported all 180 files
back, because the fallback quietly supplied them. It was only visible by running the migration
against the author's real save and reading the count of files WRITTEN, not the count read back.
Check the step you changed, not the outcome downstream of it.

**A later registration of the same name silently wins.** The transposer's fluid methods were
written and registered, and then a block of `tr_unimplemented` stubs further down the same function
assigned `getTankLevel` and `transferFluid` over the top of them. The result read as nonsense -
`getTankCapacity` answered correctly while `getTankLevel`, two lines away in the same component,
answered "not implemented in the simulator yet". Guessing at that from the outside cost several
rounds; dumping the screen found it immediately. **When a result contradicts itself, print what the
machine actually said before reasoning any further.**

## Building

`make`. Needs `cl` on the PATH.

**Close the running simulator before rebuilding.** The link fails with `LNK1168: cannot open
main.exe for writing` while it is open, and the build then *appears* to succeed — leaving the old
binary running new scripts. The symptom is `class id ... doesn't have member: <name>`: the exe is
behind the Lua.

`Failed to execute loaded script` with no line number is a Lua **syntax** error, not a runtime one.

## Style

- 100 columns, code and comments alike.
- A comment block stays attached to every function; say what it does and why it is that way, not
  how. Where a decision came from the mod's behaviour, say so — that is what stops the next session
  reverting it to something more reasonable.
- Where a bug was subtle, record the symptom at the fix. Several comments here exist to stop a
  plausible-looking change being made again.
