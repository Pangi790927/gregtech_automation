rdb  = require("recipe_db")
ih   = require("item_helper")
hwif = require("hw_interface")
h    = require("helpers")

hwc = {}

cchest_workspace_end = 72
max_machine_liters = 16000

function critical_message(msg)
    print("CRITICAL: " .. msg)
    hwif.rs_set(hwif.alarm)
    print("You must manually close the pc to repair the crafter")
    while true do
        os.sleep(1)
    end
end

function hwc.read_cchest()
    local ret = {}
    for i=1, cchest_workspace_end do
        ret[i] = hwif.cchest_get(i)
    end
    return ret
end

function liq_min_cells(cnt, msz)
    local in_liq = cnt
    local int_liq = (in_liq // msz) * msz
    if int_liq ~= in_liq then
        return msz // (in_liq - int_liq)
    else
        return 1
    end
end

function get_min_recipe_cnt(recipe)
    local recipe_mul = 1
    if recipe.is_liq == 1 then
        local in_mul = 1
        local out_mul = 1
        if recipe.liq.label ~= "none" then
            in_mul = liq_min_cells(recipe.liq.cnt, recipe.liq.msz)
        end
        if recipe.liq_out.label ~= "none" then
            out_mul = liq_min_cells(recipe.liq_out.cnt, recipe.liq_out.msz)
        end
        recipe_mul = recipe_mul * h.lcd(in_mul, out_mul)
    end
    return recipe_mul
end

function get_min_recipe_res_cnt(recipe)
    return recipe.res_cnt * get_min_recipe_cnt(recipe)
end

function get_min_recipe(recipe)
    local min_cnt = get_min_recipe_cnt(recipe)
    local min_recipe = {}
    for i = 1, #recipe.comp do
        min_recipe[recipe.comp[i].label] = {
            cnt = recipe.comp[i].cnt * min_cnt,
            msz = recipe.comp[i].msz
            as_liq = false
        }
        if min_recipe[recipe.comp[i].label].cnt > recipe.comp[i].msz then
            critical_message("Malformed recipe: " .. recipe.label)
        end
    end
    if recipe.liq.label ~= "none" then
        if recipe.liq.cnt * min_cnt > max_machine_liters then
            critical_message("Invalid recipe, min recipe requires more [liq in] space than existing")
        end
        min_recipe[ih.label2cell_label(recipe.liq.label)] = {
            cnt = recipe.liq.cnt * min_cnt / recipe.liq.msz,
            msz = 64,
            as_liq = true
        }
    end
    return min_recipe
end

function get_max_liq_batch(recipe)
    local min_cnt = get_min_recipe_cnt(recipe)
    local max_liq_batch = 64
    if recipe.liq.label ~= "none" then
        if max_machine_liters // (recipe.liq.cnt * min_cnt) < max_liq_batch then
            max_liq_batch = max_machine_liters // (recipe.liq.cnt * min_cnt)
        end
    end
    if recipe.liq_out.label ~= "none" then
        if max_machine_liters // (recipe.liq_out.cnt * min_cnt) < max_liq_batch then
            max_liq_batch = max_machine_liters // (recipe.liq_out.cnt * min_cnt)
        end
    end
    return min_liq
end

function hwc.get_missing_materials(inv, recipe, cnt)
    local min_recipe = get_min_recipe(recipe)
    local req_recipe = {}
    local mul = math.ceil(cnt / get_min_recipe_res_cnt(recipe))

    for k, v in pairs(min_recipe) do
        req_recipe[k] = min_recipe[k].cnt * mul
    end

    for i = 1, cchest_workspace_end do
        for k, v in pairs(req_recipe) do
            if ih.get_name(inv[i]) == k then
                req_recipe[k] = req_recipe[k] - ih.count(inv[i])
                if req_recipe[k] <= 0 then
                    req_recipe[k] = nil
                end
            end
        end
    end
    if next(req_recipe) == nil then
        return nil
    end

    return req_recipe
end

function create_batch(inv, recipe, cnt)
    local min_recipe = get_min_recipe(recipe)
    local batch_cnt = get_max_liq_batch(recipe)
    local min_mul = get_min_recipe_cnt(recipe)
    local min_res = get_min_recipe_res_cnt(recipe)

    -- find out how many outs can we have at the same time
    for i = 1, #recipe.out do
        if recipe.out[i].cnt * min_mul * batch_cnt > recipe.out[i].msz then
            batch_cnt = recipe.out[i].msz // (recipe.out[i].cnt * min_mul)
        end
    end

    -- find out how many ins we can have at the same time
    for k, v in pairs(min_recipe) do
        if v.cnt * batch_cnt > v.msz then
            batch_cnt = v.msz // v.cnt
        end
    end

    -- make sure to try not to craft more than required
    if batch_cnt * min_res > cnt then
        local new_bc = math.ceil(cnt / min_res)
        if new_bc < batch_cnt then
            batch_cnt = new_bc
        end
    end

    if batch_cnt < 1 then
        critical_message("Batch cnt is 0")
    end

    local batch_mats = {}
    for k, v in pairs(min_recipe) do
        batch_mats[k] = h.copy(v)
        batch_mats[k].cnt = v.cnt * batch_cnt
    end

    local batch_outs = {}
    for i = 1, #recipe.out do
        local out_item = {
            label = recipe.out[i].label,
            cnt = recipe.out[i].cnt * min_mul * batch_cnt,
            as_liq = false
        }
        table.insert(batch_outs, out_item)
    end
    if recipe.liq_out.label ~= "none" then
        local out_item = {
            label = ih.label2cell_label(recipe.liq_out.label),
            cnt = recipe.liq_out.cnt * min_mul * batch_cnt / recipe.liq_out.msz,
            as_liq = true
        }
        table.insert(batch_outs, out_item)
    end

    local batch = {
        inputs = batch_mats
        cnt = batch_cnt
        outs = batch_outs
    }

    return batch
end

function transfer_cell2liq(cchest_slot, target_mach, cell_cnt)
    -- to do this you will want to transfer all the required cells to the canner, at most
    -- 64 at a time, wait for the canner to finish and route the resulting liquid to the machine
end

function transfer_liq2cell(source_mach, cchest_slot, cell_cnt)
end

function transfer_item2mach(cchest_slot, target_mach, item_cnt)
end

function transfer_mach2item(source_mach, cchest_slot, item_cnt)
end

function inv_transfer_cnt(inv, i, cnt)
    if inv[i].size > cnt then
        inv[i].size = inv[i].size - cnt
        return cnt
    else
        local ret = inv[i].size
        inv[i] = nil
        return ret
    end
end

function craft_batch(inv, machine, batch, sim_mode)
    -- this will send the batch to the respective machine
    for i = 1, cchest_workspace_end do
        for k, v in pairs(batch.inputs) do
            if k == ih.get_name(inv[i]) and v.cnt >= 1 then
                local to_transfer = inv_transfer_cnt(inv, i, v.cnt)
                if not sim_mode then
                    if v.as_liq then
                        transfer_cell2liq(i, machine, to_transfer)
                    else
                        transfer_item2mach(i, machine, to_transfer)
                    end
                end
                v.cnt = v.cnt - to_transfer
            end
        end
    end
end

function wait_batch(inv, machine, batch, sim_mode)
    if sim_mode then
        return true
    end

    -- This here is like so:
    -- if we wait for a liquid, we must check the liquid count somehow
    -- if we wait for an item we must iterate it's input slots and check for their content

    while true do
        -- local item = trans.getStackInSlot(side, out_slot)
        -- if item and ih.get_name(item) ~= r.label then
        --     critical_message("Machine didn't craft the expected item: "
        --             .. ih.get_name(item) .. " expected: " .. r.label)
        -- end
        -- if item and item.size == expected_res then
        --     break
        -- elseif item and item.size > expected_res then
        --     critical_message("Wiremill - too many results")
        -- end
        -- os.sleep(1)
    end
    -- this will wait for the batch to finish
end

function collect_batch(inv, machine, batch, sim_mode)
    -- this will take the items from the machine back into the crafting chest

    -- if it has liquids, pack them into cells and send them into the inventory grid
    -- if it has items just send them into the inventory grid
end

function hwc.craft_items(inv, item_name, cnt, sim_mode)
    local recipe = rdb.find_recipes({item_name})[item_name]
    if not recipe then
        print("Recipe is not found in database for: " .. item_name)
        return false
    end
    if not sim_mode and hwc.get_missing_materials(inv, recipe, cnt) ~= nil then
        print("Can't start crafting without all the materials")
        return false
    end
    -- set the machine to the right configuration
    local machine = nil
    if not sim_mode then
        machine = hwif.machines[hwif.craft_info[recipe.mach_id].mach_name]
        local cfg_slot = hwif.craft_info[recipe.mach_id].cfg
        local mach_io = hwif.mach_io[machine.id]

        hwif.reset_machine(machine)
        os.sleep(1)
        if cfg_slot and recipe.mach_cfg then
            if not mach_io.cfg then
                critical_message("machine config required where no config possible")
            end
            if trans.transferItem(machine.cside, machine.side, 1,
                    cfg_slot + machine.mach_cfg - 1, mach_io.cfg) ~= 1
            then
                critical_message("Failed machine cfg")
            end
        end
        os.sleep(1)
    end
    -- now craft the thing
    while true do
        local batch = create_batch(inv, recipe, cnt)
        craft_batch(inv, machine, batch, sim_mode)
        wait_batch(inv, machine, batch, sim_mode)
        collect_batch(inv, machine, batch, sim_mode)
        cnt = cnt - batch.cnt
        if cnt <= 0 then
            return true
        end
    end
    if not sim_mode then
        hwif.reset_machine(machine)
    end
end





















function validate_materials(inv, recipe, cnt)
    local mats = {}
    for i = 1, #recipe.comp do
        mats[recipe.comp[i].label] = math.ceil(recipe.comp[i].cnt * cnt / recipe.res_cnt)
    end
    for i = 1, cchest_workspace_end do
        for k, v in pairs(mats) do
            if inv[i] and not ih.is_cell(inv[i]) and ih.get_name(inv[i]) == k then
                mats[k] = mats[k] - ih.count(inv[i])
            end
        end
    end
    local ret = true
    for k, v in pairs(mats) do
        if v > 0 then
            print("Missing material " .. k .. " X " .. v)
            ret = false
        end
    end
    return ret
end

batch_example = {
    in_items = { -- can be empty
        { label="iron_ingot", cnt=batch_in_cnt1, max_stack=64 },
        { label="gold_ingot", cnt=batch_in_cnt2, max_stack=1 },
    },
    out_items = { -- can be empty
        { label="gold_nugget", cnt=batch_out_cnt1, max_stack=16 },
        { label="gold_door", cnt=batch_out_cnt2, max_stack=1 },
    },
    in_liq = { label="hidrogen", liters=2000, cell_sz=1000 }, -- can be nil
    out_liq = { label="diamond_liq", liters=288, cell_sz=144 }, -- can be nil
}

-- this functions takes as an input the fluid name and results in cells fluid cells
function hwc.chem_reactor(inv, fluid_name, cnt, sim_mode)
    local r = rdb.find_recipes({fluid_name})[fluid_name]
    if not r then
        print("Recipe was not found in DB, can't craft it")
        return false
    end
    local in1 = nil
    local in2 = nil
    if #r.comp >= 1 then
        in1 = r.comp[1]
    end
    if #r.comp >= 2 then
        in2 = r.comp[2]
    end
    local inl = nil
    if r.liq and r.liq.label ~= "none" then
        inl = r.liq
    end
    -- TODO: verify items(in1, in2, cell(inl)) are there
    local out1 = nil
    local out2 = nil
    if #r.out >= 1 then
        out1 = r.out[1]
    end
    if #r.out >= 2 then
        out2 = r.out[2]
    end
    local outl = nil
    if r.liq_out and r.liq_out.label ~= "none" then
        outl = r.liq_out
    end
    -- create a batch describing the maximum craft
    -- send batched items and liquids to the reactor
    -- wait for the reactor to craft the expected liquid
    -- take the batch outputs and the batch liquids as cells
    -- repeat until the whole recipe is done
end

-- TODO: split in more functions:
--       a. calculate batch
--       b. insert batch input
--       c. wait for output
--       d. take output batch
-- sim_mode tells the api if it should really craft the recipe or only simulate it
function hwc.wiremill_craft(inv, item_name, cnt, sim_mode)
    local r = rdb.find_recipes({item_name})[item_name]
    if not r then
        print("Recipe was not found in DB, can't craft it in wiremill")
        return false
    end
    if not validate_materials(inv, r, cnt) then
        print("Missing materials...")
        return false
    end

    -- TODO: use the new msz to figure out max batch size
    -- TODO: fix this, we don't know inputs or outputs stack to 64
    -- we won't use more than 64 items in a slot at a time for crafting
    local batch_cnt = 64 // r.res_cnt
    for i = 1, #r.comp do
        if r.comp[i].cnt * batch_cnt > 64 then
            batch_cnt = 64 // r.comp[i].cnt
        end
    end

    -- TODO: add liquid support to the crafter
    -- TODO: make a generic crafter for items, not only for wiremill
    local wiremill_in_slot = 6
    local cfg_slot = 7
    local out_slot = 8
    local cfg_offset = hwif.cchest_circuits_slot
    local trans = hwif.machines.wiremill.trans
    local side = hwif.machines.wiremill.side
    local cchest_side = s.south

    if not sim_mode then
        hwif.reset_machine(hwif.machines.wiremill)
        os.sleep(1)
        if r.mach_cfg then
            if trans.transferItem(cchest_side, side, 1,
                    cfg_offset + r.mach_cfg - 1, cfg_slot) ~= 1
            then
                critical_message("Failed machine cfg")
            end
        end
        os.sleep(1)
    end

    while true do
        local batch_mats = {}
        if batch_cnt * r.res_cnt > cnt then
            batch_cnt = math.ceil(cnt / r.res_cnt)
        end
        for i = 1, #r.comp do
            batch_mats[r.comp[i].label] = batch_cnt * r.comp[i].cnt
        end
        for i = 1, cchest_workspace_end do
            local j = 0
            for k, v in pairs(batch_mats) do
                if inv[i] and not ih.is_cell(inv[i]) and ih.get_name(inv[i]) == k then
                    local sz = inv[i].size
                    local transfer_sz = 0
                    if batch_mats[k] >= sz then
                        batch_mats[k] = batch_mats[k] - sz
                        inv[i] = nil
                        transfer_sz = sz
                    else
                        inv[i].size = inv[i].size - batch_mats[k]
                        transfer_sz = batch_mats[k]
                        batch_mats[k] = 0
                    end
                    if not sim_mode then
                        if trans.transferItem(cchest_side, side, transfer_sz, i,
                                wiremill_in_slot + j) ~= transfer_sz
                        then
                            critical_message("Wiremill - failed IN transfer")
                        end
                    end
                end
                j = j + 1
            end
        end
        for k, v in pairs(batch_mats) do
            if v > 0 then
                if not sim_mode then
                    critical_message("not all mats in batch where sent to crafting")
                end
            end
        end
        -- now the batch is crafting, we will wait for it to finish it's job
        local expected_res = batch_cnt * r.res_cnt
        while true do
            if sim_mode then
                -- in simulation we do nothing
                break
            end
            local item = trans.getStackInSlot(side, out_slot)
            if item and ih.get_name(item) ~= r.label then
                critical_message("Machine didn't craft the expected item: "
                        .. ih.get_name(item) .. " expected: " .. r.label)
            end
            if item and item.size == expected_res then
                break
            elseif item and item.size > expected_res then
                critical_message("Wiremill - too many results")
            end
            os.sleep(1)
        end
        -- TODO: account for multilpe outputs (only in cutter and chem_reactor)

        -- now we have the items in the output slot, so we must transfer them to
        -- some free space inside the crafting chest, we will do that in two stages,
        -- first we will try to stack it with an item with the same name and
        -- second we will put it in a new slot
        local to_store = expected_res
        -- first: try to stack
        for i = 1, cchest_workspace_end do
            local to_transfer = 0
            if inv[i] and not ih.is_cell(inv[i]) and ih.get_name(inv[i]) == r.label then
                if inv[i].size < inv[i].maxSize then
                    if inv[i].size + to_store <= inv[i].maxSize then
                        to_transfer = to_store
                        inv[i].size = inv[i].size + to_store
                        to_store = 0
                    else
                        to_transfer = inv[i].maxSize - inv[i].size
                        to_store = to_store - to_transfer
                        inv[i].size = inv[i].maxSize
                    end
                end
            end
            if to_transfer > 0 and not sim_mode then
                if trans.transferItem(side, cchest_side, to_transfer,
                        out_slot, i) ~= to_transfer
                then
                    critical_message("Wiremill - failed OUT transfer")
                end
            end
        end
        -- second: try empty slots
        for i = 1, cchest_workspace_end do
            local to_transfer = 0
            if to_store <= 0 then
                break
            end
            if not inv[i] then
                if sim_mode then
                    -- TODO: fix this, we don't know the stack size of the item, assume it is 64
                    inv[i] = { label = r.label, maxSize = 64 }
                else
                    local item = trans.getStackInSlot(side, out_slot)
                    inv[i] = item
                    inv[i].size = 0
                end
                if to_store > inv[i].maxSize then
                    inv[i].size = inv[i].maxSize
                    to_transfer = inv[i].maxSize
                    to_store = to_store - inv[i].maxSize
                else
                    inv[i].size = to_store
                    to_transfer = to_store
                    to_store = 0
                end
                if not sim_mode then
                    if trans.transferItem(side, cchest_side, to_transfer,
                            out_slot, i) ~= to_transfer
                    then
                        critical_message("Wiremill - failed OUT2 transfer")
                    end
                    inv[i] = trans.getStackInSlot(cchest_side, i)
                end
            end
        end
        if to_store > 0 then
            if not sim_mode then
                critical_message("No more space for crafting")
            else
                print("No enaugh space for crafting")
            end
            return false
        end

        cnt = cnt - expected_res
        if cnt <= 0 then
            -- this means that the crafting is done
            break
        end
    end
    if not sim_mode then
        hwif.reset_machine(hwif.machines.wiremill)
    end
end

return hwc

-- hwc = require("hw_crafting")
-- inv = hwc.read_cchest()
-- r = rdb.find_recipes({"fine_gold_wire"})["fine_gold_wire"]
-- hwc.wiremill_craft(inv, r.label, 1, false)