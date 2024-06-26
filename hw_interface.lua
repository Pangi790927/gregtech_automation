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
    distillery   = { id = 1, trans = t1, side = s.west, cside = s.south, brk = { s = s.east,  n = 2 }},
    chembath     = { id = 2, trans = t1, side = s.up,   cside = s.south, brk = { s = s.east,  n = 4 }},
    chem_reactor = { id = 3, trans = t1, side = s.east, cside = s.south, brk = { s = s.east,  n = 8 }},
    assembler    = { id = 4, trans = t2, side = s.west, cside = s.north, brk = { s = s.west,  n = 1 }},
    electrolyzer = { id = 5, trans = t2, side = s.east, cside = s.north, brk = { s = s.west,  n = 4 }},
    canner       = { id = 6, trans = t2, side = s.up,   cside = s.north, brk = nil, liq = nil},
    fextractor   = { id = 7, trans = t3, side = s.west, cside = s.south, brk = { s = s.north, n = 8 }},
    mixer        = { id = 8, trans = t3, side = s.up,   cside = s.south, brk = { s = s.north, n = 4 }},
    fsolidifier  = { id = 9, trans = t3, side = s.east, cside = s.south, brk = { s = s.north, n = 2 }},
}

-- distillery
-- chembath
-- electrolyzer
-- fextractor
-- mixer
-- fsolidifier

hwif.machine_io = {
    {inputs={6},                              cfg=6,   outs={7},                    name="distillery"},
    {inputs={6},                              cfg=6,   outs={7, 8, 9},              name="chembath"},
    {inputs={6, 7},                           cfg=7,   outs={8, 9},                 name="chem_reactor"},
    {inputs={6, 7, 8, 9, 10, 11, 12, 13, 14}, cfg=14,  outs={15},                   name="assembler"},
    {inputs={6, 7},                           cfg=7,   outs={8, 9, 10, 11, 12, 13}, name="electrolyzer"},
    {inputs={6},                              cfg=nil, outs={7},                    name="canner"},
    {inputs={6},                              cfg=6,   outs={7},                    name="fextractor"},
    {inputs={6, 7, 8, 9, 10, 11},             cfg=11,  outs={12, 13, 14, 15},       name="mixer"},
    {inputs={6},                              cfg=6,   outs={7},                    name="fsolidifier"},
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
hwif.cchest_titank_slot = 77
hwif.cchest_cells_slot = 78
hwif.cchest_circuits_slot = 81
hwif.cchest_solidif_slot = 97

hwif.me_trans = t5
hwif.titank_side = s.up
hwif.titank_cside = s.west

hwif.craft_info = {
    { mach_name="distillery",   cfg=hwif.cchest_circuits_slot, cfg_num=16 },
    { mach_name="chembath",     cfg=hwif.cchest_circuits_slot, cfg_num=16 },
    { mach_name="chem_reactor", cfg=hwif.cchest_circuits_slot, cfg_num=16 },
    { mach_name="assembler",    cfg=hwif.cchest_circuits_slot, cfg_num=16 },
    { mach_name="electrolyzer", cfg=hwif.cchest_circuits_slot, cfg_num=16 },
    { mach_name="canner",       cfg=nil, cfg_num=0 },
    { mach_name="fextractor",   cfg=nil, cfg_num=0 },
    { mach_name="mixer",        cfg=hwif.cchest_circuits_slot, cfg_num=16 },
    { mach_name="fsolidifier",  cfg=hwif.cchest_solidif_slot,  cfg_num=2 },
}

hwif.craft_circuits = {
    "circ_1",  "circ_2",  "circ_3",  "circ_4",
    "circ_5",  "circ_6",  "circ_7",  "circ_8",
    "circ_9",  "circ_10", "circ_11", "circ_12",
    "circ_16", "circ_19", "circ_21", "circ_24",
}

hwif.craft_extuders = {
    "small_pipe", -- changed
    "normal_pipe", -- changed
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
    if not m.brk then
        return
    end
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
    if dst_slot then
        return t5.transferItem(s.east, s.west, cnt, src_slot, dst_slot)
    else
        return t5.transferItem(s.east, s.west, cnt, src_slot)
    end
end

function hwif.me_me_move(src_slot, dst_slot, cnt)
    if dst_slot then
        return t5.transferItem(s.east, s.south, cnt, src_slot, dst_slot)
    else
        return t5.transferItem(s.east, s.south, cnt, src_slot)
    end
end

function hwif.c_me_move(src_slot, dst_slot, cnt)
    if dst_slot then
        return t5.transferItem(s.west, s.south, cnt, src_slot, dst_slot)
    else
        return t5.transferItem(s.west, s.south, cnt, src_slot)
    end
end

function hwif.cchest_move(src_slot, dst_slot, cnt) 
    if dst_slot then
        return t1.transferItem(s.south, s.south, cnt, src_slot, dst_slot)
    else
        return t1.transferItem(s.south, s.south, cnt, src_slot)
    end
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
