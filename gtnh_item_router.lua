h       = require("helpers")
thread  = require("thread")
s       = require("sides")
c       = require("component")

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

local nofilter_out = 12

-- 12 in total
local route_outs = {
    { trans=t_wo, side=s.west },
    { trans=t_wo, side=s.down },
    { trans=t_wo, side=s.north },
    { trans=t_wo, side=s.south },
    { trans=t_no, side=s.north },
    { trans=t_no, side=s.down },
    { trans=t_so, side=s.down },
    { trans=t_so, side=s.south },
    { trans=t_eo, side=s.north },
    { trans=t_eo, side=s.down },
    { trans=t_eo, side=s.south },
    { trans=t_eo, side=s.east }
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

local route_dst = {}

function main_router()
    while true do
        os.sleep(1)
    end
end

function read_recipes()
    local route_dst_tmp = {}
    for i, v in ipairs(route_filters) do
        local t = route_filters[i]
        local stacks = t.trans.getAllStacks(t.side)
        local inv = stack.getAll()
        for i, v in ipairs(inv) do
            if v.id then
                if not route_dst_tmp[v.id] then
                    route_dst_tmp[v.id] = route_table[i]
                    print("name: " .. v.name .. " id: " .. c.id .. " dst: " .. route_table[i])
                end
            end
        end
    end
    route_dst = route_dst_tmp
end

thread.create(main_crafter)
while true do
    print("Press enter to re-read the filters")
    read_recipes()
end


    -- return t1.getStackInSlot(s.south, slot)
    -- return t1.transferItem(s.south, s.south, cnt, src_slot, dst_slot)
-- getAllStacks()
-- getInventorySize