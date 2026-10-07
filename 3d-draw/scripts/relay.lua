--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | The relay, as a connector speaks to it (console/protocol.h): the computers it has, attaching
-- | to one, opening a zone on it, and the zone's lines both ways. One connection is one computer.
-- | Runs on a coroutine the pool drives: every call that reads waits there, nothing else does.
-- |
-- |     relay.host()                      `relay` in ../config.ini, else 127.0.0.1
-- |     relay.fnv64(bytes)                the zone cache's hash, 16 hex digits
-- |     local c = relay.open(net, host, port)   nil and why when nothing listens
-- |     c:computers()                     the addresses the relay lists ('L')
-- |     c:attach(address)                 true, or false when it is not there ('A' -> 'Y' / 'N')
-- |     c:open_zone(name, code)           true, or false and why ('O' -> 'P'; a zone left open by
-- |                                       a connector that went is ended ('T') and opened again)
-- |     c:send_line(text)                 the zone's own conversation, one line ('d')
-- |     c:read_line()                     its next line; nil and why when the zone or the link
-- |                                       ended
-- |     c:close()
-- |
-- | `net` is vc's (net_composer.h) or a test's stand-in: connect, send, recv, close.
-- |
-- | @date 2026-10-05
-- | ===============================================================================================
--]]

local relay = {}

function relay.host()
    local f = io.open("../config.ini", "r")
    if f then
        for line in f:lines() do
            local key, value = line:match("^%s*([%w_]+)%s*=%s*(%S+)")
            if key == "relay" and not line:match("^%s*#") then
                f:close()
                return value
            end
        end
        f:close()
    end
    return "127.0.0.1"
end

-- FNV-1a, 64 bits, as protocol.h's payload_hash; Lua's integers wrap as the C++ ones do.
function relay.fnv64(s)
    local h = -3750763034362895579                    -- 0xcbf29ce484222325
    for i = 1, #s do
        h = (h ~ s:byte(i)) * 1099511628211           -- 0x100000001b3
    end
    return ("%016x"):format(h)
end

local Conn = {}
Conn.__index = Conn

function relay.open(net, host, port)
    local h = net.connect(host, port or 7778)
    if not h or h < 0 then return nil, "nothing listens at " .. host end
    return setmetatable({net = net, h = h, buf = "", text = "", closed = false}, Conn)
end

-- n more bytes, waiting for them; nil when the link closed.
function Conn:take(n)
    while #self.buf < n do
        if self.closed then return nil end
        local got = self.net.recv(self.h)
        if not got or got == "" then
            self.closed = true
            return nil
        end
        self.buf = self.buf .. got
    end
    local out = self.buf:sub(1, n)
    self.buf = self.buf:sub(n + 1)
    return out
end

local function u8(c) return c and c:byte(1) end

function Conn:str8()
    local n = u8(self:take(1))
    return n and self:take(n)
end

function Conn:computers()
    if self:take(1) ~= "L" then return nil end
    local n = u8(self:take(1))
    local out = {}
    for i = 1, n or 0 do out[i] = self:str8() end
    return out
end

function Conn:attach(address)
    self.net.send(self.h, "A" .. string.char(#address) .. address)
    while true do
        local t = self:take(1)
        if t == "Y" then return true end
        if t ~= "N" then return false end
        self:computers()                               -- 'N' comes with a new list
        return false
    end
end

-- One frame of the zone's channel: kind, then its data ('d', 'x', 'P', 'z'). nil when the link
-- closed - before the frame or inside it: a frame cut short had come back as 'd' with no data,
-- and read_line's concatenation ended the robot's whole life - ASIMO never linked again, the
-- watchdog closing its dead link every second (2026-10-06).
function Conn:frame()
    local t = self:take(1)
    if not t then return nil end
    local function sized()
        local len = self:take(2)
        return len and self:take(string.unpack(">I2", len))
    end
    if t == "P" then
        local status, _ = u8(self:take(1)), self:take(1)
        local data = sized()
        if not data then return nil end
        return "P", status, data
    elseif t == "z" then
        local names = {}
        for i = 1, u8(self:take(1)) or 0 do names[i] = self:str8() end
        return "z", names
    elseif t == "d" or t == "x" then
        local data = sized()
        if not data then return nil end
        return t, data
    end
    return "?", t
end

function Conn:open_zone(name, code)
    local hash = relay.fnv64(code)
    local msg = "O" .. string.char(#name) .. name .. string.char(#hash) .. hash .. "\1"
            .. string.pack(">I4", #code) .. code
    self.net.send(self.h, msg)
    local retried = false
    while true do
        local kind, a, b = self:frame()
        if not kind then return false, "the link closed" end
        if kind == "P" then
            if a == 0 then return true end
            if b and b:find("open already") and not retried then
                retried = true
                self.net.send(self.h, "T" .. string.char(#name) .. name)
                self.net.send(self.h, msg)
            else
                return false, b
            end
        elseif kind == "d" then
            self.text = self.text .. a                -- it may speak before its 'P'
        elseif kind == "x" then
            return false, "the zone ended: " .. tostring(a)
        end
    end
end

function Conn:send_line(text)
    local data = text .. "\n"
    for i = 1, #data, 60000 do
        local part = data:sub(i, i + 59999)
        self.net.send(self.h, "d" .. string.pack(">I2", #part) .. part)
    end
end

function Conn:read_line()
    while not self.text:find("\n", 1, true) do
        local kind, data = self:frame()
        if not kind then return nil, "the link closed" end
        if kind == "x" then return nil, "the zone ended: " .. tostring(data) end
        if kind == "d" then self.text = self.text .. data end
    end
    local line, rest = self.text:match("^([^\n]*)\n(.*)$")
    self.text = rest
    return line
end

function Conn:close()
    if not self.closed then
        self.closed = true
        self.net.close(self.h)
    end
end

return relay
