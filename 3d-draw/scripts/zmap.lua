--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The map of chunks (M): every chunk kept, coloured by the block on top of each column; a click
-- | shows the 3x3 chunks round the one clicked. The user, 2026-10-04: "a sort of map with chunk
-- | wide click zones that centers the map around that zone and draws the 3x3 chunk in the
-- | viewer, maybe put that map on M".
-- |
-- |     zmap.init(paths)     {chunks, zone}: data/chunks/overview.txt (zones.py writes it) and
-- |                          data/zone.txt, the robots' work zone (drawn red)
-- |     zmap.update(dt)      M toggles; the overview is read again while open, when it changed
-- |     zmap.draw()          the window; a click loads that zone into the view
-- |
-- | Ported from the old viewer (simulator/scenes/draw3d/controller.lua, 2026-10-05), without its
-- | robots: they come back with the link (3d-draw/redesign/08-order.md, stage 2).
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local look = require("look")
local watch = require("watch")
local view = require("view")
local chunks = require("chunks")

local zmap = {on = false, chunks = {}, names = {}, work = nil, w = nil, zone_path = nil}

local PX = 3                    -- screen pixels a column
local NATURAL = {
    ["minecraft:grass"] = 0x5d9b3a, ["minecraft:dirt"] = 0x86603e,
    ["minecraft:stone"] = 0x7d7d7d, ["minecraft:water"] = 0x3060e0,
    ["BiomesOPlenty:leaves4"] = 0x2f6b1f, ["minecraft:log"] = 0x6b5233,
    ["minecraft:sand"] = 0xdbd3a0, ["minecraft:gravel"] = 0x857f7b,
    ["minecraft:clay"] = 0x9fa4b1, ["BiomesOPlenty:flowers2"] = 0xa070c0,
    ["chisel:antiBlock"] = 0xd060c0, ["minecraft:cobblestone"] = 0x6f6f6f,
    ["minecraft:planks"] = 0xa8865a, ["minecraft:leaves"] = 0x3a7a2a,
}

local function abgr(rgb)
    return 0xff000000 | ((rgb & 0xff) << 16) | (rgb & 0xff00) | ((rgb >> 16) & 0xff)
end

function zmap.init(paths)
    zmap.w = watch.new(paths.chunks .. "/overview.txt")
    zmap.zone_path = paths.zone
end

-- Each chunk's rows as runs of one colour, so a frame draws a few hundred rectangles.
local function read(text)
    zmap.chunks, zmap.names = {}, {}
    for line in text:gmatch("[^\n]+") do
        local names = line:match("^names (.*)$")
        if names then
            for n in names:gmatch("%S+") do zmap.names[#zmap.names + 1] = n end
        end
        local cx, cz, data = line:match("^chunk (-?%d+) (-?%d+) (.*)$")
        if cx then
            local cols = {}
            for v in data:gmatch("[^,]+") do cols[#cols + 1] = tonumber(v) end
            local runs = {}
            for row = 0, 15 do
                local start, last = 0, nil
                for col = 0, 16 do
                    local v = col < 16 and cols[row * 16 + col + 1] or nil
                    if col == 16 or v ~= last then
                        if last ~= nil and col > 0 then
                            local name = zmap.names[last + 1]
                            local rgb = last >= 0 and name and (NATURAL[name]
                                    or look.colour_of(name, 0)) or 0x202020
                            runs[#runs + 1] = {row, start, col, abgr(rgb)}
                        end
                        start, last = col, v
                    end
                end
            end
            zmap.chunks[#zmap.chunks + 1] = {tonumber(cx), tonumber(cz), runs}
        end
    end
end

function zmap.update(dt)
    if vc.ImGui_IsKeyPressed("ImGuiKey_M", false) and not vc.ImGui_WantCaptureKeyboard() then
        zmap.on = not zmap.on
        if zmap.on then
            local cx, cz = chunks.read_pair(zmap.zone_path, "zone")
            zmap.work = cx and {cx, cz} or nil
        end
    end
    if zmap.on then
        local text = zmap.w:poll(dt)
        if text then read(text) end
    end
end

local function frame(at, cx0, cz0, cx, cz, colour, thick)
    local S = 16 * PX
    vc.ImGui_AddRect({x = at.x + (cx - 1 - cx0) * S, y = at.y + (cz - 1 - cz0) * S},
            {x = at.x + (cx + 2 - cx0) * S, y = at.y + (cz + 2 - cz0) * S}, colour, 0, thick)
end

function zmap.draw()
    if not zmap.on then return end
    vc.ImGui_Begin("chunks (M)", 0)
    if #zmap.chunks == 0 then
        vc.ImGui_Text("no chunks kept yet (data/chunks/overview.txt)")
        vc.ImGui_End()
        return
    end
    local cx0, cx1, cz0, cz1 = math.huge, -math.huge, math.huge, -math.huge
    for _, c in ipairs(zmap.chunks) do
        cx0, cx1 = math.min(cx0, c[1]), math.max(cx1, c[1])
        cz0, cz1 = math.min(cz0, c[2]), math.max(cz1, c[2])
    end
    local S = 16 * PX
    local at = vc.ImGui_GetCursorScreenPos()
    local hover
    for _, c in ipairs(zmap.chunks) do
        local ox, oy = at.x + (c[1] - cx0) * S, at.y + (c[2] - cz0) * S
        for _, r in ipairs(c[3]) do
            vc.ImGui_AddRectFilled({x = ox + r[2] * PX, y = oy + r[1] * PX},
                    {x = ox + r[3] * PX, y = oy + (r[1] + 1) * PX}, r[4], 0)
        end
        vc.ImGui_AddRect({x = ox, y = oy}, {x = ox + S, y = oy + S}, 0x50ffffff, 0, 1)
        if vc.ImGui_IsMouseHoveringRect({x = ox, y = oy}, {x = ox + S, y = oy + S}, true) then
            hover = c
        end
    end
    if zmap.work then frame(at, cx0, cz0, zmap.work[1], zmap.work[2], 0xff4040ff, 2) end
    if view.zone then frame(at, cx0, cz0, view.zone.cx, view.zone.cz, 0xff20e0ff, 2) end
    if hover then
        frame(at, cx0, cz0, hover[1], hover[2], 0xffffffff, 1)
        if vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false) then
            view.load_zone(hover[1], hover[2])
        end
    end
    vc.ImGui_Dummy({x = (cx1 - cx0 + 1) * S, y = (cz1 - cz0 + 1) * S})
    vc.ImGui_Text(hover and ("chunk %d %d: world x %d..%d, z %d..%d - click: show the 3x3 round it")
            :format(hover[1], hover[2], hover[1] * 16, hover[1] * 16 + 15, hover[2] * 16,
                    hover[2] * 16 + 15) or "point at a chunk")
    vc.ImGui_Text(("shown: %s (yellow); the robots' work zone: %s (red)"):format(
            view.zone and (view.zone.cx .. " " .. view.zone.cz) or "none",
            zmap.work and (zmap.work[1] .. " " .. zmap.work[2]) or "none"))
    vc.ImGui_End()
end

return zmap
