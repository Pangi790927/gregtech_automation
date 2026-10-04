-- snap.lua: baseline for correlation. Runs geoscan (rotates geo_scan*.txt)
-- and snapshots components (rotates comp_snapshot*.txt), same moment.
-- Usage: snap [R]   then after a world change: snap again, then lua corr.lua
local component = require("component")
local fs = require("filesystem")
local dir = "/home/fusion/"
local R = (...) or "16"

-- components first (fast), then geo scan
local cur, prev = dir .. "comp_snapshot.txt", dir .. "comp_snapshot.prev.txt"
local t = {}
for a, n in component.list() do
  local extra = ""
  if n == "transposer" then
    local p = component.proxy(a)
    local s = {}
    for side = 0, 5 do
      local ok, nm = pcall(p.getInventoryName, side)
      local tk = p.getTankCount and select(2, pcall(p.getTankCount, side)) or 0
      s[#s + 1] = side .. "=" .. tostring(ok and nm or "-") .. "/t" .. tostring(tk)
    end
    extra = " " .. table.concat(s, ",")
  elseif n == "gt_machine" then
    local ok, nm = pcall(component.invoke, a, "getName")
    extra = " " .. tostring(ok and nm or "?")
  end
  t[#t + 1] = a .. " " .. n .. extra
end
table.sort(t)
if fs.exists(cur) then fs.remove(prev); fs.rename(cur, prev) end
local f = io.open(cur, "w")
f:write("# components " .. os.date() .. "\n", table.concat(t, "\n"), "\n")
f:close()
print("components: " .. #t .. " -> " .. cur)

loadfile(dir .. "geoscan.lua")(R)
