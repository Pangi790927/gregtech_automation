-- geoscan.lua: scan solid blocks around the geolyzer, one "x y z" per line.
-- Coords are relative to the geolyzer (x=east, y=up, z=south).
-- Air reads exactly 0; hardness is noisy, so only solid/air is recorded.
-- Keeps geo_scan.txt (latest) and geo_scan.prev.txt (previous) for diff.
-- Throttled: scans drain ~12 energy each, so it waits when battery is low.
local component = require("component")
local computer = require("computer")
local fs = require("filesystem")
local g = component.geolyzer
local R = tonumber((...)) or 16
local Y0, H = -16, 32
local dir = "/home/fusion/"
local cur, prev = dir .. "geo_scan.txt", dir .. "geo_scan.prev.txt"

local function waitPower()
  if computer.energy() < 800 then
    while computer.energy() < computer.maxEnergy() * 0.9 do os.sleep(1) end
  end
end

local lines, n = {}, 0
for x = -R, R, 2 do
  for z = -R, R do
    waitPower()
    local w = (x + 1 <= R) and 2 or 1
    local c = g.scan(x, z, Y0, w, 1, H)
    -- index order: x fastest, then z, then y
    for yi = 0, H - 1 do
      for xi = 0, w - 1 do
        local v = c[yi * w + xi + 1]
        if v and v ~= 0 then
          n = n + 1
          lines[n] = string.format("%d %d %d", x + xi, Y0 + yi, z)
        end
      end
    end
  end
end
table.sort(lines)

if fs.exists(cur) then fs.remove(prev); fs.rename(cur, prev) end
local f = io.open(cur, "w")
f:write("# geoscan R=" .. R .. " y=" .. Y0 .. ".." .. (Y0 + H - 1) ..
  " time=" .. os.date() .. " solid=" .. n .. "\n")
f:write(table.concat(lines, "\n"), "\n")
f:close()
print("solid blocks: " .. n .. " -> " .. cur)
