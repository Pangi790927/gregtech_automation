-- bench.lua - what a robot's step really costs, in server ticks: the micro-benchmark of
-- 3d-draw/docs/speed.md, driven by 3d-draw/bench.py. Asked for by the user, 2026-10-04: "tell me
-- the current marks of the bots and we must figure out why those are slow, so we will analyze
-- their speed and algorithms". Run as its own zone (`...` is the zone), never beside server.lua:
-- bench.py refuses a robot whose server zone is open.
--
-- It only moves straight up into the air over where it stands and back down to the same cell:
-- no swing, no place, nothing broken. Every phase that moves first scans the column over it and
-- refuses unless all of it reads exactly 0 (the geolyzer reads air so, and only air); a move that
-- fails part way goes back down the cells it came up through. It ends where it started, its
-- position file (/home/3d-draw/pos.txt) untouched; its stand-in for that file is bench.txt.
--
-- Commands, `<id> <command> [n]`, each answered `<id> ok <ticks> <cpu-ms> [what]` or `<id> err`:
--   ping            nothing: the relay's round trip, for bench.py to take off
--   sleep <s>       os.sleep(s): s * 20 game ticks; against the PC's clock, the server's TPS
--   facing <k>      k navigation.getFacing calls (not direct: a tick each, if the mod is right)
--   energy <k>      k computer.energy calls (direct: no tick)
--   save <k>        k of server.lua's save(): makeDirectory, open, write, close
--   detect <k>      k robot.detect calls, upward
--   scan <k>        k geolyzer scans of 24 cells, as server.lua's `scan` makes them
--   turns <k>       k turns, clockwise, then as many back (2k in all): robot.turn alone
--   bare <n>        n moves up and n down, robot.move alone
--   server <n>      n up and n down as server.lua's step() and C.move do them: detect, move,
--                   save, then where()'s getFacing and energy
--   nosave <n>      the same without save; nodetect <n> without detect; nofacing <n> without
--                   where()'s getFacing
-- The ticks are computer.uptime() differences: OpenComputers counts a machine's uptime in its
-- updates, one a server tick (Machine.update, 1.9.14), whatever the server's TPS.

local z = ...
local component, computer, sides = require("component"), require("computer"), require("sides")
local fs = require("filesystem")
local robot, geo, nav = component.robot, component.geolyzer, component.navigation

local DIR, FILE = "/home/3d-draw", "/home/3d-draw/bench.txt"
local MAXN, LOW = 12, 5000        -- the most steps up a phase; the energy it will not go under
local untimed = 0                 -- seconds of a phase spent on its safety check, taken off

local function save()             -- server.lua's save(), into a file of its own
  fs.makeDirectory(DIR)
  local f = io.open(FILE, "w")
  if f then f:write("0 0 0\n") f:close() end
end

-- Whether the n cells over it, and one more, are air: one scan, outside the timed part.
local function clear(n)
  local v = geo.scan(0, 0, 1, 1, 1, n + 1)
  if type(v) ~= "table" then return false end
  for i = 1, n + 1 do if v[i] ~= 0 then return false end end
  return true
end

-- Back down k cells it came up through: they were air a moment ago. An entity under it (a
-- player) is waited for, a second at a time, ten times.
local function down(k)
  for _ = 1, k do
    local ok = false
    for _ = 1, 10 do
      if robot.move(sides.down) then ok = true break end
      os.sleep(1)
    end
    if not ok then return false end
  end
  return true
end

-- n steps up and n down, each as `step` makes it; -> nil, why when it could not.
local function updown(n, step)
  n = math.floor(tonumber(n) or 0)
  if n < 1 or n > MAXN then return nil, "n from 1 to " .. MAXN end
  if computer.energy() < LOW then return nil, "too little energy" end
  local t0 = computer.uptime()
  local air = clear(n)
  untimed = computer.uptime() - t0               -- the check is not the phase's
  if not air then return nil, "the column over it is not all air" end
  local up = 0
  for _ = 1, n do
    if not step(sides.up) then
      if not down(up) then return nil, "STRANDED " .. up .. " up: could not get down" end
      return nil, "a move up failed at " .. up .. "; back down"
    end
    up = up + 1
  end
  for k = 1, n do
    if not step(sides.down) then       -- something under it: down the plain way, waiting
      if not down(n - k + 1) then return nil, "STRANDED: could not get down" end
      return nil, "a move down was held up: the phase's time is not a step's"
    end
  end
  return true
end

-- The steps the phases time: robot.move with or without what server.lua does round it (a step
-- up or down there is detect, move, save, and where()'s getFacing and computer.energy).
local function stepper(detect, store, facing)
  return function(s)
    if detect then robot.detect(s) end
    if not robot.move(s) then return false end
    if store then save() end
    if facing then nav.getFacing() computer.energy() end
    return true
  end
end

local C = {}
function C.ping() return true end
function C.sleep(s) os.sleep(tonumber(s) or 5) return true end
function C.facing(k) for _ = 1, tonumber(k) or 10 do nav.getFacing() end return true end
function C.energy(k) for _ = 1, tonumber(k) or 10 do computer.energy() end return true end
function C.save(k) for _ = 1, tonumber(k) or 10 do save() end return true end
function C.detect(k) for _ = 1, tonumber(k) or 10 do robot.detect(sides.up) end return true end
function C.scan(k) for _ = 1, tonumber(k) or 1 do geo.scan(0, 0, -8, 1, 1, 24) end return true end
function C.turns(k)
  k = tonumber(k) or 2
  for _ = 1, k do robot.turn(true) end
  for _ = 1, k do robot.turn(false) end
  return true
end
function C.bare(n) return updown(n, stepper(false, false, false)) end
function C.server(n) return updown(n, stepper(true, true, true)) end
function C.nosave(n) return updown(n, stepper(true, false, true)) end
function C.nodetect(n) return updown(n, stepper(false, true, true)) end
function C.nofacing(n) return updown(n, stepper(true, true, false)) end

local okName, myName = pcall(robot.name)
myName = (okName and myName or computer.address():sub(1, 8)):gsub("%s", "_")
z.send(("ready 0 0 0 %s %d %s\n"):format(({[2] = "n", [3] = "s", [4] = "w", [5] = "e"})
       [nav.getFacing()] or "n", math.floor(computer.energy()), myName))

local buf, done = "", false
while not done do
  buf = buf .. z.wait(5)
  while true do
    local line, rest = buf:match("^([^\n]*)\n(.*)$")
    if not line then break end
    buf = rest
    local id, cmd, arg = line:match("^(%S+)%s+(%S+)%s*(%S*)")
    if id then
      local reply
      if cmd == "bye" then
        pcall(fs.remove, FILE)
        reply, done = id .. " ok", true
      elseif not C[cmd] then
        reply = id .. " err no command " .. cmd
      else
        local t0, c0 = computer.uptime(), os.clock()
        untimed = 0
        local ok, res, why = pcall(C[cmd], arg ~= "" and arg or nil)
        local ticks = math.floor((computer.uptime() - t0 - untimed) * 20 + 0.5)
        local ms = math.floor((os.clock() - c0) * 1000 + 0.5)
        if ok and res then
          reply = ("%s ok %d %d"):format(id, ticks, ms)
        else
          reply = ("%s err %s"):format(id, tostring(ok and why or res):gsub("\n", " "))
        end
      end
      z.send(reply .. "\n")
    end
  end
end
