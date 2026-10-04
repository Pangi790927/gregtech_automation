-- balview.lua: live screen for the headless balancer (reads /home/fusion/balancer.view).
-- Any key: leave (the balancer keeps running).
local component = require("component")
local computer = require("computer")
local event = require("event")
local term = require("term")
local ser = require("serialization")
local gpu = component.gpu
local W, H = gpu.getResolution()
local color = gpu.getDepth() > 1
local C = {title = 0x00B6FF, ok = 0x33DB00, warn = 0xFFDB00, bad = 0xFF4924, dim = 0x999999, txt = 0xFFFFFF}

local function fmt(n)
  n = math.floor(n or 0)
  if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
  if n >= 1e4 then return string.format("%.0fk", n / 1e3) end
  return tostring(n)
end
local function short(name) return (name:gsub("^molten%.", ""):gsub("^plasma%.", "pl.")) end

local y
local function put(x, text, col)
  if color then gpu.setForeground(col or C.txt) end
  gpu.set(x, y, text:sub(1, W - x + 1))
end
local function line(text, col) put(1, text, col); y = y + 1 end

local function draw()
  W, H = gpu.getResolution()
  local f = io.open("/home/fusion/balancer.view")
  local v = f and ser.unserialize(f:read("a")); if f then f:close() end
  gpu.setBackground(0x000000); gpu.fill(1, 1, W, H, " ")
  y = 1
  local age = v and (computer.uptime() - v.t) or math.huge
  local state = (not v) and "NO DATA" or (age > 30 and "NOT RUNNING (last data " .. math.floor(age) .. " s old)" or "running")
  local clock = os.date("%H:%M:%S")
  local title = ("FUSION BALANCER  " .. state .. "   (any key: leave)"):sub(1, W - #clock - 2)
  put(1, title, (state == "running") and C.title or C.bad)
  put(W - #clock + 1, clock, C.dim)
  y = y + 1
  if not v then return end
  y = y + 1
  -- queues
  for _, r in ipairs({"mk3", "mk2"}) do
    local parts = {}
    for i, b in ipairs(v.q[r] or {}) do
      parts[#parts + 1] = string.format("%d) %s %s/%sL %s", i, b.name, fmt(b.made or 0), fmt(b.expect),
        b.fed and "fed" or ("feeding " .. fmt(b.la) .. "/" .. fmt(b.lb)))
    end
    line(string.upper(r) .. ": " .. (#parts > 0 and table.concat(parts, "  ") or "idle") ..
      "   restarts " .. (v.restarts and v.restarts[r] or 0), #parts > 0 and C.ok or C.warn)
  end
  y = y + 1
  -- levels, lowest first, two columns
  local lv = {}
  for _, e in ipairs(v.levels) do lv[#lv + 1] = e end
  table.sort(lv, function(a, b) return a[2] < b[2] end)
  line("PLASMA LEVELS (lowest first)", C.title)
  local top = y
  for i, e in ipairs(lv) do
    local col = (i <= 4) and C.warn or C.txt
    local x = (i <= 8) and 1 or 41
    y = top + ((i - 1) % 8)
    put(x, string.format("%-10s %9s", e[1], fmt(e[2])), col)
  end
  y = top + 8 + 1
  -- allocation: priority order; per input  # = reserved in full, ! = desired (+missing),
  -- otherwise reserved/needed
  line("PRIORITY (# reserved, ! desired +missing)", C.title)
  local top2 = y
  local rows = math.max(1, math.min(8, H - top2))
  local al = v.alloc or {}
  for k, e in ipairs(al) do
    if k > rows * 2 then break end
    local parts, full = {}, true
    for _, x in ipairs(e[2]) do
      local name, need, res, des = short(x[1]):sub(1, 7), x[2], x[3], x[4]
      if res >= need then parts[#parts + 1] = name .. "#"
      elseif des then parts[#parts + 1] = name .. "!+" .. fmt(need - res); full = false
      else parts[#parts + 1] = name .. " " .. fmt(res) .. "/" .. fmt(need); full = false end
    end
    y = top2 + ((k - 1) % rows)
    put((k <= rows) and 1 or 41, string.format("%-9s%s", e[1]:sub(1, 8), table.concat(parts, " ")):sub(1, 39),
      full and C.ok or C.warn)
  end
  if #al == 0 then y = top2; put(1, " nothing waiting", C.ok) end
  y = top2 + rows
  -- problems
  y = H
  if v.problems and #v.problems > 0 then
    local p = v.problems
    local last = {}
    for k = math.max(1, #p - 1), #p do last[#last + 1] = p[k] end
    local txt = "LAST: " .. table.concat(last, " / ")
    if #txt > W then txt = txt:sub(1, W - 3) .. "..." end
    line(txt, C.bad)
  end
end

if (...) == "once" then draw(); return end

local ok, err = pcall(function()
  while true do
    draw()
    local e = event.pull(3, "key_down")
    if e then break end
  end
end)
if color then gpu.setForeground(0xFFFFFF) end
term.clear()
if not ok and err ~= "interrupted" then print("view error: " .. tostring(err)) end
