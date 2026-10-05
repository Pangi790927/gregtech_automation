12 - crafting: Gunter makes what the ME is short of
=================================================

The user, 2026-10-05: "start 3b, gunter crafts the short items" - and, of the whole: "it puts
gunter to craft all needed subparts and lets the rest run, gunther will craft things with exec
practically". What was learned in-game is in `docs/materials.md` ("Crafting, by the robot") and
the old `craft.py`; it carries over, as data and as programs.

## Recipes, as data (`scripts/recipes.lua`)

Only what was crafted and checked in-game (craft.py's RECIPES, 2026-10-04): a pattern of 9
cells, row by row, each an item `name:meta`, `saw` (the GregTech saw, a crafting tool that comes
back into the grid, damaged) or empty; and how many one craft makes. Planks from each log (2),
sticks, the four stairs (4), wooden and stone slabs and glass panes with the saw, the spruce gate
and trapdoor (flint). What has no recipe is named and left to the user to put into the ME.

## What to make (the exe, from its view of the ME)

The plan's bill as items (11-me.md) against the exe's view of the ME: each item short, with a
recipe, is made - its ingredients first when they are short too (planks before stairs, sticks
before gates). At least 64 at a time (the user, 2026-10-04: "craft at least 64 or around that
at once"); gates, trapdoors and fences to the count, their flint and sticks not to be spent.

## A crafting run: Gunter stays at the interface

The user, 2026-10-05: "gunther seems to do something stuppid and keeps going back to his place
to craft small batches of material" - each batch had been a trip: out, a stack made, back home.
Now one run, at the interface throughout, home at its end:

- **A batch is full stacks:** up to 64 in each grid cell, crafted again and again (`c` into the
  storage slots 8, 12-16) until the grid is empty - up to 6 stacks of what it makes a batch.
- **Gunter's inventory:** the grid is slots 1-3, 5-7, 9-11; his saw lives in slot 4; storage,
  where what he makes goes, is 8, 12-16.
- **One `config`, one `exec` a batch:** the config stocks batch N+1's ingredients and clears what
  was left of batch N, in one line; after the tick, the exec gives batch N's stacks back into the
  slots not stocked, takes N+1's straight into the grid's cells (`t`), shifts the saw in where
  the pattern wants it (`s4.<cell>`), crafts, shifts the saw back, and halts there (`h`). A batch
  is sized so its ingredient slots and the stacks it gives back fit the interface's 9.
- **The end:** a config clearing all, the tick, and an exec giving the last stacks back and home.

The copy crafts too: simbot knows the recipes, so a pattern that would not craft stops the dry
run, and what the real Gunter made is compared with what his copy made - a recipe GTNH changed
shows at once. The exe's view: ingredients taken off, what was made added on.

## Open

- Doors (vanilla's six planks, to be tried in GTNH), torches (coal?), farmland (a hoe), wheat
  (seeds), water (a bucket): no recipe yet - named for the user.
- Gunter crafting while the others build: the crew of five.
