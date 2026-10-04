--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | NOTHING. This is the program's entry script, not a module: virt_composer loads it as
-- | `main_script` (3d-draw.yaml) and main.cpp calls the globals below.
-- |
-- |     test_init()     reads settings.save, points the renderer at the Minecraft instance, and
-- |                     shows the robots' work zone (data/zone.txt)
-- |     test_draw()     one frame: the keys, the camera, the world, the windows
-- |     test_shutdown() nothing yet
-- |
-- | The old viewer's lasting parts (simulator/scenes/draw3d), each a module of its own: the zone
-- | from the chunk files (view), the plans (plan, H), markers (marks, K), labels, the map of
-- | chunks (zmap, M). Its live log, the pending cubes (J) and painting are left out: what the
-- | robots do comes from the exe itself once it drives them (3d-draw/redesign/08-order.md).
-- | The simulator's own scripts used here - settings, camera, blocks - are required from
-- | ../simulator/scripts, never copied. Tab grabs the mouse to fly, as in the simulator.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     last_time, note
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

package.path = package.path .. ";./scripts/?.lua;../simulator/scripts/?.lua"

local vc = require("virt_composer")
local settings = require("settings")
local camera = require("camera")
local chunks = require("chunks")
local view = require("view")
local plan = require("plan")
local marks = require("marks")
local labels = require("labels")
local zmap = require("zmap")

local DATA = "data/"
local PATHS = {chunks = DATA .. "chunks", anchor = DATA .. "anchor.txt", zone = DATA .. "zone.txt",
               built = DATA .. "built.txt", fixed = DATA .. "fixed.txt"}
local PLANS = {DATA .. "harbour.txt", DATA .. "village.txt"}

local last_time = 0
local note = ""

function test_init()
    settings.load("settings.save")
    vc.render_init(settings.get("minecraft_path") or "", settings.get("minecraft_jar") or "")
    camera.init(settings)
    view.init(PATHS)
    plan.init(PLANS)
    marks.init(DATA .. "markers.txt")
    labels.init(DATA .. "labels.txt")
    zmap.init(PATHS)
    view.add_overlay(plan)
    local cx, cz = chunks.read_pair(PATHS.zone, "zone")
    if not cx then
        note = "no data/zone.txt: M picks a zone"
    elseif not view.load_zone(cx, cz) then
        note = ("no chunk files round %d %d"):format(cx, cz)
    end
    last_time = vc.app_time()
    return 0
end

local function panel()
    vc.ImGui_Begin("3d-draw", 0)
    if view.zone then
        local b, c = view.zone.box, view.counts
        vc.ImGui_Text(("zone %d %d: world x %d..%d  y %d..%d  z %d..%d"):format(
                view.zone.cx, view.zone.cz, b[1], b[2], b[3], b[4], b[5], b[6]))
        vc.ImGui_Text(("%d blocks, %d drawn without a texture%s"):format(c.cells, c.untextured,
                c.cut > 0 and (", %d out of the world's 64"):format(c.cut) or ""))
    end
    if note ~= "" then vc.ImGui_Text(note) end
    vc.ImGui_Separator()
    plan.panel()
    vc.ImGui_Separator()
    marks.panel()
    vc.ImGui_Separator()
    vc.ImGui_Text("tab: fly / free the mouse   M: the map of chunks")
    vc.ImGui_Text("arrows: the zone a chunk at a time, as the camera looks")
    vc.ImGui_End()
end

function test_draw()
    local now = vc.app_time()
    local dt = now - last_time
    last_time = now
    -- Tab is this program's, not ImGui's, as in the simulator: a text box clicked once must not
    -- keep the keys from the world.
    if vc.ImGui_IsKeyPressed("ImGuiKey_Tab", false) then
        camera.toggle_capture()
        if vc.mouse_captured() then vc.ImGui_ClearFocus() end
    end
    camera.update(settings, dt)
    view.follow(dt)
    view.step_zone()
    if plan.update(dt) then view.update_overlays() end
    marks.update(dt)
    labels.update(dt)
    zmap.update(dt)

    local disp = vc.ImGui_GetDisplaySize()
    vc.render_world(view.world, math.floor(disp.x), math.floor(disp.y))

    labels.draw()
    marks.draw()
    zmap.draw()
    panel()
    return 0
end

function test_shutdown()
    return 0
end
