--[[ The relay's frames in Lua (scripts/relay.lua) against a stand-in for the relay and the robot's
-- loader: the hash matches the Python side's, the list, the attach, a zone opened (once after
-- "open already"), the ready line, a command's reply split over frames.
-- @date 2026-10-05 ]]

local relay = require("relay")
local machine = require("machine")
local simbot = require("simbot")

-- A relay and a loader in one: bytes in through send, bytes out through recv, at once.
local function stand_in()
    local w = simbot.world({})
    local r = simbot.robot(w, {x = 0, y = 0, z = -2, facing = "n"})
    local m = machine.new(r.hw, {x = 0, y = 0, z = -2, facing = "n"})
    local f = {out = {}, opened = 0, sent = {}}
    local function d(text) return "d" .. string.pack(">I2", #text) .. text end
    f.out[1] = "L" .. string.char(2) .. string.char(8) .. "aaaaaaaa" .. string.char(8)
            .. "a77c49f1"
    function f.connect() return 1 end
    function f.close() end
    function f.recv()
        return table.remove(f.out, 1) or ""
    end
    function f.send(_, bytes)
        f.sent[#f.sent + 1] = bytes
        local t = bytes:sub(1, 1)
        if t == "A" then
            f.out[#f.out + 1] = "Y"
        elseif t == "O" then
            f.opened = f.opened + 1
            if f.opened == 1 then
                local msg = "open already"
                f.out[#f.out + 1] = "P" .. string.char(2, 0) .. string.pack(">I2", #msg) .. msg
            else
                f.out[#f.out + 1] = "P" .. string.char(0, 0) .. string.pack(">I2", 0)
                -- the ready line split over two frames
                local ready = "ready " .. m.status_fast() .. "\n"
                f.out[#f.out + 1] = d(ready:sub(1, 5))
                f.out[#f.out + 1] = d(ready:sub(6))
            end
        elseif t == "d" then
            local line = bytes:sub(4):gsub("\n$", "")
            local rid, cmd = line:match("^(%S+) (%S+)")
            if cmd == "status_fast" then
                f.out[#f.out + 1] = d(rid .. " ok 0 " .. m.status_fast() .. "\n")
            end
        end
    end
    return f
end

local function run_test()
    if relay.fnv64("hello, robot") ~= "77d026da4a773735" then
        return "fnv64 differs from the Python side: " .. relay.fnv64("hello, robot")
    end
    local f = stand_in()
    local c = relay.open(f, "127.0.0.1", 7778)
    local list = c:computers()
    if not list or list[2] ~= "a77c49f1" then return "the list" end
    if not c:attach("a77c49f1") then return "the attach" end
    local ok, why = c:open_zone("rmachine", "-- code")
    if not ok then return "the zone: " .. tostring(why) end
    if f.opened ~= 2 or f.sent[3]:sub(1, 1) ~= "T" then
        return "a zone open already was not ended and opened again"
    end
    local ready = c:read_line()
    if not ready or not ready:match("^ready %- idle 1 0 0 %-2 n %d+$") then
        return "the ready line: " .. tostring(ready)
    end
    c:send_line("7 status_fast")
    local reply = c:read_line()
    if not reply or not reply:match("^7 ok 0 %- idle") then
        return "the reply: " .. tostring(reply)
    end
    local o = f.sent[2]                             -- after the attach
    if o:sub(1, 1) ~= "O" or not o:find("rmachine", 1, true)
            or not o:find(relay.fnv64("-- code"), 1, true) then
        return "the open frame"
    end
    return nil
end

return {run_test = run_test}
