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
-- | step_all(w: world, dt: number)            -> nothing
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
local saves = require("saves")
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
        -- THE DISK'S ADDRESS IS SETTLED HERE, the moment the machine exists, and not later when
        -- the disk is booted or written out. It names the folder the files are saved into and it
        -- is written into the map beside the computer, so anything that settled it later would
        -- depend on the map being saved after the disks - and the first save after loading an
        -- older world wrote a map with no address in it, for exactly that reason.
        u.hdd_address = vc.machine_hdd_address(u.machine, u.hdd_address or "")
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
                local p = n:pos()
                local addr = vc.machine_add_transposer(m, w, p[1], p[2], p[3])
                blocks.u(n).address = addr
                u.attached[key] = {addr}
            end
        elseif n.kind == blocks.KIND.REDSTONE then
            want[key] = true
            if not u.attached[key] then
                local p = n:pos()
                local addr = vc.machine_add_redstone(m, w, p[1], p[2], p[3])
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
    -- THE ADDRESS IS REMEMBERED, not made fresh each time. It names the folder this disk
    -- was saved into, the way the mod keeps a filesystem's address in the item's NBT, and
    -- world.lua writes it out beside the computer. A case that has never run has none yet
    -- and is given one here.
    vc.machine_add_hdd(m, "hdd", machines.hdd_address(cell))

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
function machines.step_all(w, dt)
    --[[ THE COMPUTERS' CLOCK MOVES WITH THE WORLD'S, and this is the only place it moves.
    --
    -- A computer in Minecraft lives inside the world's tick loop: wind the world forward and it
    -- goes with it. `dt` is how much of the world's time this step is worth - a simulated substep
    -- in a scenario, a real frame in the sandbox - and without it a fast-forwarded world would leave
    -- every program thinking at its own unhurried pace while the base raced ahead of it.
    --
    -- One step per world tick, so a program gets exactly the share of the processor it would get in
    -- the game rather than one slice a frame however much world went past. @date 2026-09-18 ]]
    vc.machine_advance_clock(dt or 0)

    local version = w and w:get_topology_version() or 0
    for _, entry in ipairs(live) do
        if entry.cell:placed() then
            --[[ Components are brought level whenever a block has been PLACED OR BROKEN, which is
            -- the whole of what makes everything hot swappable, and costs one comparison otherwise.
            --
            -- Not the world's general version: that moves whenever ANYTHING changes, a tank's
            -- contents included. Reconciling on that was a full component scan per machine per
            -- step, and once the computers began stepping with every world tick rather than once a
            -- frame it became four hundred scans a frame - which looks exactly like a hang. ]]
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

--[[ @brief Every file on a hard disk's folder, as paths relative to it.
-- |
-- | A directory on the host is a directory here, so `home/prog.lua` on the guest is a real `home`
-- | folder with a real `prog.lua` inside it - being able to open a program in a text editor is the
-- | whole point of keeping a disk as a folder rather than as a packed file.
-- |
-- | @param dir     string - the folder to walk
-- | @param prefix  string - what has been walked into so far, "" at the top
-- | @param out     table - collected paths, appended to
-- |
-- | @date 2026-09-17 14:00
--]]
local function walk_disk(dir, prefix, out)
    for _, name in ipairs(vc.path_list_dir(dir)) do
        local full = dir .. "/" .. name
        local rel = (prefix == "") and name or (prefix .. "/" .. name)
        if vc.path_is_dir(full) then
            walk_disk(full, rel, out)
        else
            out[#out + 1] = rel
        end
    end
end

--[[ @brief Writes out what is on every machine's hard disk, one folder per disk.
-- |
-- | Core: a disk is a directory of real files, named by its address, under the save's
-- | `opencomputers` folder - which is how the mod stores filesystems, and means a program can be
-- | read and edited from outside the simulator.
-- |
-- | THE FOLDER IS CLEARED FIRST. Writing over it would leave a file the guest had deleted lying on
-- | the host, and it would come back on the next load; a save would end up being the union of every
-- | state the disk had ever been in rather than the state it is in.
-- |
-- | Separate from the map because it is a different kind of thing, and a great deal larger: a fresh
-- | OpenOS install is about a hundred and eighty files, against a map of a dozen lines.
-- |
-- | @param state  state
-- | @return number - how many files were written
-- |
-- | @date 2026-09-17 14:00
--]]
--[[ @brief The address of a case's hard disk, making one if it has never had one.
-- |
-- | Core: what names the disk's folder in the save, and the field world.lua writes out beside the
-- | computer so the two find each other again. The work is in machines.of, which settles the
-- | address as soon as a machine exists; this makes sure there IS a machine first, for a case that
-- | was loaded out of a map and never switched on.
-- |
-- | @param cell  cell - a case
-- | @return string
-- |
-- | @date 2026-09-17 14:00
--]]
function machines.hdd_address(cell)
    machines.of(cell)
    return blocks.u(cell).hdd_address
end

function machines.save_disks(state)
    if not vc.path_make_dirs(saves.disks_dir()) then
        return 0
    end

    local count = 0
    for _, cell in ipairs(state.world:occupied()) do
        local u = (cell.kind == blocks.KIND.CASE) and blocks.u(cell) or nil
        if u and u.machine then
            local dir = saves.disk_dir(machines.hdd_address(cell))
            vc.path_remove_all(dir)
            vc.path_make_dirs(dir)

            for _, name in ipairs(vc.machine_hdd_files(u.machine)) do
                -- The directories are implied by the paths, so they are made on the way past.
                local parent = name:match("^(.*)/[^/]*$")
                if parent then
                    vc.path_make_dirs(dir .. "/" .. parent)
                end
                local file = io.open(dir .. "/" .. name, "wb")
                if file then
                    file:write(vc.machine_hdd_read(u.machine, name))
                    file:close()
                    count = count + 1
                end
            end
        end
    end
    return count
end

--[[ @brief Reads the disks back, onto the machines of the cases they belong to.
-- |
-- | Called after the world is loaded, so the cases exist and each already knows its disk's address -
-- | that is the field world.lua reads off the end of a cell line. A machine is made for every case
-- | that has files, which is why a computer can be started and find its system already installed
-- | without having been booted first.
-- |
-- | A folder naming a case that is no longer there is simply never looked at. A world where
-- | somebody broke a computer is an ordinary world, and the files stay on disk rather than being
-- | tidied away by a load.
-- |
-- | Falls back to the single packed file the earlier version wrote when the directory holds nothing
-- | - see machines.load_disks_legacy.
-- |
-- | @param state  state
-- | @return number - how many files were restored
-- |
-- | @date 2026-09-17 14:00
--]]
function machines.load_disks(state)
    local count = 0
    for _, cell in ipairs(state.world:occupied()) do
        local u = (cell.kind == blocks.KIND.CASE) and blocks.u(cell) or nil
        if u and u.hdd_address then
            local dir = saves.disk_dir(u.hdd_address)
            if vc.path_is_dir(dir) then
                local names = {}
                walk_disk(dir, "", names)
                if #names > 0 then
                    local m = machines.of(cell)
                    for _, name in ipairs(names) do
                        local file = io.open(dir .. "/" .. name, "rb")
                        if file then
                            local data = file:read("a") or ""
                            file:close()
                            if vc.machine_hdd_write(m, name, data) then
                                count = count + 1
                            end
                        end
                    end
                end
            end
        end
    end

    if count == 0 then
        count = machines.load_disks_legacy(state, saves.legacy("disks.save"))
    end
    return count
end

--[[ @brief Reads a PRE-DIRECTORY save's disks back, out of the one packed file they used
-- | to live in.
-- |
-- | Kept because that file exists on any machine that ran the earlier version, and on at
-- | least one of them it holds a whole installed operating system. Nothing writes this
-- | format any more: machines.load_disks falls back to it when the save directory has
-- | nothing, and the next save writes the directory layout instead. The old file is left
-- | where it is, as its own backup.
-- |
-- | A machine is named by where its case is, which is what tied a disk to a computer
-- | before the address was written down beside it.
-- |
-- | Originally: reads the disks back, onto the machines of the cases they belong to.
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
function machines.load_disks_legacy(state, path)
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
