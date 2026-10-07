--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The planner's packets in the view: with J, what is left of the packets robots are working on,
-- | see-through; with P (hidden at first), every packet as a box with its number in the order,
-- | and the plan's problems - cells never scanned "?", blocks with nothing to stand on "!".
-- | Stage 4 of 3d-draw/redesign/08-order.md.
-- |
-- |     packets.init(plans)    the plan files the panel offers (village, harbour)
-- |     packets.update()       P toggles; true when the view must be drawn again
-- |     packets.cells()        the view's overlay: the worked packets' blocks still to place
-- |     packets.activate(id), packets.finish(id)   what the crew works on (stage 5)
-- |     packets.draw()         with P, the boxes and the problem marks, over the view
-- |     packets.panel()        its part of the panel: which plan, plan it, what came out
-- |
-- | Planning reads every chunk the plan touches (chunks.read_area), not only the zone shown.
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local spawn = require("spawn")         -- spawns that keep their handle
local chunks = require("chunks")
local planner = require("live")("planner")    -- by name, for `reload planner`
local prove = require("live")("prove")
local view = require("view")

local packets = {on = false, plans = {}, pick = 1, result = nil, took = 0, note = "", want = {}}

function packets.init(plans)
    packets.plans = plans
end

-- A stair's way, as the game keeps it in meta (vanilla BlockStairs; look.lua's map_shape reads
-- it back): the plan writes meta 0 and says the way in `facing`, rising toward it, and upside
-- down as shape 6 (design/village.py, stairs()). Read as meta 0, every stair rose east.
local STAIR_META = {xpos = 0, xneg = 1, zpos = 2, zneg = 3}

local function read_plan(path)
    local want, n = {}, 0
    local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
    for line in io.lines(path) do
        local x, y, z, name, meta, shape, facing =
                line:match("^b (-?%d+) (-?%d+) (-?%d+) (%S+) (%d+) ?(%d*) ?(%S*)")
        if x then
            meta = tonumber(meta)
            if name:find("_stairs") and STAIR_META[facing] then
                meta = STAIR_META[facing] + (shape == "6" and 4 or 0)
            end
            want[x .. "," .. y .. "," .. z] = {name, meta}
            n = n + 1
            x, z = tonumber(x), tonumber(z)
            x0, x1, z0, z1 = math.min(x0, x), math.max(x1, x), math.min(z0, z), math.max(z1, z)
        end
    end
    return want, n, {x0, x1, z0, z1}
end

function packets.run()
    local path = packets.plans[packets.pick]
    local t = vc.app_time()
    local ok, want, n, ext = pcall(read_plan, path)
    if not ok then packets.note = "cannot read " .. path; return end
    -- put-backs a stopped trip owes (crew.owed: a stair's stand dug, its block not back yet):
    -- planned as the plan's own until placed
    local crew = package.loaded["crew"]
    for k, b in pairs(type(crew) == "table" and crew.owed or {}) do
        if not want[k] then want[k], n = b, n + 1 end
    end
    local a = view.anchor
    local area = chunks.read_area("data/chunks", (ext[1] + a[1]) // 16, (ext[2] + a[1]) // 16,
            (ext[3] + a[3]) // 16, (ext[4] + a[3]) // 16,
            chunks.LAYERS)
    if not area then packets.note = "no chunks under the plan"; return end
    local function have(x, y, z)
        local k = (x + a[1]) .. "," .. (y + a[2]) .. "," .. (z + a[3])
        local c = area.cells[k]
        -- name, meta, guessed, and exact: read by analyze, built or told - not a geolyzer's
        -- guess, settled or scouted (redesign/10-live.md, "A guess is not named as seen")
        if c then
            local exact = not c[7] and (c[6] == "analyzed" or c[6] == "seen" or c[6] == "built"
                                        or c[6] == "told")
            return c[4], c[5], c[7], exact
        end
        if area.air[k] then return "air" end
        if y + a[2] > area.box[4] then return "air" end   -- above all that was scanned: sky
        return nil
    end
    packets.have = have                  -- the map as planned: the copies name blocks from it too
    packets.result = planner.plan(want, have)
    packets.result.t0 = t                -- when the map it rests on was read (crew.is_done)
    packets.want, packets.active, packets.dirty = want, {}, true
    -- every packet filled on paper before it may become work (prove.lua); the program draws in
    -- between, this running on a coroutine of its own
    packets.note = ("%s: %d blocks - proving..."):format(path, n)
    packets.proof = prove.run(packets.result, want, have, {entry = {0, 0, -2},
            yield = function() vc.net_sleep_ms(0) end})
    packets.took = vc.app_time() - t
    packets.note = ("%s: %d blocks"):format(path, n)
    packets.unproven = {}
    for id, p in pairs(packets.result.packets) do
        if p.unproven then packets.unproven[#packets.unproven + 1] = id .. ": " .. p.unproven end
    end
    table.sort(packets.unproven)
end

function packets.update()
    if vc.ImGui_IsKeyPressed("ImGuiKey_P", false) and not vc.ImGui_WantCaptureKeyboard() then
        packets.on = not packets.on
    end
end

-- A robot position into the world's cell coordinates, inside the world or not (to_cell clips).
local function cell(x, y, z)
    local b, a = view.zone.box, view.anchor
    return x + a[1] - b[1], y + a[2] - b[3], z + a[3] - b[5]
end

--[[ The packets robots are working on (the crew sets them, stage 5): with J on, the blocks of each
-- still to place are drawn see-through where they will stand; placed, the map's own block shows.
-- The whole grid is not drawn - the user, 2026-10-05: "no need for me to see the whole grid, the
-- worked packets are enough". ]]
packets.active = {}
local shown, j_seen = {}, nil

function packets.activate(id) packets.active[id] = true; packets.dirty = true end
function packets.finish(id) packets.active[id] = nil; packets.dirty = true end

function packets.cells()
    local r = packets.result
    if not r or not view.j then return nil end
    local a, out = view.anchor, {}
    for id in pairs(packets.active) do
        local p = r.packets[id]
        if p and p.kind == "place" then
            for _, k in ipairs(p.cells) do
                local b = packets.want[k]
                local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
                local c = view.terrain[(x + a[1]) .. "," .. (y + a[2]) .. "," .. (z + a[3])]
                if b and not (c and c[4] == b[1]) then
                    local old = shown[k]
                    if not (old and old[1] == b[1] and old[2] == b[2]) then
                        old = {b[1], b[2], nil, nil, 2}
                        shown[k] = old
                    end
                    out[k] = old
                end
            end
        end
    end
    return out
end

-- P toggles the grid, hidden at first. True when the view is to be drawn again.
function packets.update()
    if vc.ImGui_IsKeyPressed("ImGuiKey_P", false) and not vc.ImGui_WantCaptureKeyboard() then
        packets.on = not packets.on
    end
    local changed = packets.dirty or j_seen ~= view.j
    packets.dirty, j_seen = false, view.j
    return changed
end

local EDGES = {{1, 2}, {2, 4}, {4, 3}, {3, 1}, {5, 6}, {6, 8}, {8, 7}, {7, 5},
               {1, 5}, {2, 6}, {3, 7}, {4, 8}}

-- P: every packet as a box of the 5 x 5 x 8 grid, red to dig, blue to place, its number in the
-- order over it, fading as the order goes on; and the problem marks. Hidden until P (the user,
-- 2026-10-05: "make P be hidden as a default, I want to see that when I want").
function packets.draw()
    local r = packets.result
    if not packets.on or not r or not view.zone then return end
    local disp = vc.ImGui_GetDisplaySize()
    local W, H = math.floor(disp.x), math.floor(disp.y)
    local n = #r.order
    vc.ImGui_SetDrawForeground(true)
    for _, p in pairs(r.packets) do
        local b = p.box
        local x0, y0, z0 = cell(b[1] * planner.W, b[2] * planner.H, b[3] * planner.W)
        local x1, y1, z1 = x0 + planner.W, y0 + planner.H, z0 + planner.W
        if x1 > 0 and x0 < 64 and z1 > 0 and z0 < 64 and y1 > 0 and y0 < 64 then
            local corners, behind, i = {}, false, 0
            for _, yy in ipairs({y0, y1}) do
                for _, zz in ipairs({z0, z1}) do
                    for _, xx in ipairs({x0, x1}) do
                        i = i + 1
                        local at = vc.render_project(xx + 0.02, yy + 0.02, zz + 0.02, W, H)
                        if at[3] <= 0 then behind = true end
                        corners[i] = at
                    end
                end
            end
            if not behind then
                local shade = math.floor(255 - 150 * (p.order or n) / math.max(1, n))
                local colour = p.kind == "dig" and (0xc0000000 | (40 << 8) | shade)
                        or (0xc0000000 | (shade << 16) | (120 << 8) | 40)
                for _, e in ipairs(EDGES) do
                    local a1, a2 = corners[e[1]], corners[e[2]]
                    vc.ImGui_AddLine({x = a1[1], y = a1[2]}, {x = a2[1], y = a2[2]}, colour, 1.5)
                end
                local mid = vc.render_project((x0 + x1) / 2, y1 + 0.3, (z0 + z1) / 2, W, H)
                if mid[3] > 0 then
                    vc.ImGui_AddText({x = mid[1] - 8, y = mid[2] - 8}, 0xffffffff,
                            tostring(p.order or "?"))
                end
            end
        end
    end
    local function marks(list, text, colour)
        for i, k in ipairs(list) do
            if i > 400 then break end
            local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
            local cx, cy, cz = cell(tonumber(x), tonumber(y), tonumber(z))
            local at = vc.render_project(cx + 0.5, cy + 0.5, cz + 0.5, W, H)
            if at[3] > 0 then vc.ImGui_AddText({x = at[1] - 3, y = at[2] - 7}, colour, text) end
        end
    end
    marks(r.problems.unknown, "?", 0xffc0c0c0)
    marks(r.problems.flying, "!", 0xffff40ff)
    vc.ImGui_SetDrawForeground(false)
end

function packets.panel()
    local n = 0
    for _ in pairs(packets.active) do n = n + 1 end
    vc.ImGui_Text(("packets: %d being worked (J shows what is left of them)   the grid %s (P)")
            :format(n, packets.on and "shown" or "hidden"))
    for i, path in ipairs(packets.plans) do
        if i > 1 then vc.ImGui_SameLine(0, -1) end
        local name = path:match("([^/]+)%.txt$") or path
        if vc.ImGui_SmallButton((i == packets.pick and "[%s]" or "%s"):format(name)) then
            packets.pick = i
        end
    end
    vc.ImGui_SameLine(0, -1)
    if vc.ImGui_Button("plan it", {x = 0, y = 0}) then spawn(packets.run) end
    local r = packets.result
    if r then
        local s = r.stats
        vc.ImGui_Text(packets.note .. (" - planned in %.2f s"):format(packets.took))
        vc.ImGui_Text(("%d dig packets (%d blocks), then %d place packets (%d blocks): %d in order")
                :format(s.dig_packets, s.dig_cells, s.place_packets, s.place_cells, #r.order))
        vc.ImGui_Text(("never scanned: %d (?)   nothing to stand on: %d (!)   in a cycle: %d")
                :format(#r.problems.unknown, #r.problems.flying, #r.problems.cycle))
        local pf = packets.proof
        if pf then
            vc.ImGui_Text(("proven: %d packets, %d steps, %d scaffold blocks; unproven: %d"):format(
                    pf.proven, pf.steps, pf.scaffolds, pf.unproven))
            for i, u in ipairs(packets.unproven or {}) do
                if i > 6 then break end
                vc.ImGui_Text("  " .. u)
            end
        end
    end
end

return packets
