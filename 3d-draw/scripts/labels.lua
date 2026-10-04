--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | Names shown over blocks: the station, what to build around.
-- |
-- |     labels.init(path)    data/labels.txt: `label x y z text`, robot coordinates
-- |     labels.update(dt)    the file, followed
-- |     labels.draw()        each label over its block's top, on a dark backing
-- |
-- | Ported from the old viewer (simulator/scenes/draw3d/controller.lua, 2026-10-05).
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local watch = require("watch")
local view = require("view")

local labels = {list = {}, w = nil}

function labels.init(path)
    labels.w = watch.new(path)
end

function labels.update(dt)
    local text = labels.w:poll(dt)
    if not text then return end
    labels.list = {}
    for line in text:gmatch("[^\n]+") do
        local x, y, z, words = line:match("^label (-?%d+) (-?%d+) (-?%d+) (.+)$")
        if x then
            labels.list[#labels.list + 1] = {tonumber(x), tonumber(y), tonumber(z),
                                             (words:gsub("\r$", ""))}
        end
    end
end

function labels.draw()
    if #labels.list == 0 then return end
    local disp = vc.ImGui_GetDisplaySize()
    local W, H = math.floor(disp.x), math.floor(disp.y)
    vc.ImGui_SetDrawForeground(true)
    for _, l in ipairs(labels.list) do
        local x, y, z = view.to_cell(l[1], l[2], l[3])
        local at = x and vc.render_project(x + 0.5, y + 1.3, z + 0.5, W, H)
        if at and at[3] > 0 and at[1] > -100 and at[1] < W + 100 and at[2] > 0 and at[2] < H then
            local size = vc.ImGui_CalcTextSize(l[4])
            local x0, y0 = at[1] - size.x / 2 - 4, at[2] - size.y - 4
            vc.ImGui_AddRectFilled({x = x0, y = y0}, {x = x0 + size.x + 8, y = y0 + size.y + 4},
                    0xc0202020, 3)
            vc.ImGui_AddText({x = x0 + 4, y = y0 + 2}, 0xff40e0ff, l[4])
        end
    end
    vc.ImGui_SetDrawForeground(false)
end

return labels
