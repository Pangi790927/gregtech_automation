--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | new()                                    -> state
-- |     A fresh, empty map and the interaction state that goes with it.
-- |
-- | aim(state: state)                        -> target | nil
-- |     Casts the crosshair's ray and records what it met: the cell, the
-- |     face, the cell it would place against, and the exact point on the
-- |     surface. Called once a frame; every other reader takes
-- |     `state.target` rather than casting again.
-- |
-- | place(state: state)                      -> cell | nil
-- |     Puts a computer case against whatever is aimed at, facing the
-- |     camera. Answers the cell, or nil when there is nowhere to put it.
-- |
-- | place_wire(state: state)                 -> cell | nil
-- |     Lays a redstone wire on the face the crosshair is on.
-- |
-- | place_keyboard(state: state)             -> cell | nil
-- |     Bolts a keyboard onto that face - a case or a screen only.
-- |
-- | place_flat(state: state, make: function)  -> cell | nil
-- |     The shared body of the two above.
-- |
-- | break_attach(state: state)               -> cell | nil
-- |     Takes whatever flat thing is on that face off it.
-- |
-- | break_at(state: state)                   -> cell | nil
-- |     Removes whatever the crosshair is on - the wire on the aimed face
-- |     if there is one, else the cell - and answers it. What comes back
-- |     stays a live object, so it could be put back.
-- |
-- | face_of(nx, ny, nz)                      -> face | nil
-- |     The face index of a unit normal.
-- |
-- | network_from(w: world, from: cell)       -> {cell}
-- |     Every device reachable across the component network, cables and
-- |     touching devices alike.
-- |
-- | attached_case(w: world, cell: cell)      -> cell | nil
-- |     The computer case a block shares a network with.
-- |
-- | save(state: state, path: string)         -> boolean
-- | load(state: state, path: string)         -> number
-- |     The world file: the camera, then one cell or flat thing a line.
-- |     `load` answers how many things it placed, sets the camera when the
-- |     file carried one, and leaves the map empty when there is no file.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     REACH
-- |
-- | @date 2026-09-16 16:00
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local blocks = require("blocks")

local world = {}

--[[ How far the crosshair reaches, in cells. Generous next to Minecraft's five, because this is a
flying editor rather than a game and reaching across a machine is the point. @date 2026-09-16 ]]
local REACH = 48.0

--[[ @brief A fresh map and the per-frame interaction state around it.
-- |
-- | `world` is the C++ object holding the matrix; everything beside it here is Lua's own. `target`
-- | is rewritten by aim() every frame and read by the interface and by the two tools, so exactly
-- | one ray is cast per frame no matter how many things want to know what is under the crosshair.
-- |
-- | @return state - a table with `world` and `target`
-- |
-- | @date 2026-09-16 16:00
--]]
function world.new()
    return {
        world = vc.world_create(),
        target = nil,
    }
end

--[[ @brief The face index of a unit normal, matching `face_e` in world_composer.h.
-- |
-- | The cast answers with a normal vector; the wire map is keyed by a face index. This is the one
-- | place the two are translated, so the ordering of `face_e` is written down in Lua exactly once.
-- |
-- | @param nx  number
-- | @param ny  number
-- | @param nz  number
-- | @return face | nil - nil for anything that is not one of the six unit directions
-- |
-- | @date 2026-09-16 18:00
--]]
function world.face_of(nx, ny, nz)
    if nx == -1 then return blocks.FACE.XNEG elseif nx == 1 then return blocks.FACE.XPOS end
    if ny == -1 then return blocks.FACE.YNEG elseif ny == 1 then return blocks.FACE.YPOS end
    if nz == -1 then return blocks.FACE.ZNEG elseif nz == 1 then return blocks.FACE.ZPOS end
    return nil
end

--[[ @brief Casts the crosshair's ray and records what it met.
-- |
-- | Core: the ray starts at the camera and runs along its line of sight, and C++ marches it through
-- | the matrix. What comes back is the cell coordinate hit, the face normal, and whether the thing
-- | hit was the floor rather than a block. `place_at` is that coordinate plus the normal, which is
-- | the cell a new block would occupy - and it is correct for the floor without a special case,
-- | because a floor hit is reported at y = -1 with an upward normal.
-- |
-- | @param state  state
-- | @return target | nil - a table of `x, y, z, nx, ny, nz, is_ground, cell, place_at, hit, dist`,
-- |         or nil when the ray met nothing within reach. `hit` is the exact point on the surface
-- |         in world units, and `dist` how far along the ray that was - the cell coordinate alone
-- |         cannot give the point, since a cell is a whole cube and the hit is one spot on a face
-- |
-- | @date 2026-09-16 16:00
--]]
function world.aim(state)
    local ex, ey, ez = 0, 0, 0
    local c = vc.cam_get()
    ex, ey, ez = c[1], c[2], c[3]
    local f = vc.cam_forward()

    local hit = state.world:raycast(ex, ey, ez, f[1], f[2], f[3], REACH)
    if not hit[1] then
        state.target = nil
        return nil
    end

    local x, y, z = hit[2], hit[3], hit[4]
    local nx, ny, nz = hit[5], hit[6], hit[7]

    -- The exact point the ray struck, rather than the cell it struck. The cast normalises the
    -- direction before marching, so the distance it answers is in world units and this is a plain
    -- walk along the ray.
    local dist = hit[9]

    -- Which of the six sides was struck. The wire on a face is keyed by exactly this, so the
    -- existing cast already answers "is there a wire where I am pointing" with no extra work.
    local face = world.face_of(nx, ny, nz)

    state.target = {
        x = x, y = y, z = z,
        nx = nx, ny = ny, nz = nz,
        face = face,
        attach = face and state.world:face_get(x, y, z, face) or nil,
        is_ground = hit[8],
        cell = state.world:get(x, y, z),
        place_at = {x + nx, y + ny, z + nz},
        hit = {ex + f[1] * dist, ey + f[2] * dist, ez + f[3] * dist},
        dist = dist,
    }
    return state.target
end

--[[ @brief Puts a computer case against whatever the crosshair is on.
-- |
-- | The new cell goes in the slot the aimed face points into, and is turned to face the camera, so
-- | a case placed on the floor has its screen towards whoever placed it. A slot already occupied,
-- | or one outside the map, refuses rather than overwriting - the block that is already there is
-- | more likely to be wanted than the one being placed on top of it.
-- |
-- | @param state  state
-- | @return cell | nil - the placed cell, or nil when there was nowhere to place it
-- |
-- | @date 2026-09-16 16:00
--]]
function world.place(state, make)
    make = make or blocks.make_case
    local t = state.target
    if not t then
        return nil
    end

    -- The author's rule, 2026-09-16: "you can't place blocks on a redstone face". A face carrying
    -- anything flat is not a surface to build against - a block put there would bury it. The same
    -- holds for a keyboard, which is flat for the same reason and just as buriable.
    if t.attach then
        return nil
    end

    local px, py, pz = t.place_at[1], t.place_at[2], t.place_at[3]
    if state.world:get(px, py, pz) then
        return nil
    end

    local cell = make()
    if blocks.faces_the_click(cell.kind) and t.face then
        -- POINTING AT WHAT IT WAS STUCK TO. The ray struck face `t.face` of the block behind, and
        -- the new cell sits on the far side of it, so the way back is the opposite face - which is
        -- face_e's whole reason for pairing opposites as n and n ~ 1.
        --
        -- A bus in AE2 is a part bolted to the side of the machine it serves, so the face it is on
        -- is what it means. Turning it to face the placer, the way everything else here does, would
        -- lose that.
        cell.facing = t.face ~ 1
    else
        local c = vc.cam_get()
        -- From the block towards the camera, so the front ends up looking back at the placer.
        cell.facing = blocks.facing_towards(c[1] - (px + 0.5), c[3] - (pz + 0.5))
    end

    if not state.world:set(px, py, pz, cell) then
        return nil
    end
    return cell
end

--[[ @brief Lays a redstone wire on the face the crosshair is on.
-- |
-- | Core: the wire goes on the face that was struck, not in the cell beyond it - that is what a
-- | wire is. The world refuses a face that is not exposed or that already carries one, so a second
-- | wire on the same spot, or a wire between two blocks pressed together, both simply do nothing.
-- |
-- | The floor counts. A ground hit is reported at y = -1 with an upward normal, and that is a real
-- | face key, so wiring the floor needs no special case here.
-- |
-- | @param state  state
-- | @return cell | nil - the wire, or nil when the face would not take one
-- |
-- | @date 2026-09-16 18:00
--]]
function world.place_wire(state)
    return world.place_flat(state, blocks.make_wire)
end

--[[ @brief Bolts a keyboard onto the face the crosshair is on.
-- |
-- | Only a case or a screen will take one - the author's rule, 2026-09-16, that a keyboard "sticks
-- | to a side of the case or screen". A floor face has no cell behind it at all, so aiming at the
-- | ground refuses without needing to be named as a special case.
-- |
-- | @param state  state
-- | @return cell | nil
-- |
-- | @date 2026-09-16 20:00
--]]
function world.place_keyboard(state)
    local t = state.target
    if not t then
        return nil
    end
    local host = state.world:get(t.x, t.y, t.z)
    if not host or not blocks.takes_keyboard(host.kind) then
        return nil
    end
    return world.place_flat(state, blocks.make_keyboard)
end

--[[ @brief Lays a flat thing - a wire or a keyboard - on the face the crosshair is on.
-- |
-- | Core: the thing goes on the face that was struck, not in the cell beyond it. The world refuses
-- | a face that is not exposed or that already carries something, so a second attachment on the
-- | same spot, or one between two blocks pressed together, both simply do nothing.
-- |
-- | @param state  state
-- | @param make   function - the creator for the kind being placed
-- | @return cell | nil - what was attached, or nil when the face would not take it
-- |
-- | @date 2026-09-16 20:00
--]]
function world.place_flat(state, make)
    local t = state.target
    if not t or not t.face or t.attach then
        return nil
    end

    local cell = make()
    if not state.world:face_set(t.x, t.y, t.z, t.face, cell) then
        return nil
    end
    return cell
end

--[[ @brief Takes the wire off the face the crosshair is on.
-- |
-- | @param state  state
-- | @return cell | nil - the wire removed, still a live object, or nil when there was none
-- |
-- | @date 2026-09-16 18:00
--]]
function world.break_attach(state)
    local t = state.target
    if not t or not t.face or not t.attach then
        return nil
    end

    local cell = t.attach
    state.world:face_clear(t.x, t.y, t.z, t.face)
    state.target = nil
    return cell
end

--[[ @brief Removes the cell under the crosshair.
-- |
-- | The cell is answered rather than discarded. It stays a perfectly good object after leaving the
-- | map - its `u` table and everything in it survive - which is what a future undo, or a pick-up
-- | tool, would need.
-- |
-- | @param state  state
-- | @return cell | nil - what was removed, or nil when the crosshair was on the floor or on nothing
-- |
-- | @date 2026-09-16 16:00
--]]
function world.break_at(state)
    local t = state.target
    if not t then
        return nil
    end

    -- Anything flat sits in front of the face it clings to, so it is what the crosshair is really
    -- on. Breaking takes that first and the block underneath only once it is gone.
    if t.attach then
        return world.break_attach(state)
    end

    if not t.cell then
        return nil
    end

    local cell = t.cell
    state.world:clear(t.x, t.y, t.z)
    state.target = nil
    return cell
end

--[[ @brief Every device reachable from a block across the component network.
-- |
-- | Core: a flood fill through touching network blocks. Two blocks that share a face are on the
-- | same network, and a cable is a block whose whole purpose is to be touched from both ends - so
-- | reach is the transitive closure of adjacency over cables and devices alike. That is how
-- | OpenComputers behaves: a screen against a case is connected, and a screen at the far end of a
-- | cable run is connected just the same.
-- |
-- | Cables relay but are not themselves devices, so they never come back in the answer. Anything
-- | not on the network at all - a chest, a lamp - stops the fill, which is why a cable running
-- | past a chest connects to nothing there.
-- |
-- | @param w     world
-- | @param from  cell - where to start; itself excluded from the answer
-- | @return {cell} - the devices reachable, each once
-- |
-- | @date 2026-09-17 06:00
--]]
function world.network_from(w, from)
    local found = {}
    if not from or not from:placed() then
        return found
    end

    local dirs = {{-1, 0, 0}, {1, 0, 0}, {0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}}
    local seen = {}
    local queue = {from}
    local head = 1

    local function key(p)
        return p[1] .. "," .. p[2] .. "," .. p[3]
    end
    seen[key(from:pos())] = true

    while head <= #queue do
        local cur = queue[head]
        head = head + 1
        local p = cur:pos()

        for _, d in ipairs(dirs) do
            local n = w:get(p[1] + d[1], p[2] + d[2], p[3] + d[3])
            if n and blocks.on_network(n.kind) then
                local k = key(n:pos())
                if not seen[k] then
                    seen[k] = true
                    -- A cable only relays; a device is both a result and a relay, because in
                    -- OpenComputers a component block is a node of the network too.
                    if n.kind ~= blocks.KIND.CABLE then
                        found[#found + 1] = n
                    end
                    queue[#queue + 1] = n
                end
            end
        end
    end
    return found
end

--[[ @brief The computer case a block is on the network with, if any.
-- |
-- | Adjacency was the whole of the network until cables existed; now it is reach across them, so a
-- | screen at the end of a cable run finds its case exactly as one pressed against it does.
-- |
-- | The first case found wins, and the fill walks the six directions in a fixed order, so a screen
-- | between two computers attaches to the same one every time rather than to whichever the walk
-- | happened to reach first.
-- |
-- | @param w     world - the map to look in
-- | @param cell  cell | nil - the block asking; nil answers nil
-- | @return cell | nil - the case, or nil when none is reachable
-- |
-- | @date 2026-09-16 22:00
--]]
function world.attached_case(w, cell)
    for _, n in ipairs(world.network_from(w, cell)) do
        if n.kind == blocks.KIND.CASE then
            return n
        end
    end
    return nil
end

--[[ @brief Writes the map out, one cell per line.
-- |
-- | Core: Lua owns the save file, which is the author's split - C++ holds the matrix, Lua decides
-- | what a world on disk looks like. The format is one line of `x y z kind state facing`, which is
-- | readable, diffable and trivially extended: a later field is appended and an older file still
-- | loads, because the reader takes what it finds and defaults the rest.
-- |
-- | What is not saved yet is a cell's `u` table. Nothing puts anything durable in it at this
-- | milestone, and inventing a serialisation for arbitrary Lua values before there is something to
-- | serialise would be guessing at the shape of a thing that does not exist.
-- |
-- | @param state  state
-- | @param path   string
-- | @return boolean - false when the file could not be opened for writing
-- |
-- | @date 2026-09-16 16:00
--]]
function world.save(state, path)
    local file = io.open(path, "w")
    if not file then
        return false
    end

    file:write("# gregtech_automation simulator world\n")
    file:write("# k x y z yaw pitch           - where the camera was left\n")
    file:write("# c x y z kind state facing [disk] - a cell; a case also names its disk\n")
    file:write("# w x y z face kind state     - a flat thing clinging to a face\n")
    file:write("# t x y z litres name|label   - what a tank holds\n")

    -- The camera is part of what a saved world is: coming back to a machine and being put down
    -- looking at it is the difference between a save and a list of coordinates.
    local cam = vc.cam_get()
    file:write(string.format("k %.3f %.3f %.3f %.5f %.5f\n",
            cam[1], cam[2], cam[3], cam[4], cam[5]))

    for _, cell in ipairs(state.world:occupied()) do
        local p = cell:pos()
        -- A COMPUTER CARRIES ITS DISK'S ADDRESS, the way the mod keeps it in the item's NBT.
        -- It is what names the folder its files were written to (see saves.lua), so without
        -- it a hard disk and its computer would find each other only by luck on a reload.
        local disk = (cell.kind == blocks.KIND.CASE) and blocks.u(cell).hdd_address or nil
        file:write(string.format("c %d %d %d %d %d %d%s\n",
                p[1], p[2], p[3], cell.kind, cell.state, cell.facing,
                disk and (" " .. disk) or ""))
    end
    -- What each tank holds. On its own line rather than appended to the cell, because a fluid has
    -- three fields of its own and a name that may have spaces in it - "Heavy Fuel" - which a
    -- space-separated cell line could not carry. The litres are written whole; GregTech counts
    -- them in whole litres too.
    for _, cell in ipairs(state.world:occupied()) do
        if cell.kind == blocks.KIND.TANK then
            local held = cell:fluid_get()
            if held[1] ~= "" and held[2] > 0 then
                local p = cell:pos()
                file:write(string.format("t %d %d %d %d %s|%s\n",
                        p[1], p[2], p[3], math.floor(held[2] + 0.5), held[1], held[3]))
            end
        end
    end

    -- The wires go after the cells, and the order is load-bearing: a wire needs the face it clings
    -- to to be exposed, which means the block under it has to exist by the time it is read back.
    for _, entry in ipairs(state.world:occupied_faces()) do
        local at = state.world:face_unkey(entry[1])
        -- THE KIND IS PART OF IT. Without it every flat thing came back as a redstone wire,
        -- which is what turned saved keyboards into wires on the next load.
        file:write(string.format("w %d %d %d %d %d %d\n",
                at[1], at[2], at[3], at[4], entry[2].kind, entry[2].state))
    end
    file:close()
    return true
end

--[[ @brief Reads a map back in, replacing whatever was there.
-- |
-- | The map is wiped first, so loading is a replacement rather than a merge. A line that does not
-- | parse is skipped rather than aborting the load: half a world is more use than none, and a save
-- | file edited by hand is expected to have the occasional mistake in it.
-- |
-- | @param state  state
-- | @param path   string
-- | @return number - how many cells were placed; zero when the file is absent
-- |
-- | @date 2026-09-16 16:00
--]]
function world.load(state, path)
    state.world:wipe()
    state.target = nil

    local file = io.open(path, "r")
    if not file then
        return 0
    end

    local count = 0
    for line in file:lines() do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local kx, ky, kz, kyaw, kpitch = trimmed:match(
                    "^k (-?[%d.]+) (-?[%d.]+) (-?[%d.]+) (-?[%d.]+) (-?[%d.]+)$")
            if kx then
                vc.cam_set(tonumber(kx), tonumber(ky), tonumber(kz),
                        tonumber(kyaw), tonumber(kpitch))
                state.camera_restored = true
            end

            -- A tank's contents. Read before the cell lines are tried, because the letter would
            -- otherwise be taken for part of a coordinate; and applied to a tank that must already
            -- be there, which it is - the cells are written first.
            local tx, ty, tz, tl, trest =
                    trimmed:match("^t (-?%d+) (-?%d+) (-?%d+) (%d+) (.*)$")
            if tx then
                local fname, flabel = trest:match("^([^|]*)|(.*)$")
                fname = fname or trest
                local at = state.world:get(tonumber(tx), tonumber(ty), tonumber(tz))
                if at and at.kind == blocks.KIND.TANK then
                    at:fluid_set(fname, tonumber(tl), flabel or fname)
                end
            end

            -- The six field form carries the kind. The five field one predates it and only ever
            -- held wires, so that is what it reads back as.
            local wx, wy, wz, wface, wkind, wst =
                    trimmed:match("^w (-?%d+) (-?%d+) (-?%d+) (%d+) (%d+) (%d+)$")
            if not wx then
                wx, wy, wz, wface, wst =
                        trimmed:match("^w (-?%d+) (-?%d+) (-?%d+) (%d+) (%d+)$")
                wkind = wx and tostring(blocks.KIND.WIRE) or nil
            end
            if wx then
                local cell = blocks.make_kind(tonumber(wkind))
                cell.state = tonumber(wst)
                if state.world:face_set(tonumber(wx), tonumber(wy), tonumber(wz),
                        tonumber(wface), cell) then
                    count = count + 1
                end
            else
                -- A cell line. The `c` prefix is optional, so a file written before wires existed
                -- still loads unchanged.
                local body = trimmed:match("^c (.*)$") or trimmed
                local x, y, z, kind, st, facing, disk =
                        body:match("^(-?%d+) (-?%d+) (-?%d+) (%d+) (%d+) (%d+)%s*(%S*)$")
                if x then
                    -- Through the kind's own creator, so a drive comes back with its floppy and a
                    -- case with its parts. `blocks.make` would set the number and nothing else.
                    local cell = blocks.make_kind(tonumber(kind))
                    cell.state = tonumber(st)
                    cell.facing = tonumber(facing)
                    -- The trailing field is optional: a save written before disks had their
                    -- own folders has none, and the computer is given a fresh address the
                    -- first time it is started.
                    if disk ~= "" then
                        blocks.u(cell).hdd_address = disk
                    end
                    if state.world:set(tonumber(x), tonumber(y), tonumber(z), cell) then
                        count = count + 1
                    end
                end
            end
        end
    end
    file:close()

    return count
end

return world
