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
-- | The author's number, 2026-09-18: a pump does ten thousand litres a TICK and no more. This is
-- | what stops the balancer being a trivial problem - fluid cannot be teleported, so the order
-- | things are pumped in is the whole question.
-- | @date 2026-09-17 ]]
scene.PUMP = {
    litres_per_second = 10000 * 20,        -- per tick, twenty ticks to the second
}

--[[ The compact fusion in the map.
-- |
-- | Read out of GoodGenerator's LargeFusionComputer2 and its base class. A fusion recipe runs only
-- | if its start EU fits in the store, which is what keeps six of the sixteen plasmas out of this
-- | machine's reach - iron, silver, bismuth and nickel all want more than it holds, and americium
-- | and radon are not made by fusion at this tier at all. Those six come out of the bank instead.
-- |
-- | THE COMPACT FUSION RUNS RECIPES IN PARALLEL, UP TO SIXTY-FOUR AT ONCE. The author, 2026-09-18:
-- | "you are taking into consideration the x64 paralel of the compact fusion, right?" - it was not,
-- | and the reactor was being simulated at a sixty-fourth of its real throughput. `checkRecipe_EM`
-- | asks for
-- |
-- |     para = min(getMaxPara() * extraPara(startEU), getMaxEUInput() / (EU/t * overclock))
-- |
-- | parallels, takes `para` times the recipe's inputs out of the hatches in one go, and gives
-- | `para` times its output at the end of ONE cycle. `getMaxPara()` is 64 on every mark of the
-- | machine; `extraPara` is the mark's own extra multiplier, 2 on a MK-II for a recipe starting
-- | under 160,000,000 EU and 1 above it. So the cheap recipes run 128 wide.
-- |
-- | The overclock is a separate thing and is NOT a flat two: `overclock(startEU)` halves as the
-- | recipe gets dearer - 2 below 160M, 1 at or above it - and divides the duration while
-- | multiplying the EU draw. Both ladders are in LargeFusionComputer.overclock/extraPara.
-- |
-- | What this changes for the scenario: it runs the full width. A cheap recipe at sixty-four
-- | parallel eats about twenty thousand litres a second per input, against a pump that does two
-- | hundred thousand - so the pipe has ten times the headroom it needs and the cap is what binds.
-- |
-- | It was the other way round while the pump was believed to do ten thousand a SECOND: the reactor
-- | ran at about half its parallel because the hatch could not be filled fast enough, and a batch
-- | took as long to burn as its tank took to refill. Now the tank is ready long before the batch
-- | ends, which is slack rather than a problem.
-- | @date 2026-09-18 ]]
scene.REACTOR = {
    machine = "Compact Fusion Computer MK-II",
    eu_store = 320006000,

    --[[ SIXTY-FOUR AT ONCE, AND NO MORE. The author, 2026-09-18: "paralel crafting means to take
    as many of the same recipe as possible from the inputs and craft them", "64 max".
    --
    -- Worth recording what the class says, because the two differ and the author's number is the
    -- one in force here: LargeFusionComputer.checkRecipe_EM asks for getMaxPara() * extraPara(start
    -- EU), which is 64 * 2 = 128 on a MK-II for any recipe starting under 160,000,000 EU. If that
    -- doubling is wanted back it is one number below.
    --
    -- With the pumps at ten thousand litres a TICK this is a real cap rather than a formality: the
    -- pipe delivers two hundred thousand a second and a cheap recipe at 64 parallel wants twenty,
    -- so the reactor runs at whatever this says and the plumbing no longer gets in the way. ]]
    overclock = 2,
    max_para = 64,
    extra_para = 1,
    para_threshold = 160000000,

    -- getMaxEUInput() sums min(2048 * tierOverclock * maxPara * extraPara, hatch volts * amps)
    -- over the hatches. A ZPM energy hatch is 131,072 EU/t at two amps, so the hatch side wins:
    -- 262,144 EU/t each, 8,388,608 across thirty-two of them.
    hatches = 32,
    hatch_tier = "ZPM",
    hatch_volts = 131072,
    hatch_amps = 2,
}

--[[ @brief What the reactor can draw in a tick, the way getMaxEUInput() works it out.
-- | @return number - EU/t
-- | @date 2026-09-18 ]]
function scene.reactor_eu_in()
    local r = scene.REACTOR
    local cap = 2048 * r.overclock * r.max_para * r.extra_para
    return r.hatches * math.min(cap, r.hatch_volts * r.hatch_amps)
end

--[[ @brief The overclock and the parallel cap the reactor gets on one recipe.
-- |
-- | Core: BOTH DEPEND ON THE RECIPE, not on the machine alone. A recipe whose start EU is at or
-- | above the threshold loses its overclock and its extra parallel together, so an expensive plasma
-- | runs at half the width and twice the length of a cheap one on the same reactor.
-- |
-- | @param start_eu  number - the recipe's start EU (GT_Recipe.mSpecialValue)
-- | @param eut       number - the recipe's EU/t
-- | @return number, number - the overclock divisor, and the most parallels it may run
-- | @date 2026-09-18 ]]
function scene.reactor_rates(start_eu, eut)
    local r = scene.REACTOR
    local cheap = start_eu < r.para_threshold
    local oc = cheap and r.overclock or 1
    local para = r.max_para * (cheap and r.extra_para or 1)
    if eut and eut > 0 then
        para = math.min(para, math.floor(scene.reactor_eu_in() / (eut * oc)))
    end
    return oc, math.max(1, para)
end

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
--[[ The two standalone fusions - MACHINES, not conversions.
-- |
-- | Core: THEY ARE SCHEDULED LIKE THE COMPACT FUSION, NOT PINNED TO A FLUID. They used to be "the
-- | americium one" and "the radon one", which was fine while those were the only two plasmas out of
-- | the compact fusion's reach - and wrong once it became clear FOUR MORE are: iron, nickel, silver
-- | and bismuth all want a store past a MK-II's 320,006,000 EU, and every catalyst needs at least
-- | one of them, so nothing could ever be finished.
-- |
-- | All six fit inside a MK-III's 640,060,000, and there are two machines for six plasmas - so what
-- | each makes is a decision, which is to say it belongs to the program. The author, 2026-09-18:
-- | "add them both to the same mechanism".
-- |
-- | Each gets a line of its own carrying nought for idle or a number naming one of the six. Which
-- | six is worked out from the recipes, not written here, so a modpack that moves a recipe between
-- | tiers moves this with it.
-- | @date 2026-09-18 ]]
scene.CONVERTERS = {
    {machine = "Fusion Reactor MK-III"},
    {machine = "Fusion Reactor MK-III"},
}

--[[ Which line drives each of them. @date 2026-09-18 ]]
scene.CONVERTER_LINES = {10, 16}

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
    -- "mux" is a face read as one number of nought to fifteen, "bits" as four independent on/off
    -- switches, "in" a face the COMPUTER reads rather than drives.
    mode = {"mux", "mux", "mux", "mux", "mux", "mux", "mux", "mux",
            "bits", "bits", "in", "in", "in", "in", "spare", "spare"},
}

--[[ WHAT EVERY LINE IS WIRED TO, which is the contract between the scenario and the program.
-- |
-- | Out of the computer:
-- |
-- |     1-8   lift        transposer n: 0 idle, or 1 to 4 for "send that side tank up into my C"
-- |     9     mixers      one bit per catalyst, in precedence order
-- |     10    MK-III one   0 idle, or which of the six plasmas it should make
-- |     16    MK-III two   the same, for the other machine
-- |
-- | And into it - the only thing the rig ever tells the program, because it cannot see the bank:
-- |
-- |     11-14 catalyst 1 to 4 have reached their 500,000,000 L limit
-- |
-- | Nothing drives the fills or the C pushes, and that is deliberate rather than unfinished. Every
-- | tank holds one fluid for the life of the run and draws from one bank tank, so a fill has
-- | nothing left to decide; and a C tank is only ever given something when its batch is wanted, so
-- | at most one C a side is holding anything, and an empty one pushes nothing.
-- | @date 2026-09-18 ]]

--[[ HOW BIG A BATCH IS, measured on the hungrier of a recipe's two inputs.
-- |
-- | Core: A BATCH IS A WHOLE NUMBER OF RUNS, NOT A ROUND NUMBER OF LITRES. The author, 2026-09-18:
-- | "you shouldn't take 32M as the batch, but something that is aroung 500K and multiple of the
-- | input sizes of the recipe, else it will get stuck".
-- |
-- | It got stuck two ways, and both are cured by counting runs rather than litres:
-- |
-- |   - 32,000,000 is not a multiple of 144, 375 or 72, so those recipes left a few litres in the C
-- |     tank - less than one run's worth, so nothing could ever eat them - and the program waits
-- |     for both C tanks to empty. It waits for ever.
-- |   - and the two inputs have to run out TOGETHER. Nitrogen takes 16 of one and 375 of the other;
-- |     half a million litres of each would strand four hundred and eighty thousand litres of
-- |     beryllium however neatly the number divides.
-- |
-- | So a batch is N runs, and the rig stages N times each input's own amount. Both tanks empty on
-- | the same cycle, exactly, for every recipe. N is whatever puts the LARGER input near this figure.
-- |
-- | HOW BIG TO MAKE IT IS A TRADE AGAINST THE PROGRAM'S POLL, and that is the only reason it is not
-- | smaller. The computer is a real machine running at real speed while the scenario's clock can be
-- | wound up hundreds of times - so half a second of its thinking is minutes of the base's life, and
-- | between finishing one batch and being told the next the reactor simply stands there. The author,
-- | 2026-09-18: "I see a lot of delay at large speeds between the insert".
-- |
-- | A batch that burns for longer than the program's poll hides that gap. Four million litres on the
-- | hungrier input is about three minutes of game time, against a fiftieth of a second of thinking -
-- | comfortable at any speed the simulator offers, and still an eighth of a staging tank, so a tank
-- | holds eight batches and refills faster than one burns.
-- |
-- | Smaller tracks demand more finely and idles more; larger is the other way about. Nothing else
-- | depends on the figure. @date 2026-09-18 ]]
scene.BATCH_L = 4000000

--[[ WHEN A CATALYST IS FULL, AND THE ONLY THING THE RIG EVER TELLS THE PROGRAM.
-- | The author, 2026-09-18: "it tels the computer if the catalist c1,c2,c3,c4 reached the 500M
-- | limit or not". @date 2026-09-18 ]]
scene.CATALYST_LIMIT = 500000000

--[[ What the first seven lines are actually wired to. rig.LINE_NAME is the short form the signs
-- | carry; this is the contract between the scenario and the program on the computer.
-- |
-- |     1  src A       which of the sixteen feedable fluids goes into the loading slot's A tank
-- |     2  src B       and its B tank
-- |     3  load slot   0, or which slot the two bank pumps are filling
-- |     4  run slot    0, or which slot is feeding the reactor's two input hatches
-- |     5  drain slot  0, or which slot is emptying back into the bank
-- |     6  mixers      one bit per catalyst, in precedence order
-- |     7  converters  one bit per standalone MK-III
-- |
-- | and four faces that run the OTHER WAY, from the rig into the computer - the only thing the
-- | program is ever told rather than having to believe:
-- |
-- |    11-14  catalyst 1 to 4 have reached their 500,000,000 L limit
-- |
-- | Lines 3, 4 and 5 must never name the same slot. That is not a rule the wiring enforces - the
-- | scenario counts it as a collision and refuses the load - it is a rule the program keeps by
-- | construction, because a slot is in one stage at a time.
-- | @date 2026-09-18 ]]

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
    -- The tanks above ground are not counted here any more: rig.find knows what each one is for -
    -- sixteen around the transposers and four on top of them - and says so precisely. Counting them
    -- in a lump only ever produced a complaint that was true and useless.
    -- Nor the reactor's inputs: the author's design feeds it through virtual pumps from the upper
    -- tanks, so there are no input blocks to find.
    if #roles.cases == 0 then
        missing[#missing + 1] = "a computer case to run the balancer on"
    end

    return roles, missing
end

return scene
