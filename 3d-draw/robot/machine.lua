-- machine.lua - the robot as a state machine (3d-draw/redesign/03-exec.md, 04-notation.md): it
-- runs the programs the PC sends, op by op, with no thinking of its own, and says where it is.
-- Replaces server.lua; named apart from the first clearing job's robot/exec.lua, which stays
-- until the user has walked through it. The user, 2026-10-05: "serialize an execution rather
-- than tell it a simple path ... no thinking on the robot, simple state machine".
--
-- Two ways to load it:
--   - on the robot, as a zone (3d-draw's PC opens it): `...` is the zone, and the loop at the end
--     runs - commands in, replies out;
--   - in tests and in the PC's simulation, by require: `...` is the module's name, and the module
--     table comes back - the parser and the machine, which take the robot's hardware as a table
--     (`hw`, below), so a mock can stand in for it.
--
-- The conversation, text lines in the zone's 'd' frames (console/protocol.h):
--   PC -> robot   <rid> exec <id> <program>        a new program; replaces what is left of the
--                                                  last one after its current op
--                 <rid> give_way <id> <program>    a robot waiting on another: this first, then
--                                                  back to the op it waited at
--                 <rid> geo <x> <z> <y> <w> <d> <h>  a geolyzer scan, answered at once
--                 <rid> status_fast | status | history [id] | bye
--                 <rid> setpos <x> <y> <z>         where it stands, as the PC found it; not while
--                                                  a program runs
--   robot -> PC   <rid> ok <n> [value]             then n lines, for status and history
--                 <rid> err <why>
--                 ready <status_fast line>         once, when it starts
--
-- What the robot keeps, whatever it is sent (03-exec.md):
--   - a dig only of the block the program names (its palette), never of a robot;
--   - a block in a step's way is not dug: the program stops, `blocked <name>`;
--   - a creature or a robot in the way: it waits, trying again each second;
--   - energy: before each op, energy < steps since the program began x STEP + `$cost` + LEEWAY
--     stops it, `no-energy`; then only a `$home` program runs (the user, 2026-10-05: the robot
--     never finds its own way home, the PC sends it);
--   - water is the PC's alone (the user, 2026-10-05: "the robot only executes, he doesn't care
--     about water").
-- Every op done or failed goes to the history (and to a file on the robot), for `history`.

local M = {}

M.STEP, M.LEEWAY = 12, 500          -- energy a step home costs (server.lua: 7 measured), margin
local DIRS = {["^"] = "n", v = "s", [">"] = "e", ["<"] = "w", ["+"] = "u", ["-"] = "d"}
local STEP = {n = {0, 0, -1}, s = {0, 0, 1}, e = {1, 0, 0}, w = {-1, 0, 0}, u = {0, 1, 0},
              d = {0, -1, 0}}
local BACK = {n = "s", s = "n", e = "w", w = "e", u = "d", d = "u"}
M.DIRS, M.STEP_OF = DIRS, STEP

-- ---- the notation (04-notation.md) ------------------------------------------------------------

-- A reader over the program's characters, whitespace dropped.
local function reader(text)
  local s = text:gsub("%s+", "")
  local r = {s = s, i = 1}
  function r.peek() return s:sub(r.i, r.i) end
  function r.take() local c = s:sub(r.i, r.i); r.i = r.i + 1; return c end
  function r.done() return r.i > #s end
  function r.num()
    local d = s:match("^%d+", r.i)
    if not d then return nil end
    r.i = r.i + #d
    return tonumber(d)
  end
  function r.dir()
    local d = DIRS[r.peek()]
    if d then r.i = r.i + 1 end
    return d
  end
  return r
end

-- One op from the reader, or nil and why. `src` is the op's own text, for the history.
local function read_op(r)
  local start = r.i
  local c = r.take()
  local op
  if DIRS[c] then
    op = {k = "step", dir = DIRS[c], n = r.num() or 1}
    if op.n < 1 then return nil, "a step counted 0" end
  elseif c == "f" then
    op = {k = "face", dir = r.dir()}
    if not op.dir or op.dir == "u" or op.dir == "d" then return nil, "f needs a side" end
  elseif c == "x" then
    op = {k = "dig", dir = r.dir(), block = r.num()}
    if not op.dir or not op.block then return nil, "x needs a direction and a block" end
  elseif c == "p" or c == "u" then
    op = {k = c == "p" and "put" or "use", dir = r.dir(), slot = r.num()}
    if not op.dir or (c == "p" and not op.slot) then return nil, c .. " needs its parts" end
    if r.peek() == "/" then
      r.take()
      op.face = r.dir()
      if not op.face then return nil, "/ needs a face" end
    end
    if r.peek() == "!" then r.take(); op.sneak = true end
  elseif c == "t" then
    op = {k = "take", dir = r.dir(), their = r.num()}
    if not op.dir or not op.their or r.take() ~= "." then return nil, "t<dir><their>.<mine>" end
    op.mine = r.num()
    if not op.mine then return nil, "t needs its own slot" end
    if r.peek() == "*" then r.take(); op.n = r.num() end
  elseif c == "g" then
    op = {k = "give", dir = r.dir(), mine = r.num()}
    if not op.dir or not op.mine then return nil, "g<dir><mine>" end
    if r.peek() == "." then                 -- into one slot of it: the interface's return slot
      r.take()
      op.their = r.num()
      if not op.their then return nil, "g<dir><mine>.<their>" end
    end
    if r.peek() == "*" then r.take(); op.n = r.num() end
  elseif c == "s" then
    op = {k = "shift", from = r.num()}
    if not op.from or r.take() ~= "." then return nil, "s<from>.<to>" end
    op.to = r.num()
    if not op.to then return nil, "s needs a slot to" end
    if r.peek() == "*" then r.take(); op.n = r.num() end
  elseif c == "c" then
    op = {k = "craft", slot = r.num()}
    if not op.slot then return nil, "c needs a slot" end
    if r.peek() == "*" then r.take(); op.n = r.num() end
  elseif c == "l" then
    op = {k = "look", dir = r.dir()}
    if not op.dir then return nil, "l needs a direction" end
  elseif c == "e" then
    op = {k = "equip", slot = r.num()}
    if not op.slot then return nil, "e needs a slot" end
  elseif c == "?" then
    op = {k = "expect", dir = r.dir(), block = r.num()}
    if not op.dir or not op.block then return nil, "? needs a direction and a block" end
  elseif c == "z" then
    op = {k = "charge", pct = r.num() or 95}
  elseif c == "@" then
    local v = r.num()
    if v ~= 0 and v ~= 1 then return nil, "@ takes 0 or 1" end
    op = {k = "chunk", on = v == 1}
  elseif c == "h" then
    op = {k = "halt"}
  else
    return nil, ("no op starts with %q"):format(c)
  end
  op.src = r.s:sub(start, r.i - 1)
  return op
end

--[[ A program's text into {cost, home, palette, ops}, or nil and why.
  $<cost> or $home first; then {name:meta,...} optionally; then the ops. ]]
function M.parse(text)
  local r = reader(text or "")
  local prog = {palette = {}, ops = {}}
  if r.take() ~= "$" then return nil, "a program starts with $<cost> or $home" end
  if r.s:sub(r.i, r.i + 3) == "home" then
    r.i = r.i + 4
    prog.home, prog.cost = true, 0
  else
    prog.cost = r.num()
    if not prog.cost then return nil, "$ needs a number or home" end
  end
  if r.peek() == "{" then
    local close = r.s:find("}", r.i, true)
    if not close then return nil, "the palette has no }" end
    for entry in r.s:sub(r.i + 1, close - 1):gmatch("[^,]+") do
      local name, meta = entry:match("^(.+):([%d%*]+)$")
      if not name then return nil, "palette entry " .. entry end
      prog.palette[#prog.palette + 1] = {name = name, meta = meta == "*" and "*" or tonumber(meta)}
    end
    r.i = close + 1
  end
  while not r.done() do
    local op, why = read_op(r)
    if not op then return nil, ("op %d: %s"):format(#prog.ops + 1, why) end
    if (op.k == "dig" or op.k == "expect") and not prog.palette[op.block] then
      return nil, ("op %d: block %d is not in the palette"):format(#prog.ops + 1, op.block)
    end
    prog.ops[#prog.ops + 1] = op
  end
  return prog
end

-- ---- the machine -------------------------------------------------------------------------------

--[[ The robot's hardware, as the machine uses it: every world direction is n s e w u d.
  hw.move(dir)                      true, or false and a kind ("entity", "solid", ...)
  hw.face(dir)                      true
  hw.analyze(dir)                   name, meta of the block there; nil for air
  hw.detect(dir)                    what robot.detect says: true or false, and a kind ("entity")
  hw.swing(dir)                     true when something broke
  hw.place(dir, slot, face, sneak)  true, or false and why
  hw.use(dir, slot, face, sneak)    what the use returned, as text
  hw.equip(slot)                    true when the slot's item and the tool in hand swapped
  hw.take(dir, their, mine, n)      how many came
  hw.give(dir, mine, n, their)      how many went: a plain drop, or into its slot `their`
  hw.shift(from, to, n)             true; hw.craft(slot, n) how many made
  hw.energy()                       energy, max
  hw.clock()                        seconds, the robot's own clock (computer.uptime)
  hw.chunk(on)                      true
  hw.scan(x, z, y, w, d, h)         hardness values, a table
  hw.extras()                       "max .. dur .. up .. mem .. chunk .. tanks" as text
  hw.inventory()                    "slot:name:meta:count;..."
  hw.save_pos(x, y, z, facing)      after every step
  hw.history(line | nil)            a line appended to the robot's file; nil starts it anew ]]
function M.new(hw, start)
  local m = {hw = hw, state = "idle", id = "-", prog = nil, pc = 1, left = 0, why = nil,
             pos = {start.x or 0, start.y or 0, start.z or 0}, facing = start.facing or "n",
             trail = {}, results = {}, hist = {}, stack = {}}

  -- every line ends with the robot's own clock, "@<seconds>": the PC fits its timings to them
  local function log(line)
    line = ("%s @%.2f"):format(line, hw.clock and hw.clock() or 0)
    m.hist[#m.hist + 1] = line
    hw.history(line)
  end

  local function stop(why)
    m.state, m.why = "stop", why
    local op = m.prog and m.prog.ops[m.pc]
    log(("%d %s stop %s"):format(m.pc, op and op.src or "-", why))
  end

  local function begin(id, prog)
    m.id, m.prog, m.pc, m.why = id, prog, 1, nil
    m.left = prog.ops[1] and prog.ops[1].k == "step" and prog.ops[1].n or 0
    m.trail, m.hist = {}, {}
    m.state = #prog.ops > 0 and "run" or "done"
    hw.history(nil)
  end

  local function next_op()
    m.pc = m.pc + 1
    local op = m.prog.ops[m.pc]
    m.left = op and op.k == "step" and op.n or 0
    if not op then
      if #m.stack > 0 then
        -- a give-way done: back to the op it was waiting at
        local s = table.remove(m.stack)
        m.id, m.prog, m.pc, m.left, m.trail = s.id, s.prog, s.pc, s.left, s.trail
        m.state = "run"
      else
        m.state = "done"
      end
    end
  end

  function m.exec(id, text)
    local prog, why = M.parse(text)
    if not prog then return nil, why end
    if m.state == "stop" and m.why == "no-energy" and not prog.home then
      return nil, "no-energy: only a $home program runs"
    end
    m.stack = {}
    begin(id, prog)
    return true
  end

  function m.give_way(id, text)
    if m.state ~= "wait" and m.state ~= "halt" then return nil, "not waiting: " .. m.state end
    local prog, why = M.parse(text)
    if not prog then return nil, why end
    m.stack[#m.stack + 1] = {id = m.id, prog = m.prog, pc = m.pc, left = m.left, trail = m.trail}
    begin(id, prog)
    return true
  end

  local function moved(dir)
    local d = STEP[dir]
    m.pos = {m.pos[1] + d[1], m.pos[2] + d[2], m.pos[3] + d[3]}
    if m.trail[#m.trail] == BACK[dir] then m.trail[#m.trail] = nil
    else m.trail[#m.trail + 1] = dir end
    if dir ~= "u" and dir ~= "d" then m.facing = dir end
    hw.save_pos(m.pos[1], m.pos[2], m.pos[3], m.facing)
  end

  -- One op: the machine's whole step. Returns the state after it.
  function m.step()
    if m.state ~= "run" and m.state ~= "wait" then return m.state end
    local op = m.prog.ops[m.pc]
    if not m.prog.home then
      local e = hw.energy()
      if e < #m.trail * M.STEP + m.prog.cost + M.LEEWAY then
        stop("no-energy")
        return m.state
      end
    end
    local k, ok, why, res = op.k, true, nil, nil
    -- an op sideways turns the robot to face it (the hardware's side(): a robot acts only in
    -- front, up or down): the machine's facing follows, as its copy's does - a dig sideways had
    -- left them telling different ways (Pintsize, dig -5 1 2, 2026-10-05)
    if k ~= "step" and op.dir and op.dir ~= "u" and op.dir ~= "d" then m.facing = op.dir end
    if k == "step" then
      local fine, kind = hw.move(op.dir)
      if not fine then
        local name = hw.analyze(op.dir)
        if name == "OpenComputers:robot" or kind == "entity" then
          m.state, m.why = "wait", name == "OpenComputers:robot" and "robot" or "entity"
          return m.state
        end
        stop("blocked " .. tostring(name or kind))
        return m.state
      end
      moved(op.dir)
      m.state, m.why = "run", nil
      m.left = m.left - 1
      log(("%d %s ok %d %d %d %d"):format(m.pc, op.src, m.pos[1], m.pos[2], m.pos[3],
              math.floor(hw.energy())))
      if m.left > 0 then return m.state end
      next_op()
      return m.state
    elseif k == "face" then
      hw.face(op.dir)
      m.facing = op.dir
    elseif k == "dig" then
      local want = m.prog.palette[op.block]
      local name, meta = hw.analyze(op.dir)
      if not name then
        -- air already: what the dig was to leave - done, nothing broken (10-live.md)
        log(("%d %s air already"):format(m.pc, op.src))
        m.results[#m.results + 1] = ("%d %s air"):format(m.pc, op.src)
        next_op()
        return m.state
      end
      if name == "OpenComputers:robot" or name ~= want.name
          or (want.meta ~= "*" and meta ~= want.meta) then
        stop(("not-expected %s"):format(name and (name .. ":" .. tostring(meta)) or "air"))
        return m.state
      end
      hw.swing(op.dir)
      local after = hw.analyze(op.dir)
      if after then ok, why = false, "not-dug " .. after end
    elseif k == "put" then
      ok, why = hw.place(op.dir, op.slot, op.face, op.sneak)
      if not ok then
        -- a robot or a creature in the cell is not a danger, only in the way: wait and try again
        -- every second, as a step does (the user, 2026-10-05: "robots should retry things that
        -- aren't dangerous: block placing and moving"). robot.place gives no reason for it (OC's
        -- Agent.place: false, or false and "nothing selected"); robot.detect says "entity".
        local name = hw.analyze(op.dir)
        local _, kind = hw.detect(op.dir)
        if name == "OpenComputers:robot" or (not name and kind == "entity") then
          m.state, m.why = "wait", name and "robot" or "entity"
          return m.state
        end
        why = "nothing-placed " .. tostring(why)
      end
    elseif k == "use" then
      res = hw.use(op.dir, op.slot, op.face, op.sneak)
    elseif k == "take" then
      -- only when told and only what is there: the interface's tick is the PC's to wait for
      -- (redesign/11-me.md); short is a stop, never tried again here
      local n = hw.take(op.dir, op.their, op.mine, op.n)
      res = tostring(n)
      if op.n and n < op.n then ok, why = false, ("took %d of %d"):format(n, op.n) end
    elseif k == "give" then
      local n = hw.give(op.dir, op.mine, op.n, op.their)
      res = tostring(n)
      if op.n and n < op.n then ok, why = false, ("gave %d of %d"):format(n, op.n) end
    elseif k == "shift" then
      ok = hw.shift(op.from, op.to, op.n)
      if not ok then why = "not-shifted" end
    elseif k == "craft" then
      local n = hw.craft(op.slot, op.n)
      res = tostring(n)
      if n == 0 then ok, why = false, "nothing-crafted" end
    elseif k == "look" then
      local name, meta = hw.analyze(op.dir)
      res = name and (name .. ":" .. tostring(meta)) or "air"
    elseif k == "equip" then
      -- that slot's item into the hand, the tool in hand into the slot (13-farm.md)
      ok = hw.equip(op.slot)
      if not ok then why = "not-equipped" end
    elseif k == "expect" then
      -- the block in front must be the one named, else a stop: a till that did not take
      local want = m.prog.palette[op.block]
      local name, meta = hw.analyze(op.dir)
      if not want or name ~= want.name or (want.meta ~= "*" and meta ~= want.meta) then
        stop(("not-expected %s"):format(name and (name .. ":" .. tostring(meta)) or "air"))
        return m.state
      end
    elseif k == "charge" then
      local e, max = hw.energy()
      if e < max * op.pct / 100 then
        m.state, m.why = "wait", "charge"
        return m.state
      end
    elseif k == "chunk" then
      hw.chunk(op.on)
    elseif k == "halt" then
      log(("%d %s halt"):format(m.pc, op.src))
      next_op()
      if m.state == "run" then m.state = "halt" end
      return m.state
    end
    if not ok then
      stop(why)
      return m.state
    end
    if res then m.results[#m.results + 1] = ("%d %s %s"):format(m.pc, op.src, res) end
    m.state, m.why = "run", nil
    log(("%d %s ok%s"):format(m.pc, op.src, res and (" " .. res) or ""))
    next_op()
    return m.state
  end

  -- Where it stands, told by the PC: a robot carried and placed again by hand keeps the position
  -- of the place it last walked to (Tom and Cairol, 2026-10-05, brought back to the base).
  function m.setpos(x, y, z)
    if m.state == "run" or m.state == "wait" then return nil, "a program is running" end
    if not (x and y and z) then return nil, "setpos <x> <y> <z>" end
    m.pos, m.trail = {x, y, z}, {}
    hw.save_pos(x, y, z, m.facing)
    return true
  end

  function m.status_fast()
    return ("%s %s %d %d %d %d %s %d%s"):format(m.id, m.state, m.pc, m.pos[1], m.pos[2],
            m.pos[3], m.facing, math.floor(hw.energy()), m.why and (" " .. m.why) or "")
  end

  -- The full status as lines: status_fast, the extras, the inventory, the results since the
  -- last status (then cleared).
  function m.status()
    local out = {m.status_fast(), hw.extras(), "inv " .. hw.inventory()}
    for _, r in ipairs(m.results) do out[#out + 1] = "res " .. r end
    m.results = {}
    return out
  end

  -- Only the box's own w x d x h values: the geolyzer's table is 64 long whatever the box, the
  -- rest noise (Pintsize, 2026-10-05: a 2-cell column came back as 64 numbers).
  function m.geo(x, z, y, w, d, h)
    local v = hw.scan(x, z, y, w, d, h)
    local out = {}
    for i = 1, math.min(#v, (w or 1) * (d or 1) * (h or 1)) do
      out[i] = v[i] == 0 and "0" or ("%.2f"):format(v[i])
    end
    return table.concat(out, ",")
  end

  return m
end

-- ---- on the robot ------------------------------------------------------------------------------

local z = ...
if type(z) ~= "table" or not z.send then return M end

local component, computer, sides = require("component"), require("computer"), require("sides")
local fs = require("filesystem")
local robot, geo, nav = component.robot, component.geolyzer, component.navigation
local ic = component.inventory_controller

local DIR = "/home/3d-draw/"
local POS, HIST = DIR .. "pos.txt", DIR .. "history.txt"
local FACE = {n = 2, s = 3, w = 4, e = 5}
local NAME = {[2] = "n", [3] = "s", [4] = "w", [5] = "e"}
local CLOCKWISE = {n = "e", e = "s", s = "w", w = "n"}
fs.makeDirectory(DIR)

-- Facing read from the navigation upgrade once, then kept through the turns the robot makes
-- (docs/speed.md: two getFacing calls a step cost a tick each).
local facing = NAME[nav.getFacing()] or "n"

local function face(dir)
  for _ = 1, 4 do
    if facing == dir then return true end
    robot.turn(CLOCKWISE[facing] == dir)
    facing = NAME[nav.getFacing()] or facing
  end
  return facing == dir
end

local function side(dir)
  if dir == "u" then return sides.up elseif dir == "d" then return sides.down end
  face(dir)
  return sides.front
end

-- A world direction as the robot-relative face robot.place and robot.use take (Agent.place:
-- checkSideForFace): 0 below, 1 above, 2 back, 3 front, 4 right, 5 left of where it faces.
local function local_face(dir)
  if dir == "u" then return sides.up elseif dir == "d" then return sides.down end
  if dir == facing then return sides.front end
  if CLOCKWISE[facing] == dir then return sides.right end
  if CLOCKWISE[dir] == facing then return sides.left end
  return sides.back
end

local hist_file = nil
local hw = {}
function hw.move(dir) return robot.move(side(dir)) end
function hw.face(dir) return face(dir) end
function hw.analyze(dir)
  local b = geo.analyze(side(dir))
  if type(b) ~= "table" or b.name == "minecraft:air" then return nil end
  return b.name, b.metadata or 0
end
function hw.detect(dir) return robot.detect(side(dir)) end
function hw.equip(slot)
  robot.select(slot)
  return ic.equip() and true or false
end
function hw.swing(dir) return robot.swing(side(dir)) end
function hw.place(dir, slot, f, sneak)
  robot.select(slot)
  local s = side(dir)
  if f then return robot.place(s, local_face(f), sneak or false) end
  return robot.place(s, sneak or false)
end
function hw.use(dir, slot, f, sneak)
  if slot then robot.select(slot); ic.equip() end
  local s = side(dir)
  local r = {f and robot.use(s, local_face(f), sneak or false) or robot.use(s, sneak or false)}
  if slot then ic.equip() end
  for i = 1, #r do r[i] = tostring(r[i]) end
  return table.concat(r, " ")
end
function hw.take(dir, their, mine, n)
  robot.select(mine)
  return ic.suckFromSlot(side(dir), their, n) or 0
end
function hw.give(dir, mine, n, their)
  robot.select(mine)
  local before = robot.count(mine)
  if their then ic.dropIntoSlot(side(dir), their, n)
  else robot.drop(side(dir), n) end
  return before - robot.count(mine)
end
function hw.shift(from, to, n)
  robot.select(from)
  return robot.transferTo(to, n)
end
function hw.craft(slot, n)
  robot.select(slot)
  local before = robot.count(slot)
  if not component.crafting.craft(n) then return 0 end
  return robot.count(slot) - before
end
function hw.energy() return computer.energy(), computer.maxEnergy() end
function hw.clock() return computer.uptime() end
function hw.chunk(on)
  if component.isAvailable("chunkloader") then component.chunkloader.setActive(on) end
  return true
end
function hw.scan(x, zz, y, w, d, h) return geo.scan(x, zz, y, w, d, h) end
function hw.extras()
  local chunk = component.isAvailable("chunkloader") and component.chunkloader.isActive()
  -- its name too, as the player gave it: a robot picked up and placed again comes back with a
  -- new address (Tom and Cairol, 2026-10-05), and only its name tells which it is
  local okn, name = pcall(robot.name)
  return ("max %d dur %s up %.0f mem %d/%d chunk %s tanks %s name %s slots %d"):format(
          math.floor(computer.maxEnergy()), tostring(robot.durability()), computer.uptime(),
          computer.freeMemory(), computer.totalMemory(), tostring(chunk),
          tostring(robot.tankCount and robot.tankCount() or 0),
          ((okn and name or "?"):gsub("%s", "_")), robot.inventorySize())
end
function hw.inventory()
  local out = {}
  for slot = 1, robot.inventorySize() do
    local st = robot.count(slot) > 0 and ic.getStackInInternalSlot(slot)
    if st then out[#out + 1] = ("%d:%s:%d:%d"):format(slot, st.name, st.damage or 0, st.size) end
  end
  return table.concat(out, ";")
end
function hw.save_pos(x, y, zz, f)
  local h = io.open(POS, "w")
  if h then h:write(("%d %d %d %s\n"):format(x, y, zz, f)); h:close() end
end
function hw.history(line)
  if line == nil then
    if hist_file then hist_file:close() end
    hist_file = io.open(HIST, "w")
    return
  end
  if hist_file then hist_file:write(line, "\n"); hist_file:flush() end
end

local start = {facing = facing}
local h = io.open(POS, "r")
if h then
  local x, y, zz = (h:read("*l") or ""):match("^(-?%d+) (-?%d+) (-?%d+)")
  h:close()
  start.x, start.y, start.z = tonumber(x), tonumber(y), tonumber(zz)
end
local m = M.new(hw, start)

-- One command line in, its reply out.
local function handle(line)
  local rid, cmd, rest = line:match("^(%S+)%s+(%S+)%s*(.*)$")
  if not rid then return nil end
  local function ok(value, lines)
    local head = ("%s ok %d%s\n"):format(rid, lines and #lines or 0, value and (" " .. value) or "")
    z.send(head .. (lines and #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""))
  end
  local function err(why) z.send(("%s err %s\n"):format(rid, tostring(why):gsub("\n", " "))) end
  if cmd == "exec" or cmd == "give_way" then
    local id, text = rest:match("^(%S+)%s*(.*)$")
    local fine, why = m[cmd](id or "-", text or "")
    if fine then ok() else err(why) end
  elseif cmd == "status_fast" then ok(m.status_fast())
  elseif cmd == "status" then ok(nil, m.status())
  elseif cmd == "history" then ok(nil, m.hist)
  elseif cmd == "geo" then
    local a = {}
    for v in rest:gmatch("%S+") do a[#a + 1] = tonumber(v) end
    ok(m.geo(table.unpack(a)))
  elseif cmd == "setpos" then
    local x, y, zz = rest:match("^(-?%d+)%s+(-?%d+)%s+(-?%d+)")
    local fine, why = m.setpos(tonumber(x), tonumber(y), tonumber(zz))
    if fine then ok(m.status_fast()) else err(why) end
  elseif cmd == "bye" then ok(); return "bye"
  else err("no command " .. cmd) end
end

z.send("ready " .. m.status_fast() .. "\n")
local buf, done = "", false
while not done do
  local st = m.state
  if st == "run" then m.step() end
  -- running: just read what came; waiting: try again in a second; else sleep until contacted
  buf = buf .. z.wait(st == "run" and 0 or st == "wait" and 1 or math.huge)
  for line in buf:gmatch("([^\n]*)\n") do
    if handle(line) == "bye" then done = true end
  end
  buf = buf:match("[^\n]*$")
  if st == "wait" and m.state == "wait" then m.state = "run"; m.step() end
end
