rdb = require("recipe_db")
ih = require("item_helper")
hwc = require("hw_crafting")

fine_gold_wire_recipe = {
    label = "fine_gold_wire",
    comp = {
        { label="gold_ore", cnt=1, msz=64 },
    },
    liq = { label="none", cnt=0, msz=0 },
    liq_out = { label="none", cnt=0, msz=0 },
    out = {
        { label="fine_gold_wire", cnt=8, msz=64 },
    },
    res_cnt=8,
    is_liq = 0,
    is_visible=0,
    mach_id=3,
    mach_cfg=2,
}

-- example: 1000 in -> 1000 out => min recipe 1
-- example: 500  in -> 1000 out => min recipe 2 (1 cell can result in at least 2 cells)
-- example: 1000 in -> 500  out => min recipe 2 (2 cell can result in at most 1 cells)
-- example: 500  in -> 500  out => min recipe 2 (1 cell in, 1 cell out)
-- example: 100  in -> ---      => min recipe 10 (1 cell in)
-- example: ---     -> 100  out => min recipe 10 (1 cell out)
-- example: 200  in -> 500  out =? min recipe 10 (1 cell in => 2500, so at least 2 cells in, 5 out)
-- so as a results it is cell_sz/in_cnt
-- example: 2000 in -> 3000 out => min recipe 1  (2 cell in => 3 cells out)
-- example: 2500 in -> 1200 out => min recipe 10 (min 5 cell in, min 6 cell out => x2, x5 => min 10)
-- example  250  in -> 100  out => min recipe 20 (min 4 in, min 10 out => x4, x10 => min 20)

-- print(get_min_cnt({liq={cnt=1000, msz=1000}, liq_out={cnt=1000, msz=1000}, res_cnt=1, is_liq=1}))
-- print(get_min_cnt({liq={cnt= 500, msz=1000}, liq_out={cnt=1000, msz=1000}, res_cnt=1, is_liq=1}))
-- print(get_min_cnt({liq={cnt=1000, msz=1000}, liq_out={cnt= 500, msz=1000}, res_cnt=1, is_liq=1}))
-- print(get_min_cnt({liq={cnt= 500, msz=1000}, liq_out={cnt= 500, msz=1000}, res_cnt=1, is_liq=1}))
-- print(get_min_cnt({liq={cnt= 100, msz=1000}, liq_out={label="none"}      , res_cnt=1, is_liq=1}))
-- print(get_min_cnt({liq={label="none"},       liq_out={cnt= 100, msz=1000}, res_cnt=1, is_liq=1}))
-- print(get_min_cnt({liq={cnt= 200, msz=1000}, liq_out={cnt= 500, msz=1000}, res_cnt=1, is_liq=1}))
-- print(get_min_cnt({liq={cnt=2000, msz=1000}, liq_out={cnt=3000, msz=1000}, res_cnt=1, is_liq=1}))
-- print(get_min_cnt({liq={cnt=2500, msz=1000}, liq_out={cnt=1200, msz=1000}, res_cnt=1, is_liq=1}))
-- print(get_min_cnt({liq={cnt= 250, msz=1000}, liq_out={cnt= 100, msz=1000}, res_cnt=1, is_liq=1}))

rdb.add_recipe(fine_gold_wire_recipe)


inv = hwc.read_cchest()
r = rdb.find_recipes({"fine_gold_wire"})["fine_gold_wire"]
hwc.wiremill_craft(inv, r.label, 1, false)

-- dbg_tprint(rdb.find_recipes({"ore1", "ore32"}))

-- recipe = rdb.example_recipe
-- rdb.add_recipe(recipe)
-- rdb.rm_recipe(recipe.label)
-- recipe.label = "ore1"
-- rdb.add_recipe(recipe)
-- recipe.label = "ore2"
-- rdb.add_recipe(recipe)
-- recipe.label = "ore3"
-- rdb.add_recipe(recipe)
-- recipe.label = "ore4"
-- rdb.add_recipe(recipe)

-- dbg_tprint(rdb.find_recipes({"ore1", "ore32"}))
-- print("------------")
-- dbg_tprint(rdb.get_recipes(3, 5))

-- item_cell = {
-- 	label="Hydrochloric Acid Cell",
-- 	size = 3
-- }
-- item_normal = {
-- 	label="Plastic Circuit Board",
-- 	size = 1
-- }
-- print(ih.is_cell(item_cell))
-- print(ih.is_cell(item_normal))
-- print(ih.count(item_cell))
-- print(ih.count(item_normal))
-- print(ih.get_cell_fluid_name(item_cell))
-- print(ih.get_name(item_normal))