# The simulator: reading the mods

Part of the simulator's working instructions; the top, with the rules and how to check, is
`../CLAUDE.md`. What the mod's own files said, where, and what the plausible guess had been. Paths
are from `simulator/`.

## Where the facts for the liquid tank came from

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

## Item names come from the save, not the jars

The chest panel's item list is the modpack's **real registry**, read out of
`saves/<world>/level.dat` - the same list NEI shows, 10,432 entries on the author's install. Forge
writes it into every world so item ids survive a mod list changing, and it is the ONLY place on disk
that knows the real names: a golden apple's texture is `apple_golden.png`, its lang key is
`item.appleGold.name`, and the item is `minecraft:golden_apple`. No jar knows that.

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
none of that can be in a chest. A picture is attached when the vanilla jar has a texture whose file
name matches the part after the colon. GregTech draws thousands of items off one sheet indexed by
damage value, which a registry name cannot index into. An item with no picture still lists with a
blank square, because its name is what a program compares.

## GregTech's material list comes out of the bytecode

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

## Extract to a scratch directory, and check you got there

Reading a mod's bytecode means extracting `.class` files somewhere. **That somewhere must not be
the repository.** On 2026-09-17 a run of `cd "$SCRATCH" && python -c "...extract..."` left GregTech,
GT++, GoodGenerator and TecTech class files plus seven `javap` dumps sitting untracked in the repo
root, one `git add -A` away from being committed - compiled mod code and its disassembly, which is
exactly what this repository must never carry.

The cause was `cd` to a path that resolved to nothing: an empty argument leaves the shell where it
is and says nothing. Use an absolute scratch path, or `cd X || exit`, and check `git status` after a
session of jar-reading.

## Which modpack the readers follow

The jars are looked up by name (`mc_assets.h`), newest pack first: GTNH 2.4.0 (OpenComputers
1.9.14, gregtech 5.09.43.192, AE2 rv3-beta-250, EnderIO 2.4.24), then 2.3.0. GregTech 5.09.43
writes recipes with `GT_RecipeBuilder` (`stdBuilder()...addTo(map)`) rather than one
`addFusionReactorRecipe` call, and its `eut` names `TierEU` fields: `gt_tier_eu` reads them out of
`GT_Values` (`V`, and `VP = V * 30 / 32` from its lambda) and `TierEU`. Updated 2026-10-04, when
the user moved to 2.4.0 and 47 tests failed for want of the new jar names.
