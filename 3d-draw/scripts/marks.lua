--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | Markers the user puts on blocks (K), for Claude to read: the user, 2026-10-04: "I would also
-- | like to be able to place some colored markers so I can tell you what things are, so that I
-- | won't have to go read coords".
-- |
-- |     marks.init(path)     data/markers.txt: `marker x y z colour [note]`, robot coordinates
-- |     marks.update(dt)     K toggles; C steps the colour; a left click marks the block under the
-- |                          crosshair, a right click takes a marker away; the file is followed,
-- |                          so Claude may edit or empty it while the view is open
-- |     marks.draw()         each marker as a dot on its block's top, with its note over it
-- |     marks.panel()        the panel's part: mode, colours, the note for the next marker
-- |
-- | Clicks count only while the pointer is captured (Tab): the crosshair aims. A marker whose
-- | block is gone is taken away by a right click near it (the user, 2026-10-04: "I can't remove
-- | them anymore because they no longer stay on blocks").
-- |
-- | Ported from the old viewer (simulator/scenes/draw3d/controller.lua, 2026-10-05).
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local watch = require("watch")
local view = require("view")

local marks = {on = false, path = nil, list = {}, colour = 1, note = "", at = nil, w = nil,
               message = ""}

local COLOURS = {
    {"red", 0xe03030}, {"orange", 0xf08a20}, {"yellow", 0xf0e030}, {"green", 0x40c040},
    {"cyan", 0x30d0d0}, {"blue", 0x3c64f0}, {"purple", 0xa040e0}, {"white", 0xf0f0f0},
}
local RGB = {}
for _, c in ipairs(COLOURS) do RGB[c[1]] = c[2] end

local REACH = 200                -- the whole 64-wide world, from anywhere in it
local PICK = 1.5                 -- how near the crosshair's ray a marker is taken away

local function abgr(rgb)
    return 0xff000000 | ((rgb & 0xff) << 16) | (rgb & 0xff00) | ((rgb >> 16) & 0xff)
end
marks.abgr = abgr

function marks.init(path)
    marks.path = path
    marks.w = watch.new(path)
end

local function read(text)
    marks.list = {}
    for line in text:gmatch("[^\n]+") do
        local x, y, z, colour, note =
                line:gsub("\r$", ""):match("^marker (-?%d+) (-?%d+) (-?%d+) (%a+)%s*(.*)$")
        if x then
            marks.list[#marks.list + 1] = {tonumber(x), tonumber(y), tonumber(z), colour, note}
        end
    end
end

local function save()
    local out = {"# 3d-draw viewer markers (K): marker x y z colour [note], robot coordinates\n"}
    for _, m in ipairs(marks.list) do
        out[#out + 1] = ("marker %d %d %d %s%s\n"):format(m[1], m[2], m[3], m[4],
                m[5] ~= "" and (" " .. m[5]) or "")
    end
    local text = table.concat(out)
    local f = io.open(marks.path, "wb")
    if not f then
        marks.message = "markers: cannot write " .. tostring(marks.path)
        return
    end
    f:write(text)
    f:close()
    marks.w:mark(text)
end

-- The block under the crosshair, in robot coordinates: a voxel cast, not the ground plane.
local function aim()
    if not view.zone then return nil end
    local cam, fwd = vc.cam_get(), vc.cam_forward()
    local hit = view.world:raycast(cam[1], cam[2], cam[3], fwd[1], fwd[2], fwd[3], REACH)
    if not hit[1] or hit[8] then return nil end
    return {view.to_robot(hit[2], hit[3], hit[4])}
end

local function find(p)
    for i, m in ipairs(marks.list) do
        if m[1] == p[1] and m[2] == p[2] and m[3] == p[3] then return i end
    end
end

-- Where a marker's dot is drawn: on its block's top, in the world's cells.
local function dot(m)
    local x, y, z = view.to_cell(m[1], m[2], m[3])
    if not x then return nil end
    return x + 0.5, y + 1.05, z + 0.5
end

-- The marker nearest the crosshair's ray within PICK, or within two blocks of the cell aimed at.
local function nearest()
    local cam, fwd = vc.cam_get(), vc.cam_forward()
    local len = math.sqrt(fwd[1] ^ 2 + fwd[2] ^ 2 + fwd[3] ^ 2)
    if len == 0 then return nil end
    local f = {fwd[1] / len, fwd[2] / len, fwd[3] / len}
    local a, best, best_d = marks.at, nil, nil
    for i, m in ipairs(marks.list) do
        local x, y, z = dot(m)
        if x then
            local p = {x - cam[1], y - cam[2], z - cam[3]}
            local t = p[1] * f[1] + p[2] * f[2] + p[3] * f[3]
            local d = math.sqrt((p[1] - t * f[1]) ^ 2 + (p[2] - t * f[2]) ^ 2
                                + (p[3] - t * f[3]) ^ 2)
            local near = a and math.abs(m[1] - a[1]) <= 2 and math.abs(m[2] - a[2]) <= 2
                    and math.abs(m[3] - a[3]) <= 2
            if t > 0 and (d <= PICK or near) and (not best_d or d < best_d) then
                best, best_d = i, d
            end
        end
    end
    return best
end

function marks.update(dt)
    local text = marks.w:poll(dt)
    if text then read(text) end
    local typing = vc.ImGui_WantCaptureKeyboard()
    if not typing and vc.ImGui_IsKeyPressed("ImGuiKey_K", false) then marks.on = not marks.on end
    if not marks.on then
        marks.at = nil
        return
    end
    if not typing and vc.ImGui_IsKeyPressed("ImGuiKey_C", false) then
        marks.colour = marks.colour % #COLOURS + 1
    end
    marks.at = aim()
    if not vc.mouse_captured() or vc.ImGui_WantCaptureMouse() then return end
    local i = marks.at and find(marks.at)
    if vc.ImGui_IsMouseClicked("ImGuiMouseButton_Right", false) then
        i = i or nearest()
        if i then
            table.remove(marks.list, i)
            save()
        end
        return
    end
    if marks.at and vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false) then
        local m = {marks.at[1], marks.at[2], marks.at[3], COLOURS[marks.colour][1],
                   (marks.note:gsub("[\r\n]", " "))}
        if i then marks.list[i] = m else marks.list[#marks.list + 1] = m end
        save()
    end
end

function marks.draw()
    if not view.zone then return end
    local disp = vc.ImGui_GetDisplaySize()
    local W, H = math.floor(disp.x), math.floor(disp.y)
    vc.ImGui_SetDrawForeground(true)
    for _, m in ipairs(marks.list) do
        local x, y, z = dot(m)
        local at = x and vc.render_project(x, y, z, W, H)
        if at and at[3] > 0 and at[1] > -100 and at[1] < W + 100 and at[2] > 0 and at[2] < H then
            local colour = abgr(RGB[m[4]] or 0xff00ff)
            vc.ImGui_AddCircleFilled({x = at[1], y = at[2]}, 7, colour)
            vc.ImGui_AddCircle({x = at[1], y = at[2]}, 7, 0xff000000, 2)
            local text = m[5] ~= "" and m[5] or m[4]
            local size = vc.ImGui_CalcTextSize(text)
            local x0, y0 = at[1] - size.x / 2 - 4, at[2] - size.y - 14
            vc.ImGui_AddRectFilled({x = x0, y = y0}, {x = x0 + size.x + 8, y = y0 + size.y + 4},
                    0xc0202020, 3)
            vc.ImGui_AddText({x = x0 + 4, y = y0 + 2}, colour, text)
        end
    end
    if marks.on and marks.at then
        local x, y, z = dot(marks.at)
        local at = x and vc.render_project(x, y, z, W, H)
        if at and at[3] > 0 then
            vc.ImGui_AddCircle({x = at[1], y = at[2]}, 11, abgr(COLOURS[marks.colour][2]), 3)
        end
    end
    vc.ImGui_SetDrawForeground(false)
end

function marks.panel()
    vc.ImGui_Text(("markers %s (K)   %d placed   left click marks, right click unmarks"):format(
            marks.on and "ON " or "off", #marks.list))
    for i, c in ipairs(COLOURS) do
        if i > 1 then vc.ImGui_SameLine(0, -1) end
        if vc.ImGui_SmallButton((i == marks.colour and "[%s]" or "%s"):format(c[1])) then
            marks.colour = i
        end
    end
    local typed = vc.ImGui_InputText("note", marks.note, 80)
    if typed[1] then marks.note = typed[2] end
    vc.ImGui_Text("the note goes on the next marker; Tab frees the mouse to type, Tab again to aim")
    if marks.on and marks.at then
        local a = marks.at
        local c = view.terrain[(a[1] + view.anchor[1]) .. "," .. (a[2] + view.anchor[2]) .. ","
                               .. (a[3] + view.anchor[3])]
        vc.ImGui_Text(("aiming at %d %d %d  %s"):format(a[1], a[2], a[3],
                c and (c[4] .. ":" .. c[5]) or ""))
    end
    if marks.message ~= "" then vc.ImGui_Text(marks.message) end
    vc.ImGui_Text("C: next colour   file: 3d-draw/data/markers.txt")
end

return marks
