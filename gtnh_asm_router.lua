sides = require("sides")
component = require("component")

local t_sw = component.proxy(component.get("35fc"))
local t_nw = component.proxy(component.get("9a78"))
local t_ne = component.proxy(component.get("486c"))
local t_se = component.proxy(component.get("8b59"))
local t_up = component.proxy(component.get("ce68"))

print(t_sw ,t_nw ,t_ne ,t_se, t_up)

local route_outs = {
    { trans=t_sw, src=sides.up, dst=sides.south },
    { trans=t_sw, src=sides.up, dst=sides.west },
    { trans=t_sw, src=sides.up, dst=sides.north },
    { trans=t_sw, src=sides.up, dst=sides.east },
    { trans=t_nw, src=sides.up, dst=sides.south },
    { trans=t_nw, src=sides.up, dst=sides.west },
    { trans=t_nw, src=sides.up, dst=sides.north },
    { trans=t_nw, src=sides.up, dst=sides.east },
    { trans=t_ne, src=sides.up, dst=sides.south },
    { trans=t_ne, src=sides.up, dst=sides.west },
    { trans=t_ne, src=sides.up, dst=sides.north },
    { trans=t_ne, src=sides.up, dst=sides.east },
    { trans=t_se, src=sides.up, dst=sides.south },
    { trans=t_se, src=sides.up, dst=sides.west },
    { trans=t_se, src=sides.up, dst=sides.north },
    { trans=t_se, src=sides.up, dst=sides.east }
}

function get_label(trans, side, slot)
    local items = trans.getAllStacks(side)
    local inv = items.getAll()
    return inv[slot]["label"]
end


function push_items(name, op, slot)
    -- slow print
    -- print("pushing " .. name .. " slot " .. tostring(slot) .. " dst: " .. tostring(op.dst) .. " src: " .. tostring(op.src))

    -- send the item
    op.trans.transferItem(op.src, op.dst, 64, slot)
end

while true do
    local label

    -- wait for a recipe to come
    while get_label(t_sw, sides.up, 0) == nil do
        os.sleep(0.1)
    end

    print("Doing work...")

    -- transfer the recipe
    local slot = 0
    while true do
        label = get_label(t_sw, sides.up, slot)
        if slot == 16 and label ~= "Stick" then
            print("You forgot to add the stick to the recipe!")
            os.exit(-1)
        end
        if label == "Stick" then
            -- we wait for the recipe to be taken before transfering the stick
            break
        end
        if label ~= nil then
            push_items(label, route_outs[slot + 1], slot + 1)
            slot = slot + 1
        end
    end

    -- wait for the recipe to finish
    while get_label(t_up, sides.up, 0) ~= nil do
        os.sleep(0.1)
    end

    -- push the stick
    push_items(label, route_outs[1], slot + 1)
    print("Done work!")
end

