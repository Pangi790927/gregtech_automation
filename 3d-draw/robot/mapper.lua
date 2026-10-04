-- mapper.lua - maps the area inside the contour into a block array (3d-draw/docs/map.md, "2. The
-- map"). Run as a zone from the start block, after contour.lua: `...` is the zone, whose send()
-- carries the report and the map to the PC.
--
-- 1. Every column of the region (inside the contour and the contour itself) is scanned from the
--    start: the geolyzer reads air as exactly 0 and solid blocks as hardness plus noise
--    (measured on the server, 2026-10-04), so the scan says exactly where the air is.
-- 2. The robot flies through that air, never into a liquid, to the nearest cell next to a solid
--    block not yet named, and names its unnamed neighbours with geolyzer.analyze.
-- 3. Solid blocks it cannot reach are guessed by hardness: the nearest named block, or else
--    dirt, stone or obsidian (the user's defaults).
-- 4. The map goes to the PC and to /home/3d-draw/map.txt; the robot goes back to the start.
--
-- When its energy would not get it home with a margin, the robot goes home, waits at the charger
-- (on its left at the start) until it is nearly full, and carries on (the user, 2026-10-04:
-- areas will get much larger than the battery).
--
-- What it learns is sent as it happens, one event per line, for the simulator's live view
-- (3d-draw/docs/viewer.md, "The live view"): box, pal, scan, at, blk, guess, charge. Other lines
-- are messages for people.
--
-- Positions are relative to the start block, x east, y up, z south, as contour.lua counts them.

local z = ...
local component, computer, sides = require("component"), require("computer"), require("sides")
local robot, geo = component.robot, component.geolyzer

local MARGIN = 3000             -- energy kept on top of the way home
local PER_BLOCK = 12            -- energy per block of the way home, counted generously (7 seen)
local CHARGED = 0.95            -- charging ends at this share of the maximum
local BELOW, ABOVE = 4, 4       -- the box: the contour blocks' lowest -4 to highest +4
-- Grass is broken the moment it is named, and its cell is air from then on (the user,
-- 2026-10-04: it hides the terrain, "we don't want it there either way"). Only grass: the grass
-- and fern halves of double plants (metadata 2 and 3), not their flowers. Lavender stays (the
-- user, the same day, changing their mind); see LAVENDER below for the block under it.
local function isGrass(b)
  return b.name == "minecraft:tallgrass" or b.name == "BiomesOPlenty:foliage"
      or (b.name == "minecraft:double_plant" and (b.metadata == 2 or b.metadata == 3))
end

-- Lavender: Biomes O' Plenty's flowers2 with metadata 3 (its BlockBOPFlower2 names it so). A block
-- under one that the robot could not get at is taken to be grass (the user, 2026-10-04: "if you
-- can't get an angle on the block underneath it, that it is a grass block").
local LAVENDER_NAME, LAVENDER_META = "BiomesOPlenty:flowers2", 3

local CLOCKWISE = {2, 5, 3, 4}  -- north, east, south, west, as navigation numbers them
local STEP = {[2] = {0, -1}, [3] = {0, 1}, [4] = {-1, 0}, [5] = {1, 0}}
local NAME = {[2] = "north", [3] = "south", [4] = "west", [5] = "east"}

local function say(s)
  z.send(tostring(s))
  os.sleep(0)                   -- lets octerm send it now (see contour.lua)
end

-- An event for the live view. octerm sends what is queued when this thread yields, so it yields
-- every few events; `now` yields at once, for the robot's position.
local queued = 0
local function emit(s, now)
  z.send(s)
  queued = queued + 1
  if now or queued % 8 == 0 then os.sleep(0) end
end

-- Long loops must give the machine a chance, or OpenComputers stops the program.
local ticks = 0
local function breathe()
  ticks = ticks + 1
  if ticks % 2000 == 0 then os.sleep(0) end
end

-- ---- the contour and the region ------------------------------------------------------------

local contourKey
local path = {}
for line in io.lines("/home/3d-draw/contour.txt") do
  local key = line:match("^# contour block (%S+)")
  if key then contourKey = key end
  local x, y, zz = line:match("^(-?%d+) (-?%d+) (-?%d+)$")
  if x then path[#path + 1] = {tonumber(x), tonumber(y), tonumber(zz)} end
end
assert(contourKey and #path > 3, "no contour in /home/3d-draw/contour.txt")

-- The contour's own box and the columns inside it (not reachable from beyond the contour).
local bx0, bx1, bz0, bz1, cmin, cmax = 0, 0, 0, 0, math.huge, -math.huge
for _, p in ipairs(path) do
  bx0, bx1 = math.min(bx0, p[1]), math.max(bx1, p[1])
  bz0, bz1 = math.min(bz0, p[3]), math.max(bz1, p[3])
  cmin, cmax = math.min(cmin, p[2] - 1), math.max(cmax, p[2] - 1)   -- the blocks, under the path
end
local BW = bx1 - bx0 + 1
local function col(x, zz) return (zz - bz0 + 1) * (BW + 2) + (x - bx0 + 1) + 1 end
local edge, outside = {}, {}
for _, p in ipairs(path) do edge[col(p[1], p[3])] = true end
local todo = {{bx0 - 1, bz0 - 1}}
outside[col(bx0 - 1, bz0 - 1)] = true
while #todo > 0 do
  local c = table.remove(todo)
  for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
    local x, zz = c[1] + d[1], c[2] + d[2]
    local k = col(x, zz)
    if x >= bx0 - 1 and x <= bx1 + 1 and zz >= bz0 - 1 and zz <= bz1 + 1
        and not outside[k] and not edge[k] then
      outside[k] = true
      todo[#todo + 1] = {x, zz}
    end
  end
end
local function inContour(x, zz)
  return x >= bx0 and x <= bx1 and zz >= bz0 and zz <= bz1 and not outside[col(x, zz)]
end

-- Extending: columns beyond the contour the user painted in the simulator (2026-10-04: "look a
-- bit outside of the contour ... without redoing the whole map"), in /home/3d-draw/extend.txt as
-- `x z` lines, mapped onto the map already in /home/3d-draw/map.txt. Only when run.py --extend
-- sets the global EXTEND (it puts `EXTEND = true` before this file); otherwise, or with no map
-- yet, the whole contour is mapped as before.
local fs = require("filesystem")
local MAP, EXTRA = "/home/3d-draw/map.txt", "/home/3d-draw/extend.txt"
-- Taken and cleared at once: a global outlives the zone on the robot (see exec.lua).
local extra, extending = {}, EXTEND == true and fs.exists(EXTRA) and fs.exists(MAP)
_G.EXTEND = nil
local xmin, xmax, zmin, zmax = bx0, bx1, bz0, bz1
local tooFar = 0
if extending then
  for line in io.lines(EXTRA) do
    local x, zz = line:match("^(-?%d+) (-?%d+)$")
    x, zz = tonumber(x), tonumber(zz)
    if x and not inContour(x, zz) then
      if math.abs(x) > 32 or math.abs(zz) > 32 then
        tooFar = tooFar + 1               -- beyond the geolyzer's reach from the start block
      else
        extra[x .. "," .. zz] = true
        xmin, xmax = math.min(xmin, x), math.max(xmax, x)
        zmin, zmax = math.min(zmin, zz), math.max(zmax, zz)
      end
    end
  end
end
local function inRegion(x, zz) return inContour(x, zz) or extra[x .. "," .. zz] == true end

local ymin, ymax = cmin - BELOW, cmax + ABOVE
local baseYmax = ymax

-- The painted columns may be taller than the contour's box - pillars, the user said, and "it is
-- important you see them": each is scanned once, as high as the geolyzer reaches from the start
-- (32 above it), and the box's top is raised to 2 above the highest block found. The old columns
-- then have only those new layers scanned.
local REACH = math.min(64, 32 - ymin + 1)
local preScan = {}
for k in pairs(extra) do
  local x, zz = k:match("^(-?%d+),(-?%d+)$")
  x, zz = tonumber(x), tonumber(zz)
  local v = geo.scan(x, zz, ymin, 1, 1, REACH)
  preScan[k] = v
  for i = REACH, 1, -1 do
    if v[i] ~= 0 then
      ymax = math.max(ymax, math.min(ymin + i - 1 + 2, 32))
      break
    end
  end
end
local W, D, H = xmax - xmin + 1, zmax - zmin + 1, ymax - ymin + 1

-- ---- the map ---------------------------------------------------------------------------------

local function idx(x, y, zz) return ((y - ymin) * D + (zz - zmin)) * W + (x - xmin) + 1 end
local function inBox(x, y, zz)
  return y >= ymin and y <= ymax and inRegion(x, zz)
end

local map = {}                  -- id per cell: -1 outside, 0 air, 1 contour, then the palette
local hard = {}                 -- scanned hardness of the solid cells not named yet
local guessed = {}              -- true for the cells whose block is a guess
local palette = {}              -- id -> {name, meta, hardness, how}
local byKey = {}

local function paletteId(name, meta, hardness, how)
  local key = name .. "@" .. tostring(meta)
  if not byKey[key] then
    palette[#palette + 1] = {name = name, meta = meta, hardness = hardness, how = how}
    byKey[key] = #palette
    emit(("pal %d %s %d %.2f %s"):format(#palette, name, meta, hardness, how))
  end
  return byKey[key]
end
emit(("box %d %d %d %d %d %d"):format(xmin, xmax, ymin, ymax, zmin, zmax), true)

-- The map so far, when extending: its palette keeps its ids, its cells are copied into the larger
-- box, and both are sent again, so the live view - which starts over with each run - shows them.
local known = {}                -- columns the old map already has
if extending then
  local oldBox, layers, flags = nil, {}, {}
  for line in io.lines(MAP) do
    local a, b, c, d, e, f = line:match("^box x (%S+) (%S+) y (%S+) (%S+) z (%S+) (%S+)$")
    if a then oldBox = {tonumber(a), tonumber(b), tonumber(c), tonumber(d), tonumber(e),
                        tonumber(f)} end
    local id, n, m, h, how = line:match("^palette (%d+) (%S+) (%d+) (%S+) (%S+)$")
    if id then
      assert(tonumber(id) == #palette + 1, "the old palette is out of order")
      paletteId(n, tonumber(m), tonumber(h), how)
    end
    local ly, data = line:match("^layer (%S+) (.*)$")
    if ly then layers[tonumber(ly)] = data end
    local gy, gdata = line:match("^guessed (%S+) (.*)$")
    if gy then flags[tonumber(gy)] = gdata end
  end
  assert(oldBox, "no map in " .. MAP)
  for y, data in pairs(layers) do
    local gz = {}
    for row in (flags[y] or ""):gmatch("[^;]+") do gz[#gz + 1] = row end
    local zz, zi = oldBox[5], 1
    for row in data:gmatch("[^;]+") do
      local g = {}
      for v in (gz[zi] or ""):gmatch("[^,]+") do g[#g + 1] = v end
      local x, xi = oldBox[1], 1
      for v in row:gmatch("[^,]+") do
        local id = tonumber(v)
        if id and id >= 0 and y >= ymin and y <= ymax then
          known[x .. "," .. zz] = true
          map[idx(x, y, zz)] = id
          if g[xi] == "1" then guessed[idx(x, y, zz)] = true end
          if id > 0 then
            emit(("%s %d %d %d %d"):format(g[xi] == "1" and "guess" or "blk", x, y, zz, id))
          end
        end
        x, xi = x + 1, xi + 1
      end
      zz, zi = zz + 1, zi + 1
      breathe()
    end
  end
else
  local cname, cmeta = contourKey:match("^(.*)@(%d+)$")
  paletteId(cname, tonumber(cmeta), geo.analyze(sides.down).hardness, "analyzed")   -- id 1
end

-- 1. the scan, of the columns not already known
say(("region: x %d..%d, z %d..%d, y %d..%d%s; energy %d"):format(xmin, xmax, zmin, zmax, ymin,
    ymax, extending and ", extending the map" or "", math.floor(computer.energy())))
if tooFar > 0 then
  say(tooFar .. " painted columns are beyond the geolyzer's 32 blocks; skipped")
end
local columns = 0
for x = xmin, xmax do
  for zz = zmin, zmax do
    if inRegion(x, zz) and not known[x .. "," .. zz] then
      columns = columns + 1
      local v = preScan[x .. "," .. zz] or geo.scan(x, zz, ymin, 1, 1, H)
      local seen = {}             -- for the live view: air, solid, or liquid-hard (90 and up)
      for i = 1, H do seen[i] = v[i] == 0 and "." or v[i] >= 90 and "~" or "#" end
      emit(("scan %d %d %s"):format(x, zz, table.concat(seen)))
      for i = 1, H do
        local y = ymin + i - 1
        if x == 0 and y == 0 and zz == 0 then
          map[idx(x, y, zz)] = 0                        -- the robot itself reads as solid
        elseif v[i] == 0 then
          map[idx(x, y, zz)] = 0
        else
          hard[idx(x, y, zz)] = v[i]
        end
      end
    elseif not inRegion(x, zz) then
      for y = ymin, ymax do map[idx(x, y, zz)] = -1 end
    elseif ymax > baseYmax then
      -- an old column, under a box raised for the pillars: only the new layers
      local v = geo.scan(x, zz, baseYmax + 1, 1, 1, ymax - baseYmax)
      for i = 1, ymax - baseYmax do
        local y = baseYmax + i
        if v[i] == 0 then map[idx(x, y, zz)] = 0 else hard[idx(x, y, zz)] = v[i] end
      end
    end
  end
end
if not extending then
  for _, p in ipairs(path) do                           -- the contour blocks are known
    local i = idx(p[1], p[2] - 1, p[3])
    map[i], hard[i] = 1, nil
  end
end
say(("scanned %d columns; energy %d"):format(columns, math.floor(computer.energy())))

-- ---- moving ----------------------------------------------------------------------------------

local pos = {x = 0, y = 0, z = 0}
local facing = component.navigation.getFacing()
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

-- The robot-relative side toward a world direction: "up", "down", or a facing number.
local function sideToward(dir)
  if dir == "up" then return sides.up elseif dir == "down" then return sides.down end
  local d = 0
  for i, f in ipairs(CLOCKWISE) do if f == dir then d = (i - turns) % 4 end end
  return ({[0] = sides.front, [1] = sides.right, [2] = sides.back, [3] = sides.left})[d]
end

local DIRS = {{"up", 0, 1, 0}, {"down", 0, -1, 0}, {2, 0, 0, -1}, {3, 0, 0, 1}, {4, -1, 0, 0},
              {5, 1, 0, 0}}

-- Names the block toward `dir` and puts it in the map. Returns its id.
local unnamed = {}              -- cells analyze failed on: guessed with the unreached ones

-- Breaks the grass toward `dir` and says whether it is gone. A robot swings only ahead, up and
-- down, so for a side it turns to face it first.
local function breakGrass(dir)
  local side = sideToward(dir)
  if side ~= sides.up and side ~= sides.down and side ~= sides.front then
    face(dir)
    side = sides.front
  end
  for attempt = 1, 3 do
    robot.swing(side)
    if select(2, robot.detect(side)) == "air" then return true end
  end
  return false
end

-- Names the block toward `dir` and puts it in the map; returns its id, and the analysis. Grass
-- is broken here: its id is then 0, air.
local function name(dir, x, y, zz)
  local b = geo.analyze(sideToward(dir))
  if type(b) ~= "table" then
    if inBox(x, y, zz) then
      local i = idx(x, y, zz)
      unnamed[i], hard[i] = hard[i] or 1.5, nil
    end
    return nil, {name = "?"}
  end
  if isGrass(b) and breakGrass(dir) then
    if inBox(x, y, zz) then
      map[idx(x, y, zz)], hard[idx(x, y, zz)] = 0, nil
      emit(("blk %d %d %d 0"):format(x, y, zz))
    end
    return 0, b
  end
  local id = paletteId(b.name, b.metadata, b.hardness, "analyzed")
  if inBox(x, y, zz) then
    map[idx(x, y, zz)], hard[idx(x, y, zz)] = id, nil
    emit(("blk %d %d %d %d"):format(x, y, zz, id))
  end
  return id, b
end

-- One step toward a world direction. Never into a liquid; grass is broken (the user allowed
-- it); anything else in the way is named and marked solid, and the step fails.
local function step(dir)
  local dx, dy, dz = 0, 0, 0
  for _, d in ipairs(DIRS) do if d[1] == dir then dx, dy, dz = d[2], d[3], d[4] end end
  local x, y, zz = pos.x + dx, pos.y + dy, pos.z + dz
  local side
  if dir == "up" or dir == "down" then side = sideToward(dir) else face(dir); side = sides.front end
  for attempt = 1, 5 do
    local _, kind = robot.detect(side)
    if kind == "liquid" then name(dir, x, y, zz); return false end
    local ok = robot.move(side)
    if ok then
      pos.x, pos.y, pos.z = x, y, zz
      emit(("at %d %d %d %s %d"):format(x, y, zz, NAME[facing], math.floor(computer.energy())),
           true)
      return true
    end
    _, kind = robot.detect(side)
    if kind == "entity" then
      os.sleep(1)
    else
      if name(dir, x, y, zz) ~= 0 then return false end    -- 0: it was grass, now broken
      if dir ~= "up" and dir ~= "down" then face(dir) end
    end
  end
  return false
end

-- ---- the tour --------------------------------------------------------------------------------

-- Whether air cell `i` at x, y, z has a solid neighbour in the box not named yet.
local function useful(x, y, zz)
  for _, d in ipairs(DIRS) do
    local nx, ny, nz = x + d[2], y + d[3], zz + d[4]
    if inBox(nx, ny, nz) and hard[idx(nx, ny, nz)] then return true end
  end
  return false
end

-- Breadth-first through the air from the robot to the nearest cell `want` accepts; returns the
-- list of directions to get there, or nil.
local function route(want)
  local from = idx(pos.x, pos.y, pos.z)
  local prev = {[from] = false}
  local queue, head = {{pos.x, pos.y, pos.z}}, 1
  while queue[head] do
    local c = queue[head]
    head = head + 1
    breathe()
    if want(c[1], c[2], c[3]) then
      local dirs, i = {}, idx(c[1], c[2], c[3])
      while prev[i] do
        table.insert(dirs, 1, prev[i][2])
        i = prev[i][1]
      end
      return dirs
    end
    for _, d in ipairs(DIRS) do
      local nx, ny, nz = c[1] + d[2], c[2] + d[3], c[3] + d[4]
      local n = inBox(nx, ny, nz) and idx(nx, ny, nz)
      if n and prev[n] == nil and map[n] == 0 then
        prev[n] = {idx(c[1], c[2], c[3]), d[1]}
        queue[#queue + 1] = {nx, ny, nz}
      end
    end
  end
  return nil
end

local function nameAround()
  for _, d in ipairs(DIRS) do
    local nx, ny, nz = pos.x + d[2], pos.y + d[3], pos.z + d[4]
    if inBox(nx, ny, nz) and hard[idx(nx, ny, nz)] then name(d[1], nx, ny, nz) end
  end
end

-- Follows a route; a step that fails (something the scan read as air) ends it, and the next
-- search goes around.
local function follow(dirs)
  for _, dir in ipairs(dirs) do
    if not step(dir) then return false end
  end
  return true
end

-- Goes home, waits at the charger until nearly full, and says how it went. False, with why,
-- when it cannot get home or the charger gives nothing for a minute (is it powered?).
local function charge()
  emit(("charge home %d"):format(math.floor(computer.energy())), true)
  local home = route(function(x, y, zz) return x == 0 and y == 0 and zz == 0 end)
  if not home or not follow(home) then return false, "could not get home to charge" end
  face(startFacing)
  local last, still = computer.energy(), 0
  while computer.energy() < CHARGED * computer.maxEnergy() do
    os.sleep(5)
    local e = computer.energy()
    emit(("charge wait %d"):format(math.floor(e)), true)
    if e <= last + 1 then still = still + 5 else still = 0 end
    if still >= 60 then return false, "the charger gave nothing for a minute; is it powered?" end
    last = e
  end
  emit(("charge done %d"):format(math.floor(computer.energy())), true)
  return true
end

-- Energy to get home from here, generously: the way through the air can be longer than this.
local function homeCost()
  return (math.abs(pos.x) + math.abs(pos.y) + math.abs(pos.z)) * PER_BLOCK + MARGIN
end

local stops, why, failures = 0, nil, 0
emit(("at %d %d %d %s %d"):format(pos.x, pos.y, pos.z, NAME[facing],
     math.floor(computer.energy())), true)
nameAround()
while true do
  if computer.energy() < homeCost() then
    local ok, err = charge()
    if not ok then why = err; break end
  end
  if failures >= 20 then why = "20 routes in a row failed"; break end
  local dirs = route(useful)
  if not dirs then break end
  if not follow(dirs) then
    failures = failures + 1
  else
    failures = 0
    nameAround()
    stops = stops + 1
    if stops % 25 == 0 then
      say(("named from %d places, %d kinds of block; energy %d"):format(stops, #palette,
          math.floor(computer.energy())))
    end
  end
end

-- ---- what could not be reached -------------------------------------------------------------

local DEFAULTS = {{"minecraft:dirt", 0, 0.5}, {"minecraft:stone", 0, 1.5},
                  {"minecraft:obsidian", 0, 50}}
local unreached = 0
for i, h in pairs(unnamed) do hard[i] = h end
local function lavenderAbove(i)
  local above = map[i + W * D]
  local p = above and palette[above]
  return p and p.name == LAVENDER_NAME and p.meta == LAVENDER_META
end
for i, h in pairs(hard) do
  local best, bestDiff
  for id, p in ipairs(palette) do
    local diff = math.abs(p.hardness - h)
    if p.how == "analyzed" and (not bestDiff or diff < bestDiff) then best, bestDiff = id, diff end
  end
  if lavenderAbove(i) then
    best = byKey["minecraft:grass@0"] or paletteId("minecraft:grass", 0, 0.6, "default")
  elseif not best or bestDiff > 0.6 then
    local dbest, ddiff
    for _, d in ipairs(DEFAULTS) do
      local diff = math.abs(d[3] - h)
      if not ddiff or diff < ddiff then dbest, ddiff = d, diff end
    end
    best = paletteId(dbest[1], dbest[2], dbest[3], "default")
  end
  map[i], guessed[i] = best, true
  unreached = unreached + 1
  local rel = i - 1
  emit(("guess %d %d %d %d"):format(xmin + rel % W, ymin + math.floor(rel / (W * D)),
       zmin + math.floor(rel / W) % D, best))
  breathe()
end
hard = nil

-- Guesses kept from an earlier run follow the lavender rule too: they were made before it existed.
for i in pairs(guessed) do
  local p = palette[map[i]]
  if lavenderAbove(i) and not (p and p.name == "minecraft:grass") then
    local grass = byKey["minecraft:grass@0"] or paletteId("minecraft:grass", 0, 0.6, "default")
    map[i] = grass
    local rel = i - 1
    emit(("guess %d %d %d %d"):format(xmin + rel % W, ymin + math.floor(rel / (W * D)),
         zmin + math.floor(rel / W) % D, grass))
  end
end

-- ---- home, and the map -----------------------------------------------------------------------

local home = route(function(x, y, zz) return x == 0 and y == 0 and zz == 0 end)
if home and follow(home) then face(startFacing) else why = (why or "") .. "; could not get home" end

local lines = {"# 3d-draw map 1",
  ("box x %d %d y %d %d z %d %d"):format(xmin, xmax, ymin, ymax, zmin, zmax)}
for id, p in ipairs(palette) do
  lines[#lines + 1] = ("palette %d %s %d %.2f %s"):format(id, p.name, p.meta, p.hardness, p.how)
end
for _, what in ipairs({"layer", "guessed"}) do
  for y = ymin, ymax do
    local rows = {}
    for zz = zmin, zmax do
      local row = {}
      for x = xmin, xmax do
        local i = idx(x, y, zz)
        row[#row + 1] = what == "layer" and tostring(map[i] or -1) or (guessed[i] and "1" or "0")
      end
      rows[#rows + 1] = table.concat(row, ",")
    end
    lines[#lines + 1] = ("%s %d %s"):format(what, y, table.concat(rows, ";"))
  end
end
fs.makeDirectory("/home/3d-draw")
local f = assert(io.open("/home/3d-draw/map.txt", "w"))
f:write(table.concat(lines, "\n"), "\n")
f:close()
say(("map: %d kinds of block, named from %d places, %d cells guessed%s; energy %d; saved "
    .. "/home/3d-draw/map.txt"):format(#palette, stops, unreached,
    why and (", stopped: " .. why) or "", math.floor(computer.energy())))
for id, p in ipairs(palette) do
  say(("  %d %s:%d hardness %.2f %s"):format(id, p.name, p.meta, p.hardness, p.how))
end
