-- balancer2.lua: keeps the 16 fusion plasmas at about the same level, MK2 + MK3 (v2, 2026-10-01).
-- Per reactor a queue of at most 2 batches: feed batch 1 fully (tight loop, 50 ms), then choose
-- and feed batch 2 at once (choice uses PROJECTED levels: ME + output still to come from queued
-- batches), then wait until batch 1 is done before batch 3. Reactors stay on.
-- Interface: 3 slots for A (tanks 0-2 -> NORTH), 3 for B (tanks 3-5 -> SOUTH).
-- Only full batches (max(parallels x 4, start energy <= 10%)); skip recipes without full stock.
-- Stall: report after 90 s without progress, reactor left as is.
-- Start: balancer   Stop: echo > /home/fusion/balancer.stop  (or Ctrl+C)
-- Stop keeps the queue in balancer.state and the next start resumes it (no hatch jams).
local component = require("component")
local computer = require("computer")
local fs = require("filesystem")
local ser = require("serialization")
local L = dofile("/home/fusion/fuslib.lua")

local DIR = "/home/fusion/"
local STOPFILE, STATEFILE = DIR .. "balancer.stop", DIR .. "balancer.state"
local MAX_LEVEL = 250000000   -- 250M L cap per plasma (player)
local STALL = 90
local AMORT = 0.10
local MINX = 4
local FEED_SLEEP = 0.05
local QMAX = 2

-- name, reactors, A, aPerRun, B, bPerRun, outPerRun, EU/t, ticks, start (M EU)
local RECIPES = {
  {"helium",    "23", "deuterium", 125, "tritium", 125, 125, 4096, 16, 40},
  {"helium",    "23", "deuterium", 125, "helium-3", 125, 125, 2048, 16, 60},
  {"boron",     "23", "plasma.helium", 144, "molten.lithium", 144, 144, 10240, 240, 50},
  {"oxygen",    "3",  "plasma.boron", 144, "molten.lithium", 144, 144, 49152, 240, 100},
  {"titanium",  "3",  "molten.aluminium", 144, "fluorine", 144, 144, 49152, 160, 100},
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
local REACTORS = {"mk3", "mk2"}

local function parallels(r, start)
  if r == "mk2" then return start < 160 and 128 or 64 end
  return start < 160 and 192 or (start < 320 and 128 or 64)
end
-- seconds per cycle (one run of all parallels): ticks / speed bonus / 20
-- speed (main-srv, GoodGenerator): MK2 x2 if start < 160M; MK3 x4 < 160M, x2 < 320M
local MIN_SEC = 10        -- every batch keeps the reactor busy at least this long
local function cycleSec(r, rc)
  local st = rc[10]
  local speed = (r == "mk2") and (st < 160 and 2 or 1) or (st < 160 and 4 or (st < 320 and 2 or 1))
  return rc[9] / speed / 20
end
local function minRuns(r, rc)
  local P = parallels(r, rc[10])
  return math.max(MINX * P, P * math.ceil(MIN_SEC / cycleSec(r, rc)))
end
local function batchRuns(r, rc)
  local P = parallels(r, rc[10])
  local need = math.ceil((1 - AMORT) / AMORT * rc[10] * 1e6 / (rc[8] * rc[9]))
  return math.max(minRuns(r, rc), math.ceil(need / P) * P)
end
local function recipeIndex(rc) for i, x in ipairs(RECIPES) do if x == rc then return i end end end

-- log with rotation: above 100 KB -> balancer.log.old (replaced), new log. Max ~200 KB on disk.
local LOGMAX = 100 * 1024
local logf = io.open(DIR .. "balancer.log", "a")
local logCount = 0
local function log(msg)
  local line = os.date("%H:%M:%S") .. " " .. msg
  logf:write(line, "\n"); logf:flush()
  logCount = logCount + 1
  if logCount % 50 == 0 and fs.size(DIR .. "balancer.log") > LOGMAX then
    logf:close()
    if fs.exists(DIR .. "balancer.log.old") then fs.remove(DIR .. "balancer.log.old") end
    fs.rename(DIR .. "balancer.log", DIR .. "balancer.log.old")
    logf = io.open(DIR .. "balancer.log", "a")
  end
end
local function px(a) return component.proxy(component.get(a)) end

-- state
local Q = {mk2 = {}, mk3 = {}}          -- batches: {ri, runs, la, lb, expect, fed, t0}
local cfgFor = {mk2 = nil, mk3 = nil}   -- recipe index the interface is configured for
local R = {}
for _, r in ipairs(REACTORS) do
  R[r] = {lastProg = computer.uptime(), stallLogged = false, lastBuf = -1, idleSince = nil,
          lastToggle = 0, toggles = 0}
end

local function saveState()
  local s = {mk2 = {}, mk3 = {}}
  for _, r in ipairs(REACTORS) do
    for _, b in ipairs(Q[r]) do
      s[r][#s[r] + 1] = {ri = b.ri, runs = b.runs, la = b.la, lb = b.lb, expect = b.expect, fed = b.fed, made = b.made or 0, qt = b.qt or 0, switch = b.switch, gateOk = b.gateOk}
    end
  end
  local f = io.open(STATEFILE, "w"); f:write(ser.serialize(s)); f:close()
end
local function loadState()
  if not fs.exists(STATEFILE) then return end
  local f = io.open(STATEFILE); local s = ser.unserialize(f:read("a")); f:close()
  if not s then return end
  for _, r in ipairs(REACTORS) do
    for _, b in ipairs(s[r] or {}) do
      b.t0 = computer.uptime()
      Q[r][#Q[r] + 1] = b
  -- fresh timers: the reactor was idle before, that is not a stall
  R[r].lastProg, R[r].inactiveSince, R[r].stallLogged = computer.uptime(), nil, false
      log(string.format("%s RESUME %s: left A %d B %d, fed=%s", r, RECIPES[b.ri][1], b.la, b.lb, tostring(b.fed)))
    end
  end
end

-- projected plasma levels and free stock
local function projection(fl)
  local proj, avail = {}, {}
  for k, v in pairs(fl) do avail[k] = v; proj[k] = v end
  for _, r in ipairs(REACTORS) do
    for _, b in ipairs(Q[r]) do
      local rc = RECIPES[b.ri]
      local p = "plasma." .. rc[1]
      proj[p] = (proj[p] or 0) + b.expect - (b.made or 0)
      avail[rc[3]] = (avail[rc[3]] or 0) - b.la
      avail[rc[5]] = (avail[rc[5]] or 0) - b.lb
      if proj[rc[3]] then proj[rc[3]] = proj[rc[3]] - b.la end
      if proj[rc[5]] then proj[rc[5]] = proj[rc[5]] - b.lb end
    end
  end
  return proj, avail
end

local lastSkipLog = {mk2 = -1e9, mk3 = -1e9}
-- Choice (player rules + main-srv code reading):
--  * a recipe switch (or a start from idle) pays the start energy -> switch batch = 10% rule
--  * repeating the reactor's current recipe without a gap is free -> repeat batch = parallels x4
--  * stay on the current recipe while its projected level <= lowest other + one switch batch of it
-- ALLOCATION (player model, 2026-10-01)
-- priority = projected level, lowest first (plasmas with a queued batch or at MAX are out)
-- RESERVED (#): stock taken for a recipe; for everyone else it is gone. Kept until scheduled.
-- DESIRED (!): one missing input per recipe; blocks lower-priority recipes from reserving that
--   fluid and from starting with it; incoming stock goes to the desirer first; when complete the
--   desire ends (it may then desire its other input). Stock reserved by others is untouched.
-- A recipe is schedulable when both inputs are fully reserved. Reserved batch size = the larger
-- of the reactors that can run it; when scheduled the reservation is released (the queued batch
-- then holds its inputs).
ALLOC = {}   -- plasma -> {ri, need = {fluid=L}, res = {fluid=L}, desire = fluid|nil}
local function inputsOf(rc) return rc[3], rc[5] end
local function needFor(rc)
  local best
  for _, rr in ipairs(REACTORS) do
    if rc[2]:find(rr == "mk2" and "2" or "3", 1, true) then
      local runs = batchRuns(rr, rc)
      if not best or runs > best then best = runs end
    end
  end
  return {[rc[3] ] = best * rc[4], [rc[5] ] = best * rc[6]}
end
local function openBatch(p)
  for _, rr in ipairs(REACTORS) do for _, qb in ipairs(Q[rr]) do if RECIPES[qb.ri][1] == p then return true end end end
  return false
end
local PRIO = {}   -- ordered plasma list (last allocation)

local function allocate(fl)
  local proj, avail = projection(fl)
  -- priority order
  local order = {}
  for _, p in ipairs(PLASMAS) do
    local lv = proj["plasma." .. p] or 0
    if (MAX_LEVEL and lv >= MAX_LEVEL) or openBatch(p) then ALLOC[p] = nil
    else order[#order + 1] = {p, lv} end
  end
  table.sort(order, function(a, b) return a[2] < b[2] end)
  PRIO = order
  -- recipe variant per plasma (helium has two): keep the chosen one; else the one missing least
  for _, e in ipairs(order) do
    local p = e[1]
    if not ALLOC[p] then
      local bestRi, bestMiss
      for i, rc in ipairs(RECIPES) do
        if rc[1] == p then
          local need = needFor(rc)
          local miss = 0
          for x, n in pairs(need) do miss = miss + math.max(0, n - (avail[x] or 0)) end
          if not bestMiss or miss < bestMiss then bestRi, bestMiss = i, miss end
        end
      end
      ALLOC[p] = {ri = bestRi, need = needFor(RECIPES[bestRi]), res = {}, desire = nil}
    end
  end
  -- free stock = ME - queued inputs - all reservations; if negative (stock dropped), cut the
  -- reservations of the lowest priorities first
  local free = {}
  for x, v in pairs(avail) do free[x] = v end
  for _, a in pairs(ALLOC) do for x, n in pairs(a.res) do free[x] = (free[x] or 0) - n end end
  for k = #order, 1, -1 do
    local a = ALLOC[order[k][1] ]
    for x, n in pairs(a.res) do
      if (free[x] or 0) < 0 then
        local cut = math.min(n, -free[x]); a.res[x] = n - cut; free[x] = free[x] + cut
      end
    end
  end
  -- walk priorities: reserve what is free unless a higher priority desires that fluid
  local desiredBy = {}   -- fluid -> plasma (highest priority desirer)
  for _, e in ipairs(order) do
    local p = e[1]
    local a = ALLOC[p]
    for x, n in pairs(a.need) do
      local missing = n - (a.res[x] or 0)
      if missing > 0 and (not desiredBy[x] or desiredBy[x] == p) and (free[x] or 0) > 0 then
        local take = math.min(missing, free[x])
        a.res[x] = (a.res[x] or 0) + take; free[x] = free[x] - take
      end
    end
    -- desire: complete -> clear; none -> desire the missing input with the larger shortfall,
    -- if no higher priority already desires it
    if a.desire and (a.res[a.desire] or 0) >= a.need[a.desire] then a.desire = nil end
    if not a.desire then
      local bx, bm
      for x, n in pairs(a.need) do
        local m = n - (a.res[x] or 0)
        if m > 0 and not desiredBy[x] and (not bm or m > bm) then bx, bm = x, m end
      end
      a.desire = bx
    end
    if a.desire and not desiredBy[a.desire] then desiredBy[a.desire] = p end
  end
  DESIRED = desiredBy
  FREE = free
end

local function ready(p)
  local a = ALLOC[p]
  if not a then return false end
  for x, n in pairs(a.need) do if (a.res[x] or 0) < n then return false end end
  return true
end

-- choose for reactor r: fully reserved plasmas by priority; repeat of the current recipe (x4)
-- only from free stock that nobody desires; stay on it while level <= best + one switch batch
local function choose(r, fl)
  allocate(fl)
  local tag = r == "mk2" and "2" or "3"
  local q = Q[r]
  local cur = (#q > 0) and q[#q].ri or nil
  local best, bestLevel
  for _, e in ipairs(PRIO) do
    local p, lv = e[1], e[2]
    local a = ALLOC[p]
    if a and ready(p) and RECIPES[a.ri][2]:find(tag, 1, true) then
      best, bestLevel = {ri = a.ri, runs = batchRuns(r, RECIPES[a.ri])}, lv
      break
    end
  end
  if cur then
    local rc = RECIPES[cur]
    local proj = projection(fl)
    local lv = proj["plasma." .. rc[1] ] or 0
    local runs = minRuns(r, rc)
    local okA = (FREE[rc[3] ] or 0) >= runs * rc[4] and not DESIRED[rc[3] ]
    local okB = (FREE[rc[5] ] or 0) >= runs * rc[6] and not DESIRED[rc[5] ]
    if okA and okB and (not MAX_LEVEL or lv < MAX_LEVEL) then
      local margin = batchRuns(r, rc) * rc[7]
      if not best or lv <= bestLevel + margin then
        return {ri = cur, runs = runs, repeat_ = true}, lv
      end
    end
  end
  if not best and computer.uptime() - lastSkipLog[r] > 600 then
    log(r .. " nothing to queue: no plasma with both inputs reserved")
    lastSkipLog[r] = computer.uptime()
  end
  return best, bestLevel
end

local function enqueue(r, fl)
  local pick, lvl = choose(r, fl)
  if not pick then return false end
  local rc = RECIPES[pick.ri]
  local b = {ri = pick.ri, runs = pick.runs, la = pick.runs * rc[4], lb = pick.runs * rc[6],
             expect = pick.runs * rc[7], fed = false, t0 = computer.uptime(), made = 0, qt = computer.uptime(),
             switch = not pick.repeat_}
  ALLOC[rc[1] ] = nil
  Q[r][#Q[r] + 1] = b
  R[r].lastProg, R[r].inactiveSince, R[r].stallLogged = computer.uptime(), nil, false
  log(string.format("%s QUEUE #%d %s%s: %d runs (%d L), A %s %d, B %s %d, projected level %d",
    r, #Q[r], rc[1], pick.repeat_ and " (repeat)" or " (switch)", b.runs, b.expect, rc[3], b.la, rc[5], b.lb, lvl))
  return true
end

local function feeding(r)
  for _, b in ipairs(Q[r]) do if not b.fed then return b end end
end

-- Feed model (2026-10-01): interface slot 0 set to ONE fluid -> fast pump fills the aux tank ->
-- transposer moves the needed amount aux -> NORTH (A) or SOUTH (B) in one call -> the rest goes
-- back aux -> interface. Chunks alternate A/B so both inputs arrive together.
-- Production tracking: per plasma, growth of the ME level + plasma we took out as input = made.
-- Credited FIFO (by queue time) to open batches of that plasma, both reactors.
local fedOut, lastLevel, pending = {}, nil, {}
local function trackProduction(fl)
  if not lastLevel then lastLevel = {}; for _, p in ipairs(PLASMAS) do lastLevel[p] = fl["plasma." .. p] or 0 end return end
  for _, p in ipairs(PLASMAS) do
    local now = fl["plasma." .. p] or 0
    pending[p] = (pending[p] or 0) + (now - lastLevel[p]) + (fedOut["plasma." .. p] or 0)
    lastLevel[p] = now
    fedOut["plasma." .. p] = 0
    if pending[p] > 0 then
      local open = {}
      for _, r in ipairs(REACTORS) do
        for _, b in ipairs(Q[r]) do if RECIPES[b.ri][1] == p and (b.made or 0) < b.expect then open[#open + 1] = b end end
      end
      table.sort(open, function(a, c) return (a.qt or 0) < (c.qt or 0) end)
      for _, b in ipairs(open) do
        if pending[p] <= 0 then break end
        local take = math.min(pending[p], b.expect - (b.made or 0))
        b.made = (b.made or 0) + take; pending[p] = pending[p] - take
      end
      if pending[p] > 0 then pending[p] = 0 end   -- unattributed (e.g. manual changes)
    end
  end
end

local CHUNK = 600000      -- L per fill
local FILL_WAIT = 3       -- s max per fill

local F = {mk2 = {phase = "idle"}, mk3 = {phase = "idle"}}

local function feedPass(r)
  local st = F[r]
  local cfg = L.R[r]
  local t, itf = px(cfg.tp), px(cfg.iface)
  local now = computer.uptime()
  local moved = 0
  if st.phase == "idle" then
    local b = feeding(r)
    if not b then return 0 end
    local rc = RECIPES[b.ri]
    -- recipe change: only when the previous batches are done AND the EU store is full
    -- a repeat that comes after the reactor already went idle is a fresh start: same gate
    if not b.switch and not b.gateOk and Q[r][1] == b and not px(cfg.gt).isMachineActive() then
      b.switch = true
    end
    if b.switch and not b.gateOk then
      if Q[r][1] ~= b then return 0 end
      local g = px(cfg.gt)
      local eu, mx = g.getEUStored(), g.getEUMaxStored()
      if eu < mx * 0.99 then return 0 end
      b.gateOk = true
      R[r].switchAt = now
      log(string.format("%s SWITCH to %s: previous done, EU full (%dM)", r, rc[1], eu // 1000000))
    end
    -- next fluid: the side that is behind (by share of its total), A first
    local useA
    if b.la > 0 and b.lb > 0 then
      useA = (b.la / (b.runs * rc[4])) >= (b.lb / (b.runs * rc[6]))
    else useA = b.la > 0 end
    st.b, st.useA = b, useA
    st.fluid = useA and rc[3] or rc[5]
    st.target = math.min(useA and b.la or b.lb, CHUNK)
    itf.setFluidInterfaceConfiguration(0, L.getdb().address, L.dbslot(st.fluid))
    st.phase, st.t0 = "fill", now
  elseif st.phase == "fill" then
    local x = t.getFluidInTank(cfg.aux)[1]
    if (x.name == st.fluid and x.amount >= st.target) or now - st.t0 >= FILL_WAIT then
      itf.setFluidInterfaceConfiguration(0)
      if x.name == st.fluid and x.amount > 0 then
        local _, m = t.transferFluid(cfg.aux, st.useA and 2 or 3, math.min(x.amount, st.target))
        m = tonumber(m) or 0
        if st.useA then st.b.la = st.b.la - m else st.b.lb = st.b.lb - m end
        fedOut[st.fluid] = (fedOut[st.fluid] or 0) + m
        moved = m
      end
      st.phase, st.t0 = "return", now
    end
  elseif st.phase == "return" then
    local x = t.getFluidInTank(cfg.aux)[1]
    if x.amount > 0 then
      t.transferFluid(cfg.aux, 4, x.amount); st.t0 = now
    elseif now - st.t0 >= 0.5 then           -- aux stayed empty: pump is done
      st.phase = "idle"
      local b = st.b
      if b.la <= 0 and b.lb <= 0 and not b.fed then
        b.la, b.lb, b.fed = 0, 0, true
        log(string.format("%s FED %s (%d L expected), %.0f s", r, RECIPES[b.ri][1], b.expect, now - b.t0))
      end
    end
  end
  return moved
end

local problems = {}
local function problem(msg) problems[#problems + 1] = os.date("%H:%M ") .. msg; if #problems > 4 then table.remove(problems, 1) end end

-- slow checks (about once per second): queue, done, restart, stall
local function manage(r, fl)
  local q, st = Q[r], R[r]
  local now = computer.uptime()
  local t, g = px(L.R[r].tp), px(L.R[r].gt)
  local buf = t.getFluidInTank(2)[1].amount + t.getFluidInTank(3)[1].amount
  local active = g.isMachineActive()
  local eu, mx = g.getEUStored(), g.getEUMaxStored()
  if st.lastEU and st.lastEU - eu > mx * 0.15 then
    local atSwitch = (st.switchAt and now - st.switchAt <= 15) or st.wasIdle
    local b = q[1]
    local what = b and RECIPES[b.ri][1] or "nothing queued"
    log(string.format("%s EU SPIKE -%dM (now %dM of %dM) during %s%s", r, (st.lastEU - eu) // 1000000,
      eu // 1000000, mx // 1000000, what,
      st.wasIdle and " [start from idle (gap): expected]" or (atSwitch and " [recipe change: expected]" or " [NOT at a start]")))
    if not atSwitch then problem(r .. " EU spike -" .. ((st.lastEU - eu) // 1000000) .. "M on " .. what) end
  end
  st.lastEU = eu
  st.wasIdle = not active
  if active or buf ~= st.lastBuf then st.lastProg, st.stallLogged = now, false end
  if active then st.inactiveSince = nil else st.inactiveSince = st.inactiveSince or now end
  st.lastBuf = buf
  -- batch 1 done: batch 2 fully fed and its fluids left the buffers
  for k = #q, 1, -1 do
    local b = q[k]
    if b.fed and (b.made or 0) >= b.expect then
      log(string.format("%s DONE %s: made %d of %d L, %.0f s", r, RECIPES[b.ri][1], b.made, b.expect, now - b.t0))
      table.remove(q, k)
    end
  end
  -- last batch done: all fed, buffers empty, reactor idle 15 s
  if #q >= 1 and q[1].fed and buf == 0 and not active then
    st.idleSince = st.idleSince or now
    if now - st.idleSince >= 15 then
      log(string.format("%s DONE %s (idle 15 s, made %d of %d L), %.0f s", r, RECIPES[q[1].ri][1], q[1].made or 0, q[1].expect, now - q[1].t0))
      table.remove(q, 1)
    end
  else
    st.idleSince = nil
  end
  -- queue more: keep 2 batches (a new one only after the feeding one is fully fed)
  if #q < QMAX and not feeding(r) then enqueue(r, fl) end
  -- restart: inactive 5 s with EU full and work queued (MK2 sometimes stops with inputs present;
  -- an off/on starts it again). Buffers moving does not count as working.
  -- Only when inputs are really waiting (buffers not empty or batch still feeding) for 30 s:
  -- a finished batch or a start waiting for its first inputs is normal idle, not a fault.
  local fb = feeding(r)
  local gated = fb and fb.switch and not fb.gateOk
  local waiting = buf > 0 or (fb ~= nil and not gated)
  if #q > 0 and waiting and st.inactiveSince and now - st.inactiveSince >= 30
     and g.getEUStored() >= g.getEUMaxStored() * 0.99 and now - st.lastToggle >= 30 then
    g.setWorkAllowed(false); os.sleep(0.2); g.setWorkAllowed(true)
    st.lastToggle, st.toggles = now, st.toggles + 1
    problem(r .. " stuck 30 s with inputs, restarted")
    log(r .. " stuck 30 s with inputs waiting and EU full: off/on")
  end
  if not g.isWorkAllowed() then
    -- the reactor disables itself when its EU store runs empty mid-run (that run is lost)
    g.setWorkAllowed(true)
    problem(r .. " ran out of EU (run lost), re-enabled")
    log(r .. " was disabled (EU store empty mid-run, that run's inputs/output lost): re-enabled")
  end
  if #q > 0 and not (gated and Q[r][1] == fb) and now - st.lastProg >= STALL and not st.stallLogged then
    local b = q[1]
    log(string.format("%s STALL: no progress %d s on %s (left A %d B %d, buffers %d, EU %d), reactor left on",
      r, STALL, RECIPES[b.ri][1], b.la, b.lb, buf, g.getEUStored()))
    st.stallLogged = true
    problem(r .. " stall " .. RECIPES[b.ri][1])
  end
end

-- data for the screen (balview.lua): queues, levels, needs, problems; also the heartbeat
local function writeView(fl)
  local v = {t = computer.uptime(), q = {}, levels = {}, needs = {}, problems = problems,
             restarts = {mk2 = R.mk2.toggles, mk3 = R.mk3.toggles}}
  for _, r in ipairs(REACTORS) do
    v.q[r] = {}
    for _, b in ipairs(Q[r]) do
      v.q[r][#v.q[r] + 1] = {name = RECIPES[b.ri][1], expect = b.expect, made = b.made or 0, fed = b.fed, la = b.la, lb = b.lb,
        a = RECIPES[b.ri][3], b = RECIPES[b.ri][5]}
    end
  end
  local proj, avail = projection(fl)
  for _, p in ipairs(PLASMAS) do v.levels[#v.levels + 1] = {p, fl["plasma." .. p] or 0} end
  -- needs: per plasma, the cheapest switch batch that is short, and by how much
  for _, p in ipairs(PLASMAS) do
    local best
    for _, rc in ipairs(RECIPES) do
      if rc[1] == p then
        for _, r in ipairs(REACTORS) do
          if rc[2]:find(r == "mk2" and "2" or "3", 1, true) then
            local runs = batchRuns(r, rc)
            local missA = math.max(0, runs * rc[4] - (avail[rc[3] ] or 0))
            local missB = math.max(0, runs * rc[6] - (avail[rc[5] ] or 0))
            local miss = {}
            if missA > 0 then miss[#miss + 1] = {rc[3], missA} end
            if missB > 0 then miss[#miss + 1] = {rc[5], missB} end
            local cost = missA + missB
            if not best or cost < best.cost then best = {cost = cost, miss = miss} end
          end
        end
      end
    end
    if best and best.cost > 0 and (fl["plasma." .. p] or 0) < (MAX_LEVEL or math.huge) then
      v.needs[#v.needs + 1] = {p, best.miss}
    end
  end
  v.alloc = {}
  for _, e in ipairs(PRIO) do
    local al = ALLOC[e[1] ]
    if al then
      local ins = {}
      for x, n in pairs(al.need) do ins[#ins + 1] = {x, n, al.res[x] or 0, al.desire == x} end
      table.sort(ins, function(c, d) return c[1] < d[1] end)
      v.alloc[#v.alloc + 1] = {e[1], ins}
    end
  end
  local f = io.open(DIR .. "balancer.view", "w"); f:write(ser.serialize(v)); f:close()
end

local function writeStatus(fl)
  local f = io.open(DIR .. "balancer.status", "w")
  f:write("# balancer v2 " .. os.date() .. "\n")
  for _, r in ipairs(REACTORS) do
    local parts = {}
    for i, b in ipairs(Q[r]) do
      parts[#parts + 1] = string.format("#%d %s %dL %s", i, RECIPES[b.ri][1], b.expect,
        b.fed and "fed" or string.format("feeding (left A %d B %d)", b.la, b.lb))
    end
    f:write(r .. ": " .. (#parts > 0 and table.concat(parts, "; ") or "idle") ..
      " | restarts " .. R[r].toggles .. "\n")
  end
  for _, p in ipairs(PLASMAS) do f:write(string.format("%-10s %d\n", p, fl["plasma." .. p] or 0)) end
  f:close()
end

-- dry run
local args = {...}
if args[1] == "plan" then
  local fl = L.fluids()
  loadState()
  for _, r in ipairs(REACTORS) do
    if #Q[r] < QMAX and not feeding(r) then
      local pick, lvl = choose(r, fl)
      print(r .. " would queue: " .. (pick and (RECIPES[pick.ri][1] .. " " .. pick.runs .. " runs, projected " .. lvl) or "nothing"))
      if pick then local rc = RECIPES[pick.ri]
        Q[r][#Q[r] + 1] = {ri = pick.ri, runs = pick.runs, la = pick.runs * rc[4], lb = pick.runs * rc[6], expect = pick.runs * rc[7], fed = false} end
    else print(r .. " busy (resumed queue)") end
  end
  logf:close()
  return
end

local viewFn = loadfile(DIR .. "balview.lua")
function drawView() viewFn("once") end

-- main
if fs.exists(STOPFILE) then fs.remove(STOPFILE) end
log("balancer v2 started")
do
  local ok, ch = pcall(L.autodetect)
  if not ok then log("autodetect failed: " .. tostring(ch))
  elseif #ch > 0 then log("addresses changed, found: " .. table.concat(ch, ", ")) end
end
loadState()
for _, r in ipairs(REACTORS) do
  L.clear(r)
  local t = px(L.R[r].tp)
  local x = t.getFluidInTank(L.R[r].aux)[1]
  if x.amount > 0 then t.transferFluid(L.R[r].aux, 4, x.amount) end
  L.power(r, true)
end
local fl = L.fluids()
local lastSlow, lastStatus = 0, 0
local ok, err = pcall(function()
  while not fs.exists(STOPFILE) do
    for _, r in ipairs(REACTORS) do
      local m = feedPass(r)
      if m > 0 then R[r].lastProg, R[r].stallLogged = computer.uptime(), false end
    end
    local now = computer.uptime()
    if now - lastSlow >= 1 then
      fl = L.fluids()
      trackProduction(fl)
      for _, r in ipairs(REACTORS) do manage(r, fl) end
      lastSlow = now
    end
    if now - lastStatus >= 3 then
      writeStatus(fl); writeView(fl); saveState(); lastStatus = now
      if not fs.exists(DIR .. "display.off") then pcall(drawView) end
    end
    os.sleep(FEED_SLEEP)
  end
end)
saveState()
for _, r in ipairs(REACTORS) do
  pcall(L.power, r, false); pcall(L.clear, r)
  pcall(function()   -- aux tank back to the ME
    local t = px(L.R[r].tp)
    for _ = 1, 5 do
      local x = t.getFluidInTank(L.R[r].aux)[1]
      if x.amount == 0 then break end
      t.transferFluid(L.R[r].aux, 4, x.amount); os.sleep(0.3)
    end
  end)
end
for _, r in ipairs(REACTORS) do
  for _, b in ipairs(Q[r]) do
    log(string.format("%s STOPPED with %s queued: left A %d B %d, fed=%s (resumes on next start)",
      r, RECIPES[b.ri][1], b.la, b.lb, tostring(b.fed)))
  end
end
fs.remove(DIR .. "balancer.view")  -- so "balancer" knows it is not running
log("balancer v2 stopped" .. (ok and "" or (": " .. tostring(err))))
logf:close()
