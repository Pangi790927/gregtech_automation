--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | init(settings: table)                    -> nothing
-- |     Places the camera above the middle of an empty map, looking down
-- |     at it, and applies the field of view from the settings.
-- |
-- | update(settings: table, dt: number)      -> nothing
-- |     One frame of flying: turn with the mouse while the pointer is
-- |     captured, move with the keys. Does nothing while an ImGui widget
-- |     wants the keyboard, so typing in a box never walks the camera.
-- |
-- | toggle_capture()                         -> boolean
-- |     Grabs the pointer, or gives it back. Answers the new state.
-- |
-- | eye()                                    -> x, y, z
-- | look()                                   -> dx, dy, dz
-- |     Where the camera is and the unit vector it looks along - the two
-- |     halves of the ray world.lua casts at the crosshair. Both come
-- |     from C++, which owns the yaw and pitch convention.
-- |
-- | @date 2026-09-16 16:00
-- | ===============================================================================================
--]]

local vc = require("virt_composer")

local camera = {}

--[[ @brief Puts the camera somewhere an empty map is worth looking at.
-- |
-- | Above the middle of the floor and tilted down, so the first thing on screen is the grid rather
-- | than the sky - an empty world seen edge on is indistinguishable from a broken renderer, and the
-- | first run of a fresh build should not have to answer that question.
-- |
-- | @param settings  table - read for `fov`
-- |
-- | @date 2026-09-16 16:00
--]]
function camera.init(settings)
    vc.cam_set(32.0, 14.0, 46.0, 0.0, -0.45)
    vc.cam_set_fov(settings.get("fov") or 70.0)
end

--[[ @brief Grabs the mouse for looking around, or releases it.
-- |
-- | While captured the pointer is hidden and unbounded, which is what a first-person view needs;
-- | while released the cursor is an ordinary cursor and ImGui gets it back. The interface is usable
-- | in both states, so this is a convenience rather than a mode the user can get stuck in.
-- |
-- | @return boolean - whether the pointer is captured after the call
-- |
-- | @date 2026-09-16 16:00
--]]
function camera.toggle_capture()
    local now = not vc.mouse_captured()
    vc.mouse_capture(now)
    return now
end

--[[ @brief Where the camera sits. @date 2026-09-16 16:00 ]]
function camera.eye()
    local c = vc.cam_get()
    return c[1], c[2], c[3]
end

--[[ @brief The unit vector the camera looks along.
-- |
-- | Asked of C++ rather than rebuilt here from yaw and pitch, and deliberately: the view matrix is
-- | built from this same call, so the ray the crosshair casts and the picture on screen cannot
-- | drift apart. Two copies of a trigonometric convention is one copy too many.
-- |
-- | @return number, number, number
-- |
-- | @date 2026-09-16 16:00
--]]
function camera.look()
    local f = vc.cam_forward()
    return f[1], f[2], f[3]
end

--[[ @brief One frame of flying.
-- |
-- | Core: the mouse turns the view while the pointer is captured, and the keys move it - W and S
-- | along the heading, A and D across it, E and Q straight up and down. Holding shift moves at the
-- | faster of the two speeds. Every distance is multiplied by `dt`, so the camera travels at the
-- | same rate whatever the frame rate is doing.
-- |
-- | Height is on E and Q rather than space and control, which the author reserved on 2026-09-16 for
-- | a modifier: ctrl with a click will mean interacting with the world rather than building in it.
-- |
-- | Height is the keys' business alone. W follows where the camera is pointing on the ground plane
-- | and never its tilt, so looking down at the floor and walking forward stays level instead of
-- | flying into it; E and Q are the only things that change height. Asked for by the author,
-- | 2026-09-16: "w should only go forward, not up/down".
-- |
-- | The heading is taken from the right vector rather than by flattening the look vector. The two
-- | agree everywhere they are both defined, but flattening collapses to nothing when the view is
-- | straight up or straight down, and that is exactly when a person is most likely to be holding W.
-- | Turning the right vector a quarter circle has no such case, and still leaves C++ owning the one
-- | definition of the yaw convention.
-- |
-- | The keyboard is left alone entirely while ImGui wants it, so typing a path into the settings
-- | box does not also fly across the map.
-- |
-- | @param settings  table - read for `mouse_speed`, `move_speed`, `move_speed_fast`, `invert_y`
-- | @param dt        number - seconds since the previous frame
-- |
-- | @date 2026-09-16 16:00
--]]
function camera.update(settings, dt)
    local c = vc.cam_get()
    local x, y, z, yaw, pitch = c[1], c[2], c[3], c[4], c[5]

    if vc.mouse_captured() then
        local d = vc.mouse_delta()
        local speed = settings.get("mouse_speed") or 0.0032
        yaw = yaw - d[1] * speed
        local dy = d[2] * speed
        if settings.get("invert_y") then
            dy = -dy
        end
        pitch = pitch - dy
    end

    if not vc.ImGui_WantCaptureKeyboard() then
        local fast = vc.ImGui_IsKeyDown("ImGuiKey_LeftShift")
                or vc.ImGui_IsKeyDown("ImGuiKey_RightShift")
        local speed = fast and (settings.get("move_speed_fast") or 26.0)
                or (settings.get("move_speed") or 9.0)
        local step = speed * dt

        -- Taken after the turn above, so a frame that both turns and moves goes where it is now
        -- pointing rather than where it pointed a moment ago.
        vc.cam_set(x, y, z, yaw, pitch)
        local r = vc.cam_right()
        -- The heading: the right vector turned a quarter circle in the ground plane. Always a unit
        -- vector, whatever the pitch is doing.
        local hx, hz = r[3], -r[1]

        local fwd = 0
        local side = 0
        local rise = 0
        if vc.ImGui_IsKeyDown("ImGuiKey_W") then fwd = fwd + 1 end
        if vc.ImGui_IsKeyDown("ImGuiKey_S") then fwd = fwd - 1 end
        if vc.ImGui_IsKeyDown("ImGuiKey_D") then side = side + 1 end
        if vc.ImGui_IsKeyDown("ImGuiKey_A") then side = side - 1 end
        if vc.ImGui_IsKeyDown("ImGuiKey_E") then rise = rise + 1 end
        if vc.ImGui_IsKeyDown("ImGuiKey_Q") then rise = rise - 1 end

        x = x + (hx * fwd + r[1] * side) * step
        y = y + rise * step
        z = z + (hz * fwd + r[3] * side) * step
    end

    vc.cam_set(x, y, z, yaw, pitch)
end

return camera
