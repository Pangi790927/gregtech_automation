-- The scan (SCAN, scan_box.lua) into the map where it differs from it: read 0 -> air; over 50 ->
-- water; solid where the map has air -> the planned block if PLAN names one there (the user put
-- it in, or the crew), else left as it was (its kind is not known). Written to data/world.txt
-- (world coordinates, as the crew writes it), the pathfinder's grid and the copies' world. The
-- cells robots stand in are skipped: a robot is solid to the geolyzer. PLAN: a plan file, a
-- global (e.g. "data/house.txt"). Keep a copy of data/world.txt first: it is appended to.
local vc = require("virt_composer")
local w, a = require("copy").world(), require("view").anchor
local base = require("packets").have
local plan = {}
for line in io.lines(PLAN) do
    local x, y, z, name, meta = line:match("^b (-?%d+) (-?%d+) (-?%d+) (%S+) (%d+)")
    if x then plan[x .. "," .. y .. "," .. z] = {name, tonumber(meta)} end
end
local robo = {}
for _, r in ipairs(require("robots").order) do
    if r.sf then robo[table.concat(r.sf.pos, ",")] = true end
end
local f = assert(io.open("data/world.txt", "a"))
local n = {air = 0, water = 0, planned = 0}
for k, h in pairs(SCAN) do
    if not robo[k] then
        local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        local mapped = base(x, y, z)
        local b = w:get(x, y, z)
        local now = (h == 0 and "air") or (h > 50 and "water") or "solid"
        local was = (not b and (mapped == nil or mapped == "air")) and "air"
                or ((b and b[1]:find("water")) or (mapped and mapped:find("water"))) and "water"
                or "solid"
        local put
        if now == "air" and was ~= "air" then put = {"minecraft:air", 0}; n.air = n.air + 1
        elseif now == "water" and was ~= "water" then put = {"minecraft:water", 0}
            n.water = n.water + 1
        elseif now == "solid" and was == "air" and plan[k] and plan[k][1] ~= "minecraft:air" then
            put = plan[k]; n.planned = n.planned + 1
        end
        if put then
            f:write(("%d %d %d %s %d 1.0 analyzed geolyzer %.2f (ops/scan_to_map.lua)\n")
                    :format(x + a[1], y + a[2], z + a[3], put[1], put[2], h))
            w:set(x, y, z, put[1] ~= "minecraft:air" and {put[1], put[2]} or nil)
            vc.route_set(x, y, z, put[1] == "minecraft:air" and 1 or 2)
        end
    end
end
f:close()
return ("air %d, water %d, planned blocks now there %d"):format(n.air, n.water, n.planned)
