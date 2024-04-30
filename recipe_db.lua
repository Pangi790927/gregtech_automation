-- INFO: recipes:
-- the format of a recipe is:
--   <id> <label> <items...> <input_liquid> <res_cnt> <flags>
-- where items are a list of labels and counts
-- flags are:
--   char  1:   if the result is a liquid
--   char  2:   if the result is visible in the recipe table
--   char  3:   the machine id
--   chars 4,5: the machine config setting

recipe_db = { file = "recipes.db"}

recipe_db.example_recipe = {
    label = "iron_plate",
    comp = {
        { label="iron_ore", cnt=1, msz=64 },
        { label="iron_nugget", cnt=2, msz=64 },
        { label="ender_pearl", cnt=14, msz=16 }
    },
    liq = { label="hidrogen", cnt=144, msz=1000 },
    liq_out = { label="melted_iron", cnt=345, msz=144 },
    out = {
        { label="iron_plate", cnt=4, msz=64 },
        { label="wood_pulp", cnt=3, msz=64 }
    },
    res_cnt=4,
    is_liq = 0,
    is_visible=0,
    mach_id=3,
    mach_cfg=2,
}

function recipe2str(r)
    local ret = r.label .. " "
    ret = ret .. "["
    for i=1, #r.comp do
        local c = r.comp[i]
        ret = ret .. c.label .. " " .. c.cnt .. " " .. c.msz
        if not (i == #r.comp) then
            ret = ret .. " "
        end
    end
    ret = ret .. "] "
    ret = ret .. r.liq.label .. " " .. r.liq.cnt .. " " .. r.liq.msz .. " "
    ret = ret .. r.liq_out.label .. " " .. r.liq_out.cnt .. " " .. r.liq_out.msz .. " "
    ret = ret .. r.res_cnt .. " "
    -- 8x0 are reserved for further use
    ret = ret .. r.is_liq .. r.is_visible .. r.mach_id .. "00000000" .. r.mach_cfg .. " "
    ret = ret .. "["
    for i=1, #r.out do
        local c = r.out[i]
        ret = ret .. c.label .. " " .. c.cnt .. " " .. c.msz
        if not (i == #r.out) then
            ret = ret .. " "
        end
    end
    ret = ret .. "]"
    return ret
end

function str2recipe(str)
    local res = {}
    local split = {}
    for s in str:gmatch("%S+") do
        table.insert(split, s)
    end
    res.label = split[1]
    res.comp = {}
    local last_comp_i = 3
    if not (split[2] == "[]") then
        for i=2, #split, 3 do
            local word = split[i]
            local word2 = split[i + 1]
            local word3 = split[i + 2]
            local stop = 0
            last_comp_i = i + 2
            if word:sub(1,1) == "[" then
                word = word:sub(2, #word)
            end
            if word3:sub(#word3, #word3) == "]" then
                word3 = word3:sub(1, #word3 - 1)
                stop = 1
            end
            table.insert(res.comp, {label=word, cnt=tonumber(word2), msz=tonumber(word3)})
            if stop == 1 then
                break
            end
        end
    end
    res.liq = {}
    res.liq.label = split[last_comp_i + 1]
    res.liq.cnt = tonumber(split[last_comp_i + 2])
    res.liq.msz = tonumber(split[last_comp_i + 3])
    res.liq_out = {}
    res.liq_out.label = split[last_comp_i + 4]
    res.liq_out.cnt = tonumber(split[last_comp_i + 5])
    res.liq_out.msz = tonumber(split[last_comp_i + 6])
    res.res_cnt = tonumber(split[last_comp_i + 7])
    local flags = split[last_comp_i + 8]
    res.is_liq = tonumber(flags:sub(1, 1))
    res.is_visible = tonumber(flags:sub(2, 2))
    res.mach_id = tonumber(flags:sub(3, 3))
    res.mach_cfg = tonumber(flags:sub(12, #flags))
    res.out = {}
    if not (split[last_comp_i + 9] == "[]") then
        for i=last_comp_i + 9, #split, 3 do
            local word = split[i]
            local word2 = split[i + 1]
            local word3 = split[i + 2]
            local stop = 0
            last_comp_i = i + 2
            if word:sub(1,1) == "[" then
                word = word:sub(2, #word)
            end
            if word3:sub(#word3, #word3) == "]" then
                word3 = word3:sub(1, #word3 - 1)
                stop = 1
            end
            table.insert(res.out, {label=word, cnt=tonumber(word2), msz=tonumber(word3)})
            if stop == 1 then
                break
            end
        end
    end
    return res
end

function recipe_db.add_recipe(recipe)
    local f = io.open(recipe_db.file, "r")
    local line
    if not f then
        local f = io.open(recipe_db.file, "a")
        f:write(recipe2str(recipe) .. "\n")
        f:close()
        return true
    end
    line = f:read("*l")
    while line do
        r = str2recipe(line)
        if r.label == recipe.label then
            print("Can't add recipe, recipe existing, label: ", r.label)
            f:close()
            return false
        end
        line = f:read("*l")
    end
    f:close()
    local f = io.open(recipe_db.file, "a")
    f:write(recipe2str(recipe) .. "\n")
    f:close()
    return true
end

function recipe_db.rm_recipe(label)
    local f = io.open(recipe_db.file, "r")
    local fn = io.open(recipe_db.file .. ".new", "w")
    local line
    local found = false
    line = f:read("*l")
    while line do
        r = str2recipe(line)
        if r.label ~= label then
            fn:write(line .. "\n")
        else
            print("deleted line: ", line)
            found = true
        end
        line = f:read("*l")
    end
    if found == false then
        print("nothing to delete")
        f:close()
        fn:close()
        fn = io.open(recipe_db.file .. ".new", "w")
        fn:close()
        return
    end
    f:close()
    fn:close()
    fn = io.open(recipe_db.file .. ".new", "r")
    f = io.open(recipe_db.file, "w")
    line = fn:read("*l")
    while line do
        r = str2recipe(line)
        if r.label ~= label then
            f:write(line .. "\n")
        end
        line = fn:read("*l")
    end
    f:close()
    fn:close()
    fn = io.open(recipe_db.file .. ".new", "w")
    fn:close()
end

function recipe_db.find_recipes(label_list)
    local res = {}
    local f = io.open(recipe_db.file, "r")
    if not f then
        print("no database")
        return res
    end
    local line = f:read("*l")
    if not label_list then
        print("nil not ok")
        return res
    end
    if not (type(label_list) == "table") then
        print("not table not ok")
        return res
    end
    while line do
        r = str2recipe(line)
        local found = false
        for i=1, #label_list do
            local label = label_list[i]
            if r.label == label then
                res[label] = r 
                found = true
                break
            end
        end
        line = f:read("*l")
    end
    f:close()
    return res
end

function recipe_db.get_recipes(start_id, stop_id)
    local res = {}
    local f = io.open(recipe_db.file, "r")
    if not f then
        print("no database")
        return res
    end
    local line = f:read("*l")
    local curr_line = 1
    while line do
        if curr_line > stop_id then
            break
        end
        if curr_line >= start_id then
            r = str2recipe(line)
            table.insert(res, r)
        end
        curr_line = curr_line + 1
        line = f:read("*l")
    end
    f:close()
    return res
end

return recipe_db
