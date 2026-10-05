--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The mini ME, linked through the relay like a robot: its computer runs robot/me_machine.lua as
-- | the zone `rme` (redesign/11-me.md). Asked only when needed; one command at a time.
-- |
-- |     me.link(on)                  opens (or ends) the link, on a coroutine of its own
-- |     me.ask(command)              ok, value | nil, why - waits for the link and its turn
-- |     me.items()                   {["name:meta"] = count} the network holds, or nil, why;
-- |                                  also the exe's view of it from then on (me.view)
-- |     me.view                      what the exe holds the network to hold: read once, then
-- |                                  kept by the exe - me.moved(kk, n) for every take (n < 0)
-- |                                  and give (n > 0) it orders (redesign/11-me.md)
-- |     me.config(slots)             one request: {[slot] = {name, meta, n}} stocked, every slot
-- |                                  left to clear (me.later_clear) cleared in the same line
-- |     me.later_clear(slots)        slots to clear with the next config, or me.flush()
-- |     me.SPOT, me.FACE, me.INTERFACE   where a robot stands at the interface, which way it
-- |                                  faces, the interface's cell (robot coordinates)
-- |     me.STOCK, me.RETURN          slots 1-8 stocked for the robot there; 9 never stocked
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local relay = require("relay")
local robots = require("robots")

local me = {phase = "not linked", linked = false, conn = nil, busy = false, rid = 0}

local ADDRESS, ZONE, PORT, CODE_PATH = "9cdb8754", "rme", 7778, "robot/me_machine.lua"
me.INTERFACE, me.SPOT, me.FACE = {1, 0, 1}, {0, 0, 1}, "e"
me.STOCK, me.RETURN = {1, 2, 3, 4, 5, 6, 7, 8}, 9
me.stocked = {}                         -- slot -> "name:meta" as configured now
local to_clear = {}

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

-- The link's life: connect, attach, open the zone, then hold it until unlinked or lost.
local function life(gen)
    local net = robots.net
    local function mine() return me.linked and me.gen == gen end
    while mine() do
        me.phase = "connecting"
        local c, why = relay.open(net, relay.host(), PORT)
        if c then
            local addr
            for _, a in ipairs(c:computers() or {}) do
                if a:sub(1, #ADDRESS) == ADDRESS then addr = a end
            end
            if not addr then
                me.phase = "not on the relay"
            elseif not c:attach(addr) then
                me.phase = "could not attach"
            else
                local ok, err = c:open_zone(ZONE, read_file(CODE_PATH) or "")
                local ready = ok and c:read_line()
                if not ready then
                    me.phase = "zone: " .. tostring(err or "no ready")
                else
                    me.conn, me.phase = c, "linked"
                    while mine() and not c.closed do net.sleep(500) end
                    me.conn = nil
                end
            end
            c:close()
        else
            me.phase = "no relay: " .. tostring(why)
        end
        if mine() then net.sleep(5000) end
    end
    if me.gen == gen then me.phase = "not linked" end
end

function me.link(on)
    if on == false then
        me.linked = false
        return
    end
    if me.linked then return end
    me.linked, me.gen = true, (me.gen or 0) + 1
    vc.coroutine_spawn(life, me.gen)
end

function me.ask(cmd)
    for _ = 1, 300 do                                   -- 30 s for the link and for its turn
        if me.conn and not me.busy then break end
        vc.net_sleep_ms(100)
    end
    local c = me.conn
    if not c or me.busy then return nil, "the ME is " .. me.phase end
    me.busy = true
    me.rid = me.rid + 1
    local rid = tostring(me.rid)
    c:send_line(rid .. " " .. cmd)
    local value, why
    while true do
        local line, err = c:read_line()
        if not line then why = "link lost: " .. tostring(err) break end
        if line:sub(1, #rid + 1) == rid .. " " then
            local ok, rest = line:match("^%S+ (%S+) ?(.*)$")
            if ok == "ok" then value = rest:gsub("^%d+ ?", "") else why = rest end
            break
        end
    end
    me.busy = false
    if why then return nil, why end
    return true, value
end

function me.items()
    local ok, v = me.ask("items")
    if not ok then return nil, v end
    local out = {}
    for name, dmg, n in v:gmatch("([^;]+):(%d+):(%d+)") do
        out[name .. ":" .. dmg] = (out[name .. ":" .. dmg] or 0) + tonumber(n)
    end
    me.view = out
    return out
end

function me.moved(kk, n)
    if not me.view then return end
    me.view[kk] = math.max(0, (me.view[kk] or 0) + n)
end

function me.later_clear(slots)
    for _, s in ipairs(slots) do to_clear[s] = true end
end

function me.config(slots)
    local parts = {}
    for s in pairs(to_clear) do
        if not slots[s] then parts[#parts + 1] = s .. " -" end
    end
    local keys = {}
    for s in pairs(slots) do keys[#keys + 1] = s end
    table.sort(keys)
    for _, s in ipairs(keys) do
        local it = slots[s]
        parts[#parts + 1] = ("%d %s %d %d"):format(s, it[1], it[2], it[3])
    end
    if #parts == 0 then return true, "" end
    local ok, v = me.ask("config " .. table.concat(parts, " "))
    if not ok then return nil, v end
    for s in pairs(to_clear) do me.stocked[s] = nil end
    to_clear = {}
    for s, it in pairs(slots) do me.stocked[s] = it[1] .. ":" .. it[2] end
    return true, v
end

function me.flush() return me.config({}) end

return me
