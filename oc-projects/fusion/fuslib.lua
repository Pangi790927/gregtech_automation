-- fuslib.lua: helpers to feed and run the fusion reactors (tested 2026-10-01)
local component = require("component")
local L = {}
L.R = {
  -- interface -> fast pump -> aux tank on the transposer;
  -- transposer: side 4 = interface (return rest), 2 = NORTH, 3 = SOUTH (pipes to the hatches)
  mk2 = {iface = "3ae3a8df", tp = "68b0376b", aux = 1, gt = "7be89c69"},
  mk3 = {iface = "7aae4e0e", tp = "1b039114", aux = 0, gt = "7510f90f"},
}

-- Addresses change when adapters are re-placed. If a saved address is missing:
-- reactors are found by name, interfaces by a short pump test (deuterium into slot 0,
-- see which aux tank fills, then everything goes back). Returns a list of changes.
function L.autodetect()
  local changes = {}
  local function present(a) return a and component.get(a) ~= nil end
  for r, name in pairs({mk2 = "largefusioncomputer2", mk3 = "largefusioncomputer3"}) do
    if not present(L.R[r].gt) then
      for a in component.list("gt_machine") do
        if component.invoke(a, "getName") == name then L.R[r].gt = a:sub(1, 8); changes[#changes + 1] = r .. " gt " .. a:sub(1, 8) end
      end
    end
  end
  if not (present(L.R.mk2.iface) and present(L.R.mk3.iface)) then
    local dbx = component.proxy(component.list("database")())
    dbx.set(81, "IC2:itemFluidCell", 0, '{Fluid:{FluidName:"deuterium",Amount:1000}}')
    for a in component.list("me_interface") do
      local itf = component.proxy(a)
      itf.setFluidInterfaceConfiguration(0, dbx.address, 81)
      os.sleep(1.5)
      local hit
      for _, r in ipairs({"mk2", "mk3"}) do
        local t = component.proxy(component.get(L.R[r].tp))
        if t.getFluidInTank(L.R[r].aux)[1].amount > 0 then hit = r end
      end
      itf.setFluidInterfaceConfiguration(0)
      for _ = 1, 4 do
        os.sleep(0.4)
        for _, r in ipairs({"mk2", "mk3"}) do
          local t = component.proxy(component.get(L.R[r].tp))
          local x = t.getFluidInTank(L.R[r].aux)[1].amount
          if x > 0 then t.transferFluid(L.R[r].aux, 4, x) end
        end
      end
      if hit then L.R[hit].iface = a:sub(1, 8); changes[#changes + 1] = hit .. " iface " .. a:sub(1, 8) end
    end
  end
  return changes
end
-- database looked up when used (at boot it can appear late / be re-registered)
local dbProxy
local function getdb()
  if not dbProxy or not component.get(dbProxy.address) then
    local a = component.list("database")()
    if not a then error("no database component (upgrade in an adapter)") end
    dbProxy = component.proxy(a)
  end
  return dbProxy
end
L.getdb = getdb
local function px(a) return component.proxy(component.get(a)) end

-- fluid name -> database slot (creates IC2 universal cell entries)
L.slots = {}
local nextSlot = 30
function L.dbslot(name)
  if L.slots[name] then return L.slots[name] end
  local s = nextSlot; nextSlot = nextSlot + 1
  getdb().set(s, "IC2:itemFluidCell", 0, '{Fluid:{FluidName:"' .. name .. '",Amount:1000}}')
  L.slots[name] = s
  return s
end

-- set interface config: list of fluid names (max 6); returns labels read back
function L.config(r, names)
  local p = px(L.R[r].iface)
  local out = {}
  for i = 0, 5 do
    if names[i + 1] then
      p.setFluidInterfaceConfiguration(i, getdb().address, L.dbslot(names[i + 1]))
      local c = p.getFluidInterfaceConfiguration(i)
      out[#out + 1] = c and c.label or ("FAILED " .. names[i + 1])
    else
      p.setFluidInterfaceConfiguration(i)
    end
  end
  return out
end

function L.clear(r)
  local p = px(L.R[r].iface)
  for i = 0, 5 do p.setFluidInterfaceConfiguration(i) end
end

-- move amt of the fluid in interface tank `tank` (0-based) into empty N/S buffers
function L.feed(r, tank, amt)
  local t = px(L.R[r].tp)
  local left, tries = amt, 0
  while left > 0 and tries < 120 do
    for _, side in ipairs({2, 3}) do
      if left > 0 and t.getFluidInTank(side)[1].amount == 0 then
        local ok, n = t.transferFluid(4, side, math.min(left, 16000), tank)
        if ok and n then left = left - n end
      end
    end
    if left > 0 then os.sleep(1); tries = tries + 1 end
  end
  return amt - left
end

function L.buffersEmpty(r)
  local t = px(L.R[r].tp)
  return t.getFluidInTank(2)[1].amount == 0 and t.getFluidInTank(3)[1].amount == 0
end

function L.fluids()
  local o = {}
  for _, v in ipairs(px(L.R.mk3.iface).getFluidsInNetwork()) do o[v.name or v.label] = v.amount end
  return o
end

function L.power(r, on) px(L.R[r].gt).setWorkAllowed(on) end

-- plan: { mk3 = { {{"A",amt},{"B",amt}}, ... }, mk2 = {...} }
-- Each recipe: all of A -> NORTH, all of B -> SOUTH, in chunks (interface holds 16000/slot),
-- next recipe only when both are fully fed and buffers drained. Stall guard: no progress
-- for `stall` loop steps -> that reactor off. Reactors always off + cleared at the end.
-- logfile (optional): per step "t reactor EU parallel N S" for energy measurement.
function L.run(plan, maxSteps, stall, logfile)
  stall = stall or 30
  local log, idx = {}, {}
  local lf = logfile and io.open(logfile, "w")
  for r, recipes in pairs(plan) do
    local names, seen = {}, {}
    for _, rc in ipairs(recipes) do for _, e in ipairs(rc) do
      if not seen[e[1] ] then names[#names + 1] = e[1]; seen[e[1] ] = #names - 1 end
    end end
    idx[r] = seen
    log[#log + 1] = r .. " config: " .. table.concat(L.config(r, names), ", ")
  end
  os.sleep(3)
  local before = L.fluids()
  local st = {}
  for r in pairs(plan) do st[r] = {i = 0, phase = "next"} end
  local step = 0
  local ok, err = pcall(function()
    for r in pairs(plan) do L.power(r, true) end
    local active = true
    while active and step < maxSteps do
      active = false
      for r, recipes in pairs(plan) do
        local s, t = st[r], px(L.R[r].tp)
        if s.phase == "next" then
          s.i = s.i + 1
          local rc = recipes[s.i]
          if rc then
            s.rc, s.la, s.lb, s.phase, s.last, s.since = rc, rc[1][2], rc[2][2], "feed", -1, step
            log[#log + 1] = string.format("%s #%d %s %d N / %s %d S", r, s.i, rc[1][1], rc[1][2], rc[2][1], rc[2][2])
          else s.phase = "done" end
        end
        if s.phase == "feed" then
          if s.la > 0 then local _, n = t.transferFluid(4, 2, s.la, idx[r][s.rc[1][1] ]); s.la = s.la - (n or 0) end
          if s.lb > 0 then local _, n = t.transferFluid(4, 3, s.lb, idx[r][s.rc[2][1] ]); s.lb = s.lb - (n or 0) end
          local nb, sb = t.getFluidInTank(2)[1].amount, t.getFluidInTank(3)[1].amount
          local prog = s.la + s.lb + nb + sb
          if prog == 0 then s.phase = "next"
          elseif prog ~= s.last then s.last, s.since = prog, step
          elseif step - s.since >= stall then
            log[#log + 1] = string.format("%s STALL: left A %d B %d, buffers N %d S %d; reactor off", r, s.la, s.lb, nb, sb)
            L.power(r, false); s.phase = "done"
          end
        end
        if lf then
          local g = px(L.R[r].gt)
          local par = "?"
          for _, line in ipairs(g.getSensorInformation() or {}) do
            local v = line:gsub("§.", ""):match("Running Parallel: ([%d,]+)") if v then par = v end
          end
          lf:write(string.format("%d %s EU=%d par=%s active=%s N=%d S=%d\n", step, r, g.getEUStored(), par,
            tostring(g.isMachineActive()), t.getFluidInTank(2)[1].amount, t.getFluidInTank(3)[1].amount))
        end
        if s.phase ~= "done" then active = true end
      end
      os.sleep(1); step = step + 1
    end
    local last, stable = nil, 0
    while step < maxSteps + 60 do
      os.sleep(2); step = step + 2
      local now, parts = L.fluids(), {}
      for k, v in pairs(now) do
        if v ~= (before[k] or 0) and tostring(k):find("plasma") then
          parts[#parts + 1] = k .. " " .. string.format("%+d", v - (before[k] or 0))
        end
      end
      table.sort(parts)
      local line = table.concat(parts, ", ")
      if line == last then stable = stable + 1 else stable = 0 end
      last = line
      if stable >= 4 then break end
    end
    log[#log + 1] = "plasma change: " .. tostring(last)
  end)
  for r in pairs(plan) do L.power(r, false); L.clear(r) end
  if lf then lf:close() end
  if not ok then log[#log + 1] = "ERROR: " .. tostring(err) end
  return table.concat(log, "\n")
end

return L
