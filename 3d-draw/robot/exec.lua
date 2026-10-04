-- exec.lua - does a job the PC planned (3d-draw/design/clear.py writes one): moves and breaks,
-- nothing it decides itself but when to go home. Run as a zone with the job before it:
-- 3d-draw/run.py exec <robot> --job data/job.txt puts `JOB = [==[ ... ]==]` in front of this file.
--
-- A job, one command per line:
--   m <dir>              one step: n s e w u d (x east, y up, z south, as the mapper counts)
--   b <dir> x y z name   break the block toward <dir>, which the PC says is x y z, a <name>
--   home                 at the start block: empty everything into the mini ME, and charge
--
-- It starts where the mapper left it, on the start block (0, 0, 0), and checks: the charger
-- east of it (on its left at the start, docs/map.md). Or, when the PC knows the robot was left
-- elsewhere (a program stopped out in the field), where the global START = {x, y, z} says; its
-- job then begins with the way home. Until that first `home` its trail leads back to where it
-- was left, not to the charger, so it neither goes back to charge nor empties itself on an
-- error: it would drop its things in the field. It never moves into a liquid. A step that is
-- blocked by anything but an entity, or a block that will not break, stops the job: the robot
-- goes back the way it came, empties itself, and says where and why, and the PC plans again.
--
-- When its energy would not get it back the way it came with a margin, or its inventory is
-- nearly full, it goes back the same way, empties itself and charges, and comes out along the
-- same moves again. That way is known clear: it has just been through it.
--
-- Events for the live view (docs/viewer.md, "The live view"): `at x y z facing energy` after every
-- step, `blk x y z 0` and `broke x y z` for every block broken (clear.py --apply reads those).

local z = ...
local component, computer, sides = require("component"), require("computer"), require("sides")

-- run.py sets JOB and START as globals, and globals outlive the zone on the robot: the START of
-- the run that brought it home (2026-10-04) was still set for the next job, which then counted
-- its position from out in the field. So they are taken and cleared at once.
local JOB, START = JOB, START
_G.JOB, _G.START = nil, nil

-- run.py sets JOB and START as globals, and globals outlive the zone on the robot: the START of
-- the run that brought it home (2026-10-04) was still set for the next job, which then counted
-- its position from out in the field. So they are taken and cleared at once.
local JOB, START = JOB, START
_G.JOB, _G.START = nil, nil
local robot, geo, nav = component.robot, component.geolyzer, component.navigation

local MARGIN = 3000             -- energy kept on top of the way back
local PER_BLOCK = 12            -- energy per step of the way back, generously (7 measured)
local CHARGED = 0.95            -- charging ends at this share of the maximum
local FREE_SLOTS = 2            -- fewer empty slots than this, and it goes to empty itself

local CLOCKWISE = {2, 5, 3, 4}  -- north, east, south, west, as navigation numbers them
local FACE = {n = 2, e = 5, s = 3, w = 4}
local NAME = {[2] = "north", [3] = "south", [4] = "west", [5] = "east"}
local STEP = {n = {0, 0, -1}, s = {0, 0, 1}, e = {1, 0, 0}, w = {-1, 0, 0}, u = {0, 1, 0},
              d = {0, -1, 0}}
local BACK = {n = "s", s = "n", e = "w", w = "e", u = "d", d = "u"}

local function say(s)
  z.send(tostring(s))
  os.sleep(0)                   -- lets octerm send it now (see contour.lua)
end

-- ---- facing and moving ------------------------------------------------------------------------

local pos = START and {x = START[1], y = START[2], z = START[3]} or {x = 0, y = 0, z = 0}
local facing = nav.getFacing()
local startFacing = facing
local turns = 0
for i, f in ipairs(CLOCKWISE) do if f == facing then turns = i end end

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

-- The robot-relative side toward a direction, facing it first if it is a side: a robot swings
-- and moves only ahead, up and down.
local function side(dir)
  if dir == "u" then return sides.up elseif dir == "d" then return sides.down end
  face(FACE[dir])
  return sides.front
end

local function at()
  say(("at %d %d %d %s %d"):format(pos.x, pos.y, pos.z, NAME[facing],
      math.floor(computer.energy())))
end

-- One step. Waits out an entity in the way; anything else, or a liquid, is an error.
local function step(dir)
  local s = side(dir)
  for attempt = 1, 10 do
    local _, kind = robot.detect(s)
    if kind == "liquid" then return false, "a liquid toward " .. dir end
    if robot.move(s) then
      local d = STEP[dir]
      pos.x, pos.y, pos.z = pos.x + d[1], pos.y + d[2], pos.z + d[3]
      at()
      return true
    end
    _, kind = robot.detect(s)
    if kind ~= "entity" then return false, ("blocked toward %s (%s)"):format(dir, kind) end
    os.sleep(1)
  end
  return false, "an entity stayed in the way toward " .. dir
end

-- ---- the way back, and out again ---------------------------------------------------------------

local trail = {}                -- the steps since the start block, to go back by

local function walk(dir)
  local ok, why = step(dir)
  if ok then trail[#trail + 1] = dir end
  return ok, why
end

local function goBack()
  while #trail > 0 do
    local ok, why = step(BACK[trail[#trail]])
    if not ok then return false, "on the way back: " .. why end
    trail[#trail] = nil
  end
  return true
end

-- Empties the inventory into the mini ME's interface: one step south, it is to the east (the
-- station's layout, docs/map.md), then back onto the start block. The tool is not in the inventory.
local function unload()
  local ok, why = step("s")
  if not ok then return false, "to the mini ME: " .. why end
  face(FACE.e)
  local kept = 0
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) > 0 then
      robot.select(slot)
      robot.drop(sides.front)
      if robot.count(slot) > 0 then kept = kept + 1 end
    end
  end
  robot.select(1)
  ok, why = step("n")
  if not ok then return false, "back from the mini ME: " .. why end
  if kept > 0 then say(("the mini ME did not take %d stacks"):format(kept)) end
  return true
end

local function charge()
  say(("charge home %d"):format(math.floor(computer.energy())))
  local last, still = computer.energy(), 0
  while computer.energy() < CHARGED * computer.maxEnergy() do
    os.sleep(5)
    local e = computer.energy()
    say(("charge wait %d"):format(math.floor(e)))
    if e <= last + 1 then still = still + 5 else still = 0 end
    if still >= 60 then return false, "the charger gave nothing for a minute; is it powered?" end
    last = e
  end
  say(("charge done %d"):format(math.floor(computer.energy())))
  return true
end

local function freeSlots()
  local n = 0
  for slot = 1, robot.inventorySize() do
    if robot.count(slot) == 0 then n = n + 1 end
  end
  return n
end

-- Back to the start block, empty, charged, and out again along the same steps.
local function detour(why)
  say("going home: " .. why)
  local out = {}
  for i, d in ipairs(trail) do out[i] = d end
  local ok, err = goBack()
  if not ok then return false, err end
  ok, err = unload()
  if not ok then return false, err end
  ok, err = charge()
  if not ok then return false, err end
  for _, d in ipairs(out) do
    ok, err = walk(d)
    if not ok then return false, "going out again: " .. err end
  end
  return true
end

local away = START ~= nil       -- not yet home: the trail does not lead to the charger

local function needsHome()
  if away then return nil end
  if computer.energy() < #trail * PER_BLOCK + MARGIN then return "energy" end
  if freeSlots() < FREE_SLOTS then return "inventory nearly full" end
end

-- ---- breaking ---------------------------------------------------------------------------------

local function breakToward(dir, x, y, zz, what)
  local s = side(dir)
  for attempt = 1, 4 do
    local _, kind = robot.detect(s)
    if kind == "air" then
      say(("blk %d %d %d 0"):format(x, y, zz))
      say(("broke %d %d %d"):format(x, y, zz))
      return true
    end
    if kind == "liquid" then return false, "a liquid where " .. what .. " should be" end
    robot.swing(s)
  end
  local _, kind = robot.detect(s)
  return false, ("%s at %d %d %d did not break (%s)"):format(what, x, y, zz, kind)
end

-- ---- the job ----------------------------------------------------------------------------------

-- Home is where the charger is east: checked before anything moves, unless it starts elsewhere.
if not START then
  local east = geo.analyze(side("e"))
  if type(east) ~= "table" or east.name ~= "OpenComputers:charger" then
    error("not on the start block: no charger to the east (" .. tostring(east and east.name)
          .. ")")
  end
end
at()

local n, done, why = 0, 0, nil
for line in JOB:gmatch("[^\n]+") do
  n = n + 1
  local cmd, dir, x, y, zz, what = line:match("^(%a+) ?(%a?) ?(-?%d*) ?(-?%d*) ?(-?%d*) ?(%S*)")
  local ok, err = true, nil
  if cmd == "m" then
    local need = needsHome()
    if need then ok, err = detour(need) end
    if ok then ok, err = walk(dir) end
  elseif cmd == "b" then
    local need = needsHome()
    if need then ok, err = detour(need) end
    if ok then
      ok, err = breakToward(dir, tonumber(x), tonumber(y), tonumber(zz), what)
      if ok then done = done + 1 end
    end
  elseif cmd == "home" then
    trail, away = {}, false
    ok, err = unload()
    if ok then ok, err = charge() end
  end
  if not ok then
    why = ("line %d (%s): %s"):format(n, line, err)
    break
  end
end

if why then
  say("stopped at " .. why)
  local ok, err = true, nil
  if away then ok, err = false, "it was not home yet; it stays where it stopped" end
  if ok then ok, err = goBack() end
  if ok then ok, err = unload() end
  if not ok then say("and could not get home: " .. err) end
end
-- At home it faces south, as it stood at the start (the charger on its left, docs/map.md), for the
-- programs that count from there; left out in the field, as it was.
face(away and startFacing or FACE.s)
at()
say(("done: %d blocks broken%s"):format(done, why and ", stopped early" or ""))
