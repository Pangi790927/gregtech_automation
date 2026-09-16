--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | NOTHING. This is the application's entry script, not a module: it
-- | returns no table and nothing requires it. virt_composer loads it as
-- | `main_script` (see simulator.yaml) and calls the globals below, which
-- | are the interface - to the C++ side rather than to any Lua caller.
-- |
-- |     test_init()     reads the settings and the saved world, points
-- |                     the renderer at the Minecraft instance, and puts
-- |                     the camera somewhere worth looking from.
-- |     test_draw()     one frame: input, then the world, then the
-- |                     interface. main.cpp keeps running when this
-- |                     throws, so the window stays closable while an
-- |                     error is on screen.
-- |     test_shutdown() writes the world and the settings back out.
-- |
-- | It also owns the SAVE PATHS. settings.save and world.save are resolved
-- | beside the executable through vc.path_resolve, so the simulator finds
-- | them whatever directory it was launched from.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     state, last_time, fps, handle_tools
-- |
-- | @date 2026-09-16 16:00
-- | ===============================================================================================
--]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local settings = require("settings")
local blocks = require("blocks")
local camera = require("camera")
local world = require("world")
local ui = require("ui")
local machines = require("machines")

--[[ Both files sit beside the executable rather than in the working directory, which is what
vc.path_resolve answers. Launching the simulator from a different directory should not quietly start
a second, empty world. @date 2026-09-16 ]]
local SETTINGS_PATH = vc.path_resolve("settings.save")
local WORLD_PATH = vc.path_resolve("world.save")
--[[ The contents of every machine's hard disk, beside the world rather than inside it: the world
file is a readable list of blocks, and a hundred and eighty files of operating system would drown
it. @date 2026-09-17 10:00 ]]
local DISKS_PATH = vc.path_resolve("disks.save")

local state = nil
local last_time = 0
local fps = 0

--[[ What a right click puts down, in the order the bar shows them. The colour is the swatch the
hotbar draws, since the 2D layer cannot sample the GL atlas the real textures live in. Adding a
placeable thing is a line here plus its `place` function. @date 2026-09-16 18:00 ]]
local TOOLS = {
    {name = "computer case", kind = blocks.KIND.CASE,
            place = function(st) return world.place(st, blocks.make_case) end},
    {name = "screen", kind = blocks.KIND.SCREEN,
            place = function(st) return world.place(st, blocks.make_screen) end},
    {name = "disk drive", kind = blocks.KIND.DRIVE,
            place = function(st) return world.place(st, blocks.make_drive) end},
    {name = "redstone lamp", kind = blocks.KIND.LAMP,
            place = function(st) return world.place(st, blocks.make_lamp) end},
    {name = "keyboard", kind = blocks.KIND.KEYBOARD,
            place = function(st) return world.place_keyboard(st) end},
    {name = "redstone wire", kind = blocks.KIND.WIRE,
            place = function(st) return world.place_wire(st) end},
    {name = "cable", kind = blocks.KIND.CABLE,
            place = function(st) return world.place(st, blocks.make_cable) end},
    {name = "chest", kind = blocks.KIND.CHEST,
            place = function(st) return world.place(st, blocks.make_chest) end},
    {name = "transposer", kind = blocks.KIND.TRANSPOSER,
            place = function(st) return world.place(st, blocks.make_transposer) end},
    {name = "redstone i/o", kind = blocks.KIND.REDSTONE,
            place = function(st) return world.place(st, blocks.make_redstone) end},
}
local selected = 1

--[[ The screen being looked at up close, or nil. While one is focused the camera is frozen, the
pointer is free, and typed keys are meant for the machine rather than for the simulator. Escape
leaves. @date 2026-09-16 23:30 ]]
local focus = nil

--[[ The chest being looked into, or nil. Like a focused screen it takes the frame's input, but it
is an ordinary window rather than a terminal, so ImGui handles the typing itself.
@date 2026-09-17 06:30 ]]
local chest = nil

--[[ The key codes OpenComputers uses, taken from the mod's own lib/keyboard.lua and
lib/core/full_keyboard.lua rather than remembered - a wrong code is a key that silently does the
wrong thing, or nothing.

THE CODE IS NOT DECORATION. A program identifies a key by its code and not by the character it
produced: `bin/edit.lua` matches its whole keymap with `code == keyboard.keys[key]`, and
`lib/core/cursor.lua` ends a `lua` session on `ctrl` plus `code == keys.d`. Sending every character
with a code of zero, which is what this did at first, leaves both of those unable to match anything
- the editor could not be driven and `lua` could not be left.

@date 2026-09-17 02:30 ]]
local OC_CHAR_KEY = {
    {"ImGuiKey_A", 30}, {"ImGuiKey_B", 48}, {"ImGuiKey_C", 46}, {"ImGuiKey_D", 32},
    {"ImGuiKey_E", 18}, {"ImGuiKey_F", 33}, {"ImGuiKey_G", 34}, {"ImGuiKey_H", 35},
    {"ImGuiKey_I", 23}, {"ImGuiKey_J", 36}, {"ImGuiKey_K", 37}, {"ImGuiKey_L", 38},
    {"ImGuiKey_M", 50}, {"ImGuiKey_N", 49}, {"ImGuiKey_O", 24}, {"ImGuiKey_P", 25},
    {"ImGuiKey_Q", 16}, {"ImGuiKey_R", 19}, {"ImGuiKey_S", 31}, {"ImGuiKey_T", 20},
    {"ImGuiKey_U", 22}, {"ImGuiKey_V", 47}, {"ImGuiKey_W", 17}, {"ImGuiKey_X", 45},
    {"ImGuiKey_Y", 21}, {"ImGuiKey_Z", 44},
    {"ImGuiKey_1", 2}, {"ImGuiKey_2", 3}, {"ImGuiKey_3", 4}, {"ImGuiKey_4", 5},
    {"ImGuiKey_5", 6}, {"ImGuiKey_6", 7}, {"ImGuiKey_7", 8}, {"ImGuiKey_8", 9},
    {"ImGuiKey_9", 10}, {"ImGuiKey_0", 11},
    {"ImGuiKey_Minus", 12}, {"ImGuiKey_Equal", 13},
    {"ImGuiKey_LeftBracket", 26}, {"ImGuiKey_RightBracket", 27},
    {"ImGuiKey_Semicolon", 39}, {"ImGuiKey_Apostrophe", 40}, {"ImGuiKey_GraveAccent", 41},
    {"ImGuiKey_Backslash", 43}, {"ImGuiKey_Comma", 51}, {"ImGuiKey_Period", 52},
    {"ImGuiKey_Slash", 53}, {"ImGuiKey_Space", 57},
}

--[[ The letter keys alone, by name, for building a control character. @date 2026-09-17 02:30 ]]
local OC_LETTER = {
    a = 30, b = 48, c = 46, d = 32, e = 18, f = 33, g = 34, h = 35, i = 23,
    j = 36, k = 37, l = 38, m = 50, n = 49, o = 24, p = 25, q = 16, r = 19,
    s = 31, t = 20, u = 22, v = 47, w = 17, x = 45, y = 21, z = 44,
}

--[[ The modifiers, which have to be sent as keys of their own: OpenOS answers isControlDown() out
of the set of codes it believes are held down, and that set is built from key_down and key_up.
@date 2026-09-17 02:30 ]]
local OC_MODIFIER = {
    {"ImGuiKey_LeftCtrl", 29}, {"ImGuiKey_RightCtrl", 157},
    {"ImGuiKey_LeftShift", 42}, {"ImGuiKey_RightShift", 54},
    {"ImGuiKey_LeftAlt", 56}, {"ImGuiKey_RightAlt", 184},
}

--[[ @brief The place and break tools, and the one key that changes a cell in place.
-- |
-- | Core: left click breaks what the crosshair is on and right click places a computer case against
-- | it, which is the pair the milestone asked for. `f` is the third, and it is here to make the
-- | reacting-cell mechanism visible: it writes `cell.state`, and the block is redrawn with its lit
-- | textures on the next frame without this function telling the renderer anything at all.
-- |
-- | Nothing fires while ImGui has the mouse, so clicking a button in the panel does not also punch
-- | a hole in the world behind it.
-- |
-- | @param st  state - the world state; its `target` must already be this frame's
-- |
-- | @date 2026-09-16 16:00
--]]
local function handle_tools(st)
    if vc.ImGui_WantCaptureMouse() then
        return
    end

    local ctrl = vc.ImGui_IsKeyDown("ImGuiKey_LeftCtrl") or vc.ImGui_IsKeyDown("ImGuiKey_RightCtrl")
    local t = st.target

    -- Ctrl turns the two buttons from building tools into ways of touching what is already there.
    -- The author reserved the modifier for exactly this on 2026-09-16.
    if ctrl then
        if vc.ImGui_IsMouseClicked("ImGuiMouseButton_Right", false) and t and t.cell then
            if t.cell.kind == blocks.KIND.CASE then
                machines.toggle(t.cell, st.world, settings.get("minecraft_path") or "")
            elseif t.cell.kind == blocks.KIND.SCREEN then
                focus = t.cell
                -- The pointer comes back, because a focused screen is a terminal rather than a
                -- view: there is a cursor to place and text to select.
                vc.mouse_capture(false)
            elseif t.cell.kind == blocks.KIND.CHEST then
                chest = t.cell
                vc.mouse_capture(false)
            end
        end
        return
    end

    if vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false) then
        world.break_at(st)
    end
    if vc.ImGui_IsMouseClicked("ImGuiMouseButton_Right", false) then
        TOOLS[selected].place(st)
    end

    if not vc.ImGui_WantCaptureKeyboard() and vc.ImGui_IsKeyPressed("ImGuiKey_F", false) then
        if t and t.cell then
            -- The whole of "modifications on them make them react": one assignment.
            if t.cell.state == blocks.STATE.OFF then
                t.cell.state = blocks.STATE.ON
            else
                t.cell.state = blocks.STATE.OFF
            end
        end
    end
end

--[[ @brief One frame of being inside a screen rather than looking at one.
-- |
-- | Core: while a screen is focused the world stops taking input. The camera does not move, the
-- | tools do not fire, and every character typed is meant for the machine behind the screen. Escape
-- | is the way out, and it is the only key this layer keeps for itself.
-- |
-- | Keys are read the way ImGui offers them: `input_queue_chars` for what was typed, which already
-- | accounts for layout and modifiers, and the key tables for the ones that produce no character.
-- | They become `key_down` and `clipboard`-shaped signals for the machine - the same names
-- | OpenComputers uses - so the guest needs no special case for being driven by a person.
-- |
-- | @param st  state
-- | @return boolean - whether the focus is still held afterwards
-- |
-- | @date 2026-09-16 23:30
--]]
local function handle_focus(st)
    if not focus then
        return false
    end
    -- A screen that was broken while being looked at stops being a place to stand.
    if not focus:placed() then
        focus = nil
        vc.mouse_capture(true)
        return false
    end

    if vc.ImGui_IsKeyPressed("ImGuiKey_Escape", false) then
        focus = nil
        -- Stepping out of a screen puts you back where you were - looking around, not holding a
        -- loose cursor and having to press tab to carry on.
        vc.mouse_capture(true)
        return false
    end

    -- The modifiers first, as keys in their own right. Without these a program can never see a
    -- control combination at all, because isControlDown() reads the set of held codes.
    for _, mod in ipairs(OC_MODIFIER) do
        if vc.ImGui_IsKeyPressed(mod[1], false) then
            machines.send_key(st.world, focus, 0, mod[2], true)
        end
        if vc.ImGui_IsKeyReleased(mod[1]) then
            machines.send_key(st.world, focus, 0, mod[2], false)
        end
    end

    local ctrl = vc.ImGui_IsKeyDown("ImGuiKey_LeftCtrl") or vc.ImGui_IsKeyDown("ImGuiKey_RightCtrl")

    if ctrl then
        -- A control combination reaches ImGui as no character whatsoever, so the character is made
        -- here the way a terminal does - the letter's place in the alphabet - and sent with the
        -- key's own code, which is what `code == keyboard.keys.d` compares against.
        for letter, code in pairs(OC_LETTER) do
            local key = "ImGuiKey_" .. letter:upper()
            if vc.ImGui_IsKeyPressed(key, false) then
                machines.send_key(st.world, focus, string.byte(letter) - 96, code, true)
            end
            if vc.ImGui_IsKeyReleased(key) then
                machines.send_key(st.world, focus, 0, code, false)
            end
        end
    else
        -- Ordinary typing needs BOTH halves: the character, which ImGui already has the layout and
        -- the shift state for, and the key code, which ImGui's character queue does not carry.
        --
        -- They are paired by order. Everything pressed this frame is collected in table order and
        -- lined up with the characters that arrived, which is exact for the one-key-at-a-time case
        -- that typing actually is. A character with no key to pair with still goes through with a
        -- code of zero - it types, it just cannot drive a keymap.
        local codes = {}
        for _, k in ipairs(OC_CHAR_KEY) do
            if vc.ImGui_IsKeyPressed(k[1], true) then
                codes[#codes + 1] = k[2]
            end
        end

        local chars = vc.ImGui_input_queue_chars()
        for i, ch in ipairs(chars) do
            local code = codes[i] or 0
            machines.send_key(st.world, focus, ch, code, true)
            machines.send_key(st.world, focus, ch, code, false)
        end
    end

    -- The keys that produce no character of their own, with the codes OpenOS expects for them.
    local specials = {
        {"ImGuiKey_Enter", 13, 28}, {"ImGuiKey_KeypadEnter", 13, 28},
        {"ImGuiKey_Backspace", 8, 14}, {"ImGuiKey_Tab", 9, 15},
        {"ImGuiKey_UpArrow", 0, 200}, {"ImGuiKey_DownArrow", 0, 208},
        {"ImGuiKey_LeftArrow", 0, 203}, {"ImGuiKey_RightArrow", 0, 205},
        {"ImGuiKey_Home", 0, 199}, {"ImGuiKey_End", 0, 207},
        {"ImGuiKey_Delete", 0, 211}, {"ImGuiKey_PageUp", 0, 201},
        {"ImGuiKey_PageDown", 0, 209}, {"ImGuiKey_Insert", 0, 210},
    }
    for _, k in ipairs(specials) do
        if vc.ImGui_IsKeyPressed(k[1], true) then
            machines.send_key(st.world, focus, k[2], k[3], true)
            machines.send_key(st.world, focus, k[2], k[3], false)
        end
    end

    return true
end

--[[ @brief Reads the configuration and the saved world, and gets the view ready.
-- |
-- | The order matters in one place: the renderer is initialised with the Minecraft path from the
-- | settings, so the first atlas is built from the real textures when there are any, rather than
-- | being built from stand-ins and replaced a frame later.
-- |
-- | @return number - zero; main.cpp logs anything else
-- |
-- | @date 2026-09-16 16:00
--]]
function test_init()
    settings.load(SETTINGS_PATH)

    vc.render_init(settings.get("minecraft_path") or "",
            settings.get("minecraft_jar") or "")

    state = world.new()
    -- The camera goes first, so a saved one replaces it rather than the other way round: load()
    -- sets the camera when the file carried one and says so through `camera_restored`.
    camera.init(settings)
    world.load(state, WORLD_PATH)
    -- After the world, because a disk is restored onto the machine of the case it belongs to and
    -- the cases have to exist first.
    machines.load_disks(state, DISKS_PATH)
    -- The author asked on 2026-09-16 for the simulator to open already looking around, rather than
    -- with a loose cursor waiting for a tab.
    vc.mouse_capture(true)

    if not state.camera_restored then
        camera.init(settings)
    end
    vc.cam_set_fov(settings.get("fov") or 70.0)
    last_time = vc.app_time()
    return 0
end

--[[ @brief One frame: input, then the world, then the interface.
-- |
-- | The order within the frame is deliberate. The camera moves first, then the ray is cast from
-- | where it ended up, then the tools act on what that ray found - so a click lands on what the
-- | crosshair was over at the moment it was pressed, not one frame behind. The 3D pass goes out
-- | after that, and the ImGui calls last; main.cpp clears the buffers before this runs and renders
-- | ImGui's draw data after it returns, so the panel lands on top of the world.
-- |
-- | @return number - zero
-- |
-- | @date 2026-09-16 16:00
--]]
function test_draw()
    local now = vc.app_time()
    local dt = now - last_time
    last_time = now
    -- A frame that took absurdly long - a drag of the window, a breakpoint - would otherwise
    -- teleport the camera across the map on the frame after it.
    if dt > 0.1 then
        dt = 0.1
    end
    if dt > 0 then
        fps = fps * 0.9 + (1.0 / dt) * 0.1
    end

    if vc.ImGui_IsKeyPressed("ImGuiKey_Tab", false) and not vc.ImGui_WantCaptureKeyboard() then
        camera.toggle_capture()
    end

    -- Choosing what to place: the number keys pick a slot outright, the wheel steps through them.
    if not vc.ImGui_WantCaptureKeyboard() then
        -- One through nine, then zero for the tenth, the way a row of number keys actually
        -- reads. Building the name from the index alone asked ImGui for a key called
        -- "ImGuiKey_10" as soon as there were ten things to place.
        for i = 1, math.min(#TOOLS, 10) do
            local name = (i == 10) and "ImGuiKey_0" or ("ImGuiKey_" .. i)
            if vc.ImGui_IsKeyPressed(name, false) then selected = i end
        end
    end
    if not vc.ImGui_WantCaptureMouse() then
        local wheel = vc.ImGui_GetMouseWheel()
        if wheel ~= 0 then
            selected = (selected - 1 - (wheel > 0 and 1 or -1)) % #TOOLS + 1
        end
    end
    -- Ctrl and Q checked apart rather than as a chord string, because the chord form's spelling
    -- is not something this project has verified against the binding's flag parser.
    --
    -- Not while a screen is focused: ctrl belongs to the terminal there, and quitting the whole
    -- simulator because someone reached for a shell shortcut would be a poor trade. Escape is the
    -- way out of a screen, and it always works.
    local ctrl = vc.ImGui_IsKeyDown("ImGuiKey_LeftCtrl") or vc.ImGui_IsKeyDown("ImGuiKey_RightCtrl")
    if ctrl and not focus and vc.ImGui_IsKeyPressed("ImGuiKey_Q", false) then
        vc.app_quit()
    end


    -- An open chest takes the frame the same way a focused screen does: no flying, no building,
    -- and escape closes it. It is drawn further down, as a window rather than a panel.
    if chest then
        if not chest:placed() or vc.ImGui_IsKeyPressed("ImGuiKey_Escape", false) then
            chest = nil
            vc.mouse_capture(true)
        end
    end

    -- A focused screen swallows the frame's input: no flying, no aiming, no building.
    local focused = handle_focus(state) or chest ~= nil
    if not focused then
        camera.update(settings, dt)
        world.aim(state)
        handle_tools(state)
    end

    machines.step_all(state.world)

    -- The frame goes on the cell the ray struck, and the sphere on the cell a click would fill.
    -- Together they answer the two questions aiming raises: what am I pointing at, and where would
    -- the block land. The ground has no cell to frame, so it gets the sphere alone.
    local t = focused and nil or state.target
    if t and not t.is_ground then
        vc.render_highlight(t.x, t.y, t.z)
    else
        vc.render_highlight_off()
    end

    if t then
        local p = t.place_at
        local free = state.world:get(p[1], p[2], p[3]) == nil
        -- Centred on the point the ray struck, so the ball cuts into the face rather than hanging
        -- in the air in front of it - half of it inside the surface, half of it out. It shrinks
        -- when the cell behind that face is already taken, which is the one case where a click
        -- does nothing.
        vc.render_marker(t.hit[1], t.hit[2], t.hit[3], free and 0.14 or 0.06)
    else
        vc.render_marker_off()
    end

    local disp = vc.ImGui_GetDisplaySize()
    vc.render_world(state.world, math.floor(disp.x), math.floor(disp.y))

    if chest then
        ui.chest(chest)
    elseif focused then
        ui.screen_focus(state.world, focus)
    else
        ui.crosshair()
        ui.hotbar(TOOLS, selected)
        -- The console view follows the crosshair: aiming at a screen opens it, looking away shuts
        -- it again.
        ui.miniscreen(state.world, t and t.cell or nil)

        -- The settings window is deliberately NOT drawn while a screen is focused. It carries a
        -- text box, and an ImGui text box that has been clicked stays active and EATS the character
        -- queue - the very queue the terminal's own typing is read from. A window that can quietly
        -- swallow every letter has no business being on screen while the point of the screen is to
        -- type into it. ImGui releases an active widget that is not submitted, so simply not
        -- drawing it hands the keyboard back.
        ui.panel(state, settings, {fps = fps, captured = vc.mouse_captured()})
    end
    return 0
end

--[[ @brief Writes the world and the settings back out on the way to exit.
-- |
-- | The world is saved only when `autosave` is on, because a session spent experimenting is not
-- | always one worth keeping; the settings are saved whenever something changed them, since a
-- | setting is an expressed preference either way.
-- |
-- | @return number - zero
-- |
-- | @date 2026-09-16 16:00
--]]
function test_shutdown()
    if state and settings.get("autosave") then
        world.save(state, WORLD_PATH)
        machines.save_disks(state, DISKS_PATH)
    end
    if settings.dirty() then
        settings.save(SETTINGS_PATH)
    end
    return 0
end
