rdb  = require("recipe_db")
ih   = require("item_helper")
hwif = require("hw_interface")
h    = require("helpers")
s    = require("sides")

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
    local in_mul = 1
    local out_mul = 1
    if recipe.liq.label ~= "none" then
        in_mul = liq_min_cells(recipe.liq.cnt, recipe.liq.msz)
    end
    if recipe.liq_out.label ~= "none" then
        out_mul = liq_min_cells(recipe.liq_out.cnt, recipe.liq_out.msz)
    end
    recipe_mul = recipe_mul * h.lcd(in_mul, out_mul)
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
            msz = recipe.comp[i].msz,
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
    return max_liq_batch
end

function hwc.get_missing_materials(inv, recipe, cnt)
    local min_recipe = get_min_recipe(recipe)
    local req_recipe = {}
    local _cnt = cnt
    if recipe.is_liq == 1 then
        _cnt = _cnt * recipe.liq_out.msz
    end
    local mul = math.ceil(_cnt / get_min_recipe_res_cnt(recipe))

    for k, v in pairs(min_recipe) do
        req_recipe[k] = min_recipe[k].cnt * mul
        LOG(">> req_recipe[%s] = %d", k, req_recipe[k])
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

function create_batch(recipe, cnt)
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
    local _cnt = cnt
    if recipe.is_liq == 1 then
        _cnt = _cnt * recipe.liq_out.msz
    end
    if batch_cnt * min_res > _cnt then
        local new_bc = math.ceil(_cnt / min_res)
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
            msz = recipe.out[i].msz,
            as_liq = false
        }
        table.insert(batch_outs, out_item)
    end
    if recipe.liq_out.label ~= "none" then
        local out_item = {
            label = ih.label2cell_label(recipe.liq_out.label),
            cnt = recipe.liq_out.cnt * min_mul * batch_cnt / recipe.liq_out.msz,
            liq_cnt = recipe.liq_out.cnt * min_mul * batch_cnt,
            as_liq = true
        }
        table.insert(batch_outs, out_item)
    end

    local batch = {
        inputs = batch_mats,
        cnt = batch_cnt * recipe.res_cnt,
        outs = batch_outs
    }

    return batch
end

function wait_ammount(mach, slot, ammount)
    while true do
        local item = mach.trans.getStackInSlot(mach.side, slot)
        if item and item.size == ammount then
            break
        elseif item and item.size > ammount then
            critical_message("wait_ammount: too many results")
        end
        os.sleep(1)
    end
end

-- cchest_in -> slot to take filled cells from
-- cchest_out -> slot to store empty cells to
function hwc.transfer_cell2liq(cchest_in, cchest_out, target_mach, cell_cnt)
    local mcann = hwif.machines.canner
    local expetect_liq = cell_cnt * hwif.cchest_get(cchest_in).amount
    if mcann.trans.transferItem(mcann.cside, mcann.side, cell_cnt,
            cchest_in, hwif.machine_io[mcann.id].inputs[1]) ~= cell_cnt
    then
        critical_message("Failed machine cell transfer 1")
    end
    hwif.rs_set(target_mach.trans.liq_in)
    while true do
        local liq_cnt = target_mach.trans.getTankLevel(s.down)
        if liq_cnt == expetect_liq then
            break
        elseif liq_cnt > expetect_liq then
            critical_message("More liquid than expected from cells")
        end
        os.sleep(1)
    end
    hwif.rs_reset(target_mach.trans.liq_in)
    target_mach.trans.transferFluid(s.down, target_mach.side, expetect_liq)
    if mcann.trans.transferItem(mcann.side, mcann.cside, cell_cnt,
            hwif.machine_io[mcann.id].outs[1], cchest_out) ~= cell_cnt
    then
        critical_message("Failed machine cell transfer 2")
    end
end

function hwc.transfer_liq2cell(source_mach, cchest_in, cchest_out, cell_cnt)
    local mcann = hwif.machines.canner
    if mcann.trans.transferItem(mcann.cside, mcann.side, cell_cnt,
            cchest_in, hwif.machine_io[mcann.id].inputs[1]) ~= cell_cnt
    then
        critical_message("Failed machine empty cell transfer")
    end
    source_mach.trans.transferFluid(source_mach.side, s.down, max_machine_liters)
    hwif.rs_set(source_mach.trans.liq_out)
    wait_ammount(mcann, hwif.machine_io[mcann.id].outs[1], cell_cnt)
    if mcann.trans.transferItem(mcann.side, mcann.cside, cell_cnt,
            hwif.machine_io[mcann.id].outs[1], cchest_out) ~= cell_cnt
    then
        critical_message("Failed machine filled cell transfer")
    end
    hwif.rs_reset(source_mach.trans.liq_out)
end

function hwc.transfer_item2mach(cchest_slot, target_mach, item_cnt)
    -- move the item into the machine
    if target_mach.trans.transferItem(target_mach.cside, target_mach.side, item_cnt,
            cchest_slot) ~= item_cnt
    then
        critical_message("Failed machine filled cell transfer")
    end
end

function hwc.transfer_mach2item(target_mach, source_slot, cchest_slot, item_cnt)
    -- move the item from the machine
    if target_mach.trans.transferItem(target_mach.side, target_mach.cside, item_cnt,
            source_slot, cchest_slot) ~= item_cnt
    then
        critical_message("Failed machine filled cell transfer")
    end
end

function inv_transfer_cnt(inv, i, cnt, is_liq)
    -- TODO: find a space for cells
    local cell_slot = nil
    if is_liq then
        for j = 1, cchest_workspace_end do
            if ih.get_name(inv[j]) == "empty_cell" and inv[j].size + cnt <= 64 then
                cell_slot = j
                inv[j].size = inv[j].size + cnt
                break
            end
        end
        if cell_slot == nil then
            for j = 1, cchest_workspace_end do
                if inv[j] == nil then
                    cell_slot = j
                    inv[j] = hwif.cchest_get(hwif.cchest_cells_slot)
                    inv[j].size = cnt
                    break
                end
            end
        end
        if cell_slot == nil then
            return 0, 0
        end
    end
    if inv[i].size > cnt then
        inv[i].size = inv[i].size - cnt
        return cnt, cell_slot
    else
        local ret = inv[i].size
        inv[i] = nil
        return ret, cell_slot
    end
end

function craft_batch(inv, machine, batch, sim_mode)
    -- this will send the batch to the respective machine
    local cbatch = h.copy(batch)
    for i = 1, cchest_workspace_end do
        for k, v in pairs(cbatch.inputs) do
            if k == ih.get_name(inv[i]) and v.cnt >= 1 then
                local to_transfer, cslot = inv_transfer_cnt(inv, i, v.cnt, v.as_liq)
                if to_transfer == 0 then
                    return false
                end
                if not sim_mode then
                    if v.as_liq then
                        hwc.transfer_cell2liq(i, cslot, machine, to_transfer)
                    else
                        hwc.transfer_item2mach(i, machine, to_transfer)
                    end
                end

                v.cnt = v.cnt - to_transfer
            end
        end
    end
    for k, v in pairs(cbatch.inputs) do
        if v.cnt > 0 then
            return false
        end
    end
    return true
end

function wait_batch(inv, machine, batch, sim_mode)
    if sim_mode then
        return true
    end
    local done = false
    while not done do
        for i = 1, #batch.outs do
            local item = batch.outs[i]
            if item.as_liq == true then
                local liq_ammount = machine.trans.getTankLevel(machine.side, 2)
                if liq_ammount == item.liq_cnt then
                    done = true
                    break
                elseif liq_ammount > item.liq_cnt then
                    critical_message("More liquid than expected in out slot")
                end
            else
                local out_slots = hwif.machine_io[machine.id].outs
                for j = 1, #out_slots do
                    local res = machine.trans.getStackInSlot(machine.side, out_slots[j])
                    if ih.get_name(res) == item.label and res.size == item.cnt then
                        done = true
                        break
                    elseif ih.get_name(res) == item.label and res.size > item.cnt then
                        critical_message("More item than expected in out slot")
                    end
                end
            end
        end
        os.sleep(1)
    end
end

function collect_batch(inv, machine, batch, sim_mode)
    for i = 1, #batch.outs do
        local item = batch.outs[i]
        if item.as_liq == true then
            local cell_cnt = item.cnt
            local cell_src = nil
            local rem_cell_cnt = cell_cnt
            for j = 1, cchest_workspace_end do
                if ih.get_name(inv[j]) == "empty_cell" then
                    if not cell_src then
                        cell_src = j
                        rem_cell_cnt = cell_cnt - inv[j].size
                        if rem_cell_cnt < 0 then
                            rem_cell_cnt = 0
                        end
                    else
                        local to_transfer = inv_transfer_cnt(inv, j, rem_cell_cnt)
                        if not sim_mode then
                            if machine.trans.transferItem(machine.cside, machine.cside, to_transfer,
                                    j, cell_src) ~= to_transfer
                            then
                                critical_message("Failed internal cell transfer from:" .. j .. ", to:" .. cell_src)
                            end
                        end

                        rem_cell_cnt = rem_cell_cnt - to_transfer
                    end
                end
                if rem_cell_cnt == 0 then
                    break
                end
            end
            if rem_cell_cnt > 0 or cell_src == nil then
                print("Failed to get enaugh empty cells")
                return false
            end
            local cell_dst = nil
            for j = 1, cchest_workspace_end do
                if inv[j] == nil then
                    cell_dst = j
                end
            end
            if cell_dst == nil then
                print("Failed to get enaugh space for resulting cells")
                return false
            end
            inv[cell_src].size = inv[cell_src].size - cell_cnt
            -- TODO: inv[cell_dst] = 
            if not sim_mode then
                hwc.transfer_liq2cell(machine, cell_src, cell_dst, cell_cnt)
            end
        else
            local src_slot = nil
            if not sim_mode then
                local out_slots = hwif.machine_io[machine.id].outs
                for j = 1, #out_slots do
                    local res_item = machine.trans.getStackInSlot(machine.side, out_slots[j])
                    if res_item and ih.get_name(res_item) == item.label then
                        src_slot = out_slots[j]
                        break
                    end
                end
                if not src_slot then
                    critical_message("expected output not found in machine output")
                end
            end

            local to_move = item.cnt
            local msz = 0
            for j = 1, cchest_workspace_end do
                if ih.get_name(inv[j]) == item.label then
                    local to_transfer = 0
                    msz = inv[j].maxSize
                    if to_move + inv[j].size <= msz then
                        inv[j].size = inv[j].size + to_move
                        to_transfer = to_move
                        to_move = 0
                    else
                        to_move = to_move + inv[j].size - msz
                        to_transfer = msz - inv[j].size
                        inv[j].size = msz
                    end
                    if not sim_mode then
                        hwc.transfer_mach2item(machine, src_slot, j, to_transfer)
                    end
                end
            end
            if to_move > 0 then
                for j = 1, cchest_workspace_end do
                    if inv[j] == nil then
                        inv[j] = {
                            label = item.label,
                            maxSize = msz,
                            size = to_move
                        }
                        if not sim_mode then
                            hwc.transfer_mach2item(machine, src_slot, j, to_move)
                        end
                        break
                    end
                end
            end
        end
    end
end

function hwc.prepare_machine(mach_id, mach_cfg, sim_mode)
    local machine = nil
    if not sim_mode then
        machine = hwif.machines[hwif.craft_info[mach_id].mach_name]
        local cfg_slot = hwif.craft_info[mach_id].cfg
        local mach_io = hwif.machine_io[machine.id]

        if cfg_slot and mach_cfg then
            hwif.reset_machine(machine)
            os.sleep(1)
            if not mach_io.cfg then
                critical_message("machine config required where no config possible")
            end
            if machine.trans.transferItem(machine.cside, machine.side, 1,
                    cfg_slot + mach_cfg - 1, mach_io.cfg) ~= 1
            then
                critical_message("Failed machine cfg")
            end
        end
        os.sleep(1)
    end
end

function hwc.craft_items(inv, item_name, cnt, sim_mode)
    if not sim_mode then
        print("Crafting " .. item_name .. " x" .. cnt)
    end
    local recipe = rdb.find_recipes({item_name})[item_name]
    if not recipe then
        print("Recipe is not found in database for: " .. item_name)
        return false
    end
    if (not sim_mode) and hwc.get_missing_materials(inv, recipe, cnt) ~= nil then
        print("Can't start crafting without all the materials")
        return false
    end
    -- set the machine to the right configuration
    local machine = hwc.prepare_machine(recipe.mach_id, recipe.mach_cfg, sim_mode)

    -- now craft the thing
    local _cnt = cnt
    if recipe.is_liq == 1 then
        _cnt = _cnt * recipe.liq_out.msz
    end
    while true do
        local batch = create_batch(recipe, cnt)
        craft_batch(inv, machine, batch, sim_mode)
        wait_batch(inv, machine, batch, sim_mode)
        collect_batch(inv, machine, batch, sim_mode)
        _cnt = _cnt - batch.cnt
        if _cnt <= 0 then
            break
        end
    end
    if (not sim_mode) and recipe.mach_cfg then
        hwif.reset_machine(machine)
    end
    return true
end

return hwc

-- hwc = require("hw_crafting")
-- inv = hwc.read_cchest()
-- hwc.craft_items(inv, "gold_foil", 4, false)

-- 1x_annealed_copper_wire
-- integrated_logic_circuit_(wafer)
-- integrated_logic_circuit

-- silver_bolt
-- fine_electrum_wire
-- gold_foil
-- fine_gold_wire
-- annealed_copper_bolt

-- smd_resistor
-- hydrochloric_acid_cell
-- iron_iii_chloride
-- good_circuit_board

-- integrated_logic_circuit2
-- good_integrated_circuit

-- rdb  = require("recipe_db")
-- recipe = rdb.find_recipes({"good_circuit_board"})["good_circuit_board"]
-- batch = create_batch(recipe, 1)
-- craft_batch(inv, hwif.machines.chem_reactor, batch, false)
-- wait_batch(inv, hwif.machines.chem_reactor, batch, false)
-- collect_batch(inv, hwif.machines.chem_reactor, batch, false)

-- machine = hwif.machines.assembler
-- sim_mode = false
-- hwc.transfer_cell2liq(2, 1, hwif.machines.chem_reactor, 10)
