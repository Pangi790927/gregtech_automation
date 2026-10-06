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
--   parts                                 read-only: the components, a transposer's sides
--   move <from> <to> <n> <slot> <slot>    the transposer moves n items between two sides
--   at <addr> <command> [arguments]       one command on the interface whose address begins
--                                         with addr (two interfaces, 2026-10-06); the plain
--                                         commands stay on the first (component.me_interface)
--   ifaces                                read-only: each interface's address and its 9
--                                         slots' configuration, name:damage:size or -
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

-- Read-only, what the computer is wired to: each component's type, and for a transposer, what is
-- on each of its sides (0 down, 1 up, 2 north, 3 south, 4 west, 5 east): an inventory's name,
-- size and the slots holding something; a tank's fluid, amount and capacity.
function C.parts()
  local out = {}
  for addr, kind in component.list() do
    out[#out + 1] = kind .. "@" .. addr:sub(1, 8)
    if kind == "transposer" then
      local t = component.proxy(addr)
      for side = 0, 5 do
        local name, size = t.getInventoryName(side), t.getInventorySize(side)
        local s = ("  side %d: %s"):format(side, tostring(name))
        if size then
          s = s .. " size " .. size
          for i = 1, size do
            local st = t.getStackInSlot(side, i)
            if st then s = s .. (" [%d]%s:%d:%d"):format(i, st.name, st.damage or 0, st.size) end
          end
        end
        local tanks = t.getTankCount(side) or 0
        for k = 1, tanks do
          local f = t.getFluidInTank(side, k)
          f = f and f[1] or f
          s = s .. (" tank%d %s %s/%s"):format(k, f and tostring(f.name) or "-",
                                           f and tostring(f.amount) or "0",
                                           f and tostring(f.capacity) or "?")
        end
        out[#out + 1] = s
      end
    end
  end
  return table.concat(out, ";")
end

-- n items moved by the transposer from a slot on one side to a slot on another: from the
-- interface (above, 1) into the GregTech tank's input (below, 0, slot 1), from its output (slot 2)
-- back into a slot of the interface not stocked, which hands it to the network. The tank, each
-- tick, empties a filled container in its input into itself and fills an empty one from itself,
-- the container landing in its output (GT_MetaTileEntity_DigitalTankBase.onPreTick, 2026-10-05).
function C.move(from, to, n, fslot, tslot)
  local t = component.transposer
  if not t then return nil, "no transposer" end
  local moved = t.transferItem(tonumber(from), tonumber(to), tonumber(n), tonumber(fslot),
                               tonumber(tslot))
  return tostring(math.floor(moved or 0))
end

-- One command on another interface (redesign/15-crew.md, "Two interfaces"): `me` stands for
-- it while the command runs, the first one after. The database is shared: an interface's config
-- holds a copy of the database's stack (OC's DriverBlockInterface), so an entry may be reused.
function C.at(addr, cmd, ...)
  local full = component.get(addr, "me_interface")
  if not full then return nil, "no interface " .. tostring(addr) end
  if not C[cmd] or cmd == "at" then return nil, "no command " .. tostring(cmd) end
  local first = me
  me = component.proxy(full)
  local fine, res, why = pcall(C[cmd], ...)
  me = first
  if not fine then return nil, res end
  return res, why
end

-- Read-only: every interface, its address and what each of its 9 slots is configured to stock
-- (name:damage:size, or - for none), to tell which interface is which by what the PC set.
function C.ifaces()
  local out = {}
  for addr in component.list("me_interface") do
    local t, slots = component.proxy(addr), {}
    for i = 1, 9 do
      local st = t.getInterfaceConfiguration(i)
      slots[#slots + 1] = st and ("%s:%d:%d"):format(st.name, st.damage or 0, st.size or 0)
                         or "-"
    end
    out[#out + 1] = addr:sub(1, 8) .. (addr == me.address and " first " or " ")
                    .. table.concat(slots, ",")
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
