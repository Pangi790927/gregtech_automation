s   = require("sides")
c   = require("component")
b   = require("bit32")
ev  = require("event")

rdb  = require("recipe_db")
ih   = require("item_helper")
hwif = require("hw_interface")

function wait_key()
    _, _, c = ev.pull("key_down")
    return string.char(c)
end

function present_craftnig()
    local ps = hwif.cchest_pannels_slot
    for i=1, hwif.cchest_free_slots do
        if hwif.cchest_get(i) then
            print("Failed crafting setup: Slot is not empty: ", i)
            return false
        end
    end
    for i=1, #hwif.craft_frame do
        if not (hwif.cchest_move(ps, hwif.craft_frame[i], 1) == 1) then
            print("Failed crafting setup: Can't transfer pannel")
            return false
        end
    end
    return true
end

function remove_crafting()
    local ps = hwif.cchest_pannels_slot
    for i=1, #hwif.craft_frame do
        if not (hwif.cchest_move(hwif.craft_frame[i], ps, 1) == 1) then
            print("Failed crafting uninit: Can't transfer pannel")
            return false
        end
    end
    return true
end

function read_recipe_initial()
    local comp_in = {}
    for i=1, #hwif.craft_inputs do
        local comp = hwif.cchest_get(hwif.craft_inputs[i])
        if comp then
            table.insert(comp_in, {label=ih.get_name(comp), cnt=ih.count(comp), msz=comp.maxSize})
        end
    end
    local comp_out = {}
    for i=1, #hwif.craft_outputs do
        local comp = hwif.cchest_get(hwif.craft_outputs[i])
        if comp then
            table.insert(comp_out, {label=ih.get_name(comp), cnt=ih.count(comp), msz=comp.maxSize})
        end
    end
    local comp = hwif.cchest_get(hwif.craft_liq_in)
    local liq_in = nil
    if comp then
        liq_in = {label=ih.get_cell_fluid_name(comp), cnt=1000, msz=comp.amount}
    end
    comp = hwif.cchest_get(hwif.craft_liq_out)
    local liq_out = nil
    if comp then
        liq_out = {label=ih.get_cell_fluid_name(comp), cnt=1000, msz=comp.amount}
    end
    local ret = {
        comp_in=comp_in,
        comp_out=comp_out,
        liq_in=liq_in,
        liq_out=liq_out,
    }
    return ret
end

function machine_id2str(id)
    if id == 0 then
        return "none"
    end
    return hwif.craft_info[id].mach_name
end

function get_cfg_name(mach_id, cfg_id)
    if hwif.craft_info[mach_id].mach_name == "extruder" then
        return hwif.craft_extuders[cfg_id]
    elseif hwif.craft_info[mach_id].mach_name == "lasser_engr" then
        return hwif.craft_lenses[cfg_id]
    else
        return hwif.craft_circuits[cfg_id]
    end
end

function machine_cfg_id2str(m_id, m_cfg)
    if m_id == 0 then
        return "none"
    end
    local mpos = hwif.craft_info[m_id].cfg
    if m_cfg == 0 then
        return "none"
    end
    return get_cfg_name(m_id, m_cfg)
end

function print_empty_lines(cnt)
    for i=1, cnt do
        print("")
    end
end

screen_rows = hwif.screen_rows
function run_add_recipes()
    print("> Machine is preparing the crafting area, please wait")
    print_empty_lines(screen_rows - 3)
    if not present_craftnig() then
        return false
    end
    print("> Done, you can now go and add a recipe")
    print_empty_lines(screen_rows - 2)

    local state = "r"
    local pre_recipe = {}
    local recipe = {}
    while true do
        if state == "r" then
            print("> Press any key after the recipe was configured")
            print("> q will exit")
            print_empty_lines(screen_rows - 3)
            if wait_key() == "q" then
                break
            end
            pre_recipe = read_recipe_initial()
            recipe = {
                label="none",
                comp = {},
                out = {},
                liq = { label="none", cnt=0 },
                liq_out = { label="none", cnt=0 },
                res_cnt=0,
                is_liq=0,
                is_visible=0,
                mach_id=0,
                mach_cfg=0,
            }
            if #pre_recipe.comp_in > 0 then
                recipe.comp = pre_recipe.comp_in
            end
            if #pre_recipe.comp_out > 0 then
                recipe.out = pre_recipe.comp_out
            end
            if pre_recipe.liq_in then
                recipe.liq = {
                    label=pre_recipe.liq_in.label,
                    cnt=pre_recipe.liq_in.cnt
                }
            end
            if pre_recipe.liq_out then
                recipe.liq_out = {
                    label=pre_recipe.liq_out.label,
                    cnt=pre_recipe.liq_out.cnt
                }
            end
            if #pre_recipe.comp_out > 0 then
                recipe.label = pre_recipe.comp_out[1].label
                recipe.res_cnt = pre_recipe.comp_out[1].cnt
            elseif pre_recipe.liq_out then
                recipe.is_liq = 1
                recipe.label = pre_recipe.liq_out.label
                recipe.res_cnt = pre_recipe.liq_out.cnt
            else
                print("Recipe can't have no outputs, press key to continue...")
                print_empty_lines(screen_rows - 3)
                wait_key()
                goto continue
            end
        elseif state == "l" then
            print("> Please enter the liquid input amount(L): ")
            print_empty_lines(screen_rows - 2)
            local usr_in = io.read()
            local liters = tonumber(usr_in)
            if not liters or liters <= 0 then
                print("Invalid input: " .. usr_in .. " press any key...")
                wait_key()
            else
                recipe.liq.cnt = liters
            end
        elseif state == "o" then
            print("> Please enter the liquid output amount: ")
            print_empty_lines(screen_rows - 2)
            local usr_in = io.read()
            local liters = tonumber(usr_in)
            if not liters or liters <= 0 then
                print("Invalid input: " .. usr_in .. " press any key...")
                print_empty_lines(screen_rows - 2)
                wait_key()
            else
                recipe.liq_out.cnt = liters
                if recipe.is_liq == 1 then
                    recipe.res_cnt = recipe.liq_out.cnt
                end
            end
        elseif state == "m" then
            print("> Please enter the machine id: ")
            for i=1, #hwif.craft_info do
                print(i .. ". " .. hwif.craft_info[i].mach_name)
            end
            print_empty_lines(screen_rows - 2 - #hwif.craft_info)
            local usr_in = io.read()
            local mach_id = tonumber(usr_in)
            if not mach_id or mach_id <= 0 or mach_id > #hwif.craft_info then
                print("Invalid input: " .. usr_in .. " press any key...")
                print_empty_lines(screen_rows - 2)
                wait_key()
            else
                recipe.mach_id=mach_id
            end
        elseif state == "c" then
            if recipe.mach_id == 0 then
                print("can't config machine none(0), select machine first")
                print("press any key to continue...")
                print_empty_lines(screen_rows - 3)
                wait_key()
            else
                print("> Please enter the config id: ")
                local cfg_slot = hwif.craft_info[recipe.mach_id].cfg
                local cfg_num = hwif.craft_info[recipe.mach_id].cfg_num
                for i=1, cfg_num do
                    print(i .. ". " .. get_cfg_name(recipe.mach_id, i))
                end
                print_empty_lines(screen_rows - 2 - cfg_num)
                local usr_in = io.read()
                local cfg_id = tonumber(usr_in)
                if not cfg_id or cfg_id <= 0 or cfg_id > cfg_num then
                    print("Invalid input: " .. usr_in .. " press any key...")
                    print_empty_lines(screen_rows - 2)
                    wait_key()
                else
                    recipe.mach_cfg=cfg_id
                end
            end
        elseif state == "v" then
            print("> Press 1 for visible or 0 for hidden")
            print_empty_lines(screen_rows - 2)
            local vis = wait_key()
            if vis == "1" then
                recipe.is_visible = 1
            elseif vis == "0" then
                recipe.is_visible = 0
            end
        elseif state == "s" then
            print("> Choose the output:")
            for i=1, #pre_recipe.comp_out do
                print(i .. ". " .. pre_recipe.comp_out[i].label .. " X " ..
                        pre_recipe.comp_out[i].cnt)
            end
            local has_liq_out = 0
            if pre_recipe.liq_out then
                has_liq_out = 1
                print("4. " .. pre_recipe.liq_out.label .. " X " ..
                        pre_recipe.liq_out.cnt)
            end
            print_empty_lines(screen_rows - 2 - #pre_recipe.comp_out - has_liq_out)
            local choice = wait_key()
            if choice == "4" then
                if pre_recipe.liq_out then
                    recipe.is_liq = 1
                    recipe.label = pre_recipe.liq_out.label
                    recipe.res_cnt = pre_recipe.liq_out.cnt
                end
            elseif choice == "1" or choice == "2" or choice == "3" then
                local var = tonumber(choice)
                if var <= #pre_recipe.comp_out then
                    recipe.is_liq = 0
                    recipe.label = pre_recipe.comp_out[var].label
                    recipe.res_cnt = pre_recipe.comp_out[var].cnt
                end
            end
        elseif state == "n" then
            -- none
        elseif state == "d" then
            if rdb.add_recipe(recipe) then
                print("Recipe was added!")
                print("> press any key to continue... ")
                print_empty_lines(screen_rows - 3)
                wait_key()
                state = 'r'
            else
                print("FAILED!")
                print("> press any key to continue... ")
                print_empty_lines(screen_rows - 3)
                wait_key()
            end
        elseif state == "q" then
            break
        else
            print("> invalifd choice: ", state)
            print("> press any key to continue... ")
            print_empty_lines(screen_rows - 3)
            wait_key()
        end

        local empty_lines = 0
        for i=1, #recipe.comp do
            print("IN: " .. recipe.comp[i].label .. " X " .. recipe.comp[i].cnt)
            empty_lines = empty_lines + 1
        end
        if not (recipe.liq.label == "none") then
            print("LIQ_IN: " .. recipe.liq.label .. " X " .. recipe.liq.cnt)
            empty_lines = empty_lines + 1
        end
        if not (recipe.liq_out.label == "none") then
            print("LIQ_OUT: " .. recipe.liq_out.label .. " X " .. recipe.liq_out.cnt)
            empty_lines = empty_lines + 1
        end
        print("OUT: " .. recipe.label, " X " .. recipe.res_cnt)
        print("is_liq: " ..  recipe.is_liq .. " is_visible: " .. recipe.is_visible ..
                " machine: " .. machine_id2str(recipe.mach_id))
        print("config: " .. machine_cfg_id2str(recipe.mach_id, recipe.mach_cfg))
        print("> Press any key to enter action menu")
        empty_lines = empty_lines + 5
        print_empty_lines(screen_rows - empty_lines - 1)
        wait_key()

        print("> available actions:")
        print("r - redo recipe")
        print("l - change input liquid amount")
        print("o - change output liquid amount")
        print("m - change selected machine")
        print("c - change selected machine config")
        print("v - change recipe visibility")
        print("s - select output (if a liquid or not primary)")
        print("n - none, see recipe again")
        print("d - done, save recipe")
        print("q - quit")
        print_empty_lines(screen_rows - 12)
        state = wait_key()
        ::continue::
    end

    print("> Please wait for completion")
    print_empty_lines(screen_rows - 2)
    if not remove_crafting() then
        return false
    end
    print("> Done")
end

run_add_recipes()
