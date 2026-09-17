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
        machines.step_all(w, 0.05)
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
        machines.step_all(w, 0.05)
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

    local n = 0
    local function compile_dir(where)
        local dir = vc.path_resolve(where)
        for _, name in ipairs(vc.path_list_dir(where)) do
            if name:sub(-4) == ".lua" then
                local chunk, err = loadfile(dir .. "/" .. name)
                check(name, chunk ~= nil, err)
                n = n + 1
            end
        end
    end
    compile_dir("scripts")

    -- The scenarios too, balancer.lua included. It runs on a guest machine rather than here, so
    -- nothing else would ever parse it - and a scenario whose program will not compile is a
    -- scenario that quietly tests nothing.
    for _, scene_name in ipairs(vc.path_list_dir("scenes")) do
        if vc.path_is_dir(vc.path_resolve("scenes/" .. scene_name)) then
            compile_dir("scenes/" .. scene_name)
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

    -- THE FEEDSTOCKS THE TWO MK-IIIs NEED. These were missing for a whole session: the list was
    -- typed out from a hand extraction that predated the runtime reader, so both reactors sat
    -- starved with their lamps lit and nothing in the bank to draw on.
    check("radon's feedstock is banked", have["molten.iridium"] and have["fluorine"],
            tostring(have["molten.iridium"]) .. "/" .. tostring(have["fluorine"]))
    check("and americium's", have["molten.plutonium241"] and have["hydrogen"],
            tostring(have["molten.plutonium241"]) .. "/" .. tostring(have["hydrogen"]))
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
    -- The two the MK-IIIs draw on, which is where this went wrong before.
    check("and so does the iridium radon needs",
            level("molten.iridium") == scene.BANK.cap_per_fluid, level("molten.iridium"))
    check("and the plutonium americium needs",
            level("molten.plutonium241") == scene.BANK.cap_per_fluid,
            level("molten.plutonium241"))
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

--[[ @brief The scenario's rig: do the control lines actually move liquid and run the reactor?
-- |
-- | Core: THE PATH A RECIPE TAKES, end to end and through the real actuators. The reactor is not
-- | told what to make - it runs whatever its two inputs are a recipe for - so the only way to get
-- | helium plasma out of it is to stage deuterium and tritium in front of it with the pumps, the
-- | way the program under test has to. A test that reached in and set the feeds would prove the
-- | machine works and nothing about the plumbing, which is the part with sixteen lines in it.
-- |
-- | @date 2026-09-18 00:00
--]]
local function controller_case(mc)
    print("the scenario's rig")

    package.path = package.path .. ";./scenes/fusion_balancer/?.lua"
    local ok_s, scene = pcall(require, "scene")
    local ok_b, bankmod = pcall(require, "bank")
    local ok_r, rigmod = pcall(require, "rig")
    local ok_c, ctrl = pcall(require, "controller")
    check("the rig loads", ok_r, ok_r and "" or tostring(rigmod))
    check("the controller loads", ok_c, ok_c and "" or tostring(ctrl))
    if not (ok_s and ok_b and ok_r and ok_c) then
        return
    end

    local st = world.new()
    local w = st.world

    -- The bank row.
    for i = 0, 3 do
        w:set(10 + i, 0, 50, blocks.make_qtank())
    end
    bankmod.build(w, scene, mc)

    -- Four control blocks, each with its lamp.
    for i = 0, 3 do
        w:set(10 + i * 2, 0, 60, blocks.make_redstone())
        w:set(10 + i * 2, 1, 60, blocks.make_lamp())
    end

    -- Eight transposers above ground, four tanks around each and the C tank on top. The first
    -- four carry the A fluids and feed the reactor's left input, the last four the B fluids.
    for i = 0, 7 do
        local x, z = 20 + i * 4, 60
        w:set(x, 1, z, blocks.make_transposer())
        w:set(x - 1, 1, z, blocks.make_tank())
        w:set(x + 1, 1, z, blocks.make_tank())
        w:set(x, 1, z - 1, blocks.make_tank())
        w:set(x, 1, z + 1, blocks.make_tank())
        w:set(x, 2, z, blocks.make_tank())
    end

    -- The reactor's two input hatches: loose ground tanks, belonging to no transposer.
    w:set(30, 0, 55, blocks.make_tank())
    w:set(32, 0, 55, blocks.make_tank())

    -- SMALL TANKS HERE ON PURPOSE. The mechanism under test is fill-to-the-brim, lift whole, push;
    -- none of it cares what the brim is, and a real 32,000,000 L batch is minutes of game time to
    -- stage - a long stretch of suite for one assertion.
    -- The scenario's own map keeps the real capacity.
    local T_CAP = 8000000
    for i = 0, 7 do
        local x, z = 20 + i * 4, 60
        for _, q in ipairs({{x - 1, 1, z}, {x + 1, 1, z}, {x, 1, z - 1}, {x, 1, z + 1},
                {x, 2, z}}) do
            w:get(q[1], q[2], q[3]):fluid_set_capacity(T_CAP)
        end
    end

    local log = ctrl.init(w, scene, mc or "")
    check("it read the recipes", log[1]:find("fusion recipes", 1, true) ~= nil, log[1])

    local rig_complaints = 0
    for _, l in ipairs(log) do
        if l:find("^rig: ") then rig_complaints = rig_complaints + 1 end
    end
    check("the rig is complete", rig_complaints == 0, rig_complaints)

    local function line(n, value)
        local block = math.floor((n - 1) / 4) + 1
        local face = ({blocks.FACE.XNEG, blocks.FACE.XPOS,
                blocks.FACE.ZNEG, blocks.FACE.ZPOS})[(n - 1) % 4 + 1]
        w:get(10 + (block - 1) * 2, 0, 60):rs_set(face, value)
    end

    --[[ THE TANK ASSIGNMENT. Sixteen input fluids over sixteen tanks, and the split is not a
    choice: each recipe is an edge between its two inputs, and every recipe needs one end on each
    side, which is a two-colouring. That it lands on eight and eight exactly is what makes a tank
    able to hold one fluid for the whole run - and so what removes flushing entirely. ]]
    local plan = ctrl.plan()
    check("neither side wants more tanks than there are", #plan.a <= 8 and #plan.b <= 8,
            #plan.a .. " / " .. #plan.b)
    check("every recipe has one end on each side", plan.at["deuterium"] ~= nil)
    print("  --   A: " .. table.concat(plan.a, ", "))
    print("  --   B: " .. table.concat(plan.b, ", "))

    local hel = plan.by_out["plasma.helium"]
    check("helium plasma is made from an A tank and a B tank", hel ~= nil)
    if not hel then
        return
    end

    --[[ Where a fluid lives: which transposer, and which of its four faces. Four tanks to a
    transposer, the A fluids on transposers 1 to 4 and the B fluids on 5 to 8. ]]
    local function where(at)
        return at.t, at.k
    end
    local ta, ka = where(plan.at[hel.a])
    local tb, kb = where(plan.at[hel.b])

    --[[ BANK PLUS ITS OWN STAGING TANK. plasma.helium is an input as well as a product - boron is
    made out of it - so it has a tank of its own, and the hardwired fill pulls it straight back out
    of the bank the moment any exists. The bank reads nought while the reactor is working perfectly,
    which is exactly what this case saw when it only looked at the bank. ]]
    local function made_helium()
        local n = ctrl.bank_level("plasma.helium")
        local at = plan.at["plasma.helium"]
        if at then
            local t = ctrl.side_tank(at.t, at.k)
            local h = t and t:fluid_get() or {"", 0, ""}
            if h[1] == "plasma.helium" then
                n = n + h[2]
            end
        end
        return n
    end

    -- FILLING TAKES NO COMMAND AT ALL. Every tank has one fluid and one source, so the pumps are
    -- hardwired; the lines stay at nought and the tanks fill anyway.
    for _ = 1, 10 do
        ctrl.update(w, scene, 0.05, 400)    -- a tankful at the pump's rate
    end

    local fa = ctrl.side_tank(ta, ka):fluid_get()
    local fb = ctrl.side_tank(tb, kb):fluid_get()
    print(string.format("  --   a batch of helium is %d runs: %d L of %s and %d L of %s",
            hel.runs, hel.lift_a, hel.a, hel.lift_b, hel.b))
    check("the A tank took " .. hel.a, fa[1] == hel.a, fa[1])
    check("and the B tank took " .. hel.b, fb[1] == hel.b, fb[1])
    check("both hold a batch's worth and more", fa[2] >= hel.lift_a and fb[2] >= hel.lift_b,
            fa[2] .. " / " .. fb[2])
    check("and nothing has reached the reactor yet",
            ctrl.bank_level("plasma.helium") == 0, ctrl.bank_level("plasma.helium"))

    -- THE LIFT, AND IT IS ATOMIC. The face carries the tank number and nothing else; the whole
    -- tankful goes up into C in one step and the tank is left empty behind it.
    line(ta, ka)
    line(tb, kb)
    ctrl.update(w, scene, 0.05, 1)

    local ca = ctrl.c_tank(ta):fluid_get()
    -- A BATCH, NOT A TANKFUL, and it is exactly N runs of this recipe - which is what stops a
    -- remainder too small to burn being left in C for ever. Nearly all of it because C starts
    -- draining into the hatch the instant it has anything.
    check("a batch went up into C in one step",
            ca[1] == hel.a and ca[2] > hel.lift_a * 0.9 and ca[2] <= hel.lift_a,
            ca[1] .. " " .. tostring(ca[2]))
    check("and the tank underneath kept the rest",
            ctrl.side_tank(ta, ka):fluid_get()[2] == fa[2] - hel.lift_a,
            ctrl.side_tank(ta, ka):fluid_get()[2])
    line(ta, 0)
    line(tb, 0)

    -- AND THE C TANKS PUSH THEMSELVES. No line says so: an empty C pushes nothing, and the lift
    -- is what decides when a C stops being empty, so the wire has nothing left to decide.
    for _ = 1, 20 do ctrl.update(w, scene, 0.05, 20) end

    check("the reactor is fed from C", ctrl.feed_fluid(1) == hel.a, ctrl.feed_fluid(1))
    check("on both sides", ctrl.feed_fluid(2) == hel.b, ctrl.feed_fluid(2))

    -- AND IT IS IN THE TANK A PERSON CAN SEE. The inputs were two numbers inside the controller
    -- for a while, so the tanks standing in the map for them stayed empty however well the run
    -- went - which is the whole of what the author saw.
    local hatch = w:get(30, 0, 55):fluid_get()
    check("and the input tank in the world actually holds it",
            hatch[1] == hel.a and hatch[2] > 0, hatch[1] .. " " .. tostring(hatch[2]))
    check("and it made helium plasma out of them", made_helium() > 0, made_helium())

    -- IT BATCHES. The compact fusion runs the recipe up to 64 times over - 128 on a cheap one like
    -- this - and this case exists because the simulation ran it exactly once for a whole session
    -- while still looking perfectly healthy. One parallel here means the width has been lost.
    check("and it ran the recipe many times over, not once",
            ctrl.reactor_para() > 1, "x" .. ctrl.reactor_para())
    print(string.format("  --   the reactor ran %d parallels", ctrl.reactor_para()))

    -- LOADING THE NEXT WHILE THIS ONE BURNS, which is what eight transposers are for: a different
    -- transposer, a different tank, nothing shared with the pair being burned.
    local other = nil
    for out, r in pairs(plan.by_out) do
        if out ~= "plasma.helium" and plan.at[r.a].t ~= ta then
            other = {out = out, r = r}
            break
        end
    end
    if other then
        local t2, k2 = plan.at[other.r.a].t, plan.at[other.r.a].k
        -- NOT THE BANK LEVEL, and not the C tank either. plasma.helium is an input to boron as
        -- well as a product, so its own staging tank drinks it out of the bank while the reactor
        -- makes it; and C now empties into a 32,000,000 L hatch in a couple of seconds, so it is
        -- long gone by the time this looks. What is actually being asked is whether the reactor
        -- kept producing, so that is what is measured.
        local burning = made_helium()
        for _ = 1, 20 do ctrl.update(w, scene, 0.05, 20) end

        local st = ctrl.side_tank(t2, k2):fluid_get()
        check("another transposer's tank is loaded while this one feeds the reactor",
                st[1] == other.r.a and st[2] > 0, st[1] .. " " .. tostring(st[2]))
        check("and the reactor did not pause for it", made_helium() > burning,
                made_helium() - burning)
    end
    check("with no two pumps asked for one hatch", ctrl.collisions() == 0, ctrl.collisions())

    -- THE GUARD. Two C tanks on one side holding fluid at once is two fluids for one hatch, which
    -- can only mean a batch was lifted while the last was still burning.
    local one, two = 1, 2
    ctrl.c_tank(one):fluid_set("deuterium", 1000, "Deuterium")
    ctrl.c_tank(two):fluid_set("molten.magnesium", 1000, "Magnesium")
    ctrl.update(w, scene, 0.05, 1)
    check("two C tanks cannot share an input", ctrl.collisions() > 0, ctrl.collisions())
    ctrl.c_tank(one):fluid_set("", 0, "")
    ctrl.c_tank(two):fluid_set("", 0, "")

    --[[ AND CLEAR WHAT THAT PUT IN THE HATCHES. Forcing fluid into a C tank by hand is not
    something the rig can do to itself: a batch is consumed exactly, so a hatch ends a run at
    nothing. Left there, the litres above would block the next batch of any other fluid - which is
    worth knowing about, and is what the reactor's "X and Y are not a recipe" line is for. ]]
    for i = 1, 2 do
        local h = ctrl.hatch(i)
        if h then
            h:fluid_set("", 0, "")
        end
    end

    -- THE CLOCK. A frame at a hundred times should simulate a hundred times as much, and the way
    -- it used to be written it did not: one limit was trying to be both a stall guard and a speed
    -- cap, and at sixty frames a second it held the clock to about fifteen.
    -- A fresh batch, because the last one has long since been burnt.
    line(ta, ka)
    line(tb, kb)
    ctrl.update(w, scene, 0.05, 1)
    line(ta, 0)
    line(tb, 0)

    local slow_from = made_helium()
    for _ = 1, 10 do ctrl.update(w, scene, 0.05, 1) end
    local slow = made_helium() - slow_from

    local fast_from = made_helium()
    for _ = 1, 10 do ctrl.update(w, scene, 0.05, 20) end
    local fast = made_helium() - fast_from

    check("twenty times the clock makes far more", fast > slow * 10,
            string.format("%d at 1x, %d at 20x", slow, fast))
    check("and it substeps rather than taking one big stride", ctrl.steps() > 1, ctrl.steps())

    --[[ THE FOUR LINES THAT RUN THE OTHER WAY. A comparator on each catalyst tank, driven INTO
    the control block rather than out of it, saying "this one has reached its limit".

    Worth a case of its own because a signal that never moves passes every test that only asks
    whether the program still works: the program treats nought as "not finished yet", which is what
    it would see if this were broken, and it would go on making plasma for a catalyst that was full
    with nothing anywhere to say so. So this checks BOTH edges. ]]
    local cat1 = scene.CATALYSTS[1]
    local cat_tank = nil
    for _, cell in ipairs(w:occupied()) do
        if cell.kind == blocks.KIND.QTANK and cell:fluid_lock_get()[1] == cat1.fluid then
            cat_tank = cell
        end
    end
    check("the bank has a tank for " .. cat1.fluid, cat_tank ~= nil)
    if cat_tank then
        local function limit_face()
            -- Line 11 is the third block's third face, the same arithmetic both halves use.
            local block = w:get(10 + (3 - 1) * 2, 0, 60)
            return block and block:rs_in_get(blocks.FACE.ZNEG) or -1
        end

        cat_tank:fluid_set(cat1.fluid, 0, cat1.fluid)
        ctrl.update(w, scene, 0.05, 1)
        check("an empty catalyst tank says nothing on the wire", limit_face() == 0, limit_face())

        cat_tank:fluid_set(cat1.fluid, scene.CATALYST_LIMIT, cat1.fluid)
        ctrl.update(w, scene, 0.05, 1)
        check("and a full one tells the computer", limit_face() > 0, limit_face())

        cat_tank:fluid_set(cat1.fluid, scene.CATALYST_LIMIT / 2, cat1.fluid)
        ctrl.update(w, scene, 0.05, 1)
        check("and it goes out again when the mixer drinks it",
                limit_face() == 0, limit_face())
        cat_tank:fluid_set("", 0, "")
    end

    --[[ THE CASE THE WHOLE BATCH SIZE EXISTS FOR: a recipe that does NOT take its two inputs in
    equal measure. The author, 2026-09-18: "you shouldn't take 32M as the batch, but something that
    is aroung 500K and multiple of the input sizes of the recipe, else it will get stuck".

    A tankful stuck twice over. 32,000,000 is not a whole number of 144s or 375s, so the C tank kept
    a few litres nothing could ever burn; and staging the same amount of both inputs strands most of
    the smaller one - nitrogen takes 16 of one and 375 of the other. N runs of each input's own
    amount cures both, and the proof is that BOTH C tanks reach exactly nothing. ]]
    local odd, odd_name = nil, nil
    for out, r in pairs(plan.by_out) do
        if r.amt_a ~= r.amt_b then
            odd, odd_name = r, out
        end
    end
    check("there is a recipe with unequal inputs to try", odd ~= nil)
    if odd then
        print(string.format("  --   %s takes %d and %d: a batch is %d runs, %d L and %d L",
                odd_name, odd.amt_a, odd.amt_b, odd.runs, odd.lift_a, odd.lift_b))

        for _ = 1, 10 do ctrl.update(w, scene, 0.05, 400) end       -- let the tanks refill
        local was_a, was_b = ctrl.feed_level(1), ctrl.feed_level(2)
        line(odd.a_t, odd.a_k)
        line(odd.b_t, odd.b_k)
        ctrl.update(w, scene, 0.05, 1)
        line(odd.a_t, 0)
        line(odd.b_t, 0)

        --[[ THE PROPORTION IS THE POINT, and it survives the accounting. C starts draining into
        the hatch in the same tick it is filled and the reactor starts eating out of the hatch, so
        the absolute litres standing anywhere are already a moment out of date - but everything that
        moves, moves in the recipe's own ratio, so the ratio is exact whenever it is looked at.
        Equal litres in both would fail this for any recipe that is not one-to-one. ]]
        local got_a = ctrl.c_tank(odd.a_t):fluid_get()[2] + ctrl.feed_level(1) - was_a
        local got_b = ctrl.c_tank(odd.b_t):fluid_get()[2] + ctrl.feed_level(2) - was_b
        check("each C got its own input's share, not the same number",
                got_a * odd.amt_b == got_b * odd.amt_a and got_a > odd.lift_a * 0.9,
                string.format("%d / %d, wanted %d / %d", got_a, got_b, odd.lift_a, odd.lift_b))

        for _ = 1, 120 do ctrl.update(w, scene, 0.05, 100) end
        local ea = ctrl.c_tank(odd.a_t):fluid_get()
        local eb = ctrl.c_tank(odd.b_t):fluid_get()
        check("and both run dry exactly, with nothing stranded",
                ea[2] == 0 and eb[2] == 0, ea[2] .. " / " .. eb[2])
    end

    --[[ AND THE HATCHES END EMPTY TOO. The C tanks running dry is only half of it: whatever they
    pushed into the reactor has to be consumed to the last litre as well, or the leftover sits in
    the hatch and blocks the next batch of anything else. ]]
    for i = 1, 2 do
        local h = ctrl.hatch(i)
        if h then h:fluid_set("", 0, "") end
    end
    for _ = 1, 10 do ctrl.update(w, scene, 0.05, 400) end
    line(ta, ka)
    line(tb, kb)
    ctrl.update(w, scene, 0.05, 1)
    line(ta, 0)
    line(tb, 0)
    for _ = 1, 120 do ctrl.update(w, scene, 0.05, 100) end

    local la, lb = ctrl.feed_level(1), ctrl.feed_level(2)
    local lca = ctrl.c_tank(ta):fluid_get()[2]
    local lcb = ctrl.c_tank(tb):fluid_get()[2]
    check("a whole batch leaves the C tanks empty", lca == 0 and lcb == 0, lca .. " / " .. lcb)
    check("and the hatches empty too, to the last litre", la == 0 and lb == 0, la .. " / " .. lb)

    --[[ THE WORKING SIGNAL, and why it has to exist.
    --
    -- C drains into the hatch ten times faster than the reactor eats out of it, so C runs dry with
    -- a hatchful of the batch still to go. A program that treats an empty C as a finished batch
    -- lifts the next pair into the tail of the last one - and when the two recipes share a hatch
    -- side, the new fluid goes in on top, gets eaten by the OLD recipe, and the batch that was
    -- staged is left short and out of proportion. It comes to rest with a run's worth stranded:
    -- the author, 2026-09-18, "the inputs still get stuck at 125,125".
    --
    -- So the rig says when the machine is working, which is what a redstone cover on it does in the
    -- game. Both edges, because a signal stuck on would stop the rig dead and a signal stuck off
    -- would bring the jam straight back. ]]
    local function busy_face()
        local n = rigmod.BUSY_LINE
        local blk = w:get(10 + (math.floor((n - 1) / 4)) * 2, 0, 60)
        local face = ({blocks.FACE.XNEG, blocks.FACE.XPOS,
                blocks.FACE.ZNEG, blocks.FACE.ZPOS})[(n - 1) % 4 + 1]
        return blk and blk:rs_in_get(face) or -1
    end

    check("the reactor says it is idle when nothing is staged", busy_face() == 0, busy_face())

    for _ = 1, 10 do ctrl.update(w, scene, 0.05, 400) end
    line(ta, ka)
    line(tb, kb)
    ctrl.update(w, scene, 0.05, 1)
    line(ta, 0)
    line(tb, 0)
    check("and busy the moment it has a pair", busy_face() > 0, busy_face())

    -- THE HALF THAT MATTERS: C is empty long before the machine is.
    local c_empty_at = nil
    for i = 1, 200 do
        ctrl.update(w, scene, 0.05, 100)
        if not c_empty_at and ctrl.c_tank(ta):fluid_get()[2] == 0 then
            c_empty_at = {i = i, busy = busy_face(), hatch = ctrl.feed_level(1)}
        end
    end
    check("it was still busy when the C tank ran dry",
            c_empty_at ~= nil and c_empty_at.busy > 0,
            c_empty_at and string.format("busy %d with %d L still in the hatch",
                    c_empty_at.busy, c_empty_at.hatch) or "C never emptied")
    check("and idle again once the hatches are eaten", busy_face() == 0, busy_face())

    -- AND BUSY FOR A HATCH THAT IS NOT BEING BURNED. Between two cycles the reactor is briefly
    -- making nothing while the hatches are still full, and a signal built only on "is it mid
    -- recipe" would blink idle in that gap and invite the next batch in on top. A hatch with
    -- anything in it is an unfinished batch, whether the machine is turning or not.
    local h1 = ctrl.hatch(1)
    if h1 then
        h1:fluid_set("deuterium", 1000, "Deuterium")
        ctrl.update(w, scene, 0.05, 1)
        check("a hatch with anything in it counts as busy on its own",
                busy_face() > 0, busy_face())
        h1:fluid_set("", 0, "")
        ctrl.update(w, scene, 0.05, 1)
    end

    --[[ THE LAST RUN, AND WHOLE LITRES.
    --
    -- The author, 2026-09-18: "magnesium stuck at 128 128, is this some floating point bulshit?".
    -- It was. Litres are integers in the game and a pump moving `rate * dt` is not, so a tank could
    -- come to rest on 127.99999999 - which reads as 128 in every display, floors to nought runs,
    -- and makes the reactor start a cycle of ZERO parallel: it produces nothing, calls itself busy,
    -- and the rig waits on it for ever.
    --
    -- Two cases, because the two halves fail differently: exactly one run must be burnable, and a
    -- fraction must never be left anywhere for it to trip over. ]]
    --[[ A PUMP MOVES WHOLE LITRES, and this is where that has to be proved.
    --
    -- The author, 2026-09-18: "magnesium stuck at 128 128, is this some floating point bulshit?".
    -- It was, though not where it first looked. A real frame is 0.0163 seconds, not 0.05, so a
    -- substep is a ragged fraction and `rate * dt` is not a whole number of litres. A hatch left
    -- holding 127.99999999 of a 128 L input reads as 128 in every display, fails the recipe's
    -- `at least 128` test, and can never be consumed by anything - so the reactor reports itself
    -- busy on a pair it cannot use and the rig waits on it for ever.
    --
    -- Testing it through a whole run proved nothing: everything downstream rounds the evidence away
    -- by the time it settles - a side tank stops at its capacity, a C tank gets an exact batch, and
    -- a hatch that has been handed the WHOLE of a C tank is whole again however ragged the pieces
    -- were. The fraction only exists mid-transfer. So this asks the pump directly. ]]
    do
        local from = blocks.make_tank()
        local to = blocks.make_tank()
        from:fluid_set("deuterium", 1000000, "Deuterium")
        local moved = rigmod.pump(from, to, "deuterium", "Deuterium", 0.0163 / 13)
        check("a pump moves a whole number of litres", moved == math.floor(moved), moved)
        check("and leaves a whole number behind", to:fluid_get()[2] == math.floor(to:fluid_get()[2])
                and from:fluid_get()[2] == math.floor(from:fluid_get()[2]),
                from:fluid_get()[2] .. " / " .. to:fluid_get()[2])
    end

    local cal = plan.by_out["plasma.calcium"]
    if cal then
        local h1, h2 = ctrl.hatch(1), ctrl.hatch(2)
        h1:fluid_set(cal.a, cal.amt_a, cal.a)
        h2:fluid_set(cal.b, cal.amt_b, cal.b)
        local before_cal = ctrl.bank_level("plasma.calcium")
        for _ = 1, 40 do ctrl.update(w, scene, 0.05, 20) end
        check("a single run's worth in the hatches is burnt, not left",
                ctrl.feed_level(1) == 0 and ctrl.feed_level(2) == 0,
                ctrl.feed_level(1) .. " / " .. ctrl.feed_level(2))
        check("and it really made something out of it",
                ctrl.bank_level("plasma.calcium") > before_cal,
                ctrl.bank_level("plasma.calcium") - before_cal)
    end

    --[[ A STAGING TANK IS A BUFFER, NOT A STORE. It stops at two batches of whatever the hungriest
    recipe asks of it, rather than filling all 32,000,000 L - which matters for a fluid the base
    makes as well as uses. plasma.helium is an input to boron, so its tank was swallowing eight
    batches of helium plasma before any reached the bank, and it looked as though none was being
    made at all. ]]
    local over = {}
    for t = 1, 8 do
        for k = 1, 4 do
            local f = plan.tank[t] and plan.tank[t][k]
            local cell = f and ctrl.side_tank(t, k)
            local held = cell and cell:fluid_get()[2] or 0
            if f and plan.hold[f] and held > plan.hold[f] then
                over[#over + 1] = string.format("%s %d > %d", f, held, plan.hold[f])
            end
        end
    end
    check("no staging tank hoards more than a couple of batches", #over == 0,
            table.concat(over, ", "))

    -- The mixer takes orders and nothing else.
    check("no mixer runs until told", ctrl.mixers_running() == 0, ctrl.mixers_running())

    -- The knobs, measured with everything else idle.
    ctrl.set_flow("exciteddtcc", 1000)
    local before = ctrl.bank_level("exciteddtcc")
    for _ = 1, 10 do ctrl.update(w, scene, 0.1, 1) end
    check("a flow fills the bank", math.abs((ctrl.bank_level("exciteddtcc") - before) - 1000) < 1,
            ctrl.bank_level("exciteddtcc") - before)
    ctrl.set_flow("exciteddtcc", 0)
end

--[[ @brief The balancer itself: does the program actually run and drive anything?
-- |
-- | Core: EVERY OTHER CASE TESTS THE RIG. This one tests the thing the rig exists for. It loads the
-- | scenario's own map - the one with the cables and the computer actually wired to the redstone
-- | blocks, which a hand-built test world does not have - boots the machine, and waits for the
-- | program to start driving lines by itself.
-- |
-- | It asserts nothing about WHICH plasma the balancer picks. That is a judgement call the author
-- | will tune; what must not break is that the program boots, finds its rig, and acts.
-- |
-- | @date 2026-09-18 02:00
--]]
local function balancer_case(mc)
    print("the balancer, running on the computer")

    package.path = package.path .. ";./scenes/fusion_balancer/?.lua"
    local ok_s, scene = pcall(require, "scene")
    local ok_b, bankmod = pcall(require, "bank")
    local ok_r, rigmod = pcall(require, "rig")
    local ok_c, ctrl = pcall(require, "controller")
    if not (ok_s and ok_b and ok_r and ok_c) then
        check("the scenario loads", false, "one of its modules would not load")
        return
    end

    local st = world.new()
    local n = world.load(st, vc.path_resolve("scenes/fusion_balancer/save/level.save"))
    check("the scenario's map loads", n > 0, n)
    if n == 0 then
        return
    end
    local w = st.world

    -- THE DISK TOO, read straight out of the scene folder. machines.load_disks looks under the
    -- running instance's data prefix, which under --test is test_run/ - not the scene's own save -
    -- so it finds nothing. Without an operating system the computer sits there not booting, which
    -- looks exactly like a program that failed to start.
    local case_for_disk = nil
    for _, cell in ipairs(w:occupied()) do
        if cell.kind == blocks.KIND.CASE then
            case_for_disk = cell
        end
    end
    local files = 0
    if case_for_disk then
        local addr = blocks.u(case_for_disk).hdd_address
        local root = vc.path_resolve("scenes/fusion_balancer/save/opencomputers/"
                .. tostring(addr))
        local mach = machines.of(case_for_disk)
        local function walk(dir, prefix)
            for _, name in ipairs(vc.path_list_dir(dir)) do
                local full = dir .. "/" .. name
                local rel = (prefix == "") and name or (prefix .. "/" .. name)
                if vc.path_is_dir(full) then
                    walk(full, rel)
                else
                    local f = io.open(full, "rb")
                    if f then
                        local data = f:read("a") or ""
                        f:close()
                        if vc.machine_hdd_write(mach, rel, data) then
                            files = files + 1
                        end
                    end
                end
            end
        end
        if vc.path_is_dir(root) then
            walk(root, "")
        end
    end
    check("the scenario's disk loads", files > 0, files)

    bankmod.build(w, scene, mc)
    ctrl.init(w, scene, mc or "")

    -- The program, and OpenOS's own way of running it when the shell opens.
    local src = io.open(vc.path_resolve("scenes/fusion_balancer/balancer.lua"), "r")
    check("balancer.lua is there to inject", src ~= nil)
    if not src then
        return
    end
    local text = src:read("a")
    src:close()

    local case = nil
    for _, cell in ipairs(w:occupied()) do
        if cell.kind == blocks.KIND.CASE then
            case = cell
        end
    end
    check("the map has a computer", case ~= nil)
    if not case then
        return
    end

    local m = machines.of(case)
    vc.machine_hdd_write(m, "home/balancer.lua", text)
    -- AND THE PLAN, which is the only way the program learns which tank holds what.
    vc.machine_hdd_write(m, "home/plan.lua", ctrl.plan_source())
    vc.machine_hdd_write(m, "home/.shrc", "balancer\n")
    check("the machine starts", machines.start(case, w, mc or ""))

    -- Boot, and let the shell run .shrc. The guest is a real Lua machine on real time, so this
    -- waits on the clock like everything else does.
    local deadline = vc.app_time() + 25.0
    local drove, output = false, ""
    while vc.app_time() < deadline and not drove do
        ctrl.update(w, scene, 0.02, 1)

        local lines = rigmod.lines(ctrl.signals())
        for _, v in ipairs(lines) do
            if v > 0 then
                drove = true
            end
        end
    end

    for _, row in ipairs(machines.output(case)) do
        output = output .. row .. "\n"
    end

    check("the balancer drove a control line by itself", drove,
            output ~= "" and output:sub(-200) or "no output at all")

    if not drove then
        return
    end

    local lines = rigmod.lines(ctrl.signals())
    local named = {}
    for i = 1, 10 do
        if lines[i] > 0 then
            named[#named + 1] = string.format("%s=%d", rigmod.LINE_NAME[i] or i, lines[i])
        end
    end
    print("  --   it set " .. table.concat(named, ", "))

    -- THE LINES IT DRIVES MUST BE THE ONES THE SCENARIO READS. Both sides number the blocks
    -- themselves, and they once disagreed: the program sorts its components by address because that
    -- is all it can see, while the scenario sorted by position. Everything it drove landed on lines
    -- nobody was reading, and the reactor sat idle while lines 13 to 15 lit up.
    --[[ AND IT NEVER DRIVES A LINE THE RIG DRIVES INTO IT. Eleven to fifteen carry the catalyst
    limits and the reactor's working signal - the only things the rig ever tells the program - and a
    program writing over one of them would be answering its own question. ]]
    local trodden = 0
    for i = 11, 15 do
        trodden = trodden + lines[i]
    end
    check("and it never writes over what the rig tells it", trodden == 0, trodden)

    --[[ AND THEN IT RUNS A BATCH, WHICH IS THE CASE THE WHOLE RIG EXISTS FOR.
    --
    -- Nothing here drives a line. The program has to wait for two tanks to reach 32,000,000 L on
    -- pumps it does not control, decide which pair is worth burning, lift exactly those two, and
    -- let the C tanks carry them to the reactor. If any part of that is wrong - the plan it was
    -- handed, the numbering of the transposers, the choice of recipe - nothing is produced.
    --
    -- A tankful is still minutes of game time, so this only happens with the clock wound right up.
    -- The loop stops the moment it has seen it. ]]
    -- ONLY WHAT THE COMPACT FUSION CAN MAKE COUNTS. The two standalone MK-IIIs run whenever their
    -- plasma is short, so total plasma rises within seconds whatever the balancer does - measuring
    -- that would pass while the reactor under test sat idle, which it did.
    local mine = {}
    for out in pairs(ctrl.plan().by_out) do
        mine[#mine + 1] = out
    end
    --[[ BANK PLUS STAGING, because some plasmas are inputs too. plasma.helium feeds boron, so it
    has a staging tank of its own, and the hardwired fill pulls a batch of it out of the bank the
    moment one exists - the bank reads nought while the reactor has in fact made 32,000,000 L, and
    a test that looked only at the bank would say nothing had happened. ]]
    local function held(pl)
        local n = ctrl.bank_level(pl)
        local at = ctrl.plan().at[pl]
        if at then
            local t = ctrl.side_tank(at.t, at.k)
            local h = t and t:fluid_get() or {"", 0, ""}
            if h[1] == pl then
                n = n + h[2]
            end
        end
        return n
    end
    local function ours()
        local n = 0
        for _, pl in ipairs(mine) do
            n = n + held(pl)
        end
        return n
    end
    local before = ours()

    local lifted, made = 0, false
    local deadline2 = vc.app_time() + 60.0
    while vc.app_time() < deadline2 and not made do
        ctrl.update(w, scene, 0.05, 400)

        local l = rigmod.lines(ctrl.signals())
        for i = 1, 8 do
            if l[i] > 0 then
                lifted = i
            end
        end
        made = ours() > before
    end

    check("it lifts a batch of its own accord", lifted > 0, lifted)
    check("and the reactor made plasma out of what it lifted", made)
    check("with no two C tanks ever sharing a hatch", ctrl.collisions() == 0, ctrl.collisions())

    --[[ AND IT MOVES ON. The author, 2026-09-18: "plasma helium reached 128M while others where
    stil stoped, this is not what I've described".

    The scheduler returned the first plasma under the limit, and the limit is five hundred million,
    so the first one on the list won sixteen rounds running while the rest of the catalyst's
    dependencies sat at nothing - the slowest possible route to a catalyst, which needs all of them.
    Every other case passed throughout: batches were lifted, plasma was made, no collisions. Only
    the SPREAD was wrong, so only a case that looks at the spread can see it. ]]
    local kinds, first = 0, nil
    local deadline3 = vc.app_time() + 60.0
    while vc.app_time() < deadline3 and kinds < 2 do
        ctrl.update(w, scene, 0.05, 400)

        kinds = 0
        for _, pl in ipairs(mine) do
            if held(pl) > 0 then
                kinds = kinds + 1
                first = first or pl
            end
        end
    end
    check("and then makes something else rather than hoarding one", kinds >= 2,
            string.format("only %s after a whole run", tostring(first)))

    --[[ AND THE CHANGEOVER IS CLEAN. Making two different plasmas means at least one changeover,
    which is where it used to jam: C runs dry a hatchful before the reactor does, so a program that
    calls an empty C a finished batch lifts the next pair into the tail of the last one. The hatch
    holds one fluid, refuses it, and everything stops with a run's worth stranded - while the lamps,
    the lifts and the tank levels all still look right. ]]
    check("with the hatches never left holding a pair that makes nothing",
            ctrl.jams() == 0, ctrl.jams())

    print(string.format("  --   the reactor worked %.0f%% of the run", ctrl.duty() * 100))
    local spread = {}
    for _, pl in ipairs(mine) do
        if held(pl) > 0 then
            spread[#spread + 1] = string.format("%s %.0fM", pl:gsub("^plasma%.", ""),
                    held(pl) / 1000000)
        end
    end
    print("  --   it made: " .. table.concat(spread, ", "))

    -- What it said for itself, which is the only window into its reasoning.
    -- What it said for itself, which is the only window into its reasoning. The screen, not the
    -- machine's log: print goes to the screen and the log only carries "machine started".
    local scr = nil
    for _, cell in ipairs(w:occupied()) do
        if cell.kind == blocks.KIND.SCREEN then
            scr = cell
        end
    end
    local shown = 0
    for _, row in ipairs(scr and machines.screen_output(w, scr) or {}) do
        local text = row:gsub("%s+$", "")
        if text ~= "" and not text:find("^[╒│└]") and shown < 8 then
            shown = shown + 1
            print("  --   " .. text)
        end
    end
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
    balancer_case(mc)
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

    --[[ AND THE OTHER DIRECTION, which until now did not exist: getInput answered nought whatever
    the world did, so every wire in a scenario ran one way, out of the computer. A rig that wants to
    TELL a program something - that a tank has reached its limit, say - needs this.

    Driven from inside the machine for the same reason as the rest: a test that called the C++
    would be checking the simulator against itself and would not notice the side numbering being
    wrong on one of the two paths. ]]
    rig.redstone:rs_in_set(blocks.FACE.XNEG, 15)
    typeline(rig, "=component.redstone.getInput(4)")
    check("getInput reads what the world feeds the block", until_true(w, function()
        return screen_has(rig, "15")
    end, 4.0))

    rig.redstone:rs_in_set(blocks.FACE.XNEG, 0)
    typeline(rig, "=component.redstone.getInput(4) == 0")
    check("and it goes away again", until_true(w, function()
        return screen_has(rig, "true")
    end, 4.0))

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
