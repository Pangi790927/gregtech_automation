--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | load(path: string)                      -> table
-- |     Reads the settings file, filling in any key it does not carry
-- |     from DEFAULTS, and returns the live table every other module
-- |     then reads.
-- |
-- | save(path: string)                       -> boolean
-- |     Writes the live table back, one `key = value` per line. Answers
-- |     false when the file cannot be opened for writing.
-- |
-- | get(key: string)                         -> string | number | boolean
-- | set(key: string, value: any)             -> nothing
-- |     The live table, reached by name. `set` marks the settings dirty
-- |     so the next save actually writes.
-- |
-- | dirty()                                  -> boolean
-- |     Has anything changed since the last load or save?
-- |
-- | DEFAULTS                                 table
-- |     Every key the simulator knows about, with the value it takes
-- |     when the file is absent or silent about it.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     parse_value, format_value
-- |
-- | @date 2026-09-16 16:00
-- | ===============================================================================================
--]]

local settings = {}

--[[ @brief Every setting the simulator has, and what it is worth when nothing says otherwise.
-- |
-- | `minecraft_path` is the one the author asked for by name: the settings file remembers where
-- | Minecraft is, and the renderer reads the OpenComputers textures out of the instance there. It
-- | points at the instance directory - the one holding `mods` - not at the jar. An empty string, or
-- | a path with no OpenComputers jar under it, is the ordinary case rather than a fault: the
-- | renderer then draws its hand-made shapes instead, and the interface says so.
-- |
-- | The default is the GregTech: New Horizons instance this project was written against. It is a
-- | guess about one machine, which is exactly what a default is for - it gets written into the
-- | settings file on the first run and edited from there.
-- |
-- | @date 2026-09-16 16:00
--]]
settings.DEFAULTS = {
    minecraft_path   = "C:/Users/apangratie/curseforge/minecraft/Instances/GT New Horizons",
    -- The vanilla jar, for the blocks that are not OpenComputers' - a redstone lamp is Minecraft's
    -- own. A directory works too; the launcher's usual versions/ layout is searched underneath.
    minecraft_jar    =
            "C:/Users/apangratie/curseforge/minecraft/Install/versions/1.7.10/1.7.10.jar",
    mouse_speed      = 0.0032,   -- radians of turn per pixel of mouse travel
    move_speed       = 9.0,      -- cells per second
    move_speed_fast  = 26.0,     -- cells per second while shift is held
    fov              = 70.0,     -- degrees
    invert_y         = false,
    autosave         = true,     -- write the world back out on the way to exit
}

local values = {}
local changed = false

--[[ @brief Turns one text value from the file back into a Lua value.
-- |
-- | Types are recovered from the text rather than declared: `true` and `false` become booleans, a
-- | string that is entirely a number becomes one, and everything else stays a string. That keeps
-- | the file editable by hand without a schema beside it, which matters because editing it by hand
-- | is how the Minecraft path gets corrected.
-- |
-- | @param text  string - the part after the equals sign, already trimmed
-- | @return string | number | boolean
-- |
-- | @date 2026-09-16 16:00
--]]
local function parse_value(text)
    if text == "true" then
        return true
    end
    if text == "false" then
        return false
    end
    local num = tonumber(text)
    if num then
        return num
    end
    return text
end

--[[ @brief Turns a Lua value into the text the file stores.
-- |
-- | The inverse of parse_value for booleans and strings. A number is written through `%.6g`, which
-- | is short enough to stay readable and precise enough that a mouse speed survives the round trip.
-- |
-- | @param value  string | number | boolean
-- | @return string
-- |
-- | @date 2026-09-16 16:00
--]]
local function format_value(value)
    if type(value) == "boolean" then
        return value and "true" or "false"
    end
    if type(value) == "number" then
        return string.format("%.6g", value)
    end
    return tostring(value)
end

--[[ @brief Reads the settings file and returns the live settings table.
-- |
-- | Core: every key in DEFAULTS is present afterwards whatever the file said, so no caller has to
-- | guard against a missing setting. A key in the file that DEFAULTS does not know is kept as well
-- | - an unknown setting is more likely to be one this version has not learned yet than a mistake,
-- | and silently dropping it would lose a user's edit on the next save.
-- |
-- | A missing file is not an error. It is simply the first run, and the defaults stand until
-- | something calls save().
-- |
-- | @param path  string - where the settings file lives
-- | @return table - the live table; the same one get() and set() reach
-- |
-- | @date 2026-09-16 16:00
--]]
function settings.load(path)
    values = {}
    for key, value in pairs(settings.DEFAULTS) do
        values[key] = value
    end

    local file = io.open(path, "r")
    if not file then
        changed = true    -- nothing on disk yet, so the first save has something to write
        return values
    end

    for line in file:lines() do
        -- Blank lines and `#` comments are skipped, so the file can be annotated by hand.
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local key, text = trimmed:match("^([%w_]+)%s*=%s*(.-)$")
            if key then
                values[key] = parse_value(text)
            end
        end
    end
    file:close()

    changed = false
    return values
end

--[[ @brief Writes the live settings table back out.
-- |
-- | The keys are sorted, so two saves of the same settings produce the same file and a diff shows
-- | only what actually changed.
-- |
-- | @param path  string - where to write
-- | @return boolean - false when the file could not be opened for writing
-- |
-- | @date 2026-09-16 16:00
--]]
function settings.save(path)
    local file = io.open(path, "w")
    if not file then
        return false
    end

    local keys = {}
    for key in pairs(values) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    file:write("# gregtech_automation simulator settings\n")
    file:write("# minecraft_path points at the instance directory, the one holding mods/\n")
    for _, key in ipairs(keys) do
        file:write(string.format("%s = %s\n", key, format_value(values[key])))
    end
    file:close()

    changed = false
    return true
end

--[[ @brief One setting, by name. @date 2026-09-16 16:00 ]]
function settings.get(key)
    return values[key]
end

--[[ @brief Changes one setting and marks the file as needing a write.
-- |
-- | @param key    string
-- | @param value  string | number | boolean
-- |
-- | @date 2026-09-16 16:00
--]]
function settings.set(key, value)
    if values[key] == value then
        return
    end
    values[key] = value
    changed = true
end

--[[ @brief Has anything changed since the last load or save? @date 2026-09-16 16:00 ]]
function settings.dirty()
    return changed
end

return settings
