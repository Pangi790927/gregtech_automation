-- A plan file against the scan (SCAN, scan_box.lua): what of it is gone (a block planned,
-- hardness 0 now), by block; what stands where the plan has air. PLAN: the plan file (a global,
-- e.g. "data/house.txt"). PLAN_GONE keeps the gone cells, k -> {name, meta}. A cell read solid
-- counts as there, whatever block it is: the geolyzer does not tell kinds apart.
local plan = {}
for line in io.lines(PLAN) do
    local x, y, z, name, meta = line:match("^b (-?%d+) (-?%d+) (-?%d+) (%S+) (%d+)")
    if x then plan[x .. "," .. y .. "," .. z] = {name, tonumber(meta)} end
end
local gone, kept, stands, noscan = {}, 0, 0, 0
PLAN_GONE = {}
for k, b in pairs(plan) do
    local h = SCAN[k]
    if h == nil then
        noscan = noscan + 1
    elseif b[1] ~= "minecraft:air" then
        if h == 0 then
            gone[b[1]] = (gone[b[1]] or 0) + 1
            PLAN_GONE[k] = b
        else
            kept = kept + 1
        end
    elseif h > 0 then
        stands = stands + 1
    end
end
local t, total = {}, 0
for name, n in pairs(gone) do t[#t + 1] = ("%4d %s"):format(n, name); total = total + n end
table.sort(t, function(a, b) return a > b end)
return ("gone %d, still there %d, planned air but a block %d, not scanned %d\n%s"):format(
        total, kept, stands, noscan, table.concat(t, "\n"))
