-- A plan file planned and proven on paper, the live plan (packets.result) untouched: every cell
-- the scan (SCAN) read as air counts as air - in the map and, for the proof's while, in the grid
-- (put back after). PLAN: the plan file (a global). -> its packets, proven or why not; the result
-- kept in OFFLINE_RES. Run it on a coroutine, the proof takes a while (redesign/19-ops.md):
--     lua OP='running' require('spawn')(function()
--         OP = tostring(dofile('ops/prove_offline.lua')) end)
local vc = require("virt_composer")
local packets, planner, prove = require("packets"), require("planner"), require("prove")
local SM = {xpos = 0, xneg = 1, zpos = 2, zneg = 3}       -- a stair's way, as packets.lua reads it
local want = {}
for line in io.lines(PLAN) do
    local x, y, z, name, meta, shape, facing =
            line:match("^b (-?%d+) (-?%d+) (-?%d+) (%S+) (%d+) ?(%d*) ?(%S*)")
    if x then
        meta = tonumber(meta)
        if name:find("_stairs") and SM[facing] then
            meta = SM[facing] + (shape == "6" and 4 or 0)
        end
        want[x .. "," .. y .. "," .. z] = {name, meta}
    end
end
local base = packets.have
local function have(x, y, z)
    if SCAN and SCAN[x .. "," .. y .. "," .. z] == 0 then return "air" end
    return base(x, y, z)
end
local kept = {}
for k, h in pairs(SCAN or {}) do
    if h == 0 then
        local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        kept[#kept + 1] = {x, y, z, vc.route_get(x, y, z)}
        vc.route_set(x, y, z, 1)
    end
end
local res = planner.plan(want, have)
local stats = prove.run(res, want, have, {entry = {0, 0, -2}})
for _, c in ipairs(kept) do vc.route_set(c[1], c[2], c[3], c[4]) end
OFFLINE_RES = res
local out, steps = {}, 0
for _, id in ipairs(res.order) do
    local p = res.packets[id]
    if p.steps then steps = steps + #p.steps end
    out[#out + 1] = id .. ": " .. (p.steps and (#p.steps .. " steps") or ("UNPROVEN " ..
            tostring(p.unproven):sub(1, 110)))
end
return ("%d packets, %d proven, %d unproven, %d steps\n%s"):format(#res.order, stats.proven,
        stats.unproven, steps, table.concat(out, "\n"))
