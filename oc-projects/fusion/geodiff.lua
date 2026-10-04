-- geodiff.lua: compare two geoscan files (default: prev vs latest).
-- Usage: geodiff [old] [new]
-- Prints "- gone x y z" and "+ new x y z" (coords relative to geolyzer).
local args = {...}
local dir = "/home/fusion/"
local a_path = args[1] or dir .. "geo_scan.prev.txt"
local b_path = args[2] or dir .. "geo_scan.txt"

local function load(p)
  local s = {}
  for l in io.lines(p) do
    if l ~= "" and l:sub(1, 1) ~= "#" then s[l] = true end
  end
  return s
end

local a, b = load(a_path), load(b_path)
local out = {}
for k in pairs(a) do if not b[k] then out[#out + 1] = "- gone " .. k end end
for k in pairs(b) do if not a[k] then out[#out + 1] = "+ new " .. k end end
table.sort(out)
if #out == 0 then print("no changes") else print(table.concat(out, "\n")) end
