--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | THE BANK OF FLUIDS - the ME system, in the real base - and the row of
-- | tanks that shows it.
-- |
-- |     bank.FLUIDS         every fluid the scenario moves, ins and outs
-- |     bank.build(w)       makes the row match that list, and sizes it
-- |     bank.row(w)         finds the row without changing it
-- |
-- | Every fluid a recipe takes or makes has a tank, so the whole system is
-- | visible at a glance rather than hidden in a table.
-- |
-- | @date 2026-09-17 21:00
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local blocks = require("blocks")

local bank = {}

--[[ What to call the catalysts on screen.
-- |
-- | The game's own names are "Excited Dimensionally Transcendent Crude Catalyst" and three more
-- | like it, which is far too long to sit on a bar. The author asked on 2026-09-17 for
-- | "excited-crude, excited-prosaic" and so on.
-- |
-- | ONLY THE LABEL CHANGES. The fluid keeps the name GregTech registers it under, because that is
-- | what the recipes are matched against - renaming the fluid itself would quietly stop the mixer's
-- | output finding its tank.
-- | @date 2026-09-17 ]]
bank.DISPLAY = {
    exciteddtcc = "excited-crude",
    exciteddtrc = "excited-resplendent",
    exciteddtpc = "excited-prosaic",
    exciteddtec = "excited-exotic",
}

--[[ @brief What a fluid is called on screen. @date 2026-09-17 ]]
function bank.display(fluid)
    return bank.DISPLAY[fluid] or fluid
end

--[[ @brief Which of the bank's fluids nothing in the scenario produces.
-- |
-- | Core: DERIVED, NOT LISTED. A fluid is an input only if no fusion recipe makes it and it is not
-- | one of the mixer's catalysts - so the answer follows the recipes, and a modpack update that
-- | adds a way to make deuterium changes this by itself rather than needing the list edited.
-- |
-- | These are what the base buys in rather than makes, so they start full: the scenario is about
-- | ordering production, not about running out of hydrogen.
-- |
-- | @param scene    the scenario, for its catalysts
-- | @param mc_path  where Minecraft is, to read the recipes from
-- | @return table - fluid name -> true
-- |
-- | @date 2026-09-17 ]]
function bank.input_only(scene, mc_path)
    local produced = {}
    for _, e in ipairs(vc.fusion_recipes(mc_path or "")) do
        produced[e[5]] = true
    end
    for _, c in ipairs(scene.CATALYSTS or {}) do
        produced[c.fluid] = true
    end

    local out = {}
    for _, f in ipairs(bank.FLUIDS) do
        if not produced[f] then
            out[f] = true
        end
    end
    return out
end

--[[ Every fluid the scenario deals in, in a deliberate order: what the reactor makes, then what the
-- | mixer makes of it, then what the reactor eats.
-- |
-- | READ OUT OF THE RECIPES, not invented. The plasmas and the catalysts come from the Transcendent
-- | Plasma Mixer's four recipes; the feedstocks are every non-plasma input of the fusion recipes
-- | that make those plasmas. GregTech's own naming: a plasma is `plasma.<material>`, a molten metal
-- | is `molten.<material>`, and a gas is just the material.
-- |
-- | Helium-3 is spelled with a hyphen, which is GregTech's spelling and not a typo here.
-- | @date 2026-09-17 ]]
bank.FLUIDS = {
    -- the sixteen plasmas, in the mixer's own order
    "plasma.helium", "plasma.iron", "plasma.calcium", "plasma.niobium",
    "plasma.radon", "plasma.nickel", "plasma.boron", "plasma.sulfur",
    "plasma.nitrogen", "plasma.zinc", "plasma.silver", "plasma.titanium",
    "plasma.americium", "plasma.bismuth", "plasma.oxygen", "plasma.tin",

    -- what the mixer makes of them
    "exciteddtcc", "exciteddtrc", "exciteddtpc", "exciteddtec",

    -- and what the fusion reactor eats to make the plasmas
    "deuterium", "tritium", "helium-3", "helium", "oxygen", "fluorine",
    "molten.carbon", "molten.aluminium", "molten.lithium", "molten.beryllium",
    "molten.silicon", "molten.magnesium", "molten.potassium", "molten.copper",
    "molten.cobalt", "molten.gold", "molten.arsenic", "molten.silver",
    "molten.tantalum",
}

--[[ @brief Finds the row of tanks that stands for the bank.
-- |
-- | Core: THE LONGEST STRAIGHT RUN OF TANKS ON THE GROUND. The scenario's other tanks are the
-- | reactor's two inputs and the sixteen the program reads, and those sit in short groups or above
-- | ground; the bank is the long line. Recognising it by its shape means the row can be built
-- | anywhere and moved without editing this file.
-- |
-- | @param w  world
-- | @return table | nil - {x, y, z, dx, dz, count}, the first tank and the way the row runs
-- |
-- | @date 2026-09-17 21:00
--]]
function bank.row(w)
    local at = {}
    for _, cell in ipairs(w:occupied()) do
        if blocks.is_tank(cell.kind) then
            local p = cell:pos()
            if p[2] == 0 then
                at[p[1] .. "," .. p[3]] = p
            end
        end
    end

    local best = nil
    for _, p in pairs(at) do
        for _, d in ipairs({{1, 0}, {0, 1}}) do
            -- Only start counting at the beginning of a run, so a row is measured once.
            if not at[(p[1] - d[1]) .. "," .. (p[3] - d[2])] then
                local n = 0
                while at[(p[1] + d[1] * n) .. "," .. (p[3] + d[2] * n)] do
                    n = n + 1
                end
                if n > 1 and (not best or n > best.count) then
                    best = {x = p[1], y = 0, z = p[3], dx = d[1], dz = d[2], count = n}
                end
            end
        end
    end
    return best
end

--[[ @brief Makes the row of tanks match the fluid list, sizes it, and sets the starting levels.
-- |
-- | Core: ONE TANK PER FLUID, in the order bank.FLUIDS gives, each holding what a Quantum Tank III
-- | holds. The row is extended along its own direction when it is short and the extra tanks are
-- | taken away when it is long, so the map does not have to be counted out by hand.
-- |
-- | The levels are SET, not kept: what the base buys in starts full and what the scenario makes
-- | starts empty. A rig that begins wherever the last run left it is not a rig you can compare two
-- | balancers in.
-- |
-- | @param w      world
-- | @param scene  the scenario, for its bank capacity
-- | @return number placed, number removed, table complaints
-- |
-- | @date 2026-09-17 21:00
--]]
function bank.build(w, scene, mc_path)
    local complaints = {}
    local row = bank.row(w)
    if not row then
        return 0, 0, {"no row of tanks on the ground to use as the bank"}
    end

    local cap = scene.BANK.cap_per_fluid
    local placed, removed = 0, 0

    -- THE STARTING STATE, and it is a defined one rather than whatever was left over. What the base
    -- buys in starts full; everything the scenario is supposed to MAKE starts at nothing, so a run
    -- begins from the same place every time and a balancer cannot look good by inheriting a full
    -- bank from the last one.
    local feedstock = bank.input_only(scene, mc_path)

    for i = 1, #bank.FLUIDS do
        local x = row.x + row.dx * (i - 1)
        local z = row.z + row.dz * (i - 1)
        local cell = w:get(x, 0, z)

        -- THE BANK ROW IS QUANTUM TANKS. A row standing in for an ME system holds 512,000,000 L
        -- of each fluid, which is a Quantum Tank III; the ordinary tanks elsewhere in a scene
        -- stand for input and output connections and stay at a Super Tank IV's 32,000,000. A tank
        -- of the wrong sort found in the row is replaced rather than resized, so what the row is
        -- made of says what it is.
        if cell and cell.kind ~= blocks.KIND.QTANK then
            w:clear(x, 0, z)
            cell = nil
        end

        if not cell then
            cell = blocks.make_qtank()
            if not w:set(x, 0, z, cell) then
                complaints[#complaints + 1] = string.format(
                        "no room for the bank tank at %d, 0, %d", x, z)
                cell = nil
            else
                placed = placed + 1
            end
        end

        if cell then
            cell:fluid_set_capacity(cap)
            local want = bank.FLUIDS[i]
            local label = bank.display(want)

            -- LOCKED, not filled. A tank says what it is for even while it is empty, which is the
            -- whole point of a bank: an empty chlorine tank is still the chlorine tank. Setting
            -- the contents to nothing would clear the fluid instead, because a tank holding no
            -- litres of something is just an empty tank - that is the mod's rule and ours.
            cell:fluid_lock_set(want, label)

            if feedstock[want] then
                cell:fluid_set(want, cap, label)
            else
                cell:fluid_set("", 0, "")
            end
        end
    end

    -- Anything left beyond the end of the list is not part of the bank any more.
    local i = #bank.FLUIDS
    while true do
        local x = row.x + row.dx * i
        local z = row.z + row.dz * i
        local cell = w:get(x, 0, z)
        if not cell or not blocks.is_tank(cell.kind) then
            break
        end
        w:clear(x, 0, z)
        removed = removed + 1
        i = i + 1
    end

    -- Every fluid draws now - the ones with no picture of their own use GregTech's greyscale
    -- stand-in tinted by the material's colour. What can still go wrong is the COLOUR: a material
    -- the material table does not cover comes out white, which is worth saying rather than
    -- wondering why one tank is the wrong shade.
    if vc.render_fluid_tint then
        local plain = {}
        for _, f in ipairs(bank.FLUIDS) do
            if vc.render_fluid_tile(f) >= 0 and math.floor(vc.render_fluid_tint(f)) == 0xffffff
                    and (f:find("^plasma%.") or f:find("^molten%.")) then
                plain[#plain + 1] = f
            end
        end
        if #plain > 0 then
            complaints[#complaints + 1] = string.format("%d fluids have no colour: %s",
                    #plain, table.concat(plain, ", "))
        end
    end

    return placed, removed, complaints
end

return bank
