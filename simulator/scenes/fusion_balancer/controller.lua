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

local controller = {}

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

    local roles = scene.discover(w)
    state.signals = roles.signals

    state.recipes = vc.fusion_recipes(mc_path or "")
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
    state.machines[1] = {name = scene.REACTOR.machine, store = scene.REACTOR.eu_store,
            overclock = scene.REACTOR.overclock, making = nil, progress = 0}
    for i, conv in ipairs(scene.CONVERTERS) do
        state.machines[i + 1] = {name = conv.machine, store = scene.CONVERTER_EU_STORE,
                overclock = scene.CONVERTER_OVERCLOCK, fixed = conv.fluid,
                making = nil, progress = 0}
    end

    for _, f in ipairs(bank.FLUIDS) do
        state.flow[f] = state.flow[f] or 0
        state.buf[f] = state.buf[f] or "0"
    end

    state.ready = true

    local log = {string.format("%d fusion recipes read from the mods", #state.recipes)}
    local runnable = 0
    for _, f in ipairs(bank.FLUIDS) do
        if controller.best_recipe(f, scene.REACTOR.eu_store) then
            runnable = runnable + 1
        end
    end
    log[#log + 1] = string.format("%s can make %d of the bank's fluids",
            scene.REACTOR.machine, runnable)
    log[#log + 1] = string.format("%d bank tanks, %d control blocks",
            #bank.FLUIDS, #state.signals)
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
        if controller.bank_level(r.in_a) < r.amt_a or controller.bank_level(r.in_b) < r.amt_b then
            m.starved = true
            return
        end
        bank_take(r.in_a, r.amt_a)
        bank_take(r.in_b, r.amt_b)
        m.making = r
        m.progress = 0
        m.starved = false
    end

    local seconds = (m.making.ticks / m.overclock) / 20.0
    m.progress = m.progress + dt
    if m.progress >= seconds then
        bank_add(m.making.out, m.making.amt_out)
        m.progress = 0
        m.making = nil
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
function controller.update(w, scene, dt)
    if not state.ready or dt <= 0 then
        return
    end
    if dt > 0.25 then
        dt = 0.25                   -- a stalled frame must not fast-forward the whole base
    end

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

    local sig = controller.read_signals()

    -- Line one, read as a selector: which of the bank's fluids the compact fusion should make.
    -- Nought idles it. The balancer spends this line deciding what the reactor is for right now.
    local pick = sig[1]
    local want = (pick >= 1 and pick <= #bank.FLUIDS) and bank.FLUIDS[pick] or nil
    run_machine(state.machines[1], want, dt)

    -- Line two, read as four switches: the standalone reactors, one bit each. They make what they
    -- make - the compact fusion cannot hold their recipes - so a bit only says whether to run.
    local bits = sig[2]
    for i, conv in ipairs(scene.CONVERTERS) do
        local on = (bits % (2 ^ i)) >= (2 ^ (i - 1))
        run_machine(state.machines[i + 1], on and conv.fluid or nil, dt)
    end

    -- The lamps follow the lines, so the map shows what the program is asking for without anybody
    -- having to open a window.
    for i, s in ipairs(state.signals) do
        local any = false
        for k = 1, 4 do
            if sig[(i - 1) * 4 + k] > 0 then
                any = true
            end
        end
        s.lamp.state = any and blocks.STATE.ON or blocks.STATE.OFF
    end
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
            local seconds = (m.making.ticks / m.overclock) / 20.0
            what = string.format("%s  %3.0f%%", m.making.out,
                    math.min(100, m.progress / seconds * 100))
        elseif m.starved then
            what = "waiting - the bank is short"
        else
            what = "idle"
        end
        vc.ImGui_Text(string.format("%-28s %s", m.name, what))
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
