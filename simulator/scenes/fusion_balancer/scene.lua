--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | THE SCENARIO'S DECLARATION. Not its behaviour - that is
-- | controller.lua - but everything the behaviour is measured against:
-- | which fluids exist, what the machines can do, how fast a pump moves
-- | liquid, and which blocks in the map play which part.
-- |
-- | A scene is a save directory with these two scripts beside it, run as
-- |     main.exe --scene scenes/fusion_balancer
-- |
-- | The point of the whole thing: to test a BALANCER. A program running
-- | on the simulated computer decides what to make and in what order,
-- | and this file is the world it has to do it in.
-- |
-- |     scene.FLUIDS          the sixteen plasmas, in their canonical order
-- |     scene.CATALYSTS       what the four catalysts need, and their priority
-- |     scene.BANK            what the bank of fluids will hold
-- |     scene.PUMP            how fast liquid moves
-- |     scene.REACTOR         the compact fusion the map has
-- |     scene.CONVERTERS      the two standalone fusions, as conversions
-- |     scene.CONTROLS        how many control lines there are, and their shape
-- |     scene.discover(w)     finds the blocks that play each part
-- |
-- | @date 2026-09-17 20:00
-- | ===============================================================================================
--]]

local blocks = require("blocks")

local scene = {}

scene.NAME = "fusion balancer"

--[[ The sixteen plasmas, in the order the Transcendent Plasma Mixer's recipes build on them.
-- |
-- | READ OUT OF THE GAME, not chosen here: gregtech's TranscendentPlasmaMixerRecipes makes the four
-- | catalysts from 4, 8, 12 and 16 plasmas, and each set is the previous one plus four more. So
-- | this order is the mixer's own, and `scene.CATALYSTS` below can name a count instead of a list.
-- |
-- | The sixteen level-2 tanks correspond to these one for one, in this order.
-- | @date 2026-09-17 ]]
scene.FLUIDS = {
    "helium", "iron", "calcium", "niobium",             -- crude needs these four
    "radon", "nickel", "boron", "sulfur",               -- prosaic needs the eight
    "nitrogen", "zinc", "silver", "titanium",           -- resplendent needs the twelve
    "americium", "bismuth", "oxygen", "tin",            -- exotic needs all sixteen
}

--[[ The four catalysts.
-- |
-- | `needs` is how many of scene.FLUIDS each one takes, counting from the first - which is exactly
-- | how the mixer's recipes are written. `priority` is the author's, not the game's: replenish the
-- | whole of the first before starting the next.
-- |
-- | THE PRIORITY IS MEANT TO CHANGE. The balancer under test must read it rather than assume it,
-- | which is why it is a number here and not the order of the table.
-- | @date 2026-09-17 ]]
scene.CATALYSTS = {
    {fluid = "exciteddtcc", label = "Excited DT Crude Catalyst",       needs = 4,  priority = 1},
    {fluid = "exciteddtrc", label = "Excited DT Resplendent Catalyst", needs = 12, priority = 2},
    {fluid = "exciteddtpc", label = "Excited DT Prosaic Catalyst",     needs = 8,  priority = 3},
    {fluid = "exciteddtec", label = "Excited DT Exotic Catalyst",      needs = 16, priority = 4},
}

--[[ The bank of fluids - the ME system, in the real base.
-- |
-- | A Quantum Tank III's worth of each fluid. The author settled this on 2026-09-17 after we read
-- | the number out of GregTech: commonSizeCompute tier 8 is 512,000,000, and Quantum Tank III is
-- | tier 8. (Quantum Tank IV is tier 9, which is 1,024,000,000.)
-- | @date 2026-09-17 ]]
scene.BANK = {
    cap_per_fluid = 512000000,
}

--[[ How fast liquid moves.
-- |
-- | The author's number, 2026-09-17: a pump does ten thousand litres a second and no more. This is
-- | what stops the balancer being a trivial problem - fluid cannot be teleported, so the order
-- | things are pumped in is the whole question.
-- | @date 2026-09-17 ]]
scene.PUMP = {
    litres_per_second = 10000,
}

--[[ The compact fusion in the map.
-- |
-- | Read out of GoodGenerator's LargeFusionComputer2: a Compact Fusion Computer MK-II stores
-- | 320,006,000 EU and overclocks twice. A fusion recipe runs only if its start EU fits in the
-- | store, which is what keeps six of the sixteen plasmas out of this machine's reach - iron,
-- | silver, bismuth and nickel all want more than it holds, and americium and radon are not made
-- | by fusion at this tier at all. Those six come out of the bank instead.
-- |
-- | Power is not a constraint: thirty-two ZPM hatches against a worst case under 100k EU/t.
-- | @date 2026-09-17 ]]
scene.REACTOR = {
    machine = "Compact Fusion Computer MK-II",
    eu_store = 320006000,
    overclock = 2,
    hatches = 32,
    hatch_tier = "ZPM",
}

--[[ The two standalone fusions.
-- |
-- | Core: radon and americium plasma cannot be made in the map's reactor. Their recipes want more
-- | than a Compact Fusion MK-II's 320,006,000 EU store - 450 and 500 million - so they run in two
-- | separate MK-III reactors, each switched on and off by a redstone signal. The author, 2026-09-17:
-- | the compact fusion is what the simulation is about, and these two are there to feed it.
-- |
-- | THEY RUN THE REAL RECIPES, and nothing here says what those are. We first believed no recipe
-- | existed for either and were going to model them as invented conversions; reading the mods'
-- | bytecode at runtime found both - iridium and fluorine for radon, plutonium-241 and hydrogen for
-- | americium - so the controller looks them up like any other and their feedstock comes out of the
-- | bank the same way.
-- | @date 2026-09-17 ]]
scene.CONVERTERS = {
    {fluid = "plasma.americium", machine = "Fusion Reactor MK-III"},
    {fluid = "plasma.radon",     machine = "Fusion Reactor MK-III"},
}

--[[ An MK-III's EU store, which is what lets these two run what the compact fusion cannot.
-- | Read out of GoodGenerator's LargeFusionComputer3. @date 2026-09-17 ]]
scene.CONVERTER_EU_STORE = 640060000
scene.CONVERTER_OVERCLOCK = 4

--[[ What the program under test has to work with.
-- |
-- | Four redstone blocks, four usable faces each: sixteen lines, each carrying a value of nought to
-- | fifteen. The author, 2026-09-17: a face drives "either a multiplexer of pumps or four pumps
-- | independently - a circuit turns a 16 signal into 16 only-one-on or into 4 on/off signals".
-- |
-- | WHICH READING EACH FACE GETS IS DECLARED HERE, and the controller obeys it. That is the budget
-- | the balancer has to spend, and spending it well is the thing being tested.
-- | @date 2026-09-17 ]]
scene.CONTROLS = {
    blocks = 4,
    faces_per_block = 4,
    -- "mux": the nibble selects one of sixteen pumps. "bits": it is four on/off pumps.
    mode = {"mux", "mux", "bits", "bits", "mux", "mux", "bits", "bits",
            "mux", "mux", "bits", "bits", "mux", "mux", "bits", "bits"},
}

--[[ @brief Finds the blocks in the map that play each part.
-- |
-- | Core: BY SHAPE, NOT BY COORDINATE. The author builds the map by hand, so writing positions in
-- | here would mean editing this file every time a block moves. What the scenario actually requires
-- | is a shape - four redstone blocks each with a lamp above it, a row of tanks beside transposers -
-- | and that can be recognised wherever it was built.
-- |
-- | Answers a table of roles, and a list of what it could not find, so the scenario can say plainly
-- | what the map is missing rather than failing somewhere later.
-- |
-- | @param w  world
-- | @return table roles, table missing
-- |
-- | @date 2026-09-17 20:00
--]]
function scene.discover(w)
    local roles = {signals = {}, plasma_tanks = {}, input_tanks = {}, transposers = {}, cases = {}}
    local missing = {}

    for _, cell in ipairs(w:occupied()) do
        local p = cell:pos()
        if cell.kind == blocks.KIND.REDSTONE then
            -- A control line is a redstone block with a lamp sitting on it, which is what makes it
            -- visible from across the room as well as readable by a program.
            local above = w:get(p[1], p[2] + 1, p[3])
            if above and above.kind == blocks.KIND.LAMP then
                roles.signals[#roles.signals + 1] = {cell = cell, lamp = above, pos = p}
            end
        elseif blocks.is_tank(cell.kind) then
            if p[2] == 0 then
                roles.input_tanks[#roles.input_tanks + 1] = {cell = cell, pos = p}
            else
                roles.plasma_tanks[#roles.plasma_tanks + 1] = {cell = cell, pos = p}
            end
        elseif cell.kind == blocks.KIND.TRANSPOSER then
            roles.transposers[#roles.transposers + 1] = {cell = cell, pos = p}
        elseif cell.kind == blocks.KIND.CASE then
            roles.cases[#roles.cases + 1] = {cell = cell, pos = p}
        end
    end

    -- Sorted so a position means the same thing every run: the nth tank is the nth plasma.
    local function by_place(a, b)
        if a.pos[3] ~= b.pos[3] then return a.pos[3] < b.pos[3] end
        if a.pos[1] ~= b.pos[1] then return a.pos[1] < b.pos[1] end
        return a.pos[2] < b.pos[2]
    end
    table.sort(roles.signals, by_place)
    table.sort(roles.plasma_tanks, by_place)
    table.sort(roles.input_tanks, by_place)
    table.sort(roles.transposers, by_place)

    if #roles.signals ~= scene.CONTROLS.blocks then
        missing[#missing + 1] = string.format(
                "%d redstone blocks with a lamp on top, found %d",
                scene.CONTROLS.blocks, #roles.signals)
    end
    if #roles.plasma_tanks ~= #scene.FLUIDS then
        missing[#missing + 1] = string.format("%d tanks above ground level, found %d",
                #scene.FLUIDS, #roles.plasma_tanks)
    end
    if #roles.input_tanks < 2 then
        missing[#missing + 1] = string.format("2 tanks at ground level for the reactor's inputs, "
                .. "found %d", #roles.input_tanks)
    end
    if #roles.cases == 0 then
        missing[#missing + 1] = "a computer case to run the balancer on"
    end

    return roles, missing
end

return scene
