--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | KIND / STATE / FACE                      tables of constants
-- |     The numbers world_composer.h uses, named. Nothing else in
-- |     scripts/ writes one of those integers as a literal.
-- |
-- | KIND_NAME / STATE_NAME                   tables, number -> string
-- |     What to call a kind or a state on screen and in a save file.
-- |
-- | make(kind: number)                       -> cell
-- |     Builds a cell of that kind through the C++ factory and gives it
-- |     its `u` table. THE ONE CREATOR - a cell built by calling
-- |     vc.cell_create directly has no `u` and every reader of it breaks.
-- |
-- | make_kind(kind: number)                  -> cell
-- |     The same, but through that kind's own creator, so the cell comes
-- |     back with whatever belongs in its `u`. What a save file is read
-- |     with.
-- |
-- | make_case()                              -> cell
-- |     A computer case, switched off. A cube, filling a slot.
-- |
-- | make_wire()                              -> cell
-- |     A redstone wire, unpowered. Lives on a face rather than in a
-- |     slot; world:face_set gives it its facing.
-- |
-- | make_cable() / make_chest()              -> cell
-- |     A cable, which carries the component network between blocks, and
-- |     a chest, which holds items in its `u.inventory`.
-- |
-- | make_tank()                              -> cell
-- |     A liquid tank, empty. Iron Tanks' model, a Super Tank IV's
-- |     interface: one fluid, and tank_capacity() litres of room for it.
-- |
-- | make_transposer() / make_redstone()      -> cell
-- |     A transposer, which moves items between the inventories beside
-- |     it, and a redstone I/O block, which reads and emits a signal on
-- |     each of its six sides.
-- |
-- | on_network(kind: number)                 -> boolean
-- |     Is this kind part of the component network?
-- |
-- | u(cell: cell)                            -> table
-- |     The cell's own Lua table, created on first ask. Where a
-- |     script-side field goes; adding one costs no C++ change.
-- |
-- | facing_towards(dx: number, dz: number)   -> face
-- |     Which horizontal face a cell should point to face a viewer
-- |     standing that way.
-- |
-- | describe(cell: cell)                     -> string
-- |     One line about a cell, for the interface.
-- |
-- | @date 2026-09-16 16:00
-- | ===============================================================================================
--]]

local vc = require("virt_composer")

local blocks = {}

--[[ @brief What a cell is. Mirrors `cell_kind_e` in world_composer.h.
-- |
-- | Kept here as plain Lua rather than pushed onto the vc table from C++, because the names belong
-- | to the script layer - C++ needs the numbers and nothing else. The cost is that the two lists
-- | must agree; the benefit is that adding a kind Lua understands, backed by an existing C++ kind,
-- | costs nothing on the other side.
-- |
-- | @date 2026-09-16 16:00
--]]
blocks.KIND = {
    NONE = 0,
    CASE = 1,
    WIRE = 2,
    SCREEN = 3,
    KEYBOARD = 4,
    LAMP = 5,
    DRIVE = 6,
    CABLE = 7,
    CHEST = 8,
    TRANSPOSER = 9,
    REDSTONE = 10,
    TANK = 11,
    IMPORT_BUS = 12,
    EXPORT_BUS = 13,
    QTANK = 14,
}

--[[ @brief What a cell is doing. Mirrors `cell_state_e` in world_composer.h.
-- |
-- | This is the field the author's "modifications on them will make them react" runs through:
-- | writing `cell.state = blocks.STATE.ON` goes to a C++ setter that bumps the world's version, and
-- | the block is drawn with its lit textures on the very next frame. Nothing here has to tell the
-- | renderer anything.
-- |
-- | @date 2026-09-16 16:00
--]]
blocks.STATE = {
    OFF   = 0,
    ON    = 1,
    ERROR = 2,
    BUSY  = 3,
}

--[[ @brief The six faces, ordered as `face_e` in world_composer.h - opposite faces differ by one.
-- | @date 2026-09-16 16:00
--]]
blocks.FACE = {
    XNEG = 0, XPOS = 1,
    YNEG = 2, YPOS = 3,
    ZNEG = 4, ZPOS = 5,
}

blocks.KIND_NAME = {
    [0] = "empty",
    [1] = "computer case",
    [2] = "redstone wire",
    [3] = "screen",
    [4] = "keyboard",
    [5] = "redstone lamp",
    [6] = "disk drive",
    [7] = "cable",
    [8] = "chest",
    [9] = "transposer",
    [10] = "redstone i/o",
    [11] = "liquid tank",
    -- Applied Energistics' own names, out of its en_US.lang.
    [12] = "ME Import Bus",
    [13] = "ME Export Bus",
    [14] = "quantum tank",
}

--[[ @brief Is this kind part of the component network?
-- |
-- | Mirrors `kind_on_network` in world_composer.h. A cable and every device are; a chest is not -
-- | in OpenComputers a chest is an inventory a transposer reaches into, never something the
-- | computer can see for itself.
-- |
-- | @param kind  number
-- | @return boolean
-- |
-- | @date 2026-09-17 06:00
--]]
function blocks.on_network(kind)
    return kind == blocks.KIND.CASE or kind == blocks.KIND.SCREEN
            or kind == blocks.KIND.DRIVE or kind == blocks.KIND.CABLE
            or kind == blocks.KIND.TRANSPOSER or kind == blocks.KIND.REDSTONE
end

--[[ How many slots a chest has. A single vanilla chest, which is the shape every program that
moves items around already expects. @date 2026-09-17 06:00 ]]
blocks.CHEST_SLOTS = 27

--[[ @brief Which kinds lie on a face instead of filling a slot - a wire and a keyboard.
-- |
-- | Mirrors `kind_is_flat` in world_composer.h. Both are flat, both cling to a surface, and neither
-- | can be built upon; everything that treats the two alike asks this rather than naming them.
-- |
-- | @param kind  number
-- | @return boolean
-- |
-- | @date 2026-09-16 20:00
--]]
function blocks.is_flat(kind)
    return kind == blocks.KIND.WIRE or kind == blocks.KIND.KEYBOARD
end

--[[ @brief Which kinds a keyboard will bolt onto.
-- |
-- | The author's rule, 2026-09-16: a keyboard "sticks to a side of the case or screen". It is not a
-- | thing that stands on the floor, and it is not scenery - it is an input device for a machine, so
-- | it has to be attached to one.
-- |
-- | @param kind  number - the kind of the cell whose face is being offered
-- | @return boolean
-- |
-- | @date 2026-09-16 20:00
--]]
function blocks.takes_keyboard(kind)
    return kind == blocks.KIND.CASE or kind == blocks.KIND.SCREEN
end

--[[ @brief Which kinds do something when they are right clicked.
-- |
-- | The game's rule: a block that has something to open or switch on takes the right click, and
-- | sneaking past it is how you place against one instead. A computer starts and stops, a screen
-- | is stepped into, a chest opens. Everything else is scenery as far as a click is concerned, and
-- | a right click on it simply places whatever is selected.
-- |
-- | Kept here rather than in C++ because what a click does belongs to the script layer, and kept in
-- | one function rather than spelled out at each call site so the hint on the screen and the thing
-- | the click actually does cannot drift apart.
-- |
-- | @param kind  number
-- | @return boolean
-- |
-- | @date 2026-09-17 16:00
--]]
function blocks.is_interactive(kind)
    return kind == blocks.KIND.CASE
            or kind == blocks.KIND.SCREEN
            or kind == blocks.KIND.CHEST
            or blocks.is_tank(kind)
end

blocks.FACE_NAME = {
    [0] = "-x", [1] = "+x",
    [2] = "-y", [3] = "+y",
    [4] = "-z", [5] = "+z",
}

blocks.STATE_NAME = {
    [0] = "off",
    [1] = "running",
    [2] = "error",
    [3] = "busy",
}

--[[ @brief The cell's own Lua table, made on first ask.
-- |
-- | Core: a cell is a C++ object with a fixed shape, so everything the script layer wants to
-- | remember about one lives in here instead - the same arrangement as `mexpru.u` in math_writer,
-- | and the reason a cell needs no C++ change to gain a field. The label a user types on a block,
-- | the source file a computer runs, the queue of events waiting for it: all of that belongs here.
-- |
-- | The same table comes back for the same cell every time, because `lua_object_t::push` hands back
-- | what it captured. That makes a `u` a real identity key where the cell handle itself is not.
-- |
-- | @param cell  cell - any live cell
-- | @return table - never nil; one is captured on the first call for a given cell
-- |
-- | @date 2026-09-16 16:00
--]]
function blocks.u(cell)
    local held = cell.u:push()
    if held == nil then
        held = {}
        cell.u:capture(held)
    end
    return held
end

--[[ @brief Builds a cell of `kind`. The one creator.
-- |
-- | Every cell in the simulator comes from here, so every cell has a `u` and a known set of
-- | defaults. Calling `vc.cell_create` directly would work and would produce a cell nothing else in
-- | scripts/ can read properly.
-- |
-- | @param kind  number - one of blocks.KIND
-- | @return cell - not placed anywhere; a world has to take it
-- |
-- | @date 2026-09-16 16:00
--]]
function blocks.make(kind)
    local cell = vc.cell_create(kind)
    blocks.u(cell).born = vc.app_time()
    return cell
end

--[[ @brief A redstone wire, unpowered.
-- |
-- | A wire is a cell like any other - it has a kind, a state and a `u` table - but it does not live
-- | in a slot. It clings to a face, and the world stores it in a separate map keyed by that face.
-- | Its `facing` is set by world:face_set to the side it lies on, so nothing here picks one.
-- |
-- | @return cell - not attached to anything; a face has to take it
-- |
-- | @date 2026-09-16 18:00
--]]
function blocks.make_wire()
    local cell = blocks.make(blocks.KIND.WIRE)
    cell.state = blocks.STATE.OFF
    return cell
end

--[[ @brief What a freshly crafted computer case comes with installed.
-- |
-- | The author's specification, 2026-09-16: an APU at "highest craftable tier all components, so
-- | non creative ones", RAM sticks, a Lua EEPROM and a disk. The tiers are read off the mod's own
-- | language file rather than guessed - GTNH's en_US.lang tops out at APU tier 3, Memory tier 3.5
-- | and Hard Disk Drive tier 3, with the creative APU commented out, which is what "non creative"
-- | settles on.
-- |
-- | This is inventory, so it lives in the cell's `u` rather than in C++. When the emulator arrives
-- | it reads the list from here and builds the machine's components out of it; until then it is a
-- | description that the interface can already show.
-- |
-- | @return table - a list of `{item = , tier = , slot = }`
-- |
-- | @date 2026-09-16 22:00
--]]
function blocks.default_case_parts()
    return {
        {item = "Accelerated Processing Unit (APU)", tier = "3",   slot = "cpu"},
        {item = "Memory",                            tier = "3.5", slot = "ram"},
        {item = "Memory",                            tier = "3.5", slot = "ram"},
        {item = "EEPROM (Lua BIOS)",                 tier = "-",   slot = "eeprom"},
        {item = "Hard Disk Drive",                   tier = "3",   slot = "hdd"},
    }
end

--[[ @brief A length of OpenComputers cable.
-- |
-- | A block filling its cell, not a flat thing clinging to a face - it joins to whatever sits
-- | against its six sides, which is cell adjacency and nothing subtler. The author, 2026-09-17:
-- | it "forms a link with another cable on a neighboring face of the cube, not on an edge of a
-- | face", which is what separates it from a redstone wire.
-- |
-- | @date 2026-09-17 06:00
--]]
function blocks.make_cable()
    return blocks.make(blocks.KIND.CABLE)
end

--[[ @brief A chest, empty.
-- |
-- | Its inventory lives in `u`, as a sparse table of slot to `{name, count}`. That is script-layer
-- | state and belongs nowhere near C++, which knows only that a chest is a cube.
-- |
-- | @date 2026-09-17 06:00
--]]
function blocks.make_chest()
    local cell = blocks.make(blocks.KIND.CHEST)
    -- The slots live on the C++ cell, not in `u`: a transposer is a component inside a guest
    -- machine and cannot reach a Lua table belonging to the simulator's own scripts.
    cell:inv_resize(blocks.CHEST_SLOTS)
    return cell
end

--[[ @brief A liquid tank, empty.
-- |
-- | Core: the author asked on 2026-09-17 for Iron Tanks' model with a Super Tank IV's interface.
-- | That is what it is - the block is drawn as an iron tank, and what a transposer sees when it
-- | looks at one is GregTech's digital tank: one fluid, thirty-two million litres of room.
-- |
-- | The fluid lives on the C++ cell rather than in `u`, for the same reason a chest's slots do: a
-- | transposer is a component running inside a guest machine and cannot reach a Lua table belonging
-- | to the simulator's own scripts.
-- |
-- | It starts empty. Which fluid it holds is configured by right clicking it, not chosen here -
-- | there is no sensible default, and a tank that arrived full of something would be a surprise.
-- |
-- | @date 2026-09-17 16:00
--]]
function blocks.make_tank()
    return blocks.make(blocks.KIND.TANK)
end

--[[ @brief A quantum tank, empty.
-- |
-- | Core: THE SAME TANK, SIXTEEN TIMES THE SIZE. GregTech's Quantum Tank III holds 512,000,000
-- | litres against a Super Tank IV's 32,000,000, and a scenario standing a row of them up as a
-- | fluid bank needs the bigger one. The author asked on 2026-09-17 for a second variant rather
-- | than for every tank to grow, because the rest of a scene's tanks stand for ordinary input and
-- | output connections and should stay small.
-- |
-- | It keeps the iron tank's model on purpose - the author liked it, and being able to see what is
-- | inside is worth more here than matching GregTech's opaque casing.
-- |
-- | @date 2026-09-17 ]]
function blocks.make_qtank()
    return blocks.make(blocks.KIND.QTANK)
end

--[[ @brief Is this kind a tank of either size? @date 2026-09-17 ]]
function blocks.is_tank(kind)
    return kind == blocks.KIND.TANK or kind == blocks.KIND.QTANK
end

--[[ @brief How many litres a tank holds when it is full.
-- |
-- | GregTech's own number for a Super Tank IV, read out of the mod rather than guessed: tier four
-- | of GT_MetaTileEntity_DigitalTankBase.commonSizeCompute is 32,000,000. The quest book rounds
-- | these to powers of two in its prose; the code does not.
-- |
-- | @return number
-- |
-- | @date 2026-09-17 16:00
--]]
function blocks.tank_capacity()
    return vc.render_tank_capacity()
end

--[[ @brief An ME import bus, and an ME export bus.
-- |
-- | SCENERY. The author asked on 2026-09-17 for "the object/blocks", not the behaviour: these carry
-- | no component, join no network and move nothing. They are here so an AE2 setup can be laid out
-- | and looked at.
-- |
-- | Both always point at the face they were placed against - see blocks.faces_the_click.
-- |
-- | @date 2026-09-17 18:00
--]]
function blocks.make_import_bus()
    return blocks.make(blocks.KIND.IMPORT_BUS)
end

function blocks.make_export_bus()
    return blocks.make(blocks.KIND.EXPORT_BUS)
end

--[[ @brief Does this kind point at the face it was placed against, rather than at the placer?
-- |
-- | Core: most blocks here turn to face whoever put them down, which is what you want of a screen
-- | or a computer. A bus is the other thing entirely - in AE2 it is a part bolted onto the side of
-- | the machine it works on, so which face it is stuck to is the whole of its meaning. The author,
-- | 2026-09-17: they "should be allways be placed facing the face I've clicked".
-- |
-- | @param kind  number
-- | @return boolean
-- |
-- | @date 2026-09-17 18:00
--]]
function blocks.faces_the_click(kind)
    return kind == blocks.KIND.IMPORT_BUS or kind == blocks.KIND.EXPORT_BUS
end

--[[ @brief A transposer.
-- |
-- | Core: in OpenComputers a transposer sits between two inventories and moves items from one to
-- | the other on command, addressed by the side it should reach into. It is on the component
-- | network, so a computer can see it; what it reaches into - a chest - is not.
-- |
-- | It has no state of its own worth keeping yet. The methods a program calls on it,
-- | `transferItem` and the rest, arrive with the item model.
-- |
-- | @date 2026-09-17 07:00
--]]
function blocks.make_transposer()
    return blocks.make(blocks.KIND.TRANSPOSER)
end

--[[ @brief A redstone I/O block, quiet on every side.
-- |
-- | Core: this is how a computer touches the world. It reads the signal coming in on each of its
-- | six sides and emits one on each, which is what `getInput` and `setOutput` are asking about -
-- | and this repository's own programs call `setOutput` six times over.
-- |
-- | The levels live in `u`, one per side, because they are per-block state the script layer owns.
-- |
-- | @date 2026-09-17 07:00
--]]
function blocks.make_redstone()
    local cell = blocks.make(blocks.KIND.REDSTONE)
    blocks.u(cell).output = {[0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0}
    blocks.u(cell).input  = {[0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0}
    return cell
end

--[[ @brief A redstone lamp, dark. @date 2026-09-16 22:00 ]]
function blocks.make_lamp()
    local cell = blocks.make(blocks.KIND.LAMP)
    cell.state = blocks.STATE.OFF
    return cell
end

--[[ @brief A disk drive, with a floppy already in it.
-- |
-- | The author asked on 2026-09-16 for a drive that "will auto spawn with the lua os inserted", so
-- | the floppy is part of what the block is rather than something to be found and inserted. The
-- | contents are named here and read out of the OpenComputers jar when the emulator needs them -
-- | OpenOS ships inside it, under assets/opencomputers/loot/openos.
-- |
-- | @date 2026-09-16 22:00
--]]
function blocks.make_drive()
    local cell = blocks.make(blocks.KIND.DRIVE)
    blocks.u(cell).floppy = {label = "openos", source = "loot/openos", read_only = true}
    return cell
end

--[[ @brief A screen, switched off. A cube whose front carries the display.
-- | @date 2026-09-16 20:00 ]]
function blocks.make_screen()
    local cell = blocks.make(blocks.KIND.SCREEN)
    cell.state = blocks.STATE.OFF
    -- Where a machine's console output will land. Empty until something is running; the mini view
    -- reads it from here, so the plumbing is the same before and after there is a machine.
    blocks.u(cell).lines = {}
    return cell
end

--[[ @brief A keyboard. Flat, and only bolts onto a case or a screen. @date 2026-09-16 20:00 ]]
function blocks.make_keyboard()
    return blocks.make(blocks.KIND.KEYBOARD)
end

--[[ @brief A computer case, switched off. @date 2026-09-16 16:00 ]]
function blocks.make_case()
    local cell = blocks.make(blocks.KIND.CASE)
    cell.state = blocks.STATE.OFF
    blocks.u(cell).parts = blocks.default_case_parts()
    return cell
end

--[[ @brief Builds a cell of `kind` through that kind's own creator.
-- |
-- | Core: THE ONE WAY TO REBUILD A CELL FROM A NUMBER. A kind is more than an integer - a disk
-- | drive arrives with a floppy in it, a case with its parts, a chest with an inventory, a redstone
-- | block with six levels - and all of that lives in `u`, put there by the creator.
-- |
-- | Loading a world went through `blocks.make(kind)` instead, which sets the number and nothing
-- | else. Every saved drive came back without its floppy, so a computer that had booted perfectly
-- | well before the reload had nothing to boot from after it. Anything that rebuilds a cell from a
-- | saved number goes through here.
-- |
-- | @param kind  number - one of blocks.KIND
-- | @return cell
-- |
-- | @date 2026-09-17 08:00
--]]
function blocks.make_kind(kind)
    local makers = {
        [blocks.KIND.CASE]       = blocks.make_case,
        [blocks.KIND.WIRE]       = blocks.make_wire,
        [blocks.KIND.SCREEN]     = blocks.make_screen,
        [blocks.KIND.KEYBOARD]   = blocks.make_keyboard,
        [blocks.KIND.LAMP]       = blocks.make_lamp,
        [blocks.KIND.DRIVE]      = blocks.make_drive,
        [blocks.KIND.CABLE]      = blocks.make_cable,
        [blocks.KIND.CHEST]      = blocks.make_chest,
        [blocks.KIND.TRANSPOSER] = blocks.make_transposer,
        [blocks.KIND.REDSTONE]   = blocks.make_redstone,
        [blocks.KIND.TANK]       = blocks.make_tank,
        [blocks.KIND.IMPORT_BUS] = blocks.make_import_bus,
        [blocks.KIND.EXPORT_BUS] = blocks.make_export_bus,
        [blocks.KIND.QTANK]      = blocks.make_qtank,
    }
    local make = makers[kind]
    if make then
        return make()
    end
    return blocks.make(kind)
end

--[[ @brief Which horizontal face should point at a viewer standing in the direction (dx, dz).
-- |
-- | Used when a block is placed, so its front ends up looking back at whoever put it down - which
-- | is what Minecraft does and what makes a case's screen readable without turning it afterwards.
-- | The larger of the two components decides the axis, so a diagonal snaps to the nearer face.
-- |
-- | @param dx  number - the x component of the direction from the block towards the viewer
-- | @param dz  number - the z component of the same direction
-- | @return face - one of the four horizontal members of blocks.FACE
-- |
-- | @date 2026-09-16 16:00
--]]
function blocks.facing_towards(dx, dz)
    if math.abs(dx) > math.abs(dz) then
        return dx > 0 and blocks.FACE.XPOS or blocks.FACE.XNEG
    end
    return dz > 0 and blocks.FACE.ZPOS or blocks.FACE.ZNEG
end

--[[ @brief One line describing a cell, for the interface.
-- |
-- | @param cell  cell | nil - nil answers "nothing", so a caller with no target needs no guard
-- | @return string
-- |
-- | @date 2026-09-16 16:00
--]]
function blocks.describe(cell)
    if not cell then
        return "nothing"
    end
    local pos = cell:pos()
    local what = string.format("%s (%s) at %d, %d, %d",
            blocks.KIND_NAME[cell.kind] or "unknown",
            blocks.STATE_NAME[cell.state] or "unknown",
            pos[1], pos[2], pos[3])
    if blocks.is_flat(cell.kind) then
        what = what .. " on " .. (blocks.FACE_NAME[cell.facing] or "?")
    end
    return what
end

return blocks
