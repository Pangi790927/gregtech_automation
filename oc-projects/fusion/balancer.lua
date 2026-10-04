-- balancer.lua: keeps the 16 fusion plasmas at about the same level, using MK2 + MK3.
-- Rules (BALANCER.txt): one recipe per reactor at a time; A -> NORTH, B -> SOUTH;
-- only full batches (max(parallels x 4, runs for start energy <= 10%)); skip a recipe if
-- the stock for the full batch is not there; restart a reactor that stopped with EU full.
-- Start:  balancer          (runs until stopped)
-- Stop:   create /home/fusion/balancer.stop   (or Ctrl+C) -> reactors off, configs cleared
-- Log:    /home/fusion/balancer.log    Status: /home/fusion/balancer.status
local component = require("component")
local computer = require("computer")
local fs = require("filesystem")
local L = dofile("/home/fusion/fuslib.lua")

local DIR = "/home/fusion/"
local STOPFILE = DIR .. "balancer.stop"
local MAX_LEVEL = nil      -- optional: never make a plasma above this many L (nil = no cap)
local STALL = 90           -- game seconds without any progress -> report it (reactor keeps going)
local AMORT = 0.10         -- start energy at most this share of the batch energy
local MINX = 4             -- at least parallels x MINX runs

-- name, reactors, A, aPerRun, B, bPerRun, outPerRun, EU/t, ticks, start (M EU)
local RECIPES = {
  {"helium",    "23", "deuterium", 125, "tritium", 125, 125, 4096, 16, 40},
  {"helium",    "23", "deuterium", 125, "helium-3", 125, 125, 2048, 16, 60},
  {"boron",     "23", "plasma.helium", 144, "molten.lithium", 144, 144, 10240, 240, 50},
  {"oxygen",    "23", "plasma.boron", 144, "molten.lithium", 144, 144, 49152, 240, 100},
  {"titanium",  "23", "molten.aluminium", 144, "fluorine", 144, 144, 49152, 160, 100},
  {"calcium",   "23", "molten.magnesium", 128, "oxygen", 128, 16, 8192, 128, 120},
  {"nitrogen",  "23", "molten.beryllium", 16, "deuterium", 375, 125, 16384, 16, 180},
  {"zinc",      "23", "molten.copper", 72, "tritium", 250, 72, 49152, 16, 180},
  {"niobium",   "23", "molten.cobalt", 144, "molten.silicon", 144, 144, 49152, 16, 200},
  {"sulfur",    "23", "molten.aluminium", 16, "molten.lithium", 16, 144, 10240, 32, 240},
  {"tin",       "23", "molten.silver", 144, "helium-3", 375, 144, 49152, 16, 280},
  {"iron",      "3",  "molten.silicon", 16, "molten.magnesium", 16, 144, 8192, 32, 360},
  {"radon",     "3",  "molten.iridium", 144, "fluorine", 500, 144, 98304, 32, 450},
  {"nickel",    "3",  "molten.potassium", 16, "fluorine", 144, 144, 32700, 16, 480},
  {"silver",    "3",  "molten.gold", 144, "molten.arsenic", 144, 144, 49152, 16, 350},
  {"bismuth",   "3",  "molten.tantalum", 144, "plasma.zinc", 72, 144, 98304, 16, 350},
  {"americium", "3",  "molten.plutonium241", 144, "hydrogen", 2000, 144, 98304, 64, 500},
}
local PLASMAS = {"helium", "boron", "oxygen", "titanium", "calcium", "nitrogen", "zinc", "niobium",
  "sulfur", "tin", "iron", "radon", "nickel", "silver", "bismuth", "americium"}

local function parallels(r, start)
  if r == "mk2" then return start < 160 and 128 or 64 end
  return start < 160 and 192 or (start < 320 and 128 or 64)
end

local function batchRuns(r, rc)
  local P = parallels(r, rc[10])
  local need = math.ceil((1 - AMORT) / AMORT * rc[10] * 1e6 / (rc[8] * rc[9]))
  return math.max(MINX * P, math.ceil(need / P) * P)
end

local logf = io.open(DIR .. "balancer.log", "a")
local function log(msg)
  local line = os.date("%H:%M:%S") .. " " .. msg
  logf:write(line, "\n"); logf:flush()
  print(line)
end

local function px(a) return component.proxy(component.get(a)) end

-- per reactor state
local S = {}
for _, r in ipairs({"mk2", "mk3"}) do
  S[r] = {state = "idle", err = nil}
end

local function sensorPar(g)
  for _, line in ipairs(g.getSensorInformation() or {}) do
    local v = line:gsub("§.", ""):match("Running Parallel: ([%d,]+)")
    if v then return v end
  end
  return "?"
end

-- fluids reserved by a reactor's running batch (still to be fed)
local function reserved(name, except)
  local n = 0
  for r, s in pairs(S) do
    if r ~= except and s.state == "run" then
      if s.rc[3] == name then n = n + s.la end
      if s.rc[5] == name then n = n + s.lb end
    end
  end
  return n
end

local function conflicts(r, rc)
  for o, s in pairs(S) do
    if o ~= r and s.state == "run" then
      local orc = s.rc
      local po, pn = "plasma." .. orc[1], "plasma." .. rc[1]
      if orc[1] == rc[1] then return true end                 -- same output
      if rc[3] == po or rc[5] == po then return true end      -- my input is its output
      if orc[3] == pn or orc[5] == pn then return true end    -- its input is my output
    end
  end
  return false
end

local function choose(r, fl)
  local tag = r == "mk2" and "2" or "3"
  local best, bestLevel, skipped = nil, math.huge, {}
  for _, rc in ipairs(RECIPES) do
    if rc[2]:find(tag, 1, true) and not (r == "mk3" and rc[2] == "23" and false) then
      local level = fl["plasma." .. rc[1]] or 0
      if (not MAX_LEVEL or level < MAX_LEVEL) then
        local runs = batchRuns(r, rc)
        local needA, needB = runs * rc[4], runs * rc[6]
        local haveA = (fl[rc[3]] or 0) - reserved(rc[3], r)
        local haveB = (fl[rc[5]] or 0) - reserved(rc[5], r)
        if haveA >= needA and haveB >= needB then
          local score = level
          if score < bestLevel then best, bestLevel = {rc = rc, runs = runs}, score end
        else
          skipped[#skipped + 1] = rc[1]
        end
      end
    end
  end
  return best, skipped
end

local function start(r, pick, fl)
  local s, rc = S[r], pick.rc
  L.config(r, {rc[3], rc[5]})
  s.rc, s.runs = rc, pick.runs
  s.la, s.lb = pick.runs * rc[4], pick.runs * rc[6]
  s.expect = pick.runs * rc[7]
  s.base = fl["plasma." .. rc[1]] or 0
  s.made, s.lastProg, s.idle, s.restarts, s.stallLogged = 0, -1, 0, 0, false
  s.t0 = computer.uptime(); s.since = s.t0; s.fedAt = nil
  s.state = "run"
  L.power(r, true)
  log(string.format("%s START %s: %d runs (%d L), A %s %d, B %s %d, level %d",
    r, rc[1], pick.runs, s.expect, rc[3], s.la, rc[5], s.lb, s.base))
end

local function finish(r, why)
  local s = S[r]
  L.power(r, false)
  L.clear(r)
  log(string.format("%s DONE %s (%s): ME +%d (expected %d from this reactor), restarts %d, %.0f s",
    r, s.rc[1], why, s.made, s.expect, s.restarts, computer.uptime() - s.t0))
  s.state = "idle"
end

-- Completion does not use ME levels (both reactors may make the same plasma):
-- done = all fed, buffers empty, reactor idle with EU full and a restart did not start it.
local function step(r, fl, n)
  local s = S[r]
  if s.state ~= "run" then return end
  local now = computer.uptime()
  local t, g = px(L.R[r].tp), px(L.R[r].gt)
  if s.la > 0 then local _, m = t.transferFluid(4, 2, s.la, 0); s.la = s.la - (m or 0) end
  if s.lb > 0 then local _, m = t.transferFluid(4, 3, s.lb, 1); s.lb = s.lb - (m or 0) end
  s.made = (fl["plasma." .. s.rc[1] ] or 0) - s.base   -- info only (includes other reactor)
  local nb, sb = t.getFluidInTank(2)[1].amount, t.getFluidInTank(3)[1].amount
  local fed = s.la == 0 and s.lb == 0 and nb == 0 and sb == 0
  if fed and not s.fedAt then s.fedAt = now end
  local active = g.isMachineActive()
  local prog = s.la + s.lb + nb + sb
  if active or prog ~= s.lastProg then s.lastProg, s.since, s.stallLogged = prog, now, false end
  if active then s.idle = 0; s.tries = 0 else s.idle = s.idle + 1 end
  if s.idle >= 3 and g.getEUStored() >= g.getEUMaxStored() * 0.99 then
    if fed and (s.tries or 0) >= 2 then return finish(r, "inputs used up") end
    g.setWorkAllowed(false); os.sleep(0.5); g.setWorkAllowed(true)
    s.restarts = s.restarts + 1; s.idle = 0; s.tries = (s.tries or 0) + 1
  end
  if now - s.since >= STALL and not s.stallLogged then
    s.err = string.format("STALL %s: no progress %d s; left A %d B %d, buffers N %d S %d, EU %d",
      s.rc[1], STALL, s.la, s.lb, nb, sb, g.getEUStored())
    log(r .. " " .. s.err .. " (reactor left on)")
    s.stallLogged = true
  end
end

local function writeStatus(fl, n)
  local f = io.open(DIR .. "balancer.status", "w")
  f:write("# balancer status " .. os.date() .. " step " .. n .. "\n")
  for _, r in ipairs({"mk2", "mk3"}) do
    local s = S[r]
    if s.state == "run" then
      f:write(string.format("%s run %s %d/%d L, left A %d B %d, restarts %d\n", r, s.rc[1], s.made, s.expect, s.la, s.lb, s.restarts))
    else
      f:write(r .. " " .. s.state .. (s.err and (" " .. s.err) or "") .. "\n")
    end
  end
  for _, p in ipairs(PLASMAS) do f:write(string.format("%-10s %d\n", p, fl["plasma." .. p] or 0)) end
  f:close()
end

-- dry run: "balancer plan" prints batch sizes and what each reactor would pick now
local args = {...}
if args[1] == "plan" then
  local fl = L.fluids()
  for _, rc in ipairs(RECIPES) do
    local line = string.format("%-9s %-14s/%-14s", rc[1], rc[3], rc[5])
    for _, r in ipairs({"mk2", "mk3"}) do
      if rc[2]:find(r == "mk2" and "2" or "3", 1, true) then
        local runs = batchRuns(r, rc)
        local okA = (fl[rc[3] ] or 0) >= runs * rc[4]
        local okB = (fl[rc[5] ] or 0) >= runs * rc[6]
        line = line .. string.format(" %s %d runs=%dL %s", r, runs, runs * rc[7], (okA and okB) and "OK" or "short")
      end
    end
    print(line)
  end
  for _, r in ipairs({"mk3", "mk2"}) do
    local pick = choose(r, fl)
    print(r .. " would start: " .. (pick and (pick.rc[1] .. " " .. pick.runs .. " runs") or "nothing"))
    if pick then S[r] = {state = "run", rc = pick.rc, la = pick.runs * pick.rc[4], lb = pick.runs * pick.rc[6]} end
  end
  return
end

-- main
if fs.exists(STOPFILE) then fs.remove(STOPFILE) end
for _, r in ipairs({"mk2", "mk3"}) do L.power(r, false); L.clear(r) end
log("balancer started")
local n, lastSkipLog = 0, -1000
local ok, err = pcall(function()
  while not fs.exists(STOPFILE) do
    n = n + 1
    local fl = L.fluids()
    for _, r in ipairs({"mk3", "mk2"}) do
      if S[r].state == "run" then step(r, fl, n) end
    end
    for _, r in ipairs({"mk3", "mk2"}) do
      if S[r].state == "idle" then
        local pick, skipped = choose(r, fl)
        if pick then start(r, pick, fl)
        elseif n - lastSkipLog >= 300 then
          log(r .. " idle: no full batch in stock (skipped: " .. table.concat(skipped, " ") .. ")")
          lastSkipLog = n
        end
      end
    end
    if n % 5 == 0 then writeStatus(fl, n) end
    os.sleep(1)
  end
end)
for _, r in ipairs({"mk2", "mk3"}) do
  pcall(L.power, r, false); pcall(L.clear, r)
  if S[r].state == "run" then
    log(string.format("%s STOPPED during %s: made %d of %d, left A %d B %d (rest may be in hatches)",
      r, S[r].rc[1], S[r].made, S[r].expect, S[r].la, S[r].lb))
  end
end
log("balancer stopped" .. (ok and "" or (": " .. tostring(err))))
logf:close()
