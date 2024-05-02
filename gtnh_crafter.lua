rdb  = require("recipe_db")
ih   = require("item_helper")
hwif = require("hw_interface")
h    = require("helpers")
hwc  = require("hw_crafting")

function rec_craft_recipe(name, cnt, inv, sim_mode, miss_table)
    local recipe = rdb.find_recipes({name})[name]
    LOG("Crafting: %s", name)
    if not recipe then
        print("Recipe is not found in database for: " .. name)
        return false
    end

    local mats = hwc.get_missing_materials(inv, recipe, cnt)
    if mats then
        for k, v in pairs(mats) do
            local subname = k
            local subrecipe = rdb.find_recipes({subname})[subname]
            if (not subrecipe) and ih.is_cell_label(subname) then
                subname = ih.get_cell_label_fluid_name(subname)
                subrecipe = rdb.find_recipes({subname})[subname]
            end
            if not subrecipe then
                if not sim_mode then
                    print("Missing " .. v .. "x" .. subname)
                    return false
                else
                    if not miss_table[subname] then
                        miss_table[subname] = v
                    else
                        miss_table[subname] = miss_table[subname] + v
                    end
                end
            else
                if not rec_craft_recipe(subname, v, inv, sim_mode, miss_table) then
                    return false
                end
            end
        end
    end
    if not hwc.craft_items(inv, name, cnt, sim_mode) then
        return false
    end
    return true
end

function print_miss_table(miss_table)
    if not miss_table then
        return
    end
    for k, v in pairs(miss_table) do
        print("missing:" .. k .. " x" .. v)
    end
end

function craft_recipe(name, cnt)
    local inv = hwc.read_cchest()
    local miss_table = {}
    if not rec_craft_recipe(name, cnt, h.copy(inv), true, miss_table) then
        return false
    end
    if next(miss_table) ~= nil then
        print_miss_table(miss_table)
        return false
    end
    if not rec_craft_recipe(name, cnt, inv, false, miss_table) then
        return false
    end
    return true
end

return {}

-- lua
-- require("crafter")
-- craft_recipe("integrated_logic_circuit2", 1)
-- craft_recipe("good_integrated_circuit", 1)
-- craft_recipe("advanced_circuit", 1)
-- craft_recipe("iron_iii_chloride", 1)
-- craft_recipe("smd_transistor", 64)
-- rdb.find_recipes({"good_circuit_board"})["good_circuit_board"]

-- name = "good_circuit_board"
-- cnt = 1
-- sim_mode = true
