--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | THE INVISIBLE HAND. Everything in the scenario that is not a block:
-- | the machines that turn fluids into other fluids, the pumps that carry
-- | them, and the bank they all draw on.
-- |
-- |     controller.init(w, scene)        looks the world over, once
-- |     controller.update(w, scene, dt)  one slice of simulated time
-- |     controller.draw(scene)           what is going on, on screen
-- |
-- | It works the world the way a base would, so the program under test -
-- | the balancer, running on the simulated computer - sees a system that
-- | pushes back: fluid takes time to move, machines take time to run, and
-- | the reactor in the map cannot make everything.
-- |
-- | --- internal, not on the module table -------------------------------------------------------
-- |     state, bank_take, bank_add, run_machine
-- |
-- | @date 2026-09-17 22:00
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local blocks = require("blocks")
local bank = require("bank")
local rig = require("rig")
local machines = require("machines")

--[[ The four faces of a control block, in the order the sixteen lines number them. The same order
rig.lines reads them back in; they are here too because the limit signals are driven INTO a block
rather than out of it, and rig has no reason to expose its own copy. @date 2026-09-18 ]]
local FACES = {blocks.FACE.XNEG, blocks.FACE.XPOS, blocks.FACE.ZNEG, blocks.FACE.ZPOS}

local controller = {}
local run_mixers  -- defined below, called by update

--[[ @brief A number with thousands separators. The bank deals in hundreds of millions, and a run of
-- | digits that long is unreadable without them. @date 2026-09-17 ]]
local function ui_commas(n)
    local whole = string.format("%d", math.floor((n or 0) + 0.5))
    local out = whole:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

--[[ Everything the controller remembers between frames: where things are, what the recipes are, and
how far each machine has got through what it is doing. @date 2026-09-17 ]]
local state = {
    ready = false,
    tanks = {},         -- fluid name -> the bank cell holding it
    signals = {},       -- the four redstone blocks, in map order
    recipes = {},       -- every fusion recipe the mods register
    by_out = {},        -- fluid -> the recipes that make it
    machines = {},      -- one per reactor: what it is running and how far in
    log = {},

    --[[ WHAT THE REST OF THE BASE DOES, as one number per fluid: litres a second, positive for
    what flows in and negative for what the rest of the base is drinking. The author asked for a
    knob per fluid on 2026-09-17 - "the system's deficit or production".

    This is the whole point of the dial: the balancer is not being tested against a still bank but
    against one that is filling and draining underneath it, and a deficit is what makes an ordering
    decision cost something. `buf` holds the text while it is being typed, which a number cannot. ]]
    flow = {},
    buf = {},

    --[[ FOUR MIXERS, one per catalyst, each switched on by its own bit.
    --
    -- One mixer would mean choosing a catalyst, and a choice is a thing you can only have one of:
    -- the crude catalyst would run and the other three would wait however much plasma there was.
    -- Four run at once and compete for the same sixteen plasmas, which is what a base actually
    -- looks like and what makes the priority decision worth making - the program is choosing which
    -- of them to let drink, not which single one exists. @date 2026-09-18 ]]
    mixers = {},
    collisions = 0,
    jams = 0,

    --[[ How much of the run the reactor has actually spent working.
    --
    -- The one number that says whether the program is keeping up. Everything else - litres made,
    -- batches finished - goes up either way; this is what falls when the plant is standing waiting
    -- to be told something, which is the cost of a batch that burns faster than the program looks.
    -- @date 2026-09-18 ]]
    run_time = 0,
    busy_time = 0,

    --[[ The plumbing, and the reactor's two input hatches - which ARE blocks: the two loose tanks
    standing on the ground with no transposer beside them. They were two numbers in here once, and
    the tanks the author had put in the map for them sat empty however well the run went.
    @date 2026-09-18 ]]
    rig = nil,
    feed = {{cell = nil, fluid = "", litres = 0}, {cell = nil, fluid = "", litres = 0}},
    -- how many times the reactor was made to change what it is making
    flips = 0,
}

--[[ @brief Takes fluid out of the bank, up to what is there.
-- | @return number - how much was actually taken
-- | @date 2026-09-17 ]]
local function bank_take(fluid, litres)
    local cell = state.tanks[fluid]
    if not cell or litres <= 0 then
        return 0
    end
    local held = cell:fluid_get()
    local got = math.min(held[2], litres)
    if got > 0 then
        cell:fluid_set(fluid, held[2] - got, held[3])
    end
    return got
end

--[[ @brief Puts fluid into the bank, up to what it will hold.
-- | @return number - how much actually went in
-- | @date 2026-09-17 ]]
local function bank_add(fluid, litres)
    local cell = state.tanks[fluid]
    if not cell or litres <= 0 then
        return 0
    end
    local held = cell:fluid_get()
    local lock = cell:fluid_lock_get()
    local room = cell:fluid_capacity() - held[2]
    local put = math.min(room, litres)
    if put > 0 then
        cell:fluid_set(fluid, held[2] + put, held[3] ~= "" and held[3] or lock[2])
    end
    return put
end

--[[ @brief Sets a fluid's flow: litres a second, positive for what the rest of the base puts in and
-- | negative for what it drinks. The knob in the window writes this, and so can a test.
-- | @date 2026-09-17 ]]
function controller.set_flow(fluid, rate)
    state.flow[fluid] = rate or 0
    state.buf[fluid] = string.format("%d", state.flow[fluid])
end

--[[ @brief What a fluid's flow is set to. @date 2026-09-17 ]]
function controller.get_flow(fluid)
    return state.flow[fluid] or 0
end

--[[ @brief What one of the reactor's two input hatches holds.
-- |
-- | The hatch is a tank in the world when the map has one, and a pair of numbers when it does not -
-- | a hand-built test world need not stand two tanks up to exercise the reactor.
-- | @date 2026-09-18 ]]
local function feed_get(i)
    local f = state.feed[i]
    if not f then
        return "", 0
    end
    if f.cell then
        local h = f.cell:fluid_get()
        return h[1], h[2]
    end
    return f.fluid or "", f.litres or 0
end

--[[ @brief Puts a fluid in one of the reactor's two input hatches. @date 2026-09-18 ]]
local function feed_set(i, name, litres, label)
    local f = state.feed[i]
    if not f then
        return
    end
    if litres <= 0 then
        name, litres = "", 0
    end
    if f.cell then
        f.cell:fluid_set(name, litres, label or name)
    end
    f.fluid, f.litres = name, litres
end

--[[ @brief What fluid is staged in one of the reactor's two inputs. @date 2026-09-18 ]]
function controller.feed_fluid(which)
    local name = feed_get(which)
    return name
end

--[[ @brief One of a transposer's four side tanks, numbered the way the drawing reads.
-- | @date 2026-09-18 ]]
function controller.side_tank(t, k)
    local g = state.rig and state.rig.groups[t]
    return g and g.tanks[k]
end

--[[ @brief One of the reactor's two input hatches, as a cell. @date 2026-09-18 ]]
function controller.hatch(i)
    return state.feed[i] and state.feed[i].cell
end

--[[ @brief The C tank above a transposer - what a lifted batch waits in. @date 2026-09-18 ]]
function controller.c_tank(t)
    local g = state.rig and state.rig.groups[t]
    return g and g.upper
end

--[[ @brief Which fluid lives in which tank, as rig.assign_tanks worked it out. @date 2026-09-18 ]]
function controller.plan()
    return state.plan or {a = {}, b = {}, at = {}, by_out = {}}
end

--[[ @brief The plan as Lua source, to be dropped on the computer's disk.
-- |
-- | Core: THE PROGRAM IS TOLD, NOT MADE TO GUESS. Which fluid is in which tank comes out of the
-- | mods' own recipes, and a program inside the machine cannot read those - it has no way to know
-- | that tank three of transposer one is deuterium. Every earlier version of this had the program
-- | carrying its own copy of the ordering, and the two drifted apart the first time the derivation
-- | changed: the program drove lines nobody was reading and every symptom appeared somewhere else.
-- |
-- | A base would configure this. So the scenario writes it, as a file, and the program reads it -
-- | which also means a modpack change moves both halves at once.
-- |
-- | @return string - a Lua chunk returning the table
-- | @date 2026-09-18 ]]
function controller.plan_source()
    local plan = controller.plan()
    local out = {"-- written by the scenario; do not edit", "return {"}

    out[#out + 1] = string.format("  transposers = %d, per_side = %d,",
            rig.TRANSPOSERS, rig.PER_SIDE)
    out[#out + 1] = string.format("  tank_cap = %d,", blocks.tank_capacity())
    out[#out + 1] = "  conv = {"
    for i, c in ipairs(plan.conv or {}) do
        out[#out + 1] = string.format("    [%d] = {fluid=%q, rate=%.3f},", i, c.fluid, c.rate)
    end
    out[#out + 1] = "  },"
    out[#out + 1] = string.format("  conv_lines = {%s},",
            table.concat(state.conv_lines or {}, ", "))

    out[#out + 1] = "  hold = {"
    local held = {}
    for f in pairs(plan.hold or {}) do
        held[#held + 1] = f
    end
    table.sort(held)
    for _, f in ipairs(held) do
        out[#out + 1] = string.format("    [%q] = %d,", f, plan.hold[f])
    end
    out[#out + 1] = "  },"

    out[#out + 1] = "  tank = {"
    for t = 1, rig.TRANSPOSERS do
        local row = {}
        for k = 1, rig.PER_SIDE do
            local f = plan.tank[t] and plan.tank[t][k]
            row[#row + 1] = f and string.format("[%d]=%q", k, f) or nil
        end
        out[#out + 1] = string.format("    [%d] = {%s},", t, table.concat(row, ", "))
    end
    out[#out + 1] = "  },"

    out[#out + 1] = "  recipe = {"
    local names = {}
    for name in pairs(plan.by_out) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local r = plan.by_out[name]
        out[#out + 1] = string.format(
                "    [%q] = {a=%q, b=%q, a_t=%d, a_k=%d, b_t=%d, b_k=%d, "
                        .. "amt_a=%d, amt_b=%d, amt_out=%d, runs=%d, "
                        .. "lift_a=%d, lift_b=%d, yield=%d},",
                name, r.a, r.b, r.a_t, r.a_k, r.b_t, r.b_k, r.amt_a, r.amt_b, r.amt_out,
                r.runs, r.lift_a, r.lift_b, r.yield)
    end
    out[#out + 1] = "  },"
    out[#out + 1] = "}"
    return table.concat(out, "\n") .. "\n"
end

--[[ @brief How many ticks the reactor spent holding two fluids that make nothing.
-- |
-- | The jam the author found: "the inputs still get stuck at 125,125". A batch lifted before the
-- | last had been eaten puts a new fluid up against the tail of the old one, the hatch refuses the
-- | rest, and the rig stops - while every other reading still looks healthy.
-- | @date 2026-09-18 ]]
function controller.jams()
    return state.jams
end

--[[ @brief How many times two C tanks on one side held fluid at once.
-- |
-- | The author's word for what this counts, 2026-09-18: "distribute pumps such that the least
-- | number of colisions occour". Two C tanks a side is two fluids for one hatch, which can only
-- | mean a batch was lifted while the last one was still burning. Worth seeing rather than
-- | silently half-obeying.
-- | @date 2026-09-18 ]]
function controller.collisions()
    return state.collisions
end

--[[ @brief How much is staged in one of the reactor's two inputs. @date 2026-09-18 ]]
function controller.feed_level(which)
    local _, litres = feed_get(which)
    return litres
end

--[[ @brief What fraction of the run the reactor has spent working, nought to one. @date 2026-09-18 ]]
function controller.duty()
    return state.run_time > 0 and (state.busy_time / state.run_time) or 0
end

--[[ @brief How many parallels the reactor ran on its last cycle.
-- |
-- | The number the author asked about, 2026-09-18: "you are taking into consideration the x64
-- | paralel of the compact fusion, right?". Worth being able to read, because the interesting case
-- | is not the cap - it is how far below the cap the pumps are keeping it.
-- | @date 2026-09-18 ]]
function controller.reactor_para()
    return state.machines[1] and state.machines[1].para or 0
end

--[[ @brief How many of the four mixers are part way through a cycle. @date 2026-09-18 ]]
function controller.mixers_running()
    local n = 0
    for _, m in ipairs(state.mixers) do
        if m.making then
            n = n + 1
        end
    end
    return n
end

--[[ @brief How many times the reactor has been made to change what it makes.
-- |
-- | The author's second goal, 2026-09-17: "not flip the machine too much, else it would consume too
-- | much power". Counted here so it can be measured before anything is optimised for it.
-- | @date 2026-09-18 ]]
function controller.flips()
    return state.flips
end

--[[ @brief How much of a fluid the bank holds. @date 2026-09-17 ]]
function controller.bank_level(fluid)
    local cell = state.tanks[fluid]
    return cell and cell:fluid_get()[2] or 0
end

--[[ @brief Reads the world once and works out what everything is.
-- |
-- | Core: THE RECIPES COME FROM THE MODS, not from this file. vc.fusion_recipes reads them out of
-- | the installed jars' compiled code every time the scenario starts, so the simulation runs the
-- | modpack that is actually installed - and says plainly how many it found.
-- |
-- | @param w      world
-- | @param scene  the scenario
-- | @return table - lines worth printing
-- |
-- | @date 2026-09-17 22:00
--]]
function controller.init(w, scene, mc_path)
    state.tanks = {}
    state.signals = {}
    state.machines = {}
    state.log = {}

    for _, cell in ipairs(w:occupied()) do
        if blocks.is_tank(cell.kind) then
            local lock = cell:fluid_lock_get()
            if lock[1] ~= "" then
                state.tanks[lock[1]] = cell
            end
        end
    end

    local found, complaints = rig.find(w)
    state.rig = found
    state.signals = found.signals
    state.tanks = found.bank
    --[[ THE REACTOR'S INPUTS ARE REAL TANKS. They used to be two numbers in here, which meant the
    tanks standing in the map for them never held anything - the run was correct and the thing a
    person could see was not.
    --
    -- Their capacity is left alone: they are what the author built, a Super Tank IV apiece, and a
    -- whole batch fits in one with room to spare. Pinching them to a notional hatch size was
    -- invention, and it made the C tank a bottleneck that was not there. ]]
    state.feed = {}
    for i = 1, 2 do
        local cell = found.hatches and found.hatches[i]
        if cell then
            cell:fluid_set("", 0, "")
        end
        state.feed[i] = {cell = cell, fluid = "", litres = 0}
    end
    state.flips = 0

    state.case = nil
    for _, cell in ipairs(w:occupied()) do
        if cell.kind == blocks.KIND.CASE then
            state.case = cell
        end
    end
    -- THE PLAN: which fluid lives in which tank, worked out from the recipes rather than written
    -- down. It is also what the program on the computer is handed, so the two cannot drift.
    local wanted = {}
    for i = 1, 16 do
        wanted[bank.PLASMAS[i]] = true
    end
    local plan, plan_said = rig.assign_tanks(vc.fusion_recipes(mc_path or ""),
            scene.REACTOR.eu_store, wanted, scene.BATCH_L)
    state.plan = plan
    for _, c in ipairs(plan_said) do
        complaints[#complaints + 1] = "tanks: " .. c
    end

    --[[ A DEFINED STARTING STATE for the staging area, which the bank has had all along and this
    did not. A scene map is a file, and a file remembers - the author's map came over with seventeen
    tanks still holding what an earlier design had pumped into them, including two C tanks half full
    of deuterium and tritium that nothing in this run had lifted. The reactor then saw pairs nobody
    had chosen, and two C tanks on one side counted as a collision every tick.
    --
    -- Locked rather than merely emptied, so a tank says what it is for while it is still filling -
    -- an empty deuterium tank is still the deuterium tank, which is the whole point of giving each
    -- fluid one of its own. ]]
    for t, g in ipairs(found.groups) do
        for k = 1, rig.PER_SIDE do
            local cell = g.tanks[k]
            if cell then
                local want = plan.tank[t] and plan.tank[t][k]
                cell:fluid_set("", 0, "")
                cell:fluid_lock_set(want or "", want and bank.display(want) or "")
            end
        end
        if g.upper then
            g.upper:fluid_set("", 0, "")
            g.upper:fluid_lock_set("", "")
        end
    end

    rig.build_pumps(plan)
    state.board = rig.build_board(w, bank.row(w))

    state.recipes = vc.fusion_recipes(mc_path or "")
    local wanted = {}
    for i = 1, 16 do
        wanted[bank.PLASMAS[i]] = true
    end
    state.by_out = {}
    for _, e in ipairs(state.recipes) do
        local r = {
            in_a = e[1], amt_a = tonumber(e[2]),
            in_b = e[3], amt_b = tonumber(e[4]),
            out  = e[5], amt_out = tonumber(e[6]),
            ticks = tonumber(e[7]), eut = tonumber(e[8]), start_eu = tonumber(e[9]),
        }
        state.by_out[r.out] = state.by_out[r.out] or {}
        table.insert(state.by_out[r.out], r)
    end

    -- The compact fusion, and the two that make what it cannot.
    state.collisions = 0
    state.jams = 0
    state.run_time, state.busy_time = 0, 0
    state.mixers = {}
    for i, c in ipairs(scene.CATALYSTS) do
        state.mixers[i] = {catalyst = c, making = false, progress = 0, made = 0}
    end

    state.machines[1] = {name = scene.REACTOR.machine, store = scene.REACTOR.eu_store,
            overclock = scene.REACTOR.overclock, making = nil, progress = 0}
    for i, conv in ipairs(scene.CONVERTERS) do
        state.machines[i + 1] = {name = conv.machine, store = scene.CONVERTER_EU_STORE,
                overclock = scene.CONVERTER_OVERCLOCK, making = nil, progress = 0}
    end

    --[[ WHAT THE STANDALONE REACTORS CAN MAKE THAT THE COMPACT ONE CANNOT, worked out rather than
    listed: a plasma whose cheapest recipe is past a MK-II's store but inside a MK-III's. That is
    six of the sixteen here, and every catalyst needs at least one of them.
    --
    -- The rate goes with it because the program cannot see the bank: it has to credit what it has
    -- told a machine to make, and for that it needs to know how fast. One recipe at a time, no
    -- parallel, the duration divided by the machine's overclock. ]]
    state.conv_lines = scene.CONVERTER_LINES or {}
    plan.conv = {}
    for i = 1, 16 do
        local p = bank.PLASMAS[i]
        local here = controller.best_recipe(p, scene.REACTOR.eu_store)
        local there = controller.best_recipe(p, scene.CONVERTER_EU_STORE)
        if there and not here then
            local seconds = math.max(1, math.floor(there.ticks / scene.CONVERTER_OVERCLOCK)) / 20.0
            plan.conv[#plan.conv + 1] = {fluid = p, rate = there.amt_out / seconds}
        end
    end

    for _, f in ipairs(bank.FLUIDS) do
        state.flow[f] = state.flow[f] or 0
        state.buf[f] = state.buf[f] or "0"
    end

    state.ready = true

    --[[ WHAT NOTHING IN THE BASE CAN MAKE, said at startup rather than discovered by watching.
    --
    -- Four of the sixteen plasmas have no source here at all: the compact fusion cannot reach them
    -- and neither standalone reactor makes them. Every catalyst needs at least one of the four, so
    -- as the scenario stands no catalyst can ever be finished - which is a fact about the map, not
    -- a fault in the program, and it belongs on the screen where the program's behaviour is being
    -- judged. ]]
    local orphan = {}
    for i = 1, 16 do
        local p = bank.PLASMAS[i]
        local made_here = plan.by_out[p] ~= nil
        for _, c in ipairs(plan.conv) do
            if c.fluid == p then
                made_here = true
            end
        end
        if not made_here then
            orphan[#orphan + 1] = p
        end
    end

    local log = {string.format("%d fusion recipes read from the mods", #state.recipes)}
    if #orphan > 0 then
        log[#log + 1] = "nothing here makes: " .. table.concat(orphan, ", ")
    end
    local runnable = 0
    for _, f in ipairs(bank.FLUIDS) do
        if controller.best_recipe(f, scene.REACTOR.eu_store) then
            runnable = runnable + 1
        end
    end
    log[#log + 1] = string.format("%s can make %d of the bank's fluids",
            scene.REACTOR.machine, runnable)
    log[#log + 1] = string.format("%d bank tanks, %d control blocks, %d transposer groups",
            #bank.FLUIDS, #state.signals, #found.groups)
    log[#log + 1] = string.format("%d fluids in tanks: %d on the left, %d on the right",
            #plan.a + #plan.b, #plan.a, #plan.b)
    for _, c in ipairs(complaints) do
        log[#log + 1] = "rig: " .. c
    end
    state.log = log
    return log
end

--[[ @brief The cheapest recipe for a fluid that a given reactor can actually hold.
-- |
-- | Core: a fusion recipe runs only if its start EU fits in the reactor's store. That one rule is
-- | what divides the sixteen plasmas into the ones the map's compact fusion can make and the ones
-- | that have to come from somewhere else, so it belongs here rather than in the balancer.
-- |
-- | @param fluid  string
-- | @param store  number - the reactor's EU store
-- | @return table | nil
-- |
-- | @date 2026-09-17 22:00
--]]
function controller.best_recipe(fluid, store)
    local best = nil
    for _, r in ipairs(state.by_out[fluid] or {}) do
        if r.start_eu <= store and (not best or r.start_eu < best.start_eu) then
            best = r
        end
    end
    return best
end

--[[ @brief Runs one machine for a slice of time.
-- |
-- | Core: a machine takes its whole input at the start of a cycle and gives its whole output at the
-- | end, which is how GregTech runs a recipe - not a trickle. The cycle is the recipe's duration
-- | divided by the reactor's overclock, in ticks, at twenty ticks a second.
-- |
-- | The feedstock comes out of the bank and the product goes back into it. Nothing starts unless
-- | every input is there, so a machine simply idles when the bank is short rather than half-running.
-- |
-- | @param m      table - the machine's state
-- | @param want   string | nil - the fluid it should be making, nil to idle
-- | @param dt     number - seconds
-- |
-- | @date 2026-09-17 22:00
--]]
--[[ @brief Runs the compact fusion on whatever its two inputs happen to be.
-- |
-- | Core: THE MACHINE IS NOT TOLD WHAT TO MAKE. It looks at its two feeds, finds the recipe they
-- | are the inputs for, and runs it - which is what a fusion reactor does in the game. That is why
-- | the balancer's job is staging the right pair rather than issuing a command, and why flipping
-- | it costs: changing what it makes means draining one pair and staging another.
-- |
-- | @param scene  the scenario
-- | @param dt     number - seconds
-- |
-- | @date 2026-09-18 00:00
--]]
local function run_reactor(scene, dt)
    local m = state.machines[1]
    local a_name, a_litres = feed_get(1)
    local b_name, b_litres = feed_get(2)
    local a = {fluid = a_name, litres = a_litres}
    local b = {fluid = b_name, litres = b_litres}

    if not m.making then
        -- SAY WHAT IS ACTUALLY WRONG. This used to set a bare true and the window printed
        -- "waiting - no true in the bank", which is nonsense twice over: the compact fusion never
        -- touches the bank. It burns what is in its two hatches and nothing else.
        if a.fluid == "" or b.fluid == "" then
            m.starved = "the input hatches are empty"
            return
        end
        -- Either way round: the reactor does not care which hatch a fluid came in through.
        local found = nil
        for _, list in pairs(state.by_out) do
            for _, r in ipairs(list) do
                if r.start_eu <= m.store then
                    if (r.in_a == a.fluid and r.in_b == b.fluid
                            and a.litres >= r.amt_a and b.litres >= r.amt_b) then
                        found = {r = r, from_a = r.amt_a, from_b = r.amt_b}
                    elseif (r.in_a == b.fluid and r.in_b == a.fluid
                            and b.litres >= r.amt_a and a.litres >= r.amt_b) then
                        found = {r = r, from_a = r.amt_b, from_b = r.amt_a}
                    end
                end
                if found then break end
            end
            if found then break end
        end
        if not found then
            --[[ TWO FLUIDS IN THE HATCHES THAT MAKE NOTHING. This is the jam, and it has exactly
            one cause: a batch was lifted before the last one had been eaten, so the new fluid met
            the old one. Counted rather than merely displayed, because it is the thing a test has to
            be able to fail on - everything else about the run looks healthy while it happens. ]]
            state.jams = state.jams + 1
            m.starved = string.format("%s and %s are not a recipe", a.fluid, b.fluid)
            return
        end

        if m.last_made and m.last_made ~= found.r.out then
            state.flips = state.flips + 1
        end
        m.last_made = found.r.out

        --[[ HOW WIDE. The machine batches the recipe up to sixty-four times over - a hundred and
        twenty-eight on a cheap one - and takes every parallel's input out of the hatches at the
        start of the cycle, so what is actually staged decides the width. `handleParallelRecipe` in
        the game does the same thing: it asks for the cap and gets back however many the fluids
        allowed. The pumps, not the reactor, are what this ends up limited by. ]]
        local oc, cap = scene.reactor_rates(found.r.start_eu, found.r.eut)
        local para = math.min(cap,
                math.floor(a.litres / found.from_a),
                math.floor(b.litres / found.from_b))

        --[[ NEVER A CYCLE OF NOTHING. Unreachable as things stand - a hatch holding less than one
        run fails the recipe match above before it gets here - and kept anyway, because a machine
        that sits "working" on nothing is invisible from every direction: the lamps are lit, the
        levels do not move, and nothing anywhere says why. ]]
        if para < 1 then
            m.starved = string.format("a part litre in the hatches: %.6f / %.6f",
                    a.litres, b.litres)
            return
        end

        feed_set(1, a.fluid, a.litres - found.from_a * para, a.fluid)
        feed_set(2, b.fluid, b.litres - found.from_b * para, b.fluid)
        m.making = found.r
        m.para = para
        m.seconds = math.max(1, math.floor(found.r.ticks / oc)) / 20.0
        m.progress = 0
        m.starved = nil
    end

    m.progress = m.progress + dt
    if m.progress >= m.seconds then
        bank_add(m.making.out, m.making.amt_out * m.para)
        m.progress = 0
        m.making = nil
    end
end

local function run_machine(m, want, dt)
    if not want then
        m.making = nil
        m.progress = 0
        return
    end

    if not m.making then
        local r = controller.best_recipe(want, m.store)
        if not r then
            return                                  -- this reactor cannot hold that recipe
        end
        -- Both inputs, all at once, or nothing happens.
        -- NAME THE MISSING THING. "waiting - the bank is short" was true of both reactors for an
        -- entire session and told nobody that the bank had no iridium in it at all.
        if controller.bank_level(r.in_a) < r.amt_a then
            m.starved = "no " .. r.in_a .. " in the bank"
            return
        end
        if controller.bank_level(r.in_b) < r.amt_b then
            m.starved = "no " .. r.in_b .. " in the bank"
            return
        end
        bank_take(r.in_a, r.amt_a)
        bank_take(r.in_b, r.amt_b)
        m.making = r
        m.progress = 0
        m.starved = nil
    end

    local seconds = (m.making.ticks / m.overclock) / 20.0
    m.progress = m.progress + dt
    if m.progress >= seconds then
        bank_add(m.making.out, m.making.amt_out)
        m.progress = 0
        m.making = nil
    end
end

--[[ @brief Runs the Transcendent Plasma Mixer for a slice of time.
-- |
-- | Core: the mixer takes 1000 L of each of the first `needs` plasmas and gives 1000 L of its
-- | catalyst. The four recipes and their plasma counts are gregtech's own, read in scene.lua.
-- |
-- | It makes the most important catalyst it has the plasmas for, so a program that keeps the first
-- | four plasmas topped up gets crude catalyst forever, and one that manages all sixteen gets the
-- | exotic. That is the whole shape of the problem the balancer is being asked to solve.
-- |
-- | @param scene  the scenario
-- | @param dt     number - seconds
-- |
-- | @date 2026-09-17 22:00
--]]
function run_mixers(scene, dt, bits)
    local PER = 1000                       -- litres of each plasma, and of the catalyst

    for i, m in ipairs(state.mixers) do
        local on = (math.floor(bits / (2 ^ (i - 1))) % 2) == 1
        local c = m.catalyst

        if not m.making then
            -- ONLY WHEN THE COMPUTER SAYS SO. The author, 2026-09-17: "only from the computer the
            -- command to turn plasmas into one of the excited will come".
            if on then
                local ok = true
                for k = 1, c.needs do
                    if controller.bank_level(bank.PLASMAS[k]) < PER then
                        ok = false
                        break
                    end
                end

                -- And room under the ceiling: it stops around five hundred million rather than
                -- filling a tank to the brim and spilling.
                local cell = state.tanks[c.fluid]
                local ceiling = math.min(cell and cell:fluid_capacity() or 0, 500000000)
                if ok and cell and cell:fluid_get()[2] + PER <= ceiling then
                    for k = 1, c.needs do
                        bank_take(bank.PLASMAS[k], PER)
                    end
                    m.making = true
                    m.progress = 0
                end
            end
        else
            -- Twenty seconds a cycle, which is the mixer's own recipe time in the game. A mixer
            -- switched off mid-cycle finishes what it took: the plasmas are already in it.
            m.progress = m.progress + dt
            if m.progress >= 20.0 then
                bank_add(c.fluid, PER)
                m.made = m.made + PER
                m.progress = 0
                m.making = false
            end
        end
    end
end

--[[ @brief Reads the sixteen control lines the program under test drives.
-- |
-- | Four redstone blocks, four faces each, every face a value of nought to fifteen. What a face
-- | MEANS is scene.CONTROLS' business; this only reads them.
-- |
-- | @return table - sixteen numbers
-- | @date 2026-09-17 22:00
--]]
function controller.read_signals()
    local out = {}
    local FACES = {blocks.FACE.XNEG, blocks.FACE.XPOS, blocks.FACE.ZNEG, blocks.FACE.ZPOS}
    for _, sig in ipairs(state.signals) do
        for _, face in ipairs(FACES) do
            out[#out + 1] = sig.cell:rs_get(face)
        end
    end
    while #out < 16 do
        out[#out + 1] = 0
    end
    return out
end

--[[ @brief One slice of simulated time.
-- |
-- | @param w      world
-- | @param scene  the scenario
-- | @param dt     number - seconds since the last call
-- |
-- | @date 2026-09-17 22:00
--]]
local function tick(w, scene, dt)

    -- The rest of the base, first: what it puts in and what it drinks, before the machines look
    -- at what is there. A fluid the bank has none of simply cannot be drunk.
    for _, f in ipairs(bank.FLUIDS) do
        local rate = state.flow[f] or 0
        if rate > 0 then
            bank_add(f, rate * dt)
        elseif rate < 0 then
            bank_take(f, -rate * dt)
        end
    end

    --[[ THE RIG ANSWERS. Four faces carrying one bit each: catalyst n has reached its limit.
    --
    -- This is a comparator on a bank tank, and it is driven INTO the block rather than out of it -
    -- cell_t::rs_in, which had to be added for this, because until then nothing in the world could
    -- tell a computer anything. The program reads them with redstone.getInput.
    --
    -- Why it matters: the program has no line of sight to the bank. Every other number it works
    -- with is its own bookkeeping, and bookkeeping drifts; whether a catalyst is DONE is the one
    -- thing that must not be a guess, because getting it wrong means either stopping early or
    -- never moving on to the next catalyst at all. ]]
    -- Once the computer is running, put the control blocks AND THE SLOTS in the order IT sees
    -- them. Both are numbered by component address inside the machine and by position out here,
    -- and the two orders are not the same one.
    if state.case then
        rig.sort_signals(state.rig, blocks.u(state.case).machine)
        rig.sort_groups(state.rig, blocks.u(state.case).machine)
    end

    local sig = rig.lines(state.signals)
    local function bit(v, n) return (math.floor(v / (2 ^ (n - 1))) % 2) == 1 end

    --[[ THE EIGHT TRANSPOSERS, one control face each.
    --
    -- Core: A TRANSPOSER DOES ONE THING TO ONE TANK. The face's low two bits pick the tank, bit
    -- three fills it from the bank and bit four lifts it into the C tank above. That is the whole
    -- instruction set, and it is why eight transposers cost eight of the sixteen lines rather than
    -- thirty-two: the block itself cannot do two things at once, so nothing is lost by saying so.
    --
    -- WHICH FLUID A TANK TAKES IS NOT ON THE WIRE. Every input fluid has a tank of its own for the
    -- life of the run - the assignment is a two-colouring of the recipes, worked out in
    -- rig.assign_tanks - so naming the tank names the fluid. That is the whole reason a tank never
    -- has to be flushed between recipes. ]]
    local groups = state.rig.groups
    local plan = state.plan
    local half = rig.TRANSPOSERS / 2

    --[[ A LIFT IS AN EDGE, NOT A LEVEL.
    --
    -- Core: ONE COMMAND, ONE LIFT, however long the wire stays high. A program cannot take a line
    -- down again any faster than it polls, and the scenario's clock runs hundreds of times faster
    -- than the program does - so a line left high for one poll was being honoured over and over.
    -- The author saw the hatches holding five batches of a recipe nobody had asked for five times:
    -- "now it's stuck on 0L?", with the C tanks reading empty because they had long since handed
    -- everything on.
    --
    -- The request is LATCHED, not consumed on sight, and the latch outlives the wire going low.
    -- Two reasons, both found the hard way:
    --   - the lift can legitimately fail on the tick it is asked for, because C may still hold the
    --     last batch or the tank may be a few litres short;
    --   - and a program that asks for the same tank twice running never puts a nought in between,
    --     so there is no second edge to find. Waiting for one deadlocks: no lift, so the machine
    --     never reports busy, so the program never moves on, so the line never changes. ]]
    state.lift_seen = state.lift_seen or {}
    state.lift_armed = state.lift_armed or {}

    local wants = {}
    for t, g in ipairs(groups) do
        local v = sig[t] or 0

        -- EVERY FILL RUNS, ALWAYS, AND NOTHING ON THE WIRE SAYS SO. A tank holds one fluid for the
        -- life of the run and takes it from one bank tank; when it is full it stops. There is
        -- nothing left for a command to decide, so there is no command.
        for k = 1, rig.PER_SIDE do
            local fluid = plan.tank[t] and plan.tank[t][k]
            local tank = g.tanks[k]
            if tank and fluid then
                -- Only up to what a batch or two needs. A tank filled to the brim is a store, and
                -- a store of something the base makes is that much of it hidden from the bank.
                local hold = math.min(tank:fluid_capacity(), plan.hold[fluid] or math.huge)
                rig.pump(state.tanks[fluid], tank, fluid, bank.display(fluid), dt, hold)
            end
        end

        if rig.lifting(v) then
            if state.lift_seen[t] ~= v then
                state.lift_seen[t] = v
                state.lift_armed[t] = rig.tank_of(v)        -- a fresh request
            end
        else
            state.lift_seen[t] = nil            -- the wire is low; the same value counts as new
        end
        if state.lift_armed[t] then
            wants[t] = state.lift_armed[t]
        end
    end

    --[[ THE LIFT, AND IT IS ATOMIC - BUT IT MOVES A BATCH, NOT A TANKFUL.
    --
    -- The author, 2026-09-18: "a computer transfer makes sure that all 32M of liquid are transfered
    -- in one go and the tank is left empty in it's back" - and then, once that had been built and
    -- had stuck: "you shouldn't take 32M as the batch, but something that is aroung 500K and
    -- multiple of the input sizes of the recipe, else it will get stuck".
    --
    -- Both are satisfied by moving N RUNS' WORTH in one step. It is still all or nothing, and it
    -- still leaves nothing behind that the reactor cannot use: N times each input's own amount
    -- means the two C tanks run dry on the same cycle, for every recipe, exactly. A tankful does
    -- not - 32,000,000 is not a whole number of 144s, so those recipes stranded a few litres in C
    -- that nothing could eat and the program waited for an empty tank for ever.
    --
    -- WHICH pair is going up is what says how much, so the rig looks the recipe up. That is not the
    -- rig making a decision: the pumps between these tanks and these hatches were sized for these
    -- recipes, and a pair that is not a recipe is a mistake rather than an instruction. ]]
    local lifting = {}
    for t, k in pairs(wants) do
        lifting[t] = plan.tank[t] and plan.tank[t][k]
    end
    local recipe = next(lifting) and rig.pair_recipe(plan, lifting) or nil

    if next(lifting) and not recipe then
        state.collisions = state.collisions + 1          -- lifted a pair nothing can be made from
    end

    if recipe then
        for t, k in pairs(wants) do
            local g = groups[t]
            local fluid = lifting[t]
            local want = (fluid == recipe.a) and recipe.lift_a
                    or ((fluid == recipe.b) and recipe.lift_b or nil)
            local tank = g.tanks[k]
            if want and tank and g.upper then
                local have = tank:fluid_get()
                local into = g.upper:fluid_get()
                if have[1] ~= "" and into[1] == "" and have[2] >= want then
                    g.upper:fluid_set(have[1], want, have[3])
                    tank:fluid_set(have[1], have[2] - want, have[3])
                    state.lift_armed[t] = nil           -- the command is spent
                end
            end
        end
    end

    --[[ THE C TANKS INTO THE REACTOR, WIRED STRAIGHT THROUGH. Nothing on a line says whether a C
    pushes: an empty one has nothing to push, and the lift is what decides when a C stops being
    empty. C1 to C4 reach the left hatch and C5 to C8 the right, which is also why the pair cannot
    arrive the wrong way round whatever the program does.
    --
    -- Two C tanks on one side holding fluid at the same time would be two fluids for one hatch.
    -- That should never happen - it would mean a batch was lifted while the last one was still
    -- burning - so it is counted rather than silently half-done. ]]
    local pushed = {nil, nil}
    for c, g in ipairs(groups) do
        local have = g.upper and g.upper:fluid_get() or {"", 0, ""}
        if have[1] ~= "" then
            local which = c <= half and 1 or 2
            if pushed[which] then
                state.collisions = state.collisions + 1
            else
                pushed[which] = true
                local held, litres = feed_get(which)
                if held == "" or held == have[1] then
                    -- Bounded by the hatch's own tank and nothing else.
                    local hatch = state.feed[which].cell
                    local room = (hatch and hatch:fluid_capacity() or math.huge) - litres
                    -- Whole litres, for the same reason rig.pump rounds: a fractional hatch floors
                    -- to nought runs and the reactor spins making nothing.
                    local moved = math.floor(math.min(have[2], room, rig.PUMP_RATE * dt))
                    if moved >= 1 then
                        g.upper:fluid_set(have[1], have[2] - moved, have[3])
                        if have[2] - moved <= 0 then
                            g.upper:fluid_set("", 0, "")
                        end
                        feed_set(which, have[1], litres + moved, have[3])
                    end
                end
            end
        end
    end

    state.run_time = state.run_time + dt
    if state.machines[1] and state.machines[1].making then
        state.busy_time = state.busy_time + dt
    end

    -- THE REACTOR runs whatever its two inputs happen to be a recipe for. Nothing tells it what to
    -- make: what is in front of it decides, which is how the machine works in the game and is the
    -- reason the balancer's job is staging rather than commanding.
    run_reactor(scene, dt)

    -- LINE 7: the two standalone reactors, one bit each. They make what they make.
    for i = 1, #scene.CONVERTERS do
        local line = (scene.CONVERTER_LINES or {})[i] or 0
        local pick = plan.conv[math.floor(sig[line] or 0)]
        run_machine(state.machines[i + 1], pick and pick.fluid or nil, dt)
    end

    -- THE MIXER. It eats the first N plasmas and makes one catalyst of them, which is what the
    -- whole scenario is for: gregtech's Transcendent Plasma Mixer, whose four recipes take 4, 8, 12
    -- and 16 of the sixteen plasmas and whose nesting is why scene.FLUIDS is in the order it is.
    --
    -- It runs whatever the highest-priority catalyst it CAN make is, which is the behaviour a real
    -- base would have with a filtered bus: it is not the thing being tested. What is being tested
    -- is whether the program keeps the right plasmas in front of it.
    run_mixers(scene, dt, sig[9])


    --[[ WHAT THE RIG TELLS THE COMPUTER, worked out LAST.
    --
    -- At the top of the tick these were a tick stale, and for the working signal that is the whole
    -- difference: a batch lifted this tick had not reached the hatches yet, so the rig still said
    -- idle and a program acting on it would lift straight over itself. A report belongs after the
    -- thing it reports on. ]]
    --[[ THE REACTOR'S OWN WORKING SIGNAL. On while it is part way through a cycle or while either
    hatch still holds anything - which is the same question asked two ways, since a hatch with
    something in it is a batch that is not finished. ]]
    do
        local busy = state.machines[1] and state.machines[1].making ~= nil
        for i = 1, 2 do
            local _, litres = feed_get(i)
            if litres > 0 then
                busy = true
            end
        end
        local n = rig.BUSY_LINE
        local blk = state.signals[math.floor((n - 1) / 4) + 1]
        if blk then
            blk.cell:rs_in_set(FACES[(n - 1) % 4 + 1], busy and 15 or 0)
        end
    end

    for i, cat in ipairs(scene.CATALYSTS or {}) do
        local n = rig.LIMIT_BASE + i
        local s = state.signals[math.floor((n - 1) / 4) + 1]
        if s then
            local held = state.tanks[cat.fluid]
            local full = held and held:fluid_get()[2] >= (scene.CATALYST_LIMIT or 500000000)
            s.cell:rs_in_set(FACES[(n - 1) % 4 + 1], full and 15 or 0)
        end
    end


    -- The board beside the bank: a lamp per pump, lit while its line is driving, and a sign under
    -- it saying what that pump is moving.
    rig.update_board(state.board, sig, blocks)

    -- THE CONTROL BLOCKS SAY WHAT THEY CARRY. Four identical lamps that mean "something here is
    -- live" tell you nothing about which something; each one now names its four lines and shows
    -- their values, and lights when any of them is driving.
    for i, s in ipairs(state.signals) do
        local any = false
        local label = {}
        for k = 1, 4 do
            local n = (i - 1) * 4 + k
            local v = sig[n]
            if v > 0 then
                any = true
            end
            label[#label + 1] = string.format("%d %s = %d", n, rig.LINE_NAME[n] or "spare", v)
        end
        s.lamp.state = any and blocks.STATE.ON or blocks.STATE.OFF
        blocks.u(s.lamp).text = table.concat(label, "\n")
    end
end

--[[ @brief One frame of the scenario, however much simulated time that is.
-- |
-- | Core: THE CLOCK IS WOUND BY SUBSTEPPING, not by handing the machines a bigger number. A slice
-- | of simulated time is split into steps of at most a twentieth of a second and each is run in
-- | turn, because the machines work in discrete cycles: a recipe that takes four tenths of a second
-- | would produce ONE output from a two second step instead of five, and the faster the clock ran
-- | the less the base would make. Speeding it up would quietly change the answer.
-- |
-- | The stall guard is on REAL time, before the multiplier. A frame that took two seconds because
-- | something else on the machine hogged the processor must not fast-forward the base - but a
-- | hundred times speed asked for on purpose must not be clamped away, which is what happened when
-- | one limit tried to do both jobs: at sixty frames a second it held the clock to about fifteen
-- | times however high the setting went.
-- |
-- | @param w      world
-- | @param scene  the scenario
-- | @param dt     number - real seconds since the last frame
-- | @param speed  number - how many simulated seconds to a real one
-- |
-- | @date 2026-09-18 ]]
function controller.update(w, scene, dt, speed)
    if not state.ready or not dt or dt <= 0 then
        return
    end

    if dt > 0.25 then
        dt = 0.25                   -- a stalled frame is not a reason to skip the base forward
    end

    local total = dt * (speed or 1)
    local STEP = 0.05
    local MOST = 400                -- and no more, so a high setting cannot stall the frame itself

    local steps = math.max(1, math.min(MOST, math.ceil(total / STEP)))
    local each = total / steps

    --[[ AND THE COMPUTERS MOVE WITH THE WORLD'S CLOCK. The author, 2026-09-18: "the two should
    run in sync independent of the speed of the world".
    --
    -- Core: THE CLOCK IS WHAT HAS TO BE SHARED. A program measuring a second now measures a second
    -- OF THE WORLD, so what it does stops changing with the speed slider - which is the whole of
    -- what was wrong before.
    --
    -- One step a frame, though, not one per world tick. The emulator's cost does rise with the
    -- world's speed, which is only proper since the computer is inside the world - but it rises on
    -- the frame that has to draw, and a wound-up clock then meant hundreds of machine steps before
    -- anything reached the screen. What that costs at speed is that the program samples the world
    -- less often than the world ticks, and the window's "reactor working" line is where it shows.
    -- @date 2026-09-18 ]]
    for _ = 1, steps do
        tick(w, scene, each)
    end
    machines.step_all(w, total)

    state.steps = steps
end

--[[ @brief The control blocks, for anything that needs to read the lines. @date 2026-09-18 ]]
function controller.signals()
    return state.signals
end

--[[ @brief How many substeps the last frame took, for the interface to show. @date 2026-09-18 ]]
function controller.steps()
    return state.steps or 0
end


--[[ @brief What the scenario is doing, on screen.
-- |
-- | The bank is a great many numbers and the machines are a few, so the window leads with the
-- | machines and lists only the fluids that are not empty - a wall of zeroes hides the one row
-- | that matters.
-- |
-- | @param scene  the scenario
-- | @date 2026-09-17 22:00
--]]
function controller.draw(scene)
    if not state.ready then
        return
    end

    vc.ImGui_Begin("scenario - " .. (scene.NAME or "scene"), 0)

    for _, line in ipairs(state.log) do
        vc.ImGui_Text(line)
    end
    vc.ImGui_Separator()

    for _, m in ipairs(state.machines) do
        local what
        if m.making then
            -- The reactor carries its own cycle length and width, because both depend on the
            -- recipe it happens to be running; the converters run one at a time.
            local seconds = m.seconds or (m.making.ticks / m.overclock) / 20.0
            what = string.format("%s  %3.0f%%", m.making.out,
                    math.min(100, m.progress / seconds * 100))
            if m.para and m.para > 1 then
                what = what .. string.format("  x%d parallel", m.para)
            end
        elseif m.starved then
            what = "waiting - " .. tostring(m.starved)
        else
            what = "idle"
        end
        vc.ImGui_Text(string.format("%-28s %s", m.name, what))
    end

    for i, m in ipairs(state.mixers) do
        local what
        if m.making then
            what = string.format("%3.0f%%", math.min(100, m.progress / 20.0 * 100))
        else
            what = "idle"
        end
        vc.ImGui_Text(string.format("%-28s %-8s made %s L",
                "mixer " .. i .. " " .. bank.display(m.catalyst.fluid), what, ui_commas(m.made)))
    end

    --[[ THE TRANSPOSERS, one row each. There are no "slots" any more - that was an earlier design
    where four of them held four whole batches, and the rows outlived it and said nothing.
    --
    -- What matters per transposer is exactly two things: what its C tank is holding, because that
    -- is the batch on its way to the reactor, and how full its own side tanks are, because that is
    -- what says whether the next batch can start. ]]
    for t = 1, (state.rig and #state.rig.groups or 0) do
        local g = state.rig.groups[t]
        local c = g.upper and g.upper:fluid_get() or {"", 0, ""}
        local ready = {}
        for k = 1, rig.PER_SIDE do
            local want = state.plan.tank[t] and state.plan.tank[t][k]
            local held = g.tanks[k] and g.tanks[k]:fluid_get() or {"", 0, ""}
            if want then
                local cap = g.tanks[k] and g.tanks[k]:fluid_capacity() or 1
                ready[#ready + 1] = string.format("%s %d%%", bank.display(want),
                        math.floor(held[2] / cap * 100 + 0.5))
            end
        end
        vc.ImGui_Text(string.format("T%d %s  %-26s %s", t, t <= #state.rig.groups / 2 and "A" or "B",
                c[1] == "" and "C empty" or string.format("C %s %s L", c[3], ui_commas(c[2])),
                table.concat(ready, ", ")))
    end

    vc.ImGui_Text(string.format("%-28s %.0f%% of the run", "reactor working",
            controller.duty() * 100))

    -- And the two hatches, which is where the pair actually meets the reactor.
    for i, side in ipairs({"left", "right"}) do
        local name, litres = feed_get(i)
        vc.ImGui_Text(string.format("%-28s %s", "reactor input " .. side,
                name == "" and "-" or string.format("%s %s L", name, ui_commas(litres))))
    end

    if state.collisions > 0 then
        vc.ImGui_Text(string.format("%-28s %d", "pump collisions", state.collisions))
    end

    vc.ImGui_Separator()
    local sig = controller.read_signals()
    local parts = {}
    for i = 1, 16 do
        parts[#parts + 1] = string.format("%2d", sig[i])
    end
    vc.ImGui_Text("control lines: " .. table.concat(parts, " "))

    vc.ImGui_Separator()
    vc.ImGui_Text("flow is litres a second: + fills the bank, - is what the base drinks")

    -- EVERY fluid, not only the ones with something in them. The author asked on 2026-09-17 to see
    -- the fluids in here, and a list that hides the empty ones is exactly the wrong shape for that:
    -- what you look at a bank to find out is usually which thing has run out.
    local cap = scene.BANK.cap_per_fluid
    local BAR = 168
    local STEP = 100

    -- NOT IN A SCROLLING CHILD. It was, briefly, to stop a tall window covering things - but a
    -- fixed-height pane cannot be dragged bigger, and the author wants to open the list right out
    -- and see the whole bank at once. The window is a window: resize it.
    vc.ImGui_PushItemSpacing({x = 4, y = 2})
    for i, f in ipairs(bank.FLUIDS) do
        local held = controller.bank_level(f)
        local full = (cap > 0) and (held / cap) or 0

        -- THE BAR FILLS THE NAME. The author asked for the level to read as the name filling up,
        -- so the bar is drawn behind the text rather than beside it: one glance says both what the
        -- fluid is and how much of it there is.
        local at = vc.ImGui_GetCursorScreenPos()
        vc.ImGui_AddRectFilled({x = at.x, y = at.y}, {x = at.x + BAR, y = at.y + 17},
                0xff1c1c1c, 2)
        if full > 0 then
            vc.ImGui_AddRectFilled({x = at.x, y = at.y},
                    {x = at.x + math.max(2, BAR * full), y = at.y + 17}, 0xff3f7fbf, 2)
        end
        vc.ImGui_AddRect({x = at.x, y = at.y}, {x = at.x + BAR, y = at.y + 17}, 0xff3a3a3a, 2, 1)
        vc.ImGui_AddText({x = at.x + 5, y = at.y + 1}, 0xffffffff, bank.display(f))
        vc.ImGui_Dummy({x = BAR, y = 17})

        -- The knob: down, a number you can type in, and up.
        vc.ImGui_SameLine(0, 6)
        if vc.ImGui_SmallButton("-##m" .. i) then
            state.flow[f] = (state.flow[f] or 0) - STEP
            state.buf[f] = string.format("%d", state.flow[f])
        end
        vc.ImGui_SameLine(0, 2)
        vc.ImGui_PushItemWidth(74)
        local typed = vc.ImGui_InputText("##f" .. i, state.buf[f] or "0", 16)
        vc.ImGui_PopItemWidth()
        if typed[1] then
            state.buf[f] = typed[2]
            state.flow[f] = tonumber(state.buf[f]) or 0
        end
        vc.ImGui_SameLine(0, 2)
        if vc.ImGui_SmallButton("+##p" .. i) then
            state.flow[f] = (state.flow[f] or 0) + STEP
            state.buf[f] = string.format("%d", state.flow[f])
        end

        vc.ImGui_SameLine(0, 8)
        vc.ImGui_Text(string.format("%15s L", ui_commas(held)))

        -- ONE COLUMN. It was two, to keep the window short - but the author asked on 2026-09-17
        -- for a single row per fluid so the whole thing can be narrow and pushed to the side of
        -- the screen, which is worth more than the height it saves.
    end
    vc.ImGui_PopItemSpacing()

    vc.ImGui_End()
end

return controller
