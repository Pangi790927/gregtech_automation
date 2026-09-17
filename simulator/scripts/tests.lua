--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | NOTHING to the application. This is the TESTING instance's entry
-- | script and nothing requires it: main.cpp calls the `sim_test` global
-- | below when it was started with `--test`, and the real instance never
-- | loads it at all.
-- |
-- | Why it is a file of its own: a test written into the application's
-- | own startup runs every time a person opens the simulator. That
-- | happened - the window stayed blank while the test ran and then closed
-- | itself, which looks exactly like the application being broken.
-- |
-- |     sim_test()      builds a world of its own, runs every case, and
-- |                     answers zero when they all passed.
-- |
-- | Everything here works on a world it builds itself, under test_run/,
-- | and never reads the real save.
-- |
-- | --- internal, not on any module table -------------------------------------------------------
-- |     failures, check, settle, until_true, build_rig, the cases
-- |
-- | @date 2026-09-17 12:00
-- | ===============================================================================================
--]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local settings = require("settings")
local blocks = require("blocks")
local world = require("world")
local machines = require("machines")
local saves = require("saves")

local failures = 0

--[[ @brief Records one expectation and prints how it went.
-- |
-- | Every case prints whether it passed rather than only what failed, because a test that silently
-- | did nothing and a test that passed look identical otherwise.
-- |
-- | @param name  string - what was expected
-- | @param ok    any - truthy for a pass
-- | @param got   any | nil - what was actually seen, shown when it fails
-- |
-- | @date 2026-09-17 12:00
--]]
local function check(name, ok, got)
    if ok then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (got ~= nil and ("  (got " .. tostring(got) .. ")") or ""))
    end
end

--[[ @brief Runs every machine for a stretch of real time.
-- |
-- | A guest that calls `os.sleep` is waiting on the wall clock, so only the wall clock will do.
-- | @date 2026-09-17 12:00
--]]
local function settle(w, seconds)
    local deadline = vc.app_time() + seconds
    while vc.app_time() < deadline do
        machines.step_all(w)
    end
end

--[[ @brief Runs until `done` answers true, or until the cap runs out.
-- |
-- | Waiting on the thing being waited for rather than on a count of iterations is what keeps a test
-- | to the length of the work instead of the length of a guess.
-- |
-- | @return boolean - whether it came true before the cap
-- |
-- | @date 2026-09-17 12:00
--]]
local function until_true(w, done, cap)
    local deadline = vc.app_time() + (cap or 8.0)
    while vc.app_time() < deadline do
        machines.step_all(w)
        if done() then
            return true
        end
    end
    return false
end

--[[ @brief Builds the rig every case runs against: a computer with a screen, a keyboard, an OpenOS
-- | drive, and a transposer and redstone block wired to a chest and a lamp.
-- |
-- | Laid out the way the author's own world is, so a test failing here means the same thing would
-- | fail there.
-- |
-- | @return table - the state, and the blocks a case needs to reach
-- |
-- | @date 2026-09-17 12:00
--]]
local function build_rig()
    local st = world.new()
    local w = st.world
    local B = blocks

    local case = B.make_case()
    w:set(10, 0, 10, case)
    w:set(11, 0, 10, B.make_drive())
    local scr = B.make_screen()
    w:set(10, 1, 10, scr)
    w:face_set(10, 1, 10, B.FACE.XPOS, B.make_keyboard())

    w:set(9, 0, 10, B.make_cable())
    local rs = B.make_redstone()
    w:set(8, 0, 10, rs)
    local lamp = B.make_lamp()
    w:set(7, 0, 10, lamp)

    local trans = B.make_transposer()
    w:set(9, 0, 11, trans)
    local chest = B.make_chest()
    w:set(9, 0, 12, chest)

    -- Two tanks against the transposer, on opposite sides, so fluid has somewhere to go. From the
    -- transposer at (9,0,11) the first lies on negative x, which is side 4, and the second on
    -- positive x, side 5.
    local tank_a = B.make_tank()
    w:set(8, 0, 11, tank_a)
    local tank_b = B.make_tank()
    w:set(10, 0, 11, tank_b)

    return {state = st, w = w, case = case, screen = scr, chest = chest,
            lamp = lamp, redstone = rs, transposer = trans, tank_a = tank_a, tank_b = tank_b}
end

--[[ @brief Types a line at a screen, one character at a time, and waits for it to be taken.
-- | @date 2026-09-17 12:00
--]]
local LETTER = {a = 30, b = 48, c = 46, d = 32, e = 18, f = 33, g = 34, h = 35, i = 23,
                j = 36, k = 37, l = 38, m = 50, n = 49, o = 24, p = 25, q = 16, r = 19,
                s = 31, t = 20, u = 22, v = 47, w = 17, x = 45, y = 21, z = 44}
local PUNCT = {[" "] = 57, ["."] = 52, ["/"] = 53}

local function typeline(rig, text)
    for c in text:gmatch(".") do
        local code = LETTER[c:lower()] or PUNCT[c] or 0
        machines.send_key(rig.w, rig.screen, string.byte(c), code, true)
        machines.send_key(rig.w, rig.screen, string.byte(c), code, false)
        settle(rig.w, 0.004)
    end
    machines.send_key(rig.w, rig.screen, 13, 28, true)
    machines.send_key(rig.w, rig.screen, 13, 28, false)
    -- Only long enough for the machine to take the line. What it ANSWERS is waited for by the
    -- until_true the caller checks with, so waiting for it twice only makes the suite slower.
    settle(rig.w, 0.12)
end

--[[ @brief Does anything on the screen contain this text? @date 2026-09-17 12:00 ]]
local function screen_has(rig, text)
    for _, r in ipairs(machines.screen_output(rig.w, rig.screen)) do
        if r:find(text, 1, true) then
            return true
        end
    end
    return false
end

--[[ @brief Is the shell showing a prompt? @date 2026-09-17 12:00 ]]
local function at_prompt(rig)
    local rows = machines.screen_output(rig.w, rig.screen)
    for _, r in ipairs(rows) do
        if r:find("#", 1, true) then
            return true
        end
    end
    return false
end

--[[ @brief Writes the flat files the FIRST version of the simulator wrote, and checks that a save
-- | in that shape is still found and still read.
-- |
-- | Core: the most important case in the suite. The author has a real save in the old shape, with a
-- | whole installed operating system and his own program on it, and moving to a directory must not
-- | be what loses them. It builds an old save of its own rather than reading his, so it runs
-- | anywhere, and it goes through saves.readable and machines.load_disks - the same two calls the
-- | application makes - rather than through the legacy readers directly.
-- |
-- | @date 2026-09-17 14:00
--]]
local function legacy_save_case()
    print("a save from before the directory")

    local PROG = "print('from the old save')\n"
    local file = io.open(saves.legacy("world.save"), "w")
    file:write("# a simulator world, written the old flat way\n")
    file:write("k 20.000 4.000 24.000 0.00000 -0.20000\n")
    file:write("c 20 0 20 1 1 5\n")
    file:close()

    -- Length prefixed and named by where the case is, which is the format that used to be written.
    file = io.open(saves.legacy("disks.save"), "wb")
    file:write("# a simulator disk, written the old packed way\n")
    file:write(string.format("f 20 0 20 %d home/prog.lua\n", #PROG))
    file:write(PROG)
    file:write("\n")
    file:close()

    local st = world.new()
    world.load(st, saves.readable(saves.level_path(), "world.save"))
    local case = st.world:get(20, 0, 20)
    check("the old map is found", case ~= nil and case.kind == blocks.KIND.CASE)
    check("a case with no address written down still loads",
            case ~= nil and blocks.u(case).hdd_address == nil)

    check("the old disks are read", machines.load_disks(st) == 1)
    check("and the program is still on the disk",
            vc.machine_hdd_read(blocks.u(case).machine, "home/prog.lua") == PROG)

    -- AND THEN SAVING IT AGAIN HAS TO BE COMPLETE. This computer was never switched on, so for a
    -- while its disk got an address only when the disks were written - which is after the map is
    -- written, so the map went out without one and the files went into a folder nothing pointed
    -- at. The real save lost all hundred and eighty of its files exactly this way.
    saves.prepare()
    world.save(st, saves.level_path())
    local out = machines.save_disks(st)
    check("it writes back out as a directory", out == 1, out)

    local addr = blocks.u(case).hdd_address
    check("a computer that was never started still has an address", addr ~= nil)
    check("and a folder", addr ~= nil and vc.path_is_dir(saves.disk_dir(addr)))

    local st2 = world.new()
    world.load(st2, saves.level_path())
    local case2 = st2.world:get(20, 0, 20)
    check("the address is in the map", blocks.u(case2).hdd_address == addr,
            blocks.u(case2).hdd_address)
    check("so the files are found without the old file", machines.load_disks(st2) == 1)
    check("and they are the same files",
            vc.machine_hdd_read(blocks.u(case2).machine, "home/prog.lua") == PROG)
end

--[[ @brief Compiles every script in scripts/, without running any of them.
-- |
-- | Core: THE TESTING INSTANCE NEVER PARSES main.lua. It loads tests.lua instead, which is the
-- | whole point of the split - but it means a syntax error in the application's own entry script,
-- | or in the interface it draws, passes a green suite and is found by opening the simulator and
-- | watching it fail to start. `loadfile` compiles and stops, so this costs nothing and covers
-- | every file the application actually loads.
-- |
-- | @date 2026-09-17 16:00
--]]
local function scripts_compile_case()
    print("every script compiles")

    local dir = vc.path_resolve("scripts")
    local n = 0
    for _, name in ipairs(vc.path_list_dir("scripts")) do
        if name:sub(-4) == ".lua" then
            local chunk, err = loadfile(dir .. "/" .. name)
            check(name, chunk ~= nil, err)
            n = n + 1
        end
    end
    check("there were scripts to compile", n > 0, n)
end

--[[ @brief What a right click does to each kind.
-- |
-- | The author's rule, 2026-09-17: a right click opens what can be opened, and shift places against
-- | it instead. main.lua asks blocks.is_interactive which kinds those are, and so does the hint on
-- | the screen, so this is the one table that decides both.
-- |
-- | @date 2026-09-17 16:00
--]]
local function interaction_case()
    print("what a right click opens")

    check("a computer case", blocks.is_interactive(blocks.KIND.CASE))
    check("a screen", blocks.is_interactive(blocks.KIND.SCREEN))
    check("a chest", blocks.is_interactive(blocks.KIND.CHEST))
    check("a liquid tank", blocks.is_interactive(blocks.KIND.TANK))
    check("a quantum tank", blocks.is_interactive(blocks.KIND.QTANK))

    -- The ones a right click has to keep placing on, or building stops working.
    for _, kind in ipairs({blocks.KIND.WIRE, blocks.KIND.KEYBOARD, blocks.KIND.LAMP,
            blocks.KIND.DRIVE, blocks.KIND.CABLE, blocks.KIND.TRANSPOSER,
            blocks.KIND.REDSTONE}) do
        check("a " .. blocks.KIND_NAME[kind] .. " is still built on",
                not blocks.is_interactive(kind))
    end
end

--[[ @brief The blocks that point at what they were placed against, and the catalogue the chest
-- | panel stocks from.
-- |
-- | @date 2026-09-17 18:00
--]]
local function bus_and_item_case()
    print("buses and the item catalogue")

    check("an import bus faces the click", blocks.faces_the_click(blocks.KIND.IMPORT_BUS))
    check("so does an export bus", blocks.faces_the_click(blocks.KIND.EXPORT_BUS))
    check("a computer case does not", not blocks.faces_the_click(blocks.KIND.CASE))
    check("a bus is NOT on the network", not blocks.on_network(blocks.KIND.IMPORT_BUS)
            and not blocks.on_network(blocks.KIND.EXPORT_BUS))

    -- Placed through world.place, the function a click actually goes through, with a target shaped
    -- the way world.aim shapes one. All six faces, because a bus can be stuck to the underside of
    -- something as readily as to its side, and `facing` used to only ever be horizontal.
    local st = world.new()
    local w = st.world
    w:set(20, 1, 20, blocks.make_case())

    for face = 0, 5 do
        local d = {[0] = {-1, 0, 0}, [1] = {1, 0, 0}, [2] = {0, -1, 0},
                   [3] = {0, 1, 0}, [4] = {0, 0, -1}, [5] = {0, 0, 1}}
        local at = {20 + d[face][1], 1 + d[face][2], 20 + d[face][3]}
        st.target = {x = 20, y = 1, z = 20, face = face, attach = nil,
                place_at = at, cell = w:get(20, 1, 20)}
        local bus = world.place(st, blocks.make_import_bus)
        check(string.format("a bus placed on face %d points back at it", face),
                bus ~= nil and bus.facing == (face ~ 1), bus and bus.facing)
        w:clear(at[1], at[2], at[3])
    end

    -- The item catalogue. It comes out of the vanilla jar, so it is empty on a machine that has not
    -- got one - which is not a failure, only nothing to check.
    local ids = vc.render_item_ids()
    local labels = vc.render_item_labels()
    local dmgs = vc.render_item_damage()
    check("the catalogue is a list", type(ids) == "table")
    check("with a label each", #ids == #labels, #ids .. "/" .. #labels)

    if #ids > 0 then
        -- MOST ITEMS HAVE NO PICTURE and that is expected, not a fault: the names come from the
        -- modpack's registry, ten thousand of them, while the pictures come from the vanilla jar.
        -- GregTech alone draws thousands of items off one sheet indexed by damage value, which a
        -- registry name cannot pick a square out of. So this looks for one that does have a
        -- picture rather than assuming the first one will.
        local with_picture, sample = 0, nil
        for _i, id in ipairs(ids) do
            local uv = vc.render_item_uv(id, dmgs[_i] or 0)
            if uv[3] > uv[1] then
                with_picture = with_picture + 1
                sample = sample or {id, uv}
            end
        end
        -- Most have one. The exceptions are deliberate: a mod that packs thousands of items
        -- behind one registry name builds their icons at runtime from a material colour, which no
        -- file holds, so those list with their real name and a blank square rather than not at all.
        check("a good many items have a picture", with_picture > 1000, with_picture)
        if sample then
            local uv = sample[2]
            check("and its patch of the atlas is a real one",
                    uv[4] > uv[2] and uv[3] <= 1.0 and uv[4] <= 1.0,
                    sample[1] .. " " .. table.concat({uv[1], uv[2], uv[3], uv[4]}, ","))
        end
        check("the atlas exists", vc.render_item_atlas_id() > 0)

        -- The whole point of reading the registry: the names are the game's, not the textures'.
        local by_name = {}
        for _, id in ipairs(ids) do
            by_name[id] = true
        end
        -- The items a mod hides behind a shared registry name and a damage value. Searching for
        -- one of these found nothing until the lang file was read for them.
        local variants, named = 0, nil
        for i, id in ipairs(ids) do
            if (dmgs[i] or 0) ~= 0 then
                variants = variants + 1
                named = named or labels[i]
            end
        end
        check("items behind a shared name are listed by variant", variants > 0, variants)
        check("and they have a real name", named ~= nil and named ~= "", named)

        -- THE CASE THE AUTHOR REPORTED, 2026-09-17: "all the dusts from searching naquadah are
        -- not there". They were not, because the name is a template GregTech fills in from its
        -- compiled material list. Searching for one is the end-to-end check that the material list
        -- is still being read out of the jar and still joining up with the lang file.
        local want = {["Naquadah Dust"] = false, ["Naquadah Plate"] = false,
                ["Naquadah Ingot"] = false}
        local naquadah = 0
        for _, l in ipairs(labels) do
            if l:find("Naquadah", 1, true) then
                naquadah = naquadah + 1
            end
            if want[l] == false then
                want[l] = true
            end
        end
        check("a naquadah search finds a good many things", naquadah > 20, naquadah)
        for name, seen in pairs(want) do
            check(name .. " is one of them", seen)
        end

        -- AND IT IS DRAWN. GregTech keeps no picture for these: the shape comes from a texture set
        -- and the colour from the material, both read out of its compiled code. If either stops
        -- being read this stays true by name and goes blank, so the picture is checked too.
        local drawn, dust_uv = 0, nil
        for i, l in ipairs(labels) do
            if (dmgs[i] or 0) ~= 0 then
                local uv = vc.render_item_uv(ids[i], dmgs[i])
                if uv[3] > uv[1] then
                    drawn = drawn + 1
                    if l == "Naquadah Dust" then
                        dust_uv = uv
                    end
                end
            end
        end
        check("most of them are drawn", drawn > 5000, drawn)
        check("a naquadah dust has a picture of its own", dust_uv ~= nil)

        if by_name["minecraft:golden_apple"] then
            check("a registry name is the item's, not its texture's",
                    by_name["minecraft:golden_apple"] and not by_name["minecraft:apple_golden"])
        else
            print("  --   no save registry here, so the names are texture names")
        end
    else
        print("  --   no vanilla jar here, so nothing to check")
    end

    -- An id nobody has a picture for draws nothing rather than the wrong thing.
    local none = vc.render_item_uv("minecraft:no_such_item_at_all", 0)
    check("an unknown item has no patch", none[3] <= none[1])

    -- The mini views cannot be DRAWN here - there is no ImGui frame in the testing instance - but
    -- the guard at the top of each can be, and that is what runs on every frame a person looks at
    -- anything that is not a chest or a tank. A misnamed function or a broken guard shows up here
    -- rather than as the world vanishing the moment the crosshair crosses a block.
    local ui = require("ui")
    check("the chest mini view exists", type(ui.minichest) == "function")
    check("the tank mini view exists", type(ui.minitank) == "function")
    ui.minichest(nil)
    ui.minitank(nil)
    ui.minichest(w:get(20, 1, 20))
    ui.minitank(w:get(20, 1, 20))
    check("and both ignore anything that is not theirs", true)
end

--[[ @brief The fusion recipes, read out of the installed mods at runtime.
-- |
-- | Core: these are checked against values read BY HAND out of the same jars with a disassembler,
-- | so the reader is measured against the game rather than against itself. If a modpack update
-- | moves them the counts change and this says so; if the reader breaks, the named recipes vanish.
-- |
-- | @date 2026-09-17 22:00
--]]
local function fusion_recipe_case(mc)
    print("fusion recipes, read from the mods")

    local r = vc.fusion_recipes(mc or "")
    check("some recipes were found", #r > 10, #r)
    if #r == 0 then
        print("  --   no minecraft path here, so there was nothing to read")
        return
    end

    -- Indexed by what they make, since that is how the scenario asks for them.
    local by_out = {}
    for _, e in ipairs(r) do
        by_out[e[5]] = by_out[e[5]] or {}
        table.insert(by_out[e[5]], e)
    end

    check("helium plasma has a recipe", by_out["plasma.helium"] ~= nil)
    check("and two routes to it", by_out["plasma.helium"] and #by_out["plasma.helium"] == 2,
            by_out["plasma.helium"] and #by_out["plasma.helium"])

    -- Deuterium + Tritium -> Helium plasma, 16 ticks, 4096 EU/t, 40,000,000 to start.
    local he = by_out["plasma.helium"] and by_out["plasma.helium"][1]
    if he then
        check("its inputs are deuterium and tritium",
                he[1] == "deuterium" and he[3] == "tritium", he[1] .. " + " .. he[3])
        check("125 L of each", he[2] == "125" and he[4] == "125", he[2] .. "/" .. he[4])
        check("16 ticks", he[7] == "16", he[7])
        check("4096 EU/t", he[8] == "4096", he[8])
        check("40,000,000 EU to start", he[9] == "40000000", he[9])
    end

    -- The one GTNH's own core mod adds, and the reason a balancer has ordering to do: boron plasma
    -- is made OUT OF helium plasma.
    local boron = by_out["plasma.boron"] and by_out["plasma.boron"][1]
    check("boron plasma has a recipe", boron ~= nil)
    if boron then
        check("made out of helium plasma", boron[1] == "plasma.helium" or boron[3] == "plasma.helium",
                boron[1] .. " + " .. boron[3])
        check("with molten lithium", boron[1] == "molten.lithium" or boron[3] == "molten.lithium")
        check("240 ticks", boron[7] == "240", boron[7])
        check("and it came from the core mod", boron[10]:find("CoreMod", 1, true) ~= nil, boron[10])
    end

    -- Bismuth eats zinc plasma, the other dependency in the graph.
    local bi = by_out["plasma.bismuth"] and by_out["plasma.bismuth"][1]
    check("bismuth plasma is made from zinc plasma",
            bi ~= nil and (bi[1] == "plasma.zinc" or bi[3] == "plasma.zinc"),
            bi and (bi[1] .. " + " .. bi[3]))

    -- THE TWO WE COULD NOT FIND BY HAND. A python scan over a disassembly missed them; this reader
    -- did not, which is the argument for reading the game rather than transcribing it.
    for _, want in ipairs({"plasma.radon", "plasma.americium"}) do
        local e = by_out[want] and by_out[want][1]
        check(want .. " has a recipe", e ~= nil)
        if e then
            print(string.format("  --   %s: %s %s + %s %s -> %s %s, %s ticks, %s EU/t, start %s",
                    want, e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8], e[9]))
        end
    end

    -- What a Compact Fusion MK-II can and cannot run, which is the scenario's real constraint.
    local MK2 = 320006000
    local fits, too_big = 0, {}
    for out_name, list in pairs(by_out) do
        local best = nil
        for _, e in ipairs(list) do
            local s = tonumber(e[9])
            if not best or s < best then best = s end
        end
        if best and best <= MK2 then
            fits = fits + 1
        elseif best then
            too_big[#too_big + 1] = out_name
        end
    end
    check("an MK-II can run a good many of them", fits > 8, fits)
    table.sort(too_big)
    print("  --   past an MK-II's store: " .. table.concat(too_big, ", "))
end

--[[ @brief The fusion balancer scenario's bank of fluids.
-- |
-- | Core: the row of tanks that stands for the ME system has to end up with one tank per fluid, in
-- | a known order, each the size of the tank it stands for. The scenario builds it from whatever
-- | row it finds, so the case gives it a short row and checks it grew correctly.
-- |
-- | @date 2026-09-17 21:00
--]]
local function bank_case(mc)
    print("the scenario's bank of fluids")

    package.path = package.path .. ";./scenes/fusion_balancer/?.lua"
    local ok_s, scene = pcall(require, "scene")
    local ok_b, bank = pcall(require, "bank")
    check("the scene loads", ok_s, ok_s and "" or tostring(scene))
    check("the bank loads", ok_b, ok_b and "" or tostring(bank))
    if not (ok_s and ok_b) then
        return
    end

    local st = world.new()
    local w = st.world

    -- A short row, plus one tank too many at the far end, and a block in the way of neither.
    for i = 0, 4 do
        w:set(10 + i, 0, 40, blocks.make_tank())
    end

    local placed, removed, complaints = bank.build(w, scene, mc)
    -- Every one of them placed: the five that were there were ordinary tanks, and the bank row is
    -- quantum tanks, so they are replaced rather than resized.
    check("it built one quantum tank per fluid", placed == #bank.FLUIDS,
            placed .. " placed for " .. #bank.FLUIDS .. " fluids")
    check("and took nothing away that was not there", removed == 0, removed)

    local first = w:get(10, 0, 40)
    check("the first tank is locked to the first fluid",
            first ~= nil and first:fluid_lock_get()[1] == bank.FLUIDS[1],
            first and first:fluid_lock_get()[1])
    check("and is a quantum tank", first ~= nil and first.kind == blocks.KIND.QTANK,
            first and blocks.KIND_NAME[first.kind])
    check("and is the size the scenario says", first ~= nil
            and first:fluid_capacity() == scene.BANK.cap_per_fluid, first:fluid_capacity())
    -- The rest of a scene's tanks stand for ordinary connections and stay small.
    check("an ordinary tank is still a super tank IV",
            blocks.make_tank():fluid_capacity() == 32000000,
            blocks.make_tank():fluid_capacity())
    check("and a quantum tank a quantum tank III",
            blocks.make_qtank():fluid_capacity() == 512000000,
            blocks.make_qtank():fluid_capacity())
    check("which is a quantum tank III", scene.BANK.cap_per_fluid == 512000000)

    local last = w:get(10 + #bank.FLUIDS - 1, 0, 40)
    check("the last tank is locked to the last fluid",
            last ~= nil and last:fluid_lock_get()[1] == bank.FLUIDS[#bank.FLUIDS],
            last and last:fluid_lock_get()[1])
    check("and nothing was built past it", w:get(10 + #bank.FLUIDS, 0, 40) == nil)

    -- Every fluid the recipes touch has somewhere to go.
    local have = {}
    for _, f in ipairs(bank.FLUIDS) do
        have[f] = true
    end
    check("every plasma the mixer needs is in the bank",
            have["plasma.helium"] and have["plasma.tin"] and have["plasma.americium"])
    check("so is every catalyst it makes",
            have["exciteddtcc"] and have["exciteddtrc"] and have["exciteddtpc"]
            and have["exciteddtec"])
    check("and the reactor's own feedstocks",
            have["deuterium"] and have["tritium"] and have["helium-3"]
            and have["molten.lithium"] and have["molten.tantalum"])

    -- THE STARTING STATE. What the base buys in starts full, what the scenario makes starts empty,
    -- and rebuilding puts it back to that rather than inheriting the last run.
    local feed = bank.input_only(scene, mc)
    check("deuterium is bought in, not made", feed["deuterium"] == true)
    check("and helium plasma is not", feed["plasma.helium"] == nil)
    check("nor is a catalyst", feed["exciteddtcc"] == nil)

    local function level(name)
        for _, cell in ipairs(w:occupied()) do
            if blocks.is_tank(cell.kind) and cell:fluid_lock_get()[1] == name then
                return cell:fluid_get()[2]
            end
        end
    end
    check("feedstock starts full", level("deuterium") == scene.BANK.cap_per_fluid,
            level("deuterium"))
    check("and what the scenario makes starts empty", level("plasma.helium") == 0,
            level("plasma.helium"))

    check("the catalysts read as the author names them",
            bank.display("exciteddtcc") == "excited-crude"
            and bank.display("exciteddtec") == "excited-exotic")
    check("but keep the name the game gives them",
            level("exciteddtcc") ~= nil)

    -- EVERY fluid draws. Most have no picture of their own and use GregTech's greyscale stand-in
    -- coloured by the material - without that a row of bank tanks looks empty, which is exactly
    -- what the author reported on 2026-09-17.
    local undrawn = {}
    for _, f in ipairs(bank.FLUIDS) do
        if vc.render_fluid_tile(f) < 0 then
            undrawn[#undrawn + 1] = f
        end
    end
    check("every bank fluid has something to draw with", #undrawn == 0,
            table.concat(undrawn, ", "))
    check("a plasma falls back to the plasma stand-in",
            vc.render_fluid_tile("plasma.helium") >= 0)
    check("and a molten metal to the molten one",
            vc.render_fluid_tile("molten.lithium") >= 0)
    check("a fluid with its own picture keeps it",
            vc.render_fluid_tile("deuterium") >= 0
            and math.floor(vc.render_fluid_tint("deuterium")) == 0xffffff)

    for _, c in ipairs(complaints) do
        print("  --   " .. c)
    end
end

--[[ @brief The scenario's controller: does the invisible hand actually run a machine?
-- |
-- | Core: THE POINT IS THAT IT MOVES FLUID, not that it loads. A scene that compiles and does
-- | nothing looks exactly like a scene that works until somebody watches a tank for a minute.
-- | So this builds the rig, tells the reactor to make helium plasma the way the program under test
-- | would, and waits for plasma to appear in the bank.
-- |
-- | @date 2026-09-17 22:30
--]]
local function controller_case(mc)
    print("the scenario's controller")

    package.path = package.path .. ";./scenes/fusion_balancer/?.lua"
    local ok_s, scene = pcall(require, "scene")
    local ok_b, bankmod = pcall(require, "bank")
    local ok_c, ctrl = pcall(require, "controller")
    check("the controller loads", ok_c, ok_c and "" or tostring(ctrl))
    if not (ok_s and ok_b and ok_c) then
        return
    end

    local st = world.new()
    local w = st.world

    -- A bank row, and the four control blocks the scenario looks for.
    for i = 0, 3 do
        w:set(10 + i, 0, 50, blocks.make_tank())
    end
    for i = 0, 3 do
        w:set(10 + i * 2, 0, 55, blocks.make_redstone())
        w:set(10 + i * 2, 1, 55, blocks.make_lamp())
    end

    bankmod.build(w, scene, mc)
    local log = ctrl.init(w, scene, mc or "")
    check("it read the recipes", #log > 0 and log[1]:find("fusion recipes", 1, true) ~= nil,
            log[1])
    check("it found the four control blocks",
            #ctrl.read_signals() == 16, #ctrl.read_signals())

    -- The reactor needs feedstock. Deuterium and tritium make helium plasma, which is the first
    -- fluid in the bank and so is selector value one.
    local function bank_cell(name)
        for _, cell in ipairs(w:occupied()) do
            if blocks.is_tank(cell.kind) and cell:fluid_lock_get()[1] == name then
                return cell
            end
        end
    end
    local deut = bank_cell("deuterium")
    local trit = bank_cell("tritium")
    check("the bank has a deuterium tank", deut ~= nil)
    check("and a tritium tank", trit ~= nil)
    if not (deut and trit) then
        return
    end
    deut:fluid_set("deuterium", 100000, "Deuterium")
    trit:fluid_set("tritium", 100000, "Tritium")

    check("helium plasma starts at nothing", ctrl.bank_level("plasma.helium") == 0)
    check("and the compact fusion can make it",
            ctrl.best_recipe("plasma.helium", scene.REACTOR.eu_store) ~= nil)
    -- What it cannot: radon wants 450,000,000 and the MK-II holds 320,006,000.
    check("but not radon plasma",
            ctrl.best_recipe("plasma.radon", scene.REACTOR.eu_store) == nil)
    check("though an MK-III can",
            ctrl.best_recipe("plasma.radon", scene.CONVERTER_EU_STORE) ~= nil)

    -- Line one selects what the reactor makes. The redstone block's own faces are what the program
    -- under test would drive, so the test drives them the same way.
    local sig = w:get(10, 0, 55)
    sig:rs_set(blocks.FACE.XNEG, 1)

    -- The recipe is 16 ticks at 2x overclock, so well under a second of simulated time.
    for _ = 1, 40 do
        ctrl.update(w, scene, 0.05)
    end

    local made = ctrl.bank_level("plasma.helium")
    check("the reactor made helium plasma", made > 0, made)
    check("and it ate the feedstock", deut:fluid_get()[2] < 100000, deut:fluid_get()[2])

    -- Switched off, it stops.
    sig:rs_set(blocks.FACE.XNEG, 0)
    local before = ctrl.bank_level("plasma.helium")
    for _ = 1, 40 do
        ctrl.update(w, scene, 0.05)
    end
    check("and stops when the line goes low", ctrl.bank_level("plasma.helium") == before,
            ctrl.bank_level("plasma.helium") - before)
    -- THE KNOBS. A flow per fluid is what makes the bank move under the balancer's feet, so it is
    -- worth checking that a positive one fills and a negative one drains, at the rate asked for.
    --
    -- MEASURED WITH THE REACTOR IDLE, and that is not fussiness: the first version of this case
    -- ran it while the reactor was still going and the tritium came out 250 L light, because the
    -- reactor was drinking it. The test was wrong, not the controller - but a loose tolerance
    -- would have hidden a real leak just as happily.
    -- Filled into something the scenario MAKES, which starts empty: a feedstock tank starts full
    -- and adding to it does nothing, which is correct and useless as a measurement.
    ctrl.set_flow("exciteddtcc", 1000)
    ctrl.set_flow("tritium", -2000)
    local lith_before = ctrl.bank_level("exciteddtcc")
    local trit_before = ctrl.bank_level("tritium")
    for _ = 1, 10 do
        ctrl.update(w, scene, 0.1)          -- one second of simulated time
    end
    check("a positive flow fills the bank",
            math.abs((ctrl.bank_level("exciteddtcc") - lith_before) - 1000) < 1,
            ctrl.bank_level("exciteddtcc") - lith_before)
    check("and a negative one drains it",
            math.abs((trit_before - ctrl.bank_level("tritium")) - 2000) < 1,
            trit_before - ctrl.bank_level("tritium"))
    ctrl.set_flow("exciteddtcc", 0)
    ctrl.set_flow("tritium", 0)

end

--[[ @brief The cases. @date 2026-09-17 12:00 ]]
local function run_cases(mc)
    -- From nothing every time. A suite that starts on whatever the last run left behind passes and
    -- fails for reasons that have nothing to do with the change being tested.
    vc.path_remove_all(saves.dir())
    scripts_compile_case()
    interaction_case()
    bus_and_item_case()
    fusion_recipe_case(mc)
    bank_case(mc)
    controller_case(mc)
    legacy_save_case()

    local rig = build_rig()
    local w = rig.w

    print("boot")
    check("the machine starts", machines.start(rig.case, w, mc))
    check("it reaches a shell prompt", until_true(w, function() return at_prompt(rig) end, 10.0))

    local m = blocks.u(rig.case).machine
    check("it is idle rather than spinning", m:idle())
    check("it can see a screen", m:has_screen())

    print("the component network")
    local kinds = {}
    for _, n in ipairs(world.network_from(w, rig.case)) do
        kinds[blocks.KIND_NAME[n.kind]] = true
    end
    check("the transposer is on the network", kinds["transposer"])
    check("the redstone block is on the network", kinds["redstone i/o"])
    check("the chest is NOT on the network", not kinds["chest"])
    -- A tank is a container a transposer reaches into, not a component a computer can see - the
    -- same as a chest. GregTech's tanks are not OpenComputers blocks.
    check("a tank is NOT on the network", not kinds["liquid tank"])

    print("hot swapping")
    local before = m:component_count()
    w:set(9, 1, 10, blocks.make_transposer())
    settle(w, 0.4)
    check("a block placed on a running machine becomes a component",
            m:component_count() == before + 1, m:component_count())
    w:clear(9, 1, 10)
    settle(w, 0.4)
    check("breaking it takes the component away",
            m:component_count() == before, m:component_count())

    print("items and redstone")
    check("the chest has slots", rig.chest:inv_size() == blocks.CHEST_SLOTS, rig.chest:inv_size())
    check("the lamp starts dark", rig.lamp.state == blocks.STATE.OFF, rig.lamp.state)

    -- Driven from INSIDE the machine, through the interpreter, rather than by calling the C++ from
    -- the test. Anything else would be checking the simulator against itself; this goes the whole
    -- way a program goes - guest code, component call, world.
    --
    -- The sides are the mod's own numbering: from the transposer at (9,0,11) the chest at (9,0,12)
    -- lies on positive z, which is side 3; from the redstone block at (8,0,10) the lamp at (7,0,10)
    -- lies on negative x, which is side 4.
    typeline(rig, "lua")
    check("the interpreter starts", until_true(w, function()
        return screen_has(rig, "lua>")
    end, 6.0))

    rig.chest:inv_set(1, "minecraft:cobblestone", 17, 0, "Cobblestone")
    typeline(rig, "=component.transposer.getInventorySize(3)")
    check("the transposer sees the chest", until_true(w, function()
        return screen_has(rig, "27")
    end, 4.0))

    typeline(rig, "=component.transposer.getStackInSlot(3,1).size")
    check("the transposer reads the stack", until_true(w, function()
        return screen_has(rig, "17")
    end, 4.0))

    typeline(rig, "component.redstone.setOutput(4,15)")
    check("setOutput lights the lamp", until_true(w, function()
        return rig.lamp.state == blocks.STATE.ON
    end, 4.0), rig.lamp.state)
    check("the block records what it emits", rig.redstone:rs_get(blocks.FACE.XNEG) == 15,
            rig.redstone:rs_get(blocks.FACE.XNEG))

    typeline(rig, "component.redstone.setOutput(4,0)")
    check("setting it back to nothing darkens the lamp", until_true(w, function()
        return rig.lamp.state == blocks.STATE.OFF
    end, 4.0), rig.lamp.state)

    -- and out of the interpreter again, with the control key, which is its own small test
    machines.send_key(w, rig.screen, 0, 29, true)
    settle(w, 0.05)
    machines.send_key(w, rig.screen, 4, 32, true)
    machines.send_key(w, rig.screen, 0, 32, false)
    settle(w, 0.3)
    machines.send_key(w, rig.screen, 0, 29, false)
    check("ctrl+d leaves the interpreter", until_true(w, function()
        return at_prompt(rig)
    end, 4.0))

    print("liquid tanks")
    check("a tank starts empty", rig.tank_a:fluid_get()[1] == "", rig.tank_a:fluid_get()[1])
    -- GregTech's own number for a Super Tank IV, which is what the author asked the interface to
    -- be. Read from the mod: tier four of commonSizeCompute is 32,000,000 litres.
    check("it holds a Super Tank IV's worth", rig.tank_a:fluid_capacity() == 32000000,
            rig.tank_a:fluid_capacity())

    rig.tank_a:fluid_set("chlorine", 5000, "Chlorine")
    local held = rig.tank_a:fluid_get()
    check("what goes in comes back", held[1] == "chlorine" and held[2] == 5000
            and held[3] == "Chlorine", table.concat({held[1], held[2], held[3]}, "/"))

    check("it will not hold more than it can", rig.tank_a:fluid_set("chlorine", 1e12, "Chlorine")
            == 32000000)
    rig.tank_a:fluid_set("chlorine", 5000, "Chlorine")

    check("setting nothing empties it", rig.tank_a:fluid_set("", 0, "") == 0
            and rig.tank_a:fluid_get()[1] == "")
    rig.tank_a:fluid_set("chlorine", 5000, "Chlorine")

    print("what a transposer sees of a tank")
    -- Through the guest again, because that is the interface the author asked for: what a program
    -- running on the computer sees when it looks at a tank. The method names and the shape of the
    -- table they answer are OpenComputers' own, read out of Transposer$Common.
    typeline(rig, "lua")
    check("the interpreter is back", until_true(w, function()
        return screen_has(rig, "lua>")
    end, 6.0))

    typeline(rig, "t=component.transposer")
    typeline(rig, "=t.getTankCount(4)")
    check("it finds one tank", until_true(w, function()
        return screen_has(rig, "1")
    end, 4.0))

    typeline(rig, "=t.getTankCapacity(4)")
    check("and its capacity", until_true(w, function()
        return screen_has(rig, "32000000")
    end, 4.0))

    typeline(rig, "=t.getTankLevel(4)")
    check("and how much is in it", until_true(w, function()
        return screen_has(rig, "5000")
    end, 4.0))

    typeline(rig, "=t.getFluidInTank(4).label")
    check("and what the game calls it", until_true(w, function()
        return screen_has(rig, "Chlorine")
    end, 4.0))

    typeline(rig, "=t.getFluidInTank(4).name")
    check("and its internal name", until_true(w, function()
        return screen_has(rig, "chlorine")
    end, 4.0))

    -- An empty tank answers nothing at all, the way an empty slot does for getStackInSlot.
    typeline(rig, "=t.getFluidInTank(5)")
    check("an empty tank describes nothing", until_true(w, function()
        return screen_has(rig, "nil")
    end, 4.0))

    typeline(rig, "t.transferFluid(4,5,1000)")
    check("fluid moves between two tanks", until_true(w, function()
        return rig.tank_b:fluid_get()[2] == 1000
    end, 4.0), rig.tank_b:fluid_get()[2])
    check("and leaves the tank it came from", rig.tank_a:fluid_get()[2] == 4000,
            rig.tank_a:fluid_get()[2])
    check("carrying its name with it", rig.tank_b:fluid_get()[1] == "chlorine"
            and rig.tank_b:fluid_get()[3] == "Chlorine")

    -- A tank already holding something else takes nothing: a real tank does not mix.
    rig.tank_b:fluid_set("lubricant", 1000, "Lubricant")
    typeline(rig, "t.transferFluid(4,5,1000)")
    settle(w, 0.4)
    check("a tank will not mix two fluids", rig.tank_b:fluid_get()[2] == 1000
            and rig.tank_b:fluid_get()[1] == "lubricant", rig.tank_b:fluid_get()[1])

    typeline(rig, "=t.compareFluid(4,5)")
    check("comparing two different fluids says no", until_true(w, function()
        return screen_has(rig, "false")
    end, 4.0))

    machines.send_key(w, rig.screen, 0, 29, true)
    settle(w, 0.05)
    machines.send_key(w, rig.screen, 4, 32, true)
    machines.send_key(w, rig.screen, 0, 32, false)
    settle(w, 0.3)
    machines.send_key(w, rig.screen, 0, 29, false)
    check("out of the interpreter again", until_true(w, function()
        return at_prompt(rig)
    end, 4.0))

    print("saving")
    check("the save directory is made", saves.prepare())
    check("the map writes", world.save(rig.state, saves.level_path()))

    -- The rig boots off the floppy, so its hard disk is empty until something puts a file there.
    -- Two files, one of them a directory down, because a nested path is what tells a folder of real
    -- files apart from a flat one with slashes in the names.
    local m = blocks.u(rig.case).machine
    vc.machine_hdd_write(m, "home/prog.lua", 'print("hello")\n')
    vc.machine_hdd_write(m, "etc/hostname", "rig")
    vc.machine_hdd_write(m, "home/doomed.lua", "-- deleted before the second save")

    local written = machines.save_disks(rig.state)
    check("the disk writes its files", written == 3, written)

    local addr = blocks.u(rig.case).hdd_address
    check("the disk has a folder of its own", addr ~= nil and
            vc.path_is_dir(saves.disk_dir(addr)), addr)
    check("a guest directory is a real directory",
            vc.path_is_dir(saves.disk_dir(addr) .. "/home"))

    -- Read by the host, as a plain file, which is the whole point of keeping a disk this way.
    local f = io.open(saves.disk_dir(addr) .. "/home/prog.lua", "rb")
    local on_host = f and f:read("a")
    if f then f:close() end
    check("a program can be read with a text editor", on_host == 'print("hello")\n', on_host)

    -- A file the guest removed must not survive the save. The folder is cleared and rewritten
    -- precisely so a save is the state of the disk rather than every state it has ever had.
    vc.machine_hdd_remove(m, "home/doomed.lua")
    machines.save_disks(rig.state)
    check("a deleted file does not linger on the host",
            io.open(saves.disk_dir(addr) .. "/home/doomed.lua", "rb") == nil)

    print("loading it back")
    w:wipe()
    world.load(rig.state, saves.level_path())
    check("a keyboard is still a keyboard after a reload",
            (w:face_get(10, 1, 10, blocks.FACE.XPOS) or {}).kind == blocks.KIND.KEYBOARD)
    local drive = w:get(11, 0, 10)
    check("a drive comes back with its floppy", drive and blocks.u(drive).floppy ~= nil)

    -- THE ADDRESS IS WHAT TIES THEM BACK TOGETHER, so it is the one field worth checking by name.
    local case2 = w:get(10, 0, 10)
    check("the computer remembers which disk is its own",
            blocks.u(case2).hdd_address == addr, blocks.u(case2).hdd_address)

    local tank2 = w:get(8, 0, 11)
    check("a tank comes back", tank2 ~= nil and tank2.kind == blocks.KIND.TANK)
    local back = tank2 and tank2:fluid_get() or {"", 0, ""}
    check("still holding what it held", back[1] == "chlorine" and back[2] == 4000
            and back[3] == "Chlorine", table.concat({back[1], back[2], back[3]}, "/"))
    check("the files come back off the folder", machines.load_disks(rig.state) == 2)
    check("with their contents",
            vc.machine_hdd_read(blocks.u(case2).machine, "home/prog.lua") == 'print("hello")\n')
    check("and the deleted one stays gone",
            vc.machine_hdd_read(blocks.u(case2).machine, "home/doomed.lua") == "")
end

--[[ @brief The testing instance's entry point. main.cpp calls this under `--test`.
-- |
-- | @return number - zero when everything passed, which is what the process exits with
-- |
-- | @date 2026-09-17 12:00
--]]
function sim_test()
    if not vc.app_is_testing() then
        print("sim_test refused: this is not the testing instance")
        return 1
    end

    settings.load(saves.readable(saves.settings_path(), "settings.save"))
    local mc = settings.get("minecraft_path") or ""
    vc.render_init(mc, settings.get("minecraft_jar") or "")

    local started = vc.app_time()
    run_cases(mc)
    print(string.format("%d failure(s) in %.1fs", failures, vc.app_time() - started))
    return failures == 0 and 0 or 1
end
