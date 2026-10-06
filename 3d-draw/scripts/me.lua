--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The mini ME, linked through the relay like a robot: its computer runs robot/me_machine.lua as
-- | the zone `rme` (redesign/11-me.md). Asked only when needed; one command at a time. Two
-- | interfaces, a station each (redesign/17-stations.md).
-- |
-- |     me.link(on)                  opens (or ends) the link, on a coroutine of its own; once
-- |                                  linked, the interfaces listed (me.list_ifaces)
-- |     me.relink()                  the link opened anew - me_machine.lua read again - in its
-- |                                  turn as an ask, so no request is cut
-- |     me.ask(command)              ok, value | nil, why - waits for the link and its turn
-- |     me.items()                   {["name:meta"] = count} the network holds, or nil, why;
-- |                                  also the exe's view of it from then on (me.view)
-- |     me.view                      what the exe holds the network to hold: read once, then
-- |                                  kept by the exe - me.moved(kk, n) for every take (n < 0)
-- |                                  and give (n > 0) it orders (redesign/11-me.md)
-- |     me.stations                  {n, INTERFACE, SPOT, FACE, addr, stocked, to_clear, owner}
-- |                                  each: the interface's cell, where a robot stands and faces,
-- |                                  its component's address (nil: not known), what is stocked
-- |                                  ("name:meta" a slot), the slots to clear, its lock's holder
-- |                                  (station 2 on; station 1's is crew.me_owner)
-- |     me.open()                    the stations in use: the first always, the second once its
-- |                                  address is known and it is not switched off (st.off)
-- |     me.config(slots, st)         one request on station st (default the first): {[slot] =
-- |                                  {name, meta, n}} stocked, every slot left to clear cleared
-- |     me.later_clear(slots, st)    slots to clear with st's next config, or me.flush(st)
-- |     me.parse_ifaces(v)           the answer of `ifaces` -> {{addr, first, slots}, ...}
-- |     me.identify(list, stocked)   which address is the first station's -> a1, a2 | nil, why
-- |     me.learn()                   asked after a robot took at the first station: the two told
-- |                                  apart by what it took (me.identify) -> true, note | nil, why
-- |     me.SPOT, me.FACE, me.INTERFACE, me.stocked   the first station's, as before
-- |     me.STOCK, me.RETURN          slots 1-8 stocked for the robot there; 9 never stocked
-- |
-- | Read again in place (`lua dofile('scripts/me.lua')`, or `reload me`): the link, the view,
-- | the stations and what is stocked are kept - the same table, so every holder of it goes on.
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local vc = require("virt_composer")
local spawn = require("spawn")         -- spawns that keep their handle
local relay = require("relay")
local robots = require("robots")

-- the module already loaded (dofile), or kept by its unload (`reload me`): the same table
local me = package.loaded["me"]
if type(me) ~= "table" then me = rawget(_G, "ME_KEPT") end
rawset(_G, "ME_KEPT", nil)
if type(me) ~= "table" then
    me = {phase = "not linked", linked = false, conn = nil, busy = false, rid = 0}
end

local ADDRESS, ZONE, PORT, CODE_PATH = "9cdb8754", "rme", 7778, "robot/me_machine.lua"
me.STOCK, me.RETURN = {1, 2, 3, 4, 5, 6, 7, 8}, 9
me.ASK_WAIT_MS = 120000     -- the link and its turn: two stations queue more asks (17-stations)

-- The stations (17-stations.md): the first, robot (1,0,1), its spot west of it; the second,
-- (1,1,2) above the adapter (world 256 64 141), its spot (0,1,2) - Cairol stood there, east of
-- it the interface (2026-10-06). The first keeps the table me.stocked always was.
me.stocked = me.stocked or {}
me.stations = me.stations or {}
local PLACES = {{INTERFACE = {1, 0, 1}, SPOT = {0, 0, 1}, FACE = "e"},
                {INTERFACE = {1, 1, 2}, SPOT = {0, 1, 2}, FACE = "e"}}
for n, p in ipairs(PLACES) do
    local st = me.stations[n] or {n = n, to_clear = {}}
    st.INTERFACE, st.SPOT, st.FACE = p.INTERFACE, p.SPOT, p.FACE
    st.stocked = n == 1 and me.stocked or st.stocked or {}
    me.stations[n] = st
end
local S1 = me.stations[1]
me.INTERFACE, me.SPOT, me.FACE = S1.INTERFACE, S1.SPOT, S1.FACE

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

-- The station named by a table or a number; the first when none.
local function station(st)
    if type(st) == "number" then return me.stations[st] end
    return st or S1
end

--[[ The stations in use: the first always; the second only once its address is known - before,
-- every command goes to the first as it always did - and not switched off by hand (st.off). ]]
function me.open()
    local out = {S1}
    for n = 2, #me.stations do
        local st = me.stations[n]
        if st.addr and not st.off then out[#out + 1] = st end
    end
    return out
end

-- The link's life: connect, attach, open the zone, then hold it until unlinked or lost. Once
-- linked, the interfaces are listed on a coroutine of their own (read-only, me.list_ifaces).
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
                    me.learn_tries = 0
                    spawn(function() me.list_ifaces() end)
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
    spawn(life, me.gen)
end

--[[ The link opened anew, so the ME's computer reads robot/me_machine.lua again (its new
-- commands), without cutting a request: it waits its turn as an ask does and holds it while the
-- link closes and opens - the robots' asks wait meanwhile (ASK_WAIT_MS). -> true | nil, why ]]
function me.relink()
    local waited = 0
    while me.busy and waited < me.ASK_WAIT_MS do
        vc.net_sleep_ms(100)
        waited = waited + 100
    end
    if me.busy then return nil, "the ME stayed busy" end
    me.busy = true
    me.link(false)
    for _ = 1, 100 do
        if not me.conn then break end
        vc.net_sleep_ms(100)
    end
    vc.net_sleep_ms(600)                       -- the old life's last poll, its link closed
    me.link()
    for _ = 1, 600 do
        if me.conn then break end
        vc.net_sleep_ms(100)
    end
    me.busy = false
    if not me.conn then return nil, "not linked again: " .. tostring(me.phase) end
    return true
end

function me.ask(cmd)
    local waited = 0
    while not (me.conn and not me.busy) and waited < me.ASK_WAIT_MS do
        vc.net_sleep_ms(100)
        waited = waited + 100
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

function me.later_clear(slots, st)
    st = station(st)
    for _, s in ipairs(slots) do st.to_clear[s] = true end
end

--[[ One request on a station: its slots stocked, the ones left to clear cleared, in one line.
-- A station whose address is known is named (`at <addr> config ...`, me_machine.lua); the first
-- with no address known takes the plain command, as before there were two. ]]
function me.config(slots, st)
    st = station(st)
    local parts = {}
    for s in pairs(st.to_clear) do
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
    local cmd = "config " .. table.concat(parts, " ")
    if st.addr then cmd = "at " .. st.addr .. " " .. cmd
    elseif st ~= S1 then return nil, "station " .. st.n .. " has no address known" end
    local ok, v = me.ask(cmd)
    if not ok then return nil, v end
    for s in pairs(st.to_clear) do st.stocked[s] = nil end
    for s in pairs(st.to_clear) do st.to_clear[s] = nil end
    for s, it in pairs(slots) do st.stocked[s] = it[1] .. ":" .. it[2] end
    return true, v
end

function me.flush(st) return me.config({}, st) end

--[[ `ifaces`' answer, "addr8 [first ]cfg,...,cfg;..." with cfg name:damage:size or - (one per
-- slot, 1-9), into {{addr, first, slots = {[i] = "name:damage" | false}}, ...}. ]]
function me.parse_ifaces(v)
    local out = {}
    for part in (v or ""):gmatch("[^;]+") do
        local addr, rest = part:match("^%s*(%x+)%s+(.*)$")
        if addr then
            local first = rest:match("^first%s+") ~= nil
            rest = rest:gsub("^first%s+", "")
            local slots, i = {}, 0
            for cfg in (rest .. ","):gmatch("([^,]*),") do
                i = i + 1
                local nd = cfg:match("^(.+:%d+):%d+$")
                slots[i] = nd or false
            end
            out[#out + 1] = {addr = addr, first = first, slots = slots}
        end
    end
    return out
end

--[[ Which interface is the first station's: the one configured as the PC stocked it
-- (`stocked`, slot -> "name:meta", the first station's) right after a robot standing at the
-- first spot took those items - so that address is the interface in front of the spot - every
-- other slot empty; the other interface not so. Read-only; anything else is not decided, and
-- only the first station is used (17-stations.md). -> addr1, addr2 | addr1 (one interface) |
-- nil, why ]]
function me.identify(list, stocked)
    if #list == 1 then return list[1].addr end
    if #list ~= 2 then return nil, ("%d interfaces seen, not 2"):format(#list) end
    if not next(stocked or {}) then return nil, "nothing stocked to tell them apart by" end
    local function matches(it)
        for s = 1, 9 do
            local want, have = stocked[s] or false, it.slots[s] or false
            if want ~= have then return false end
        end
        return true
    end
    local a, b = matches(list[1]), matches(list[2])
    if a == b then
        return nil, a and "both interfaces configured alike" or "neither configured as stocked"
    end
    if a then return list[1].addr, list[2].addr end
    return list[2].addr, list[1].addr
end

--[[ The interfaces the ME's computer sees (`ifaces`, read-only), kept in me.ifaces. A station
-- whose address is no longer among them is let go (only the first used). An older
-- me_machine.lua without `ifaces` leaves everything on the first, said in me.ifaces_why. ]]
function me.list_ifaces()
    local ok, v = me.ask("ifaces")
    if not ok then
        me.ifaces, me.ifaces_why = nil, "ifaces: " .. tostring(v)
        return nil, me.ifaces_why
    end
    me.ifaces = me.parse_ifaces(v)
    local seen = {}
    for _, it in ipairs(me.ifaces) do seen[it.addr] = true end
    for _, st in ipairs(me.stations) do
        if st.addr and not seen[st.addr] then st.addr = nil end
    end
    if not S1.addr then
        for n = 2, #me.stations do me.stations[n].addr = nil end
    end
    me.ifaces_why = ("%d interface(s) seen"):format(#me.ifaces)
    return true, me.ifaces_why
end

-- Whether a take at the first station should be followed by me.learn: the second not known,
-- the ME's computer able to say (`ifaces` answered or not yet asked), three tries a link.
function me.wants_learning()
    local st2 = me.stations[2]
    if not st2 or st2.addr or (me.learn_tries or 0) >= 3 then return false end
    if me.ifaces and #me.ifaces < 2 then return false end
    return not (me.ifaces_why or ""):find("no command", 1, true)
end

--[[ Called right after a robot at the first station took what was stocked there, the stock
-- still configured: `ifaces` asked, and the two told apart by it (me.identify). Read-only.
-- -> true, note | nil, why (only the first station used then). ]]
function me.learn()
    me.learn_tries = (me.learn_tries or 0) + 1
    local ok, why = me.list_ifaces()
    if not ok then return nil, why end
    local a1, a2 = me.identify(me.ifaces, S1.stocked)
    if not a1 then return nil, "the interfaces not told apart: " .. tostring(a2) end
    if not a2 then return nil, "one interface only: station 1 as before" end
    S1.addr, me.stations[2].addr = a1, a2
    return true, ("the interfaces told apart: station 1 is %s, station 2 is %s"):format(a1, a2)
end

-- `reload me` keeps this table for the module read next (control.lua calls unload first).
function me.unload() rawset(_G, "ME_KEPT", me) end

return me
