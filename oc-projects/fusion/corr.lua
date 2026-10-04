-- corr.lua: correlate the last two snaps (snap.lua).
-- Prints block changes (geodiff) and component changes, and pairs them
-- when there is exactly one block change and one component change.
local dir = "/home/fusion/"

local function load(p, key)
  local s = {}
  for l in io.lines(p) do
    if l ~= "" and l:sub(1, 1) ~= "#" then s[key and l:match("^(%S+)") or l] = l end
  end
  return s
end
local function diff(a, b)
  local gone, new = {}, {}
  for k, v in pairs(a) do if not b[k] then gone[#gone + 1] = v end end
  for k, v in pairs(b) do if not a[k] then new[#new + 1] = v end end
  table.sort(gone); table.sort(new)
  return gone, new
end

local gg, gn = diff(load(dir .. "geo_scan.prev.txt"), load(dir .. "geo_scan.txt"))
local cg, cn = diff(load(dir .. "comp_snapshot.prev.txt", true), load(dir .. "comp_snapshot.txt", true))

for _, v in ipairs(gg) do print("- block gone " .. v) end
for _, v in ipairs(gn) do print("+ block new  " .. v) end
for _, v in ipairs(cg) do print("- comp gone  " .. v) end
for _, v in ipairs(cn) do print("+ comp new   " .. v) end
if #gg + #gn + #cg + #cn == 0 then print("no changes") end

local b = (#gn == 1 and #gg == 0) and gn[1] or ((#gg == 1 and #gn == 0) and gg[1])
local c = (#cn == 1 and #cg == 0) and cn[1] or ((#cg == 1 and #cn == 0) and cg[1])
if b and c then
  print("PAIR: " .. c:match("^(%S+)") .. " at " .. b .. " (x=E y=UP z=S, rel. geolyzer)")
elseif (#gg + #gn) > 0 and (#cg + #cn) > 0 then
  print("several changes: pair by hand")
end
