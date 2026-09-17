--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | THE PLUMBING. What the sixteen control lines are wired to, and the
-- | pumps they run.
-- |
-- |     rig.assign_tanks()  which fluid lives in which tank, derived
-- |     rig.find(w)         the transposers, tanks and signals, by shape
-- |     rig.lines(signals)  the sixteen line values, as the script set them
-- |     rig.run(...)        one slice of pumping
-- |
-- | Split out of controller.lua because it is a different kind of thing:
-- | the controller decides what the machines DO, this decides where the
-- | liquid goes.
-- |
-- | @date 2026-09-18 00:00
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local blocks = require("blocks")

local rig = {}

--[[ How fast a pump moves liquid, in litres a SECOND.
-- |
-- | Ten thousand litres a TICK, which is what the author's pumps do - corrected 2026-09-18: "btw
-- | melodic are 10kL/t not /s so 20 times faster". Twenty ticks to a second, so two hundred
-- | thousand here. It was written as ten thousand a second for a day and everything downstream was
-- | timed against that, which is why the number is spelt out rather than left as 200000.
-- |
-- | This is the difference between the pipe being the constraint and the reactor being it. At ten
-- | thousand a second the reactor ran at about half its parallel because the hatch could not be
-- | filled fast enough; at two hundred thousand it runs the full sixty-four and the pipe has room
-- | to spare. @date 2026-09-18 ]]
rig.PUMP_RATE = 10000 * 20

--[[ What a machine input holds: WHATEVER THE TANK IN THE MAP HOLDS, which is a Super Tank IV's
-- | 32,000,000 L.
-- |
-- | It was pinched to sixty-four thousand for a while on the reasoning that a hatch is a buffer
-- | rather than a store. That was invention - the author put those two tanks there and they are
-- | what they are: "It shouldn't be only 64k, leave it unbounded to 32k" / "32M, sorry". Nothing
-- | overrides them now, and the push is bounded by the tank's own capacity.
-- | @date 2026-09-18 ]]

--[[ THE EIGHT TRANSPOSERS, and what each one is.
-- |
-- | The author's layout, 2026-09-18, drawn out by hand:
-- |
-- |         A1        B1
-- |      A4 T1 A2  B4 T2 B2          C1 above T1, C2 above T2, ...
-- |         A3        B3
-- |         A5        B5
-- |      A8 T3 A6  B8 T4 B6
-- |         A7        B7
-- |
-- | with four more of the same behind them. Four transposers carry the A tanks and four carry the
-- | B tanks; every A tank's C pipes to the reactor's LEFT input and every B tank's C to the RIGHT.
-- |
-- | Core: A TANK IS A FLUID, FOR GOOD. The sixteen fluids the twelve runnable recipes need split
-- | exactly eight and eight (see rig.assign_tanks), so every input fluid gets a tank of its own and
-- | no tank ever has to be emptied to make room for another. That removes the whole class of
-- | collisions that a shared tank creates; what is left is only the question of which recipe holds
-- | which C tank, and there are eight of those for a queue four deep.
-- |
-- | WHY EIGHT AND NOT FOUR. Hanging a prepared recipe means holding its pair in a C pair, and a C
-- | tank belongs to one transposer - so N recipes hung at once needs N left-side C tanks and N
-- | right-side ones, which is 2N transposers. Four steps of lookahead therefore wants eight.
-- |
-- | Sides are numbered the way the drawing reads - north, east, south, west - which is 2, 5, 3, 4
-- | to the program inside the machine.
-- | @date 2026-09-18 ]]
rig.TRANSPOSERS = 8
rig.PER_SIDE = 4
rig.SLOT_SIDE = {2, 5, 3, 4}

--[[ @brief Splits the recipes' input fluids into an A half and a B half, one tank each.
-- |
-- | Core: THIS IS NOT A CHOICE, IT IS A TWO-COLOURING. Treat each recipe as an edge between its two
-- | input fluids. Every recipe must have one end in A and the other in B, which is exactly what a
-- | proper two-colouring of that graph is; the graph is a forest for this modpack, so each component
-- | colours in only one way up to a flip, and the flips are then picked to land on eight and eight.
-- |
-- | An odd cycle would make it impossible - two recipes would have to share a side - and that is
-- | reported rather than fudged, because the fudge is a tank that has to be flushed between recipes
-- | and that is the thing this layout exists to avoid.
-- |
-- | @param recipes  table - as vc.fusion_recipes gives them
-- | @param store    number - the reactor's EU store
-- | @param wanted   table - the outputs worth making
-- | @return table - {a = {fluid x8}, b = {fluid x8}, by_out = {[out] = {a_at, b_at, a, b, ...}}},
-- |                 and a list of complaints
-- | @date 2026-09-18 ]]
function rig.assign_tanks(recipes, store, wanted, batch_l)
    local complaints = {}

    -- The edges: one per runnable recipe, keeping the cheapest recipe for each output.
    local best = {}
    for _, e in ipairs(recipes) do
        local out, start_eu = e[5], tonumber(e[9])
        if wanted[out] and start_eu <= store then
            if not best[out] or start_eu < tonumber(best[out][9]) then
                best[out] = e
            end
        end
    end

    local edges = {}
    for out, e in pairs(best) do
        edges[#edges + 1] = {out = out, u = e[1], v = e[3],
                amt_u = tonumber(e[2]), amt_v = tonumber(e[4]), amt_out = tonumber(e[6])}
    end
    table.sort(edges, function(x, y) return x.out < y.out end)

    -- Neighbours, so the colouring can walk a component.
    local near = {}
    local function link(a, b)
        near[a] = near[a] or {}
        table.insert(near[a], b)
    end
    for _, e in ipairs(edges) do
        link(e.u, e.v)
        link(e.v, e.u)
    end

    -- Two-colour each component, breadth first, and keep the two halves of each one apart so the
    -- component can be flipped whole when the totals are balanced below.
    local colour, seen, parts = {}, {}, {}
    for _, e in ipairs(edges) do
        for _, root in ipairs({e.u, e.v}) do
            if not seen[root] then
                local zero, one = {root}, {}
                colour[root], seen[root] = 0, true
                local queue, at = {root}, 1
                while at <= #queue do
                    local v = queue[at]
                    at = at + 1
                    for _, n in ipairs(near[v] or {}) do
                        if not seen[n] then
                            seen[n] = true
                            colour[n] = 1 - colour[v]
                            table.insert(colour[n] == 0 and zero or one, n)
                            queue[#queue + 1] = n
                        elseif colour[n] == colour[v] then
                            complaints[#complaints + 1] = string.format(
                                    "%s and %s must share a side - the recipes make an odd cycle",
                                    v, n)
                        end
                    end
                end
                parts[#parts + 1] = {zero, one}
            end
        end
    end

    -- Pick a flip per component so the A half comes to exactly half the fluids. A plain walk that
    -- takes whichever half is smaller does NOT get there in general; this asks for the exact total.
    local want = 0
    for _, pr in ipairs(parts) do
        want = want + #pr[1] + #pr[2]
    end
    want = math.floor(want / 2)

    local reach = {[0] = {}}                        -- total -> the flips that make it
    for i, pr in ipairs(parts) do
        local nextr = {}
        for total, how in pairs(reach) do
            for _, flip in ipairs({false, true}) do
                local add = flip and #pr[2] or #pr[1]
                local t = total + add
                if not nextr[t] then
                    local copy = {}
                    for k, v in pairs(how) do copy[k] = v end
                    copy[i] = flip
                    nextr[t] = copy
                end
            end
        end
        reach = nextr
    end

    local chosen = reach[want]
    if not chosen then
        -- Nothing lands on the exact half; take the closest so the rig is still usable and say so.
        local nearest
        for total in pairs(reach) do
            if not nearest or math.abs(total - want) < math.abs(nearest - want) then
                nearest = total
            end
        end
        chosen = reach[nearest]
        complaints[#complaints + 1] = string.format(
                "the fluids split %d / %d, not evenly - a tank will have to be shared",
                nearest, want * 2 - nearest)
    end

    local side = {}
    for i, pr in ipairs(parts) do
        local a_half, b_half = pr[1], pr[2]
        if chosen[i] then
            a_half, b_half = pr[2], pr[1]
        end
        for _, f in ipairs(a_half) do side[f] = "a" end
        for _, f in ipairs(b_half) do side[f] = "b" end
    end

    --[[ How much of each fluid is worth keeping staged: two batches of the largest call any recipe
    makes on it.
    --
    -- Core: A STAGING TANK IS A BUFFER, NOT A STORE. Filling all 32,000,000 L of one is harmless
    -- for something bought in, and quietly awful for a fluid the base MAKES - plasma.helium is an
    -- input to boron as well as a product, so its tank swallowed eight batches of it before any
    -- reached the bank and it looked as though none was being made at all.
    --
    -- Two batches: one to hand and one being drawn on, which is all a batch-at-a-time rig can use.
    -- @date 2026-09-18 ]]
    local out = {a = {}, b = {}, by_out = {}, at = {}, tank = {}, hold = {}}
    for _, e in ipairs(edges) do
        for _, f in ipairs({e.u, e.v}) do
            if not out.at[f] then
                local half = side[f] == "a" and out.a or out.b
                half[#half + 1] = f
                out.at[f] = {side = side[f], index = #half}
            end
        end
    end

    --[[ ROUND ROBIN ACROSS THE TRANSPOSERS, NOT DOWN THEM.
    --
    -- Filling the first transposer's four faces before touching the second would put four of the
    -- seven A fluids on one block and leave two blocks empty - and two fluids on one transposer
    -- cannot be staged at the same time, because that transposer has one C tank. Spreading them
    -- means at most two fluids a transposer here, so almost any pair of recipes can be prepared
    -- side by side, which is the whole reason for having eight. ]]
    local half_n = rig.TRANSPOSERS / 2
    for t = 1, rig.TRANSPOSERS do
        out.tank[t] = {}
    end
    for _, e in ipairs({{"a", out.a, 0}, {"b", out.b, half_n}}) do
        for i, f in ipairs(e[2]) do
            local t = ((i - 1) % half_n) + 1 + e[3]
            local k = math.floor((i - 1) / half_n) + 1
            out.at[f].t, out.at[f].k = t, k
            out.tank[t][k] = f
        end
    end

    for _, e in ipairs(edges) do
        local a_f, b_f = e.u, e.v
        local a_amt, b_amt = e.amt_u, e.amt_v
        if side[e.u] == "b" then
            a_f, b_f, a_amt, b_amt = e.v, e.u, e.amt_v, e.amt_u
        end
        --[[ HOW MANY RUNS MAKE A BATCH. Whatever puts the hungrier input nearest the target, so
        the rig stages N times each input's own amount and both tanks run dry on the same cycle.
        At least one, so a recipe whose inputs are larger than the target still runs. ]]
        local runs = math.max(1, math.floor((batch_l or 500000) / math.max(a_amt, b_amt)))
        out.by_out[e.out] = {a = a_f, b = b_f, amt_a = a_amt, amt_b = b_amt,
                amt_out = e.amt_out, runs = runs,
                lift_a = runs * a_amt, lift_b = runs * b_amt, yield = runs * e.amt_out,
                a_t = out.at[a_f].t, a_k = out.at[a_f].k,
                b_t = out.at[b_f].t, b_k = out.at[b_f].k}
    end

    for _, r in pairs(out.by_out) do
        out.hold[r.a] = math.max(out.hold[r.a] or 0, r.lift_a * 2)
        out.hold[r.b] = math.max(out.hold[r.b] or 0, r.lift_b * 2)
    end

    for _, half in ipairs({{"A", out.a}, {"B", out.b}}) do
        if #half[2] > rig.TRANSPOSERS / 2 * rig.PER_SIDE then
            complaints[#complaints + 1] = string.format("%d %s fluids, only %d tanks",
                    #half[2], half[1], rig.TRANSPOSERS / 2 * rig.PER_SIDE)
        end
    end
    return out, complaints
end

--[[ EVERY PUMP IN THE SCENARIO, and which control turns it on.
-- |
-- | Core: the board. A sign and a lamp for each of these stands beside the bank, so what the
-- | program is doing is readable from across the room rather than only in a window. `on` answers
-- | whether the line driving that pump is live.
-- |
-- | Only what can be OFF is here. The fills and the C pushes are hardwired, and a lamp that never
-- | goes out says nothing.
-- |
-- | @date 2026-09-18 ]]
local function bit(v, n) return (math.floor(v / (2 ^ (n - 1))) % 2) == 1 end

--[[ What each of the sixteen lines is for, so the block carrying it can say so. Spare lines are
left unnamed rather than given a made-up purpose. @date 2026-09-18 ]]
rig.LINE_NAME = {
    [1] = "T1 lift", [2] = "T2 lift", [3] = "T3 lift", [4] = "T4 lift",
    [5] = "T5 lift", [6] = "T6 lift", [7] = "T7 lift", [8] = "T8 lift",
    [9] = "mixers", [10] = "MK-III one", [16] = "MK-III two",
    [11] = "c1 full", [12] = "c2 full", [13] = "c3 full", [14] = "c4 full",
    [15] = "reactor busy",
}

--[[ THE FOUR LINES THAT RUN THE OTHER WAY.
-- |
-- | Core: EVERYTHING ELSE ON THE RIG IS THE COMPUTER TALKING. These four are the rig answering, and
-- | they are the only fact the program is ever handed rather than having to infer - the author,
-- | 2026-09-18: "a redstone signal with the limit should be given to a redstone face (this time a
-- | face will be used entirely for a single on/off) ... it tels the computer if the catalist
-- | c1,c2,c3,c4 reached the 500M limit or not ... this would be reading from the bank".
-- |
-- | A whole face for one bit, deliberately. It is a comparator off a tank, which is what it would
-- | be in the game, and there is nothing else for that face to carry.
-- |
-- | The program cannot see the bank at all - nothing it owns is next to a bank tank - so without
-- | these it would have to guess from its own bookkeeping whether a catalyst was finished, and
-- | bookkeeping drifts. @date 2026-09-18 ]]
rig.LIMIT_BASE = 10

--[[ AND ONE MORE COMING BACK: the reactor is still working on what it was given.
-- |
-- | Core: AN EMPTY C TANK DOES NOT MEAN A FINISHED BATCH. The pumps move two hundred thousand
-- | litres a second and the reactor eats about twenty, so C hands the whole batch over to the input
-- | tank in a couple of seconds and then reads empty with the entire batch still to burn. A program
-- | that treats an empty C as "done" lifts the next pair straight into a tank that still has the
-- | last one in it, the push is refused because a tank holds one fluid, and the whole rig stops
-- | with a run's worth stranded. The author saw where it came to rest: "the inputs still get stuck
-- | at 125,125".
-- |
-- | This is a machine's working signal, which is what a redstone cover on the machine gives you in
-- | the game, and it is the only honest way for the program to know: it cannot see the hatches, and
-- | no amount of waiting a fixed time is right at every clock speed.
-- | @date 2026-09-18 ]]
rig.BUSY_LINE = 15

--[[ ONE FACE PER TRANSPOSER, AND IT SAYS ONE THING: LIFT THIS TANK.
-- |
-- | Core: THE FILLS NEED NO CONTROL AT ALL. The author, 2026-09-18: "simply map all on both A and B
-- | and then route them all directly to the imputs from C, so all can be nonstop on". Half of that
-- | is exactly right and it is the larger half - every tank holds one fluid for the life of the run
-- | and draws from one bank tank, and a full tank simply stops accepting, so all sixteen bank pumps
-- | are hardwired on and sixteen commands disappear.
-- |
-- | AND THE C TANKS NEED NO CONTROL EITHER, because the lift already is the control. The author,
-- | 2026-09-18: "can't we just have lift part be the one that sincronizes? I mean when starting a
-- | recipe, send A and B to their respective Cs and wait for the transfer to go to the output
-- | before scheduling another one ... there is no way to reverse them by mistake because A and B
-- | don't mix the C's".
-- |
-- | That is right, and it is why the eight C tanks pipe straight into the two hatches with nothing
-- | on a wire: if nothing is lifted into a C until its batch is wanted, then at most one A-side C
-- | and one B-side C is ever holding anything, and an empty C pushes nothing. The four A-side C
-- | tanks can only reach the left hatch and the four B-side ones the right, so the pair cannot come
-- | out the wrong way round however the program behaves.
-- |
-- | What is left is a face per transposer carrying 0 for idle, or 1 to 4 for "lift that side tank
-- | into my C". Eight of those, the mixers, the converters: TEN lines and three redstone blocks.
-- |
-- | The timing falls out of the geometry rather than being arranged. A lift empties its side tank,
-- | which starts refilling at once and takes a tankful at the pump's rate to do it; C drains into
-- | the hatch at the same rate. So the fluid is ready again exactly when its batch has finished.
-- | @date 2026-09-18 ]]
function rig.tank_of(v) return math.floor(v) end
function rig.lifting(v) local n = math.floor(v) return n >= 1 and n <= rig.PER_SIDE end

rig.PUMPS = {}

--[[ @brief Rebuilds the board's pump list once the tank assignment is known.
-- |
-- | The labels carry the fluid because a tank holds one for good - "deuterium -> A1" says more than
-- | "fill A1" ever could, and it never goes out of date.
-- | @date 2026-09-18 ]]
function rig.build_pumps(plan)
    rig.PUMPS = {}
    local half = rig.TRANSPOSERS / 2

    -- The fills are not on the board: they are always on, and a lamp that never goes out says
    -- nothing. What is worth watching is which tank each transposer is lifting.
    for t = 1, rig.TRANSPOSERS do
        local letter = t <= half and "A" or "B"
        rig.PUMPS[#rig.PUMPS + 1] = {
            label = string.format("T%d%s lift -> C%d", t, letter, t),
            on = function(g) return rig.lifting(g[t]) end,
        }
    end

    for _, e in ipairs({
        {label = "mixer crude",       on = function(g) return bit(g[9], 1) end},
        {label = "mixer resplendent", on = function(g) return bit(g[9], 2) end},
        {label = "mixer prosaic",     on = function(g) return bit(g[9], 3) end},
        {label = "mixer exotic",      on = function(g) return bit(g[9], 4) end},
        {label = "MK-III one",        on = function(g) return math.floor(g[10]) > 0 end},
        {label = "MK-III two",        on = function(g) return math.floor(g[16]) > 0 end},
    }) do
        rig.PUMPS[#rig.PUMPS + 1] = e
    end
    return rig.PUMPS
end

--[[ @brief Stands a sign and a lamp up for every pump, in a line beside the bank.
-- |
-- | Core: ALONGSIDE THE BANK, one column over, running the same way. The author asked for the row
-- | to sit parallel to the tanks so the two read together - what is being moved, and out of which
-- | tank.
-- |
-- | The lamp goes above its sign rather than beside it, so a glance down the row is a row of lights
-- | with a row of labels under it rather than the two interleaved.
-- |
-- | @param w    world
-- | @param row  table - the bank row, from bank.row
-- | @return table - the signs and lamps, in rig.PUMPS order
-- |
-- | @date 2026-09-18 ]]
function rig.build_board(w, row)
    local board = {}
    if not row then
        return board
    end

    -- EVERY SIGN GOES FIRST, wherever it is, and the lamp standing on it with it.
    --
    -- The board used to be placed and never cleared, so moving it left the old row standing in the
    -- world with nothing driving it - two rows of labels, one of them lying. Sweeping first means
    -- the board's position is decided in exactly one place and moving it is a one-line change, not
    -- a change plus a clean-up nobody remembers to do.
    local stale = {}
    for _, cell in ipairs(w:occupied()) do
        if cell.kind == blocks.KIND.SIGN then
            stale[#stale + 1] = cell:pos()
        end
    end
    for _, p in ipairs(stale) do
        local above = w:get(p[1], p[2] + 1, p[3])
        if above and above.kind == blocks.KIND.LAMP then
            w:clear(p[1], p[2] + 1, p[3])
        end
        w:clear(p[1], p[2], p[3])
    end

    -- One column over, at right angles to the way the row runs. It was moved two columns to the
    -- far side for a moment and moved back: the board belongs beside the tanks it describes.
    local px, pz = row.dz, -row.dx

    for i, pump in ipairs(rig.PUMPS) do
        local x = row.x + px + row.dx * (i - 1)
        local z = row.z + pz + row.dz * (i - 1)

        local sign = w:get(x, 0, z)
        if not sign or sign.kind ~= blocks.KIND.SIGN then
            w:clear(x, 0, z)
            sign = blocks.make_sign(pump.label)
            if not w:set(x, 0, z, sign) then
                sign = nil
            end
        end

        local lamp = w:get(x, 1, z)
        if not lamp or lamp.kind ~= blocks.KIND.LAMP then
            w:clear(x, 1, z)
            lamp = blocks.make_lamp()
            if not w:set(x, 1, z, lamp) then
                lamp = nil
            end
        end

        board[i] = {sign = sign, lamp = lamp, pump = pump}
    end
    return board
end

--[[ @brief Brings the board up to date: the lamps follow the lines.
-- |
-- | The signs never change any more. They used to, because a pump's fluid came off a mux line and
-- | the label had to say which; now a tank holds one fluid for the life of the run, so the sign is
-- | written once when the board is built and is right for ever.
-- |
-- | @date 2026-09-18 ]]
function rig.update_board(board, lines, blocks_mod)
    for _, e in ipairs(board) do
        if e.lamp then
            e.lamp.state = e.pump.on(lines) and blocks_mod.STATE.ON or blocks_mod.STATE.OFF
        end
    end
end

--[[ @brief Finds the plumbing in the map, by shape.
-- |
-- | Core: the rig is recognised, not written down. An entry transposer is one standing ABOVE the
-- | ground - the two at ground level are the author's spares and play no part - its entry tanks are
-- | the four beside it, and its upper tank is the one directly on top of it. The bank is the long
-- | row of quantum tanks, and a control block is a redstone block with a lamp on it.
-- |
-- | @param w  world
-- | @return table roles, table complaints
-- |
-- | @date 2026-09-18 00:00
--]]
function rig.find(w)
    local r = {groups = {}, signals = {}, bank = {}}
    local complaints = {}

    local transposers, lamps = {}, {}
    for _, cell in ipairs(w:occupied()) do
        local p = cell:pos()
        if cell.kind == blocks.KIND.TRANSPOSER and p[2] > 0 then
            transposers[#transposers + 1] = {cell = cell, pos = p}
        elseif cell.kind == blocks.KIND.REDSTONE then
            local above = w:get(p[1], p[2] + 1, p[3])
            if above and above.kind == blocks.KIND.LAMP then
                r.signals[#r.signals + 1] = {cell = cell, lamp = above, pos = p}
            end
        elseif cell.kind == blocks.KIND.QTANK then
            local lock = cell:fluid_lock_get()
            if lock[1] ~= "" then
                r.bank[lock[1]] = cell
            end
        end
    end

    --[[ THE REACTOR'S TWO INPUT HATCHES.
    --
    -- Core: THE ONES THAT BELONG TO NOTHING ELSE. A plain tank standing on the ground with no
    -- transposer beside it is not one of the staging tanks and is not the bank, which is quantum
    -- so it is one of the two the fluid is meant to arrive in. Found by what they are NOT, because
    -- there is nothing else for a loose ground tank in this scenario to be.
    --
    -- They were abstract until now: the controller kept the two inputs as a pair of numbers and the
    -- tanks the author had put in the map for them sat empty for ever. Which is a fair description
    -- of the bug - the simulation was right and the picture was not, and the picture is the thing
    -- somebody looks at. @date 2026-09-18 ]]
    local loose = {}
    for _, cell in ipairs(w:occupied()) do
        local p = cell:pos()
        if cell.kind == blocks.KIND.TANK and p[2] == 0 then
            local beside = false
            for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
                for _, dy in ipairs({0, -1, 1}) do
                    local n = w:get(p[1] + d[1], p[2] + dy, p[3] + d[2])
                    if n and n.kind == blocks.KIND.TRANSPOSER then
                        beside = true
                    end
                end
            end
            if not beside then
                loose[#loose + 1] = {cell = cell, pos = p}
            end
        end
    end
    table.sort(loose, function(a, b)
        if a.pos[3] ~= b.pos[3] then return a.pos[3] < b.pos[3] end
        return a.pos[1] < b.pos[1]
    end)
    r.hatches = {loose[1] and loose[1].cell, loose[2] and loose[2].cell}
    if not (r.hatches[1] and r.hatches[2]) then
        complaints[#complaints + 1] = string.format(
                "2 loose ground tanks for the reactor's inputs, found %d", #loose)
    end

    local function by_place(a, b)
        if a.pos[3] ~= b.pos[3] then return a.pos[3] < b.pos[3] end
        return a.pos[1] < b.pos[1]
    end
    table.sort(transposers, by_place)
    table.sort(r.signals, by_place)

    -- AND THEN BY ADDRESS, which is the only ordering the program inside the machine can also
    -- compute. It cannot see where a block is; all it has is component.list, so it sorts by
    -- address - and a scenario that numbered its lines by position put the program's line one on a
    -- different block from its own. Everything the program drove landed on lines nobody read.
    --
    -- Positions are still the tie-break, so a machine that has not been started yet - and so has no
    -- components to ask - still gets a stable order rather than an arbitrary one.
    r.order_by_address = false
    r.groups_by_address = false

    -- A group: the transposer, its four side tanks and the C tank above it. THE ORDER IS THE
    -- DRAWING'S - north, east, south, west - so tank 1 of a group is the A1 of the author's sketch
    -- and side 2, 5, 3, 4 to the program. Sorting them any other way would leave the scenario and
    -- the program numbering the same tank differently.
    local SIDE = {
        {{0, 0, -1}, blocks.FACE.ZNEG},
        {{1, 0, 0},  blocks.FACE.XPOS},
        {{0, 0, 1},  blocks.FACE.ZPOS},
        {{-1, 0, 0}, blocks.FACE.XNEG},
    }
    for _, t in ipairs(transposers) do
        local p = t.pos
        local g = {transposer = t.cell, pos = p, tanks = {}, faces = {}, upper = nil}
        for _, s in ipairs(SIDE) do
            local n = w:get(p[1] + s[1][1], p[2] + s[1][2], p[3] + s[1][3])
            if n and blocks.is_tank(n.kind) then
                g.tanks[#g.tanks + 1] = n
                g.faces[#g.faces + 1] = s[2]
            end
        end
        local up = w:get(p[1], p[2] + 1, p[3])
        if up and blocks.is_tank(up.kind) then
            g.upper = up
        end
        r.groups[#r.groups + 1] = g

        if #g.tanks ~= rig.PER_SIDE then
            complaints[#complaints + 1] = string.format(
                    "the transposer at %d, %d, %d has %d tanks around it, not 4",
                    p[1], p[2], p[3], #g.tanks)
        end
        if not g.upper then
            complaints[#complaints + 1] = string.format(
                    "the transposer at %d, %d, %d has no tank above it", p[1], p[2], p[3])
        end
    end

    if #r.groups ~= rig.TRANSPOSERS then
        complaints[#complaints + 1] = string.format("%d transposers above ground, found %d",
                rig.TRANSPOSERS, #r.groups)
    end
    if #r.signals ~= 4 then
        complaints[#complaints + 1] = string.format("4 redstone blocks with a lamp, found %d",
                #r.signals)
    end
    return r, complaints
end

--[[ @brief The sixteen line values, as the program under test left them.
-- |
-- | Four blocks, four faces each, in map order then west, east, north, south - which is the order
-- | `sides` numbers them in, so a program counting lines counts the same way this does.
-- |
-- | @param signals  table - from rig.find
-- | @return table - sixteen numbers, nought to fifteen
-- |
-- | @date 2026-09-18 00:00
--]]
local FACES = {blocks.FACE.XNEG, blocks.FACE.XPOS, blocks.FACE.ZNEG, blocks.FACE.ZPOS}

--[[ @brief Puts the control blocks in the order the program inside the machine sees them.
-- |
-- | Called once the machine is running, when its components have addresses to sort by. Until then
-- | the positional order stands, which is wrong but stable - and the lamps show it, so a mismatch
-- | is visible rather than silent.
-- |
-- | @param r        the rig, from rig.find
-- | @param machine  the case's machine
-- |
-- | @date 2026-09-18 ]]
function rig.sort_signals(r, machine)
    if not machine or r.order_by_address then
        return false
    end

    local addr = {}
    for _, s in ipairs(r.signals) do
        local a = vc.machine_component_at(machine, s.pos[1], s.pos[2], s.pos[3])
        if a == "" then
            return false                -- not every block is a component yet; try again later
        end
        addr[s] = a
    end

    table.sort(r.signals, function(a, b) return addr[a] < addr[b] end)
    r.order_by_address = true
    return true
end

--[[ @brief Puts the slots in the order the program inside the machine numbers them.
-- |
-- | Core: THE SAME TRAP THE REDSTONE BLOCKS FELL INTO. A program cannot see where a block is; all
-- | it has is component.list, so it numbers the transposers by address. A scenario that numbered
-- | its transposers by position would have the program lifting from one and the rig lifting from
-- | another - and every symptom of that appears somewhere else, in a C tank that never fills.
-- |
-- | @param r        the rig, from rig.find
-- | @param machine  the computer, for machine_component_at
-- | @return boolean - whether the order is settled
-- | @date 2026-09-18 ]]
function rig.sort_groups(r, machine)
    if not machine or r.groups_by_address then
        return false
    end

    local addr = {}
    for _, g in ipairs(r.groups) do
        local a = vc.machine_component_at(machine, g.pos[1], g.pos[2], g.pos[3])
        if a == "" then
            return false                -- not a component yet; try again next tick
        end
        addr[g] = a
    end

    table.sort(r.groups, function(a, b) return addr[a] < addr[b] end)
    r.groups_by_address = true
    return true
end

function rig.lines(signals)
    local out = {}
    for _, s in ipairs(signals) do
        for _, f in ipairs(FACES) do
            out[#out + 1] = s.cell:rs_get(f)
        end
    end
    while #out < 16 do
        out[#out + 1] = 0
    end
    return out
end

--[[ @brief The recipe whose two inputs are exactly the pair being lifted, or nil.
-- |
-- | Core: THE RIG KNOWS ITS OWN RECIPES. It has to, because the lift moves a BATCH rather than a
-- | tankful and a batch is N runs of a particular recipe - which pair is going up is what says how
-- | much. That is a property of how the rig was built, not a decision: the pumps between these
-- | tanks and these hatches were sized for these recipes.
-- |
-- | @param plan   the tank plan
-- | @param fluids table - the fluids being lifted this tick, by tank
-- | @return table | nil - the recipe entry
-- | @date 2026-09-18 ]]
function rig.pair_recipe(plan, fluids)
    local have = {}
    for _, f in pairs(fluids) do
        have[f] = true
    end
    for _, r in pairs(plan.by_out or plan.recipe or {}) do
        if have[r.a] and have[r.b] then
            return r
        end
    end
    return nil
end

--[[ @brief Moves liquid from one tank to another, at the pump's rate and no faster.
-- |
-- | THE RATE IS THE WHOLE POINT. Ten thousand litres a second is what stops the balancer being a
-- | matter of pressing everything at once: a recipe's worth of feedstock takes real time to stage,
-- | so the order things are pumped in is the question being asked.
-- |
-- | @return number - how much moved
-- | @date 2026-09-18 00:00
--]]
function rig.pump(from_cell, to_cell, fluid, label, dt, cap_override)
    if not from_cell or not to_cell or fluid == "" then
        return 0
    end
    local have = from_cell:fluid_get()
    if have[1] ~= fluid or have[2] <= 0 then
        return 0
    end

    local into = to_cell:fluid_get()
    if into[1] ~= "" and into[1] ~= fluid then
        return 0                            -- a tank holds one fluid; it will not mix
    end

    --[[ WHOLE LITRES ONLY.
    --
    -- Core: A LITRE IS AN INTEGER IN THE GAME and it has to be one here, because everything
    -- downstream divides by a recipe's input size. A tick's worth of pumping is `rate * dt` and dt
    -- is whatever is left of a frame, so without this a tank ends up holding 127.99999999 litres -
    -- which looks exactly like 128 in every display and floors to nothing when the reactor asks how
    -- many runs it can afford. It then starts a cycle of ZERO parallel, makes nothing, and reports
    -- itself busy for ever. The author found where it stops: "magnesium stuck at 128 128".
    --
    -- Rounding DOWN rather than up, so a pump can never invent a litre that was not in the tank it
    -- came from. @date 2026-09-18 ]]
    local cap = cap_override or to_cell:fluid_capacity()
    local room = cap - into[2]
    local want = rig.PUMP_RATE * dt
    local moved = math.floor(math.min(have[2], room, want))
    if moved < 1 then
        return 0
    end

    from_cell:fluid_set(fluid, have[2] - moved, have[3])
    to_cell:fluid_set(fluid, into[2] + moved, label or have[3])
    return moved
end

return rig
