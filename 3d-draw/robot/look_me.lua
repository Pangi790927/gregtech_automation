-- look_me.lua - what the robot has, and what it can see in the mini ME (3d-draw/docs/map.md,
-- the station): one block forward the ME's interface is on its left; the inventory controller reads
-- the interface's slots (facing it: an inventory controller reads ahead, above and below only)
-- and the robot comes back to the start, facing as it was. Moves nothing else, takes nothing.

local z = ...
local component, sides = require("component"), require("sides")
local robot, ic = component.robot, component.inventory_controller
local function say(s) z.send(tostring(s)); os.sleep(0) end

local kinds = {}
for _, kind in component.list() do kinds[#kinds + 1] = kind end
table.sort(kinds)
say("components: " .. table.concat(kinds, " "))
say(("inventory %d slots, tanks %d"):format(robot.inventorySize(), robot.tankCount()))

assert(robot.move(sides.front), "could not move to the interface")
assert(robot.turn(false), "could not turn")
local ok, err = pcall(function()
  local b = component.geolyzer.analyze(sides.front)
  say("facing: " .. b.name .. ":" .. b.metadata)
  local n = ic.getInventorySize(sides.front)
  say("the interface shows " .. tostring(n) .. " slots")
  for i = 1, n or 0 do
    local s = ic.getStackInSlot(sides.front, i)
    if s then
      say(("  slot %d: %d x %s:%d (%s)"):format(i, s.size, s.name, s.damage, s.label))
    end
  end
end)
if not ok then say("reading failed: " .. tostring(err)) end
assert(robot.turn(true), "could not turn back")
assert(robot.move(sides.back), "could not come back")
say("back at the start")
