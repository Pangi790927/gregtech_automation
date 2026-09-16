--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | crosshair()                              -> nothing
-- |     Draws the aiming mark in the middle of the window.
-- |
-- | hotbar(tools: table, selected: number)   -> nothing
-- |     The selector across the bottom: the chosen thing in the middle,
-- |     its neighbours flanking it, the wheel moving between them.
-- |
-- | terminal_panel(w, screen, x0, y0, x1, y1, hint) -> nothing
-- |     THE ONE RENDERER for a screen's console, into a given rectangle.
-- |
-- | miniscreen(w: world, cell: cell | nil)   -> nothing
-- |     That panel, three sevenths of the window wide, on the right,
-- |     following the crosshair.
-- |
-- | screen_focus(w: world, screen: cell)     -> nothing
-- |     The same panel at the size of the window, for a focused screen.
-- |
-- | block_model(kind, cx, cy, size, alpha)   -> nothing
-- |     One block drawn at an angle, textured from the world atlas.
-- |
-- | draw_grid(lines, x, y, w, h, cursor)     -> nothing
-- |     A screen's grid, all of it, sized to fit the room given, with the
-- |     cursor drawn as a caret where the terminal put it.
-- |
-- | chest(cell: cell | nil)                  -> boolean
-- |     The chest window: its slots, and a way to put items in by hand.
-- |
-- | panel(state: state, settings: table, info: table) -> nothing
-- |     The one window: what the crosshair is on, where the textures came
-- |     from, the controls, and the few settings worth changing while the
-- |     simulator is running.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     mc_path_buf
-- |
-- | @date 2026-09-16 16:00
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local blocks = require("blocks")
local world = require("world")
local machines = require("machines")

local ui = {}

--[[ The Minecraft path as it is being typed. Held across frames because an ImGui text box hands
back the whole string every frame and has nowhere of its own to keep it. Seeded on the first draw
from the settings, then owned by the box until Apply is pressed. @date 2026-09-16 ]]
local mc_path_buf = nil

--[[ How many keys have been handed to a machine since the simulator started. Shown in the focused
view, because a person looking at a terminal that will not type needs to know whether the keys are
leaving this side at all. @date 2026-09-17 03:30 ]]
ui.keys_sent = 0

--[[ @brief An OpenComputers colour, which is plain 24 bit red-green-blue, as the packed value ImGui
-- | wants, which puts the channels the other way round and carries an alpha.
-- | @date 2026-09-17 04:30 ]]
local function oc_colour(v)
    v = math.floor(v or 0)
    local r = (v >> 16) & 0xff
    local g = (v >> 8) & 0xff
    local b = v & 0xff
    return 0xff000000 | (b << 16) | (g << 8) | r
end

--[[ @brief Draws the aiming mark at the centre of the window.
-- |
-- | Two short strokes with a gap in the middle rather than a dot, so it stays visible against both
-- | a bright sky and a dark block face without needing to know which is behind it.
-- |
-- | @date 2026-09-16 16:00
--]]
function ui.crosshair()
    vc.ImGui_SetDrawForeground(true)
    local disp = vc.ImGui_GetDisplaySize()
    local cx = disp.x * 0.5
    local cy = disp.y * 0.5
    local arm = 9
    local gap = 3
    local colour = 0xddffffff

    vc.ImGui_AddLine({x = cx - arm, y = cy}, {x = cx - gap, y = cy}, colour, 1.5)
    vc.ImGui_AddLine({x = cx + gap, y = cy}, {x = cx + arm, y = cy}, colour, 1.5)
    vc.ImGui_AddLine({x = cx, y = cy - arm}, {x = cx, y = cy - gap}, colour, 1.5)
    vc.ImGui_AddLine({x = cx, y = cy + gap}, {x = cx, y = cy + arm}, colour, 1.5)
    vc.ImGui_SetDrawForeground(false)
end

--[[ @brief Draws a block as a small angled model, textured from the world atlas.
-- |
-- | Core: three faces of a cube seen from above and to one side - top, left and right - each drawn
-- | as an image quad with the real texture the block wears in the world. The author asked for this
-- | on 2026-09-16: "draw the 3d model in the bottom scrol menu, draw it at an angle so it is clear
-- | what it is".
-- |
-- | It is a projection, not a render: the three parallelograms are written out directly rather than
-- | put through a matrix. ImGui interpolates a texture across a quad's two triangles, which is
-- | exact for a parallelogram, so an affine projection like this one is the one case where the 2D
-- | layer can draw a textured solid correctly and cheaply. Anything with perspective would need a
-- | framebuffer and a second render pass for a picture 48 pixels across.
-- |
-- | Flat things - a wire, a keyboard - have no cube to show, so they are drawn as the top face
-- | alone, which is what they actually look like lying on the ground.
-- |
-- | @param kind   number - the kind whose textures to use
-- | @param cx     number - the centre of the model, horizontally
-- | @param cy     number - the centre of the model, vertically
-- | @param size   number - roughly the width of the drawn cube, in pixels
-- | @param alpha  number - 0 to 255, applied to the whole model
-- |
-- | @date 2026-09-16 22:00
--]]
function ui.block_model(kind, cx, cy, size, alpha)
    local tex = vc.render_atlas_id()
    if tex == 0 then
        return
    end

    -- A dimetric view: half-width across, a quarter-height of rise per step. The same proportions
    -- an isometric tile uses, which is what makes the shape read as a cube without perspective.
    local hw = size * 0.5
    local hh = size * 0.25
    local tall = size * 0.52

    local function shade(mul)
        local v = math.floor(255 * mul)
        return (alpha << 24) | (v << 16) | (v << 8) | v
    end

    local function quad(role, p1, p2, p3, p4, mul)
        local uv = vc.render_tile_uv(kind, blocks.STATE.OFF, role)
        -- uv arrives as {u0, v0, u1, v1}; the four corners walk it clockwise from the top left.
        vc.ImGui_AddImageQuad(tex, p1, p2, p3, p4,
                {x = uv[1], y = uv[2]}, {x = uv[3], y = uv[2]},
                {x = uv[3], y = uv[4]}, {x = uv[1], y = uv[4]}, shade(mul))
    end

    -- The four corners of the top face, then the two skirt corners that fall from it.
    local t_top   = {x = cx,      y = cy - tall * 0.5 - hh}
    local t_right = {x = cx + hw, y = cy - tall * 0.5}
    local t_bot   = {x = cx,      y = cy - tall * 0.5 + hh}
    local t_left  = {x = cx - hw, y = cy - tall * 0.5}
    local b_right = {x = cx + hw, y = cy - tall * 0.5 + tall}
    local b_bot   = {x = cx,      y = cy - tall * 0.5 + hh + tall}
    local b_left  = {x = cx - hw, y = cy - tall * 0.5 + tall}

    if blocks.is_flat(kind) then
        quad(3, t_left, t_top, t_right, t_bot, 1.0)
        return
    end

    -- Top first, then the two walls. The brightness matches the world's own face shading, so a
    -- block in the menu and the same block on the ground read as the same object.
    quad(2, t_left, t_top, t_right, t_bot, 1.0)
    quad(3, t_left, t_bot, b_bot, b_left, 0.74)
    quad(0, t_bot, t_right, b_right, b_bot, 0.88)
end

--[[ @brief The selector across the bottom: what a right click would place.
-- |
-- | Core: the selected thing sits in the middle, large and named; its neighbours flank it, smaller
-- | and dimmed, so the wheel's effect is visible before it is used. The author asked for this shape
-- | on 2026-09-16: "I want to see the currently selected object type in the center
-- | and a wheel would go to the next or previous ones".
-- |
-- | The list wraps, so the neighbours are real even with only two entries and the wheel never dead
-- | ends.
-- |
-- | Drawn on the FOREGROUND list. A window draw list is clipped to its window, and outside any
-- | Begin the current window is ImGui's implicit debug one - which is why an earlier version
-- | of this bar drew correctly and was then clipped away to nothing.
-- |
-- | Each entry shows the block itself, drawn at an angle out of the same atlas the world uses, so
-- | the menu and the world cannot disagree about what a thing looks like.
-- |
-- | @param tools     table - a list of `{name = , colour = }`, in wheel order
-- | @param selected  number - the index in the middle
-- |
-- | @date 2026-09-16 20:00
--]]
function ui.hotbar(tools, selected)
    local disp = vc.ImGui_GetDisplaySize()
    local cx = disp.x * 0.5
    local base = disp.y - 30

    vc.ImGui_SetDrawForeground(true)

    local function slot(index, offset, size, alpha)
        local tool = tools[index]
        if not tool then
            return
        end
        local x = cx + offset
        local y = base - size
        local fill = (alpha << 24) | 0x181818
        local edge = (alpha << 24) | 0xaaaaaa

        vc.ImGui_AddRectFilled({x = x - size / 2, y = y}, {x = x + size / 2, y = y + size},
                fill, 5)
        vc.ImGui_AddRect({x = x - size / 2, y = y}, {x = x + size / 2, y = y + size},
                edge, 5, 1.5)

        -- The block itself, angled, rather than a swatch standing in for it.
        ui.block_model(tool.kind, x, y + size * 0.52, size * 0.78, alpha)
    end

    local n = #tools
    local prev = (selected - 2) % n + 1
    local next_i = selected % n + 1

    slot(prev, -74, 40, 0x66)
    slot(next_i, 74, 40, 0x66)
    slot(selected, 0, 64, 0xee)

    local label = tools[selected] and tools[selected].name or ""
    local size = vc.ImGui_CalcTextSize(label)
    vc.ImGui_AddText({x = cx - size.x * 0.5, y = base + 4}, 0xffffffff, label)

    vc.ImGui_SetDrawForeground(false)
end

--[[ @brief A terminal panel for one screen, drawn into the rectangle given.
-- |
-- | Core: THE ONE RENDERER. The small view that follows the crosshair and the large one stepped
-- | inside are the same panel at two sizes - same frame, same title, same grid, same colours - so a
-- | screen looks like itself wherever it is being looked at. They were written twice once, and the
-- | small one stopped making sense beside the large one because of it.
-- |
-- | Everything about the size comes from the rectangle. The grid inside picks its own font to fit,
-- | so the same code draws a thumbnail and a full window without knowing which it is.
-- |
-- | @param w       world
-- | @param screen  cell - the screen to show
-- | @param x0      number - the panel's left edge
-- | @param y0      number - its top edge
-- | @param x1      number - its right edge
-- | @param y1      number - its bottom edge
-- | @param hint    string | nil - a note along the bottom right, for the focused view's way out
-- |
-- | @date 2026-09-17 05:00
--]]
function ui.terminal_panel(w, screen, x0, y0, x1, y1, hint)
    local lines, host, is_grid, cursor, runs = machines.screen_output(w, screen)

    vc.ImGui_AddRectFilled({x = x0, y = y0}, {x = x1, y = y1}, 0xf00a0a0a, 6)
    vc.ImGui_AddRect({x = x0, y = y0}, {x = x1, y = y1}, 0xff5f9fd0, 6, 2)

    local p = screen:pos()
    local title
    if host then
        local hp = host:pos()
        title = string.format("screen %d, %d, %d  -  case at %d, %d, %d",
                p[1], p[2], p[3], hp[1], hp[2], hp[3])
    else
        title = string.format("screen %d, %d, %d  -  no computer case", p[1], p[2], p[3])
    end
    vc.ImGui_AddText({x = x0 + 12, y = y0 + 8}, 0xff9ad8ff, title)
    vc.ImGui_AddLine({x = x0 + 8, y = y0 + 26}, {x = x1 - 8, y = y0 + 26}, 0xff3a3a3a, 1)

    -- Where the keys are going. "Nothing appears" has several very different causes and they are
    -- indistinguishable from the outside, so the panel says which one it is.
    local note, colour
    if not host then
        note, colour = "no computer case", 0xffd0a050
    elseif not machines.has_keyboard(w, screen) then
        note, colour = "no keyboard - bolt one onto the screen", 0xffd0a050
    else
        note, colour = string.format("keyboard ok - %d keys sent", ui.keys_sent or 0), 0xff70b070
    end
    local nsize = vc.ImGui_CalcTextSize(note)
    vc.ImGui_AddText({x = x1 - nsize.x - 12, y = y0 + 8}, colour, note)

    local line_h = vc.ImGui_GetFontSize() + 3
    if #lines == 0 then
        vc.ImGui_AddText({x = x0 + 12, y = y0 + 34}, 0xff707070,
                host and "the machine is not running - ctrl+right click the case to start it"
                or "nothing to show")
    elseif is_grid then
        ui.draw_grid(lines, x0 + 10, y0 + 32, (x1 - x0) - 20, (y1 - y0) - 44, cursor, runs)
    else
        -- A boot log, which genuinely does read from the bottom.
        local room = math.floor((y1 - y0 - 46) / line_h)
        local first = math.max(1, #lines - room + 1)
        local row = 0
        for i = first, #lines do
            vc.ImGui_AddText({x = x0 + 12, y = y0 + 34 + row * line_h}, 0xffd8d8d8, lines[i])
            row = row + 1
        end
    end

    if hint then
        local size = vc.ImGui_CalcTextSize(hint)
        vc.ImGui_AddText({x = x1 - size.x - 12, y = y1 - line_h - 6}, 0xff808080, hint)
    end
end

--[[ @brief The console view that follows the crosshair, on the right of the window.
-- |
-- | Three sevenths of the window across, as asked for, and tall enough to keep a screen's own
-- | proportions - an OpenComputers grid is a good deal wider than it is tall, and a panel that
-- | ignored that would squash the text.
-- |
-- | @param w     world
-- | @param cell  cell | nil - the screen being looked at; anything else draws nothing
-- |
-- | @date 2026-09-16 20:00
--]]
function ui.miniscreen(w, cell)
    if not cell or cell.kind ~= blocks.KIND.SCREEN then
        return
    end

    local disp = vc.ImGui_GetDisplaySize()
    local panel_w = math.floor(disp.x * 3 / 7)
    local panel_h = math.floor(panel_w * 0.36) + 38
    local x0 = disp.x - panel_w - 16
    local y0 = 16

    vc.ImGui_SetDrawForeground(true)
    ui.terminal_panel(w, cell, x0, y0, x0 + panel_w, y0 + panel_h, nil)
    vc.ImGui_SetDrawForeground(false)
end

--[[ @brief Draws a screen's grid so that all of it fits, choosing a font size to suit.
-- |
-- | Core: every row is drawn, from the first. A grid has to be shown whole - a full-screen program
-- | puts meaning at the top and the bottom at once, so cropping either end hides something the
-- | program thought it had displayed.
-- |
-- | The size is measured rather than assumed. A candidate is picked from the room available, one
-- | row of the widest possible text is measured at that size, and the result is scaled to fit -
-- | which handles both the column count and whatever font ImGui is actually using, instead of
-- | guessing at an advance width.
-- |
-- | @param lines  {string} - every row of the grid, in order
-- | @param x      number - the left edge to draw from
-- | @param y      number - the top edge
-- | @param w       number - the room available across
-- | @param h       number - the room available down
-- | @param cursor  table | nil - {column, row}, both counted from one; zeroes mean the cursor is
-- |                in the dark half of its blink and nothing is drawn. Only used when there are no
-- |                runs, since a coloured grid already shows the cursor as the inverted cell it is
-- | @param runs    table | nil - per row, a list of {foreground, background, text}; when present
-- |                the grid is drawn in its own colours and `lines` is not used
-- |
-- | @date 2026-09-17 04:00
--]]
function ui.draw_grid(lines, x, y, w, h, cursor, runs)
    local rows = #lines
    if rows == 0 then
        return
    end

    local cols = 0
    for _, l in ipairs(lines) do
        if #l > cols then
            cols = #l
        end
    end
    if cols < 1 then
        cols = 1
    end

    -- A first guess from the vertical room, then corrected by measuring the real width.
    local guess = math.max(5.0, math.min(h / rows - 1.0, 18.0))
    vc.ImGui_PushFont(guess)
    local probe = vc.ImGui_CalcTextSize(string.rep("M", cols))
    vc.ImGui_PopFont()

    local size = guess
    if probe.x > w and probe.x > 0 then
        size = math.max(5.0, guess * (w / probe.x))
    end

    local step = h / rows
    vc.ImGui_PushFont(size)
    local cw = vc.ImGui_CalcTextSize("M").x

    if runs then
        -- Backgrounds first, across the whole grid, then the text over them - so a run's fill can
        -- never land on top of the characters of the run before it.
        for i, row in ipairs(runs) do
            local col = 0
            for _, run in ipairs(row) do
                local text = run[3]
                local bg = math.floor(run[2] or 0)
                if bg ~= 0 then
                    vc.ImGui_AddRectFilled(
                            {x = x + col * cw, y = y + (i - 1) * step},
                            {x = x + (col + #text) * cw, y = y + i * step}, oc_colour(bg), 0)
                end
                col = col + #text
            end
        end
        for i, row in ipairs(runs) do
            local col = 0
            for _, run in ipairs(row) do
                local text = run[3]
                vc.ImGui_AddText({x = x + col * cw, y = y + (i - 1) * step},
                        oc_colour(run[1]), text)
                col = col + #text
            end
        end
    else
        for i, line in ipairs(lines) do
            if line ~= "" then
                vc.ImGui_AddText({x = x, y = y + (i - 1) * step}, 0xffd8d8d8, line)
            end
        end
    end

    -- Only when the colours are not available: with them, the cursor is already visible, because a
    -- terminal draws one by inverting a cell and an inverted cell is a filled background.
    if not runs and cursor and cursor[1] and cursor[1] > 0 and cursor[2] > 0 then
        local cx = x + (cursor[1] - 1) * cw
        local cy = y + (cursor[2] - 1) * step
        vc.ImGui_AddRectFilled({x = cx, y = cy}, {x = cx + cw, y = cy + step}, 0xcc44dd66, 0)
    end

    vc.ImGui_PopFont()
end

--[[ @brief The focused screen: the whole window given over to one machine's console.
-- |
-- | Core: ctrl and a right click on a screen brings the player inside it, and this is what that
-- | looks like - the same terminal panel the crosshair view draws, at the size of the window, with
-- | the world dimmed behind it. Escape leaves.
-- |
-- | The world behind is dimmed rather than hidden, so it stays clear that this is a thing in the
-- | world being looked at closely and not a different mode of the application.
-- |
-- | @param w       world
-- | @param screen  cell - the focused screen
-- |
-- | @date 2026-09-16 23:30
--]]
function ui.screen_focus(w, screen)
    local disp = vc.ImGui_GetDisplaySize()
    local margin = 48

    vc.ImGui_SetDrawForeground(true)
    vc.ImGui_AddRectFilled({x = 0, y = 0}, {x = disp.x, y = disp.y}, 0xb0000000, 0)
    ui.terminal_panel(w, screen, margin, margin, disp.x - margin, disp.y - margin,
            "esc to step back out")
    vc.ImGui_SetDrawForeground(false)
end

--[[ The item being typed into the chest window, held across frames because an ImGui text box
hands back the whole string every frame and has nowhere of its own to keep it.
@date 2026-09-17 06:30 ]]
local chest_name_buf = "minecraft:cobblestone"
local chest_count_buf = "64"

--[[ @brief The chest window: what is inside, and a way to put something in.
-- |
-- | Core: a real ImGui window rather than a heads-up panel, because this one is worked with rather
-- | than glanced at - it has a text box and buttons, and it is opened deliberately with ctrl and a
-- | right click. Nothing is being typed at a machine while it is open, so there is no keyboard to
-- | compete for.
-- |
-- | Putting items in by hand is the point. This is a test bench: a program that moves items around
-- | needs something to move, and until a transposer exists there is nothing else to fill a chest
-- | with. Clicking a full slot empties it again.
-- |
-- | @param cell  cell | nil - the chest; anything else draws nothing
-- | @return boolean - whether the window is still wanted
-- |
-- | @date 2026-09-17 06:30
--]]
function ui.chest(cell)
    if not cell or cell.kind ~= blocks.KIND.CHEST then
        return false
    end
    if not cell:placed() then
        return false
    end

    local inv = blocks.u(cell).inventory
    if not inv then
        inv = {}
        blocks.u(cell).inventory = inv
    end

    local p = cell:pos()
    vc.ImGui_Begin(string.format("chest %d, %d, %d", p[1], p[2], p[3]), 0)

    local used = 0
    for _ in pairs(inv) do
        used = used + 1
    end
    vc.ImGui_Text(string.format("%d of %d slots used", used, blocks.CHEST_SLOTS))
    vc.ImGui_Separator()

    -- Nine across, the way a chest is laid out, so a slot number here means the same thing it
    -- would mean to a program counting slots.
    for i = 1, blocks.CHEST_SLOTS do
        local slot = inv[i]
        local label
        if slot then
            label = string.format("%s x%d##%d", slot.name, slot.count, i)
        else
            label = string.format("-##%d", i)
        end
        if vc.ImGui_Button(label, {x = 118, y = 0}) and slot then
            inv[i] = nil
        end
        if i % 9 ~= 0 then
            vc.ImGui_SameLine(0, -1)
        end
    end

    vc.ImGui_Separator()

    local name = vc.ImGui_InputText("item", chest_name_buf, 64)
    if name[1] then
        chest_name_buf = name[2]
    end
    local count = vc.ImGui_InputText("count", chest_count_buf, 8)
    if count[1] then
        chest_count_buf = count[2]
    end

    if vc.ImGui_Button("put in the first free slot", {x = 0, y = 0}) then
        for i = 1, blocks.CHEST_SLOTS do
            if not inv[i] then
                local n = math.max(1, tonumber(chest_count_buf) or 1)
                inv[i] = {name = chest_name_buf, count = n}
                break
            end
        end
    end
    vc.ImGui_SameLine(0, -1)
    if vc.ImGui_Button("empty it", {x = 0, y = 0}) then
        for i = 1, blocks.CHEST_SLOTS do
            inv[i] = nil
        end
    end

    vc.ImGui_Separator()
    vc.ImGui_Text("esc to close")
    vc.ImGui_End()
    return true
end

--[[ @brief The one interface window.
-- |
-- | Core: it answers the three questions a person actually has while using this - what am I looking
-- | at, are these the real Minecraft textures, and which key does what. The settings it exposes are
-- | the ones worth changing without restarting; everything else lives in the settings file.
-- |
-- | The texture source line is not decoration. Whether the world is drawn from the OpenComputers
-- | jar or from the hand-made stand-ins is invisible from a distance once the shapes are right, and
-- | someone who has just typed a Minecraft path needs to be told plainly whether it worked.
-- |
-- | @param state     state - read for the aim target and the cell count
-- | @param settings  table - read and written; a changed setting is applied immediately
-- | @param info      table - `fps` and `captured`, which main.lua measures and this only reports
-- |
-- | @date 2026-09-16 16:00
--]]
function ui.panel(state, settings, info)
    if mc_path_buf == nil then
        mc_path_buf = settings.get("minecraft_path") or ""
    end

    vc.ImGui_Begin("simulator", 0)

    vc.ImGui_Text(string.format("%.0f fps   %d cells placed", info.fps, state.world:count()))

    local t = state.target
    if not t then
        vc.ImGui_Text("looking at: nothing in reach")
    elseif t.is_ground then
        vc.ImGui_Text(string.format("looking at: the floor, at %d, %d", t.x, t.z))
    else
        vc.ImGui_Text("looking at: " .. blocks.describe(t.cell))
    end

    vc.ImGui_Separator()

    if vc.render_mc_ok() then
        vc.ImGui_Text("textures: from the minecraft instance")
        vc.ImGui_Text(vc.render_mc_source())
    else
        vc.ImGui_Text("textures: hand-drawn stand-ins")
        vc.ImGui_Text("no OpenComputers jar under the path below")
    end

    -- These widgets answer one table, `{changed, value}`: ImGui writes its result through a
    -- pointer, which Lua cannot hand it, so the binding returns the pair instead.
    local typed = vc.ImGui_InputText("minecraft path", mc_path_buf, 512)
    if typed[1] then
        mc_path_buf = typed[2]
    end
    if vc.ImGui_Button("apply path", {x = 0, y = 0}) then
        settings.set("minecraft_path", mc_path_buf)
        vc.render_set_mc_path(mc_path_buf, settings.get("minecraft_jar") or "")
    end

    vc.ImGui_Separator()

    local fov = vc.ImGui_SliderFloat("fov", settings.get("fov") or 70.0, 40.0, 110.0)
    if fov[1] then
        settings.set("fov", fov[2])
        vc.cam_set_fov(fov[2])
    end

    local speed = vc.ImGui_SliderFloat("move speed", settings.get("move_speed") or 9.0, 1.0, 40.0)
    if speed[1] then
        settings.set("move_speed", speed[2])
    end

    local inverted = vc.ImGui_Checkbox("invert look", settings.get("invert_y") or false)
    if inverted[1] then
        settings.set("invert_y", inverted[2])
    end

    vc.ImGui_Separator()

    vc.ImGui_Text(info.captured and "mouse: captured - tab to release"
            or "mouse: free - tab to capture and look around")
    vc.ImGui_Text("wasd moves level, e and q for up and down, shift to go faster")
    vc.ImGui_Text("left click breaks, right click places the selected thing")
    vc.ImGui_Text("the mouse wheel, or 1 to 4, changes what is selected")
    vc.ImGui_Text("the orange ball marks where a placed block would go")
    vc.ImGui_Text("a wire cannot be built on, and breaking takes the wire first")
    vc.ImGui_Text("f toggles the aimed case between off and running")
    vc.ImGui_Text("ctrl+right click a case to start it, a screen to step into it")
    vc.ImGui_Text("ctrl+q quits, saving the world on the way out")

    vc.ImGui_End()
end

return ui
