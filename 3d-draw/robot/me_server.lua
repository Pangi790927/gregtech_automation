-- me_server.lua - the mini ME's computer (the one with the Adapter on the ME interface) as a thin
-- interface for the PC: it puts items from the network into the interface's own slots, where the
-- robot takes them with inventory_controller.suckFromSlot (3d-draw/docs/materials.md,
-- "Materials").
-- Run as a zone (3d-draw/rlink.py opens it, as it opens robot/server.lua); the same conversation:
--   PC -> here   <id> <command> [arguments]       a batch
--   here -> PC   <id> ok [values] | <id> err <why> | <id> skip       and `ready` once
--
-- How (OpenComputers 1.9.14, li/cil/oc/integration/appeng/DriverBlockInterface and NetworkControl,
-- read 2026-10-04): an interface keeps each of its 9 slots stocked with what its configuration
-- names, from the network. setInterfaceConfiguration(slot, database, entry, size) names it by a
-- database entry, and store(filter, database, entry, count) writes an item of the network into
-- that entry. So the computer needs a database: the database upgrade in the Adapter's own slot.
--
-- Commands:
--   stock <slot> <name> <damage> [size]   keep that slot stocked with size (64) of the item
--   clear <slot>                          stop stocking it (what is in it stays, to be taken)
--   count <name> <damage>                 how many the network has
--   items                                 all the network holds: name:damage:count;... (cached
--                                         2 s: the PC asks before every load)
--   claim <side> <robot>                  that side of the interface is the robot's until it
--   release <side> <robot>                releases it; err if another holds it
--   bye
--
-- This computer is the authority over the mini ME and its interface (the user, 2026-10-04: "why
-- isn't the server pc the owner of the data inside the me, keeping it cached for the other two
-- ... make the static-pc the authority such that each builder first asks him for a lock"): what
-- the network holds, and which robot stands at which side.
--
-- getItemsInNetwork walks the whole network on the server's thread; it is safe only because the
-- mini ME is a network of its own (the user confirmed it, 2026-10-04; see read_me.lua). `count`
-- passes a filter, which the driver applies to that same walk.

local z = ...
local component = require("component")
local computer = require("computer")
local me, db = component.me_interface, component.database
assert(db, "no database: it goes in the Adapter's own slot")

local C = {}

function C.stock(slot, name, damage, size)
  slot, damage, size = tonumber(slot), tonumber(damage), tonumber(size) or 64
  db.clear(slot)
  if not me.store({name = name, damage = damage}, db.address, slot, 1) then
    return nil, ("the network has no %s:%d"):format(name, damage)
  end
  if not me.setInterfaceConfiguration(slot, db.address, slot, size) then
    return nil, "the interface did not take the configuration"
  end
  return ("%d %s %d %d"):format(slot, name, damage, size)
end

function C.clear(slot)
  me.setInterfaceConfiguration(tonumber(slot))
  return tostring(slot)
end

function C.count(name, damage)
  local n = 0
  for _, st in ipairs(me.getItemsInNetwork({name = name, damage = tonumber(damage)})) do
    n = n + (st.size or 0)
  end
  return tostring(math.floor(n))
end

local cache, cached_at = nil, -math.huge
function C.items()
  if not cache or computer.uptime() - cached_at > 2 then
    local out = {}
    for _, st in ipairs(me.getItemsInNetwork()) do
      if (st.size or 0) > 0 then
        out[#out + 1] = ("%s:%d:%d"):format(st.name, st.damage or 0, math.floor(st.size))
      end
    end
    cache, cached_at = table.concat(out, ";"), computer.uptime()
  end
  return cache
end

local holders = {}                      -- side -> the robot that holds it
function C.claim(side, who)
  if holders[side] and holders[side] ~= who then
    return nil, "held by " .. holders[side]
  end
  holders[side] = who
  return side
end
function C.release(side, who)
  if holders[side] == who then holders[side] = nil end
  return side
end

z.send("ready\n")
local buf, done = "", false
while not done do
  buf = buf .. z.wait(5)
  local failed = false
  while true do
    local line, rest = buf:match("^([^\n]*)\n(.*)$")
    if not line then break end
    buf = rest
    local id, cmd, args = line:match("^(%S+)%s+(%S+)%s*(.*)$")
    if id then
      local reply
      if failed then
        reply = id .. " skip"
      elseif cmd == "bye" then
        reply, done = id .. " ok", true
      elseif not C[cmd] then
        reply, failed = id .. " err no command " .. cmd, true
      else
        local a = {}
        for v in args:gmatch("%S+") do a[#a + 1] = v end
        local ok, res, why = pcall(C[cmd], table.unpack(a))
        if ok and res then
          reply = id .. " ok " .. res
        else
          reply, failed = id .. " err " .. tostring(ok and why or res):gsub("\n", " "), true
        end
      end
      z.send(reply .. "\n")
    end
  end
end
