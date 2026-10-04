--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The map as zones.py keeps it: chunk files, with what was built and what the user told laid
-- | over them. Plain Lua, no `vc`, so the tests read it without a window.
-- |
-- |     chunks.read_zone(dir, cx, cz, layers)   the 3x3 chunks round cx, cz: {box, cells}
-- |     chunks.read_pair(path, word)            `<word> a b` from a one-line file (zone.txt,
-- |                                             anchor.txt), as two or three numbers
-- |
-- | A chunk file (data/chunks/c<cx>_<cz>.txt, written by zones.py), in world coordinates:
-- |     box x <x0> <x1> y <y0> <y1> z <z0> <z1>
-- |     palette <id> <name> <meta> <hardness> <how>     its own numbers; 0 or none is air
-- |     layer <y> <row>;<row>;...                       a row per z, ids by x, comma separated
-- |     guessed <y> <row>;<row>;...                     1 where the block was guessed
-- | A layer file (data/built.txt, data/fixed.txt): `x y z name meta hardness how ...` per line,
-- | world coordinates; laid over the chunks in the order given, air taking a block away.
-- |
-- | A cell: {x, y, z, name, meta, how, guess}, keyed "x,y,z".
-- |
-- | Read from simulator/scenes/draw3d/controller.lua's zone_load (2026-10-05), which does the same
-- | into the view's events; this keeps only the reading, so the view and the control share it.
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local chunks = {}

local AIR = "minecraft:air"

local function lines_of(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local out = {}
    for line in f:lines() do out[#out + 1] = line end
    f:close()
    return out
end

--[[ @brief The numbers after `word` on a one-line file's first line: `zone 15 7` -> 15, 7.
-- | @return numbers, or nil when the file or the word is not there
-- | @date 2026-10-05 ]]
function chunks.read_pair(path, word)
    local lines = lines_of(path)
    if not lines then return nil end
    for _, line in ipairs(lines) do
        local rest = line:match("^" .. word .. "%s+(.*)$")
        if rest then
            local out = {}
            for v in rest:gmatch("%S+") do out[#out + 1] = tonumber(v) end
            return table.unpack(out)
        end
    end
    return nil
end

-- One chunk file into `cells`; widens `box` to hold it. Missing files are skipped: a zone at the
-- map's edge has fewer than nine.
local function read_chunk(path, cells, box)
    local lines = lines_of(path)
    if not lines then return end
    local b = {(lines[2] or ""):match("^box x (%S+) (%S+) y (%S+) (%S+) z (%S+) (%S+)$")}
    if not b[1] then return end
    for i = 1, 6 do b[i] = tonumber(b[i]) end
    box[3], box[4] = math.min(box[3], b[3]), math.max(box[4], b[4])
    local pal, guessed = {}, {}
    for _, line in ipairs(lines) do
        local id, name, meta, _, how = line:match("^palette (%d+) (%S+) (%d+) (%S+) (%S+)$")
        if id then pal[tonumber(id)] = {name, tonumber(meta), how} end
        local gy, data = line:match("^guessed (%S+) (.*)$")
        if gy then guessed[tonumber(gy)] = data end
    end
    for _, line in ipairs(lines) do
        local ly, data = line:match("^layer (%S+) (.*)$")
        if ly then
            local y = tonumber(ly)
            local grows = {}
            for row in (guessed[y] or ""):gmatch("[^;]+") do grows[#grows + 1] = row end
            local zi = 0
            for row in data:gmatch("[^;]+") do
                local flags = {}
                for v in (grows[zi + 1] or ""):gmatch("[^,]+") do flags[#flags + 1] = v end
                local xi = 0
                for v in row:gmatch("[^,]+") do
                    local p = pal[tonumber(v)]
                    if p then
                        local x, z = b[1] + xi, b[5] + zi
                        cells[x .. "," .. y .. "," .. z] = {x, y, z, p[1], p[2], p[3],
                                                            flags[xi + 1] == "1"}
                    end
                    xi = xi + 1
                end
                zi = zi + 1
            end
        end
    end
end

--[[ @brief The 3x3 chunks round cx, cz, with the layer files laid over them.
-- |
-- | @param dir     string - the chunk folder (data/chunks)
-- | @param cx      number - the middle chunk, world chunk coordinates (x // 16)
-- | @param cz      number
-- | @param layers  table of strings - layer files, laid over in this order (built, then fixed)
-- | @return table {box = {x0, x1, y0, y1, z0, z1}, cells = {["x,y,z"] = cell}} or nil when no
-- |         chunk of the zone has a file
-- | @date 2026-10-05 ]]
function chunks.read_zone(dir, cx, cz, layers)
    local x0, x1 = (cx - 1) * 16, (cx + 2) * 16 - 1
    local z0, z1 = (cz - 1) * 16, (cz + 2) * 16 - 1
    local box, cells = {x0, x1, math.huge, -math.huge, z0, z1}, {}
    for i = cx - 1, cx + 1 do
        for j = cz - 1, cz + 1 do
            read_chunk(("%s/c%d_%d.txt"):format(dir, i, j), cells, box)
        end
    end
    if box[3] == math.huge then return nil end
    for _, path in ipairs(layers or {}) do
        for _, line in ipairs(lines_of(path) or {}) do
            local x, y, z, name, meta, _, how =
                    line:match("^(-?%d+) (-?%d+) (-?%d+) (%S+) (%d+) (%S+) (%S+)")
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            if x and x >= x0 and x <= x1 and z >= z0 and z <= z1 then
                local k = x .. "," .. y .. "," .. z
                if name == AIR then
                    cells[k] = nil
                else
                    cells[k] = {x, y, z, name, tonumber(meta), how, false}
                    box[3], box[4] = math.min(box[3], y), math.max(box[4], y)
                end
            end
        end
    end
    return {box = box, cells = cells}
end

return chunks
