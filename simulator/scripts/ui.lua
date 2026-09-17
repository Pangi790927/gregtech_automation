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
-- | minichest(cell) / minitank(cell)         -> nothing
-- |     The same idea as miniscreen, for the two things that hold
-- |     something: look at a chest or a tank and it says what is in it.
-- |
-- | chest(cell: cell | nil)                  -> boolean
-- |     The chest window: its slots, and a way to put items in by hand.
-- |
-- | tank(cell: cell | nil)                   -> boolean
-- |     The liquid tank window: which GregTech fluid it holds, and how
-- |     many litres of it. The fluids offered are read out of the game.
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
                host and "the machine is not running - right click the case to start it"
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
-- | Core: a right click on a screen brings the player inside it, and this is what that
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

--[[ The item catalogue, asked for once, and which slot of which chest is being edited.
-- |
-- | The same arrangement the tank panel uses and for the same reasons: the boxes hold TEXT while
-- | they are being typed in, so they are seeded when a different chest or slot is opened and own
-- | themselves after that. @date 2026-09-17 18:00 ]]
local item_ids = nil
local item_labels = nil
local item_damage = nil
local item_filter = ""

--[[ The filter's answer, kept until the filter changes.
-- |
-- | Ten thousand names lower-cased and searched EVERY FRAME is what made the picker crawl. The
-- | search only changes when somebody types in it, so the answer is worked out then and reused
-- | until they do. @date 2026-09-17 20:00 ]]
local item_hits = nil
local item_hits_for = nil
local chest_at = nil
local chest_slot = 1
local chest_name_buf = ""
local chest_count_buf = "1"
--[[ The variant and the game's name for what is being put in a slot. Typed names have neither,
which is right: an id typed by hand is whatever was typed. @date 2026-09-17 21:00 ]]
local chest_damage = 0
local chest_label = ""

--[[ @brief Forgets the item catalogue, so the next window rebuilds it. @date 2026-09-17 18:00 ]]
function ui.forget_items()
    item_ids = nil
    item_labels = nil
    item_damage = nil
end

--[[ @brief Draws one item's picture at the cursor, and leaves the cursor past it.
-- |
-- | Out of the interface's own atlas rather than the world's - see build_item_atlas in
-- | render_composer.h for why the items have a texture of their own.
-- |
-- | @param id    string - the item id
-- | @param size  number - pixels on a side
-- |
-- | @date 2026-09-17 18:00
--]]
local function item_icon_at(id, damage, x, y, size)
    local uv = vc.render_item_uv(id or "", damage or 0)
    if uv[3] > uv[1] then
        vc.ImGui_AddImageQuad(vc.render_item_atlas_id(),
                {x = x, y = y}, {x = x + size, y = y},
                {x = x + size, y = y + size}, {x = x, y = y + size},
                {x = uv[1], y = uv[2]}, {x = uv[3], y = uv[2]},
                {x = uv[3], y = uv[4]}, {x = uv[1], y = uv[4]}, 0xffffffff)
        return true
    end
    return false
end

--[[ @brief The same, at the cursor, which it then steps past. For a list. @date 2026-09-17 18:00 ]]
local function item_icon(id, damage, size)
    local at = vc.ImGui_GetCursorScreenPos()
    if not item_icon_at(id, damage, at.x, at.y, size) then
        vc.ImGui_AddQuadFilled({x = at.x, y = at.y}, {x = at.x + size, y = at.y},
                {x = at.x + size, y = at.y + size}, {x = at.x, y = at.y + size}, 0xff383838)
    end
    vc.ImGui_Dummy({x = size, y = size})
end

--[[ @brief The frame every mini view is drawn in: the panel, its border and its title.
-- |
-- | One function so a chest, a tank and a screen all look like the same kind of thing when the
-- | crosshair finds them. Answers where the contents may be drawn.
-- |
-- | @param title   string - the line across the top
-- | @param height  number - how tall the panel should be
-- | @return number, number, number, number - the left, top, right and bottom of the room inside
-- |
-- | @date 2026-09-17 19:00
--]]
local function mini_frame(title, height)
    local disp = vc.ImGui_GetDisplaySize()
    local panel_w = math.floor(disp.x * 3 / 7)
    local x0, y0 = disp.x - panel_w - 16, 16
    local x1, y1 = x0 + panel_w, y0 + height

    vc.ImGui_AddRectFilled({x = x0, y = y0}, {x = x1, y = y1}, 0xf00a0a0a, 6)
    vc.ImGui_AddRect({x = x0, y = y0}, {x = x1, y = y1}, 0xff5f9fd0, 6, 2)
    vc.ImGui_AddText({x = x0 + 12, y = y0 + 8}, 0xff9ad8ff, title)
    vc.ImGui_AddLine({x = x0 + 8, y = y0 + 26}, {x = x1 - 8, y = y0 + 26}, 0xff3a3a3a, 1)

    return x0 + 12, y0 + 34, x1 - 12, y1 - 10
end

--[[ @brief What is in the chest the crosshair is on, without opening it.
-- |
-- | Core: the same idea as the console view - look at a thing and it tells you about itself. A
-- | chest read through a transposer is usually being watched rather than edited, and opening it
-- | every time to see whether a program has moved anything is a poor way to watch.
-- |
-- | Read-only on purpose. The window a right click opens is where a chest is changed; this one
-- | takes no input at all, so walking past a chest cannot disturb it.
-- |
-- | @param cell  cell | nil - whatever is under the crosshair
-- |
-- | @date 2026-09-17 19:00
--]]
function ui.minichest(cell)
    if not cell or cell.kind ~= blocks.KIND.CHEST or not cell:placed() then
        return
    end

    local n = cell:inv_size()
    local used = 0
    for i = 1, n do
        if cell:inv_get(i)[2] > 0 then
            used = used + 1
        end
    end

    vc.ImGui_SetDrawForeground(true)

    local p = cell:pos()
    local rows = math.max(1, math.ceil(n / 9))
    local x0, y0, x1, y1 = mini_frame(string.format(
            "chest %d, %d, %d  -  %d of %d slots used", p[1], p[2], p[3], used, n),
            34 + rows * 38 + 12)

    -- Nine across, sized to whatever room the panel has, so the grid reads the way the big one
    -- does rather than being a different shape at a different size.
    local cellw = math.min(36, math.floor((x1 - x0) / 9) - 4)
    for i = 1, n do
        local slot = cell:inv_get(i)
        local col, row = (i - 1) % 9, math.floor((i - 1) / 9)
        local x = x0 + col * (cellw + 4)
        local y = y0 + row * (cellw + 2)

        vc.ImGui_AddRectFilled({x = x, y = y}, {x = x + cellw, y = y + cellw}, 0x30ffffff, 3)
        if slot[2] > 0 then
            item_icon_at(slot[1], slot[3], x + 2, y + 2, cellw - 4)
            local txt = tostring(slot[2])
            local sz = vc.ImGui_CalcTextSize(txt)
            vc.ImGui_AddText({x = x + cellw - 2 - sz.x, y = y + cellw - 2 - sz.y},
                    0xffffffff, txt)
        end
    end

    vc.ImGui_SetDrawForeground(false)
end

--[[ @brief What is in the tank the crosshair is on, without opening it.
-- |
-- | Shows the fluid, how many litres of it and how full that leaves the tank - the same three
-- | things the configuring window leads with, because they are what you look at a tank to find out.
-- |
-- | @param cell  cell | nil - whatever is under the crosshair
-- |
-- | @date 2026-09-17 19:00
--]]
function ui.minitank(cell)
    if not cell or not blocks.is_tank(cell.kind) or not cell:placed() then
        return
    end

    local held = cell:fluid_get()
    local name, amount, label = held[1], held[2], held[3]
    local cap = cell:fluid_capacity()

    vc.ImGui_SetDrawForeground(true)

    local p = cell:pos()
    local x0, y0, x1, y1 = mini_frame(string.format("%s %d, %d, %d",
            blocks.KIND_NAME[cell.kind] or "tank", p[1], p[2], p[3]), 122)

    if name == "" then
        -- A locked tank says what it is FOR even while it is empty, which is what makes a row of
        -- them readable as a bank rather than as a row of empty boxes.
        local lock = cell:fluid_lock_get()
        if lock[1] ~= "" then
            local tile = vc.render_fluid_tile(lock[1])
            if tile >= 0 then
                local uv = vc.render_tile_uv_at(math.floor(tile))
                vc.ImGui_AddImageQuad(vc.render_atlas_id(),
                        {x = x0, y = y0}, {x = x0 + 40, y = y0},
                        {x = x0 + 40, y = y0 + 40}, {x = x0, y = y0 + 40},
                        {x = uv[1], y = uv[2]}, {x = uv[3], y = uv[2]},
                        {x = uv[3], y = uv[4]}, {x = uv[1], y = uv[4]}, 0x60ffffff)
            end
            vc.ImGui_AddText({x = x0 + 50, y = y0}, 0xff909090, lock[2])
            vc.ImGui_AddText({x = x0 + 50, y = y0 + 18}, 0xff707070,
                    string.format("empty  -  holds %s L", ui.commas(cap)))
        else
            vc.ImGui_AddText({x = x0, y = y0 + 6}, 0xff909090,
                    string.format("empty  -  room for %s L", ui.commas(cap)))
        end
        vc.ImGui_SetDrawForeground(false)
        return
    end

    -- The fluid's own picture, at the size the big window uses it.
    local tile = vc.render_fluid_tile(name)
    if tile >= 0 then
        local uv = vc.render_tile_uv_at(math.floor(tile))
        vc.ImGui_AddImageQuad(vc.render_atlas_id(),
                {x = x0, y = y0}, {x = x0 + 40, y = y0},
                {x = x0 + 40, y = y0 + 40}, {x = x0, y = y0 + 40},
                {x = uv[1], y = uv[2]}, {x = uv[3], y = uv[2]},
                {x = uv[3], y = uv[4]}, {x = uv[1], y = uv[4]}, ui.fluid_colour(name))
    end

    local full = (cap > 0) and (amount / cap) or 0.0
    vc.ImGui_AddText({x = x0 + 50, y = y0}, 0xffffffff, label ~= "" and label or name)
    vc.ImGui_AddText({x = x0 + 50, y = y0 + 18}, 0xffb0b0b0,
            string.format("%s L of %s L", ui.commas(amount), ui.commas(cap)))

    -- A bar, because a percentage of thirty-two million is a number nobody can picture. It is
    -- never quite empty while there is anything in there at all, for the same reason the fluid
    -- drawn inside the block never is: a tank with a litre in it is not an empty tank.
    local bx0, bx1 = x0, x1
    local by0 = y0 + 52
    vc.ImGui_AddRectFilled({x = bx0, y = by0}, {x = bx1, y = by0 + 18}, 0xff202020, 3)
    local filled = bx0 + math.max(2.0, (bx1 - bx0) * full)
    vc.ImGui_AddRectFilled({x = bx0, y = by0}, {x = filled, y = by0 + 18}, 0xff3f7fbf, 3)
    vc.ImGui_AddRect({x = bx0, y = by0}, {x = bx1, y = by0 + 18}, 0xff4a4a4a, 3, 1)

    local pct = string.format("%.3f%% full", full * 100.0)
    vc.ImGui_AddText({x = bx0 + 6, y = by0 + 1}, 0xffffffff, pct)

    vc.ImGui_SetDrawForeground(false)
end

--[[ @brief The chest window: its slots, which one is selected, and what goes in it.
-- |
-- | Core: a slot is CHOSEN by clicking it and then filled by the two boxes, rather than items being
-- | dropped into whichever slot happened to be free. The author asked for both on 2026-09-17: a
-- | button that selects a position, and an item menu like the fluid one.
-- |
-- | The slots are read off the C++ cell, which is what a transposer reaches into. Reading them from
-- | `u` would show a different chest from the one a program sees.
-- |
-- | WHERE THE ITEM NAMES COME FROM, and why the box stays editable: the catalogue is built from the
-- | vanilla jar's texture files, so an id here is a texture name with a namespace on the front.
-- | That is not always the registry name - a golden apple's texture is apple_golden while the item
-- | is minecraft:golden_apple - and there is no item registry in the instance to check against. So
-- | the panel says so and lets the name be typed over.
-- |
-- | @param cell  cell | nil - the chest being looked into
-- | @return boolean - whether the window was drawn
-- |
-- | @date 2026-09-17 18:00
--]]
function ui.chest(cell)
    if not cell or cell.kind ~= blocks.KIND.CHEST or not cell:placed() then
        return false
    end

    if cell:inv_size() == 0 then
        cell:inv_resize(blocks.CHEST_SLOTS)
    end
    if not item_ids then
        item_ids = vc.render_item_ids()
        item_labels = vc.render_item_labels()
        item_damage = vc.render_item_damage()
    end

    local p = cell:pos()
    local key = string.format("%d,%d,%d", p[1], p[2], p[3])
    if chest_at ~= key then
        chest_at = key
        chest_slot = 1
    end
    if chest_slot < 1 or chest_slot > cell:inv_size() then
        chest_slot = 1
    end

    vc.ImGui_Begin(string.format("chest %d, %d, %d", p[1], p[2], p[3]), 0)

    local used = 0
    for i = 1, cell:inv_size() do
        if cell:inv_get(i)[2] > 0 then
            used = used + 1
        end
    end
    vc.ImGui_Text(string.format("%d of %d slots used", used, cell:inv_size()))
    vc.ImGui_Separator()

    -- Nine across, the way a chest is laid out, so a slot number here means what it would mean to
    -- a program counting slots. A click SELECTS rather than clears - clearing is what an empty name
    -- box does, and a slot that emptied itself on a misclick lost whatever was in it.
    --
    -- Drawn as a real slot rather than as a row of text: a square big enough to see the picture in,
    -- with its number and its count written over the top, the way an inventory reads in the game.
    -- The author asked for this on 2026-09-17.
    --
    -- The square is an empty Selectable and everything is painted over it afterwards, because the
    -- window's draw list is emptied after the widgets are: drawing first would put the picture
    -- underneath the selection highlight instead of on it.
    local SLOT = 72
    local before = chest_slot
    for i = 1, cell:inv_size() do
        local slot = cell:inv_get(i)
        local at = vc.ImGui_GetCursorScreenPos()

        if vc.ImGui_Selectable(string.format("##s%d", i), i == chest_slot, 0,
                {x = SLOT, y = SLOT}) then
            chest_slot = i
        end

        -- Inset, so the selection shows as a border around the picture rather than behind it.
        if not item_icon_at(slot[1], slot[3], at.x + 6, at.y + 6, SLOT - 12) then
            vc.ImGui_AddQuadFilled({x = at.x + 6, y = at.y + 6}, {x = at.x + SLOT - 6, y = at.y + 6},
                    {x = at.x + SLOT - 6, y = at.y + SLOT - 6},
                    {x = at.x + 6, y = at.y + SLOT - 6}, 0x18ffffff)
        end

        -- The number in the corner, dim, so it reads as a label on the slot and not as contents.
        vc.ImGui_AddText({x = at.x + 4, y = at.y + 2}, 0xff8c8c8c, tostring(i))

        -- How many, bottom right and bright, which is where a stack size sits in the game.
        if slot[2] > 0 then
            local txt = tostring(slot[2])
            local sz = vc.ImGui_CalcTextSize(txt)
            vc.ImGui_AddText({x = at.x + SLOT - 5 - sz.x, y = at.y + SLOT - 3 - sz.y},
                    0xffffffff, txt)
        end

        if i % 9 ~= 0 then
            vc.ImGui_SameLine(0, 6)
        end
    end

    -- A newly chosen slot seeds the boxes from what is in it, so editing starts from the truth.
    local held = cell:inv_get(chest_slot)
    if before ~= chest_slot then
        chest_name_buf = held[1]
        chest_count_buf = string.format("%d", held[2] > 0 and held[2] or 1)
        chest_damage = held[3]
        chest_label = held[4]
    end

    vc.ImGui_Separator()
    vc.ImGui_Text(string.format("slot %d", chest_slot))

    -- The boxes decide what is in the chosen slot, the way the tank's litres box does. Clearing
    -- the name empties the slot.
    local typed = vc.ImGui_InputText("item", chest_name_buf, 64)
    if typed[1] then
        chest_name_buf = typed[2]
        -- A name typed by hand is its own item: whatever variant was there belonged to the item
        -- that was there, and carrying it over would label the new one with the old one's name.
        chest_damage, chest_label = 0, chest_name_buf
        cell:inv_set(chest_slot, chest_name_buf, tonumber(chest_count_buf) or 1,
                chest_damage, chest_label)
    end
    local cnt = vc.ImGui_InputText("count", chest_count_buf, 8)
    if cnt[1] then
        chest_count_buf = cnt[2]
        cell:inv_set(chest_slot, chest_name_buf, tonumber(chest_count_buf) or 0,
                chest_damage, chest_label)
    end

    if vc.ImGui_Button("empty the whole chest", {x = 0, y = 0}) then
        for i = 1, cell:inv_size() do
            cell:inv_set(i, "", 0, 0, "")
        end
        chest_name_buf = ""
        chest_damage, chest_label = 0, ""
    end

    vc.ImGui_Separator()

    if #item_ids == 0 then
        vc.ImGui_Text("no items found - is the minecraft jar set in the settings?")
        vc.ImGui_Separator()
        vc.ImGui_Text("esc to close")
        vc.ImGui_End()
        return true
    end

    local f = vc.ImGui_InputText("search", item_filter, 64)
    if f[1] then
        item_filter = f[2]
    end

    -- Worked out when the search changes and not before. See item_hits.
    if item_hits_for ~= item_filter then
        item_hits_for = item_filter
        item_hits = {}
        local needle = item_filter:lower()
        for i = 1, #item_ids do
            if needle == "" or item_ids[i]:lower():find(needle, 1, true)
                    or (item_labels[i] or ""):lower():find(needle, 1, true) then
                item_hits[#item_hits + 1] = i
            end
        end
    end

    -- Which list this is matters: a registry name is the item's real id, a texture name only
    -- looks like one. The panel says which it is showing rather than letting them be confused.
    vc.ImGui_Text(string.format("%d of %d  -  %s", #item_hits, #item_ids,
            vc.render_item_from_registry()
                    and "the modpack's registry, the ones with a picture"
                    or "TEXTURE names - no save found, so these are not real item ids"))
    vc.ImGui_Text("anything else goes in by typing its id in the box above")

    -- ONLY THE ROWS IN VIEW ARE DRAWN. Ten thousand Selectables a frame is more than ImGui will
    -- do at a sensible rate, and all but a dozen of them are off-screen anyway. The rows above and
    -- below are stood in for by one empty box each, which is what keeps the scrollbar honest.
    --
    -- The arithmetic only works if a row's height is exactly known, so the spacing between items
    -- is pushed to nothing and every row is given a fixed height.
    local ROW, VIEW = 18, 260
    vc.ImGui_BeginChild("items", {x = 0, y = VIEW}, 1, 0)
    vc.ImGui_PushItemSpacing({x = 6, y = 0})

    local total = #item_hits
    local scroll = vc.ImGui_GetScrollY()
    local first = math.max(1, math.floor(scroll / ROW) - 1)
    local last = math.min(total, first + math.ceil(VIEW / ROW) + 2)

    if first > 1 then
        vc.ImGui_Dummy({x = 1, y = (first - 1) * ROW})
    end
    for k = first, last do
        local i = item_hits[k]
        local id = item_ids[i]
        item_icon(id, item_damage[i] or 0, ROW)
        vc.ImGui_SameLine(0, 6)
        if vc.ImGui_Selectable(string.format("%s##i%d", item_labels[i] or id, i),
                id == chest_name_buf and (item_damage[i] or 0) == chest_damage,
                0, {x = 0, y = ROW}) then
            chest_name_buf = id
            chest_damage = item_damage[i] or 0
            chest_label = item_labels[i] or id
            local n = math.max(1, tonumber(chest_count_buf) or 1)
            cell:inv_set(chest_slot, id, n, chest_damage, chest_label)
            chest_count_buf = string.format("%d", n)
        end
    end
    if last < total then
        vc.ImGui_Dummy({x = 1, y = (total - last) * ROW})
    end

    vc.ImGui_PopItemSpacing()
    vc.ImGui_EndChild()

    vc.ImGui_Separator()
    vc.ImGui_Text("esc to close")
    vc.ImGui_End()
    return true
end

--[[ @brief A number with thousands separators - 32000000 reads as 32,000,000.
-- |
-- | GregTech does this itself (GT_Utility.formatNumbers, which is what its tank tooltip runs the
-- | capacity through), and at thirty-two million a run of digits is unreadable without it.
-- |
-- | @param n  number
-- | @return string
-- |
-- | @date 2026-09-17 16:00
--]]
function ui.commas(n)
    local whole = string.format("%d", math.floor(n + 0.5))
    local sign = ""
    if whole:sub(1, 1) == "-" then
        sign, whole = "-", whole:sub(2)
    end
    local out = whole:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    out = out:gsub("^,", "")
    return sign .. out
end

--[[ The fluid catalogue, asked for once. It comes from the GregTech jar by way of the atlas, so
it cannot change while the simulator is running unless the Minecraft path does - and when it does,
the atlas is rebuilt and this is dropped. @date 2026-09-17 16:00 ]]
local fluid_names = nil
local fluid_labels = nil
local fluid_filter = ""
local tank_amount_buf = "0"

--[[ Which tank the litres box is currently editing, and which fluid was picked for it.
-- |
-- | The box holds TEXT while it is being typed in - half a number is not a number - so it cannot be
-- | read back off the cell every frame or a keystroke would be undone as soon as it was made. It is
-- | seeded from the tank when a different tank is opened, and owns itself after that.
-- |
-- | The picked fluid is remembered here rather than read off the cell because a tank at nought
-- | litres holds nothing at all - that is the mod's own rule, a drained tank has a null FluidStack
-- | rather than a zero one - and a panel that forgot which fluid you had chosen the moment you
-- | typed a zero would be unusable. @date 2026-09-17 17:00 ]]
local tank_at = nil
local tank_pick_name = ""
local tank_pick_label = ""

--[[ @brief Forgets the fluid catalogue, so the next window rebuilds it.
-- |
-- | Called when the atlas is rebuilt, which is the only thing that can change what fluids exist.
-- | @date 2026-09-17 16:00
--]]
function ui.forget_fluids()
    fluid_names = nil
    fluid_labels = nil
end

--[[ @brief Draws one fluid's texture at the cursor, and leaves the cursor past it.
-- |
-- | The picture comes out of the world atlas, the same GL texture the blocks are drawn from, which
-- | is why it is an image quad rather than an ImGui image: nothing here has a texture of its own.
-- |
-- | @param name  string - the fluid's internal name
-- | @param size  number - pixels on a side
-- |
-- | @date 2026-09-17 16:00
--]]
--[[ @brief A fluid's colour, as ImGui packs one.
-- |
-- | Most fluids have no picture and are drawn as a greyscale stand-in multiplied by the material's
-- | colour, which is how GregTech draws them. The renderer answers that colour as 0xRRGGBB and
-- | ImGui wants 0xAABBGGRR, so the two ends get swapped here.
-- | @date 2026-09-17 ]]
function ui.fluid_colour(name)
    local rgb = math.floor(vc.render_fluid_tint(name or ""))
    local r = math.floor(rgb / 65536) % 256
    local g = math.floor(rgb / 256) % 256
    local b = rgb % 256
    return 0xff000000 + b * 65536 + g * 256 + r
end

local function fluid_icon(name, size)
    local at = vc.ImGui_GetCursorScreenPos()
    local tile = vc.render_fluid_tile(name or "")
    if tile >= 0 then
        local uv = vc.render_tile_uv_at(math.floor(tile))
        vc.ImGui_AddImageQuad(vc.render_atlas_id(),
                {x = at.x, y = at.y}, {x = at.x + size, y = at.y},
                {x = at.x + size, y = at.y + size}, {x = at.x, y = at.y + size},
                {x = uv[1], y = uv[2]}, {x = uv[3], y = uv[2]},
                {x = uv[3], y = uv[4]}, {x = uv[1], y = uv[4]}, ui.fluid_colour(name))
    else
        vc.ImGui_AddQuadFilled({x = at.x, y = at.y}, {x = at.x + size, y = at.y},
                {x = at.x + size, y = at.y + size}, {x = at.x, y = at.y + size}, 0xff404040)
    end
    vc.ImGui_Dummy({x = size, y = size})
end

--[[ @brief The liquid tank window: what it holds, and how much.
-- |
-- | Core: the author asked on 2026-09-17 for a tank whose type is configurable, with the texture
-- | and the name taken from the game. Both are - the list below is every fluid the installed
-- | GregTech ships a texture for, and each one's name is the one GregTech's own generated lang file
-- | gives it. Nothing here names a fluid itself.
-- |
-- | The amount is in litres, which is the unit GregTech displays: a Super Tank's tooltip is its
-- | capacity followed by " L". A tank holds one fluid at a time, so choosing a different one while
-- | there is something in it replaces it rather than mixing.
-- |
-- | @param cell  cell | nil - the tank being configured
-- | @return boolean - whether the window was drawn
-- |
-- | @date 2026-09-17 16:00
--]]
function ui.tank(cell)
    if not cell or not blocks.is_tank(cell.kind) or not cell:placed() then
        return false
    end

    if not fluid_names then
        fluid_names = vc.render_fluid_names()
        fluid_labels = vc.render_fluid_labels()
    end

    local p = cell:pos()
    vc.ImGui_Begin(string.format("%s %d, %d, %d",
            blocks.KIND_NAME[cell.kind] or "tank", p[1], p[2], p[3]), 0)

    local held = cell:fluid_get()
    local name, amount, label = held[1], held[2], held[3]
    local cap = cell:fluid_capacity()

    -- A different tank than last frame: the box and the picked fluid start from what IS in it.
    local key = string.format("%d,%d,%d", p[1], p[2], p[3])
    if tank_at ~= key then
        tank_at = key
        tank_amount_buf = string.format("%d", math.floor(amount + 0.5))
        tank_pick_name = name
        tank_pick_label = label
    end

    -- What is in it now, with its own picture beside it.
    if name ~= "" then
        fluid_icon(name, 32)
        vc.ImGui_SameLine(0, 8)
        vc.ImGui_Text(string.format("%s\n%s L of %s L  (%.1f%%)",
                label ~= "" and label or name,
                ui.commas(amount), ui.commas(cap), cap > 0 and (amount / cap * 100.0) or 0.0))
    else
        local lock = cell:fluid_lock_get()
        if lock[1] ~= "" then
            fluid_icon(lock[1], 32)
            vc.ImGui_SameLine(0, 8)
            vc.ImGui_Text(string.format("%s\nempty - locked to this fluid, holds %s L",
                    lock[2], ui.commas(cap)))
        else
            vc.ImGui_Text(string.format("empty - room for %s L", ui.commas(cap)))
        end
    end

    vc.ImGui_Separator()

    -- HOW MUCH IS IN IT IS WHAT THE BOX SAYS. There are no set, add, take, fill or empty buttons:
    -- the author asked on 2026-09-17 for the box to decide the contents and nothing else to.
    -- Typing a number puts that many litres in; clearing it or typing a zero empties it.
    local typed = vc.ImGui_InputText("litres", tank_amount_buf, 16)
    if typed[1] then
        tank_amount_buf = typed[2]
        if tank_pick_name ~= "" then
            -- An unreadable box - empty, or a minus sign on its own part way through typing - is
            -- taken as nought rather than left alone, so backspacing to nothing empties the tank
            -- instead of freezing it at whatever it last read.
            cell:fluid_set(tank_pick_name, tonumber(tank_amount_buf) or 0, tank_pick_label)
        end
    end

    if tank_pick_name == "" then
        vc.ImGui_Text("pick a fluid below, then say how many litres of it")
    else
        vc.ImGui_Text(string.format("full at %s L", ui.commas(cap)))
    end

    vc.ImGui_Separator()

    if #fluid_names == 0 then
        vc.ImGui_Text("no fluids found - is the minecraft path set, with gregtech in it?")
        vc.ImGui_Separator()
        vc.ImGui_Text("esc to close")
        vc.ImGui_End()
        return true
    end

    local f = vc.ImGui_InputText("search", fluid_filter, 64)
    if f[1] then
        fluid_filter = f[2]
    end
    vc.ImGui_Text(string.format("%d fluids, from gregtech", #fluid_names))

    -- The picker. A child rather than the window itself, so the part above stays put while a list
    -- of a couple of hundred fluids scrolls underneath it.
    vc.ImGui_BeginChild("fluids", {x = 0, y = 320}, 1, 0)
    local needle = fluid_filter:lower()
    for i = 1, #fluid_names do
        local fname = fluid_names[i]
        local flabel = fluid_labels[i] or fname
        if needle == "" or fname:lower():find(needle, 1, true)
                or flabel:lower():find(needle, 1, true) then
            fluid_icon(fname, 18)
            vc.ImGui_SameLine(0, 6)
            -- Keeping whatever was in it: choosing a fluid says what it is, not how much.
            if vc.ImGui_Selectable(string.format("%s##f%d", flabel, i), fname == tank_pick_name,
                    0, {x = 0, y = 0}) then
                -- Choosing a fluid says WHAT is in the tank; the box says how much. The litres
                -- already typed are kept, so picking a different fluid swaps it over rather than
                -- emptying the tank.
                tank_pick_name = fname
                tank_pick_label = flabel
                cell:fluid_set(fname, tonumber(tank_amount_buf) or 0, flabel)
            end
        end
    end
    vc.ImGui_EndChild()

    vc.ImGui_Separator()
    vc.ImGui_Text("esc to close")
    vc.ImGui_End()
    return true
end

--[[ @brief Writes every sign's text over the block it belongs to.
-- |
-- | Core: A SIGN'S TEXT IS NOT A TEXTURE. It is a string that changes while the scenario runs, so
-- | it cannot be baked into the atlas - it is drawn by projecting the block's position onto the
-- | screen and putting the words there. Behind the camera or too far away, it is skipped.
-- |
-- | Drawn on the foreground list so it sits over the world rather than being clipped into some
-- | window's rectangle.
-- |
-- | @param w  world
-- |
-- | @date 2026-09-18 ]]
function ui.signs(w)
    local disp = vc.ImGui_GetDisplaySize()
    local W, H = math.floor(disp.x), math.floor(disp.y)

    vc.ImGui_SetDrawForeground(true)
    for _, cell in ipairs(w:occupied()) do
        -- ANY BLOCK CAN CARRY A LABEL, not only a sign. A lamp that says nothing is a lamp nobody
        -- can read: the four above the redstone blocks meant "something on this block is live" and
        -- looked identical to each other. Putting the text on the lamp itself labels it where it
        -- stands, without needing a sign block squeezed in beside it.
        local text = blocks.u(cell).text
        if text and text ~= "" then
            local p = cell:pos()
            local lines = {}
            for line in tostring(text):gmatch("[^\n]+") do
                lines[#lines + 1] = line
            end

            -- The middle of the block's top, so the words sit on it rather than in it.
            local at = vc.render_project(p[1] + 0.5, p[2] + 1.02, p[3] + 0.5, W, H)
            if at[3] > 0 and at[1] > -200 and at[1] < W + 200 and at[2] > 0 and at[2] < H then
                local lh = vc.ImGui_GetFontSize() + 2
                local wide = 0
                for _, l in ipairs(lines) do
                    wide = math.max(wide, vc.ImGui_CalcTextSize(l).x)
                end
                local top = at[2] - lh * #lines - 2

                -- A dark plate behind them, because white words over a bright world are
                -- unreadable at exactly the angles you want to read them from.
                vc.ImGui_AddRectFilled({x = at[1] - wide * 0.5 - 3, y = top - 2},
                        {x = at[1] + wide * 0.5 + 3, y = at[2] + 1}, 0xb0000000, 3)
                for i, l in ipairs(lines) do
                    local sz = vc.ImGui_CalcTextSize(l)
                    vc.ImGui_AddText({x = at[1] - sz.x * 0.5, y = top + (i - 1) * lh},
                            0xffffffff, l)
                end
            end
        end
    end
    vc.ImGui_SetDrawForeground(false)
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

    -- WHICH SCENARIO IS RUNNING, or plainly that none is. Without this the only sign that a scene
    -- was not loaded is a window that is not there, and a window that is not there looks exactly
    -- like a window that is broken.
    if info.scene and info.scene ~= "" then
        vc.ImGui_Text("scenario: " .. info.scene)
    else
        vc.ImGui_Text("no scenario - start with --scene scenes/<name> for the controller")
    end
    vc.ImGui_Separator()

    vc.ImGui_Text(info.captured and "mouse: captured - tab to release"
            or "mouse: free - tab to capture and look around")
    vc.ImGui_Text("wasd moves level; space rises, shift sinks, both together hold still")
    vc.ImGui_Text("ctrl moves at the faster speed")
    vc.ImGui_Text("left click breaks; right click opens a case, screen or chest")
    vc.ImGui_Text("(a scenario's map is read-only - nothing can be broken or placed)")
    vc.ImGui_Text("right click anything else - or shift+right click - places instead")
    vc.ImGui_Text("the mouse wheel, or 1 to 9, changes what is selected")
    if info.scene and info.scene ~= "" then
        vc.ImGui_Text(string.format("scenario clock: %gx  -  minus slower, equals faster, 0 resets",
                info.sim_speed or 1))
    end
    vc.ImGui_Text("the orange ball marks where a placed block would go")
    vc.ImGui_Text("a wire cannot be built on, and breaking takes the wire first")
    vc.ImGui_Text("f toggles the aimed case between off and running")
    vc.ImGui_Text("ctrl+q quits, saving the world on the way out")

    vc.ImGui_End()
end

return ui
