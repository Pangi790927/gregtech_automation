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

package.path = package.path .. ";./scripts/?.lua;../simulator/scripts/?.lua;./robot/?.lua"

local vc = require("virt_composer")

--[[ A module looked up by name at every use, not held: `reload <name>` on the control port then
-- reaches the running program at once, with no restart (the user, 2026-10-05: "less shutdowns
-- are needed"). `reinit[name]` gives a reloaded module what init gave it at the start. Not for
-- robots or control: they hold coroutines and sockets. ]]
local live = require("live")
reinit = {}
local settings = require("settings")
local camera = require("camera")
local chunks = require("chunks")
local view = require("view")
local plan = live("plan")
local marks = live("marks")
local labels = live("labels")
local zmap = live("zmap")
local robots = require("robots")
local control = require("control")
local packets = live("packets")
local sim = live("sim")

local DATA = "data/"
local PATHS = {chunks = DATA .. "chunks", anchor = DATA .. "anchor.txt", zone = DATA .. "zone.txt",
               built = DATA .. "built.txt", fixed = DATA .. "fixed.txt",
               scouted = DATA .. "scouted.txt"}
local PLANS = {DATA .. "harbour.txt", DATA .. "village.txt"}

local last_time = 0
local note = ""

function test_init()
    settings.load("settings.save")
    vc.render_init(settings.get("minecraft_path") or "", settings.get("minecraft_jar") or "")
    camera.init(settings)
    view.init(PATHS)
    reinit.plan = function() plan.init(PLANS) end
    reinit.packets = function() packets.init({DATA .. "village.txt", DATA .. "harbour.txt"}) end
    reinit.marks = function() marks.init(DATA .. "markers.txt") end
    reinit.labels = function() labels.init(DATA .. "labels.txt") end
    reinit.zmap = function() zmap.init(PATHS) end
    for _, f in pairs(reinit) do f() end
    view.add_overlay(plan)
    view.add_overlay(robots)
    view.add_overlay(packets)
    view.add_overlay(sim)
    local cx, cz = chunks.read_pair(PATHS.zone, "zone")
    if not cx then
        note = "no data/zone.txt: M picks a zone"
    elseif not view.load_zone(cx, cz) then
        note = ("no chunk files round %d %d"):format(cx, cz)
    end
    if not control.start(7790) then note = "the control port 7790 is taken" end
    last_time = vc.app_time()
    return 0
end

-- ImGui's window flags and conditions, as imgui.h numbers them
local AUTO_SIZE, ONCE = 64, 2

local function panel()
    -- top left, sized to what it holds: at a fixed size its lower parts were scrolled out of sight
    vc.ImGui_SetNextWindowPos({x = 10, y = 10}, ONCE)
    vc.ImGui_Begin("3d-draw", AUTO_SIZE)
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
    packets.panel()
    vc.ImGui_Separator()
    sim.panel()
    vc.ImGui_Separator()
    vc.ImGui_Text("tab: fly / free the mouse   M: the map of chunks")
    vc.ImGui_Text("arrows: the zone a chunk at a time, as the camera looks")
    vc.ImGui_Text(("O: the robots' paths %s   J: what is left of the worked packets %s"):format(
            view.paths and "shown" or "hidden", view.j and "shown" or "hidden"))
    vc.ImGui_End()
end

-- A module's part of the frame, kept from taking the frame with it: an error in one is logged
-- once, shown in the panel, and the rest is drawn (2026-10-05: a debug line in sim.lua threw
-- every frame and blanked the user's view for some 9000 frames).
local failed = {}
local function guarded(name, f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    local why = tostring(r)
    if failed[name] ~= why then
        failed[name] = why
        print(name .. " failed: " .. why)
        note = name .. " failed: " .. why
    end
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
    if vc.ImGui_IsKeyPressed("ImGuiKey_J", false) and not vc.ImGui_WantCaptureKeyboard() then
        view.j = not view.j
    end
    if vc.ImGui_IsKeyPressed("ImGuiKey_O", false) and not vc.ImGui_WantCaptureKeyboard() then
        view.paths = not view.paths
    end
    local over = guarded("plan.update", plan.update, dt)
    over = guarded("packets.update", packets.update) or over
    over = guarded("robots.update", robots.update, dt) or over
    over = guarded("sim.update", sim.update, dt) or over
    if over then view.update_overlays() end
    guarded("marks.update", marks.update, dt)
    guarded("labels.update", labels.update, dt)
    guarded("zmap.update", zmap.update, dt)

    local disp = vc.ImGui_GetDisplaySize()
    vc.render_world(view.world, math.floor(disp.x), math.floor(disp.y))

    guarded("labels.draw", labels.draw)
    guarded("marks.draw", marks.draw)
    guarded("packets.draw", packets.draw)
    guarded("sim.draw", sim.draw)
    guarded("robots.draw", robots.draw)
    guarded("robots.panel", robots.panel)
    guarded("zmap.draw", zmap.draw)
    panel()
    return 0
end

function test_shutdown()
    return 0
end
