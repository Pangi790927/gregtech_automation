ev = require("event")
fs = require("filesystem")

helpers = {}
helpers.logfile = fs.open("/home/logfile.log", "w")

function LOG(fmt, ...) helpers.logfile:write(string.format(fmt, ...) .. "\n") end

function helpers.dbg_tprint(tbl, indent)
    if not indent then
        indent = 0
    end
    for k, v in pairs(tbl) do
        formatting = string.rep("  ", indent) .. k .. ": "
        if type(v) == "table" then
            print(formatting)
            helpers.dbg_tprint(v, indent+1)
        elseif type(v) == 'boolean' then
            print(formatting .. tostring(v))      
        else
            print(formatting .. v)
        end
    end
end

function helpers.copy(obj, seen)
    if type(obj) ~= 'table' then
        return obj
    end
    if seen and seen[obj] then
        return seen[obj]
    end
    local s = seen or {}
    local res = setmetatable({}, getmetatable(obj))
    s[obj] = res
    for k, v in pairs(obj) do
        res[helpers.copy(k, s)] = helpers.copy(v, s)
    end
    return res
end


function helpers.gcd(a, b)
    return b == 0 and a or helpers.gcd(b, a % b)
end

function helpers.lcd(a, b)
    return a * b / helpers.gcd(a, b)
end

function helpers.wait_key()
    _, _, c = ev.pull("key_down")
    return string.char(c)
end

return helpers
