--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The world on screen: one zone of the map (3x3 chunks), with the layers laid over it, drawn
-- | into the renderer's 64-cube world. The overlays (the plan, H) say which cells they draw;
-- | the zone's own block shows wherever no overlay does.
-- |
-- |     view.init(paths)            paths: {chunks, anchor, zone, built, fixed}
-- |     view.load_zone(cx, cz, step)  reads a zone and draws it; the camera is placed the first
-- |                                 time, then stays on the same blocks - or, with `step`, at the
-- |                                 same place over the zone, so the view moves with it
-- |     view.step_zone()            the arrows move the zone a chunk at a time (below)
-- |     view.redraw()               draws the zone and the overlays again: after a toggle, a file
-- |                                 changed, a new zone. One rebuild of the renderer's mesh.
-- |     view.add_overlay(o)         o.cells() -> {["rx,ry,rz"] = {name, meta, shape, facing}} or
-- |                                 nil while off; name "minecraft:air" empties the cell
-- |     view.follow(dt)             reads the zone's files again when one changed (below)
-- |     view.to_cell(rx, ry, rz)    a robot position's cell in the world, or nil outside it
-- |     view.to_robot(cx, cy, cz)   a cell's robot position
-- |     view.world, view.zone, view.anchor, view.counts
-- |
-- | Robot coordinates count from the start block (data/anchor.txt: robot 0 0 0 = world 255 63
-- | 139); the files of the map are in world coordinates, the plans and markers in robot ones.
-- |
-- | Following: the old viewer re-read and compared about a megabyte every 2 s and rebuilt the
-- | whole mesh on every robot event, which made it lag (2026-10-05). Here a file's size is
-- | looked at every second and its text read only when the size changed, or every 10 s for an
-- | edit of the same length; the mesh is rebuilt only when something drawn changed.
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local blocks = require("blocks")
local look = require("look")
local chunks = require("chunks")
local watch = require("watch")

local view = {world = nil, zone = nil, anchor = {255, 63, 139}, terrain = {},
              counts = {cells = 0, untextured = 0, cut = 0}}

local AIR = "minecraft:air"
local SIZE = 64                                      -- world_composer.h: WORLD_X, _Y, _Z

local paths = {}
local overlays = {}
local kinds = {}                 -- "name meta" -> {tex, tint, shape, facing, colour, tile}
local cam_placed = false

local FACINGS = {xneg = blocks.FACE.XNEG, xpos = blocks.FACE.XPOS, zneg = blocks.FACE.ZNEG,
                 zpos = blocks.FACE.ZPOS}
view.FACINGS = FACINGS

function view.init(p)
    paths = p
    view.world = vc.world_create()
    local x, y, z = chunks.read_pair(paths.anchor, "start")
    if x then view.anchor = {x, y, z} end
end

-- The cell of the world a robot position falls in, or nil: the zone's west, north corner at the
-- world's 0, its lowest block at 0.
function view.to_cell(rx, ry, rz)
    local b = view.zone and view.zone.box
    if not b then return nil end
    local a = view.anchor
    local x, y, z = rx + a[1] - b[1], ry + a[2] - b[3], rz + a[3] - b[5]
    if x < 0 or y < 0 or z < 0 or x >= SIZE or y >= SIZE or z >= SIZE then return nil end
    return x, y, z
end

function view.to_robot(x, y, z)
    local b, a = view.zone.box, view.anchor
    return x + b[1] - a[1], y + b[3] - a[2], z + b[5] - a[3]
end

function view.add_overlay(o)
    overlays[#overlays + 1] = o
end

-- How a kind of block is drawn, worked out once; its texture comes in textures().
local function kind(name, meta, shape, facing)
    local key = name .. " " .. meta .. " " .. tostring(shape) .. " " .. tostring(facing)
    local k = kinds[key]
    if k then return k end
    local tex, tint, s = look.look(name, meta)
    local f = facing
    if shape then
        s = shape
    elseif s == look.CUBE then
        s, f = look.map_shape(name, meta, s)
    end
    k = {tex = tex, tint = tint, shape = s or 0, facing = f, colour = look.colour_of(name, meta)}
    kinds[key] = k
    return k
end

-- Every texture not yet looked for, in one pass over the jars.
local function textures()
    local want, keys = {}, {}
    for _, k in pairs(kinds) do
        if k.tile == nil then
            want[#want + 1] = k
            keys[#keys + 1] = k.tex
        end
    end
    if #want == 0 then return end
    local tiles = vc.render_block_tiles(table.concat(keys, "\n")) or {}
    for i, k in ipairs(want) do
        k.tile = (tiles[i] or -1) >= 0 and tiles[i] or -1
    end
end

-- Blocks go to the world in one call (world_t::put_blocks, 2026-10-05): eight numbers a block,
-- a shape of -1 to empty the slot. One call into C++ a block cost 0.36 s for a zone.
local ZPOS = blocks.FACE.ZPOS
local function put(flat, x, y, z, k, ghost)
    local n = #flat
    if not k then
        flat[n + 1], flat[n + 2], flat[n + 3], flat[n + 4] = x, y, z, -1
        flat[n + 5], flat[n + 6], flat[n + 7], flat[n + 8] = 0, -1, ZPOS, 0
        return
    end
    flat[n + 1], flat[n + 2], flat[n + 3], flat[n + 4] = x, y, z, k.tile
    flat[n + 5], flat[n + 6] = k.tile >= 0 and k.tint or k.colour, k.shape
    flat[n + 7], flat[n + 8] = k.facing or ZPOS, ghost and 1 or 0
end

local shown = {}                 -- the overlays' cells as drawn: robot "x,y,z" -> block

local function overlay_cells()
    local over = {}
    for _, o in ipairs(overlays) do
        for key, b in pairs(o.cells() or {}) do over[key] = b end
    end
    return over
end

function view.redraw()
    local w = view.world
    w:wipe()
    shown = {}
    if not view.zone then return end
    local over = overlay_cells()
    shown = over
    -- the kinds first, so all their textures come in one pass
    local a, todo = view.anchor, {}
    for _, c in pairs(view.terrain) do
        local rk = (c[1] - a[1]) .. "," .. (c[2] - a[2]) .. "," .. (c[3] - a[3])
        if not over[rk] then
            todo[#todo + 1] = {c[1] - a[1], c[2] - a[2], c[3] - a[3], kind(c[4], c[5]), c[7]}
        end
    end
    for key, b in pairs(over) do
        if b[1] ~= AIR then
            local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
            todo[#todo + 1] = {tonumber(x), tonumber(y), tonumber(z),
                               kind(b[1], b[2], b[3], b[4]), false}
        end
    end
    textures()
    local cut, untextured, flat = 0, 0, {}
    for _, t in ipairs(todo) do
        local x, y, z = view.to_cell(t[1], t[2], t[3])
        if x then
            put(flat, x, y, z, t[4], t[5])
            if t[4].tile < 0 then untextured = untextured + 1 end
        else
            cut = cut + 1
        end
    end
    w:put_blocks(flat)
    view.counts.untextured, view.counts.cut = untextured, cut
end

--[[ @brief Draws again only the cells an overlay changed: what it draws now, or the zone's own
-- | block where it drew before and no longer does. Turning the plan on (H) with view.redraw()
-- | put all ~30,000 cells of the zone again from Lua - 0.36 s, the user's "H is laggy"
-- | (2026-10-05) - for the ~4,000 of the plan's that fall in the world.
-- | @date 2026-10-05 ]]
function view.update_overlays()
    if not view.zone then return end
    local over, w, a = overlay_cells(), view.world, view.anchor
    local todo = {}
    for key, b in pairs(over) do
        if shown[key] ~= b then todo[#todo + 1] = key end
    end
    for key in pairs(shown) do
        if over[key] == nil then todo[#todo + 1] = key end
    end
    -- what each changed cell becomes: the overlay's block, or the zone's own, or nothing
    local puts = {}
    for _, key in ipairs(todo) do
        local rx, ry, rz = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
        rx, ry, rz = tonumber(rx), tonumber(ry), tonumber(rz)
        local x, y, z = view.to_cell(rx, ry, rz)
        if x then
            local b = over[key]
            if b then
                puts[#puts + 1] = {x, y, z, b[1] ~= AIR and kind(b[1], b[2], b[3], b[4]), false}
            else
                local c = view.terrain[(rx + a[1]) .. "," .. (ry + a[2]) .. "," .. (rz + a[3])]
                puts[#puts + 1] = {x, y, z, c and kind(c[4], c[5]), c and c[7]}
            end
        end
    end
    textures()
    local flat = {}
    for _, p in ipairs(puts) do put(flat, p[1], p[2], p[3], p[4] or nil, p[5]) end
    w:put_blocks(flat)
    shown = over
end

-- The files the zone is drawn from: its nine chunks, then built and fixed.
local function zone_files(cx, cz)
    local out = {}
    for i = cx - 1, cx + 1 do
        for j = cz - 1, cz + 1 do out[#out + 1] = ("%s/c%d_%d.txt"):format(paths.chunks, i, j) end
    end
    out[#out + 1] = paths.built
    out[#out + 1] = paths.fixed
    return out
end

local zone_watch = nil

function view.load_zone(cx, cz, step)
    local z = chunks.read_zone(paths.chunks, cx, cz, {paths.built, paths.fixed})
    if not z then return false end
    local old = view.zone and view.zone.box
    view.zone = {cx = cx, cz = cz, box = z.box}
    view.terrain = z.cells
    local n = 0
    for _ in pairs(z.cells) do n = n + 1 end
    view.counts.cells = n
    zone_watch = watch.new(zone_files(cx, cz))
    zone_watch:poll(1.0)                              -- takes the files as they are now
    view.redraw()
    local b = z.box
    if not cam_placed then
        vc.cam_set(24.5, (b[4] - b[3]) + 10, 48 + 14, 0.0, -0.55)
        cam_placed = true
    elseif step and old then
        -- a step by chunk (the arrows): the camera keeps its place over the zone, so the view
        -- moves with it, by a chunk across, and up or down with the ground
        local cam = vc.cam_get()
        vc.cam_set(cam[1], cam[2] + old[3] - b[3], cam[3], cam[4], cam[5])
    elseif old and (old[1] ~= b[1] or old[3] ~= b[3] or old[5] ~= b[5]) then
        -- the same blocks stay under the camera when the zone's corner moved
        local cam = vc.cam_get()
        vc.cam_set(cam[1] + old[1] - b[1], cam[2] + old[3] - b[3], cam[3] + old[5] - b[5],
                   cam[4], cam[5])
    end
    return true
end

--[[ @brief The arrow keys move the zone shown a chunk at a time, as seen from the camera: up is
-- | the compass direction the camera looks closest to, left a quarter turn from it, and so on.
-- | The user, 2026-10-05: "let arrow key move the drawn area chunk-wise, so reposition to the new
-- | chunk center on those". A zone with no chunk file at all is not stepped into.
-- | @date 2026-10-05 ]]
local ARROWS = {{"ImGuiKey_UpArrow", 0}, {"ImGuiKey_LeftArrow", 1}, {"ImGuiKey_DownArrow", 2},
                {"ImGuiKey_RightArrow", 3}}
function view.step_zone()
    if not view.zone or vc.ImGui_WantCaptureKeyboard() then return end
    for _, a in ipairs(ARROWS) do
        if vc.ImGui_IsKeyPressed(a[1], false) then
            local f = vc.cam_forward()
            local fx, fz
            if math.abs(f[1]) > math.abs(f[3]) then
                fx, fz = f[1] > 0 and 1 or -1, 0
            else
                fx, fz = 0, f[3] > 0 and 1 or -1
            end
            for _ = 1, a[2] do fx, fz = fz, -fx end      -- a quarter turn to the left each
            view.load_zone(view.zone.cx + fx, view.zone.cz + fz, true)
            return
        end
    end
end

-- The zone's files, followed (watch.lua): the zone is read and drawn again when one changed.
function view.follow(dt)
    if view.zone and zone_watch and zone_watch:poll(dt) then
        view.load_zone(view.zone.cx, view.zone.cz)
    end
end


return view
