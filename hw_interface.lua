s   = require("sides")
c   = require("component")
b   = require("bit32")

hwif = {}

-- east:  1-liquid        2-bwiremill 4-bextruder 8-bchem
-- north: 1-liquid        2-blasser   4-bcutting  8-bcircasm
-- west:  1-basm          2-liquid    4-bbending  8-general_alarm
-- south: 1-general_place 2-t2_liq    4-t3_liq    8-t1_liq
rs = c.redstone

t1 = c.proxy(c.get("6861")) -- w-wiremill e-chem_react u-extruder
t2 = c.proxy(c.get("a85a")) -- w-asmmach  e-bendingm   u-canner
t3 = c.proxy(c.get("7c02")) -- w-circasm  e-lasereng   u-cutting
t4 = c.proxy(c.get("dd46")) -- reciper chest
t5 = c.proxy(c.get("0bb7")) -- ME transposer

hwif.machines = {
    wiremill     = { id = 1, trans = t1, side = s.west, cside = s.south, brk = { s = s.east,  n = 2 }},
    extruder     = { id = 2, trans = t1, side = s.up,   cside = s.south, brk = { s = s.east,  n = 4 }},
    chem_reactor = { id = 3, trans = t1, side = s.east, cside = s.south, brk = { s = s.east,  n = 8 }},
    assembler    = { id = 4, trans = t2, side = s.west, cside = s.north, brk = { s = s.west,  n = 1 }},
    bending_mach = { id = 5, trans = t2, side = s.east, cside = s.north, brk = { s = s.west,  n = 4 }},
    canner       = { id = 6, trans = t2, side = s.up,   cside = s.north, brk = nil, liq = nil},
    circ_assemb  = { id = 7, trans = t3, side = s.west, cside = s.south, brk = { s = s.north, n = 8 }},
    cutting_mach = { id = 8, trans = t3, side = s.up,   cside = s.south, brk = { s = s.north, n = 4 }},
    lasser_engr  = { id = 9, trans = t3, side = s.east, cside = s.south, brk = { s = s.north, n = 2 }},
}

hwif.machine_io = {
    {inputs={6},    cfg=7, outs={8},    lin=nil, lout=nil, name="wiremill"},
    {inputs={6},    cfg=7, outs={8},    lin=nil, lout=nil, name="extruder"},
    {inputs={6, 7}, cfg=7, outs={8, 9}, lin=10,  lout=3,   name="chem_reactor"},
    {inputs={6, 7, 8, 9, 10, 11, 12, 13, 14}, cfg=14, outs={15}, lin=16, lout=15, name="assembler"},
    {inputs={6}, cfg=7, outs={8}, lin=nil, lout=nil, name="bending_mach"},
    {inputs={6}, cfg=nil, outs={7}, lin=3, lout=8, name="canner"},
    {inputs={6, 7, 8, 9, 10, 11}, cfg=11, outs={12}, lin=13, lout=nil, name="circ_assemb"},
    {inputs={6}, cfg=7, outs={8, 9}, lin=nil, lout=nil, name="cutting_mach"},
    {inputs={6}, cfg=7, outs={8}, lin=nil, lout=nil, name="lasser_engr"},
}

hwif.alarm = { s = s.west, n = 8 }
hwif.placer = { s = s.south, n = 1 }

-- those enable the liquid to flow from a crafting core to the canner
t1.liq_out = { s = s.east,  n = 1 }
t2.liq_out = { s = s.west,  n = 2 }
t3.liq_out = { s = s.north, n = 1 }

-- those enable the liquid to flow from the canner buffer to the crafting core
t1.liq_in = { s = s.south, n = 8 }
t2.liq_in = { s = s.south, n = 2 }
t3.liq_in = { s = s.south, n = 4 }

hwif.cchest_free_slots = 12*6

hwif.cchest_lens_slot = 73
hwif.cchest_pannels_slot = 77
hwif.cchest_cells_slot = 78
hwif.cchest_circuits_slot = 81
hwif.cchest_extruder_slot = 97

hwif.craft_info = {
    { mach_name="wiremill",     cfg=hwif.cchest_circuits_slot, cfg_num=16 },
    { mach_name="extruder",     cfg=hwif.cchest_extruder_slot, cfg_num=12 },
    { mach_name="chem_reactor", cfg=hwif.cchest_circuits_slot, cfg_num=16 },
    { mach_name="assembler",    cfg=hwif.cchest_circuits_slot, cfg_num=16 },
    { mach_name="bending_mach", cfg=hwif.cchest_circuits_slot, cfg_num=16 },
    { mach_name="canner",       cfg=nil, cfg_num=0 },
    { mach_name="circ_assemb",  cfg=hwif.cchest_circuits_slot, cfg_num=16 },
    { mach_name="cutting_mach", cfg=nil, cfg_num=0 },
    { mach_name="lasser_engr",  cfg=hwif.cchest_lens_slot,     cfg_num=4 },
}

hwif.craft_frame = {
    1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12,
    13,             17,     19,     21, 22, 23, 24,
    25,             29,     31, 32, 33, 34, 35, 36,
    37,             41,     43,     45, 46, 47, 48,
    49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60
}

hwif.craft_inputs = {
    14, 15, 16,
    26, 27, 28,
    38, 39, 40
}

hwif.craft_outputs = {
    18, 30, 42
}

hwif.craft_liq_in  = 20
hwif.craft_liq_out = 44

hwif.screen_rows = 16

hwif.craft_circuits = {
    "circ_1",  "circ_2",  "circ_3",  "circ_4",
    "circ_5",  "circ_6",  "circ_7",  "circ_8",
    "circ_9",  "circ_10", "circ_11", "circ_12",
    "circ_16", "circ_19", "circ_21", "circ_24",
}

hwif.craft_extuders = {
    "small_pipe",
    "normal_pipe",
    "large_pipe",
    "small_gear",
    "gear",
    "rotor",
    "rod",
    "bolt",
    "plate",
    "casing",
    "ring",
    "block"
}

hwif.craft_lenses = {
    "emerald_lens",
    "green_saphire_lens",
    "diamond_lens",
    "ruby_lens"
}

-- function hwif.init_hw()
hwif.rstate = {}
hwif.rstate[s.west] = 0
hwif.rstate[s.north] = 0
hwif.rstate[s.east] = 0
hwif.rstate[s.south] = 0

rs.setOutput(s.west, 0)
rs.setOutput(s.north, 0)
rs.setOutput(s.east, 0)
rs.setOutput(s.south, 0)
-- end

function hwif.rs_set(r)
    hwif.rstate[r.s] = b.bor(hwif.rstate[r.s], r.n)
    rs.setOutput(r.s, hwif.rstate[r.s])
end

function hwif.rs_reset(r)
    hwif.rstate[r.s] = b.band(hwif.rstate[r.s], b.bnot(r.n))
    rs.setOutput(r.s, hwif.rstate[r.s])
end

function hwif.rs_toggle(r)
    hwif.rs_set(r)
    os.sleep(0.4)
    hwif.rs_reset(r)
    os.sleep(0.4)
end

function hwif.rs_me_read()
    return rs.getInput(s.down)
end

function hwif.reset_machine(m)
    hwif.rs_toggle(m.brk)
    os.sleep(3)
    hwif.rs_toggle(hwif.placer)
end

function hwif.cchest_get(slot)
    return t1.getStackInSlot(s.south, slot)
end

function hwif.cchest_get_all()
    local stack = t1.getAllStacks(s.south)
    return stack.getAll()
end

function hwif.rchest_get(slot)
    return t4.getStackInSlot(s.west, slot)
end

function hwif.me_in_chest_get(slot)
    return t5.getStackInSlot(s.east, slot)
end

function hwif.me_in_chest_get_all(slot)
    local stack = t5.getAllStacks(s.east)
    return stack.getAll()
end

function hwif.me_out_chest_get(slot)
    return t5.getStackInSlot(s.south, slot)
end

function hwif.me_out_chest_get_all(slot)
    local stack = t5.getAllStacks(s.east)
    return stack.getAll()
end

function hwif.me_c_move(src_slot, dst_slot, cnt)
    return t5.transferItem(s.east, s.west, cnt, src_slot, dst_slot)
end

function hwif.c_me_move(src_slot, dst_slot, cnt)
    return t5.transferItem(s.west, s.south, cnt, src_slot, dst_slot)
end

function hwif.cchest_move(src_slot, dst_slot, cnt)
    return t1.transferItem(s.south, s.south, cnt, src_slot, dst_slot)
end

return hwif

-- TODO: remember the configs internaly, and check them at startup

-- OBS:
-- transferFluid(src_side, dst_side, liters)



-- INFO: wiremill inventory (9)
-- 6. IN slot 1
-- 7. IN slot 2
-- 8. OUT slot

-- INFO: extruder inventory (9)
-- 6. IN slot 1
-- 7. IN slot 2
-- 8. OUT slot

-- INFO: chem_reactor inventory (10)
-- 3. Liq OUT slot
-- 6. IN slot 1
-- 7. IN slot 2
-- 8. OUT slot 1
-- 9. OUT slot 2
-- 10. Liq IN slot


-- INFO: assembler inventory (16)
-- 6-14. IN slots 1-9
-- 15. OUT slot
-- 16. Liq IN slot

-- INFO: bending_mach inventory (9)
-- 6. IN slot 1
-- 7. IN slot 2
-- 8. OUT slot

-- INFO: canner inventory (8)
-- 6. IN slot
-- 7. OUT slot
-- 3. Liq OUT slot
-- 8. Liq IN slot

-- INFO: circ_assemb inventory (13)
-- 6-11. IN slot 1-6
-- 12. OUT slot
-- 13. Liq IN slot

-- INFO: cutting_mach inventory (10)
-- 6-7. IN slot 1-2
-- 8-9. OUT slot 1-2
-- 10. Liq IN slot (external lubricant)

-- INFO: lasser_engr inventory (9)
-- 6. IN slot 1
-- 7. IN slot 2
-- 8. OUT slot
