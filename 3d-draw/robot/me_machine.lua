-- me_machine.lua - the mini ME's computer (the one with the Adapter on the ME interface, and a
-- database in the Adapter's slot) as a machine of the link: robot/me_server.lua's commands in the
-- robots' conversation (3d-draw/redesign/11-me.md, 03-exec.md). Opened as a zone by
-- scripts/me.lua, as robots.lua opens robot/machine.lua:
--   PC -> here   <rid> <command> [arguments]
--   here -> PC   <rid> ok 0 [value] | <rid> err <why>       and `ready me` once
--
-- How (OpenComputers 1.9.14, li/cil/oc/integration/appeng/DriverBlockInterface and NetworkControl,
-- read 2026-10-04; me_server.lua): an interface keeps each of its 9 slots stocked with what its
-- configuration names, from the network. setInterfaceConfiguration(slot, database, entry, size)
-- names it by a database entry; store(filter, database, entry, count) writes an item of the
-- network into that entry.
--
-- Commands:
--   config <slot> <name> <damage> <size> | <slot> - ...
--                                         every slot named set or cleared, in one request
--                                         (3d-draw/redesign/11-me.md): the exe knows the counts
--   stock <slot> <name> <damage> [size]   keep that slot stocked with size (64) of the item
--   clear <slot>                          stop stocking it (what is in it stays, to be taken)
--   count <name> <damage>                 how many the network has
--   items                                 all the network holds: name:damage:count;...
--   bye
--
-- getItemsInNetwork walks the whole network on the server's thread; it is safe only because the
-- mini ME is a network of its own (the user confirmed it, 2026-10-04).

local z = ...
local component = require("component")
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

function C.config(...)
  local a, i, done = {...}, 1, {}
  while i <= #a do
    local slot = a[i]
    if a[i + 1] == "-" then
      C.clear(slot)
      done[#done + 1] = slot .. " -"
      i = i + 2
    else
      local ok, why = C.stock(slot, a[i + 1], a[i + 2], a[i + 3])
      if not ok then return nil, "slot " .. slot .. ": " .. tostring(why) end
      done[#done + 1] = slot
      i = i + 4
    end
  end
  return table.concat(done, ",")
end

function C.count(name, damage)
  local n = 0
  for _, st in ipairs(me.getItemsInNetwork({name = name, damage = tonumber(damage)})) do
    n = n + (st.size or 0)
  end
  return tostring(math.floor(n))
end

function C.items()
  local out = {}
  for _, st in ipairs(me.getItemsInNetwork()) do
    if (st.size or 0) > 0 then
      out[#out + 1] = ("%s:%d:%d"):format(st.name, st.damage or 0, math.floor(st.size))
    end
  end
  return table.concat(out, ";")
end

-- One command line in, its reply out.
local function handle(line)
  local rid, cmd, rest = line:match("^(%S+)%s+(%S+)%s*(.*)$")
  if not rid then return nil end
  if cmd == "bye" then
    z.send(rid .. " ok 0\n")
    return "bye"
  end
  if not C[cmd] then
    z.send(("%s err no command %s\n"):format(rid, cmd))
    return nil
  end
  local a = {}
  for v in rest:gmatch("%S+") do a[#a + 1] = v end
  local fine, res, why = pcall(C[cmd], table.unpack(a))
  if fine and res then
    z.send(("%s ok 0 %s\n"):format(rid, res))
  else
    z.send(("%s err %s\n"):format(rid, (tostring(fine and why or res):gsub("\n", " "))))
  end
end

z.send("ready me\n")
local buf, done = "", false
while not done do
  buf = buf .. z.wait(math.huge)
  for line in buf:gmatch("([^\n]*)\n") do
    if handle(line) == "bye" then done = true end
  end
  buf = buf:match("[^\n]*$")
end
