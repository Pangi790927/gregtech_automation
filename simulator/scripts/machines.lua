--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | of(cell: cell)                           -> machine | nil
-- |     The machine belonging to a computer case, made on the first ask.
-- |     Anything that is not a case answers nil.
-- |
-- | start(cell, w: world, mc_path: string)    -> boolean
-- | stop(cell: cell)                          -> nothing
-- | toggle(cell, w: world, mc_path: string)   -> boolean
-- |     Turn a case on or off. Starting gathers whatever is plugged into
-- |     the case first - its hard disk, and the floppy in any disk drive
-- |     standing against it. `toggle` answers whether it runs afterwards.
-- |
-- | step_all(w: world)                        -> nothing
-- |     Gives every live machine its slice of the frame, reconciling its
-- |     components first whenever the world has changed.
-- |
-- | save_disks(state, path) / load_disks(state, path)
-- |     Every machine's hard disk, written beside the world file. An
-- |     installed operating system has to outlive the session.
-- |
-- | output(cell: cell)                        -> {string}
-- |     What a case has printed. A screen shows this.
-- |
-- | screen_output(w: world, screen: cell)     -> {string}, cell | nil, boolean
-- |     What a screen is displaying, the case behind it, and whether what
-- |     came back is a GRID rather than a log. A grid is every row of the
-- |     screen in order and must be drawn whole, from the top; a log is
-- |     the host-side boot messages and reads from the bottom. A grid
-- |     also answers where the cursor is, as {x, y} or zeroes, and the
-- |     rows again as coloured runs of {foreground, background, text}.
-- |
-- | send_key(w, cell, ch, code, down)         -> boolean
-- | has_keyboard(w: world, cell: cell)        -> boolean
-- |     Typing at a screen, and whether anything is listening.
-- |
-- | reconcile(w: world, case: cell)           -> nothing
-- |     Brings a machine's components level with what the world says is
-- |     attached to it. Everything is hot swappable, always.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     live
-- |
-- | @date 2026-09-16 23:30
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local blocks = require("blocks")
local world = require("world")

local machines = {}

--[[ Every machine that has been made, so step_all has something to walk. A case keeps its own
machine in its `u`, but nothing walks the map looking for cases every frame - this list is the
registry, and a machine stays on it until the world is wiped. @date 2026-09-16 ]]
local live = {}

--[[ @brief The machine belonging to a case, created on the first ask.
-- |
-- | Core: a machine is per case, and it lives in that case's `u` - which is what `u` is for. The
-- | cell is a C++ object with a fixed shape; the machine attached to it is a script-layer concern
-- | and needs no field in C++.
-- |
-- | The machine is created but not started. A case on the ground is a computer that is switched
-- | off, and switching it on is something the player does.
-- |
-- | @param cell  cell | nil - a computer case; anything else answers nil
-- | @return machine | nil
-- |
-- | @date 2026-09-16 23:30
--]]
function machines.of(cell)
    if not cell or cell.kind ~= blocks.KIND.CASE then
        return nil
    end
    local u = blocks.u(cell)
    if not u.machine then
        u.machine = vc.machine_create()
        -- The cell goes on the registry beside its machine, because keeping a machine's components
        -- level with the world means knowing which block it belongs to, every frame.
        live[#live + 1] = {cell = cell, machine = u.machine, seen_version = -1}
    end
    return u.machine
end

--[[ @brief One cell's place in the world, as a key a table can be indexed by. @date 2026-09-17 ]]
local function cellkey(cell)
    local p = cell:pos()
    return p[1] .. "," .. p[2] .. "," .. p[3]
end

--[[ @brief Brings a machine's components level with what is actually attached to it in the world.
-- |
-- | Core: EVERYTHING IS HOT SWAPPABLE, ALWAYS. This runs whenever the world changes, not only at
-- | boot, so a transposer placed against a running computer becomes a component it can see the
-- | moment it is placed, and breaking one takes it away again. That is how OpenComputers behaves -
-- | the mod fires `component_added` and `component_removed` at runtime and everything reacts - and
-- | it is what this did not do at first, gathering everything once at boot instead. The result was
-- | a block that was plainly there and plainly invisible to the machine.
-- |
-- | What is attached is remembered per block, keyed by where the block is, so the comparison is
-- | between two sets rather than a guess: anything in the world and not on the machine is added,
-- | anything on the machine and no longer in the world is removed.
-- |
-- | Screens are done before keyboards, because a keyboard is attached TO a screen and needs its
-- | address to exist first.
-- |
-- | @param w     world
-- | @param case  cell - a computer case
-- |
-- | @date 2026-09-17 09:00
--]]
function machines.reconcile(w, case)
    local u = blocks.u(case)
    local m = u.machine
    if not m or not case:placed() then
        return
    end
    u.attached = u.attached or {}

    local want = {}

    -- Pass one: the devices that sit in cells.
    local screens = {}
    for _, n in ipairs(world.network_from(w, case)) do
        local key = cellkey(n)
        if n.kind == blocks.KIND.SCREEN then
            want[key] = true
            if not u.attached[key] then
                local addr = vc.machine_add_screen(m)
                blocks.u(n).screen_address = addr
                u.attached[key] = {addr}
            end
            screens[#screens + 1] = {cell = n, address = blocks.u(n).screen_address}
        elseif n.kind == blocks.KIND.DRIVE then
            want[key] = true
            if not u.attached[key] then
                local floppy = blocks.u(n).floppy
                local addr = floppy and floppy.source
                        and vc.machine_add_floppy(m, floppy.label or "floppy", floppy.source)
                u.attached[key] = {addr}
            end
        elseif n.kind == blocks.KIND.TRANSPOSER then
            want[key] = true
            if not u.attached[key] then
                local addr = vc.machine_add_transposer(m)
                blocks.u(n).address = addr
                u.attached[key] = {addr}
            end
        elseif n.kind == blocks.KIND.REDSTONE then
            want[key] = true
            if not u.attached[key] then
                local addr = vc.machine_add_redstone(m)
                blocks.u(n).address = addr
                u.attached[key] = {addr}
            end
        end
    end

    -- Pass two: the keyboards, which live on the faces of a screen or of the case itself.
    local hosts = {{cell = case, address = screens[1] and screens[1].address}}
    for _, scr in ipairs(screens) do
        hosts[#hosts + 1] = {cell = scr.cell, address = scr.address}
    end
    for _, host in ipairs(hosts) do
        if host.address then
            local p = host.cell:pos()
            for face = 0, 5 do
                local att = w:face_get(p[1], p[2], p[3], face)
                if att and att.kind == blocks.KIND.KEYBOARD then
                    local key = "kb:" .. cellkey(host.cell) .. ":" .. face
                    want[key] = true
                    if not u.attached[key] then
                        local addr = vc.machine_add_keyboard(m, host.address)
                        u.attached[key] = {addr}
                        u.keyboard = u.keyboard or addr
                    end
                end
            end
        end
    end

    -- Whatever is on the machine and no longer in the world goes.
    for key, addrs in pairs(u.attached) do
        if not want[key] then
            for _, addr in ipairs(addrs) do
                if addr then
                    vc.machine_remove_component(m, addr)
                    if u.keyboard == addr then
                        u.keyboard = nil
                    end
                end
            end
            u.attached[key] = nil
        end
    end
end

--[[ @brief Starts the machine in a case.
-- |
-- | Core: the machine is cleared and given the parts that are inside the case itself - its EEPROM,
-- | its scratch filesystem and its hard disk - and then everything attached to it in the world is
-- | reconciled on, exactly as it will be on every later change. Only then does it start, and the
-- | BIOS looks through the filesystems it can see for one with an `/init.lua` to boot.
-- |
-- | So a bare computer with a blank disk finds nothing and says so, and the same computer with an
-- | OpenOS drive on its network boots into the operating system - which is the author's
-- | description of how it should work, 2026-09-17: "someone brings an os disk and connect it to
-- | the pc, when connected, the pc would find it on start and boot from it".
-- |
-- | @param cell     cell - a computer case
-- | @param w        world
-- | @param mc_path  string - the Minecraft instance to read the mod's Lua from
-- | @return boolean - whether it came up
-- |
-- | @date 2026-09-17 00:30
--]]
function machines.start(cell, w, mc_path)
    local m = machines.of(cell)
    if not m then
        return false
    end

    if not vc.machine_prepare(m, mc_path or "") then
        cell.state = blocks.STATE.ERROR
        return false
    end

    -- Every component is built fresh by prepare, so what was recorded before is gone with it.
    local u = blocks.u(cell)
    u.attached = {}
    u.keyboard = nil

    -- The case's own hard disk, out of the parts it was crafted with.
    vc.machine_add_hdd(m, "hdd")

    -- Everything the world says is attached. The same call keeps it level from now on.
    machines.reconcile(w, cell)

    local ok = vc.machine_boot(m)
    -- The case's own state drives its textures, so a running computer lights up without anything
    -- else being told about it.
    cell.state = ok and blocks.STATE.ON or blocks.STATE.ERROR
    return ok
end

--[[ @brief Stops the machine in a case and lets its Lua state go. @date 2026-09-16 23:30 ]]
function machines.stop(cell)
    local m = machines.of(cell)
    if not m then
        return
    end
    vc.machine_stop(m)
    cell.state = blocks.STATE.OFF
end

--[[ @brief Starts a stopped case, stops a running one.
-- |
-- | @param cell     cell
-- | @param mc_path  string
-- | @return boolean - whether it is running afterwards
-- |
-- | @date 2026-09-16 23:30
--]]
function machines.toggle(cell, w, mc_path)
    local m = machines.of(cell)
    if not m then
        return false
    end
    if m:running() then
        machines.stop(cell)
        return false
    end
    return machines.start(cell, w, mc_path)
end

--[[ @brief Gives every live machine its slice of this frame.
-- |
-- | Core: each machine is resumed until it asks to wait, faults, or spends the budget C++ allows a
-- | single step. That budget is what keeps a computer in a tight loop from starving the renderer -
-- | everything here runs on one thread.
-- |
-- | A machine that has stopped or faulted on its own is reflected back onto whichever case owns it,
-- | so a computer that crashes shows it on the outside.
-- |
-- | @date 2026-09-16 23:30
--]]
function machines.step_all(w)
    local version = w and w:get_version() or 0
    for _, entry in ipairs(live) do
        if entry.cell:placed() then
            -- Components are brought level whenever the world has changed, which is the whole of
            -- what makes everything hot swappable: the world's version moves on every placement
            -- and every break, and on nothing else, so this costs one comparison on a still world.
            if w and version ~= entry.seen_version then
                machines.reconcile(w, entry.cell)
                entry.seen_version = version
            end
            vc.machine_step(entry.machine)
        end
    end
end

--[[ @brief Keeps a case's lit texture in step with its machine. @date 2026-09-16 23:30 ]]
function machines.sync(cell)
    local u = blocks.u(cell)
    local m = u.machine
    if not m then
        return
    end
    local st = m:get_status()
    local want = blocks.STATE.OFF
    if st == 1 then
        want = blocks.STATE.ON
    elseif st == 2 then
        want = blocks.STATE.ERROR
    elseif st == 3 then
        want = blocks.STATE.BUSY
    end
    if cell.state ~= want then
        cell.state = want
    end
end

--[[ @brief What a case has printed, as a list of lines.
-- |
-- | @param cell  cell | nil
-- | @return {string} - empty when there is no machine
-- |
-- | @date 2026-09-16 23:30
--]]
function machines.output(cell)
    local u = cell and blocks.u(cell)
    local m = u and u.machine
    if not m then
        return {}
    end
    local out = {}
    for i = 1, m:output_len() do
        out[i] = m:output_at(i)
    end
    return out
end

--[[ @brief What the case a screen is attached to has printed.
-- |
-- | @param w       world
-- | @param screen  cell - a screen
-- | @return {string}, cell | nil, boolean - the lines, the case they came from, and whether
-- |         they are a screen grid rather than a boot log
-- |
-- | @date 2026-09-16 23:30
--]]
function machines.screen_output(w, screen)
    local host = world.attached_case(w, screen)
    if not host then
        return {}, nil
    end
    machines.sync(host)

    -- Once the machine has a screen of its own, what it is displaying is the truth. The host-side
    -- boot log is only what there is to show before a graphics card exists.
    local m = blocks.u(host).machine
    if m and m:has_screen() then
        local size = m:screen_size()
        local rows = {}
        for y = 1, size[2] do
            rows[y] = m:screen_row(y)
        end

        -- THE WHOLE GRID, blank rows and all, and not a line of it dropped.
        --
        -- A screen is not a scrolling log. It is a fixed grid that a full-screen program lays out
        -- deliberately: `edit` puts the file at the top and its status bar on the last row.
        -- Trimming the blanks, or showing only the rows that happen to fit, silently hides
        -- whichever part the caller decided was expendable - which was the top, so a file being
        -- typed was invisible while the status bar underneath it looked perfectly alive.
        -- The colours travel beside the text, as runs. Without them the terminal is monochrome
        -- and the cursor - which a terminal draws by inverting a cell - cannot be seen at all.
        local runs = {}
        for y = 1, size[2] do
            runs[y] = m:screen_row_runs(y)
        end
        return rows, host, true, m:screen_cursor(), runs
    end

    return machines.output(host), host, false, nil, nil
end

--[[ @brief Writes every machine's hard disk out.
-- |
-- | Core: an installed operating system has to survive closing the simulator, or `install` is a
-- | thing you do once per session rather than once per computer. The world file holds blocks; this
-- | holds what is on their disks, which is a different kind of thing and a great deal larger - a
-- | fresh OpenOS install is about a hundred and eighty files.
-- |
-- | The format is length prefixed rather than line based, because the contents are file data and a
-- | Lua source file is full of newlines. Each entry is a header line naming the machine, the path
-- | and the exact byte count, then that many bytes verbatim.
-- |
-- | A machine is named by where its case is, which is what ties a disk back to a computer when the
-- | world is read again.
-- |
-- | @param state  state
-- | @param path   string
-- | @return boolean - false when the file could not be opened for writing
-- |
-- | @date 2026-09-17 10:00
--]]
function machines.save_disks(state, path)
    local file = io.open(path, "wb")
    if not file then
        return false
    end

    file:write("# gregtech_automation simulator disks\n")
    file:write("# f <x> <y> <z> <bytes> <path>, then that many bytes\n")

    for _, cell in ipairs(state.world:occupied()) do
        if cell.kind == blocks.KIND.CASE then
            local m = blocks.u(cell).machine
            if m then
                local p = cell:pos()
                for _, name in ipairs(vc.machine_hdd_files(m)) do
                    local data = vc.machine_hdd_read(m, name)
                    file:write(string.format("f %d %d %d %d %s\n",
                            p[1], p[2], p[3], #data, name))
                    file:write(data)
                    file:write("\n")
                end
            end
        end
    end
    file:close()
    return true
end

--[[ @brief Reads the disks back, onto the machines of the cases they belong to.
-- |
-- | Called after the world is loaded, so the cases exist to attach them to. A machine is made for
-- | each case that has files, which is why a computer can be started and find its system already
-- | installed without having been booted first.
-- |
-- | A disk naming a case that is no longer there is skipped rather than being an error: a world
-- | where somebody broke a computer is a perfectly ordinary world.
-- |
-- | @param state  state
-- | @param path   string
-- | @return number - how many files were restored
-- |
-- | @date 2026-09-17 10:00
--]]
function machines.load_disks(state, path)
    local file = io.open(path, "rb")
    if not file then
        return 0
    end

    local count = 0
    while true do
        local line = file:read("l")
        if not line then
            break
        end
        if line:sub(1, 1) ~= "#" and line ~= "" then
            local x, y, z, bytes, name =
                    line:match("^f (-?%d+) (-?%d+) (-?%d+) (%d+) (.*)$")
            if x then
                local data = file:read(tonumber(bytes)) or ""
                file:read("l")      -- the newline written after the data
                local cell = state.world:get(tonumber(x), tonumber(y), tonumber(z))
                if cell and cell.kind == blocks.KIND.CASE then
                    local m = machines.of(cell)
                    if vc.machine_hdd_write(m, name, data) then
                        count = count + 1
                    end
                end
            end
        end
    end
    file:close()
    return count
end

--[[ @brief Sends a typed character to the machine a screen belongs to.
-- |
-- | Core: the signal carries the keyboard's address, and OpenOS checks it against the screen's own
-- | keyboards before letting a program see the key. So a screen with no keyboard bolted to it
-- | swallows everything typed at it, which is the behaviour the game has.
-- |
-- | @param w     world
-- | @param cell  cell - the screen being typed at
-- | @param ch    number - the character's code point, or 0 for a key that makes none
-- | @param code  number - the key code, which is what a program compares against keyboard.keys
-- | @param down  boolean | nil - false for a release; nil means a press
-- | @return boolean - whether anything took it
-- |
-- | @date 2026-09-17 01:30
--]]
function machines.send_key(w, cell, ch, code, down)
    local host = world.attached_case(w, cell)
    if not host then
        return false
    end
    local u = blocks.u(host)
    if not u.machine or not u.keyboard then
        return false
    end
    if down == nil then
        down = true
    end
    if down then
        -- Counted so the focused view can say whether keys are leaving this side at all.
        local ui = package.loaded["ui"]
        if ui then
            ui.keys_sent = (ui.keys_sent or 0) + 1
        end
    end
    return vc.machine_key(u.machine, u.keyboard, ch or 0, code or 0, down)
end

--[[ @brief Is there a keyboard the machine behind this screen will listen to?
-- | @date 2026-09-17 01:30 ]]
function machines.has_keyboard(w, cell)
    local host = world.attached_case(w, cell)
    return host ~= nil and blocks.u(host).keyboard ~= nil
end

return machines
