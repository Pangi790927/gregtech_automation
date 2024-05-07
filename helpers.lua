ev = require("event")
fs = require("filesystem")

helpers = {}

if logfile == nil then
    logfile = fs.open("/home/logfile.log", "w")
end

function LOG(fmt, ...) logfile:write(string.format(fmt, ...) .. "\n") end

function LOG_RECIPE(r)
    LOG("name: %s", r.name)
    for k, v in ipairs(r.comp) do
        LOG("    it-> cnt: %5d msz: %5d comp: %s", v.cnt, v.msz, v.label)
    end
    if r.liq then
        LOG("    LI-> cnt: %5d msz: %5d comp: %s", r.liq.cnt, r.liq.msz, r.liq.label)
    end
    if r.liq_out then
        LOG("    LI<- cnt: %5d msz: %5d comp: %s", r.liq_out.cnt, r.liq_out.msz, r.liq_out.label)
    end
    for k, v in ipairs(r.out) do
        LOG("    it<- cnt: %5d msz: %5d comp: %s", v.cnt, v.msz, v.label)
    end
    local mach_cfg = -1
    if r.mach_cfg ~= nil then
        mach_cfg = r.mach_cfg
    end
    LOG("    flags: is_li[%d] is_vis[%d] res_cnt[%d]", r.is_liq, r.is_visible, r.res_cnt)
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
