ev = require("event")
fs = require("filesystem")

helpers = {}
helpers.logfile = fs.open("/home/logfile.log", "w")

function LOG(fmt, ...) helpers.logfile:write(string.format(fmt, ...) .. "\n") end

function LOG_RECIPE(r)
    LOG("name: %s", r.name)
    for k, v in ipairs(r.comp) do
        LOG("    -> cnt: %5d msz: %5d comp: %s", v.cnt, v.msz, v.label)
    end
    if r.liq then
        LOG("    li-> cnt: %5d msz: %5d comp: %s", v.liq.cnt, v.liq.msz, v.liq.label)
    end
    if r.liq_out then
        LOG("    li<- cnt: %5d msz: %5d comp: %s", v.liq_out.cnt, v.liq_out.msz, v.liq_out.label)
    end
    for k, v in ipairs(r.out) do
        LOG("    -> cnt: %5d msz: %5d comp: %s", v.cnt, v.msz, v.label)
    end
    LOG("    flags: is_li[] is_vis[] res_cnt[%d]", r.is_liq, r.is_visible, r.res_cnt)
    LOG("    mach: id[%d] cfg[%d]", r.mach_id, mach_cfg)
end

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
