-- server.lua - the robot as a thin interface to the world: the PC holds the map, plans and decides,
-- and sends commands; the robot does them and says what happened (3d-draw/docs/robots.md, "The
-- robot server"). Asked for by the user, 2026-10-04: "I don't really see why you need to hold data on
-- the robot, it can be streamed back and forth" - the mapper, holding the map, had just run out of
-- memory. Run as a zone (3d-draw/rlink.py opens it); `...` is the zone.
--
-- The conversation, text lines inside the zone's 'd' frames (console/protocol.h):
--   PC -> robot   <id> <command> [arguments]        a batch: any number of lines at once
--   robot -> PC   <id> ok [values]                  done, and what it found
--                 <id> err <why>                    not done; the rest of that batch is skipped:
--                 <id> skip                         - so a failed step does not let the next run
--                 ready <x> <y> <z> <facing> <energy> <name>   once, when it starts
-- Directions are the world's: n s e w u d (x east, y up, z south). Positions count from the
-- start block (0, 0, 0), as the mapper's do.
--
-- What it keeps itself, because the link can drop at any moment:
--   - it never moves into a liquid (a source block it moved into would be gone for good);
--   - its position, in /home/3d-draw/pos.txt after every step, and set to the start block
--     whenever the charger is east of it (docs/robots.md: no other place is so). Facing
--     is read from the navigation upgrade every time, never counted;
--   - the way home: its steps since it was last there (or last charged), with every step that
--     undoes the one before taken off. Below an energy floor (the way home at 12 a step, plus a
--     margin) it does nothing that spends energy but `back`, which walks that way home, and a
--     `move <dir> home`: a step of a way home the PC planned, often far shorter than the trail
--     (the scout, 2026-10-04, was stranded 10 steps from its charger by a trail of hundreds).
--
-- Commands (values after `ok`):
--   hello                     x y z facing energy maxEnergy slots durability
--   pos                       x y z facing
--   setpos x y z              a new robot's position, as the PC found it      x y z facing
--   energy                    energy maxEnergy
--   move <dir> [home] [wet]   x y z facing energy; `home`: a step of the way home; `wet`:
--                             into a liquid - only where the PC knows a block will replace it
--                             (a stilt's cell: the user, 2026-10-04, "you can enter in water on
--                             a block that will be replaced either way")
--   face <n|s|e|w>            facing
--   back                      walks the way home: x y z facing energy
--   detect <dir>              solid kind
--   analyze <dir>             name meta hardness       (nothing there: air)
--   scan <dx> <dz> [dy] [h]   h hardness values, comma separated, from dy up (default -8, 24),
--                             at the column dx, dz from the robot (geolyzer: air is exactly 0)
--   swing <dir> [home]        kind-after              (it must end as air, or it is an error)
--                             `home`: below the energy floor too, as `move <dir> home` - for a
--                             dig-out the user has approved, and nothing else
--   place <dir> [face] [slot] [sneak]  name-placed: into the cell toward dir, clicking its
--                             neighbour toward face (a world direction; "-" lets the robot pick)
--   use <dir> [face] [sneak]  what robot.use said; a face as place takes (a hoe)
--   select <slot>             slot
--   stack <slot>              name meta count | empty
--   inventory                 slot:name:meta:count;... of the slots that are not empty
--   suck <dir> [count] / suckslot <dir> <slot> [count] / drop <dir> [count] / dropslot <dir>
--     <slot> [count]          how many moved
--   equip                     swaps the selected slot with the tool slot
--   chunk <on|off>            the chunkloader upgrade, if it has one
--   transfer <from> <to> [count]   moves items between its own slots: how many are in `to`
--   craft <slot> [count]      crafts from the grid (slots 1-3, 5-7, 9-11) into that slot, up to
--                             count times: name damage how-many-made
--   wait <seconds>            energy
--   charge [share] [seconds]  waits at the charger until energy is that share of the maximum
--                             (0.95), giving up when nothing came for that long (60)
--   bye                       the server ends

local z = ...
local component, computer, sides = require("component"), require("computer"), require("sides")
local fs = require("filesystem")
local robot, geo, nav = component.robot, component.geolyzer, component.navigation
local ic = component.inventory_controller

local POS = "/home/3d-draw/pos.txt"
local PER_STEP, FLOOR = 12, 1500  -- the way home's cost per step (7 measured), and the margin
local FACE = {n = 2, s = 3, w = 4, e = 5}
local NAME = {[2] = "n", [3] = "s", [4] = "w", [5] = "e"}
local STEP = {n = {0, 0, -1}, s = {0, 0, 1}, e = {1, 0, 0}, w = {-1, 0, 0}, u = {0, 1, 0},
              d = {0, -1, 0}}
local BACK = {n = "s", s = "n", e = "w", w = "e", u = "d", d = "u"}
local CLOCKWISE = {n = "e", e = "s", s = "w", w = "n"}

-- ---- where it is -------------------------------------------------------------------------------

local pos = {0, 0, 0}
local trail = {}

local function facing() return NAME[nav.getFacing()] end

local function save()
  fs.makeDirectory("/home/3d-draw")
  local f = io.open(POS, "w")
  if f then f:write(("%d %d %d\n"):format(pos[1], pos[2], pos[3])) f:close() end
end

local function face(dir)
  for _ = 1, 4 do
    local now = facing()
    if now == dir then return true end
    robot.turn(CLOCKWISE[now] == dir)
  end
  return facing() == dir
end

-- The robot-relative side toward a world direction, facing it first if it is a side.
local function side(dir)
  if dir == "u" then return sides.up elseif dir == "d" then return sides.down end
  assert(FACE[dir], "no direction " .. tostring(dir))
  assert(face(dir), "could not turn " .. dir)
  return sides.front
end

-- The charger east of it means the start block, whatever the file says - if the battery under
-- the solar panel is there too, one up and north-east (1 1 -1), with the wire and the panel.
-- A second charger, two blocks north, has its east side free as well: a robot put there
-- (Pintsize, 2026-10-04) took itself
-- for one at the start block. The geolyzer reads air as exactly 0.
local function atHome()
  local f = facing()
  local b = geo.analyze(side("e"))
  face(f)
  if type(b) ~= "table" or b.name ~= "OpenComputers:charger" then return false end
  -- battery, wire and panel, 1 to 3 up: a third charger, under the wire between the two (the
  -- user, 2026-10-04), has a charger and air there instead for one west of it
  local v = geo.scan(1, -1, 1, 1, 1, 3)
  return type(v) == "table" and (v[1] or 0) ~= 0 and (v[2] or 0) ~= 0 and (v[3] or 0) ~= 0
end

local function where()
  return ("%d %d %d %s"):format(pos[1], pos[2], pos[3], facing())
end

local function energyLow()
  return computer.energy() < #trail * PER_STEP + FLOOR
end

-- ---- the commands ------------------------------------------------------------------------------

local function step(dir, wet)
  local s = side(dir)
  for _ = 1, 10 do
    local _, kind = robot.detect(s)
    if kind == "liquid" and not wet then return nil, "a liquid toward " .. dir end
    if robot.move(s) then
      local d = STEP[dir]
      pos = {pos[1] + d[1], pos[2] + d[2], pos[3] + d[3]}
      if trail[#trail] == BACK[dir] then trail[#trail] = nil else trail[#trail + 1] = dir end
      if pos[1] == 0 and pos[2] == 0 and pos[3] == 0 then trail = {} end
      save()
      return true
    end
    _, kind = robot.detect(s)
    if kind ~= "entity" then return nil, ("blocked toward %s (%s)"):format(dir, kind) end
    os.sleep(1)
  end
  return nil, "an entity stayed in the way toward " .. dir
end

local C = {}
local SPENDS = {move = true, swing = true, place = true, use = true, scan = true, analyze = true}

function C.hello()
  return ("%s %d %d %d %s"):format(where(), math.floor(computer.energy()),
         math.floor(computer.maxEnergy()),
         robot.inventorySize(), tostring(robot.durability()))
end
function C.pos() return where() end
-- How many fluid tanks the robot has (a tank upgrade each), read only: the user asked whether
-- a robot could carry water to the field (2026-10-04).
function C.tanks() return tostring(robot.tankCount and robot.tankCount() or "none") end
-- Uptime (s), free and total memory (bytes), read only: whether a robot that left the relay for
-- 40 s had rebooted, and how close it runs to its memory (Gunter, 2026-10-04).
function C.sys()
  return ("%.0f %d %d"):format(computer.uptime(), computer.freeMemory(), computer.totalMemory())
end
-- Where a robot new to the build stands, as the PC worked it out (it has no pos.txt yet).
function C.setpos(x, y, zz)
  pos = {tonumber(x), tonumber(y), tonumber(zz)}
  trail = {}
  save()
  return where()
end
function C.energy()
  return ("%d %d"):format(math.floor(computer.energy()), math.floor(computer.maxEnergy()))
end
function C.move(dir, a, b)
  local ok, why = step(dir, a == "wet" or b == "wet")
  if not ok then return nil, why end
  return ("%s %d"):format(where(), math.floor(computer.energy()))
end
function C.face(dir)
  if not face(dir) then return nil, "could not turn " .. tostring(dir) end
  return facing()
end
function C.back()
  while #trail > 0 do
    local ok, why = step(BACK[trail[#trail]])
    if not ok then return nil, "on the way home: " .. why end
  end
  return ("%s %d"):format(where(), math.floor(computer.energy()))
end
function C.detect(dir)
  local solid, kind = robot.detect(side(dir))
  return tostring(solid) .. " " .. tostring(kind)
end
function C.analyze(dir)
  local b = geo.analyze(side(dir))
  if type(b) ~= "table" then return "air" end
  return ("%s %d %.2f"):format(b.name, b.metadata or 0, b.hardness or 0)
end
function C.scan(dx, dz, dy, h)
  dy, h = tonumber(dy) or -8, tonumber(h) or 24
  local v = geo.scan(tonumber(dx), tonumber(dz), dy, 1, 1, h)
  local out = {}
  for i = 1, h do out[i] = v[i] == 0 and "0" or ("%.2f"):format(v[i]) end
  return table.concat(out, ",")
end
-- Never at a robot: it is a block, and a swing breaks it into an item - three builders broke
-- three others that way, each standing in a cell the plan built in (2026-10-04).
function C.swing(dir)
  local s = side(dir)
  local b = geo.analyze(s)
  if type(b) == "table" and b.name == "OpenComputers:robot" then
    return nil, "blocked: a robot"
  end
  for _ = 1, 4 do
    local _, kind = robot.detect(s)
    if kind == "air" then return "air" end
    if kind == "liquid" then return nil, "a liquid" end
    robot.swing(s)
  end
  local _, kind = robot.detect(s)
  if kind == "air" then return "air" end
  return nil, "did not break (" .. tostring(kind) .. ")"
end
-- The face to click, a world direction, as the robot-relative side robot.place takes (its
-- Agent.place: checkSideForFace converts it with toLocal/toGlobal): 0 below, 1 above, 2 back,
-- 3 front, 4 right, 5 left, of the way the robot faces now.
local function localFace(dir)
  if dir == "u" then return sides.up elseif dir == "d" then return sides.down end
  local now = facing()
  if dir == now then return sides.front end
  if CLOCKWISE[now] == dir then return sides.right end
  if CLOCKWISE[dir] == now then return sides.left end
  return sides.back
end

function C.place(dir, face, slot, sneak)
  if slot and slot ~= "-" then robot.select(tonumber(slot)) end
  local st = ic.getStackInInternalSlot(robot.select())
  local s = side(dir)                                    -- turns first, when it is a side
  local ok, why
  if face and face ~= "-" then
    ok, why = robot.place(s, localFace(face), sneak == "sneak")
  else
    ok, why = robot.place(s, sneak == "sneak")
  end
  if not ok then return nil, tostring(why or "not placed") end
  return st and st.name or "?"
end
-- use <dir> [face] [sneak]: with a face, the click goes on that face of the block beyond the
-- target, as place does. A hoe tills only a block with air over it, so a robot cannot till the
-- block it stands on: it stands beside the cell over the dirt and clicks the dirt's top face
-- (`use n d`; the wheat field, 2026-10-04). Without a face, as before (a trapdoor's `use`).
function C.use(dir, a, b)
  local face, sneak = nil, a == "sneak" or b == "sneak"
  if a and a ~= "sneak" and a ~= "-" then face = a end
  local r
  if face then
    r = {robot.use(side(dir), localFace(face), sneak)}
  else
    r = {robot.use(side(dir), sneak)}
  end
  for i = 1, #r do r[i] = tostring(r[i]) end
  return table.concat(r, " ")
end
function C.select(slot) return tostring(robot.select(tonumber(slot))) end
function C.stack(slot)
  local st = ic.getStackInInternalSlot(tonumber(slot))
  if not st then return "empty" end
  return ("%s %d %d"):format(st.name, st.damage or 0, st.size or 0)
end
function C.inventory()
  local out = {}
  for slot = 1, robot.inventorySize() do
    local st = robot.count(slot) > 0 and ic.getStackInInternalSlot(slot)
    if st then out[#out + 1] = ("%d:%s:%d:%d"):format(slot, st.name, st.damage or 0, st.size) end
  end
  return table.concat(out, ";")
end
local function moved(before, slot)
  return tostring(before - robot.count(slot))
end
function C.suck(dir, count)
  local slot = robot.select()
  local before = robot.count(slot)
  robot.suck(side(dir), tonumber(count))
  return tostring(robot.count(slot) - before)
end
function C.suckslot(dir, slot, count)
  local n = ic.suckFromSlot(side(dir), tonumber(slot), tonumber(count))
  return tostring(n or 0)
end
function C.drop(dir, count)
  local slot = robot.select()
  local before = robot.count(slot)
  robot.drop(side(dir), tonumber(count))
  return moved(before, slot)
end
function C.dropslot(dir, slot, count)
  local n = ic.dropIntoSlot(side(dir), tonumber(slot), tonumber(count))
  return tostring(n or 0)
end
function C.equip() return tostring(ic.equip()) end
-- The chunkloader upgrade, when the robot has one: its chunk stays loaded while it is far from
-- any player (the scout's, 2026-10-04).
-- Answers isActive() after setActive: setActive returns whether the state changed (the mod's
-- doc), so a loader already on answered "false" and looked broken (2026-10-04).
function C.chunk(on)
  if not component.isAvailable("chunkloader") then return nil, "no chunkloader" end
  component.chunkloader.setActive(on == "on")
  return tostring(component.chunkloader.isActive())
end
function C.transfer(from, to, count)
  robot.select(tonumber(from))
  local ok = robot.transferTo(tonumber(to), tonumber(count))
  robot.select(1)
  if not ok then return nil, ("could not move slot %s to %s"):format(from, to) end
  return tostring(robot.count(tonumber(to)))
end
-- Crafts from the 3x3 grid, the inventory's top-left (slots 1-3, 5-7, 9-11), into the selected
-- slot; up to `count` times. What it makes, and how many of it, come back.
function C.craft(slot, count)
  robot.select(tonumber(slot))
  local before = robot.count(tonumber(slot))
  local ok = component.crafting.craft(tonumber(count))
  local st = ic.getStackInInternalSlot(tonumber(slot))
  if not ok then return nil, "nothing crafted" end
  return ("%s %d %d"):format(st and st.name or "?", st and st.damage or 0,
                             robot.count(tonumber(slot)) - before)
end
function C.wait(s)
  os.sleep(tonumber(s) or 1)
  return tostring(math.floor(computer.energy()))
end
function C.charge(share, patience)
  share, patience = tonumber(share) or 0.95, tonumber(patience) or 60
  local last, still = computer.energy(), 0
  while computer.energy() < share * computer.maxEnergy() do
    os.sleep(5)
    local e = computer.energy()
    if e <= last + 1 then still = still + 5 else still = 0 end
    if still >= patience then return nil, "the charger gave nothing for " .. patience .. "s" end
    last = e
  end
  trail = {}                      -- charged: the way home starts here
  return tostring(math.floor(computer.energy()))
end

-- ---- the loop ----------------------------------------------------------------------------------

local f = io.open(POS, "r")
if f then
  local x, y, zz = (f:read("*l") or ""):match("^(-?%d+) (-?%d+) (-?%d+)")
  f:close()
  if x then pos = {tonumber(x), tonumber(y), tonumber(zz)} end
end
if atHome() then pos = {0, 0, 0} end
save()
-- Its name, as the player gave it (the user's robots are Cairol and Gunter): the view draws each
-- robot by it.
local okName, myName = pcall(robot.name)
myName = (okName and myName or computer.address():sub(1, 8)):gsub("%s", "_")
z.send(("ready %s %d %s\n"):format(where(), math.floor(computer.energy()), myName))

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
      -- `swing <dir> home` passes the floor as `move <dir> home` does: a robot sealed in under
      -- ground can only dig its way out, and below the floor it could not even do that (Cairol,
      -- 2026-10-04, in the tunnel under the river, every command answered "low energy"). Only
      -- for a dig-out the user approved: that day the user asked for Cairol to be forced
      -- straight up 10 blocks.
      elseif SPENDS[cmd] and energyLow()
          and not ((cmd == "move" or cmd == "swing") and args:match("home")) then
        reply, failed = id .. " err low energy: send back", true
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
