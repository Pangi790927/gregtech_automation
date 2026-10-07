-- A box of the world scanned by a scout's geolyzer from where it stands, read only: 8x8 a layer,
-- the hardness of each cell into SCAN["x,y,z"] (robot coordinates). Progress in SCANNED. Set as
-- globals before the dofile: BOX = {x0, x1, y0, y1, z0, z1} (within 32 of the scout), SCOUT (a
-- robot with a geolyzer: Tom_Servo, Cairol, Pintsize). The cabin's box: {-15, 8, -4, 8, -9, 9}.
-- Hardness 0 is air, no guess; ~100 is water or lava; anything else is a block, its kind not
-- told apart - the noise here was about +-1 (redesign/19-ops.md, "Scanning").
local vc = require("virt_composer")
local robots = require("robots")
local scout = SCOUT or "Tom_Servo"
local b = BOX
SCAN, SCANNED = {}, "starting"
require("spawn")(function()
    local r = robots.by[scout]
    local p = r.sf.pos
    local n = 0
    for y = b[3], b[4] do
        for x0 = b[1], b[2], 8 do
            for z0 = b[5], b[6], 8 do
                local w, d = math.min(8, b[2] - x0 + 1), math.min(8, b[6] - z0 + 1)
                local t = robots.send(scout, ("geo %d %d %d %d %d 1"):format(x0 - p[1], z0 - p[3],
                        y - p[2], w, d))
                for _ = 1, 100 do
                    if t.head then break end
                    vc.net_sleep_ms(100)
                end
                local v = {}
                for h in tostring(t.head):match("^%S+ ok %d+ (.*)$"):gmatch("[^,]+") do
                    v[#v + 1] = tonumber(h)
                end
                for dz = 0, d - 1 do
                    for dx = 0, w - 1 do
                        SCAN[(x0 + dx) .. "," .. y .. "," .. (z0 + dz)] = v[dx + dz * w + 1]
                    end
                end
                n = n + 1
                SCANNED = ("%d scans, layer %d"):format(n, y)
            end
        end
    end
    SCANNED = "done: " .. n .. " scans"
end)
return "scanning from " .. scout
