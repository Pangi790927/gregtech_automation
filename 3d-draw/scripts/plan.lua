--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The plans over the map (H): the buildings the user approved, drawn where they will stand.
-- |
-- |     plan.init(paths)     the plan files (data/harbour.txt, data/village.txt, ...)
-- |     plan.update(dt)      H toggles; a plan file that changed is read again; true when the
-- |                          view must be drawn again
-- |     plan.cells()         the view's overlay: robot "x,y,z" -> {name, meta, shape, facing},
-- |                          or nil while hidden
-- |     plan.panel()         its line in the panel
-- |
-- | A plan file (3d-draw/design/*.py writes them), robot coordinates, one block a line:
-- |     b <x> <y> <z> <name> <meta> <shape> <facing>
-- | An air block is ground the plan digs away: its cell is drawn empty.
-- |
-- | Ported from the old viewer's plan (simulator/scenes/draw3d/controller.lua, 2026-10-05).
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local watch = require("watch")
local view = require("view")

local plan = {on = false, files = {}, at = {}, count = 0, w = nil}

function plan.init(paths)
    plan.files = paths
    plan.w = watch.new(paths)
end

local function read(text)
    plan.at, plan.count = {}, 0
    for line in text:gmatch("[^\n]+") do
        local x, y, z, name, meta, shape, facing =
            line:match("^b (-?%d+) (-?%d+) (-?%d+) (%S+) (%d+) (%d+) (%S+)")
        if x then
            plan.at[x .. "," .. y .. "," .. z] = {name, tonumber(meta), tonumber(shape),
                                                  view.FACINGS[facing]}
            plan.count = plan.count + 1
        end
    end
end

function plan.update(dt)
    local redraw = false
    if vc.ImGui_IsKeyPressed("ImGuiKey_H", false) and not vc.ImGui_WantCaptureKeyboard() then
        plan.on = not plan.on
        redraw = true
    end
    local text = plan.w:poll(dt)
    if text then
        read(text)
        redraw = redraw or plan.on
    end
    return redraw
end

function plan.cells()
    return plan.on and plan.at or nil
end

function plan.panel()
    vc.ImGui_Text(("plan %s (H)   %d blocks in %d files"):format(plan.on and "shown" or "hidden",
            plan.count, #plan.files))
end

return plan
