--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | THE PROGRAM UNDER TEST. Not part of the simulator: this is
-- | OpenComputers Lua, it runs on the computer in the map, and the
-- | scenario copies it onto that computer's disk as /home/balancer.lua
-- | every time it loads.
-- |
-- | The job. One reactor, sixteen plasmas to keep up, four catalysts
-- | that want more of them the further down the list you go. The reactor
-- | is not commanded - it runs whatever pair of fluids is in front of it
-- | - so the work is deciding what to put in front of it, and when.
-- |
-- | THE RIG DOES ALMOST ALL OF IT. Every input fluid has a tank of its
-- | own, filled from the bank by a pump that is always on; every C tank
-- | drains straight into its side of the reactor. The only thing on a
-- | wire is the lift, and the lift is the whole synchronisation:
-- |
-- |     lift A and B -> their C tanks -> the reactor burns the pair
-- |
-- | Nothing else can be in a C tank while that happens, because nothing
-- | else was lifted. And a lifted tank starts refilling at once, taking
-- | exactly as long as the C takes to drain, so the same fluid is ready
-- | again the moment its batch finishes.
-- |
-- | What it CANNOT do: see the bank. Nothing it owns is next to a bank
-- | tank, so what it knows about stock is what it believes it has made.
-- |
-- |     balancer          run it
-- |     balancer once     one decision, printed, then stop
-- |
-- | @date 2026-09-18 06:00
-- | ===============================================================================================
--]]

local component = require("component")
local sides = require("sides")
local event = require("event")

--[[ The sixteen plasmas, in the order the mixer's recipes build on them: the first four make the
crude catalyst, the first eight the prosaic, and so on. @date 2026-09-18 ]]
local PLASMA = {
    "plasma.helium", "plasma.iron", "plasma.calcium", "plasma.niobium",
    "plasma.radon", "plasma.nickel", "plasma.boron", "plasma.sulfur",
    "plasma.nitrogen", "plasma.zinc", "plasma.silver", "plasma.titanium",
    "plasma.americium", "plasma.bismuth", "plasma.oxygen", "plasma.tin",
}

local IS_PLASMA = {}
for i, p in ipairs(PLASMA) do
    IS_PLASMA[p] = i
end

--[[ The catalysts, most important first. `needs` is how many of PLASMA each takes, counting from
the first. REWRITE THIS TABLE AND THE PROGRAM FOLLOWS IT - nothing below assumes which is which,
because the author said the order is meant to change. @date 2026-09-18 ]]
local CATALYST = {
    {name = "crude",       needs = 4},
    {name = "resplendent", needs = 12},
    {name = "prosaic",     needs = 8},
    {name = "exotic",      needs = 16},
}

--[[ WHICH PLASMAS THE TWO STANDALONE REACTORS CAN MAKE. Read from the plan, not written here:
-- | it is every plasma whose recipe is past the compact fusion's store but inside a MK-III's, which
-- | is six of the sixteen and is not a thing this program could work out for itself.
-- |
-- | It was a hardcoded pair - americium and radon - while those were believed to be the only two out
-- | of reach. Iron, nickel, silver and bismuth are as well, and every catalyst needs at least one of
-- | them, so with the pair pinned nothing could ever be finished. @date 2026-09-18 ]]
local function conv_index(plan, p)
    for i, c in ipairs(plan.conv or {}) do
        if c.fluid == p then
            return i
        end
    end
    return nil
end

--[[ WHEN A PLASMA COUNTS AS DONE. The author, 2026-09-18: "if that plasma or catalist didn't reach
500M already". The bank tanks hold 512,000,000 L, so this is as full as one sensibly gets. ]]
local TARGET = 500000000

--[[ How long a tank may sit at the same level before its fluid is called missing, in seconds.
-- |
-- | With the fills hardwired on, a tank that is neither full nor rising can only mean the bank has
-- | run out of what feeds it. There is no other reading left, which is one of the quieter benefits
-- | of taking the fill pumps off the wire. @date 2026-09-18 ]]
local STALL = 10

--[[ And how long to leave that recipe alone afterwards. Long enough not to ask again every poll,
short enough that a shortage which clears is noticed. @date 2026-09-18 ]]
local COOLDOWN = 300

--[[ The lines. Eight lifts, then the mixers and the two standalone reactors - ten of the sixteen,
and three redstone blocks rather than four. @date 2026-09-18 ]]
local LIFT_BASE = 0
local L = {MIXERS = 9}
local FACE = {sides.west, sides.east, sides.north, sides.south}

--[[ THE ONLY LINES THAT COME THE OTHER WAY. Four faces, one bit each: catalyst n has reached its
500,000,000 L limit. A comparator on a bank tank, read with getInput rather than getOutput.

This is the only fact the program is ever handed. Everything else it works with is its own
bookkeeping, and bookkeeping drifts - but whether a catalyst is FINISHED must not be a guess, or it
either stops early or never moves on to the next one at all. @date 2026-09-18 ]]
local LIMIT_BASE = 10

--[[ AND ONE MORE: the reactor is still working on the last pair.
-- |
-- | Core: AN EMPTY C TANK IS NOT A FINISHED BATCH. C drains into the hatch ten times faster than
-- | the reactor eats out of it, so C runs dry with a hatchful still to go. Lifting the next pair at
-- | that moment pushes it into a hatch that still holds the last one, the hatch refuses it - it
-- | holds one fluid - and everything stops. The author, 2026-09-18: "the inputs still get stuck at
-- | 125,125", which is one run's worth of helium left over.
-- |
-- | Waiting a fixed time instead would be wrong at every clock speed but one. @date 2026-09-18 ]]
local BUSY_LINE = 15

--[[ Sides 2, 5, 3, 4 are north, east, south and west - the order the author's drawing reads - and
side 1 is straight up, which is the C tank. @date 2026-09-18 ]]
local SIDE = {2, 5, 3, 4}

--[[ @brief Finds the rig by asking the components what is there.
-- |
-- | Addresses change every time a world is built, so nothing is written down: the blocks are
-- | whatever answers to "redstone" and "transposer", sorted by address. The scenario sorts its own
-- | the same way, which is the only ordering both halves can compute - a program cannot see where
-- | a block is, and a scenario that numbered by position once had the program driving lines nobody
-- | was reading.
-- | @date 2026-09-18 ]]
local function find_rig()
    local rig = {redstone = {}, transposers = {}}
    for address in component.list("redstone") do
        rig.redstone[#rig.redstone + 1] = component.proxy(address)
    end
    table.sort(rig.redstone, function(a, b) return a.address < b.address end)
    if #rig.redstone < 3 then
        return nil, "fewer than three redstone blocks - not enough lines to drive anything"
    end

    for address in component.list("transposer") do
        rig.transposers[#rig.transposers + 1] = component.proxy(address)
    end
    table.sort(rig.transposers, function(a, b) return a.address < b.address end)
    if #rig.transposers < 8 then
        return nil, "fewer than eight transposers - the rig is not built"
    end
    return rig
end

--[[ @brief Reads the plan the scenario left on the disk.
-- |
-- | Core: THE PROGRAM IS TOLD WHICH TANK HOLDS WHAT. Working it out would mean reading the mods'
-- | recipes, which a program inside the machine cannot do. Every earlier version carried its own
-- | copy of the ordering, and the two drifted apart the first time the derivation changed.
-- | @date 2026-09-18 ]]
local function read_plan()
    local f = loadfile("/home/plan.lua")
    if not f then
        return nil, "no /home/plan.lua - the scenario did not leave one"
    end
    local ok, plan = pcall(f)
    if not ok or type(plan) ~= "table" or not plan.tank then
        return nil, "plan.lua would not load"
    end
    return plan
end

--[[ @brief Puts a value on one of the sixteen lines. @date 2026-09-18 ]]
local function set_line(rig, n, value)
    local block = rig.redstone[math.floor((n - 1) / 4) + 1]
    if block then
        block.setOutput(FACE[(n - 1) % 4 + 1], value)
    end
end

--[[ @brief Reads a line the rig drives into us. @date 2026-09-18 ]]
local function get_line(rig, n)
    local block = rig.redstone[math.floor((n - 1) / 4) + 1]
    if not block then
        return 0
    end
    local ok, v = pcall(block.getInput, FACE[(n - 1) % 4 + 1])
    return (ok and v) or 0
end

--[[ @brief Which catalysts the bank says are finished. @date 2026-09-18 ]]
local function limits(rig)
    local done = {}
    for n = 1, #CATALYST do
        done[n] = get_line(rig, LIMIT_BASE + n) > 0
    end
    return done
end

--[[ @brief What a transposer's four side tanks and its C tank hold. @date 2026-09-18 ]]
local function read_transposer(rig, t)
    local tp = rig.transposers[t]
    local out = {tank = {}, c = {name = "", amount = 0}}
    if not tp then
        return out
    end
    local function look(side)
        local ok, info = pcall(tp.getFluidInTank, side)
        if ok and info and info.name then
            return {name = info.name, amount = info.amount or 0}
        end
        return {name = "", amount = 0}
    end
    for k = 1, 4 do
        out.tank[k] = look(SIDE[k])
    end
    out.c = look(1)
    return out
end

--[[ @brief How many litres of `f` one batch of `p` eats.
-- |
-- | A batch is N runs, and the rig stages N times each input's own amount - so the two run out
-- | together whatever the recipe's proportions are, and nothing is left that cannot be used.
-- | @date 2026-09-18 ]]
local function eats(plan, p, f)
    local r = plan.recipe[p]
    if not r then
        return 0
    end
    if r.a == f then return r.lift_a end
    if r.b == f then return r.lift_b end
    return 0
end

--[[ @brief How much plasma one batch of `p` gives back. @date 2026-09-18 ]]
local function yields(plan, p)
    local r = plan.recipe[p]
    return r and r.yield or 0
end

--[[ @brief Everything in a wanted plasma's tree that could be started right now, with its depth.
-- |
-- | Core: A NODE IS CRAFTABLE WHEN ITS CHILDREN ARE READY, and the ones that are not send you
-- | further down. Some plasmas are made out of other plasmas - boron wants helium plasma, and
-- | oxygen's dearer recipe wants boron - so asking for the one at the top is asking for nothing
-- | unless what it stands on is there.
-- |
-- | Depth is counted from the catalyst: its own needs are level one, what those are made of is
-- | level two. They are COLLECTED rather than chosen between here, because the choice is made on
-- | depth first and stock second, and that comparison has to see them all at once.
-- |
-- | @param depth  number - how far below the catalyst `p` sits
-- | @param out    table - candidates are appended as {p = name, depth = n}
-- | @param at     table - the shallowest depth each node has been reached at
-- | @date 2026-09-18 ]]
local function gather(plan, p, img, depth, out, at, blocked)
    local r = plan.recipe[p]
    if not r or depth > 8 then
        return                      -- this reactor cannot make it at all
    end
    -- A node reached twice by different routes counts at its SHALLOWEST, because that is how near
    -- to the result making it actually gets you.
    if at[p] and at[p] <= depth then
        return
    end
    at[p] = depth

    local ready = true
    for _, f in ipairs({r.a, r.b}) do
        if IS_PLASMA[f] and (img[f] or 0) < eats(plan, p, f) then
            ready = false
            gather(plan, f, img, depth + 1, out, at, blocked)
        end
    end
    if ready and not blocked(p) then
        out[#out + 1] = {p = p, depth = depth}
    end
end

--[[ @brief Can this catalyst ever be finished at all?
-- |
-- | Core: A CATALYST THAT CANNOT BE COMPLETED MUST NOT HOLD THE REACTOR. Precedence says work on
-- | the first catalyst until it is done - which is right, and which never ends if one of the things
-- | it needs has no source anywhere in the base. The program then cycles that catalyst's few
-- | makeable plasmas for ever and everything below it starves. The author, 2026-09-18: "stuck
-- | building either calcium plasma or niobium plasma, never goes to the next recipe element".
-- |
-- | A need counts as obtainable if this reactor has a recipe for it, or one of the standalone
-- | reactors makes it, or there is already a target's worth of it. Anything else - iron, nickel,
-- | silver and bismuth plasma in this base - is a wall, and a catalyst behind one is skipped rather
-- | than worked at for ever.
-- |
-- | @date 2026-09-18 ]]
local function reachable(plan, cat, img)
    for i = 1, cat.needs do
        local p = PLASMA[i]
        if not (plan.recipe[p] or conv_index(plan, p) or (img[p] or 0) >= TARGET) then
            return false, p
        end
    end
    return true
end

--[[ @brief What to make next, given what we believe we have.
-- |
-- | Core: THE HIGHEST LEVEL YOU CAN CRAFT, AND THE SMALLEST OF THOSE. The author's rule,
-- | 2026-09-18: "the rule is to build the one on the highest level that you can craft (on the path
-- | to the priority target catalyst) and the smalest in size, such that the same level get
-- | equilibrated".
-- |
-- | Two keys, and the order between them is the whole of it:
-- |
-- |   - DEPTH FIRST, shallowest wins. A node one step from the catalyst gets you nearer the result
-- |     than one three steps down, so the moment a node's children are ready it is worth more than
-- |     anything beneath it. Going deeper than you must is work that does not advance the goal.
-- |   - THEN SIZE, smallest wins, which is what equilibrates a level. A catalyst needs ALL of its
-- |     plasmas, so taking the one furthest behind brings them up together. Taking the first on the
-- |     list instead stocks one to the brim while the rest sit at nothing - the slowest possible
-- |     route to a catalyst, and what this did at first: "plasma helium reached 128M while others
-- |     where stil stoped".
-- |
-- | Size before depth would be wrong the other way about: it would chase whatever happened to be
-- | lowest anywhere in the tree, including things several levels down that nothing is waiting on.
-- |
-- | @param blocked  function - says whether a plasma cannot be started right now
-- | @param done     table - per catalyst, what the bank's own limit signal says
-- | @param note     function | nil - told once about a catalyst that can never be finished
-- | @return string | nil, string - what to make, and why
-- | @date 2026-09-18 ]]
local function choose(plan, img, blocked, done, note)
    for n, cat in ipairs(CATALYST) do
        -- THE BANK SAYS SO, NOT US. A catalyst at its limit is finished with; move to the next one
        -- down the precedence list rather than going on stocking what it needed.
        local can, wall = reachable(plan, cat, img)
        if not can and note then
            note(n, string.format("%s can never be made here - nothing makes %s", cat.name, wall))
        end

        if not done[n] and can then
            local out, at = {}, {}
            for i = 1, cat.needs do
                local p = PLASMA[i]
                if (img[p] or 0) < TARGET then
                    gather(plan, p, img, 1, out, at, blocked)
                end
            end

            local pick
            for _, c in ipairs(out) do
                if not pick or c.depth < pick.depth
                        or (c.depth == pick.depth and (img[c.p] or 0) < (img[pick.p] or 0)) then
                    pick = c
                end
            end
            if pick then
                return pick.p, string.format("%s: level %d, least stocked at %d L",
                        cat.name, pick.depth, img[pick.p] or 0)
            end
        end
    end

    -- Every catalyst is supplied or walled off. Keep the lowest topped up so the reactor is never
    -- idle while there is room for anything.
    local low, low_at = math.huge, nil
    for _, p in ipairs(PLASMA) do
        if plan.recipe[p] and (img[p] or 0) < low and not blocked(p) then
            low, low_at = img[p] or 0, p
        end
    end
    if not low_at then
        return nil, "nothing that can be made is ready to start"
    end
    return low_at, "no catalyst to work towards - topping up " .. low_at
end

--[[ @brief Which mixers may run, as one bit each.
-- |
-- | They all drink from the same sixteen plasmas, so letting every one that could run run would let
-- | the exotic catalyst - which needs all sixteen - empty the tanks the crude one lives on. The
-- | floor therefore rises down the priority list: a quarter of the target per step, so the last one
-- | has to leave three quarters of a tank of everything behind it.
-- | @date 2026-09-18 ]]
local function mixer_bits(img, done)
    local bits = 0
    for n, cat in ipairs(CATALYST) do
        local floor_at = math.max(1000, (n - 1) * (TARGET / 4))
        local ok = not done[n]                  -- a full catalyst tank wants no more made
        for i = 1, cat.needs do
            if not ok or (img[PLASMA[i]] or 0) < floor_at then
                ok = false
                break
            end
        end
        if ok then
            bits = bits + 2 ^ (n - 1)
        end
    end
    return bits
end

--[[ @brief One turn: watch the batch in flight, and start the next when the C tanks are clear.
-- |
-- | Core: THE LIFT IS THE WHOLE SYNCHRONISATION. The author, 2026-09-18: "when starting a recipe,
-- | send A and B to their respective Cs and wait for the transfer to go to the output before
-- | scheduling another one, this way the fluids wait after the compact fusion to consume the pairs
-- | and there is no way to reverse them by mistake because A and B don't mix the C's".
-- |
-- | So there is no push to command and no queue to keep. A batch is:
-- |
-- |     both side tanks full   ->   lift them   ->   wait for both C tanks to empty
-- |
-- | and nothing else can be in a C while that runs, because nothing else was lifted. The pair
-- | cannot be got the wrong way round either: an A tank's C only reaches the left hatch.
-- |
-- | @param now  number - seconds, for the stall clock
-- | @return string | nil - something worth printing
-- | @date 2026-09-18 ]]
local function step(rig, plan, st, now)
    local done = limits(rig)
    local seen = {}
    for t = 1, plan.transposers do
        seen[t] = read_transposer(rig, t)
    end

    -- Every message, not the last one: a turn can finish a batch and start the next, and the
    -- finish is the half worth reading.
    local said = {}
    local function say(fmt, ...)
        said[#said + 1] = string.format(fmt, ...)
    end

    --[[ IS THE RIG DOING ANYTHING? That is the only question this program can reliably ask.
    --
    -- Core: WATCH LEVELS, NEVER TRANSIENTS. There was a state machine here - lifting, then burning,
    -- then done - and it deadlocked the moment the scenario's clock was wound up, because a whole
    -- batch now happens between two of this program's polls. It never saw the lift land, so it
    -- never moved on; the rig meanwhile honoured the line it was still holding and poured batch
    -- after batch into the reactor. The author saw the end of that: "now it's stuck on 0L?".
    --
    -- A level survives any clock speed. The machine is working or it is not; a C tank holds
    -- something or it does not. Nothing in between has to be caught. @date 2026-09-18 ]]
    local busy = get_line(rig, BUSY_LINE) > 0
    local c_clear = true
    for t = 1, plan.transposers do
        if seen[t].c.name ~= "" then
            c_clear = false
        end
    end
    local idle = not busy and c_clear

    -- ---------------------------------------------------------------- the batch that was running
    if st.job and idle then
        --[[ NOTHING IS IN A C TANK AND THE MACHINE IS IDLE, so what was last asked for has been
        made. Credit the image - the only way this program ever learns anything about the bank.
        --
        -- This believes a batch it did not watch. The alternative is to watch for something, and
        -- there is nothing to watch that lasts longer than a poll. It is checked against the one
        -- fact the rig does report: the catalyst limits come off the tanks themselves, so a drifted
        -- image cannot make the program stop early or run on. ]]
        local r = st.job.r
        st.img[st.job.out] = (st.img[st.job.out] or 0) + yields(plan, st.job.out)
        for _, f in ipairs({r.a, r.b}) do
            if IS_PLASMA[f] then
                st.img[f] = math.max(0, (st.img[f] or 0) - eats(plan, st.job.out, f))
            end
        end
        say("%s made - %d L believed in the bank", st.job.out, st.img[st.job.out])
        st.job = nil
    end

    -- ---------------------------------------------------------------- and start the next one
    if not st.job and idle then
        --[[ A recipe can start when both its tanks hold a batch's worth of their own input. They
        are not emptied by a lift any more - a batch is a fraction of a tankful - so in the steady
        state everything is ready and the choice is purely about what is most needed. ]]
        local function blocked(p)
            local r = plan.recipe[p]
            if not r then
                return true
            end
            if (st.cooldown[p] or 0) > now then
                return true
            end
            if seen[r.a_t].c.name ~= "" or seen[r.b_t].c.name ~= "" then
                return true                 -- its C tank still has the last batch in it
            end
            -- A BATCH'S WORTH, NOT A TANKFUL. The tank goes on filling behind the lift; what has
            -- to be there is what this batch will take.
            return seen[r.a_t].tank[r.a_k].amount < r.lift_a
                    or seen[r.b_t].tank[r.b_k].amount < r.lift_b
        end

        --[[ Said once per catalyst, not once per turn: a wall is a standing fact about the base,
        and repeating it every twentieth of a second would bury everything else. ]]
        st.said_wall = st.said_wall or {}
        local function note(n, text)
            if not st.said_wall[n] then
                st.said_wall[n] = true
                say("%s", text)
            end
        end

        local want, why = choose(plan, st.img, blocked, done, note)
        if want then
            local r = plan.recipe[want]
            st.job = {out = want, r = r, since = now}
            say("%s starting (%s)", want, why)
        else
            --[[ NOTHING IS READY, AND THAT MIGHT MEAN A SHORTAGE. With the fills always on, a tank
            that is not full and not rising can only be short at the bank. Watch the total and, if
            it has not moved in STALL seconds, put the recipe that was waiting on it aside for a
            while so the next one down the list gets a turn. ]]
            local total = 0
            for t = 1, plan.transposers do
                for k = 1, 4 do
                    total = total + seen[t].tank[k].amount
                end
            end
            if total > (st.level or -1) then
                st.level, st.since = total, now
            elseif now - (st.since or now) > STALL then
                for n, cat in ipairs(CATALYST) do
                    for i = 1, (done[n] and 0 or cat.needs) do
                        local p = PLASMA[i]
                        local r = plan.recipe[p]
                        if r and (st.cooldown[p] or 0) <= now and (st.img[p] or 0) < TARGET then
                            st.cooldown[p] = now + COOLDOWN
                            say("%s set aside - the bank is short of %s or %s", p, r.a, r.b)
                            break
                        end
                    end
                    if said then
                        break
                    end
                end
                st.since = now
            end
        end
    end

    -- ---------------------------------------------------------------- and put it on the wires
    --[[ THE LIFT IS A PULSE, held for exactly one turn. The rig latches the request and keeps
    trying until it lands, so there is nothing to gain by leaving the wire high - and leaving it
    high is what deadlocked it: two jobs in a row wanting the same tank never put a nought between
    them, and a rig watching for a change never saw one. ]]
    local lift = {}
    if st.job and not st.job.commanded then
        lift[st.job.r.a_t] = st.job.r.a_k
        lift[st.job.r.b_t] = st.job.r.b_k
        st.job.commanded = true
    end
    for t = 1, plan.transposers do
        set_line(rig, LIFT_BASE + t, lift[t] or 0)
    end

    set_line(rig, L.MIXERS, mixer_bits(st.img, done))

    --[[ THE TWO STANDALONE REACTORS, scheduled by the same rule as everything else.
    --
    -- Six plasmas need them and there are two machines, so what each makes is a decision. Taken by
    -- precedence and then by stock, like the compact fusion's: the first catalyst still wanting one
    -- of the six gets them, least stocked first, which equilibrates them the same way.
    --
    -- Their output is credited by ESTIMATE, at the rate the plan carries, because nothing here can
    -- see the bank and these machines have no tanks the program can read. It is the one piece of
    -- pure bookkeeping in the program, and the catalyst limit lines are what stop it mattering:
    -- when the bank says a catalyst is done, it is done, whatever this believed. ]]
    local want = {}
    for n, cat in ipairs(CATALYST) do
        if not done[n] then
            for i = 1, cat.needs do
                local p = PLASMA[i]
                if conv_index(plan, p) and (st.img[p] or 0) < TARGET then
                    local seen = false
                    for _, q in ipairs(want) do
                        seen = seen or q == p
                    end
                    if not seen then
                        want[#want + 1] = p
                    end
                end
            end
        end
    end
    table.sort(want, function(a, b) return (st.img[a] or 0) < (st.img[b] or 0) end)

    for i = 1, #(plan.conv_lines or {}) do
        local p = want[i]
        set_line(rig, plan.conv_lines[i], p and conv_index(plan, p) or 0)
        if p then
            -- What it will have made since the last look, which is how this program learns that
            -- anything happened at all out there.
            local c = plan.conv[conv_index(plan, p)]
            st.img[p] = (st.img[p] or 0) + c.rate * math.max(0, now - (st.conv_at or now))
        end
    end
    st.conv_at = now

    return said
end

local function main(args)
    local rig, err = find_rig()
    if not rig then
        print("balancer: " .. err)
        return 1
    end
    local plan, perr = read_plan()
    if not plan then
        print("balancer: " .. perr)
        return 1
    end

    local st = {img = {}, job = nil, cooldown = {}}
    for _, p in ipairs(PLASMA) do
        st.img[p] = 0
    end

    if args[1] == "once" then
        for _, line in ipairs(step(rig, plan, st, os.clock())) do
            print(line)
        end
        for t = 1, plan.transposers do
            local r = read_transposer(rig, t)
            local row = {}
            for k = 1, 4 do
                row[#row + 1] = string.format("%s %d",
                        r.tank[k].name ~= "" and r.tank[k].name or "-", r.tank[k].amount)
            end
            print(string.format("T%d  C=%s %d  |  %s", t,
                    r.c.name ~= "" and r.c.name or "-", r.c.amount, table.concat(row, ", ")))
        end
        return 0
    end

    print("balancer running - q to stop")
    while true do
        for _, line in ipairs(step(rig, plan, st, os.clock())) do
            print(line)
        end

        --[[ A TICK, not half a second. The rig cannot start anything this program has not asked
        for, so every moment between looks is a moment the reactor may be standing finished - and
        the scenario's clock can run hundreds of times faster than this loop does, which turns a
        lazy poll into minutes of idle plant. A twentieth of a second is one Minecraft tick, which
        is as often as anything in the world can change anyway. ]]
        local e, _, ch = event.pull(0.05, "key_down")
        if e and ch == 113 then             -- q
            break
        end
    end

    for n = 1, L.CONV do
        set_line(rig, n, 0)     -- not the limit lines: those are the rig's to drive, not ours
    end
    print("balancer stopped")
    return 0
end

return main({...})
