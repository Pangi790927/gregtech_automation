rdb  = require("recipe_db")
ih   = require("item_helper")
hwif = require("hw_interface")
h    = require("helpers")
hwc  = require("hw_crafter")

hwif.init_hw()


function rec_craft_recipe(name, cnt, inv, sim_mode, miss_table)
    local recipe = rdb.find_recipes({item_name})[item_name]
    if not recipe then
        print("Recipe is not found in database for: " .. item_name)
        return false
    end

    local mats = hwc.get_missing_materials(inv, recipe, cnt)
    if mats then
        for k, v in pairs(mats) do
            local subrecipe = rdb.find_recipes({k})[k]
            if not subrecipe then
                if not sim_mode then
                    print("Missing " .. v.cnt .. "x" .. k)
                    return false
                else
                    if not miss_table[k] then
                        miss_table[k] = v.cnt
                    else
                        miss_table[k] = miss_table[k] + v.cnt
                    end
                end
            else
                if not rec_craft_recipe(k, v, inv, sim_mode) then
                    return false
                end
            end
        end
    else
        if not hwc.craft_items(recipe, cnt, inv, sim_mode) then
            return false
        end
    end
    return true
end

function craft_recipe(name, cnt)
    local inv = hwc.read_cchest()
    local miss_table = {}
    if not rec_craft_recipe(name, cnt, inv, true, miss_table) then
        return false
    end
    if next(miss_table) ~= nil then
        return false
    end
    if not rec_craft_recipe(name, cnt, inv, false, miss_table) then
        return false
    end
    return true
end