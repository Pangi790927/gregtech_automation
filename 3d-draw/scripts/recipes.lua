--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | Gunter's recipes, as data (redesign/12-craft.md): only what was crafted and checked in-game
-- | (the old craft.py's RECIPES, 2026-10-04; docs/materials.md, "Crafting, by the robot").
-- |
-- |     recipes.BY["name:meta"]       {pattern = 9 cells row by row ("name:meta" | "saw" | false),
-- |                                   yield = how many one craft makes, exact = made to the count}
-- |     recipes.GRID                  the robot's inventory slots of the 3x3 grid, cell by cell
-- |     recipes.SAW, recipes.SAW_SLOT the GregTech saw, and the slot it lives in
-- |     recipes.match(cells)          what a laid grid makes: "name:meta", per craft, or nil -
-- |                                   cells {[1..9] = "name:meta"}; the copies craft with it
-- |     recipes.plan(need, have)      what to make, in order, ingredients first: a list of
-- |                                   {item, crafts}; and what has no recipe {item = n short}
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local recipes = {}

recipes.GRID = {1, 2, 3, 5, 6, 7, 9, 10, 11}
recipes.SAW, recipes.SAW_SLOT = "gregtech:gt.metatool.01:10", 4
recipes.BATCH = 64       -- the user, 2026-10-04: "craft at least 64 or around that at once"

local S = "saw"
local LOG_S, LOG_B = "minecraft:log:1", "minecraft:log:2"
local LOG_A, LOG_D = "minecraft:log2:0", "minecraft:log2:1"
local PL_S, PL_B, PL_A, PL_D = "minecraft:planks:1", "minecraft:planks:2", "minecraft:planks:4",
                               "minecraft:planks:5"
local ST, SB, CB, GL = "minecraft:stick:0", "minecraft:stonebrick:0", "minecraft:cobblestone:0",
                       "minecraft:glass:0"
local FL, SL_S = "minecraft:flint:0", "minecraft:wooden_slab:1"
local _ = false

local function stairs(p) return {p, _, _, p, p, _, p, p, p} end

recipes.BY = {
    [PL_S] = {pattern = {LOG_S, _, _, _, _, _, _, _, _}, yield = 2},
    [PL_B] = {pattern = {LOG_B, _, _, _, _, _, _, _, _}, yield = 2},
    [PL_A] = {pattern = {LOG_A, _, _, _, _, _, _, _, _}, yield = 2},
    [PL_D] = {pattern = {LOG_D, _, _, _, _, _, _, _, _}, yield = 2},
    [ST] = {pattern = {PL_S, _, _, PL_S, _, _, _, _, _}, yield = 2},
    ["minecraft:spruce_stairs:0"] = {pattern = stairs(PL_S), yield = 4},
    ["minecraft:dark_oak_stairs:0"] = {pattern = stairs(PL_D), yield = 4},
    ["minecraft:acacia_stairs:0"] = {pattern = stairs(PL_A), yield = 4},
    ["minecraft:stone_brick_stairs:0"] = {pattern = stairs(SB), yield = 4},
    ["minecraft:stone_stairs:0"] = {pattern = stairs(CB), yield = 4},
    ["minecraft:wooden_slab:1"] = {pattern = {S, PL_S, _, _, _, _, _, _, _}, yield = 2},
    ["minecraft:wooden_slab:2"] = {pattern = {S, PL_B, _, _, _, _, _, _, _}, yield = 2},
    ["minecraft:wooden_slab:5"] = {pattern = {S, PL_D, _, _, _, _, _, _, _}, yield = 2},
    ["minecraft:stone_slab:5"] = {pattern = {S, SB, _, _, _, _, _, _, _}, yield = 1},
    ["minecraft:stone_slab:3"] = {pattern = {S, CB, _, _, _, _, _, _, _}, yield = 1},
    ["minecraft:glass_pane:0"] = {pattern = {S, GL, _, _, _, _, _, _, _}, yield = 2},
    ["ExtraTrees:fence:1"] = {pattern = {ST, PL_S, ST, ST, PL_S, ST, ST, PL_S, ST}, yield = 1,
                              exact = true},
    ["malisisdoors:spruceFenceGate:0"] = {pattern = {FL, _, FL, PL_S, ST, PL_S, PL_S, ST, PL_S},
                                          yield = 1, exact = true},
    ["malisisdoors:trapdoor_spruce:0"] = {pattern = {SL_S, ST, SL_S, ST, FL, ST, SL_S, ST, SL_S},
                                          yield = 1, exact = true},
}

-- What a laid grid makes: the recipe whose pattern it is, cell for cell (as laid by the exe:
-- always at the grid's top left, so no shape is looked for).
function recipes.match(cells)
    for item, r in pairs(recipes.BY) do
        local same = true
        for i = 1, 9 do
            local want, got = r.pattern[i], cells[i] or false
            if want == "saw" then want = recipes.SAW end
            if want ~= got then same = false break end
        end
        if same then return item, r.yield end
    end
end

-- What to make for `need` {item = n} against `have` {item = n} (the exe's view of the ME): each
-- short item with a recipe, at least BATCH (exact ones to the count), its ingredients first when
-- they run short too. -> {{item, crafts}, ...} in order; {item = n} with no recipe.
function recipes.plan(need, have)
    local stock, order, none = {}, {}, {}
    for k, v in pairs(have or {}) do stock[k] = v end
    local function make(item, n, depth)
        local r = recipes.BY[item]
        if not r or depth > 6 then
            none[item] = (none[item] or 0) + n
            return
        end
        local amount = r.exact and n or math.max(n, recipes.BATCH)
        local crafts = (amount + r.yield - 1) // r.yield
        local per = {}
        for _, c in ipairs(r.pattern) do
            if c and c ~= "saw" then per[c] = (per[c] or 0) + 1 end
        end
        for ing, k in pairs(per) do
            local want = k * crafts
            if (stock[ing] or 0) < want then make(ing, want - (stock[ing] or 0), depth + 1) end
            stock[ing] = (stock[ing] or 0) - want
        end
        order[#order + 1] = {item = item, crafts = crafts}
        stock[item] = (stock[item] or 0) + crafts * r.yield
    end
    local items = {}
    for item in pairs(need) do items[#items + 1] = item end
    table.sort(items)
    for _, item in ipairs(items) do
        local short = need[item] - (stock[item] or 0)
        if short > 0 then make(item, short, 0) end
        stock[item] = (stock[item] or 0) - need[item]
    end
    return order, none
end

return recipes
