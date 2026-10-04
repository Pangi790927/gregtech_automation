-- contour.lua - walks the contour the user laid out and records it (3d-draw/docs/map.md, "1. The
-- contour"). Run as a zone: `...` is the zone, whose send() carries the report to the PC.
--
-- The robot starts standing on a contour block, the area on its right. Positions are counted
-- from the start block, x and z along the world's axes, y up; every move reports success, so
-- the count cannot drift. Each step tries forward, right, then left; a direction is undone when
-- it fails. The walk ends back at the start. The contour is sent as it grows and saved to
-- /home/3d-draw/contour.txt.

local z = ...
local component, computer, sides = require("component"), require("computer"), require("sides")
local robot, geo = component.robot, component.geolyzer

local MAX_STEPS = 2000          -- a contour longer than this is a mistake in the walk
local MIN_ENERGY = 5000         -- stop while there is still enough to come home
local MAX_FALL = 32

-- World facings as navigation numbers them (sides: 2 north, 3 south, 4 west, 5 east), in
-- clockwise order, and the step each one makes.
local CLOCKWISE = {2, 5, 3, 4}
local STEP = {[2] = {0, -1}, [3] = {0, 1}, [4] = {-1, 0}, [5] = {1, 0}}
local NAME = {[2] = "north", [3] = "south", [4] = "west", [5] = "east"}

-- Sends a report line. The zone is one of octerm's threads, and robot calls do not yield to the
-- others: without the sleep, octerm only gets to send what is queued when the walk is over.
local function say(s)
  z.send(tostring(s))
  os.sleep(0)
end

-- The robot's state: position from the start block, and the world facing.
local pos = {x = 0, y = 0, z = 0}
local facing = component.navigation.getFacing()
local startFacing = facing
local turns = 0                 -- index of `facing` in CLOCKWISE
for i, f in ipairs(CLOCKWISE) do if f == facing then turns = i end end
assert(turns > 0, "unexpected facing " .. tostring(facing))

local function key(b) return b.name .. "@" .. tostring(b.metadata) end
local contour = key(geo.analyze(sides.down))

-- Whether the block on `side` is a contour block.
local function isContour(side) return key(geo.analyze(side)) == contour end

-- Turns once, clockwise or not, keeping `facing` in step.
local function turn(clockwise)
  assert(robot.turn(clockwise), "turn failed")
  turns = (turns + (clockwise and 0 or 2)) % 4 + 1
  facing = CLOCKWISE[turns]
end

local function face(target)
  while facing ~= target do
    local want
    for i, f in ipairs(CLOCKWISE) do if f == target then want = i end end
    turn((want - turns) % 4 == 1 or (want - turns) % 4 == 2)
  end
end

-- One move, `side` front, back, up or down. Grass ahead is broken (the user allowed it); a
-- player or mob in the way is waited for a little. Returns true when moved; keeps `pos`.
-- Never into a liquid: a robot moving into a source block deletes it (it took a water block
-- once, 2026-10-04), and detect() calls a liquid not solid. Moving back is the exception: that
-- is undoing a try, into the cell the robot has just left.
local function move(side)
  if side ~= sides.back and select(2, robot.detect(side)) == "liquid" then
    return false, "liquid"
  end
  for attempt = 1, 5 do
    local ok, why = robot.move(side)
    if ok then
      if side == sides.up then pos.y = pos.y + 1
      elseif side == sides.down then pos.y = pos.y - 1
      else
        local d = STEP[facing]
        local k = side == sides.front and 1 or -1
        pos.x, pos.z = pos.x + d[1] * k, pos.z + d[2] * k
      end
      return true
    end
    local _, kind = robot.detect(side)
    if kind == "replaceable" and side ~= sides.back then
      robot.swing(side)
    elseif kind == "entity" then
      os.sleep(1)
    else
      return false, kind or why
    end
  end
  return false, "still blocked"
end

-- Undoes the moves of a failed try, newest first.
local UNDO = {[sides.front] = sides.back, [sides.up] = sides.down, [sides.down] = sides.up}
local function undo(done)
  for i = #done, 1, -1 do
    local ok, why = move(UNDO[done[i]])
    if not ok then error("could not undo a failed try: " .. tostring(why)) end
  end
end

-- Tries one direction from where the robot stands. On success the robot stands on a contour
-- block one step further; on failure it is back where it was (facing `target`).
local function try(target)
  face(target)
  local done = {}
  local function went(side) done[#done + 1] = side end
  -- rise while the way ahead is a wall of contour blocks
  while robot.detect(sides.front) do
    if not isContour(sides.front) then undo(done); return false, "blocked" end
    if not move(sides.up) then undo(done); return false, "cannot rise" end
    went(sides.up)
  end
  if not move(sides.front) then undo(done); return false, "cannot move" end
  went(sides.front)
  -- fall, while a contour block is next to the robot; the block it just stepped off counts as
  -- next to it for the first block of the fall
  for fallen = 0, MAX_FALL do
    local solid, kind = robot.detect(sides.down)
    if kind == "liquid" then undo(done); return false, "liquid below" end
    if solid then
      if isContour(sides.down) then return true end
      undo(done)
      return false, "landed off the contour"
    end
    local near = fallen == 0
    for _, s in ipairs({sides.front, sides.left, sides.right, sides.back}) do
      near = near or isContour(s)
    end
    if not near then undo(done); return false, "no contour left to fall along" end
    if not move(sides.down) then undo(done); return false, "cannot fall" end
    went(sides.down)
  end
  undo(done)
  return false, "fell too far"
end

local path = {{0, 0, 0}}
local function where() return ("%d %d %d"):format(pos.x, pos.y, pos.z) end
say("contour block: " .. contour .. "; facing " .. NAME[facing] .. "; energy "
    .. math.floor(computer.energy()))

local finished, why = false, nil
for step = 1, MAX_STEPS do
  if computer.energy() < MIN_ENERGY then why = "energy low"; break end
  local base = turns
  local moved = false
  for _, offset in ipairs({0, 1, 3}) do                 -- forward, right, left
    local target = CLOCKWISE[(base - 1 + offset) % 4 + 1]
    local ok, failed = try(target)
    if ok then moved = true; break end
    say(("  at %s, %s failed: %s"):format(where(), NAME[target], failed))
  end
  if not moved then why = "dead end at " .. where(); break end
  path[#path + 1] = {pos.x, pos.y, pos.z}
  say(("step %d: %s facing %s"):format(step, where(), NAME[facing]))
  if pos.x == 0 and pos.y == 0 and pos.z == 0 then finished = true; break end
end
if not finished and not why then why = "more than " .. MAX_STEPS .. " steps" end
if finished then face(startFacing) end    -- the station is laid out around this facing

local fs = require("filesystem")
fs.makeDirectory("/home/3d-draw")
local f = assert(io.open("/home/3d-draw/contour.txt", "w"))
f:write("# contour block " .. contour .. "\n")
for _, p in ipairs(path) do f:write(("%d %d %d\n"):format(p[1], p[2], p[3])) end
f:close()
say((finished and "done: back at the start after " or "stopped: " .. why .. " after ")
    .. (#path - 1) .. " steps; energy " .. math.floor(computer.energy())
    .. "; saved /home/3d-draw/contour.txt")
