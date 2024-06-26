local h       = require("helpers")
local thread  = require("thread")
local event   = require("event")
local ser     = require("serialization")
local fs      = require("filesystem")
local deflate = require("deflate")
local nbt     = require("nbt")
local ih      = require("item_helper")
local hwif    = require("hw_interface")
local hwc     = require("hw_crafting")
local th      = require("thread_helper")

-- queue for registering new recipes
local reciper2crafter = th.create_channel("r2c")

local crafts_path = "/home/crafts.db"

local pattern_slot = 20
local machine_slot = 23
local config_slot = 26
local liquid_in_slot = 47
local liquid_out_slot = 53

local cf = fs.open(crafts_path)

local function read_all()
    local ret = ""
    local read_res = cf:read(1000000000)
    while read_res do
        ret = ret .. read_res
        read_res = cf:read(1000000000)
    end
    return ret
end

local crafts
if cf then
    crafts = ser.unserialize(read_all())
else
    crafts = {}
end

local function update_files()
    local cf = fs.open(crafts_path, "w")
    cf:write(ser.serialize(crafts))
    cf:close()
end

local function add_crafting_recipe(registration)
    th.tprint("registering recipe uid: " .. registration.uid)

    crafts[registration.uid] = registration

    local cf = fs.open(crafts_path, "w")
    cf:write(ser.serialize(crafts))
    cf:close()
end

local function has_recipe_name(str)
    return (string.sub(str, 1, string.len("recipe_")) == "recipe_")
end

local function get_recipe_name(item)
    if item and item.label then
        local label = ih.get_name(item)
        if label and (label == "inscriber_name_press") then
            local outpattern = {}
            deflate.gunzip({
                input = item.tag,
                output = function(byte)
                    outpattern[#outpattern+1] = string.char(byte)
                end,
                disable_crc = true
            })
            local r = nbt.readFromNBT(outpattern)
            local recipe_name = nil
            if r and r.InscribeName then
                recipe_name = r.InscribeName
                return true, string.lower(recipe_name)
            end
        end
        if label and has_recipe_name(label) and item.name == "minecraft:stick"
        then
            return true, string.lower(label)
        end
    end
    return false, nil
end

local function get_one_recipe()
    -- cchest_get_all
    -- me_in_chest_get
    -- me_in_chest_get_all
    -- me_out_chest_get
    -- me_out_chest_get_all
    -- me_c_move
    -- c_me_move

    local inv = hwif.me_in_chest_get_all()
    for i=0, #inv - 1 do
        local is_recipe_name, recipe_name = get_recipe_name(inv[i])
        if is_recipe_name then
            while hwif.me_me_move(i+1, 1, 1) ~= 1 do
                th.tprint("Output chest is not empty...")
                os.sleep(1)
            end

            th.tprint("Found valid recipe: " .. recipe_name)
            return crafts[recipe_name]
        end
    end
    return nil
end

-- 72 - 2(eggs and coins)
local cchest_workspace_end = 70

local function move_recipe_items(recipe)
    local required = {}
    for k, v in pairs(recipe.batch.inputs) do
        required[k] = v.cnt
    end
    if recipe.extra_cells then
        required["empty_cell"] = recipe.extra_cells
    end

    local inv = hwif.me_in_chest_get_all()
    for i=0, #inv - 1 do
        if inv[i] and inv[i].label then
            local name = ih.get_name(inv[i])
            th.tprint("move in name: " .. name)
            if required[name] and required[name] > 0.01 then
                local cnt = hwif.me_c_move(i + 1, nil, required[name])
                required[name] = required[name] - cnt
            end
        end
    end
end

local function move_outputs(recipe)
    -- Take from chest and move into the output chest

    local inv = hwif.cchest_get_all()
    for i=0, cchest_workspace_end - 1 do
        if inv[i] and inv[i].label then 
            local name = ih.get_name(inv[i])
            local req_cnt = inv[i].size
            while req_cnt > 0 do
                local cnt = hwif.c_me_move(i + 1, nil, req_cnt)
                req_cnt = req_cnt - cnt
                os.sleep(0.1)
            end
        end
    end
end

local except_table = {
    ["programmed_circuit"] = {},
    ["mold_(ingot)"] = {},
    ["mold_(plate)"] = {}
}
local function is_empty_machine(machine, include_circ)
    local all_slots = machine.trans.getAllStacks(machine.side).getAll()
    for i, v in ipairs(all_slots) do
        if v and v.label then
            th.tprint("empty_name: " .. ih.get_name(v))
        end
        if v and v.label and ((not except_table[ih.get_name(v)]) or include_circ) then
            return false
        end
    end
    return true
end

local last_mach_id = nil
local last_mach_cfg = nil
local last_mach = nil
local function craft_one_batch()
    local recipe = get_one_recipe()
    if not recipe then
        -- no recipe was found in the chest
        return
    else
        th.tprint(">> will craft: " .. recipe.uid)
    end
    move_recipe_items(recipe)

    local machine
    th.tprint(": last_mach_id     " .. tostring(last_mach_id) .. " mach_id  " .. tostring(recipe.mach_id))
    th.tprint(": last_mach_cfg    " .. tostring(last_mach_cfg) .. " mach_cfg " .. tostring(recipe.mach_cfg))
    th.tprint(": last_mach        " .. tostring(last_mach))
    th.tprint(": is_empty_machine " .. tostring(last_mach and is_empty_machine(last_mach)))
    if not ((last_mach_id == recipe.mach_id) and (last_mach_cfg == recipe.mach_cfg)
            and last_mach and is_empty_machine(last_mach))
    then
        machine = hwc.prepare_machine(recipe.mach_id, recipe.mach_cfg, false)
        if last_mach and last_mach_id ~= recipe.mach_id then
            hwif.reset_machine(last_mach)
        end
        last_mach = machine
        last_mach_id = recipe.mach_id
        last_mach_cfg = recipe.mach_cfg
    else
        if last_mach and last_mach_id ~= recipe.mach_id then
            hwif.reset_machine(last_mach)
        end
        machine = last_mach
    end
    local inv = hwc.read_cchest()
    if not craft_batch(inv, machine, recipe.batch, false) then
        th.tprint("ERROR: FAILED CRAFT STAGE")
        return
    end
    if not wait_batch(inv, machine, recipe.batch, false) then
        th.tprint("ERROR: FAILED WAIT STAGE")
        return
    end
    if not collect_batch(inv, machine, recipe.batch, false) then
        th.tprint("ERROR: FAILED COLLECT STAGE")
        return
    end

    move_outputs()
end

-- This is the thread that receives the requests from the ae2 system and crafts them it will exit
-- on error and should be independent of the main_reciper, except from receiving crafting recipes
-- from it
local function main_crafter()
    while true do
        -- TODO: event: redstone from the request chest

        -- TODO fill this var
        local has_items_in_me_c = hwif.rs_me_read() > 0
        if reciper2crafter.pending() then
            -- highest priority
            th.tprint(">> Adding a recipe")
            local recipe = reciper2crafter.recv()
            add_crafting_recipe(recipe)
        elseif has_items_in_me_c or th.rs_chann.pending() then
            if has_items_in_me_c then
                -- th.tprint(">> Redstone was up, will craft a recipe")
                craft_one_batch()
            end
            if th.rs_chann.pending() then
                th.tprint("redstone queue pending")
                th.rs_chann.clear()
                th.tprint("redstone queue cleared")
            end
            os.sleep(0.2)
        else
            th.tprint(">> Waiting for events")
            local some_chan = th.wait_any(reciper2crafter, th.rs_chann)
            th.tprint(">> Got event on channel " .. some_chan.name)
        end

        -- find the first label in the chest
        -- wait for as many from each recipe as stated by the label
        -- transfer the recipe to the crafting chest
        -- start the crafting process
    end
end

local function read_recipe()
    local pattern = hwif.rchest_get(pattern_slot)
    local machine = hwif.rchest_get(machine_slot)
    local config = hwif.rchest_get(config_slot)
    local liq_in = hwif.rchest_get(liquid_in_slot)
    local liq_out = hwif.rchest_get(liquid_out_slot)

    -- TODO: remove
    -- deflate = require("deflate")
    -- nbt     = require("nbt")
    -- hwif    = require("hw_interface")
    -- pattern_slot = 20
    -- pattern = hwif.rchest_get(pattern_slot)
    -- outpattern = {}
    -- pstr = ""
    -- for i,v in ipairs(outpattern) do pstr = pstr .. v end
    -- print(pstr)

    if not pattern then
        th.tprint("You must insert a pattern")
        return nil
    end

    -- Find the uid of the recipe
    local uid = nil
    local outpattern = {}
    deflate.gunzip({input = pattern.tag, output = function(byte) outpattern[#outpattern+1] = string.char(byte) end, disable_crc = true })
    local r = nbt.readFromNBT(outpattern)
    
    for i, v in ipairs(r["in"]) do
        if v.tag then
            if v.tag.InscribeName then
                uid = v.tag.InscribeName
                break
            end
            if v.tag.display and v.tag.display.Name and has_recipe_name(v.tag.display.Name) then
                uid = v.tag.display.Name
                break
            end
        end
    end
    if not uid then
        th.tprint("Pattern needs to have a label inside")
        return nil
    else
        th.tprint("Recipe uid: " .. uid)
    end

    -- read the input liquid
    local liqin_cell_name = nil
    local liqin_msz = nil
    if liq_in then
        liqin_cell_name = ih.get_name(liq_in)
        liqin_msz = ih.get_msz_of_liq(liq_in)
    end

    -- read the output liquid
    local liqout_cell_name = nil
    local liqout_msz = nil
    local liqout_cnt = nil
    if liq_out then
        liqout_cell_name = ih.get_name(liq_out)
        liqout_msz = ih.get_msz_of_liq(liq_out)
        liqout_cnt = liq_out.size
    end

    -- read the machine id
    local machine_name2id = {
        ["basic_chemical_reactor"] = hwif.machines.chem_reactor.id,
        ["basic_assembling_machine"] = hwif.machines.assembler.id,
        ["basic_electrolyzer"] = hwif.machines.electrolyzer.id,
        ["basic_distillery"] = hwif.machines.distillery.id,
        ["basic_mixer"] = hwif.machines.mixer.id,
        ["basic_fluid_solidifier"] = hwif.machines.fsolidifier.id,
        ["basic_fluid_extractor"] = hwif.machines.fextractor.id,
        ["basic_fluid_chemical_bath"] = hwif.machines.chembath.id
    }
    local machine_id = 0
    if not machine then
        th.tprint("You need to have a machine configured")
        return nil
    else
        machine_id = machine_name2id[ih.get_name(machine)]
    end

    local solidif_name2id = {
        ["Mold (Ingot)"] = 1,
        ["Mold (Plate)"] = 2,
    }
    local circ_dmg2id = {
        [1] = 1,
        [2] = 2,
        [3] = 3,
        [4] = 4,
        [5] = 5,
        [6] = 6,
        [7] = 7,
        [8] = 8,
        [9] = 9,
        [10] = 10,
        [11] = 11,
        [12] = 12,
        [16] = 13,
        [19] = 14,
        [21] = 15,
        [24] = 16,
    }
    -- read the machine config
    local config_id = nil
    if config then
        -- TODO: check what needs to be read here to decide the config
        if machine_id == hwif.machines.fsolidifier.id then
            config_id = solidif_name2id[config.label]
        else
            config_id = circ_dmg2id[config.damage]
        end
        if not config_id then
            th.tprint("You must use a programed_circuit/mold in the config slot")
            return nil
        end
    end

    local recipe = {}
    recipe.uid = string.lower(item.label)
    recipe.mach_id = machine_id
    recipe.mach_cfg = config_id
    recipe.batch = {}
    recipe.batch.inputs = {}
    recipe.batch.outs = {}

    th.tprint("machine id: " .. machine_id)
    if config_id then
        th.tprint("machine_cfg: " .. config_id)
    end

    if liq_out then
        local liq_cnt = liqout_msz * liqout_cnt
        table.insert(recipe.batch.outs, {
            label = liqout_cell_name,
            msz = liqout_msz,
            cnt = liqout_cnt,
            liq_cnt = liq_cnt,
            as_liq = true
        })
        th.tprint("OUT liqname: " .. liqout_cell_name .. " cnt " .. liqout_cnt .. " msz " .. liqout_msz)
    end

    for i, v in ipairs(pattern.inputs) do
        if i == 8 and v.name and (ih.name_format(v.name) == "empty_cell") then
            recipe.extra_cells = v.count
            th.tprint("Extra cells: " .. v.count)
        elseif v.name and (ih.name_format(v.name) == liqin_cell_name) then
            -- this is the input liquid
            recipe.batch.inputs[liqin_cell_name] = {
                msz = liqin_msz,
                cnt = v.count,
                as_liq = true
            }
            th.tprint("IN  liqname: " .. liqin_cell_name .. " cnt " .. v.count .. " msz " .. liqin_msz)
        elseif i == 9 then
            -- this is the label name, it is remembered in the uid, so we ignore it here
        elseif v.name then
            -- this is an item
            -- TODO: verify if items need msz, if so, take them from input
            local item_name = ih.name_format(v.name)
            local item_cnt = v.count
            recipe.batch.inputs[item_name] = {
                cnt = item_cnt,
                as_liq = false
            }
            th.tprint("IN  item: " .. item_name .. " cnt " .. item_cnt)
        end
    end

    for i, v in ipairs(pattern.outputs) do
        if v.name and (ih.name_format(v.name) == liqout_cell_name) then
            -- liquid out is added whenever liquid is specified
        elseif v.name then
            -- this is an item
            -- TODO: verify if items need msz, if so, bad luck
            local item_name = ih.name_format(v.name)
            local item_cnt = v.count
            table.insert(recipe.batch.outs, {
                label = item_name,
                cnt = item_cnt,
                as_liq = false
            })
            th.tprint("OUT item: " .. item_name .. " cnt " .. item_cnt)
        end
    end

    -- TODO: we make a great assumption here: the name in the pattern is the label in our crafting
    -- system
    -- TODO: make a database keeping the infos(msz, label...) for known items, when all the items
    -- from a recipe are known, register them and make crafting batches, instead of single craftings

    return recipe
end

local KEY_ENTER = 28
local KEY_Y = 21
local function wait_keys(codes)
    while true do
        local msg = th.kd_chann.recv()
        for i, v in ipairs(codes) do
            if msg.code == v then
                return v
            end
        end
    end
end

-- This is the reciper, this will be used to add recipes into the system
local function main_reciper()
    while true do
        th.tprint("> Configure the recipe and press enter: ")
        wait_keys({KEY_ENTER})
        
        -- 0. Read the recipe pattern
        local pattern_recipe = read_recipe()
        if pattern_recipe then
            th.tprint("> Would you like to save the recipe [y/n]: ")
            local key = th.kd_chann.recv()
            if key.code == KEY_Y then
                reciper2crafter.send(pattern_recipe)
                -- table.insert(crafting_registrations, h.copy(pattern_recipe))
                -- event.push("_added_recipe")
                th.tprint("> Recipe sent to the crafting unit, please install the new recipe in the interface" ..
                        " and clean the recipe editor slots.")
            else
                th.tprint("> Recipe was not added, please clean the recipe editor before leaving.")
            end
        end
    end
end

for k, v in pairs(hwif.machines) do
    if not is_empty_machine(v, true) then
        hwif.reset_machine(v)
    end
end


local t1 = th.create_thread(main_crafter)
local t2 = th.create_thread(main_reciper)

th.handle_threads()

-- hwif = require("hw_interface")
-- deflate = require("deflate")
-- nbt = require("nbt")

-- stack = hwif.rchest_get(1)
-- out = {}
-- deflate.gunzip({input = stack.tag,output = function(byte)out[#out+1]=string.char(byte)end})
-- r = nbt.readFromNBT(out)
-- r["in"] -- list of 
-- r["in"][1] -- first item
-- r["in"][1].tag.InscribeName

-- ip = hwif.cchest_get(2)
-- out2 = {}
-- deflate.gunzip({input = ip.tag,output = function(byte)out2[#out2+1]=string.char(byte)end})
-- t2 = nbt.readFromNBT(out2)

-- 7206, 4, 4357
