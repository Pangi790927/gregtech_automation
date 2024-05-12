h       = require("helpers")
thread  = require("thread")
s       = require("sides")
c       = require("component")
ih      = require("item_helper")

-- W - 88cd
-- N - 29a9
-- E - 2390
-- S - 2611

-- 1R - 50ca
-- 2R - bc1f

--           N
--
--          05
--       03 06 09
-- W  01 02 ## 10 12  E
--       04 07 11
--          08
--
--           S

-- N                    S
--     02         07
--  01 03 05   06 08 10
--     04         09
--           W

local t_wo = c.proxy(c.get("88cd"))
local t_no = c.proxy(c.get("29a9"))
local t_eo = c.proxy(c.get("2390"))
local t_so = c.proxy(c.get("2611"))
local t_1r = c.proxy(c.get("50ca"))
local t_2r = c.proxy(c.get("bc1f"))

-- 12 in total
local route_outs = {
    { trans=t_wo, src = s.east,  side=s.west },
    { trans=t_wo, src = s.east,  side=s.down },
    { trans=t_wo, src = s.east,  side=s.north },
    { trans=t_wo, src = s.east,  side=s.south },
    { trans=t_no, src = s.south, side=s.north },
    { trans=t_no, src = s.south, side=s.down },
    { trans=t_so, src = s.north, side=s.down },
    { trans=t_so, src = s.north, side=s.south },
    { trans=t_eo, src = s.west,  side=s.north },
    { trans=t_eo, src = s.west,  side=s.down },
    { trans=t_eo, src = s.west,  side=s.south },
    { trans=t_eo, src = s.west,  side=s.east }
}

local route_filters = {
    { trans=t_1r, side=s.north },
    { trans=t_1r, side=s.up },
    { trans=t_1r, side=s.west },
    { trans=t_1r, side=s.down },
    { trans=t_1r, side=s.south },
    { trans=t_2r, side=s.north },
    { trans=t_2r, side=s.up },
    { trans=t_2r, side=s.west },
    { trans=t_2r, side=s.down },
    { trans=t_2r, side=s.south }
}

local route_table = {
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
}

local sname = {
    [s.south] = "south",
    [s.north] = "north",
    [s.west] = "west",
    [s.east] = "east",
    [s.down] = "down",
    [s.up] = "up"
}

local nofilter_out = 12

local source_chest = { trans=t_wo, side=s.east }
local route_dst = {}

function move_item(item, slot)
    local uid = ih.get_name(item)
    local t = {}
    local route_id = nofilter_out
    if route_dst[uid] then
        route_id = route_dst[uid]
    end
    t = route_outs[route_id]
    -- print(uid .. " side " .. sname[t.side] .. " src " .. sname[t.src] .. " slot " .. slot .. " route " .. route_id)
    t.trans.transferItem(t.src, t.side, 64, slot)
    -- print("doop")
end

function main_router()
    while true do
        -- print("boop")
        os.sleep(1)
        local stack = source_chest.trans.getAllStacks(source_chest.side)
        local inv = stack.getAll()

        local v = inv[0]
        if v.id then
            move_item(v, 1)
        end
        for i, v in ipairs(inv) do
            if v.id then
                move_item(v, i + 1)
            end
        end
    end
end

function read_recipes()
    local route_dst_tmp = {}
    for i, v in ipairs(route_filters) do
        local t = route_filters[i]
        local stack = t.trans.getAllStacks(t.side)
        local inv = stack.getAll()
        local v = inv[0]
        if v.id then
            local uid = ih.get_name(v)
            if not route_dst_tmp[uid] then
                route_dst_tmp[uid] = route_table[i]
                print("uid: " .. uid .. " id: " .. v.id .. " dst: " .. route_table[i])
            end
        end
        for j, v in ipairs(inv) do
            if v.id then
                local uid = ih.get_name(v)
                if not route_dst_tmp[uid] then
                    route_dst_tmp[uid] = route_table[i]
                    print("uid: " .. uid .. " id: " .. v.id .. " dst: " .. route_table[i])
                end
            end
        end
    end
    route_dst = route_dst_tmp
end

function main_filter()
    while true do
        print("Press enter to re-read the filters")
        io.read()
        read_recipes()
    end
end

read_recipes()
thread.create(main_filter)
main_router()


-- 
-- s = require("sides")
-- c = require("component")
-- t = c.proxy(c.get("bc1f"))
-- stack = t.getAllStacks(s.down)
-- inv = stack.getAll()

    -- return t1.getStackInSlot(s.south, slot)
    -- return t1.transferItem(s.south, s.south, cnt, src_slot, dst_slot)
-- getAllStacks()
-- getInventorySize